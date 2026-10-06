#!/usr/bin/env python3
"""Reproduce: mercat TUI hangs on quit (and on 'e') when the terminal never
answers DSR (ESC [ 5 n / ESC [ 6 n).

vaxis 0.5.1 Loop.stop() writes a Device Status Report request so the blocked
reader thread's read() returns, then thread.join()s with no timeout. A terminal
(or multiplexer / serial console / recording tool) that does not answer DSR
leaves read() blocked forever, so quitting never finishes.

This script plays a "mute terminal": it runs mercat on a pty, drains its
output, never writes any reply, then sends a key and measures how long the
process takes to exit.

usage: dsr_hang.py [--answer] MERCAT_BINARY FILE.md [KEY] [TIMEOUT_SECONDS]
  KEY defaults to 'q' ('ctrl-c' sends ^C). Exit status: 0 = exited in time, 1 = hung (reproduced).
  --answer is the control run: reply to DSR like a normal terminal (then the
  same key exits promptly), proving the unanswered DSR is the cause.
"""
import fcntl
import os
import pty
import struct
import termios
import select
import signal
import sys
import time


ANSWER = False


def answer(fd, chunk):
    if not ANSWER:
        return
    if b"\x1b[5n" in chunk:
        os.write(fd, b"\x1b[0n")
    if b"\x1b[6n" in chunk:
        os.write(fd, b"\x1b[1;1R")


def drain(fd, seconds):
    end = time.monotonic() + seconds
    out = b""
    while time.monotonic() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            answer(fd, chunk)
            out += chunk
    return out


def main():
    global ANSWER
    if len(sys.argv) > 1 and sys.argv[1] == "--answer":
        ANSWER = True
        del sys.argv[1]
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    binary, doc = sys.argv[1], sys.argv[2]
    key_arg = sys.argv[3] if len(sys.argv) > 3 else "q"
    key = b"\x03" if key_arg == "ctrl-c" else key_arg.encode()
    timeout = float(sys.argv[4]) if len(sys.argv) > 4 else 5.0

    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.environ.pop("TMUX", None)
        os.execv(binary, [binary, "-t", doc])

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
    # Startup: vaxis.queryTerminal waits up to 1 s for replies we never send.
    startup = drain(fd, 2.0)
    print(f"startup output: {len(startup)} bytes ({'answering DSR' if ANSWER else 'no replies sent'})")

    sent_at = time.monotonic()
    os.write(fd, key)
    exited = False
    while time.monotonic() - sent_at < timeout:
        drain(fd, 0.1)
        done, _ = os.waitpid(pid, os.WNOHANG)
        if done == pid:
            exited = True
            break
    elapsed = time.monotonic() - sent_at

    if exited:
        print(f"OK: exited {elapsed:.2f}s after {key!r}")
        return 0
    print(f"HUNG: still running {elapsed:.1f}s after {key!r} (terminal never answered DSR)")
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
    return 1


if __name__ == "__main__":
    sys.exit(main())
