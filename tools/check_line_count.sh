#!/usr/bin/env bash
# Enforce a soft 500-line-per-file ceiling on Zig sources under src/.
#
# The ceiling applies to production modules. `*_test.zig` sibling files are
# exempt (tests are extracted there to keep their module small; test length is
# tracked separately). A production file over the limit fails CI unless it is
# grandfathered below. The grandfather list is the set of files that already
# exceeded the limit when the check was introduced (plus pure-data tables); it
# must only ever shrink. Do NOT add new entries — split the file instead.
set -euo pipefail

limit=500

grandfathered=(
  src/core/mermaid/parser.zig
  src/core/mermaid/types.zig
  src/core/markdown.zig
  src/core/render/blocks.zig
  src/core/render/frontmatter.zig
  src/core/preprocess.zig
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

fail=0
while IFS= read -r f; do
  n=$(wc -l < "$f")
  if [ "$n" -gt "$limit" ] && ! is_grandfathered "$f"; then
    echo "line-count: $f has $n lines (limit $limit) — split it or (last resort) grandfather it"
    fail=1
  fi
done < <(find src -name '*.zig' -not -name '*_test.zig' | sort)

if [ "$fail" -eq 0 ]; then
  echo "line-count: OK (all non-grandfathered Zig files <= $limit lines)"
fi
exit $fail
