#!/usr/bin/env python3
"""End-to-end QA harness for the standalone terminal_mux binary.

Run:  python3 tests/mux_qa.py [path-to-tmux-binary]
      (default: ../zig-out/bin/tmux relative to this file)

Asserts two invariants a screenshot-level regression would violate:

1. NO HOST SCROLL — models the host terminal's cursor with xterm's
   deferred-wrap semantics; any printable that would wrap-scroll from the
   bottom row (or a raw LF there) fails. This is the exact defect behind the
   2026-07-16 "stacked green status bars" bug: a stale renderer cursor-tracker
   suppressed CUPs, printables landed bottom-right pending-wrap, and the host
   screen scrolled every frame.

2. BACKGROUND PANES DRAIN — after Ctrl-b % the new pane runs a large `seq`
   while focus returns to the first pane. If the event loop only drains the
   focused pane (the pre-fix behavior), the background shell blocks on a full
   PTY buffer and its marker file never appears.

Covers along the way: startup, 2500+ streamed lines, wide chars, a mid-run
SIGWINCH resize, split + spawn, pane focus cycling, new window + switching.
"""
import errno
import fcntl
import os
import re
import signal
import struct
import sys
import tempfile
import termios
import time
import unicodedata

MUX = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "zig-out", "bin", "tmux")

