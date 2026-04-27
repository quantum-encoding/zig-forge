# zigix_monitor — Security Audit Findings

**Scope.** TUI dashboard reading system-wide `/proc` files (no per-PID reads). Single
process, single thread, c_allocator. No IPC sockets, no privileged syscalls, no
fork/exec, no network listener, no file writes outside zig_tui's terminal output.

**Out of scope (does not apply to this app).** Several attack surfaces from the brief
do not exist here and are NOT findings:

- No `/proc/<pid>/cmdline` or `/proc/<pid>/environ` reads → no argv/env leakage,
  no execve TOCTOU race window.
- No `bind(2)` of any AF_UNIX/AF_INET socket → no socket-mode/SO_PEERCRED issues.
- No `setuid`/`setgid`, no `seteuid`/drop-privs path → no privilege handling bug.
- No `ptrace` → no Yama/scope concern.
- Only world-readable files: `/proc/{stat,meminfo,uptime,loadavg,net/dev,net/tcp,
  net/tcp6,net/udp}` + `uname(2)` + `statvfs("/")`.

The qai automated scan (44 files, 285 "vulns") is overwhelmingly false-positives:
flagged every `@import("../theme.zig")` as CWE-22 path traversal and audited the
`.zig-cache/cimport.zig` glibc bindings. Findings below are the genuine items
found by manual review.

---

## H-1 — Undefined-memory read on `clock_gettime` failure path

- **Severity.** High (UB; can hang on the addEntry path)
- **Locations.**
  - `src/main.zig:233-234` (`getCurrentTime`)
  - `src/sysinfo.zig:123-125` (`SysInfoCollector.collect`)
  - `src/views/logs.zig:42-43` (`addEntry`)

Each site declares `var clock_ts: std.c.timespec = undefined;` then calls
`_ = std.c.clock_gettime(.REALTIME, &clock_ts);` discarding the return value. If
the syscall fails (EFAULT/EINVAL/EPERM, or a seccomp filter blocks it), `clock_ts`
remains `undefined` and is then read.

Reading `undefined` is UB in Zig. In `ReleaseFast`/`ReleaseSmall` the bytes are
whatever was on the stack. The cast `@intCast(clock_ts.sec)` from `i64` to `u64`
can produce an arbitrary value — including ones near `u64::MAX`.

In `formatEpoch` (`logs.zig:209-249`) the resulting `epoch` drives a
`while (true)` year-counting loop that decrements by ~365 per iteration. With a
near-`u64::MAX` epoch, this is ~5 × 10¹⁶ iterations per log entry — an effective
**hang of the TUI render thread**.

**Exploit sketch.** Run under a seccomp filter (e.g. systemd
`SystemCallFilter=~clock_gettime`) that turns the call into ENOSYS. First log
write (`addEntry`) latches a poisoned epoch; the TUI freezes on the Logs tab.
Even without seccomp, any release-build run with stack noise that happens to set
`tv_sec` negative produces the same hang.

**Fix direction.** Check the return value of `clock_gettime` and zero / fall
back on failure. Treat `tv_sec < 0` as an error, not as `@intCast` input.

---

## H-2 — `formatEpoch` year loop unbounded on hostile / future epoch

- **Severity.** High (DoS via infinite loop)
- **Location.** `src/views/logs.zig:209-249`

```zig
var year: u32 = 1970;
while (true) {
    const days_in_year: u64 = if (isLeap(year)) 366 else 365;
    if (days < days_in_year) break;
    days -= days_in_year;
    year += 1;
}
```

`year` is a `u32`. With a bad `epoch_secs` (see H-1, or any pathological clock
state in the year ≥ 2¹⁰ ≈ 5879 AD with a real clock that ever wraps), the loop
will eventually overflow `year += 1` (UB / `IntegerOverflow` panic in safe
modes). Long before that it spins for billions of iterations.

This is the DoS amplifier that turns H-1 into a hang.

**Fix direction.** Cap `year` (e.g. break above 9999 and return a sentinel
timestamp), or compute year via a fixed-cost division instead of per-year
subtraction.

---

## M-1 — `/proc` reads are single-shot; truncate silently on short reads

- **Severity.** Medium (accuracy / monitoring blind-spot)
- **Locations.**
  - `src/sysinfo.zig:333-345` (`readProcFile`)
  - `src/views/services.zig:168-179` (`readProcFile` — duplicate)

```zig
const n = c.read(fd, buf.ptr, buf.len);
if (n <= 0) return null;
return buf[0..@intCast(n)];
```

A single `read(2)` is performed. `/proc` files can return short reads (the
kernel emits one page or one record at a time for several pseudo-files), and
the call can be interrupted with `EINTR`. The code:

