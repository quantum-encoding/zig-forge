#!/usr/bin/env -S python3 -I
"""Benchmark the zdedupe core across commits, and remember the last good one.

  bench.py fixtures                           make the fixture trees (once; kept between runs)
  bench.py run [REF...] [-t T]... [-n N]      time scans with REF's core (default: `.`)
  bench.py compare A B [-t T]...              medians, a verdict per target, same-results check
  bench.py log [-t T] [-l N]                  recent runs on this machine
  bench.py good [REF --note TEXT]             show, or record, the last good commit
  bench.py restore [--apply]                  put the last good core back in programs/zdedupe
  bench.py once PATH... [-- PHASEBENCH-ARGS]  one scan with the working tree's core, its output shown

REF is any zig-forge revision (a sha, HEAD~2, a tag) or `.`: the working tree as it is,
uncommitted edits included. A REF is built from a `git archive` export of that commit, so
benchmarking an old commit never touches the checkout.

Each build is the core as it ships (zig build-lib -OReleaseFast -mcpu baseline with
compiler-rt, the toolchain scripts/zig-toolchain.sh picks), linked into phasebench.c,
which drives a scan through the C API exactly as the apps do. A build is identified by
its source id (scripts/zig-source-id.sh) and toolchain identity, so two commits with the
same core share one build and one history.

Every run is appended to results/<host>.jsonl: wall and CPU time per phase (CPU / wall is
the "cores busy" figure), peak RSS, the load average when it started, and a digest of
what the scan found. `compare` refuses to call a faster build good when its results
differ. good.json holds the last good commit and its numbers; `restore` brings that core
back as a new commit, so whatever was tried since stays in history.

Runs of different builds are interleaved (A B A B ...) after one untimed warm-up per
target, so drift in the machine's state (thermals, other work, the page cache) lands on
every build alike. The numbers are warm-cache: they measure the core, not the disk.
"""
import argparse
import ctypes
import datetime
import hashlib
import json
import os
import platform
import random
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
FORGE = HERE.parent.parent
PROGRAM_REL = "programs/zdedupe"
PROGRAM = FORGE / PROGRAM_REL
HOME = Path(os.environ.get("ZDEDUPE_BENCH_HOME") or Path.home() / ".cache" / "zdedupe-bench")
RESULTS = HERE / "results"
GOOD = HERE / "good.json"
PHASEBENCH_C = HERE / "phasebench.c"
DARWIN = sys.platform == "darwin"

# What the macOS app sets by default (zdedupe-app ScanOptions): hidden files, build output
# and credential stores excluded. A folder comparison sets hidden files only.
APP_FLAGS = {0: ["-H", "-x", "-c"], 1: ["-H"]}

# Bump a fixture's version when its recipe changes; runs on different versions are not compared.
TARGETS = {
    "small": {
        "fixture": "small", "version": 1, "mode": 0, "paths": ["."],
        "desc": "100,000 files of 100 B-48 KiB, 40% duplicates: per-file cost (walk, open, hash)",
    },
    "clones": {
        "fixture": "clones", "version": 1, "mode": 0, "paths": ["."], "darwin": True,
        "desc": "8,000 identical 16 KiB files in 4,000 APFS clone pairs: grouping and clone accounting",
    },
    "medium": {
        "fixture": "medium", "version": 1, "mode": 0, "paths": ["."],
        "desc": "190 files of 1-32 MiB: 60 exact copies, 30 that differ only in their last 4 KiB: whole-file hashing",
    },
    "delete": {
        "fixture": "medium", "version": 2, "mode": 0, "paths": ["."], "copy": True, "flags": ["-D"],
        "desc": "permanent delete of every extra copy in a clone of `medium`, verified by content",
    },
    "big": {
        "fixture": "big", "version": 1, "mode": 0, "paths": ["."],
        "desc": "six 1 GiB files of one size: two identical pairs, one differing at the end, one at the start",
    },
    "compare": {
        "fixture": "compare", "version": 1, "mode": 1, "paths": ["a", "b"],
        "desc": "Compare mode: 20,000 files and four 512 MiB files per side, a few changed, missing or added",
    },
}
# How `fingerprint` digests what a scan found; digests of different versions never compare.
# 2: the scanned roots are replaced by a placeholder first.
FINGERPRINT = 2
FIXTURE_MTIME = 1_700_000_000  # every fixture file gets this mtime, so results do not depend on when it was made


def die(msg):
    print(f"bench: {msg}", file=sys.stderr)
    sys.exit(1)


