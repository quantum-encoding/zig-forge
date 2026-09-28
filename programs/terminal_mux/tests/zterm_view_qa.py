#!/usr/bin/env python3
"""End-to-end QA for the zterm view protocol (docs/VIEW-PROTOCOL.md) and
for `zterm attach`, which is built on it.

Run:  python3 tests/zterm_view_qa.py [path-to-zterm]   (default ../zig-out/bin/zterm)

Hermetic: temp HOME, /bin/sh panes, short /tmp socket paths (sun_path).

What it holds the server to:
  * hello, then a FULL frame at the requested size; later frames carry only
    the rows that changed; seq counts up by one;
  * the server — never the client — answers terminal queries (CPR);
  * wide characters arrive as their own two-column spans (zterm's widths);
  * resize (by a viewer, or by the one-shot `resize` request) yields a full
    frame at the new size; history by absolute line number;
  * exit carries the child's real status;
  * spawn `env` reaches that child only, and bad env objects are refused;
  * OSC 133 marks arrive as `marks` messages (the set on view open, the
    changed tail after), on the right absolute lines, and in history replies;
  * STATE-SYNC: a viewer that stops reading while its pane floods does not
    stall the server, and converges on the final screen once it reads;
  * `zterm attach`: draws, never relays a raw query to the host terminal,
    resizes the pane on SIGWINCH, detaches with the pane alive, and
    reports the pane's exit status.
"""
import fcntl, json, os, pty, select, shutil, signal, socket, struct, subprocess, sys, tempfile, termios, time

HERE = os.path.dirname(os.path.abspath(__file__))
Z = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "zig-out", "bin", "zterm")
base = tempfile.mkdtemp(prefix="ztvq-", dir="/tmp")
home = os.path.join(base, "home"); os.makedirs(home)
open(os.path.join(home, ".profile"), "w").close()
sock = os.path.join(base, "c.sock")
env = dict(os.environ, HOME=home, SHELL="/bin/sh", ZTERM_SOCKET=sock)
fails = []

def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail and not ok else ""))
    if not ok: fails.append(name)

def cli(*a):
    return subprocess.run([Z, "cli", *a], env=env, capture_output=True, text=True, timeout=10).stdout

def request(obj):
    s = socket.socket(socket.AF_UNIX); s.connect(sock); s.settimeout(5)
    s.sendall(json.dumps(obj).encode() + b"\n")
    out = b""
    while True:
        d = s.recv(65536)
        if not d: break
        out += d
    s.close(); return out.decode()

class View:
    """A view-protocol client that keeps every message and a reconstructed screen."""
    def __init__(self, pane, rows=None, cols=None):
        self.s = socket.socket(socket.AF_UNIX); self.s.connect(sock); self.s.settimeout(0.1)
        req = {"cmd": "view", "pane": pane}
        if rows: req.update(rows=rows, cols=cols)
        self.send(req); self.buf = b""; self.msgs = []; self.rows = {}
    def send(self, o): self.s.sendall(json.dumps(o).encode() + b"\n")
    def pump(self, t):
        end = time.time() + t
        while time.time() < end:
            try:
                d = self.s.recv(1 << 20)
                if not d: break
                self.buf += d
            except socket.timeout: pass
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                m = json.loads(line); m["_rx"] = time.time(); self.msgs.append(m)
                if m["t"] == "frame":
                    if m["full"]: self.rows = {}
                    for l in m["lines"]:
                        cells = [" "] * m["cols"]
                        for sp in l["spans"]:
                            x = sp["x"]
                            for ch in sp["text"]:
                                if x < len(cells): cells[x] = ch
                                x += sp.get("w", 1)
                        self.rows[l["y"]] = "".join(cells).rstrip()
    def frames(self): return [m for m in self.msgs if m["t"] == "frame"]
    def text(self): return "\n".join(self.rows[k] for k in sorted(self.rows))
    def until(self, pred, t=15):
        end = time.time() + t
        while time.time() < end:
            self.pump(0.2)
            if pred(): return True
        return False

def cpr_prog(path):
    return ("python3 -c \"import tty,os;tty.setraw(0);os.write(1,b'\\033[6n');r=b''\n"
            "while not r.endswith(b'R'): r+=os.read(0,1)\n"
            f"open('{path}','wb').write(r)\"\r")

