# Guardian Shield — Red-Team Audit

**Scope:** Linux x86_64 daemon surface (`zig_sentinel`, `wardenctl`, `libwarden`, `libwarden_fork`, `input_sovereignty/input-guardian`, `guardian_observer`).
**Out of scope:** `libmacwarden` and `network-filter` (macOS-only). `crucible/`, `gui/`, eBPF C kernel side beyond user-space loaders.
**Build target:** glibc 2.39 / x86_64 / Linux (per `build.zig`). `_FORTIFY_SOURCE=0` is forced for `libwarden*`.

Severity: **CRIT** breaks the security model or yields code-as-root. **HIGH** defeats the stated defense or grants arbitrary file/process actions. **MED** weakens posture, exploitable in narrow conditions. **LOW/INFO** hardening / hygiene.

---

## CRIT-01 — `zig-sentinel` loads eBPF object from a relative path
**File:** `src/zig_sentinel/main.zig:262`
```zig
const bpf_obj_path = "src/zig-sentinel/ebpf/syscall_counter.bpf.o";
```
The daemon runs as root (CAP_BPF + CAP_SYS_ADMIN). The path is *relative*, resolved against the daemon's CWD. Any process that can launch zig-sentinel from a controlled directory — or anyone who places a file at that relative path before launch — gets a malicious eBPF program loaded into the kernel as root.

Note also: there is a name mismatch (`zig-sentinel` vs `zig_sentinel`), so on a clean install this load path **only works when the operator manually puts a `.bpf.o` somewhere on disk**, which is itself an attractive plant point.

**Exploit sketch.** Convince root/init script to `cd /tmp && zig-sentinel …`. Plant `/tmp/src/zig-sentinel/ebpf/syscall_counter.bpf.o` as an arbitrary BPF program with the maps named `syscall_counts`, `grimoire_events`, `monitored_syscalls`, `grimoire_config`. Daemon attaches it as a tracepoint with no further verification → full kernel-level read/write primitive.

**Fix.** Resolve to an absolute, install-time-known path (e.g. `/usr/lib/zig-sentinel/ebpf/syscall_counter.bpf.o`). Open `O_RDONLY|O_NOFOLLOW`, `fstat` it, and refuse non-root-owned or world-writable files. Same fix needed for `guardian_observer.c:162` (CRIT-08).

---

## CRIT-02 — Mass-kill primitive via `@intCast(u32 → i32)` on attacker-influenced PID
**File:** `src/zig_sentinel/main.zig:911` (Grimoire enforce), `src/zig_sentinel/correlation.zig:586` (auto-terminate)
```zig
const kill_result = std.posix.kill(@intCast(result.pid), std.posix.SIG.KILL);
```
`result.pid` is a `u32` consumed from a BPF ring buffer. `std.posix.kill` takes `pid_t` (`i32`). On Linux:
- `kill(0, sig)` → signal **the daemon's own process group** (almost everything if it's pid 1 of a unit).
- `kill(-1, sig)` → signal **every process the caller has permission to** (i.e., as root, the whole system bar pid 1 and itself).
- `kill(<negative>, sig)` → signal entire process group `|pgrp|`.

A `u32` value with the high bit set bitcasts to a negative `i32`. `@intCast` in `ReleaseFast` is undefined behavior on overflow but in practice produces the negative value. So:

1. **PID 0 from ringbuf** (kernel idle/swapper, or trivially craftable in a malicious BPF) → SIGKILL the daemon's process group.
2. **u32 ≥ 0x80000000** → negative pid_t → broadcast SIGKILL to a process group (including `-1`).
3. **PID-reuse TOCTOU**: between the BPF event and `kill()`, the original process may have exited and its PID been reused — so an innocent victim takes the SIGKILL.

`--auto-terminate` and `--grimoire-enforce` flags expose this directly. The Grimoire pattern matcher reads sequences in user-controlled order, meaning a sandboxed process that knows the patterns can frame an arbitrary PID for termination.

**Exploit sketch.** Craft a syscall sequence matching `privesc_setuid_root`, then immediately `exit()` so the kernel reuses your PID for the next forked process — most distros tend to reuse low PIDs quickly under fork pressure. Daemon SIGKILLs the wrong process. Or supply (via a malicious kernel-side BPF, see CRIT-01) `event.pid = 0` to wipe out the daemon's session.

**Fix.**
- Reject `pid <= 1` and `pid > 4_194_304` (Linux `PID_MAX_LIMIT`) before signalling.
- Use a checked cast: `if (result.pid == 0 or result.pid > std.math.maxInt(i32)) return error.BadPid;`.
- Defeat PID reuse: open `/proc/<pid>` (or `pidfd_open(2)`) **at the time the event was raised**, then `pidfd_send_signal` so the kernel guarantees the same process. See `man 2 pidfd_open`.
- Disable `--auto-terminate` / `--grimoire-enforce` unless a stronger identifier (cgroup path, namespace inode, exe inode) matches the original event.

