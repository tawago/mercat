#!/usr/bin/env bash
# Runs every DSR-hang scenario against one mercat binary.
# usage: run_all.sh /path/to/mercat [doc.md]
# Expect today: the three "mute terminal" cases print HUNG, the control prints OK.
here=$(cd "$(dirname "$0")" && pwd)
bin=$1
doc=${2:-$here/sample.md}
[ -x "$bin" ] || { echo "usage: $0 /path/to/mercat [doc.md]"; exit 2; }
# Keep the user's real config (and its editor) out of the 'e' case.
XDG_CONFIG_HOME=$(mktemp -d)
export XDG_CONFIG_HOME
trap 'rm -rf "$XDG_CONFIG_HOME"' EXIT
export EDITOR=true VISUAL=
echo "== 1. quit with q, terminal never answers DSR";      python3 -I "$here/dsr_hang.py" "$bin" "$doc" q 5
echo "== 2. quit with Ctrl-C, terminal never answers DSR"; python3 -I "$here/dsr_hang.py" "$bin" "$doc" ctrl-c 5
echo "== 3. edit with e (stops the input loop first)";    python3 -I "$here/dsr_hang.py" "$bin" "$doc" e 5
echo "== 4. control: terminal answers DSR, quit with q";   python3 -I "$here/dsr_hang.py" --answer "$bin" "$doc" q 5
