#!/usr/bin/env bash
# Builds the playground's renderers into site/play/bin/: mercat (zig) and mermaid-ascii (go, pinned in go.mod).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
bin="$root/site/play/bin"
mkdir -p "$bin"

(cd "$root" && zig build wasm)
cp "$root/zig-out/web/mercat.wasm" "$bin/mercat.wasm"

(cd "$root/site/play/mermaid-ascii" && GOOS=js GOARCH=wasm go build -trimpath -ldflags="-s -w" -o "$bin/mermaid-ascii.wasm" .)
cp "$(go env GOROOT)/lib/wasm/wasm_exec.js" "$bin/wasm_exec.js"
# mermaid-ascii is MIT: its license travels with the copy we serve
(cd "$root/site/play/mermaid-ascii" && cp "$(go list -m -f '{{.Dir}}' github.com/AlexanderGrooff/mermaid-ascii)/LICENSE" "$bin/mermaid-ascii-LICENSE.txt")
