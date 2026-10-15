#!/usr/bin/env bash
# Every copy of the release version must agree; with an argument (a tag like v0.3.2), so must it.
set -euo pipefail
cd "$(dirname "$0")/.."

zon=$(sed -n 's/^ *\.version = "\([^"]*\)",.*/\1/p' build.zig.zon)
status=0

check() {
  if [ "$2" != "$zon" ]; then
    echo "version mismatch: $1 has '$2', build.zig.zon has '$zon'" >&2
    status=1
  fi
}

check build.zig "$(sed -n 's/.*addOption(\[\]const u8, "version", "\([^"]*\)").*/\1/p' build.zig)"
check mods/mercat/.claude-plugin/plugin.json "$(sed -n 's/^ *"version": "\([^"]*\)".*/\1/p' mods/mercat/.claude-plugin/plugin.json)"
check mods/mercat/hooks/mercat.ts "$(sed -n "s/^export const MOD_VERSION = '\([^']*\)'.*/\1/p" mods/mercat/hooks/mercat.ts)"
if [ $# -gt 0 ]; then check tag "${1#v}"; fi

if [ $status -eq 0 ]; then echo "versions agree: $zon"; fi
exit $status