def sh(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout


def git(*args):
    return sh(["git", "-C", str(FORGE), *args]).strip()


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --- machine and toolchain -------------------------------------------------------

def machine():
    if DARWIN:
        host = sh(["scutil", "--get", "LocalHostName"]).strip()
        cpu = sh(["sysctl", "-n", "machdep.cpu.brand_string"]).strip()
    else:
        host = socket.gethostname().split(".")[0]
        cpu = platform.machine()
        try:
            with open("/proc/cpuinfo") as f:
                cpu = next((l.split(":", 1)[1].strip() for l in f if l.startswith("model name")), cpu)
        except OSError:
            pass
    return {"host": host, "cpu": cpu, "ncpu": os.cpu_count()}


def toolchain(zig_override):
    """(zig path, toolchain identity). The forge's Zig unless --zig names another."""
    script = FORGE / "scripts" / "zig-toolchain.sh"
    if zig_override:
        z = shutil.which(zig_override) or zig_override
        z = str(Path(z).resolve())
        out = sh(["bash", "-c", '. "$1" && printf "%s\\n%s\\n" "$2" "$(forge_zig_id "$2")"', "_", str(script), z])
    else:
        out = sh(["bash", "-c", '. "$1" && forge_zig_require && printf "%s\\n%s\\n" "$ZIG" "$ZIG_TOOLCHAIN_ID"', "_", str(script)])
    zig, ident = out.splitlines()[:2]
    return zig, ident


# --- sources and builds ----------------------------------------------------------

class Build:
    def __init__(self, ref, commit, dirty, source_id, tc_id, zig, src):
        self.ref, self.commit, self.dirty = ref, commit, dirty
        self.source_id, self.toolchain, self.zig, self.src = source_id, tc_id, zig, src
        flags = sha256_bytes(PHASEBENCH_C.read_bytes() + BUILD_FLAGS.encode())
        self.key = sha256_bytes(f"{source_id}\n{tc_id}\n{flags}".encode())[:16]
        self.dir = HOME / "builds" / self.key
        self.bin = self.dir / "phasebench"

    @property
    def label(self):
        if self.ref == ".":
            return f"worktree{'*' if self.dirty else ''}@{self.commit[:8]}"
        return self.commit[:8]


def source_id(program_dir):
    return sh([str(FORGE / "scripts" / "zig-source-id.sh"), str(program_dir)]).strip()


def export(commit, dest):
    """Export the program, and every directory its build reads, as of `commit`."""
    def archive(paths):
        a = subprocess.run(["git", "-C", str(FORGE), "archive", commit, *paths], check=True, capture_output=True)
        subprocess.run(["tar", "-x", "-C", str(dest)], input=a.stdout, check=True)
    archive([PROGRAM_REL])
    deps = sh([str(FORGE / "scripts" / "zig-source-id.sh"), "--deps", str(dest / PROGRAM_REL)]).split()
    outside = sorted({os.path.normpath(f"{PROGRAM_REL}/{d}") for d in deps if d.startswith("..")})
    if outside:
        archive(outside)
    return dest / PROGRAM_REL


def identify(ref, zig_override, scratch):
    zig, tc_id = toolchain(zig_override)
    if ref == ".":
        commit = git("rev-parse", "HEAD")
        dirty = bool(git("status", "--porcelain", "--", PROGRAM_REL))
        src = PROGRAM
    else:
        try:
            commit = git("rev-parse", "--verify", f"{ref}^{{commit}}")
        except subprocess.CalledProcessError:
            die(f"{ref} is not a commit in {FORGE}")
        dirty = False
        src = export(commit, Path(tempfile.mkdtemp(dir=scratch)))
    return Build(ref, commit, dirty, source_id(src), tc_id, zig, src)


BUILD_FLAGS = "-OReleaseFast -mcpu baseline -lc -fcompiler-rt"


def build(b):
    if b.bin.exists():
        return
    arch = {"arm64": "aarch64", "aarch64": "aarch64", "x86_64": "x86_64", "amd64": "x86_64"}[platform.machine().lower()]
    target = f"{arch}-macos" if DARWIN else f"{arch}-linux-gnu"
    tmp = b.dir.with_name(b.dir.name + ".tmp")
    if tmp.exists():
        shutil.rmtree(tmp)
    tmp.mkdir(parents=True)
    lib = tmp / "libzdedupe.a"
    # One cache per toolchain: 0.16 and 0.17 must never share one.
    cache = HOME / "zig-cache" / sha256_bytes(b.toolchain.encode())[:12]
    print(f"bench: building {b.label} ({b.toolchain.split(' + ')[0]})", file=sys.stderr)
    subprocess.run([b.zig, "build-lib", "-target", target, *BUILD_FLAGS.split(), "--name", "zdedupe",
                    "src/lib.zig", f"-femit-bin={lib}", "--cache-dir", str(cache)], cwd=b.src, check=True)
    if DARWIN:
        # As scripts/build-zig-xcframework.sh in tauri_apps/zdedupe ships it: compiler-rt
        # folded into one object exporting only zdedupe_*, so it never clashes with the
        # host's own compiler-rt.
        fold = tmp / "fold"
        fold.mkdir()
        sh(["ar", "x", str(lib)], cwd=fold)
        objs = sorted(str(p) for p in fold.glob("*.o"))
        for o in objs:
            os.chmod(o, 0o644)
        syms = sh(["nm", "-g", "--defined-only", *objs])
        exports = sorted({l.split()[2] for l in syms.splitlines() if len(l.split()) == 3 and l.split()[2].startswith("_zdedupe_")})
        (fold / "exports.txt").write_text("\n".join(exports) + "\n")
        sh(["ld", "-r", "-o", str(fold / "merged.o"), *objs, "-exported_symbols_list", str(fold / "exports.txt")])
        lib.unlink()
        sh(["libtool", "-static", "-o", str(lib), str(fold / "merged.o")])
        shutil.rmtree(fold)
        link = ["-framework", "Security", "-framework", "CoreFoundation"]
    else:
        link = ["-lpthread", "-lm"]
    sh(["cc", "-O2", "-o", str(tmp / "phasebench"), str(PHASEBENCH_C), str(lib), *link])
    (tmp / "build.json").write_text(json.dumps({
        "ref": b.ref, "commit": b.commit, "dirty": b.dirty, "source_id": b.source_id,
        "toolchain": b.toolchain, "flags": BUILD_FLAGS, "target": target, "built_at": now_iso(),
    }, indent=2) + "\n")
    if b.dir.exists():
        shutil.rmtree(b.dir)
    tmp.rename(b.dir)


# --- fixtures --------------------------------------------------------------------

def fixture_dir(name):
    return HOME / "fixtures" / name


def remove(path):
    """To the Trash where `trash` exists (a fixture can be large and slow to remake)."""
    if shutil.which("trash"):
        subprocess.run(["trash", str(path)], check=True)
    elif path.is_dir():
        shutil.rmtree(path)
    else:
        path.unlink()


def write_fixed(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def pin_mtimes(root):
    for dirpath, _, files in os.walk(root):
        for n in files:
            os.utime(os.path.join(dirpath, n), (FIXTURE_MTIME, FIXTURE_MTIME), follow_symlinks=False)


def clonefile(src, dst):
    libc = ctypes.CDLL("libc.dylib", use_errno=True)
    if libc.clonefile(str(src).encode(), str(dst).encode(), 0) != 0:
        raise OSError(ctypes.get_errno(), f"clonefile {src} -> {dst}")


def make_small(root):
    subprocess.run([sys.executable, "-I", str(HERE / "mkfixture.py"), str(root), "100000"], check=True)


def make_clones(root):
    # One content, so one duplicate group; 4,000 independent copies, each with one APFS
    # clone. Every file has the same mtime, so the group's order is by path: all copies,
    # then all clones - each copy opens a new clone class.
    data = random.Random(2).randbytes(16 * 1024)
    for i in range(4000):
        write_fixed(root / "copies" / f"c{i:05d}", data)
    (root / "clones").mkdir()
    for i in range(4000):
        clonefile(root / "copies" / f"c{i:05d}", root / "clones" / f"k{i:05d}")


def make_medium(root):
    # Below chunked.zig's 64 MiB, so every candidate is hashed whole by the
    # parallel hasher; the near copies share a size and first MiB with an
    # original, so only a full hash tells them apart.
    rng = random.Random(8)
    originals = []
    for i in range(100):
        data = rng.randbytes(rng.randint(1 << 20, 32 << 20))
        write_fixed(root / "originals" / f"o{i:03d}.bin", data)
        originals.append(data)
    for i in range(60):
        write_fixed(root / "copies" / f"c{i:03d}.bin", originals[i])
    for i in range(30):
        data = originals[60 + i]
        write_fixed(root / "near" / f"n{i:03d}.bin", data[:-4096] + bytes(b ^ 0xA5 for b in data[-4096:]))


def make_big(root):
    # a1 = a2 and b1 = b2; c is a1 with its last 64 KiB changed (read to the end before it
    # differs), d is b1 with its first 4 KiB changed (differs at once).
    chunk, chunks = 64 << 20, 16
    rng = random.Random(3)
    names = ["a1", "a2", "c", "b1", "b2", "d"]
    root.mkdir(parents=True, exist_ok=True)
    files = {n: open(root / f"{n}.bin", "wb") for n in names}
    try:
        for j in range(chunks):
            x, y = rng.randbytes(chunk), rng.randbytes(chunk)
            files["a1"].write(x)
            files["a2"].write(x)
            files["c"].write(x if j < chunks - 1 else x[:-65536] + bytes(b ^ 0xFF for b in x[-65536:]))
            files["b1"].write(y)
            files["b2"].write(y)
            files["d"].write(y if j > 0 else bytes(b ^ 0xFF for b in y[:4096]) + y[4096:])
    finally:
        for f in files.values():
            f.close()


def make_compare(root):
    a, b = root / "a", root / "b"
    subprocess.run([sys.executable, "-I", str(HERE / "mkfixture.py"), str(a), "20000"], check=True)
    rng = random.Random(4)
    (a / "big").mkdir()
    for i in range(4):
        with open(a / "big" / f"{i}.bin", "wb") as f:
            for _ in range(8):
                f.write(rng.randbytes(64 << 20))
    if DARWIN:
        subprocess.run(["cp", "-c", "-R", str(a), str(b)], check=True)
    else:
        subprocess.run(["cp", "-R", "--reflink=auto", str(a), str(b)], check=True)
    files = sorted(p for p in b.rglob("*.dat"))
    picks = random.Random(5).sample(files, 20)
    for p in picks[:10]:  # modified: same size, different bytes
        data = p.read_bytes()
        p.write_bytes(bytes(x ^ 0x5A for x in data))
    for p in picks[10:15]:  # only in a
        p.unlink()
    for i in range(5):  # only in b
        write_fixed(b / "added" / f"n{i}.dat", random.Random(6 + i).randbytes(1000 + i))
    with open(b / "big" / "3.bin", "r+b") as f:  # modified at its very end
        f.seek(-1, os.SEEK_END)
        last = f.read(1)
        f.seek(-1, os.SEEK_END)
        f.write(bytes([last[0] ^ 1]))


MAKERS = {"small": make_small, "clones": make_clones, "medium": make_medium, "big": make_big, "compare": make_compare}


def ensure_fixture(t):
    spec = TARGETS[t]
    if spec["fixture"] != t:  # a target that runs on another's fixture
        return ensure_fixture(spec["fixture"])
    root = fixture_dir(spec["fixture"])
    stamp = root.with_name(root.name + ".version")
    if root.exists() and stamp.exists() and stamp.read_text().strip() == str(spec["version"]):
        return root
    if spec.get("darwin") and not DARWIN:
        return None
    (HOME / "fixtures").mkdir(parents=True, exist_ok=True)
    (HOME / "fixtures" / ".metadata_never_index").touch()  # keep Spotlight out of the timings
    for old in (root, stamp):
        if old.exists():
            remove(old)
    tmp = root.with_name(root.name + ".tmp")
    if tmp.exists():
        shutil.rmtree(tmp)
    print(f"bench: making fixture {spec['fixture']}: {spec['desc']}", file=sys.stderr)
    MAKERS[spec["fixture"]](tmp)
    pin_mtimes(tmp)
    tmp.rename(root)
    stamp.write_text(f"{spec['version']}\n")
    return root


# --- running ---------------------------------------------------------------------

def target_spec(name, args):
    if name.startswith("path:"):
        return {"mode": 0, "paths": [name[5:]], "version": 0, "desc": f"real tree {name[5:]}"}
    if name.startswith("compare:"):
        a, b = name[8:].split("|", 1)
        return {"mode": 1, "paths": [a, b], "version": 0, "desc": f"compare {a} with {b}"}
    spec = TARGETS[name]
    root = ensure_fixture(name)
    if root is None:
        return None
    return {**spec, "root": str(root), "paths": [str(root / p) if p != "." else str(root) for p in spec["paths"]]}


def fingerprint(mode, export_path, overview, roots=()):
    """What a scan found, comparable across builds and runs: the scanned roots are
    replaced by a placeholder, so a run on a fresh clone of a fixture matches another."""
    if not export_path.exists():
        return None
    if mode == 1:
        rep = json.loads(export_path.read_text())
        lists = {k: sorted(rep.get(k, [])) for k in ("identical", "only_in_a", "only_in_b", "modified")}
        return {"digest": sha256_bytes(json.dumps(lists, sort_keys=True).encode())[:16],
                **{f"{k}_count": len(v) for k, v in lists.items()}}
    text = export_path.read_text(errors="surrogateescape")
    # With folder analysis, phasebench also writes every identical set and overlapping pair.
    dirs = export_path.with_name(export_path.name + ".dirs")
    if dirs.exists():
        text += dirs.read_text(errors="surrogateescape")
    for root in sorted(roots, key=len, reverse=True):
        text = text.replace(root, "<root>")
    out = {"digest": sha256_bytes(text.encode(errors="surrogateescape"))[:16]}
    for k in ("files_scanned", "duplicate_groups", "duplicate_files", "space_savings", "identical_sets"):
        if overview and k in overview:
            out[k] = overview[k]
    return out


def run_detached(cmd, rundir, timeout):
    """Run `cmd` as a launchd job, outside this process tree, and wait for it.

    An Endpoint Security client may authorize the opens of an agent's process tree on a
    slower path than an app's; a launchd job is timed the way the app is."""
    label = f"io.quantumencoding.zdedupe-bench.{os.getpid()}.{int(time.time() * 1000)}"
    script = rundir / "job.sh"
    script.write_text("#!/bin/sh\n" + " ".join(f"'{c}'" for c in cmd) +
                      f" > '{rundir}/stdout' 2> '{rundir}/stderr'\necho $? > '{rundir}/rc'\n")
    script.chmod(0o755)
    subprocess.run(["launchctl", "submit", "-l", label, "--", str(script)], check=True)
    deadline = time.time() + timeout
    try:
        while not (rundir / "rc").exists():
            if time.time() > deadline:
                return None
            time.sleep(0.2)
        return int((rundir / "rc").read_text().strip() or 1)
    finally:
        subprocess.run(["launchctl", "remove", label], capture_output=True)


def wait_quiet(args):
    """With --quiet, wait (up to --quiet-wait seconds) for the 1-minute load average
    to fall under the threshold; a shared machine's other work otherwise shows up
    as noise. Returns the seconds waited."""
    if not args.quiet:
        return 0.0
    t0 = time.time()
    told = False
    while os.getloadavg()[0] > args.quiet and time.time() - t0 < args.quiet_wait:
        if not told:
            print(f"bench: waiting for load < {args.quiet} (now {os.getloadavg()[0]:.1f})", file=sys.stderr, flush=True)
            told = True
        time.sleep(5)
    if os.getloadavg()[0] > args.quiet:
        # A run under this load would only be left out of every verdict later.
        die(f"load still {os.getloadavg()[0]:.1f} after {args.quiet_wait:.0f}s of waiting for < {args.quiet}; "
            "stopped (the runs recorded so far stay)")
    return round(time.time() - t0, 1)


def run_one(b, name, spec, round_no, args):
    waited = wait_quiet(args)
    rundir = Path(tempfile.mkdtemp(dir=HOME / "runs"))
    try:
        flags = list(APP_FLAGS[spec["mode"]]) + (["-d"] if args.dirs and spec["mode"] == 0 else []) + spec.get("flags", [])
        paths = spec["paths"]
        if spec.get("copy"):
            # A target that destroys what it scans gets a fresh APFS clone (a plain copy
            # elsewhere) of its fixture: cheap, and its files are no clones of each other.
            # Timestamps are kept, or every copy would digest differently (the export
            # carries each file's mtime).
            copy = rundir / "tree"
            cp = ["cp", "-c", "-R", "-p"] if DARWIN else ["cp", "-a", "--reflink=auto"]
            subprocess.run([*cp, spec["root"], str(copy)], check=True)
            paths = [str(copy / os.path.relpath(p, spec["root"])) for p in paths]
        cmd = [str(b.bin), "-m", str(spec["mode"]), *flags, "-o", str(rundir / "store.bin"),
               "-J", str(rundir / "result.json"), "-E", str(rundir / "export"), *paths]
        load = os.getloadavg()[0]
        timed_out = False
        if args.detached and DARWIN:
            rc = run_detached(cmd, rundir, args.timeout)
            timed_out = rc is None
        else:
            try:
                p = subprocess.run(cmd, capture_output=True, text=True, timeout=args.timeout)
                rc = p.returncode
                (rundir / "stderr").write_text(p.stderr)
            except subprocess.TimeoutExpired:
                timed_out, rc = True, None
        rec = {
            "at": now_iso(), **MACHINE, "ref": b.ref, "commit": b.commit, "dirty": b.dirty,
            "source_id": b.source_id, "toolchain": b.toolchain, "build": b.key,
            "target": name, "fixture_version": spec["version"], "flags": flags,
            "detached": bool(args.detached and DARWIN), "round": round_no, "load": round(load, 2),
            "waited_s": waited, "fingerprint": FINGERPRINT,
        }
        if timed_out:
            return {**rec, "rc": None, "timeout": True, "wall_s": float(args.timeout)}
        res_path = rundir / "result.json"
        if not res_path.exists():
            err = (rundir / "stderr").read_text()[-400:] if (rundir / "stderr").exists() else ""
            return {**rec, "rc": rc, "timeout": False, "error": err}
        r = json.loads(res_path.read_text())
        phases = {p["name"]: {"wall_s": round(p["wall_s"], 4), "cpu_s": round(p["cpu_s"], 4),
                              "sys_s": round(p.get("sys_s", 0.0), 4),
                              "cores": round(p["cpu_s"] / p["wall_s"], 2) if p["wall_s"] > 0 else 0.0}
                  for p in r["phases"]}
        result = fingerprint(spec["mode"], rundir / "export", r.get("overview"), paths)
        wall, cpu, sys_s = r["wall_s"], r["cpu_s"], r.get("sys_s", 0.0)
        if "delete" in r:
            d = r["delete"]
            phases["delete"] = {"wall_s": round(d["wall_s"], 4), "cpu_s": round(d["cpu_s"], 4), "sys_s": round(d["sys_s"], 4),
                                "cores": round(d["cpu_s"] / d["wall_s"], 2) if d["wall_s"] > 0 else 0.0}
            # A delete target is judged on scan and delete together.
            wall, cpu, sys_s = wall + d["wall_s"], cpu + d["cpu_s"], sys_s + d["sys_s"]
            rep = d.get("report") or {}
            if result is not None:
                result = {**result, **{f"delete_{k}": rep.get(k) for k in ("deleted", "skipped_changed", "failed_count")}}
                result["digest"] = sha256_bytes((result["digest"] + json.dumps(
                    [rep.get("deleted"), rep.get("skipped_changed"), rep.get("failed_count")])).encode())[:16]
        return {**rec, "rc": r["rc"], "timeout": False, "wall_s": round(wall, 4), "cpu_s": round(cpu, 4),
                "sys_s": round(sys_s, 4), "cores": round(cpu / wall, 2) if wall > 0 else 0.0,
                "maxrss_mb": r["maxrss_mb"], "phases": phases, "result": result}
    finally:
        shutil.rmtree(rundir, ignore_errors=True)


def ledger_path():
    return RESULTS / f"{MACHINE['host']}.jsonl"


def append_ledger(rec):
    RESULTS.mkdir(exist_ok=True)
    with open(ledger_path(), "a") as f:
        f.write(json.dumps(rec, sort_keys=True) + "\n")


def read_ledger():
    p = ledger_path()
    if not p.exists():
        return []
    return [json.loads(l) for l in p.read_text().splitlines() if l.strip()]


def describe_run(rec):
    if rec.get("timeout"):
        return f"TIMEOUT after {rec['wall_s']:.0f}s"
    if "error" in rec or rec.get("rc") not in (0,):
        return f"FAILED rc={rec.get('rc')} {rec.get('error', '')[-200:]}"
    ph = "  ".join(f"{n} {p['wall_s']:.2f}s/{p['cores']:.1f}c" for n, p in rec["phases"].items())
    return f"{rec['wall_s']:8.2f}s  {rec['cores']:5.2f} cores  {rec['maxrss_mb']:7.0f} MB   {ph}"


def cmd_run(args):
    targets = args.target or [t for t in TARGETS if DARWIN or not TARGETS[t].get("darwin")]
    targets += [f"path:{os.path.abspath(p)}" for p in args.path or []]
    if args.compare_paths:
        targets.append(f"compare:{os.path.abspath(args.compare_paths[0])}|{os.path.abspath(args.compare_paths[1])}")
    for t in targets:
        if not (t in TARGETS or t.startswith(("path:", "compare:"))):
            die(f"no target {t} (have: {', '.join(TARGETS)}; or --path / --compare-paths)")
    (HOME / "runs").mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(dir=HOME / "runs"))
    try:
        builds = [identify(r, args.zig, scratch) for r in (args.refs or ["."])]
        for b in builds:
            build(b)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    started = now_iso()
    load = os.getloadavg()[0]
    if load > (os.cpu_count() or 1) * 0.25 and not args.quiet:
        print(f"bench: load average is {load:.1f} on {os.cpu_count()} CPUs; other work will show in the timings (--quiet waits)", file=sys.stderr)
    for t in targets:
        spec = target_spec(t, args)
        if spec is None:
            print(f"bench: {t}: not on this platform", file=sys.stderr)
            continue
        print(f"\n== {t}: {spec['desc']}")
        run_one(builds[0], t, spec, -1, args)  # warm-up: page cache, directory caches; not recorded
        for i in range(args.runs):
            order = builds[i % len(builds):] + builds[:i % len(builds)]
            for b in order:
                rec = run_one(b, t, spec, i, args)
                append_ledger(rec)
                print(f"  {b.label:22} run {i + 1}: {describe_run(rec)}", flush=True)
    if len(builds) >= 2:
        print()
        # This invocation's runs only: interleaved, so under the same conditions.
        report(builds[0], builds[-1], targets, since=started, dirs=args.dirs)
    print(f"\nbench: runs recorded in {ledger_path().relative_to(FORGE)}")


# --- comparing -------------------------------------------------------------------

def target_mode(name):
    if name in TARGETS:
        return TARGETS[name]["mode"]
    return 1 if name.startswith("compare:") else 0


def runs_of(b, target, ledger=None, since=None, max_load=None, detached=False, dirs=False):
    """Recorded runs of build `b` on `target`, launched the same way (in this process
    tree, or `detached`) and with folder analysis on or off (`dirs`): from `since` (an
    ISO time) on, and started at a load average of at most `max_load`, when given."""
    ledger = read_ledger() if ledger is None else ledger
    spec_v = TARGETS[target]["version"] if target in TARGETS else 0
    return [r for r in ledger if r["source_id"] == b.source_id and r["toolchain"] == b.toolchain
            and r["target"] == target and r.get("fixture_version") == spec_v and r.get("round", 0) >= 0
            and bool(r.get("detached")) == detached
            # Folder analysis is a duplicates-scan option; a folder comparison never takes it.
            and (target_mode(target) != 0 or ("-d" in r.get("flags", [])) == dirs)
            and (since is None or r["at"] >= since) and (max_load is None or r.get("load", 0) <= max_load)]


def summarize(runs):
    ok = [r for r in runs if r.get("rc") == 0 and not r.get("timeout")]
    timeouts = [r for r in runs if r.get("timeout")]
    if not ok:
        return {"n": 0, "timeouts": len(timeouts), "failed": len(runs) - len(timeouts)}
    walls = [r["wall_s"] for r in ok]
    med = statistics.median(walls)
    phases = {}
    for r in ok:
        for n, p in r["phases"].items():
            phases.setdefault(n, []).append((p["wall_s"], p["cores"]))
    return {
        "n": len(ok), "timeouts": len(timeouts), "failed": len(runs) - len(ok) - len(timeouts),
        "wall_s": med, "spread": (max(walls) - min(walls)) / med if med > 0 else 0.0,
        "cores": statistics.median(r["cores"] for r in ok),
        "maxrss_mb": statistics.median(r["maxrss_mb"] for r in ok),
        "phases": {n: {"wall_s": statistics.median(w for w, _ in v), "cores": statistics.median(c for _, c in v)}
                   for n, v in phases.items()},
        "digests": sorted({(r.get("result") or {}).get("digest") for r in ok if r.get("fingerprint", 1) == FINGERPRINT} - {None}),
    }


def verdict(a, b):
    """(text, regressed) for build b against build a on one target."""
    if a["n"] == 0 or b["n"] == 0:
        if b.get("timeouts") and a["n"]:
            return "REGRESSION (timed out)", True
        if a.get("timeouts") and b["n"]:
            return "faster (A timed out)", False
        return "no runs to compare", False
    delta = (b["wall_s"] - a["wall_s"]) / a["wall_s"]
    noise = max(0.05, a["spread"], b["spread"])
    few = " (fewer than 3 runs)" if min(a["n"], b["n"]) < 3 else ""
    if delta > noise:
        return f"REGRESSION {delta:+.1%}{few}", True
    if delta < -noise:
        return f"faster {delta:+.1%}{few}", False
    return f"same within noise ({delta:+.1%}, noise {noise:.0%}){few}", False


def report(a, b, targets, since=None, max_load=None, dirs=False):
    ledger = read_ledger()
    bad = False
    scope = f"runs since {since}" if since else "all recorded runs"
    if max_load is not None:
        scope += f" started at load <= {max_load:g}"
    print(f"A = {a.label} ({a.ref})   B = {b.label} ({b.ref})   on {MACHINE['host']} ({MACHINE['cpu']}); {scope}")
    for t in targets:
        sa = summarize(runs_of(a, t, ledger, since, max_load, dirs=dirs))
        sb = summarize(runs_of(b, t, ledger, since, max_load, dirs=dirs))
        if max_load is not None:
            left_out = len(runs_of(a, t, ledger, since, dirs=dirs)) + len(runs_of(b, t, ledger, since, dirs=dirs)) - sa["n"] - sb["n"] \
                - sa.get("timeouts", 0) - sb.get("timeouts", 0) - sa.get("failed", 0) - sb.get("failed", 0)
            if left_out:
                print(f"  {t}: {left_out} run(s) started above load {max_load:g} left out")
        text, regressed = verdict(sa, sb)
        same = "results: n/a"
        if sa["n"] and sb["n"] and not (sa["digests"] and sb["digests"]):
            same = "results: n/a (no runs with the current fingerprint on one side)"
        elif sa["n"] and sb["n"]:
            if sa["digests"] == sb["digests"] and len(sa["digests"]) == 1:
                same = "results: same"
            elif t not in TARGETS:
                same = "results: differ (a real tree can change between runs)"
            else:
                same = "results: DIFFER"
                regressed = True
        bad |= regressed
        def col(s):
            if not s["n"]:
                return f"{'timeout' if s.get('timeouts') else 'no runs':>22}"
            return f"{s['wall_s']:8.2f}s ±{s['spread']:4.0%} {s['cores']:5.2f}c n={s['n']}"
        print(f"  {t:12} A {col(sa)}   B {col(sb)}   {text}; {same}")
        if sa["n"] and sb["n"]:
            for n in sb["phases"]:
                pa, pb = sa["phases"].get(n), sb["phases"][n]
                if pa and max(pa["wall_s"], pb["wall_s"]) >= 0.05:
                    print(f"      {n:11} {pa['wall_s']:8.3f}s {pa['cores']:5.2f}c  ->  {pb['wall_s']:8.3f}s {pb['cores']:5.2f}c")
    return bad


def cmd_compare(args):
    (HOME / "runs").mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(dir=HOME / "runs"))
    try:
        a, b = identify(args.a, args.zig, scratch), identify(args.b, args.zig_b or args.zig, scratch)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    ledger = read_ledger()
    targets = args.target or sorted({r["target"] for r in ledger if r["source_id"] in (a.source_id, b.source_id)})
    if not targets:
        die(f"no runs recorded for {a.label} or {b.label}: `bench.py run {args.a} {args.b}` first")
    max_load = None if args.max_load < 0 else (args.max_load if args.max_load else (os.cpu_count() or 1) * 0.25)
    sys.exit(1 if report(a, b, targets, since=args.since, max_load=max_load, dirs=args.dirs) else 0)


