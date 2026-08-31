#!/bin/sh
# Runs once per initdb (PGDATA is a tmpfs, so once per container
# start): installs the vendored cel4postgres bundle first, then every
# fga4postgres script, in name order. This exists because initdb runs
# only a flat directory and a single-file bind mount cannot be layered
# over a read-only directory mount -- so sql/ and vendor/ are mounted
# at their own paths and this script sequences them.
set -eu

for f in /vendor/cel4postgres--*.sql /sql/*.sql; do
  echo "fga4postgres initdb: applying $f"
  psql -v ON_ERROR_STOP=1 \
    --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f "$f"
done