1. Has no read-loop, so partial content is treated as the whole file.
2. Has no `EINTR` retry — a SIGCHLD/SIGWINCH at the wrong moment returns -1
   and silently yields `null` (treated as "file unavailable").
3. Truncates content larger than the buffer:
   - `parseCpuStat` 4 KB buffer — `/proc/stat` on a host with ≥ ~28 CPUs
     exceeds 4 KB. Cores past the truncation point parse partial, falling to
     `parseInt … catch 0`, producing zeroed CPU usage for those cores
     (silently wrong dashboard).
   - `parseNetDev` 4 KB buffer — busy hosts (containers, VLANs, veth pairs)
     blow past 4 KB; later interfaces invisible.
   - `services.zig` 8 KB buffer for `/proc/net/tcp{,6}` — a host with a few
     hundred sockets exceeds 8 KB, **the LISTEN entry for an audited service
     can fall past the cut and the service is reported "STOPPED" while running.**
     This is the most operationally consequential one: monitoring lies to the
     operator under load.

**Exploit sketch.** Open a few hundred local TCP connections (or run the
monitor on a busy server). The 8 KB ceiling on `/proc/net/tcp` parsing means
which services appear "RUNNING" depends on socket-table ordering. Any local
unprivileged process can fill the table to push a watched port past the
truncation point.

**Fix direction.** Read in a loop until EOF or until a growable buffer fills;
retry on `EINTR`; or use `std.fs.File`/`readToEndAlloc` with a sane cap.

---

## M-2 — Buffer-reuse pattern in `services.refresh` masks short-read

- **Severity.** Medium
- **Location.** `src/views/services.zig:35-48`

```zig
var buf: [8192]u8 = undefined;
if (readProcFile("/proc/net/tcp", &buf)) |data| { parseTcpPorts(data); }
if (readProcFile("/proc/net/tcp6", &buf)) |data| { parseTcpPorts(data); }
if (readProcFile("/proc/net/udp", &buf)) |data| { parseUdpPorts(data); }
```

Same 8 KB reused across three `/proc` files. Combined with M-1 this means each
file is independently capped at 8 KB and any leftover bytes from a previous
file are not zeroed before the next read (only the read-returned slice is
parsed, so this is not a memory-disclosure but it is a correctness footgun if
anyone later widens the parser to scan past `n`).

**Fix direction.** Per-file growable read; or `@memset` between reads if the
single-shot pattern is kept.

---

## M-3 — `c.read` return-value handling: signed-to-unsigned cast without
floor

- **Severity.** Medium
- **Locations.** `src/sysinfo.zig:344`, `src/views/services.zig:178`

```zig
const n = c.read(fd, buf.ptr, buf.len);
if (n <= 0) return null;
return buf[0..@intCast(n)];
```

`c.read` returns `ssize_t`. The `n <= 0` guard handles error/EOF, but the cast
`@intCast(n)` to `usize` will panic in safe modes if `n` somehow exceeds
`isize` positive range (cannot happen with a 4 KB / 8 KB buffer in practice,
so this is theoretical). Worth noting because the same pattern is replicated
across both files — any future caller passing a larger buffer than `isize_max`
inherits the trap.

**Fix direction.** `@as(usize, @intCast(n))` is fine for current sizes;
documenting the implicit assumption avoids regressions.

---

## M-4 — Integer overflow in `getDiskUsage` block-count math

- **Severity.** Medium (overflow → wildly wrong "used %" displayed; could
  cross the >0.9 red threshold and cause spurious alerts)
- **Location.** `src/sysinfo.zig:325-329`

```zig
const block_size: u64 = stat.f_frsize;
snap.disk_total_kb = (stat.f_blocks * block_size) / 1024;
snap.disk_used_kb  = ((stat.f_blocks - stat.f_bfree) * block_size) / 1024;
```

`f_blocks * block_size` is `u64 * u64`. On a 4 KB-block 16 EiB filesystem
(ZFS, large NFS shares, pseudo-fs reporting absurd values) the product
overflows. In `ReleaseFast` it wraps silently; in safe modes it panics. In
`Debug` the panic kills the TUI.

Less hypothetically: when running on a filesystem that reports `f_blocks =
ULONG_MAX` (some FUSE / overlay drivers do this when the underlying size is
unknown), the multiplication overflows on first call and the disk bar is
wrong / the process panics in safe mode.

**Fix direction.** `std.math.mul` (returns error.Overflow) or compute as
`(blocks / 1024) * block_size` if precision permits; clamp to a max if the
fs reports `~u64::MAX`.

---

## M-5 — `@intFromFloat` on potentially-non-finite values in `drawBar`

