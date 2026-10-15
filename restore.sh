#!/bin/sh
set -eu

name="${BACKUP_NAME:-$PGDATABASE}"

usage() {
  echo 'usage: restore check|apply [snapshot]' >&2
  echo '       restore files check|apply [snapshot]' >&2
  exit 2
}

confirm() {
  printf '%s Type "%s" to confirm: ' "$1" "$2"
  read -r answer
  if [ "$answer" != "$2" ]; then
    echo 'Aborted' >&2
    exit 1
  fi
}

kind=database
if [ "${1:-}" = files ]; then
  kind=files
  shift
fi
mode="${1:-}"
snapshot="${2:-latest}"

case "$mode" in
  check | apply) ;;
  *) usage ;;
esac

load() {
  dropdb --if-exists "$1"
  createdb "$1"
  pg_restore --no-owner --single-transaction --dbname="$1" "$dump"
}

swap() {
  psql -d postgres -q -v ON_ERROR_STOP=1 --single-transaction \
    -v current="$PGDATABASE" -v restored="${PGDATABASE}_restore" -v previous="${PGDATABASE}_before_restore" <<'SQL'
ALTER DATABASE :"current" RENAME TO :"previous";
ALTER DATABASE :"restored" RENAME TO :"current";
SQL
}

database_check() {
  load "${PGDATABASE}_check"
  psql -d "${PGDATABASE}_check" -c "
    select table_schema || '.' || table_name as table,
      (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text::int as rows
    from information_schema.tables
    where table_schema not in ('pg_catalog', 'information_schema') and table_type = 'BASE TABLE'
    order by table_schema, table_name"
  dropdb "${PGDATABASE}_check"
  echo "Snapshot $snapshot restores cleanly"
}

database_apply() {
  confirm "Replace database \"$PGDATABASE\" with snapshot $snapshot?" "$PGDATABASE"
  load "${PGDATABASE}_restore"
  dropdb --if-exists "${PGDATABASE}_before_restore"
  if ! swap; then
    echo "Swap failed, snapshot is waiting in ${PGDATABASE}_restore. Stop the app first" >&2
    exit 1
  fi
  echo "Restored snapshot $snapshot. Previous database kept as ${PGDATABASE}_before_restore"
}

files_check() {
  target="$(mktemp -d)"
  trap 'rm -rf "$target"' EXIT
  restic restore "$snapshot" --host "$name" "$@" --target "$target"
  for path in $BACKUP_PATHS; do
    printf '%s  %s files  %s\n' "$path" "$(find "$target$path" -type f | wc -l | tr -d ' ')" "$(du -sh "$target$path" | cut -f1)"
  done
  echo "Snapshot $snapshot restores cleanly"
}

files_apply() {
  confirm "Restore $BACKUP_PATHS from snapshot $snapshot over the current files?" "$name"
  restic restore "$snapshot" --host "$name" "$@" --target /
  echo "Restored $BACKUP_PATHS from snapshot $snapshot"
}

if [ "$kind" = database ]; then
  dump="$(mktemp)"
  trap 'rm -f "$dump"' EXIT
  restic dump --host "$name" --path "/$name.dump" "$snapshot" "/$name.dump" > "$dump"
  "database_$mode"
  exit 0
fi

if [ -z "${BACKUP_PATHS:-}" ]; then
  echo 'BACKUP_PATHS is empty, there are no files to restore' >&2
  exit 2
fi

set --
for path in $BACKUP_PATHS; do
  set -- "$@" --path "$path"
done
"files_$mode" "$@"
