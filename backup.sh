#!/bin/sh
set -eu

name="${BACKUP_NAME:-$PGDATABASE}"

ping() {
  [ -n "${BACKUP_PING_URL:-}" ] || return 0
  curl -fsS -m 10 --retry 3 -o /dev/null "$BACKUP_PING_URL$1" || true
}

database() {
  restic backup --host "$name" --stdin-filename "$name.dump" --stdin-from-command -- pg_dump --format=custom --compress=0
}

files() {
  [ -n "${BACKUP_PATHS:-}" ] || return 0
  # shellcheck disable=SC2086
  restic backup --host "$name" $BACKUP_PATHS
}

snapshot() {
  database \
    && files \
    && restic forget --host "$name" --prune \
      --keep-daily "${BACKUP_KEEP_DAILY:-7}" \
      --keep-weekly "${BACKUP_KEEP_WEEKLY:-4}" \
      --keep-monthly "${BACKUP_KEEP_MONTHLY:-6}" \
    && restic check
}

ping /start
if snapshot; then
  ping ""
else
  ping /fail
  exit 1
fi