- **Severity.** Medium (panic in safe modes if NaN ever sneaks in)
- **Location.** `src/views/overview.zig:144-145`

```zig
const clamped = std.math.clamp(ratio, 0.0, 1.0);
const filled: u16 = @intFromFloat(clamped * @as(f32, @floatFromInt(width)));
```

`std.math.clamp` does **not** sanitize NaN — `clamp(NaN, 0, 1)` returns NaN
on both branches in IEEE 754 because all comparisons with NaN are false.
`@intFromFloat(NaN)` is UB (panic in safe builds).

Today every call site passes a value derived from a guarded division
(`mem_total_kb > 0`, etc.), so NaN is not currently reachable. But the
function takes `f32` with no precondition documented, and `cpu_total / 100.0`
is computed in `parseCpuStat` only when `dt > 0` — if a future tweak forgets
the guard, `0/0` → NaN → panic.

**Fix direction.** Add `if (!std.math.isFinite(clamped)) return;` at top of
`drawBar`, or replace `clamp` with explicit NaN guard.

---

## M-6 — `formatRate` / `formatBytes` printf buffer can fall back to "?"

- **Severity.** Medium (cosmetic, but represents silent failure on very
  large counters)
- **Locations.** `src/sysinfo.zig:392-405` (`formatRate`),
  `src/views/network.zig:128-141` (duplicate `formatBytes`)

`bytes_per_sec * 10` overflows `u64` for inputs ≥ `u64::MAX/10`. In `ReleaseFast`
the wrap silently produces a small number that prints fine (so the user sees
a wrong rate, not an error). In safe mode it panics.

In addition, the `[16]u8` output buffer is too small for the worst-case
`bufPrint` of `{d}.{d} B/s` when `bytes_per_sec` is near `u64::MAX` (20 digits
+ ".X B/s" = 27 chars). Catch falls back to `"?"`. Not a memory safety bug
because of the catch, but it is a swallowed error.

The same `formatBytes` is duplicated in `network.zig` instead of importing
from `sysinfo.zig` — divergence risk.

**Fix direction.** Use `std.math.mul` or div-then-mul; widen the format buffer
to ~32 bytes; deduplicate `formatBytes` into `sysinfo.zig`.

---

## M-7 — Mutable global state, no init guard

- **Severity.** Medium (correctness / re-entrancy risk if the app ever spawns
  a second collector)
- **Locations.**
  - `src/main.zig:22-25` — `current_tab`, `collector`, `snapshot`, `tick_counter`
  - `src/views/services.zig:28-29` — `listening_ports: [65536]bool`,
    `ports_loaded`
  - `src/views/network.zig:13-18` — `prev_rx`, `prev_tx`, `prev_timestamp`,
    `rx_rate`, `tx_rate`, `has_prev`
  - `src/views/logs.zig:27-35` — log ring, scroll, init flags

Single-threaded today, so not exploitable. Worth flagging because:

1. The 65536-bool table (64 KiB BSS) is sparse — wastes cache and creates a
   shared-state surface for any future multi-tenant / multi-window mode.
2. `addEntry` is reachable from `checkForEvents` on the tick path; any future
   refactor that calls it from a signal handler or worker thread will race
   the ring buffer (`head`, `count`) without synchronization.
3. The `refresh_count` static inside `checkForEvents` (`logs.zig:112-115`) is
   a struct-scoped counter — fine, but the pattern is easy to miss when
   reasoning about test-resetability.

**Fix direction.** Wrap state in structs with explicit init/deinit; replace
`[65536]bool` with a hash set or sorted small array of ports actually queried.

---

## L-1 — Errors silently swallowed (`catch 0`, `catch "?"`)

- **Severity.** Low (defense-in-depth observation)
- **Locations.** `parseCpuStat` x8, `parseMeminfo` (`extractKbValue`),
  `parseUptime`, `parseLoadAvg` x3, `parseNetDev` x9, `parseTcpPorts`/
  `parseUdpPorts` (port hex), `formatKb`/`formatRate`/`formatBytes`/
  `formatUptime`, `getCurrentTime`.

Every numeric parse uses `catch 0` and every `bufPrint` uses `catch "?"`.
This is appropriate for a cosmetic monitor, but makes it impossible to
distinguish "kernel returned junk" from "this counter really is zero".
Not exploitable; flagged because aggregated parse failures could mask a
genuine kernel anomaly the operator should see.

---

## L-2 — Saturating arithmetic on counters without resync logic

- **Severity.** Low
- **Locations.**
  - `src/sysinfo.zig:199,200,207,208,242` — `current[0].total() -| prev`
  - `src/views/network.zig:27-28` — `iface.rx_bytes -| prev_rx[i]`

