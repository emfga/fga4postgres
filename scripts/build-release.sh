#!/usr/bin/env sh
# Build the release artifacts into dist/.
#
# The version has one home: the row sql/010_install.sql seeds
# into fga.schema_version. This script reads it from there rather
# than keeping a copy that could drift (CLAUDE.md: no version
# copies).
#
# Two bundles, because plain SQL scripts and pg_tle are both
# first-class distribution channels: the all-in bundle inlines the
# vendored cel4postgres release so one file installs everything on a
# bare database; the engine-only file serves databases that already
# run the pinned cel4postgres.
#
# Each comes in two shapes. The plain file carries no transaction
# control, so it runs inside whatever transaction the caller already
# holds -- a migration tool's, pg_tle's CREATE EXTENSION, or psql's
# --single-transaction:
#
#   psql -v ON_ERROR_STOP=1 -1 -f fga4postgres--<version>.sql
#
# The -tx file is the same bundle between exactly one BEGIN; and one
# COMMIT;, for a plain `psql -f` that should still be all or nothing.

set -eu

cd "$(dirname "$0")/.."

version=$(sed -n "s/^VALUES ('\([0-9][0-9.]*\)');$/\1/p" \
  sql/010_install.sql)
case $version in
  *.*.*) ;;
  *)
    echo "could not read the version from sql/010_install.sql" >&2
    exit 1
    ;;
esac

vendored=$(ls vendor/cel4postgres--*.sql)
case $(printf '%s\n' "$vendored" | wc -l) in
  1) ;;
  *)
    echo "expected exactly one vendored cel4postgres bundle" >&2
    exit 1
    ;;
esac

# Neither the sources nor the vendored cel4postgres bundle may open
# or close a transaction; that is what lets the plain artifacts run
# inside a caller's transaction. A BEGIN; or COMMIT; line would
# silently commit that transaction halfway, so refuse to build
# rather than ship it.
# shellcheck disable=SC2086
if grep -n -x -e 'BEGIN;' -e 'COMMIT;' "$vendored" sql/*.sql; then
  echo "install scripts must not open or close transactions" >&2
  exit 1
fi

rm -rf dist
mkdir -p dist

# Concatenate the named files, each behind a banner naming its
# source, so an error line in a bundle is traceable to a script.
# Writes <name>--<version>.sql and its <name>-tx--<version>.sql
# twin.
bundle() {
  name=$1
  shift
  for f in "$@"; do
    printf -- '-- ---- %s ----\n\n' "$f"
    cat "$f"
    printf '\n'
  done >"dist/$name--$version.sql"
  {
    printf 'BEGIN;\n\n'
    cat "dist/$name--$version.sql"
    printf 'COMMIT;\n'
  } >"dist/$name-tx--$version.sql"
}

engine=$(ls sql/*.sql)

# shellcheck disable=SC2086
bundle fga4postgres "$vendored" $engine
# shellcheck disable=SC2086
bundle fga4postgres-engine $engine

(cd dist && sha256sum -- *.sql >SHA256SUMS)

echo "version $version"
ls -l dist