class HostScreen:
    """Minimal host-terminal cursor model (deferred wrap, CUP, CR/LF)."""
    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.row = self.col = 0
        self.pending_wrap = False
        self.scrolls = []

    def resize(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.row = min(self.row, rows - 1)
        self.col = min(self.col, cols - 1)
        self.pending_wrap = False

    def cup(self, row, col):
        self.row = min(max(row, 0), self.rows - 1)
        self.col = min(max(col, 0), self.cols - 1)
        self.pending_wrap = False

    def printable(self, width):
        if self.pending_wrap:
            self.pending_wrap = False
            self.col = 0
            if self.row == self.rows - 1:
                self.scrolls.append(("wrap-scroll", self.row))
            else:
                self.row += 1
        self.col += width
        if self.col >= self.cols:
            self.col = self.cols - 1
            self.pending_wrap = True

    def linefeed(self):
        if self.row == self.rows - 1:
            self.scrolls.append(("lf-scroll", self.col))
        else:
            self.row += 1

CSI = re.compile(rb"\x1b\[([0-9;?]*)([A-Za-z@`~])")
OSC = re.compile(rb"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
# A sequence still in progress at the end of a read chunk. Without carrying it
# to the next chunk, a split "ESC[30;1" + "H" is mis-parsed: the ESC is skipped
# and "0;1H" is counted as printables — phantom wrap-scrolls under load.
PARTIAL = re.compile(rb"(?:\x1b|\x1b\[[0-9;?]*|\x1b\][^\x07\x1b]*)$")

def feed(screen, text):
    text = getattr(screen, "carry", b"") + text
    screen.carry = b""
    m = PARTIAL.search(text)
    if m:
        screen.carry = text[m.start():]
        text = text[:m.start()]
    i = 0
    while i < len(text):
        b = text[i]
        if b == 0x1B:
            m = CSI.match(text, i)
            if m:
                params, final = m.group(1).decode(), m.group(2).decode()
                if final in ("H", "f"):
                    parts = [p for p in params.split(";") if p]
                    r = int(parts[0]) - 1 if len(parts) > 0 else 0
                    c = int(parts[1]) - 1 if len(parts) > 1 else 0
                    screen.cup(r, c)
                i = m.end()
                continue
            m = OSC.match(text, i)
            if m:
                i = m.end()
                continue
            i += 2 if i + 1 < len(text) else 1
            continue
        if b == 0x0A:
            screen.linefeed(); i += 1; continue
        if b == 0x0D:
            screen.col = 0; screen.pending_wrap = False; i += 1; continue
        if b < 0x20 or b == 0x7F:
            i += 1; continue
        n = 1
        if b >= 0xF0: n = 4
        elif b >= 0xE0: n = 3
        elif b >= 0xC0: n = 2
        if i + n > len(text):               # multi-byte char split across reads
            screen.carry = text[i:] + screen.carry
            break
        ch = text[i:i+n].decode("utf-8", "replace")
        w = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        screen.printable(w)
        i += n

def set_winsize(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

def spawn_mux(rows, cols):
    master, slave = os.openpty()
    set_winsize(slave, rows, cols)   # sized BEFORE the mux reads it
    pid = os.fork()
    if pid == 0:
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        os.dup2(slave, 0); os.dup2(slave, 1); os.dup2(slave, 2)
        os.close(master); os.close(slave)
        os.execv(MUX, [MUX])
    os.close(slave)
    return pid, master

def drain(master, screen, seconds):
    end = time.time() + seconds
    while time.time() < end:
        try:
            data = os.read(master, 65536)
        except OSError as e:
            if e.errno == errno.EIO:
                return
            time.sleep(0.02); continue
        if data:
            feed(screen, data)
        else:
            time.sleep(0.02)

def resize_and_sync(master, pid, screen, rows, cols, timeout=5.0):
    """Resize the PTY and switch the model's geometry EXACTLY at the mux's
    post-resize clear-screen (ESC[2J). Frames already in flight were rendered
    for the old geometry — applying the new one at signal time makes the model
    clamp them differently than it should and reports phantom scrolls."""
    set_winsize(master, rows, cols)
    os.kill(pid, signal.SIGWINCH)
    end = time.time() + timeout
    pending = bytearray()
    while time.time() < end:
        try:
            data = os.read(master, 65536)
        except OSError as e:
            if e.errno == errno.EIO:
                break
            time.sleep(0.02); continue
        if not data:
            time.sleep(0.02); continue
        pending.extend(data)
        cut = bytes(pending).find(b"\x1b[2J")
        if cut >= 0:
            feed(screen, bytes(pending[:cut]))     # old-geometry tail
            screen.resize(rows, cols)
            feed(screen, bytes(pending[cut:]))     # new world from the clear on
            return
        # No clear yet: feed what we have under the old geometry.
        feed(screen, bytes(pending))
        pending.clear()
    raise AssertionError("mux never emitted a clear-screen after SIGWINCH")

def kill_mux(pid):
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)

def scenario_scroll_invariant():
    rows, cols = 30, 100
    pid, master = spawn_mux(rows, cols)
    screen = HostScreen(rows, cols)
    drain(master, screen, 1.5)
    os.write(master, b"seq 1 2000\n")
    drain(master, screen, 2.5)
    os.write(master, "echo '日本語ワイド文字 🚀🚀🚀 test'\n".encode())
    drain(master, screen, 1.0)
    resize_and_sync(master, pid, screen, 24, 80)
    drain(master, screen, 1.0)
    os.write(master, b"seq 1 500\n")
    drain(master, screen, 1.5)
    kill_mux(pid)
    assert not screen.scrolls, f"host scrolled: {screen.scrolls[:5]}"
    print("PASS scroll-invariant (stream, wide chars, resize)")

def scenario_background_drain():
    rows, cols = 30, 100
    pid, master = spawn_mux(rows, cols)
    screen = HostScreen(rows, cols)
    marker = tempfile.mktemp(prefix="mux-qa-bg-")
    drain(master, screen, 1.5)

    os.write(master, b"\x02%")            # Ctrl-b % : split + spawn shell
    drain(master, screen, 1.5)            # new pane's shell boots
    os.write(master, b"\x02o")            # focus the new pane
    drain(master, screen, 0.3)
    cmd = f"seq 1 300000; touch {marker}\n".encode()
    os.write(master, cmd)                 # heavy stream in pane B...
    drain(master, screen, 0.2)
    os.write(master, b"\x02o")            # ...and focus back to pane A NOW

    # Generous deadline: an UNDRAINED pane never finishes no matter how long we
    # wait (that's the assertion) — a drained one just needs CPU headroom on a
    # loaded machine.
    deadline = time.time() + 60
    while time.time() < deadline and not os.path.exists(marker):
        drain(master, screen, 0.25)
    ok = os.path.exists(marker)
    if ok:
        os.unlink(marker)

    # Window smoke: create a window, hop back and forth — must stay alive.
    os.write(master, b"\x02c")
    drain(master, screen, 1.0)
    os.write(master, b"\x02p")
    drain(master, screen, 0.5)
    os.write(master, b"\x02n")
    drain(master, screen, 0.5)
    alive = True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        alive = False
    kill_mux(pid)

    assert ok, "background pane stalled: marker never appeared (PTY not drained while unfocused)"
    assert alive, "mux died during window create/switch"
    assert not screen.scrolls, f"host scrolled during multiplexing: {screen.scrolls[:5]}"
    print("PASS background-drain (split pane streams while unfocused) + window smoke")

def cli(sock_path, request):
    """One request over the zterm control protocol; returns the response."""
    import socket
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(sock_path)
    s.sendall(request.encode() + b"\n")
    resp = bytearray()
    while True:
        try:
            chunk = s.recv(65536)
        except OSError:
            break
        if not chunk:
            break
        resp.extend(chunk)
    s.close()
    return bytes(resp).decode("utf-8", "replace")

def scenario_control_socket():
    """Drive the visible mux over its control socket, wezterm-cli style.

    A REAL terminal drains the mux's stdout continuously; if this harness only
    drains between CLI calls, a post-split full redraw fills the PTY buffer and
    the mux's blocking stdout write stalls its event loop — the CLI response
    then never arrives. So a drainer thread plays the terminal's role here.
    """
    import json
    import threading
    sock = tempfile.mktemp(prefix="mux-qa-ctl-", suffix=".sock")
    os.environ["ZTERM_SOCKET"] = sock          # inherited by the forked mux
    try:
        pid, master = spawn_mux(30, 100)
        screen = HostScreen(30, 100)

        stop = threading.Event()
        def drainer():
            while not stop.is_set():
                try:
                    data = os.read(master, 65536)
                except OSError as e:
                    if e.errno == errno.EIO:
                        return
                    time.sleep(0.02); continue
                if data:
                    feed(screen, data)
                else:
                    time.sleep(0.02)
        t = threading.Thread(target=drainer, daemon=True)
        t.start()
        time.sleep(1.5)                        # shell boots

        panes = json.loads(cli(sock, "list"))
        assert len(panes) == 1 and panes[0]["active"], f"unexpected list: {panes}"

        r = json.loads(cli(sock, "split h"))
        assert r["ok"], f"split failed: {r}"
        time.sleep(1.5)                        # new shell boots
        panes = json.loads(cli(sock, "list"))
        assert len(panes) == 2, f"expected 2 panes after split: {panes}"

        marker = tempfile.mktemp(prefix="mux-qa-cli-")
        assert cli(sock, f"send 1 touch {marker}").startswith("ok")
        assert cli(sock, "enter 1").startswith("ok")
        deadline = time.time() + 15
        while time.time() < deadline and not os.path.exists(marker):
            time.sleep(0.25)
        assert os.path.exists(marker), "sent command never ran in pane 1"
        os.unlink(marker)

        cap = cli(sock, "capture 1")
        assert "touch" in cap, f"capture missing the typed command:\n{cap[:400]}"

        assert cli(sock, "focus 1").startswith("ok")
        panes = json.loads(cli(sock, "list"))
        assert panes[1]["active"], "focus 1 didn't take"

        assert cli(sock, "kill 1").startswith("ok")
        time.sleep(0.5)
        panes = json.loads(cli(sock, "list"))
        assert len(panes) == 1, f"expected 1 pane after kill: {panes}"

        stop.set()
        kill_mux(pid)                          # EIO unblocks the drainer read
        t.join(timeout=2)
        assert not screen.scrolls, f"host scrolled during CLI driving: {screen.scrolls[:5]}"
        print("PASS control-socket (list/split/send/enter/capture/focus/kill)")
    finally:
        del os.environ["ZTERM_SOCKET"]

if __name__ == "__main__":
    scenario_scroll_invariant()
    scenario_background_drain()
    scenario_control_socket()
    print("ALL QA SCENARIOS PASS")
