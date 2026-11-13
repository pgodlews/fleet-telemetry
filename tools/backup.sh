#!/usr/bin/env bash
#
# backup.sh - nightly backup of the Tesla telemetry stack (runs on the
# production host; see deploy/systemd/tesla-backup.{service,timer}).
#
# Each run writes into one flat directory, $BACKUP_DIR:
#   tesla-<UTC stamp>.dump          pg_dump custom format of the whole database,
#                                   taken through `docker exec` so the host needs
#                                   no PostgreSQL client tools
#   globals-<UTC stamp>.sql         roles (pg_dumpall --globals-only, no passwords),
#                                   needed to restore grants such as grafana_ro
#   attachments-<UTC stamp>.tar.gz  service-log photos (skipped if absent)
# with <UTC stamp> = YYYYmmddTHHMMSSZ.
#
# Every file is written under a ".partial" name and renamed only when it is
# complete and verified, so a host pulling this directory (tools/backup_pull.sh)
# never copies a half-written dump. Files are mode 640.
#
# Local retention: files older than KEEP_DAYS are deleted, but the newest 3
# dumps are always kept.
#
# Exit status is non-zero if any step fails; partial files of a failed run are
# removed. Restore: deploy/README.md, "Backup and restore".
#
# Configuration (environment, or /etc/default/tesla-backup via the systemd unit):
#   BACKUP_DIR       destination directory      (default /u01/backups/tesla)
#   KEEP_DAYS        local retention in days    (default 14)
#   DB_CONTAINER     database container         (default tesla-timescaledb)
#   DB_NAME          database                   (default tesla)
#   ATTACHMENTS_DIR  service-log photos on host (default /u01/fleet-telemetry/attachments)
#
# The off-host copy is pulled by a second machine (tools/backup_pull.sh); this
# script never pushes anywhere.

set -euo pipefail

BACKUP_DIR=${BACKUP_DIR:-/u01/backups/tesla}
KEEP_DAYS=${KEEP_DAYS:-14}
DB_CONTAINER=${DB_CONTAINER:-tesla-timescaledb}
DB_NAME=${DB_NAME:-tesla}
ATTACHMENTS_DIR=${ATTACHMENTS_DIR:-/u01/fleet-telemetry/attachments}
KEEP_MIN_DUMPS=3

log() {
  echo "backup: $*" >&2
  if command -v logger >/dev/null; then logger -t tesla-backup "$*" || true; fi
}

case "$KEEP_DAYS" in
  ''|*[!0-9]*) log "KEEP_DAYS must be a whole number, got '$KEEP_DAYS'"; exit 2 ;;
esac

mkdir -p "$BACKUP_DIR"
umask 027   # files 640, nothing world-readable

stamp=$(date -u +%Y%m%dT%H%M%SZ)
dump="$BACKUP_DIR/tesla-$stamp.dump"
globals="$BACKUP_DIR/globals-$stamp.sql"
attach="$BACKUP_DIR/attachments-$stamp.tar.gz"

cleanup_partials() {
  rm -f -- "$dump.partial" "$globals.partial" "$attach.partial"
}
fail() {
  log "FAILED: $*"
  cleanup_partials
  exit 1
}
trap 'fail "unexpected error on line $LINENO"' ERR

# finish <file>: make a completed .partial visible under its final name.
finish() {
  chmod 640 -- "$1.partial"
  mv -f -- "$1.partial" "$1"
}

docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null | grep -qx true \
  || fail "container $DB_CONTAINER is not running"

log "dumping $DB_NAME from $DB_CONTAINER"
# TimescaleDB dumps restore correctly when pg_restore is wrapped in
# timescaledb_pre_restore() / timescaledb_post_restore() (see the restore steps).
docker exec "$DB_CONTAINER" pg_dump -U postgres -d "$DB_NAME" -Fc \
  > "$dump.partial" || fail "pg_dump"
# A truncated dump still exists on disk; check that its table of contents reads.
docker exec -i "$DB_CONTAINER" pg_restore --list < "$dump.partial" > /dev/null \
  || fail "dump does not read back"
docker exec "$DB_CONTAINER" pg_dumpall -U postgres --globals-only --no-role-passwords \
  > "$globals.partial" || fail "pg_dumpall --globals-only"

if [ -d "$ATTACHMENTS_DIR" ]; then
  tar -C "$(dirname "$ATTACHMENTS_DIR")" -czf "$attach.partial" "$(basename "$ATTACHMENTS_DIR")" \
    || fail "attachments tar"
else
  log "attachments directory $ATTACHMENTS_DIR not found, skipping"
fi

# Globals and attachments first, the dump last: a puller that keys on the
# dump sees a complete set.
finish "$globals"
if [ -f "$attach.partial" ]; then finish "$attach"; fi
finish "$dump"
trap - ERR

log "ok: $(basename "$dump") ($(du -h "$dump" | cut -f1))"

# Retention. Never delete one of the newest KEEP_MIN_DUMPS dumps, whatever
# their age (a host that was off for a month must not lose its last backups).
keep=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'tesla-*.dump' | sort -r | head -n "$KEEP_MIN_DUMPS")
find "$BACKUP_DIR" -maxdepth 1 -type f \
  \( -name 'tesla-*.dump' -o -name 'globals-*.sql' -o -name 'attachments-*.tar.gz' -o -name '*.partial' \) \
  -mtime +"$KEEP_DAYS" -print |
while IFS= read -r f; do
  s=$(basename "$f" | sed -E 's/^[a-z]+-([0-9]{8}T[0-9]{6}Z).*/\1/')
  if printf '%s\n' "$keep" | grep -q -- "tesla-$s.dump"; then
    continue
  fi
  rm -f -- "$f" && log "pruned $(basename "$f")"
done
