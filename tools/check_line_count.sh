#!/usr/bin/env bash
# Implementation modules are capped at 500 code lines; test files are not capped.
#
# A code line is a line that is not blank and whose first non-space characters
# are not `//`, so doc comments and blank lines are free. The cap applies to
# every Zig source under src/ except `*_test*.zig` files (tests are extracted
# into sibling files to keep their module small; test length is not tracked).
# The mermaid_v2 lint (tools/lint_imports.zig, `zig build lint`) applies the
# same rule, counted the same way, to its tree.
#
# A module over the cap fails CI unless it is grandfathered below. The
# grandfather list is the set of files that already exceeded the limit when
# the check was introduced (plus pure-data tables); it must only ever shrink.
# Do NOT add new entries — split the file instead.
set -euo pipefail

limit=500

grandfathered=(
  src/core/mermaid/parser.zig
  src/core/mermaid/types.zig
  src/core/markdown/parser.zig
  src/core/markdown/render/blocks.zig
  src/core/markdown/render/frontmatter.zig
  src/core/markdown/preprocess.zig
  src/core/mermaid/sequence/render.zig
  src/export/png_encode.zig
  src/export/png.zig
  src/export/glyph_sheet.zig
  src/export/layout.zig
  src/cli/args.zig
  src/tui/app.zig
  src/core/theme/presets.zig # pure preset color-table data
)

is_grandfathered() {
  local f=$1
  for g in "${grandfathered[@]}"; do
    [ "$f" = "$g" ] && return 0
  done
  return 1
}

# Count lines that are neither blank nor `//`-prefixed after leading whitespace,
# exactly as tools/lint_imports.zig counts them.
code_lines() {
  awk '{ t = $0; sub(/^[ \t\r]+/, "", t) } t != "" && t !~ /^\/\// { c++ } END { print c + 0 }' "$1"
}

fail=0
while IFS= read -r f; do
  n=$(code_lines "$f")
  if [ "$n" -gt "$limit" ] && ! is_grandfathered "$f"; then
    echo "line-count: $f has $n code lines (limit $limit) — split it or (last resort) grandfather it"
    fail=1
  fi
done < <(find src -name '*.zig' -not -name '*_test*.zig' | sort)

if [ "$fail" -eq 0 ]; then
  echo "line-count: OK (all non-grandfathered implementation modules <= $limit code lines)"
fi
exit $fail
