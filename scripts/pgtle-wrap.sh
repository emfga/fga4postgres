#!/usr/bin/env sh
# Wrap release artifacts into a pg_tle registration script, so the
# flagship channel (CREATE EXTENSION via pg_tle) can be validated
# against the exact files a release publishes. Validation-only:
# the output is generated where needed, never published.
#
#   pgtle-wrap.sh <extname> <version> <artifact.sql>... > out.sql
#
# The artifacts run unchanged except for one transformation: their
# top-level BEGIN;/COMMIT; lines are dropped, because a pg_tle
# script executes inside CREATE EXTENSION's own transaction, where
# transaction control is not allowed.

set -eu

name=$1
version=$2
shift 2

tag='_fga_pgtle_'
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

cat -- "$@" | grep -v -x -e 'BEGIN;' -e 'COMMIT;' >"$tmp"

# The bundle becomes one dollar-quoted literal; the quoting breaks
# if its tag ever appears in the content, so refuse instead of
# emitting a script that fails somewhere deep in pg_tle.
if grep -qF "\$$tag\$" "$tmp"; then
  echo "dollar-quote tag \$$tag\$ appears in the input" >&2
  exit 1
fi

printf "SELECT pgtle.install_extension(\n"
printf "  '%s',\n  '%s',\n  'OpenFGA natively in PostgreSQL',\n" \
  "$name" "$version"
printf '$%s$\n' "$tag"
cat "$tmp"
printf '$%s$\n);\n' "$tag"
