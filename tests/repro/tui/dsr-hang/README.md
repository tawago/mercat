# TUI hangs on quit when the terminal never answers DSR

Status: **open**, tracked in
[#87](https://github.com/tawago/mercat/issues/87).

When the terminal never answers a Device Status Report query
(`ESC [5n` / `ESC [6n`), quitting the TUI (`q`, `Ctrl-C`) or starting the
editor (`e`) hangs. vaxis 0.5.1 `Loop.stop()` writes a DSR query so its
blocked reader thread's `read()` returns, then joins that thread with no
timeout. A terminal, multiplexer, serial console or recording tool that does
not reply leaves the reader blocked forever.

## Files

| File | Purpose |
| --- | --- |
| `dsr_hang.py` | Runs mercat on a pty that never replies ("mute terminal"), sends one key and times the exit. `--answer` is the control: it replies to DSR like a normal terminal. Exit status 1 means it hung. |
| `run_all.sh` | Runs the four scenarios below against one binary, with an empty config and `EDITOR=true`. |
| `sample.md` | The document opened in each run. |

## Reproduce

```sh
zig build -Doptimize=ReleaseSafe
bash tests/repro/tui/dsr-hang/run_all.sh "$PWD/zig-out/bin/mercat"
```

Needs Linux or macOS and `python3`. Each scenario waits at most 5 seconds and
kills mercat if it is still running.

## Current behavior

```
== 1. quit with q, terminal never answers DSR
HUNG: still running 5.0s after b'q' (terminal never answered DSR)
== 2. quit with Ctrl-C, terminal never answers DSR
HUNG: still running 5.0s after b'\x03' (terminal never answered DSR)
== 3. edit with e (stops the input loop first)
HUNG: still running 5.0s after b'e' (terminal never answered DSR)
== 4. control: terminal answers DSR, quit with q
OK: exited 0.00s after b'q'
```

Once #87 is fixed, scenarios 1-3 should print `OK` like the control.