---

## CRIT-03 — `libwarden` can be globally disabled by any unprivileged user
**File:** `src/libwarden/main.zig:193,250-320`
```zig
const EMERGENCY_KILL_SWITCH      = "/tmp/.warden_emergency_disable";
const EMERGENCY_KILL_SWITCH_ROOT = "/var/run/warden_emergency_disable";
```
`shouldBypassAllProtection()` runs **before** any policy lookup. It returns `true` if any of these hold:
1. `WARDEN_DISABLE=1` / `GUARDIAN_SHIELD_DISABLE=1` / `LIBWARDEN_DISABLE=1` in the **process's own** environment.
2. `/tmp/.warden_emergency_disable` exists (sticky bit notwithstanding — any local user can create it).
3. `/proc/cmdline` contains `warden.disable=1`.

The whole point of libwarden's "process restrictions" feature is to constrain *untrusted* processes (per the comments: `python`, `harvester`, `codex-cli`, AI agents). Those processes own their own environment block. They literally only need:
```sh
WARDEN_DISABLE=1 python evil.py
# or
touch /tmp/.warden_emergency_disable && python evil.py
```
to defeat every interceptor (`unlink`, `openat`, `execve`, `chmod`, `symlink`, `link`, `truncate`, `mkdir`, …).

**Exploit sketch.** Sandbox spawns `codex-cli` with libwarden preloaded. codex-cli does `setenv("WARDEN_DISABLE","1",1); unlink("/etc/shadow");` — succeeds. Or a separate user runs `touch /tmp/.warden_emergency_disable` once and every process on the box loses the shield until it's removed.

**Fix.** Two levels:
- The "I might lock myself out" recovery is a real concern, but the kill-switch can't be reachable by the very processes you're trying to constrain. Move the magic file to a path only root can write (`/var/run/warden_emergency_disable` *only*, owned `root:root`, mode `0700` parent dir; remove the `/tmp` variant).
- Drop the env-var override unconditionally. If you need a recovery escape hatch, gate it on `geteuid() == 0` and on a UID-restricted file. Document the kernel-cmdline escape; it's the only one that actually constrains the threat actor (only root can edit cmdline at boot).

---

## CRIT-04 — Process identity is taken from `/proc/self/comm`, which the process owns
**File:** `src/libwarden/main.zig:655` (`getCurrentProcessName`), used by `isProcessExempt` and `getProcessRestrictions`. Same pattern in `src/libwarden_fork/main.zig:131`.
```zig
const fd = c.open("/proc/self/comm", c.O_RDONLY, …);
```
Any process can rewrite its own `comm` with `prctl(PR_SET_NAME, "make")` (or `pthread_setname_np`, or by `argv[0]` rewrite for some kernels). `comm` is up to 16 bytes, but every name in libwarden's `exempt_processes` and `restricted_processes` lists fits.

Two failure modes:
1. **Becoming exempt.** The default exempt list contains build tools (`make`, `cargo`, `rustc`, `gcc`, …). A restricted python process does `prctl(PR_SET_NAME, "make")` and is now exempt from *every* check (`isProcessExempt() ⇒ return state.original_unlink(path)`).
2. **Escaping a restriction.** A restricted process names itself `not-on-the-list` and `getProcessRestrictions()` returns `null`, removing the `block_tmp_execute` / `block_tmp_write` defenses.

The same trick defeats `libwarden_fork`'s "build tool gets 2× rate limit" and the build-tool whitelist for burst detection (`isBuildToolProcess`, `libwarden_fork/main.zig:147`).

**Exploit sketch.** `python -c 'import ctypes; ctypes.CDLL(None).prctl(15, b"cargo", 0,0,0); open("/etc/shadow","r")'` — bypasses the protection that was meant to stop this exact behavior.

**Fix.** Comm is a hint, never a security boundary. Use `/proc/self/exe` (a symlink to the actual executable inode that cannot be forged in-process), and resolve to a **realpath**, then match against full executable paths. Even better: use the underlying file's `(dev, inode)` pair and pin the allow/deny list to inode identity. Note that the executable identity can also be evaded via `execveat(AT_EMPTY_PATH)` from `memfd_create`; for high-assurance you need an LSM, not LD_PRELOAD.

---

