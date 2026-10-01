#!/usr/bin/env sh
# Install every artifact in dist/ on a bare database of the pinned
# image, in the shape each one promises:
#
# - a plain artifact runs inside a transaction it does not own.
#   Installed between BEGIN and ROLLBACK it must leave no fga or cel
#   schema behind -- one stray COMMIT; would keep them -- and
#   installed with --single-transaction it must answer fga.version();
# - a -tx artifact installs with a bare psql -f;
# - each one installs a second time over itself, because re-running
#   the installer is the upgrade path.
#
# The engine-only files install over the vendored cel4postgres
# bundle, in the same transaction. Run after build-release.sh; used
# by the CI and release workflows.

set -eu

cd "$(dirname "$0")/.."

version=$(sed -n "s/^VALUES ('\([0-9][0-9.]*\)');$/\1/p" \
  sql/010_install.sql)
image=$(sed -n 's/^ *image: \(postgres:[^ ]*\)$/\1/p' compose.yaml)
cel=$(basename "$(ls vendor/cel4postgres--*.sql)")

docker run -d --rm --name smoke \
  -e POSTGRES_DB=fga -e POSTGRES_USER=fga -e POSTGRES_PASSWORD=pw \
  -v "$PWD/dist:/dist:ro" -v "$PWD/vendor:/vendor:ro" \
  "$image" >/dev/null
trap 'docker rm -f smoke >/dev/null' EXIT

# -h 127.0.0.1: over the socket, pg_isready can reach initdb's
# temporary server; only the final one listens on TCP.
for _ in $(seq 60); do
  docker exec smoke pg_isready -h 127.0.0.1 -U fga -d fga -q \
    2>/dev/null && break
  sleep 2
done

sql() {
  docker exec -e PGOPTIONS='-c client_min_messages=warning' \
    smoke psql -h 127.0.0.1 -U fga -d fga -v ON_ERROR_STOP=1 -q "$@"
}

reset() {
  sql -c 'DROP SCHEMA IF EXISTS fga CASCADE' \
    -c 'DROP SCHEMA IF EXISTS cel CASCADE'
}

expect_version() {
  got=$(sql -tAc 'SELECT fga.version()')
  if [ "$got" != "$version" ]; then
    echo "expected $version, got '$got'" >&2
    exit 1
  fi
  reset
}

# $1 names the bundle; the rest are the files installed before it.
smoke() {
  name=$1
  shift
  pre=
  for f in "$@"; do
    pre="$pre -f $f"
  done

  plain="/dist/$name--$version.sql"
  echo "== $plain"
  # shellcheck disable=SC2086
  sql -c 'BEGIN' $pre -f "$plain" -c 'ROLLBACK'
  left=$(sql -tAc "SELECT count(*) FROM pg_namespace
                   WHERE nspname IN ('fga', 'cel')")
  if [ "$left" != 0 ]; then
    echo "$plain committed on its own" >&2
    exit 1
  fi
  # shellcheck disable=SC2086
  sql --single-transaction $pre -f "$plain"
  # shellcheck disable=SC2086
  sql --single-transaction $pre -f "$plain"
  expect_version

  tx="/dist/$name-tx--$version.sql"
  echo "== $tx"
  # shellcheck disable=SC2086
  sql $pre -f "$tx"
  # shellcheck disable=SC2086
  sql $pre -f "$tx"
  expect_version
}

smoke fga4postgres
smoke fga4postgres-engine "/vendor/$cel"