def cmd_log(args):
    rows = [r for r in read_ledger() if not args.target or r["target"] in args.target]
    for r in rows[-args.limit:]:
        label = f"{'worktree*' if r['dirty'] else r['commit'][:8]}"
        print(f"{r['at']}  {label:10} {r['target']:10} {describe_run(r)}")


# --- last good -------------------------------------------------------------------

def cmd_good(args):
    if not args.ref:
        if not GOOD.exists():
            print("no last good commit recorded yet: `bench.py good <ref> --note '...'` after a run")
            return
        g = json.loads(GOOD.read_text())
        print(f"last good: {g['commit']}  marked {g['marked_at']} on {g['marked_on']}\n  {g['note']}")
        for host, targets in g["baselines"].items():
            for t, s in targets.items():
                print(f"  {host:16} {t:10} {s['wall_s']:8.2f}s  {s['cores']:5.2f} cores  n={s['n']}  results {s['digest']}")
        since = git("log", "--oneline", f"{g['commit']}..HEAD", "--", PROGRAM_REL)
        print(f"\nprograms/zdedupe since then:\n{since or '  (no changes)'}")
        return
    if args.ref == ".":
        die("mark a commit, not the working tree: commit the change first")
    if not args.note:
        die("say why it is good: --note '...'")
    (HOME / "runs").mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(dir=HOME / "runs"))
    try:
        b = identify(args.ref, args.zig, scratch)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    ledger = read_ledger()
    base = {}
    quiet = (os.cpu_count() or 1) * 0.25  # a loaded run is no baseline
    for t in sorted({r["target"] for r in ledger}):
        s = summarize(runs_of(b, t, ledger, max_load=quiet))
        if s["n"]:
            base[t] = {"wall_s": round(s["wall_s"], 4), "cores": round(s["cores"], 2), "n": s["n"],
                       "digest": s["digests"][0] if len(s["digests"]) == 1 else None}
    if not base:
        die(f"no runs of {b.label} on this machine: `bench.py run {args.ref}` first")
    old = json.loads(GOOD.read_text()) if GOOD.exists() else {}
    baselines = old.get("baselines", {}) if old.get("commit") == b.commit else {}
    baselines[MACHINE["host"]] = base
    GOOD.write_text(json.dumps({
        "commit": b.commit, "source_id": b.source_id, "toolchain": b.toolchain,
        "marked_at": now_iso(), "marked_on": MACHINE["host"], "note": args.note, "baselines": baselines,
    }, indent=2) + "\n")
    print(f"bench: {b.commit[:12]} recorded as last good in {GOOD.relative_to(FORGE)}; commit and push it")


