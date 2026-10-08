#!/usr/bin/env bash
# Implementation modules are capped at 1000 code lines; test files are not capped.
#
# A code line is a line that is not blank and whose first non-space characters
# are not `//`, so doc comments and blank lines are free. The cap applies to
# every Zig source under src/ except `*_test*.zig` files (tests are extracted
# into sibling files to keep their module small; test length is not tracked).
# This script is the only implementation of the cap.
set -euo pipefail

limit=1000

# Count lines that are neither blank nor `//`-prefixed after leading whitespace.
code_lines() {
  awk '{ t = $0; sub(/^[ \t\r]+/, "", t) } t != "" && t !~ /^\/\// { c++ } END { print c + 0 }' "$1"
}

fail=0
while IFS= read -r f; do
  n=$(code_lines "$f")
  if [ "$n" -gt "$limit" ]; then
    echo "line-count: $f has $n code lines (limit $limit) — split it"
    fail=1
  fi
done < <(find src -name '*.zig' -not -name '*_test*.zig' | sort)

if [ "$fail" -eq 0 ]; then
  echo "line-count: OK (all implementation modules <= $limit code lines)"
fi
exit $fail
