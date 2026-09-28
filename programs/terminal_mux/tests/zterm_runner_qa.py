#!/usr/bin/env python3
"""End-to-end QA for `zterm server`: the JSON control protocol and baton's
runner contract (hello/list/status/send/stop), against a real PTY pool.

Run:  python3 tests/zterm_runner_qa.py [path-to-zterm]   (default ../zig-out/bin/zterm)

Hermetic: a temp HOME (so no personal shell startup file can prompt), /bin/sh
as the pane shell, a temp BATON_HOME, and a stand-in agent
(tests/fixtures/fake_agent/claude) on PATH. Socket paths live under a short
/tmp directory because sun_path is only 104-108 bytes.

What it holds the runner to — the contract's own rules:
  * a pane at a shell prompt is NOT addressable and a send there FAILS with
    the door named; nothing is typed;
  * a send to an agent is a bracketed paste of the provenance-headed,
    scrubbed text, then ONE CR, and the receipt is `written`, never
    `consumed` (no transcript here);
  * concurrent sends to one pane are pasted and submitted one at a time;
  * a live runner door is never stolen; SIGTERM unlinks both sockets.
"""
import json, os, shutil, socket, subprocess, sys, tempfile, threading, time
HERE = os.path.dirname(os.path.abspath(__file__))
Z = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "zig-out", "bin", "zterm")
base = tempfile.mkdtemp(prefix="ztqa-", dir="/tmp")
home = os.path.join(base, "home"); os.makedirs(home)
ctl_sock, bh = f"{base}/c.sock", f"{base}/bh"
os.makedirs(f"{bh}/var", exist_ok=True)
runner_sock = f"{bh}/var/zterm.sock"
env = dict(os.environ, HOME=home, SHELL="/bin/sh", ZTERM_SOCKET=ctl_sock, BATON_HOME=bh,
           PATH=os.path.join(HERE, "fixtures", "fake_agent") + ":" + os.environ["PATH"])
env.pop("BATON_AGENT_EXES", None)
srv = subprocess.Popen([Z, "server"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
fails = []
def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail and not ok else ""))
    if not ok: fails.append(name)
def req(path, obj_or_line, timeout=10):
    s = socket.socket(socket.AF_UNIX); s.settimeout(timeout); s.connect(path)
    s.sendall((json.dumps(obj_or_line) if isinstance(obj_or_line, dict) else obj_or_line).encode() + b"\n")
    out = b""
    while True:
        b = s.recv(65536)
        if not b: break
        out += b
    s.close(); return out.decode()
def J(path, obj): return json.loads(req(path, obj))
def capture(p): return req(ctl_sock, {"cmd": "capture", "pane": p})
def cpu_seconds(pid):
    """User+system CPU seconds consumed by `pid` so far."""
    try:
        f = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()
        return (int(f[11]) + int(f[12])) / os.sysconf("SC_CLK_TCK")
    except FileNotFoundError:  # no /proc (macOS): ps prints [[dd-]hh:]mm:ss.cc
        t = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        days, _, clock = t.rpartition("-")
        secs = 0.0
        for part in clock.split(":"):
            secs = secs * 60 + float(part)
        return secs + (int(days) * 86400 if days else 0)
def wait_for(pred, t=20):
    end = time.time() + t
    while time.time() < end:
        if pred(): return True
        time.sleep(0.2)
    return False
