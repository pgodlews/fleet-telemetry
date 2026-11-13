#!/usr/bin/env bash
#
# Ordered, fail-fast migration runner.
#
# Runs as a docker-entrypoint-initdb.d script on a fresh volume, and is also
# invoked by `make migrate` against an existing database. Migrations are
# applied in the order given by sql/migrations.txt (filename order is wrong —
# see the header of that file), each with ON_ERROR_STOP so a broken migration
# aborts the run instead of leaving a half-built schema behind.
#
# Applied files are recorded in the schema_migrations table and skipped on
# subsequent runs. Set FORCE=1 to re-apply everything regardless (all
# migrations in this repo are written to be idempotent).
#
# Not run with --single-transaction: TimescaleDB refuses to create continuous
# aggregates inside a transaction block. Migrations that need atomicity carry
# their own BEGIN/COMMIT (see 027).

set -euo pipefail

SQL_DIR="${SQL_DIR:-/sql}"
MANIFEST="${MANIFEST:-$SQL_DIR/migrations.txt}"
DB_USER="${POSTGRES_USER:-postgres}"
DB_NAME="${POSTGRES_DB:-tesla}"
FORCE="${FORCE:-0}"

psql_run() {
  psql -v ON_ERROR_STOP=1 --no-psqlrc -U "$DB_USER" -d "$DB_NAME" "$@"
}

if [ ! -f "$MANIFEST" ]; then
  echo "migrate: manifest not found at $MANIFEST" >&2
  exit 1
fi

psql_run -q -c "
  CREATE TABLE IF NOT EXISTS schema_migrations (
    filename    text PRIMARY KEY,
    applied_at  timestamptz NOT NULL DEFAULT now()
  );"

applied=0
skipped=0

while IFS= read -r line; do
  # strip comments and surrounding whitespace
  file="${line%%#*}"
  file="$(echo "$file" | xargs || true)"
  [ -z "$file" ] && continue

  path="$SQL_DIR/$file"
  if [ ! -f "$path" ]; then
    echo "migrate: listed in manifest but missing: $file" >&2
    exit 1
  fi

  if [ "$FORCE" != "1" ]; then
    already="$(psql_run -tAc "SELECT 1 FROM schema_migrations WHERE filename = '$file'")"
    if [ "$already" = "1" ]; then
      skipped=$((skipped + 1))
      continue
    fi
  fi

  echo ">>> $file"
  psql_run -f "$path"
  psql_run -q -c "INSERT INTO schema_migrations (filename) VALUES ('$file')
                  ON CONFLICT (filename) DO UPDATE SET applied_at = now();"
  applied=$((applied + 1))
done < "$MANIFEST"

echo "migrate: $applied applied, $skipped already up to date"
