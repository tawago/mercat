#!/usr/bin/env bash

set -euo pipefail

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
internal_dir="${MDV_INTERNAL_TESTS_DIR:-$repo_root/../mdv-internal-tests}"

if [ ! -d "$internal_dir" ]; then
    printf 'Internal test checkout not found: %s\n' "$internal_dir" >&2
    printf 'Set MDV_INTERNAL_TESTS_DIR or clone the internal repo next to this one.\n' >&2
    exit 1
fi

exec zig build -Dinternal-tests-dir="$internal_dir" test-all --summary all