## CRIT-05 — Self-preservation substring/prefix bypass in `libwarden`
**File:** `src/libwarden/main.zig:198-213,277-289`
```zig
const SELF_PRESERVATION_PATHS = .{ "/etc/ld.so.preload", "/etc/warden/", "/usr/lib/libwarden", … };
const SELF_PRESERVATION_SUBSTRINGS = .{ "libwarden.so", "warden-config", "ld.so.preload", … };
…
for (SELF_PRESERVATION_PATHS) |safe_path|
    if (std.mem.startsWith(u8, path_slice, safe_path)) return true;
for (SELF_PRESERVATION_SUBSTRINGS) |substring|
    if (std.mem.indexOf(u8, path_slice, substring)) |_| return true;
```
Two compounding problems:

1. **Prefix matches without trailing slash.** `/usr/lib/libwarden` matches `/usr/lib/libwarden_evil/anything`. `/lib/libwarden` matches `/lib/libwardenfoo/cron.d/job`. Attacker creates such a directory and any path inside it bypasses **every** interceptor.
2. **Substring matches anywhere in the path.** `mkdir /tmp/libwarden.so_pwn/` makes `/tmp/libwarden.so_pwn/etc/passwd` count as "self-preservation," disabling all checks for that path. Symbolic-name substrings are a guarantee, not a security boundary.

**Exploit sketch.**
```sh
mkdir /tmp/libwarden.so_pwn
ln -s /etc /tmp/libwarden.so_pwn/etc
# Now writes to /tmp/libwarden.so_pwn/etc/<anything> bypass libwarden,
# and the kernel resolves them to /etc/<anything>.
```

**Fix.**
- Compare full canonicalized paths, not prefixes/substrings. For each "safe" path, build the absolute realpath at init and require equality (or ancestor relationship using path-component matching, not byte-prefix).
- Resolve the user-supplied path with `realpath`/`fstatat(AT_SYMLINK_NOFOLLOW)` before matching. Note this still races (CRIT-06).

---

## CRIT-06 — Path-string interception is bypassed by symlinks and `..` traversal (TOCTOU + literal-string check)
**File:** `src/libwarden/main.zig:801-833` (`isProtectedForOperation`, `isWhitelisted`); applies to every interceptor.
```zig
fn isProtectedForOperation(path: [*:0]const u8, operation: []const u8) bool {
    …
    for (state.protected_paths) |protected|
        if (std.mem.startsWith(u8, path_slice, protected.path)) { … }
}
```
libwarden checks the **literal string** the caller passed, not the inode the kernel will operate on. Two cases:

1. **`..` traversal escape:** a path like `/tmp/../etc/cron.d/x` does **not** start with `/etc/`, so it isn't flagged. The kernel resolves it to `/etc/cron.d/x` and the write proceeds. *No canonicalization happens.* (`config.zig` advertises `canonicalize_paths: bool = true` but it's never read in the hot path.)
2. **Symlink TOCTOU:** even if the literal path looks safe, the attacker can race `open()` between the path check and the actual syscall. Or simpler: drop a symlink ahead of time. `open("/tmp/innocent")` where `/tmp/innocent → /etc/passwd` passes libwarden's checks because `/tmp/` is whitelisted; the kernel then opens `/etc/passwd`.

The whitelist semantics make this worse: `/tmp/` is in the default whitelist (`config.zig:470`), so any symlink under `/tmp` bypasses every protected path.

**Exploit sketch.**
```sh
ln -s /etc/passwd /tmp/passwd
# In a restricted/codex-cli process:
open("/tmp/passwd", O_WRONLY)   # libwarden sees /tmp/ → whitelisted → allowed
                                # kernel writes to /etc/passwd
```

**Fix.** LD_PRELOAD path-string interception is fundamentally insufficient for this threat model. To make it usable you'd need:
- Resolve to an O_PATH fd with `O_NOFOLLOW` at every component, then policy-check via `fstat` and parent-directory chain. This is what AppArmor/SELinux/Landlock do. *Use Landlock.* (`linux/landlock.h`, since 5.13.)
- Until then, document this as best-effort against accidental damage, not against an active attacker. Today the README/banner promises "Path Fortress" — that's overclaim.

---

## CRIT-07 — `input-guardian` writes audit log to `/tmp` while running as root (symlink attack)
**File:** `src/input_sovereignty/input-guardian.zig:415`
```zig
const fp = std.c.fopen("/tmp/input-guardian-alerts.json", "a") orelse return;
```
`fopen("…","a")` calls `open(O_WRONLY|O_CREAT|O_APPEND)` which **follows symlinks**. The daemon needs root for `/dev/input/eventX` (`monitorLinuxDevice` opens with `RDONLY`). Any local user can:
```sh
ln -s /etc/cron.d/zz /tmp/input-guardian-alerts.json
```
before the daemon starts. The daemon then *appends attacker-controlled JSON* (with the `pattern.name` they chose by triggering a forbidden incantation) to `/etc/cron.d/zz` as root → privilege escalation via cron.