srv = subprocess.Popen([Z, "server", "--no-runner"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(100):
        if os.path.exists(sock): break
        time.sleep(0.1)

    # ── the protocol, driven directly ─────────────────────────────────────
    v = View(1, 10, 40)
    v.until(lambda: len(v.frames()) >= 1 and "$" in v.text())
    check("hello first, then a full frame at the requested size",
          v.msgs[0]["t"] == "hello" and v.msgs[0]["v"] == 1 and v.frames()[0]["full"]
          and (v.frames()[0]["rows"], v.frames()[0]["cols"]) == (10, 40), v.msgs[:2])
    v.send({"input": "text", "data": "echo ok-$((6*7)) 日本\r"})
    check("typed input runs and is drawn", v.until(lambda: "ok-42" in v.text()))
    incr = [f for f in v.frames() if not f["full"]]
    check("later frames carry only changed rows", incr and all(len(f["lines"]) < 10 for f in incr[-3:]),
          [len(f["lines"]) for f in incr[-3:]])
    wide = [sp for f in v.frames() for l in f["lines"] for sp in l["spans"] if sp.get("w") == 2]
    check("a CJK run is ONE w:2 span (every code point two columns)", any(sp["text"] == "\u65e5\u672c" for sp in wide), wide[:2])
    th = v.msgs[0].get("theme", {})
    check("hello carries the theme: fg/bg/cursor and all 256 palette entries",
          all(th.get(k, "").startswith("#") for k in ("fg", "bg", "cursor", "cursor_text"))
          and len(th.get("palette", [])) == 256 and "bold_is_bright" in th, list(th)[:6])
    probe = os.path.join(base, "cpr1")
    v.send({"input": "text", "data": cpr_prog(probe)})
    ok = v.until(lambda: os.path.exists(probe))
    check("the SERVER answers the pane's CPR query", ok and open(probe, "rb").read().startswith(b"\x1b["),
          open(probe, "rb").read() if ok else "no reply")
    v.send({"resize": {"rows": 12, "cols": 50}})
    check("a viewer's resize → a full frame at the new size",
          v.until(lambda: any(f["full"] and (f["rows"], f["cols"]) == (12, 50) for f in v.frames())))
    request({"cmd": "resize", "pane": 1, "rows": 14, "cols": 60})
    check("a one-shot `resize` request also resyncs viewers",
          v.until(lambda: any(f["full"] and (f["rows"], f["cols"]) == (14, 60) for f in v.frames()), 5))
    v.send({"input": "text", "data": "seq 1 40\r"}); v.until(lambda: "40" in v.text())
    last = v.frames()[-1]
    v.send({"history": {"from": last["oldest"], "count": 2}})
    v.until(lambda: any(m["t"] == "history" for m in v.msgs))
    h = [m for m in v.msgs if m["t"] == "history"][-1]
    check("history returns lines by absolute number from oldest",
          [l["n"] for l in h["lines"]] == [last["oldest"], last["oldest"] + 1], h["lines"][:2])
    counts = {r["pane"]: r["viewers"] for r in json.loads(cli("list"))}
    check("list reports how many clients view each pane", counts.get(1) == 1, counts)
    seqs = [f["seq"] for f in v.frames()]
    check("frame seq counts up by one", seqs == list(range(1, len(seqs) + 1)))

    # ── spawn env + OSC 133 marks ─────────────────────────────────────────
    # The skip variables keep /etc/profile.d shell integrations (wezterm.sh,
    # vte.sh) out of this login shell, so the only marks are the ones printed
    # below — and they show the env is in place before the shell starts.
    r = json.loads(request({"cmd": "spawn", "env": {"ZT_QA_VAR": "hello-env", "ZDOTDIR": base,
                                                    "WEZTERM_SHELL_SKIP_ALL": "1", "VTE_VERSION": ""}}))
    mp = r.get("pane")
    check("spawn accepts an env object", r.get("ok") is True and mp, r)
    for bad, why in (({"lower": "x"}, "lowercase key"), ({"A": 1}, "non-string value"),
                     ({"ZTERM_PANE": "9"}, "pane identity"), ({"A": "x" * 5000}, "value too long"),
                     ({f"K{i}": "v" for i in range(40)}, "too many"), ("A=1", "not an object")):
        r = json.loads(request({"cmd": "spawn", "env": bad}))
        check(f"spawn refuses a bad env ({why})", r.get("ok") is False and r.get("error"), r)
    mv = View(mp, 24, 80)
    mv.until(lambda: "$" in mv.text())
    marks_msgs = lambda vw: [m for m in vw.msgs if m["t"] == "marks"]
    first = next((m for m in mv.msgs if m["t"] in ("marks", "frame")), {})
    check("a new view gets the (empty) mark set ahead of its first frame",
          first.get("t") == "marks" and first.get("marks") == [] and "from" in first, first)
    mv.send({"input": "text", "data": 'echo "v=$ZT_QA_VAR"\r'})
    check("spawn env reaches the child", mv.until(lambda: "v=hello-env" in mv.text()), mv.text()[-200:])
    v.send({"input": "text", "data": 'echo "w=[$ZT_QA_VAR]"\r'})
    check("…and only that child", v.until(lambda: "w=[]" in v.text()), v.text()[-200:])
    mv.send({"input": "text", "data":
             "printf '\\033]133;A\\007PROMPT-X \\033]133;B\\007cmd\\033]133;C\\033\\134\\n'; "
             "echo MARK-OUT; printf '\\033]133;D;4\\007'; echo\r"})
    got = lambda: {m["k"] for mm in marks_msgs(mv) for m in mm["marks"]} >= {"A", "B", "C", "D"}
    check("OSC 133 A/B/C/D reach the view as marks", mv.until(got), marks_msgs(mv)[-2:])
    mv.pump(0.3)
    fr = mv.frames()[-1]
    def abs_of(needle):
        ys = [y for y, t in mv.rows.items() if needle in t and "printf" not in t and "echo" not in t]
        return fr["live_top"] + ys[0] if ys else None
    # A client's copy: each `marks` message replaces everything from `from` down.
    def replay(msgs):
        held = {}
        for mm in msgs:
            held = {k: x for k, x in held.items() if k[0] < mm["from"]}
            for m in mm["marks"]: held[(m["n"], m["k"])] = m
        return held
    held = replay(marks_msgs(mv))
    pl, ol = abs_of("PROMPT-X"), abs_of("MARK-OUT")
    check("A, B and C sit on the prompt's absolute line",
          pl is not None and all((pl, k) in held for k in "ABC"), (pl, sorted(held)))
    check("the shell's own integration stayed off (env applied at startup)",
          set(held) == {(pl, "A"), (pl, "B"), (pl, "C"), (ol + 1, "D")}, sorted(held))
    check("D sits after the output and carries the exit status",
          ol is not None and held.get((ol + 1, "D"), {}).get("exit") == 4, (ol, sorted(held)))
    carrier = next((mm for mm in marks_msgs(mv) if any(m["k"] == "D" and m.get("exit") == 4 for m in mm["marks"])), {})
    check("later marks messages carry only the changed tail",
          carrier.get("from") == pl and all(m["n"] >= pl for m in carrier["marks"]), carrier)
    mv.send({"history": {"from": fr["oldest"], "count": 100}})
    mv.until(lambda: any(m["t"] == "history" for m in mv.msgs), 5)
    hm = [m for m in mv.msgs if m["t"] == "history"][-1]
    check("a history reply carries the marks of its lines",
          {(m["n"], m["k"]) for m in hm.get("marks", [])} == set(held), hm.get("marks"))
    mv2 = View(mp)
    mv2.until(lambda: len(mv2.frames()) >= 1)
    full = next((m for m in mv2.msgs if m["t"] == "marks"), {})
    check("a second view opens with the whole mark set",
          {(m["n"], m["k"]) for m in full.get("marks", [])} == set(held), full)
    mv.send({"input": "text", "data": "clear\r"})
    mv.until(lambda: "MARK-OUT" not in mv.text(), 5)
    mv.send({"input": "text", "data": "printf '\\033]133;A\\007'; echo AGAIN\r"})
    mv.until(lambda: "AGAIN" in mv.text(), 5)
    mv.pump(0.5)
    fr = mv.frames()[-1]
    again = abs_of("AGAIN")
    held = replay(marks_msgs(mv))
    mv3 = View(mp)
    mv3.until(lambda: len(mv3.frames()) >= 1)
    check("a mark written above held ones replaces the stale tail",
          again is not None and (again, "A") in held and all(m.get("exit") != 4 for m in held.values()),
          (again, sorted(held)))
    check("…and a client replaying the tails holds exactly the server's set",
          set(held) == set(replay(marks_msgs(mv3))), (sorted(held), marks_msgs(mv3)))

    # ── state-sync backpressure ───────────────────────────────────────────
    sp = json.loads(cli("spawn"))["pane"]
    slow = View(sp, 24, 80)          # connects, then does not read
    fast = View(sp)
    fast.until(lambda: "$" in fast.text())
    flood_t0 = time.time()
    fast.send({"input": "text", "data": "seq 1 1000000; echo FLOOD-DONE\r"})
    t0 = time.time(); listed = cli("list"); dt = time.time() - t0
    check("a viewer that stops reading does not stall the server", listed.startswith("[") and dt < 2.0, f"{dt:.2f}s")
    check("…and the reading viewer keeps up", fast.until(lambda: "FLOOD-DONE" in fast.text(), 60))
    # Pacing: one frame per 8 ms at most (the default --frame-ms), however
    # many reads the flood took. The flood was started by typed input, whose
    # answering frame is never held, so frames from the first 100 ms are not
    # counted. 190/s leaves room for timer slack; unpaced this was 2000-5000/s.
    paced_from = flood_t0 + 0.1
    paced = [f["_rx"] for f in fast.frames() if f["_rx"] > paced_from]
    span = (paced[-1] - paced_from) if paced else 0
    check("frames are paced while a pane streams (<= ~120/s)",
          len(paced) >= 5 and span > 0 and len(paced) / span <= 190,
          f"{len(paced)} frames in {span:.2f}s after the input window")
    # Only the FIRST frame after the typed command is exempt: a command that
    # floods on Enter must not get a frame per PTY read until a window closes
    # (a 50 ms window sent ~300 frames there once the emulator got faster).
    early = [f for f in fast.frames() if flood_t0 <= f["_rx"] < flood_t0 + 0.1]
    check("a flood started by input is paced after its first frame",
          len(early) <= 25, f"{len(early)} frames in the first 100 ms")
    check("…and the stalled viewer converges on the final screen once it reads",
          slow.until(lambda: "FLOOD-DONE" in slow.text(), 30), slow.text()[-120:])

    # ── pacing never holds the answer to input ────────────────────────────
    # Keys sent back to back, each as soon as the last one's echo is drawn:
    # every key lands inside the pacing interval, so a pacer that ignored
    # input would add the whole 8 ms to each (measured before the fix).
    kp = json.loads(cli("spawn"))["pane"]
    kv = View(kp, 24, 80)
    kv.send({"input": "text", "data": "exec cat\r"}); kv.pump(0.5)
    # Timed to the arrival of the frame's bytes: View.pump would sit out its
    # socket timeout after the frame and time itself instead.
    kv.s.settimeout(0.05)
    lat = []
    for i in range(30):
        got = b""; t0 = time.time()
        kv.send({"input": "text", "data": "k"})
        while b'"t":"frame"' not in got and time.time() - t0 < 2:
            try:
                got += kv.s.recv(1 << 20)
            except socket.timeout:
                pass
        lat.append(time.time() - t0)
    kv.s.settimeout(0.1)
    lat.sort()
    check("a keystroke's echo is not held by pacing (median < 3 ms)", lat[len(lat) // 2] < 0.003,
          f"median {lat[len(lat) // 2] * 1000:.2f} ms")

    # ── exit status ───────────────────────────────────────────────────────
    v.send({"input": "text", "data": "exit 3\r"})
    v.until(lambda: any(m["t"] == "exit" for m in v.msgs))
    ex = [m for m in v.msgs if m["t"] == "exit"]
    check("exit carries the child's real status", ex and ex[0]["code"] == 3, ex)

    # ── zterm attach, a client of the same protocol ───────────────────────
    ap = json.loads(cli("spawn"))["pane"]
    def attach(rows, cols):
        pid, fd = pty.fork()
        if pid == 0:
            os.execve(Z, [Z, "attach", str(ap)], env)
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        return pid, fd
    def drain(fd, t):
        out = b""; end = time.time() + t
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.1)
            if r:
                try: out += os.read(fd, 65536)
                except OSError: break
        return out
    def pane_dims():
        return [(r["rows"], r["cols"]) for r in json.loads(cli("list")) if r["pane"] == ap]
    pid, fd = attach(20, 70); out = drain(fd, 1.5)
    check("attach enters the host alt screen and draws the pane", b"\x1b[?1049h" in out and b"$" in out)
    check("attach draws in the SERVER's theme (truecolour), not the host palette", b";38;2;" in out and b";48;2;" in out)
    check("attach sizes the pane to the window", pane_dims() == [(20, 70)], pane_dims())
    probe2 = os.path.join(base, "cpr2")
    os.write(fd, cpr_prog(probe2).encode()); out = drain(fd, 2.5)
    check("attach never relays a raw query to the host terminal", b"\x1b[6n" not in out)
    check("…the server answered it instead", os.path.exists(probe2))
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0)); os.kill(pid, signal.SIGWINCH)
    drain(fd, 1.0)
    check("SIGWINCH resizes the pane", pane_dims() == [(30, 100)], pane_dims())
    os.write(fd, b"MARK=kept\r"); drain(fd, 0.5)
    os.write(fd, b"\x02d"); out = drain(fd, 1.0); os.waitpid(pid, 0)
    check("Ctrl-b d detaches and restores the host screen", b"detached" in out and b"\x1b[?1049l" in out)
    pid, fd = attach(30, 100); drain(fd, 1.0)
    os.write(fd, b"echo state-$MARK\r"); out = drain(fd, 1.0)
    check("reattach finds the same shell", b"state-kept" in out)
    os.write(fd, b"exit 5\r"); out = drain(fd, 3.0); os.waitpid(pid, 0)
    check("attach reports the pane's exit status", b"exited (5)" in out, out[-80:])
finally:
    srv.terminate()
    try: srv.wait(timeout=10)
    except Exception: srv.kill()
    shutil.rmtree(base, ignore_errors=True)

print("ALL ZTERM VIEW QA PASS" if not fails else f"{len(fails)} FAILED: {fails}")
sys.exit(1 if fails else 0)
