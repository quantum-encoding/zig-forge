#!/usr/bin/env python3
"""Record one zterm benchmark run, so performance can be compared over time.

    scripts/bench-run.py [--label SLUG] [--quick] [--repeat N] [--cpus LIST]
                         [--no-build] [--compare PATH] [--fail-on-regression]

Runs, in order:
  1. zterm-bench      the core: parser MiB/s on four fixed inputs, PTY ingest,
                      pane create/attach cost (src/bench.zig)
  2. zterm-viewbench  through a `zterm server`, as a front end sees it:
                      keypress round trip, resize, output throughput with
                      1/4/16 viewers and a stalled one, reattach + history
                      (src/viewbench.zig)
  3. the server's own peak RSS, and its CPU while idle afterwards

and records the run in the layout the Experiments panel reads
(~/work/experiments-mcp):

  BENCH.md                                     one row per run: commit … flags | stamp
  bench/runs/<date>-<label>/README.md          what was measured, where, caveats
  bench/runs/<date>-<label>/report-<stamp>.json   every number with its samples
  bench/runs/<date>-<label>/table-<stamp>.md      the printed tables + comparison
  bench/runs/<date>-<label>/stderr-<stamp>.log    everything the programs printed

then compares against the previous run (or --compare PATH). A metric is called
better or WORSE only when both runs have at least 5 samples, the medians differ
by more than 5%, AND the two runs' min..max ranges do not overlap. Anything
less is noise on a machine in use: two runs of the same commit here differ by
10-25% on most timings, so a weaker rule reports regressions that are not.

Hermetic: every pane runs /bin/sh under a temp HOME — no personal shell
startup file runs (one that prompts would receive what the benchmarks type),
and the server's socket lives under /tmp.

For numbers worth comparing: AC power, the performance power profile, an idle
machine, and --cpus to pin (e.g. --cpus 2-7). The report records all of these,
so a noisy run can be recognised later rather than trusted.
"""
import argparse
import datetime
import glob
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)  # programs/terminal_mux
BIN = os.path.join(ROOT, "zig-out", "bin")
RUNS = os.path.join(ROOT, "bench", "runs")
BENCH_MD = os.path.join(ROOT, "BENCH.md")
SCHEMA = 1

# The BENCH.md row. The Experiments reader takes column 1 as the commit,
# column 14 as the flags and column 15 as the stamp it pairs the report by —
# so those three positions are fixed; the columns between are ours.
ROW_METRICS = [
    ("feed_mixed_mibs", "mixed MiB/s"),
    ("feed_plain_mibs", "plain MiB/s"),
    ("feed_cjk_mibs", "cjk MiB/s"),
    ("feed_redraw_mibs", "redraw MiB/s"),
    ("pty_ingest_mibs", "pty MiB/s"),
    ("keypress_us", "key p50 µs"),
    ("view_output_mibs_v1", "view MiB/s"),
    ("view_output_mibs_v16", "view×16 MiB/s"),
    ("reattach_history_ms", "10k history ms"),
    ("server_peak_rss_mb", "server RSS MB"),
]
HEADER = ["commit", "date", "machine"] + [h for _, h in ROW_METRICS] + ["flags", "stamp"]
assert HEADER.index("flags") == 13 and HEADER.index("stamp") == 14  # 1-based 14, 15

NOISE_PCT = 5.0
MIN_SAMPLES = 5


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, text=True, **kw)