Counter wraparound or interface remove/re-add will produce a saturated zero
delta, not a fresh resync. Today the rate just reads as 0 for one tick
(harmless). If anyone later wires alerting off these deltas, a wraparound
will be invisible.

---

## L-3 — Information disclosure: `/proc/net/tcp{,6}` & `udp` show all sockets

- **Severity.** Low (informational; expected for a monitor)
- **Locations.** `src/views/services.zig:36-44`

These files are world-readable on default Linux but expose **every** local
socket (any UID's). The TUI only displays whether a hard-coded port appears
in any LISTEN entry, so the leakage in the rendered output is bounded —
however, the entire list is parsed and held in memory while running. Not a
concern in single-user use; mention because if this binary is ever wrapped
in a service-account daemon serving multiple operators, the information
in-process is broader than what is shown.

**Note.** `hidepid=2` and `proc.subset=pid` mount options do **not** restrict
`/proc/net/tcp`; only `net.proc.netfilter` and per-netns scoping do.

---

## L-4 — `nanosleep` return value discarded; EINTR shortens warm-up window

- **Severity.** Low
- **Location.** `src/main.zig:38-39`

```zig
var req = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 100_000_000 };
_ = c.nanosleep(&req, null);
```

If interrupted, the second sample happens early, CPU delta divides by a
smaller `dt` and the very first frame's CPU% is noisy. Cosmetic; sleep
loop or `clock_nanosleep(TIMER_ABSTIME)` would fix it.

---

## L-5 — Duplicated `readProcFile` between `sysinfo.zig` and `services.zig`

- **Severity.** Low (maintainability)
- **Locations.** `src/sysinfo.zig:333-345`, `src/views/services.zig:168-179`

Two identical functions with the same single-shot read flaw (M-1). A fix in
one will not propagate. Move to a shared helper.

---

## Info — observations, not bugs

- `MAX_CORES = 16` (`src/sysinfo.zig:6`) silently truncates per-core display
  on systems with more cores. `cpu_count` reports the truncated number, so
  the dashboard is internally consistent but underreports.
- `MAX_NET_IFACES = 8` similarly caps display.
- `LogEntry.message` is `[96]u8` and `addEntry` `@memcpy`s `min(len, 96)`
  bytes — long messages are truncated mid-byte (could split a UTF-8 codepoint
  and render as `?` in the TUI). Cosmetic.
- `formatEpoch` is UTC-only; no timezone offset applied (vs `getCurrentTime`
  in `main.zig` which is also UTC-by-arithmetic). Consistent at least.
- `parseTcpPorts` accepts `state == "0A"` (LISTEN) and parses `port_hex` as
  base-16 `u16`. Fine — `parseInt` rejects values > 65535, so no overflow.
- `parseUdpPorts` marks any non-zero local port as "listening", which is
  the only way to discover UDP services without `SO_BPF` filter; matches
  intent.

---

## Summary table

| ID  | Sev | File:line                     | Class                              |
|-----|-----|-------------------------------|------------------------------------|
| H-1 | High | sysinfo.zig:123, main.zig:233, logs.zig:42 | UB on syscall failure |
| H-2 | High | logs.zig:209                  | Unbounded loop on bad epoch        |
| M-1 | Med  | sysinfo.zig:333, services.zig:168 | Single-shot /proc read; trunc/EINTR |
| M-2 | Med  | services.zig:35               | Buffer reuse hides short-read      |
| M-3 | Med  | sysinfo.zig:344, services.zig:178 | ssize_t→usize cast contract  |
| M-4 | Med  | sysinfo.zig:325               | Integer overflow in disk math      |
| M-5 | Med  | overview.zig:144              | `@intFromFloat` on possible NaN    |
| M-6 | Med  | sysinfo.zig:392, network.zig:128 | bufPrint overflow / dup        |
| M-7 | Med  | (multiple)                    | Mutable globals, no synch          |
| L-1 | Low  | (pervasive)                   | Silent parse-error swallowing      |
| L-2 | Low  | sysinfo.zig:199, network.zig:27 | Counter wrap saturated to 0     |
| L-3 | Low  | services.zig:36               | /proc/net/tcp leaks all sockets    |
| L-4 | Low  | main.zig:38                   | nanosleep EINTR ignored            |
| L-5 | Low  | sysinfo.zig:333, services.zig:168 | Duplicated helper             |

The two High items chain: H-1 plants a poisoned epoch, H-2 spins forever on
it. Fix H-1 first; that defangs H-2. Then M-1 (operationally the most
visible — services lying about RUNNING/STOPPED under socket pressure).