def cmd_restore(args):
    if not GOOD.exists():
        die("no last good commit recorded (bench.py good)")
    g = json.loads(GOOD.read_text())
    commit = g["commit"]
    head_tree, good_tree = git("rev-parse", f"HEAD:{PROGRAM_REL}"), git("rev-parse", f"{commit}:{PROGRAM_REL}")
    print(f"last good: {commit[:12]} ({g['marked_at']}): {g['note']}")
    if head_tree == good_tree:
        print("HEAD's programs/zdedupe is already that core; nothing to restore")
        return
    print(f"programs/zdedupe since then:\n{git('log', '--oneline', f'{commit}..HEAD', '--', PROGRAM_REL)}")
    steps = [
        ["git", "-C", str(FORGE), "restore", f"--source={commit}", "--staged", "--worktree", "--", PROGRAM_REL],
        ["git", "-C", str(FORGE), "commit", "-m", f"zdedupe: restore the core to {commit[:12]}, the last good bench ({g['note']})"],
    ]
    if not args.apply:
        print("\nto restore it as a new commit (what was tried since stays in history):")
        for s in steps:
            print("  " + " ".join(f"'{x}'" if " " in x else x for x in s))
        print("  then push, and vendor it in tauri_apps/zdedupe: scripts/vendor-core.sh HEAD")
        print("or run `bench.py restore --apply` to stage it")
        return
    if git("status", "--porcelain", "--", PROGRAM_REL):
        die("programs/zdedupe has uncommitted changes; commit or set them aside first")
    subprocess.run(steps[0], check=True)
    print(git("status", "--short", "--", PROGRAM_REL))
    print(f"\nstaged. Commit with:\n  {' '.join(steps[1][:4])} -m \"{steps[1][5]}\"")


