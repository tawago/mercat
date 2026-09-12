# Unicode data pin

The files in `17.0.0/` are unmodified upstream Unicode 17.0.0 data and test
files. `tools/unicode/generate.zig` is the machine-readable manifest: it pins
each source URL and SHA-256 digest. `tools/unicode/fetch.sh` is the only
networked update path; normal builds and `zig build unicode-check` are offline.

All files are distributed under `17.0.0/LICENSE.txt` (Unicode License v3).
