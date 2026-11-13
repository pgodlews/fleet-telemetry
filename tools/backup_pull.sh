#!/usr/bin/env bash
#
# backup_pull.sh - pull the Tesla telemetry backups from the production host
# onto this machine, and optionally mirror them to a locally mounted NAS share.
# Meant for cron on the receiving host, e.g.:
#
#   15 6 * * *  SRC=backup@prod.example.net:/u01/backups/tesla/ DEST=/srv/backups/tesla \
#               SSH_KEY=/home/backup/.ssh/tesla_backup_pull \
#               MIRROR_DIR=/mnt/nas/backups/tesla \
#               /opt/fleet-telemetry/tools/backup_pull.sh
#
# The production side (tools/backup.sh) writes tesla-<stamp>.dump,
# globals-<stamp>.sql and attachments-<stamp>.tar.gz; in-progress files end in
# .partial and are never pulled.
#
# Environment (no defaults name a real host; nothing secret lives here):
#   SRC              required  user@host:/path/ of the backup directory on the source
#   DEST             required  local directory to pull into
#   SSH_KEY          required  private key dedicated to this pull. On the source,
#                              restrict it in authorized_keys to read-only rsync of
#                              the backup directory, e.g.
#                                command="rrsync -ro /u01/backups/tesla",restrict ssh-ed25519 AAAA...
#                              (with rrsync -ro, SRC's path is relative to that dir,
#                              so SRC=backup@host:/ works too)
#   KEEP_DAYS        local retention in days, default 30
#   MAX_AGE_H        fail if the newest local dump is older, default 48
#   MIRROR_DIR       optional; mirror DEST here after the pull (e.g. a NAS share)
#   MIRROR_MOUNT     optional; the mount point MIRROR_DIR must live on. Without it
#                    the script requires MIRROR_DIR or one of its parents (other
#                    than /) to be a mount point
#   MIRROR_KEEP_DAYS retention in the mirror, default 90
#
# Retention never deletes the newest 3 dumps in either place. rsync never
# deletes anything: not on the source, not locally, not in the mirror.
#
# Exit status: 0 on success; non-zero with one "backup_pull: ..." line on
# stderr if the pull fails, the newest local dump is too old, or (after the
# pull has completed) the mirror step fails.

set -euo pipefail

KEEP_DAYS=${KEEP_DAYS:-30}
MAX_AGE_H=${MAX_AGE_H:-48}
MIRROR_DIR=${MIRROR_DIR:-}
MIRROR_MOUNT=${MIRROR_MOUNT:-}
MIRROR_KEEP_DAYS=${MIRROR_KEEP_DAYS:-90}
KEEP_MIN_DUMPS=3

die() { echo "backup_pull: $*" >&2; exit 1; }

: "${SRC:?backup_pull: set SRC=user@host:/path/}"
: "${DEST:?backup_pull: set DEST=/local/dir}"
: "${SSH_KEY:?backup_pull: set SSH_KEY=/path/to/dedicated/key}"
[ -r "$SSH_KEY" ] || die "SSH_KEY $SSH_KEY is not readable"
for n in "$KEEP_DAYS" "$MAX_AGE_H" "$MIRROR_KEEP_DAYS"; do
  case "$n" in ''|*[!0-9]*) die "KEEP_DAYS, MAX_AGE_H and MIRROR_KEEP_DAYS must be whole numbers" ;; esac
done

mkdir -p "$DEST"

# prune <dir> <days>: delete backup files older than <days>, except every file
# belonging to one of the newest KEEP_MIN_DUMPS dumps.
prune() {
  local dir=$1 days=$2 keep f stamp
  keep=$(find "$dir" -maxdepth 1 -type f -name 'tesla-*.dump' -printf '%f\n' | sort -r | head -n "$KEEP_MIN_DUMPS")
  find "$dir" -maxdepth 1 -type f \
    \( -name 'tesla-*.dump' -o -name 'globals-*.sql' -o -name 'attachments-*.tar.gz' \) \
    -mtime +"$days" -print |
  while IFS= read -r f; do
    stamp=$(basename "$f" | sed -E 's/^[a-z]+-([0-9]{8}T[0-9]{6}Z).*/\1/')
    if printf '%s\n' "$keep" | grep -qx -- "tesla-$stamp.dump"; then
      continue
    fi
    rm -f -- "$f"
  done
}

# newest_age_h <dir>: age in hours of the newest dump, or empty if none.
newest_age_h() {
  local t
  t=$(find "$1" -maxdepth 1 -type f -name 'tesla-*.dump' -printf '%T@\n' | sort -n | tail -1)
  [ -n "$t" ] && echo $(( ( $(date +%s) - ${t%.*} ) / 3600 ))
}

# ---- pull ------------------------------------------------------------------
# No --delete / --remove-source-files: nothing is ever deleted by rsync.
# --ignore-existing: a completed backup never changes, so do not re-send it.
if ! rsync -a --ignore-existing --partial-dir=.rsync-partial \
      --include='tesla-*.dump' --include='globals-*.sql' --include='attachments-*.tar.gz' \
      --exclude='*' \
      -e "ssh -i $SSH_KEY -o IdentitiesOnly=yes -o BatchMode=yes" \
      "$SRC" "$DEST/"; then
  die "rsync from $SRC failed"
fi

prune "$DEST" "$KEEP_DAYS"

age=$(newest_age_h "$DEST" || true)
[ -n "$age" ] || die "no tesla-*.dump in $DEST after pull"
[ "$age" -le "$MAX_AGE_H" ] || die "newest dump in $DEST is ${age}h old (limit ${MAX_AGE_H}h)"

# ---- mirror ----------------------------------------------------------------
# Runs only after a successful pull. An unmounted NFS/SMB share leaves an empty
# directory on the local disk; copying into it would silently fill that disk,
# so the mount is checked first.
[ -z "$MIRROR_DIR" ] && exit 0

[ -d "$MIRROR_DIR" ] || die "mirror: MIRROR_DIR $MIRROR_DIR does not exist (share not mounted?)"
if [ -n "$MIRROR_MOUNT" ]; then
  mountpoint -q "$MIRROR_MOUNT" || die "mirror: $MIRROR_MOUNT is not mounted"
  case "$(cd "$MIRROR_DIR" && pwd -P)/" in
    "$(cd "$MIRROR_MOUNT" && pwd -P)"/*) ;;
    *) die "mirror: $MIRROR_DIR is not under $MIRROR_MOUNT" ;;
  esac
else
  p=$(cd "$MIRROR_DIR" && pwd -P)
  mounted=0
  while [ "$p" != "/" ]; do
    if mountpoint -q "$p"; then mounted=1; break; fi
    p=$(dirname "$p")
  done
  [ "$mounted" -eq 1 ] || die "mirror: $MIRROR_DIR is not on a mounted filesystem (share not mounted?)"
fi
[ -w "$MIRROR_DIR" ] || die "mirror: $MIRROR_DIR is not writable"

rsync -a --ignore-existing --exclude=.rsync-partial "$DEST/" "$MIRROR_DIR/" || die "mirror: rsync to $MIRROR_DIR failed"
prune "$MIRROR_DIR" "$MIRROR_KEEP_DAYS"