def out(cmd, default=""):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return default


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def context(cpus):
    cpu_model = ""
    for line in read("/proc/cpuinfo").splitlines():
        if line.startswith("model name"):
            cpu_model = line.split(":", 1)[1].strip()
            break
    on_ac = None
    for ps in glob.glob("/sys/class/power_supply/*"):
        if read(os.path.join(ps, "type")) == "Mains":
            on_ac = read(os.path.join(ps, "online")) == "1"
    mem_kb = 0
    for line in read("/proc/meminfo").splitlines():
        if line.startswith("MemTotal:"):
            mem_kb = int(line.split()[1])
    # Dirty = the CODE differs from the commit. This script's own outputs do
    # not count, or every run after the first would be marked dirty.
    status = out(["git", "-C", ROOT, "status", "--porcelain", "--", ".",
                  ":(exclude)BENCH.md", ":(exclude)bench/runs"])
    return {
        "commit": out(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"], "unknown"),
        "dirty": bool(status),
        "machine": socket.gethostname(),
        "kernel": os.uname().release,
        "cpu": cpu_model,
        "cpu_count": os.cpu_count(),
        "mem_gb": round(mem_kb / 1024 / 1024, 1),
        "governor": read("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"),
        "energy_preference": read("/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference"),
        "power_profile": out(["powerprofilesctl", "get"]),
        "on_ac": on_ac,
        "loadavg_start": read("/proc/loadavg").split()[:3],
        "zig": out(["zig", "version"]),
        "pinned_cpus": cpus or None,
    }


def hermetic_env(home):
    env = {k: v for k, v in os.environ.items()
           if k not in ("ZDOTDIR", "ENV", "BASH_ENV", "ZTERM_SOCKET", "BATON_HOME",
                        "WEZTERM_PANE", "ZTERM_PANE")}
    env.update(HOME=home, SHELL="/bin/sh")
    return env


def pinned(cmd, cpus):
    return (["taskset", "-c", cpus] + cmd) if cpus else cmd


def proc_status(pid, key):
    for line in read(f"/proc/{pid}/status").splitlines():
        if line.startswith(key + ":"):
            return int(line.split()[1])
    return 0


def proc_cpu_ticks(pid):
    fields = read(f"/proc/{pid}/stat").rsplit(")", 1)[-1].split()
    return int(fields[11]) + int(fields[12]) if len(fields) > 12 else 0


def single(value, unit, higher_is_better):
    """A metric sampled once, in the programs' metric shape."""
    return {"unit": unit, "higher_is_better": higher_is_better, "trend_only": False, "n": 1, "median": value,
            "min": value, "max": value, "mean": value, "p90": value, "p99": value, "samples": [value]}


def wait_socket(path, proc, timeout=5.0):
    end = time.time() + timeout
    while time.time() < end:
        if proc.poll() is not None:
            raise RuntimeError(f"zterm server exited early ({proc.returncode})")
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(path)
            s.close()
            return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError("zterm server never listened on " + path)


def view_stage(env, cpus, view_args, log, server_args):
    """Start a server, run the view benchmark against it, measure the server."""
    sockdir = tempfile.mkdtemp(prefix="zb-", dir="/tmp")
    sock = os.path.join(sockdir, "s.sock")
    senv = dict(env, ZTERM_SOCKET=sock)
    with open(os.path.join(sockdir, "server.log"), "w") as slog:
        server = subprocess.Popen(pinned([os.path.join(BIN, "zterm"), "server", "--no-runner"] + server_args, cpus),
                                  env=senv, stdout=slog, stderr=subprocess.STDOUT)
    try:
        wait_socket(sock, server)
        r = subprocess.run(pinned([os.path.join(BIN, "zterm-viewbench"), "--socket", sock, "--json"] + view_args, cpus),
                           env=senv, capture_output=True, text=True, timeout=1800)
        log.append("== zterm-viewbench ==\n" + r.stderr)
        if r.returncode != 0:
            raise RuntimeError("zterm-viewbench failed:\n" + r.stderr[-2000:])
        report = json.loads(r.stdout)
        # Idle cost after the work: every benchmark pane has been killed; the
        # server's default pane (an idle /bin/sh) remains.
        hz = os.sysconf("SC_CLK_TCK")
        t0, c0 = time.time(), proc_cpu_ticks(server.pid)
        time.sleep(3)
        idle_pct = (proc_cpu_ticks(server.pid) - c0) / hz / (time.time() - t0) * 100
        report["metrics"]["server_peak_rss_mb"] = single(round(proc_status(server.pid, "VmHWM") / 1024, 2), "MB", False)
        report["metrics"]["server_idle_cpu_pct"] = single(round(idle_pct, 3), "%", False)
    finally:
        server.send_signal(signal.SIGTERM)
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
        log.append("== zterm server ==\n" + read(os.path.join(sockdir, "server.log")))
        shutil.rmtree(sockdir, ignore_errors=True)
    return report


def previous_report(exclude):
    reports = sorted(glob.glob(os.path.join(RUNS, "*", "report-*.json")),
                     key=lambda p: os.path.basename(p))
    reports = [p for p in reports if os.path.abspath(p) != os.path.abspath(exclude)]
    return reports[-1] if reports else None


def compare(new, old_path):
    """Rows of (metric, old, new, change %, verdict)."""
    with open(old_path) as f:
        old = json.load(f)
    rows, regressions = [], []
    for name, m in new["metrics"].items():
        o = old.get("metrics", {}).get(name)
        if not o or not o.get("median"):
            continue
        change = (m["median"] - o["median"]) / o["median"] * 100
        # The runs' ranges must not overlap: new entirely above or below old.
        apart = m["min"] > o["max"] or m["max"] < o["min"]
        better = (change > 0) == m["higher_is_better"]
        if m.get("trend_only") or o.get("trend_only"):
            verdict = "(trend)"
        elif abs(change) <= NOISE_PCT or not apart:
            verdict = "~"
        elif min(m["n"], o["n"]) < MIN_SAMPLES:
            verdict = f"? n<{MIN_SAMPLES}"
        elif better:
            verdict = "better"
        else:
            verdict = "WORSE"
            regressions.append(name)
        rows.append((name, o["median"], m["median"], change, verdict))
    return old, rows, regressions


def fmt(v):
    return f"{v:.3f}" if abs(v) < 100 else f"{v:.1f}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--label", default="run", help="slug for the run directory (e.g. baseline, after-coalesce)")
    ap.add_argument("--quick", action="store_true", help="small volumes: a smoke test, not a comparable run")
    ap.add_argument("--repeat", type=int, default=5, help="samples per core metric (default 5)")
    ap.add_argument("--cpus", default="", help="pin every process to these CPUs (taskset list, e.g. 2-7)")
    ap.add_argument("--frame-ms", type=int, default=None,
                    help="the server's frame pacing interval (default: the server's own; 0 = unpaced)")
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--compare", default="", help="report JSON to compare with (default: the previous run)")
    ap.add_argument("--fail-on-regression", action="store_true", help="exit 1 when a metric is WORSE")
    a = ap.parse_args()
    if not a.label.replace("-", "").replace("_", "").isalnum():
        ap.error("--label: letters, digits, - and _ only")

    if not a.no_build:
        run(["zig", "build", "-Doptimize=ReleaseFast"], cwd=ROOT)

    stamp = datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
    ctx = context(a.cpus)
    home = tempfile.mkdtemp(prefix="zbench-home-", dir="/tmp")
    env = hermetic_env(home)
    core_args = ["--repeat", str(a.repeat)]
    view_args = ["--repeat", str(a.repeat)]
    if a.quick:
        core_args += ["--feed-mib", "16", "--pty-mib", "4"]
        view_args += ["--keys", "100", "--seq", "100000"]
    server_args = ["--frame-ms", str(a.frame_ms)] if a.frame_ms is not None else []
    flags = " ".join(core_args + (["--quick"] if a.quick else []) + (["--cpus", a.cpus] if a.cpus else []) + server_args)

    log = []
    try:
        r = subprocess.run(pinned([os.path.join(BIN, "zterm-bench"), "--json"] + core_args, a.cpus),
                           env=env, capture_output=True, text=True, timeout=1800)
        log.append("== zterm-bench ==\n" + r.stderr)
        if r.returncode != 0:
            sys.exit("zterm-bench failed:\n" + r.stderr[-2000:])
        core = json.loads(r.stdout)
        view = view_stage(env, a.cpus, view_args, log, server_args)
    finally:
        shutil.rmtree(home, ignore_errors=True)
    ctx["loadavg_end"] = read("/proc/loadavg").split()[:3]

    report = {
        "bench": "zterm", "schema": SCHEMA, "stamp": stamp, "label": a.label, "flags": flags,
        "quick": a.quick, "context": ctx,
        "config": {"core": core["config"], "view": view["config"], "server_args": server_args,
                   "schemas": {"zterm-bench": core["schema"], "zterm-viewbench": view["schema"]}},
        "zterm_version": core.get("zterm_version"),
        "inputs": core["inputs"],
        "metrics": {**core["metrics"], **view["metrics"]},
    }

    run_dir = os.path.join(RUNS, f"{datetime.date.today().isoformat()}-{a.label}")
    os.makedirs(run_dir, exist_ok=True)
    report_path = os.path.join(run_dir, f"report-{stamp}.json")
    with open(report_path, "w") as f:
        json.dump(report, f, indent=2)
        f.write("\n")

    table = [f"# zterm bench {stamp} — {ctx['commit']}{' (dirty)' if ctx['dirty'] else ''} on {ctx['machine']}", "",
             f"flags: `{flags}` · power: {ctx['power_profile'] or '?'}, AC={ctx['on_ac']}, governor={ctx['governor']} · "
             f"load {' '.join(ctx['loadavg_start'])} → {' '.join(ctx['loadavg_end'])}", "",
             "| metric | median | min | max | p99 | unit | n |", "|---|---:|---:|---:|---:|---|---:|"]
    for name, m in report["metrics"].items():
        table.append(f"| {name} | {fmt(m['median'])} | {fmt(m['min'])} | {fmt(m['max'])} | {fmt(m['p99'])} | {m['unit']} | {m['n']} |")

    old_path = a.compare or previous_report(report_path)
    regressions = []
    if old_path:
        old, rows, regressions = compare(report, old_path)
        oc = old.get("context", {})
        table += ["", f"## vs {os.path.relpath(old_path, ROOT)} ({oc.get('commit', '?')}, {old.get('flags', '')})", "",
                  f"better/WORSE only when both runs have n >= {MIN_SAMPLES}, the change exceeds {NOISE_PCT:.0f}%, "
                  "and the runs' min..max ranges do not overlap.", "",
                  "| metric | before | after | change | |", "|---|---:|---:|---:|---|"]
        for name, o, n, ch, verdict in rows:
            table.append(f"| {name} | {fmt(o)} | {fmt(n)} | {ch:+.1f}% | {verdict} |")
        if old.get("quick") != report["quick"] or old.get("config", {}).get("schemas") != report["config"]["schemas"]:
            table += ["", "**Not comparable:** the runs differ in --quick or in a benchmark's schema."]
    text = "\n".join(table) + "\n"
    with open(os.path.join(run_dir, f"table-{stamp}.md"), "w") as f:
        f.write(text)
    with open(os.path.join(run_dir, f"stderr-{stamp}.log"), "w") as f:
        f.write("\n".join(log))

    readme = os.path.join(run_dir, "README.md")
    if not os.path.exists(readme):
        with open(readme, "w") as f:
            f.write(f"# {run_dir.rsplit('/', 1)[-1]} — zterm on {ctx['machine']}\n\n"
                    f"{ctx['cpu']} ({ctx['cpu_count']} CPUs, {ctx['mem_gb']} GB), kernel {ctx['kernel']}, zig {ctx['zig']}.\n\n"
                    "Recorded by `scripts/bench-run.py`; the metrics are defined in `src/bench.zig` and "
                    "`src/viewbench.zig`. Each `report-<stamp>.json` holds every sample and the machine state "
                    "at the time (power profile, AC, governor, load before and after).\n\n"
                    "Caveats: timings on a desktop in use are noisy. Read a change against the spread "
                    "(min..max) of both runs, not the medians alone; `--quick` runs are smoke tests.\n")

    new_file = not os.path.exists(BENCH_MD)
    with open(BENCH_MD, "a") as f:
        if new_file:
            f.write("# zterm benchmark runs\n\nOne row per `scripts/bench-run.py` run; the report behind "
                    "each row is `bench/runs/*/report-<stamp>.json`.\n\n")
            f.write("| " + " | ".join(HEADER) + " |\n|" + "---|" * len(HEADER) + "\n")
        cells = [ctx["commit"] + ("+dirty" if ctx["dirty"] else ""), datetime.date.today().isoformat(), ctx["machine"]]
        cells += [fmt(report["metrics"][k]["median"]) if k in report["metrics"] else "" for k, _ in ROW_METRICS]
        cells += [flags, stamp]
        f.write("| " + " | ".join(cells) + " |\n")

    print(text)
    print(f"recorded {os.path.relpath(report_path, ROOT)}")
    if regressions and a.fail_on_regression:
        sys.exit(1)


if __name__ == "__main__":
    main()
