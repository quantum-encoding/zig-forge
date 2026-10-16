#!/usr/bin/env python3
"""Record the raw byte stream claude's TUI emits, for renderer regression tests.

Spawns `claude` in a real PTY at a fixed 120x40, drives it with a canned
prompt, and saves every byte the program wrote to stdout. The saved stream is
replayed through terminal_mux's C ABI (via a Zig harness) to reproduce the
renderer defects deterministically — no live model needed after capture.
"""
import errno
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time

CLAUDE = "/opt/homebrew/bin/claude"
OUT = sys.argv[1] if len(sys.argv) > 1 else "claude_tui_stream.bin"
ROWS, COLS = 40, 120

def set_winsize(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

def main():
    pid, master = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.environ["COLORTERM"] = "truecolor"
        # A prompt that draws the whole TUI: boxes, spinner icons, wrapped
        # text, the composer — then exits so the capture terminates.
        os.execv(CLAUDE, [CLAUDE, "-p", "say hello and list three colors, then stop"])
    set_winsize(master, ROWS, COLS)

    captured = bytearray()
    deadline = time.time() + 60
    last_data = time.time()
    while time.time() < deadline:
        r, _, _ = select.select([master], [], [], 0.5)
        if master in r:
            try:
                data = os.read(master, 65536)
            except OSError as e:
                if e.errno == errno.EIO:
                    break
                continue
            if not data:
                break
            captured.extend(data)
            last_data = time.time()
        elif time.time() - last_data > 4:
            break  # quiet for 4s → TUI settled / exited

    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)

    with open(OUT, "wb") as f:
        f.write(captured)
    print(f"captured {len(captured)} bytes → {OUT}")

if __name__ == "__main__":
    main()