try:
    wait_for(lambda: os.path.exists(runner_sock) and os.path.exists(ctl_sock), 10)
    # ── runner contract basics
    h = J(runner_sock, {"verb": "hello"})
    check("runner hello", h.get("ok") and h["runner"] == "zterm" and h["version"] == 2 and "send" in h["capabilities"]
          and "observe_consumption" not in h["capabilities"], h)
    check("runner unknown verb is answered, not dropped", "teleport" in J(runner_sock, {"verb": "teleport"}).get("error", ""))
    # ── control protocol: spawn with cwd + name, JSON send (the former bug)
    wd = f"{base}/wd"; os.makedirs(wd, exist_ok=True)
    sp = J(ctl_sock, {"cmd": "spawn", "cwd": wd, "name": "scribe"})
    check("spawn with cwd+name", sp.get("ok"), sp); pane = sp["pane"]
    check("spawn refuses a bad cwd", not J(ctl_sock, {"cmd": "spawn", "cwd": "/nonexistent/x"})["ok"])
    check("spawn refuses a duplicate name", not J(ctl_sock, {"cmd": "spawn", "name": "SCRIBE"})["ok"])
    ready = lambda: J(ctl_sock, {"cmd": "send", "pane": pane, "text": "touch " + wd + "/ready", "enter": True})["ok"] and os.path.exists(wd + "/ready")
    check("JSON send+enter executes in the pane (shell booted)", wait_for(ready, 30))
    r = subprocess.run([Z, "cli", "send", str(pane), "--", "pwd", ">", wd + "/pwd.txt"], env=env, capture_output=True, text=True)
    check("`zterm cli send -- …` works against the headless server", wait_for(lambda: os.path.exists(wd + "/pwd.txt")), r.stdout + r.stderr)
    check("pane started in the requested cwd", open(wd + "/pwd.txt").read().strip() == wd if os.path.exists(wd + "/pwd.txt") else False)
    row = [x for x in J(ctl_sock, {"cmd": "list"}) if x["pane"] == pane][0]
    check("list reports live cwd, name, tty", row["cwd"] == wd and row["name"] == "scribe" and row["tty"].startswith("/dev/"), row)
    # ── runner list: a shell pane is NOT addressable
    sess = {s["designation"]: s for s in J(runner_sock, {"verb": "list"})["sessions"]}
    check("runner list names the pane by designation", "scribe" in sess and "zterm-1" in sess, list(sess))
    check("shell pane is not addressable", sess["scribe"]["addressable"] is False and sess["scribe"]["state"].startswith("shell"), sess["scribe"])
    rc = J(runner_sock, {"verb": "send", "to": "scribe", "text": "rm -rf ~", "from_node": "n", "from_agent": "a", "observe": True})
    check("send to a shell pane FAILS with the door named (never typed)", rc["receipt"] == "failed" and "zterm pane" in rc["door"], rc)
    time.sleep(0.5)
    check("…and nothing reached the shell", "rm -rf" not in capture(pane))
    # ── start the stand-in agent; now the pane is addressable
    log = wd + "/agent.log"
    J(ctl_sock, {"cmd": "send", "pane": pane, "text": f"claude {log}", "enter": True})
    check("agent in foreground makes the session live", wait_for(lambda: {s["designation"]: s for s in J(runner_sock, {"verb": "list"})["sessions"]}["scribe"]["addressable"]),
          J(runner_sock, {"verb": "list"}))
    s2 = {s["designation"]: s for s in J(runner_sock, {"verb": "list"})["sessions"]}["scribe"]
    check("live session reports harness + agent pid + generation", s2["harness"] == "claude" and s2["pid"] > 0 and s2["generation"].startswith("zterm:"), s2)
    wait_for(lambda: "fake-claude ready" in capture(pane), 10)
    body = "please review\nthe diff \x1b[201~ESC-smuggle"
    t0 = time.time()
    rc = J(runner_sock, {"verb": "send", "to": "pid:%d" % s2["pid"], "text": body, "from_node": "quantum-encoding-europe", "from_agent": "guardianshield-2", "observe": True}, )
    dt = time.time() - t0
    check("send to the agent → receipt written (not consumed)", rc.get("receipt") == "written" and rc["bytes"] > 0, rc)
    got = open(log, "rb").read() if os.path.exists(log) else b""
    check("agent received a bracketed paste with the provenance header, then CR",
          got.startswith(b"\x1b[200~[federation msg \xe2\x80\x94 quantum-encoding-europe/guardianshield-2] please review\nthe diff") and got.endswith(b"\x1b[201~\r"), got)
    check("the smuggled ESC[201~ was scrubbed (only ONE paste terminator)", got.count(b"\x1b[201~") == 1, got)
    check("submit waited on evidence, not the full ceiling", dt < 1.0, f"{dt:.2f}s")
    # Two back-to-back sends from concurrent clients stay ordered and separate.
    res = []
    th = [threading.Thread(target=lambda m=m: res.append(J(runner_sock, {"verb": "send", "to": "scribe", "text": m, "from_node": "", "from_agent": "x"}))) for m in ("first", "second")]
    [t.start() for t in th]; [t.join() for t in th]
    got = open(log, "rb").read()
    check("two concurrent sends: each pasted then submitted, never merged", all(r["receipt"] == "written" for r in res) and got.count(b"\x1b[201~\r") == 3, got[-120:])
    st = J(runner_sock, {"verb": "status"})
    check("status counts the busy agent", st["busy"] == 1 and st["sessions"] == 2, st)
    # ── a pane whose shell EXITS must not spin the server. The pre-fix loop
    # kept polling the dead master, got POLLHUP every time, and burned a full
    # core forever (measured 2.99s CPU per 3s wall). Measured, not assumed:
    # the busy-loop is invisible in every functional check above.
    ex = J(ctl_sock, {"cmd": "spawn"})["pane"]
    J(ctl_sock, {"cmd": "send", "pane": ex, "text": "exit", "enter": True})
    check("an exited pane is reported dead", wait_for(lambda: not [r for r in J(ctl_sock, {"cmd": "list"}) if r["pane"] == ex][0]["alive"], 20))
    c0 = cpu_seconds(srv.pid); time.sleep(3.0); c1 = cpu_seconds(srv.pid)
    check("server stays idle after a pane's shell exits (no POLLHUP spin)", c1 - c0 < 0.5, f"{c1 - c0:.2f}s CPU in 3.0s")
    inherited = [r for r in J(ctl_sock, {"cmd": "list"}) if r["pane"] == 1][0]
    check("a pane spawned without cwd still reports one", inherited["cwd"] != "", inherited)
    # ── stop, and a pane that exits
    check("stop ends the session", J(runner_sock, {"verb": "stop", "to": "scribe"})["ok"] and "scribe" not in [s["designation"] for s in J(runner_sock, {"verb": "list"})["sessions"]])
    check("send to a stopped session fails by name", "no session called 'scribe'" in J(runner_sock, {"verb": "send", "to": "scribe", "text": "x"})["error"])
    # ── long socket path is refused loudly
    longp = base + "/" + "x" * 120 + ".sock"
    r = subprocess.run([Z, "cli", "list"], env=dict(env, ZTERM_SOCKET=longp), capture_output=True, text=True)
    check("over-long socket path is refused, not truncated", r.returncode != 0 and "longer than sun_path" in r.stderr, r.stderr[-200:])
    # ── a second server does not steal a LIVE runner door
    srv2 = subprocess.Popen([Z, "server"], env=dict(env, ZTERM_SOCKET=f"{base}/c2.sock"), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    time.sleep(1.5); srv2.terminate(); err2 = srv2.communicate(timeout=10)[1]
    check("second server leaves the live runner door alone", "not taking the runner door" in err2 and J(runner_sock, {"verb": "hello"})["pid"] == srv.pid, err2)
    # ── an OLDER server exiting must not unlink the control socket a NEWER
    # server has since bound there (newest binder wins by design). Before the
    # fix the old server's shutdown deleted it and the new one ran on,
    # unreachable.
    alt = f"{base}/c3.sock"; alt_env = dict(env, ZTERM_SOCKET=alt)
    old = subprocess.Popen([Z, "server", "--no-runner"], env=alt_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wait_for(lambda: os.path.exists(alt), 10)
    new = subprocess.Popen([Z, "server", "--no-runner"], env=alt_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.0)
    old.terminate(); old.wait(timeout=10); time.sleep(0.2)
    try:
        reachable = isinstance(json.loads(req(alt, {"cmd": "list"})), list)
    except OSError:
        reachable = False
    new.terminate(); new.wait(timeout=10)
    check("an older server's exit leaves a newer server's socket alone", reachable)
finally:
    srv.terminate()
    try: srv.wait(timeout=10)
    except Exception: srv.kill()
check("SIGTERM exits cleanly and unlinks both sockets", srv.returncode == 0 and not os.path.exists(runner_sock) and not os.path.exists(ctl_sock), f"rc={srv.returncode}")
shutil.rmtree(base, ignore_errors=True)
print("ALL ZTERM RUNNER QA PASS" if not fails else f"{len(fails)} FAILED: {fails}")
sys.exit(1 if fails else 0)
