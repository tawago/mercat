#!/usr/bin/env bash
# Local preview: rebuilds mercat.wasm from the current tree, then serves site/ with caching off.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
bin="$root/site/play/bin"

if [ -f "$bin/mermaid-ascii.wasm" ]; then
  (cd "$root" && zig build wasm)
  cp "$root/zig-out/web/mercat.wasm" "$bin/mercat.wasm"
else
  "$root/site/play/build.sh"
fi

cd "$root/site"
exec python3 -c '
import sys, http.server as h
class H(h.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()
h.test(H, port=int(sys.argv[1]))
' "${1:-8000}"