def cmd_fixtures(args):
    for t in TARGETS:
        root = ensure_fixture(t)
        print(f"{t:10} {root if root else 'not on this platform'}")


def cmd_once(args):
    (HOME / "runs").mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(dir=HOME / "runs"))
    try:
        b = identify(".", args.zig, scratch)
        build(b)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    cut = args.args.index("--") if "--" in args.args else len(args.args)
    paths, extra = args.args[:cut], args.args[cut + 1:]
    if not paths:
        die("once: name at least one path")
    os.execv(str(b.bin), [str(b.bin), *extra, *paths])


def main():
    global MACHINE
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zig", help="build with this Zig instead of the forge's (an old commit may need 0.16)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("fixtures")
    p.set_defaults(fn=cmd_fixtures)
    p = sub.add_parser("run")
    p.add_argument("refs", nargs="*")
    p.add_argument("-t", "--target", action="append", help=f"one of {', '.join(TARGETS)} (default: all)")
    p.add_argument("-p", "--path", action="append", help="also scan this real tree for duplicates")
    p.add_argument("--compare-paths", nargs=2, metavar=("A", "B"), help="also compare these two real folders")
    p.add_argument("-n", "--runs", type=int, default=3)
    p.add_argument("--timeout", type=float, default=900)
    p.add_argument("--dirs", action="store_true", help="duplicate scans also analyze folders")
    p.add_argument("--detached", action="store_true", help="run each scan as a launchd job, outside this process tree (macOS)")
    p.add_argument("--quiet", type=float, metavar="LOAD", help="before each run, wait for the 1-minute load average to fall under LOAD")
    p.add_argument("--quiet-wait", type=float, default=900,
                   help="longest wait for --quiet, in seconds (default 900); past it the bench stops")
    p.set_defaults(fn=cmd_run)
    p = sub.add_parser("compare")
    p.add_argument("a")
    p.add_argument("b")
    p.add_argument("-t", "--target", action="append")
    p.add_argument("--zig-b", help="B was built with this Zig")
    p.add_argument("--since", help="only runs from this ISO time on (e.g. 2026-10-16T17:00)")
    p.add_argument("--dirs", action="store_true", help="the runs made with folder analysis (run --dirs)")
    p.add_argument("--max-load", type=float, default=0,
                   help="leave out runs started above this load average (default: a quarter of the CPUs; -1 keeps all)")
    p.set_defaults(fn=cmd_compare)
    p = sub.add_parser("log")
    p.add_argument("-t", "--target", action="append")
    p.add_argument("-l", "--limit", type=int, default=30)
    p.set_defaults(fn=cmd_log)
    p = sub.add_parser("good")
    p.add_argument("ref", nargs="?")
    p.add_argument("--note")
    p.set_defaults(fn=cmd_good)
    p = sub.add_parser("restore")
    p.add_argument("--apply", action="store_true")
    p.set_defaults(fn=cmd_restore)
    p = sub.add_parser("once")
    p.add_argument("args", nargs=argparse.REMAINDER, help="PATH... [-- PHASEBENCH-ARGS]")
    p.set_defaults(fn=cmd_once)
    args = ap.parse_args()
    MACHINE = machine()
    args.fn(args)


if __name__ == "__main__":
    main()
