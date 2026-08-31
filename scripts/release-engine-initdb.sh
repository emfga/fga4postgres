#!/bin/sh
# Release-smoke initdb sequencer: install the vendored cel4postgres
# bundle first, then the engine-only release artifact — the layered
# install the engine-only file is for. Used by the release
# workflow's smoke job only.
set -eu

for f in /vendor/cel4postgres--*.sql /engine.sql; do
  echo "release smoke: applying $f"
  psql -v ON_ERROR_STOP=1 \
    --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f "$f"
done