`pattern.name` is a hardcoded compile-time string, but the JSON line still contains a controlled timestamp and `enforce` field, plus the attacker chooses which detections fire. Most cron drop-ins with embedded `*/1 * * * * root <cmd>` lines will execute regardless of the surrounding JSON garbage if `<cmd>` ends up on its own line.

**Fix.**
- Path must be admin-controlled (CLI flag or default to `/var/log/input-guardian/alerts.json`), the directory must be `0750 root:root`, and the file must be opened with `O_NOFOLLOW|O_APPEND|O_CLOEXEC` and (for the dir) `O_DIRECTORY|O_NOFOLLOW`.
- Drop privileges (`setresuid` to a service user) immediately after opening `/dev/input/eventX` and the log fd.

---

## CRIT-08 — `guardian-observer.c` mirrors CRIT-01/02 in C
**File:** `src/guardian_observer/guardian-observer.c`
```c
:162  obj = bpf_object__open_file("guardian-observer.bpf.o", NULL); // relative path
:198  __u32 pid = atoi(argv[i]);                                    // silent on garbage
:200  register_agent_process(map_fd, pid);                           // pid==0 ⇒ kernel idle
```
And `src/guardian_observer/guardian-judge.c:98,125`:
```c
kill(pid, SIGKILL);   // PID from BPF event, no validation, no pidfd
kill(pid, SIGSTOP);
```
Same exploit shape: relative BPF path → arbitrary kernel program load; `kill(0, SIGKILL)` from a malformed event SIGKILLs the daemon's own process group; PID reuse races SIGKILL onto innocent processes.

`atoi("0")` returns 0, and `atoi("garbage")` returns 0 silently. Registering pid 0 in the `agent_processes` BPF map (intended as a hashmap-of-monitored-PIDs) generally has the side effect of either no-op (if the BPF lookups skip pid 0) or treating *every kernel context* as "monitored" depending on how the BPF program checks `pid==0`. Read the BPF C side carefully; either way, CLI input handling is broken.

**Fix.**
- Absolute BPF path; `O_NOFOLLOW`; verify owner/mode.
- `strtoul(argv[i], &end, 10)`; validate `end != argv[i]`, `*end == '\0'`, and `1 < pid < PID_MAX_LIMIT`.
- `pidfd_open` + `pidfd_send_signal` per CRIT-02.

---

## CRIT-09 — `libwarden`'s SIGHUP handler does heap allocation (not async-signal-safe)
**File:** `src/libwarden/main.zig:605-629`
```zig
fn sighupHandler(_: c_int) callconv(.c) void {
    …
    const new_config = config_mod.loadConfig(allocator) catch |err| { … };
    state.config = new_config;
}
```
`loadConfig` calls `c.open` → `c.read` → `std.json.parseFromSlice` with `c_allocator` (i.e. `malloc`). `malloc/free` are **not async-signal-safe** (POSIX rationale, glibc explicit). Hardcoded LD_PRELOAD library where the host process can be in the middle of any allocation when SIGHUP arrives → arena lock held → handler tries to take it again → deadlock; or, with non-recursive allocators, **heap corruption** in the host process.

Same applies to `state.config = new_config;` race: the live interceptor threads can be reading `state.config.protected_paths` mid-update. There's no synchronization, just the `reload_in_progress` flag, which doesn't make the assignment atomic for readers.

**Exploit sketch.** Send `wardenctl reload` while the host process (e.g. python) is allocating in interpreter init. glibc's malloc lock is held. The signal handler enters `parseFromSlice` → calls `malloc` → blocks forever. Process hang. With unlucky scheduling, you get heap corruption that's exploitable via the host process's later allocations.

**Fix.** A signal handler must do the minimum: set an `std::atomic<bool> reload_pending = true`. Do the actual reload in the next interceptor entry that observes the flag, *outside* signal context. Use a seqlock / RCU-style swap or a mutex (`pthread_mutex_trylock`) for the config swap, never plain assignment.

---

## HIGH-10 — No privilege drop, no `NO_NEW_PRIVS`, no seccomp, no `DUMPABLE=0`
**Files:** `src/zig_sentinel/main.zig:71+` (`main`), `src/guardian_observer/guardian-observer.c:138+`, `src/input_sovereignty/input-guardian.zig:424+`
None of the daemons:
- call `prctl(PR_SET_NO_NEW_PRIVS, 1)` (so any execve they ever do can re-grant suid).
- call `prctl(PR_SET_DUMPABLE, 0)` (so `/proc/<pid>/mem` and core dumps remain readable by the same UID; not a problem when only root, but becomes one if you ever drop privs).
- install a seccomp filter narrowing the syscalls they can issue (BPF loaders especially benefit).
- drop CAP_BPF/CAP_SYS_ADMIN/UID after attaching their BPF programs / opening their input device. They keep root for the entire monitor lifetime.

