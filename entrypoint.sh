#!/bin/sh
set -eu

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

: "${PGHOST:?set PGHOST}" "${PGDATABASE:?set PGDATABASE}" "${RESTIC_REPOSITORY:?set RESTIC_REPOSITORY}" "${RESTIC_PASSWORD:?set RESTIC_PASSWORD}"

umask 077
export -p > /run/backup.env
echo "${BACKUP_SCHEDULE:-0 1 * * *} . /run/backup.env && backup > /proc/1/fd/1 2>&1" > /etc/crontabs/root
exec crond -f -d 8
