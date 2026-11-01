#!/usr/bin/env bash
# Prints the CHANGELOG.md section of a version; first renames [Unreleased] to it when it has none.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1#v}"

if ! grep -qxF "## [$version]" CHANGELOG.md; then
  awk -v v="$version" '!done && $0 == "## [Unreleased]" { print; print ""; print "## [" v "]"; done = 1; next } { print }' \
    CHANGELOG.md > CHANGELOG.md.tmp
  mv CHANGELOG.md.tmp CHANGELOG.md
fi

notes=$(awk -v h="## [$version]" '$0 == h { on = 1; next } on && /^## \[/ { exit } on { print }' CHANGELOG.md \
  | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')
if [ -z "$notes" ]; then
  echo "CHANGELOG.md has no notes for $version" >&2
  exit 1
fi
printf '%s\n' "$notes"
