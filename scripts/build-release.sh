#!/usr/bin/env sh
# Build the release artifacts into dist/.
#
# The version has one home: the row sql/010_install.sql seeds
# into fga.schema_version. This script reads it from there rather
# than keeping a copy that could drift (CLAUDE.md: no version
# copies).
#
# Two shapes, because plain SQL scripts and pg_tle are both
# first-class distribution channels:
# the all-in bundle inlines the vendored cel4postgres release
# so one `psql -f` installs everything on a bare database; the
# engine-only file serves databases that already run the pinned
# cel4postgres. Plain concatenation is safe because every script
# opens and closes its own transaction. Install with
# ON_ERROR_STOP so a failure stops between them:
#
#   psql -v ON_ERROR_STOP=1 -f fga4postgres--<version>.sql

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

rm -rf dist
mkdir -p dist

# Concatenate the named files, each behind a banner naming its
# source, so an error line in a bundle is traceable to a script.
bundle() {
  out=$1
  shift
  for f in "$@"; do
    printf -- '-- ---- %s ----\n\n' "$f"
    cat "$f"
    printf '\n'
  done >"dist/$out"
}

engine=$(ls sql/*.sql)

# shellcheck disable=SC2086
bundle "fga4postgres--$version.sql" "$vendored" $engine
# shellcheck disable=SC2086
bundle "fga4postgres-engine--$version.sql" $engine

(cd dist && sha256sum -- *.sql >SHA256SUMS)

echo "version $version"
ls -l dist