Combined with any of CRIT-01/02/07/08 above, "exploit zig-sentinel" → "kernel-level adversary."

**Fix.** After attach:
```c
prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
cap_t caps = cap_get_proc(); cap_clear(caps);
// retain only what's needed (CAP_KILL if you signal, CAP_DAC_READ_SEARCH if you scan procfs)
cap_set_proc(caps);
setresgid(svc_gid, svc_gid, svc_gid);
setgroups(0, NULL);                       // <- before setresuid
setresuid(svc_uid, svc_uid, svc_uid);
prctl(PR_SET_DUMPABLE, 0);
// install seccomp filter
```
Order matters: `setgroups` before `setresuid` (otherwise you can't clear the supplementary groups).

---

## HIGH-11 — `libwarden` config search includes a relative path *and* a hardcoded user home
**File:** `src/libwarden/config.zig:327-332`
```zig
const CONFIG_PATHS = [_][]const u8{
    "/etc/warden/warden-config.json",
    "/forge/config/warden-config-docker-test.json",
    "./config/warden-config.json",
    "/home/founder/zig_forge/config/warden-config.json",
};
```
LD_PRELOAD libraries inherit the host process's CWD. A "restricted" process running in an attacker-controlled directory wins the search by placing its own `config/warden-config.json` with `process_exemptions.exempt_processes = ["python"]` — and now python is exempt. The hardcoded `/home/founder/...` path means a single-user dev box becomes a single point of policy.

**Fix.** Only `/etc/warden/warden-config.json`. Reject any config not owned by `root:root` mode `0644` or stricter; reject any whose parent dir is non-root-writable. Resolve once at init.

---

## HIGH-12 — Baseline / log files written without `O_NOFOLLOW`, attackable by symlinks
**Files:**
- `src/zig_sentinel/baseline.zig:271` (`O_WRONLY|O_CREAT|O_TRUNC`, mode `0o644`, default dir `/var/lib/zig-sentinel/baselines/`).
- `src/zig_sentinel/main.zig:951` (`O_WRONLY|O_CREAT|O_APPEND`, default `/var/log/zig-sentinel/grimoire_alerts.json`).
- `src/zig_sentinel/outputs.zig:283,335` (`createFile`, default `/var/log/zig-sentinel/alerts.json`, plus rename-on-rotation).

Each `mkdir(0o755)` creates the directory if missing. On a fresh install the daemon (running as root) walks into a directory whose ancestors haven't been audited and creates files there. If any ancestor is world-writable (or even attacker-controllable on first install), an attacker pre-positions:
```sh
ln -s /etc/sudoers.d/00-pwn /var/log/zig-sentinel/grimoire_alerts.json
```
Daemon then appends JSON-shaped lines into `/etc/sudoers.d/00-pwn` as root. While sudoers parsers reject malformed lines, the attacker controls `pattern.name` content via crafted hot-pattern matches, and even a partial match like a single line `<garbage>\n%sudo ALL=(ALL) NOPASSWD: ALL` is sometimes accepted. More reliable targets: cron drop-ins, systemd unit fragments, `ld.so.conf.d` files.

`baseline.zig:367` also reads attacker-pointed file: `try ctx.allocator.alloc(u8, file_size)` → memory-exhaustion DoS via a planted sparse multi-TB symlink target.

**Fix.** Open every daemon-managed file with `O_NOFOLLOW`. Open the parent dir with `O_DIRECTORY|O_NOFOLLOW` once, and use `*at(2)` syscalls to operate within. Reject if any ancestor is not `root:root 0755` (or stricter). Cap allocation by `min(file_size, 16 MiB)` for log/baseline reads.

---

## HIGH-13 — `libwarden_fork`: data races on globals, env-var/comm bypass
**File:** `src/libwarden_fork/main.zig:81-94`
```zig
var fork_count_current_second: u32 = 0;
var total_fork_count: u32 = 0;
var burst_forks: [100]i64 = undefined;   // initialized lazily
var burst_index: usize = 0;
```
Plain (non-atomic) global state mutated from `fork()`/`vfork()` interceptors. Multi-threaded host processes (Java VMs, Go runtimes, modern Python with sub-interpreters, anything calling `posix_spawn`) get torn reads/writes — counters drift, threshold checks pass when they shouldn't. In `ReleaseFast`, the compiler may also re-order the increments below the threshold check.

`burst_forks: [100]i64 = undefined` is read by `detectBurstPattern` before being initialized — uninitialized stack/data → false positives or false negatives depending on what the linker put there.

**Bypass:** `SAFE_FORK_OVERRIDE=1` env disables enforcement; `prctl(PR_SET_NAME, "make")` doubles the limit and removes burst detection (`isBuildToolProcess`, line 147).

**Fix.** Use `std.atomic.Value(u32)` everywhere. Initialize `burst_forks` to zeros at first call (or `.{ -1 } ** 100` so uninitialized slots are treated as "before the window"). Drop the env override (or gate on `geteuid()==0`). Identity by exe inode, not comm.

---

## HIGH-14 — `wardenctl reload` SIGHUPs PIDs after a TOCTOU on `/proc/<pid>/maps`
**File:** `src/wardenctl/main.zig:578-606`
```zig
while (try iter.next(io)) |entry| {
    const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;
    …
    if (std.mem.indexOf(u8, content, "libwarden.so") != null) {
        _ = std.os.linux.kill(pid, std.os.linux.SIG.HUP);
    }
}
```
Between reading the maps file and `kill()`, the original process may have exited and the PID been reused by an unrelated daemon. SIGHUP's default action is *terminate*; many daemons ignore or re-init on SIGHUP, but some die. As root, `wardenctl reload` can sporadically kill or reconfigure the wrong process.

When run as a non-root user, `kill` returns EPERM for cross-uid targets — so this is mostly a root-induced DoS issue.

**Fix.** Use `pidfd_open(pid, 0)` *before* the maps check, then `pidfd_send_signal(pidfd, SIGHUP, NULL, 0)`. The kernel will refuse the signal if the PID has been reused.

---

## HIGH-15 — JSON / syslog / auditd messages are built without escaping attacker-influenced strings
**Files:**
- `src/zig_sentinel/main.zig:963` (`logGrimoireMatch`)
- `src/zig_sentinel/outputs.zig:218` (`SyslogOutput.send`)
- `src/zig_sentinel/outputs.zig:292` (`JsonLogOutput.send`)
- `src/zig_sentinel/outputs.zig:475` (`AuditdOutput.send`)
- `src/zig_sentinel/outputs.zig:540` (`WebhookOutput.send`)
- `src/input_sovereignty/input-guardian.zig:402-411`

Example:
```zig
"…\"pid\":{d},\"syscall\":{d},\"z_score\":{d:.2},\"message\":\"{s}\"}}", … alert.message …
```
`alert.message` and similar fields can contain unescaped `"`, `\`, or newlines — leading to broken JSON, log injection, and (at the auditd line) **audit-record forgery** by injecting `\n` and a fake `type=USER_AVC msg=…` line. SIEMs treat the JSON output as authoritative; an attacker who can drive a few alerts can poison the log feed and frame other PIDs.

**Fix.** Use a real JSON encoder (`std.json.Stringify` with `.escape_unicode = false, .escape_solidus = false` — and *let it escape control chars*), not `std.fmt.allocPrint` of a literal-pattern string. For RFC 5424 syslog and auditd, strip / escape control bytes (`\n`, `\r`, `=`, `\"`).

---

## HIGH-16 — `getProcessNamespace` / `isInContainer` always returns false inside a container
**File:** `src/zig_sentinel/grimoire.zig:698-702`
```zig
fn isInContainer(self: *Self, pid: u32) bool {
    const our_ns = self.getProcessNamespace(1) catch 0;  // PID 1 is init in host namespace
    const their_ns = self.getProcessNamespace(pid) catch 0;
    return (our_ns != 0 and their_ns != 0 and our_ns != their_ns);
}
```
The comment is wrong: PID 1 in the daemon's mount namespace is whatever the daemon's PID namespace says it is. Inside a container, that's the container's init, so `our_ns == their_ns` for every process *inside that same container*, and the function reports "not in container." Pattern decisions that rely on `isInContainer` (none currently in `grimoire.zig`, but the helper is exported) are wrong.

Also: `getProcessNamespace(1)` for *any* daemon caller — even outside containers — fails if `/proc/1/ns/pid` requires `CAP_SYS_PTRACE` to readlink and the daemon isn't there (it normally is, as root). `catch 0` then silently broadens the comparison.

**Fix.** Use `/proc/self/ns/pid`, not `/proc/1/ns/pid`. Compare by inode (the namespace's stable ID), via `stat()` on the symlink target, not by parsing the `pid:[N]` string.

---

## MED-17 — Pattern matching by `strstr` is over-broad and trivially evaded
**File:** `src/guardian_observer/guardian-judge.c:28,37`
```c
if (strstr(command, dangerous_patterns[i].pattern)) { … }
```
Patterns include `"rm -rf /"`, `"chmod 000 /"`, `":(){:|:&};:"`, `"curl -X POST"`, `"sudo chmod +s"`, `"chown -R root"`, `"git rebase -i"`, …

False-positive consequences:
- `rm -rf /tmp/foo` contains `rm -rf /` as a substring → SIGKILL.
- A coding agent producing the literal text `"# In a real implementation"` in its output (very common in LLM workflows) → SIGSTOP and frozen process.

False-negatives (actual evasion):
- `eval $'\\x72\\x6d\\x20-rf\\x20/'` doesn't contain `rm -rf /`.
- `bash -c "$(echo 'rm' '-rf' '/')"` likewise.
- Any base64/hex/python `os.system` wrapper.

**Fix.** Substring matching on shell text isn't a security mechanism. Move enforcement to syscall semantics (which BPF already gives you): block `unlinkat(AT_FDCWD, "/", AT_REMOVEDIR)` chains, block `chmod` of `/`, block `mkfs.*` execve patterns based on the resolved binary path (you already have CAP_BPF; this is what eBPF LSM is for).

---

## MED-18 — `getSyscallName` allocates with `page_allocator` and leaks/dangles
**File:** `src/zig_sentinel/main.zig:771-805`
```zig
return std.fmt.allocPrint(std.heap.page_allocator, "sys_{d}", .{nr}) catch "unknown";
```
- The slice escapes the function and is never freed → unbounded growth on a long-running daemon any time it sees an unknown syscall number.
- `page_allocator` rounds every allocation up to a page (4 KiB) and may re-use freed pages → on the next call, the previously returned slice could overlap with whatever the page now backs (in practice unlikely to free, but the lifetime *is* invalid).

**Fix.** Use a fixed lookup table or a static `[64]u8` buffer scoped per-call. Don't return heap-allocated names from a hot per-event display function.

---

## MED-19 — `populateMonitoredSyscalls` count is wrong, inflates "monitoring N syscalls"
**File:** `src/zig_sentinel/main.zig:812-839`
```zig
for (&grimoire.HOT_PATTERNS) |*pattern|
    for (pattern.steps[0..pattern.step_count]) |*step|
        if (step.syscall_nr) |syscall_nr| {
            _ = c.bpf_map_update_elem(map_fd, &key, &val, c.BPF_ANY);
            count += 1;          // counts steps, not unique syscalls
            …
        }
```
`count` is per-step, but the BPF map is a set keyed by syscall_nr. The "Populated N syscall entries" log is misleading. Cosmetic, but operators rely on this log for sanity checks.

**Fix.** Increment only inside the `if (!seen.contains(...))` branch.

---

## MED-20 — `_FORTIFY_SOURCE=0` is unconditionally set for `libwarden*`
**File:** `build.zig:34,49,108,…`
```zig
libwarden.root_module.addCMacro("_FORTIFY_SOURCE", "0");
```
This disables glibc's hardened versions of `memcpy`, `strcpy`, `read`, `open`, etc., which catch many overflow/format bugs at runtime. The note explains it's a translate-c workaround for glibc 2.42+ headers — that's a real bug, but the chosen fix loses hardening for *all* builds, even those targeting glibc 2.39 where the workaround isn't needed. The custom Zig `@cImport` happens to use `unistd.h` / `fcntl.h` / `stdlib.h` only, so most of the fortified guards aren't even on the hot path. Still: any future code added to libwarden won't benefit from FORTIFY.

**Fix.** Either (a) target a fixed glibc explicitly and conditionally enable FORTIFY when the host glibc supports it, (b) avoid `@cImport`-ing the affected headers (write small `extern` declarations by hand for `open`/`read`/`close`/etc.), or (c) when building against glibc ≥ 2.42, confine the workaround to only the headers that need it (`addCMacro` per-cImport, not per-module).

---

## LOW-21 — glibc 2.39 build target on a 2.42+ host: stdc layout fragility
**File:** `build.zig:6-12`
```zig
.glibc_version = .{ .major = 2, .minor = 39, .patch = 0 },
```
The binary is statically tied to glibc 2.39 layouts. When deployed on a host with glibc ≥ 2.42, struct layouts that changed (e.g. `struct sigaction`, locale data, FILE internals) silently shift. The codebase already reports a related bug (V8.2 sigaction crash → switched to portable `signal()`). Other fragile spots:
- `struct iovec` (`grimoire.zig:711-718`) — unchanged across recent glibcs, but the daemon directly hands pointers to `process_vm_readv`, so any ABI change kills it.
- `c.O_*` flag values and `c_int` widths — fine on x86_64.
- `__errno_location()` — returned pointer layout is part of glibc ABI, stable.

Risk is low today, but the bigger meta-risk is that the project tries to paper over Zig translate-c bugs with build flags rather than rewriting the affected code. Each flag silently lowers another guardrail. **Plan a rewrite of the `c.zig` cImport to a hand-curated `extern` interface** for the few symbols actually used; this also fixes MED-20.

---

## LOW-22 — `setEnforcementMode` is exposed without auth
**File:** `src/zig_sentinel/inquisitor.zig:180-192`
The Inquisitor struct exposes `setEnforcementMode(true/false)` and `addBlacklistEntry`. There is no daemon-level authentication on these (they're library functions). Whatever wrapper calls them must enforce its own auth. The blacklist BPF map size is **8** entries (`MAX_BLACKLIST_ENTRIES = 8`) — too small for a serious deny list, and a hint that any production policy would have to fall back to userspace pattern matching (back to MED-17).

**Fix.** Document the threat model (daemon trusts whoever can call its in-process API). For production, expose policy mutations only via an authenticated Unix socket with `SO_PEERCRED` checks and a UID allow-list.

---

## INFO-23 — `correlation` PID-state map is unbounded
**File:** `src/zig_sentinel/correlation.zig:117+` (`process_states` is `AutoHashMap(u32, ProcessExfilState)`). If the daemon runs forever and processes are short-lived, the map grows without GC. Memory exhaustion DoS by spawning many short-lived processes that briefly trigger any tracked syscall. Add a TTL sweep keyed on `last_seen`.

---

## Summary table

| ID | Severity | Component | Issue |
|----|----------|-----------|-------|
| CRIT-01 | crit | zig-sentinel | Relative-path BPF object load as root |
| CRIT-02 | crit | zig-sentinel, correlation | `kill(@intCast(u32→i32))` on attacker-influenced PID; PID-reuse TOCTOU |
| CRIT-03 | crit | libwarden | Env-var / `/tmp` magic-file kill switch |
| CRIT-04 | crit | libwarden, libwarden_fork | Identity from spoofable `/proc/self/comm` |
| CRIT-05 | crit | libwarden | Self-preservation prefix/substring bypass |
| CRIT-06 | crit | libwarden | Path-string check vs symlink/`..` traversal |
| CRIT-07 | crit | input-guardian | `/tmp` audit log followed-symlink → root file write |
| CRIT-08 | crit | guardian-observer | Relative BPF path; `atoi` PID; PID kill TOCTOU |
| CRIT-09 | crit | libwarden | SIGHUP handler does heap allocation |
| HIGH-10 | high | all daemons | No setresuid / NO_NEW_PRIVS / DUMPABLE / seccomp / cap drop |
| HIGH-11 | high | libwarden | Relative + hardcoded `/home/founder/…` config search |
| HIGH-12 | high | zig-sentinel, baseline, outputs | Log/baseline writes without `O_NOFOLLOW` |
| HIGH-13 | high | libwarden_fork | Data races on globals; uninitialized burst array; env/comm bypass |
| HIGH-14 | high | wardenctl | TOCTOU between `/proc/<pid>/maps` and `kill` |
| HIGH-15 | high | outputs, grimoire log | JSON / syslog / auditd injection (no escaping) |
| HIGH-16 | high | grimoire | `isInContainer` uses `/proc/1/ns/pid` (wrong inside containers) |
| MED-17  | med  | guardian-judge | `strstr` pattern matching, false +/− |
| MED-18  | med  | zig-sentinel | `page_allocator` leak in `getSyscallName` |
| MED-19  | med  | zig-sentinel | `populateMonitoredSyscalls` over-counts |
| MED-20  | med  | build.zig | `_FORTIFY_SOURCE=0` for libwarden* |
| LOW-21  | low  | build.zig | glibc 2.39 hardcoded; layout fragility |
| LOW-22  | low  | inquisitor | In-process API has no auth; 8-entry blacklist |
| INFO-23 | info | correlation | Unbounded PID-state map |

## Top-3 fixes to ship first
1. **CRIT-02 + CRIT-08 (PID kill safety):** switch to `pidfd_open` + `pidfd_send_signal`, validate PID range. Without this, the daemon is a remote-mass-kill primitive any time it processes a malformed event.
2. **CRIT-01 + CRIT-08 (BPF path):** absolute path, `O_NOFOLLOW`, owner check. Loading a BPF program is a kernel-privileged action; treat the object file like the kernel module it morally is.
3. **CRIT-03 + CRIT-04 (libwarden bypass):** drop the env-var bypass, move the magic file under root-only paths, identify processes by exe inode not comm. Until this lands, libwarden is theatre against any attacker who reads the source.
