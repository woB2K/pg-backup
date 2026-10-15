#!/bin/sh
set -eu
cd "$(dirname "$0")"

export PG_MAJOR="${PG_MAJOR:-16}"

compose() {
  docker compose -p "pg-backup-smoke-$PG_MAJOR" "$@"
}

sql() {
  compose exec -T db psql -U app -d "${2:-app}" -Atc "$1"
}

file() {
  compose run --rm -T backup cat "/data/uploads/$1"
}

cleanup() {
  compose down -v --remove-orphans > /dev/null 2>&1 || true
}
trap cleanup EXIT

compose up -d --wait db
sql 'create table smoke (id int); insert into smoke select generate_series(1, 100)'
compose run --rm -T backup sh -c 'mkdir -p /data/uploads/nested && echo one > /data/uploads/nested/one.txt && echo two > /data/uploads/two.txt'
compose run --rm -T backup restic init

compose up -d --build backup
for _ in $(seq 1 30); do
  compose logs backup | grep -q 'no errors were found' && break
  sleep 5
done
compose logs backup
compose logs backup | grep -q 'no errors were found'
compose stop backup

sql 'delete from smoke where id > 10'
compose run --rm -T backup sh -c 'rm /data/uploads/nested/one.txt && echo changed > /data/uploads/two.txt'

compose run --rm -T backup restore check | tee /dev/stderr | grep -Eq 'smoke +\| +100'
compose run --rm -T backup restore files check | tee /dev/stderr | grep -q '/data/uploads  2 files'
echo app | compose run --rm -T backup restore apply
echo app | compose run --rm -T backup restore files apply

[ "$(sql 'select count(*) from smoke')" = 100 ]
[ "$(sql 'select count(*) from smoke' app_before_restore)" = 10 ]
[ "$(file nested/one.txt)" = one ]
[ "$(file two.txt)" = two ]
echo "backup smoke passed on postgres $PG_MAJOR"
