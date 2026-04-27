# Chronos Engine — Red Team Audit

**Target:** `/Users/director/work/poly-repo/zig-forge/programs/chronos_engine`
**Date:** 2026-04-27
**Scope:** Sovereign Clock daemon, Phi timestamp library, IPC sockets, D-Bus bridge, eBPF cognitive watcher, conductor correlation engine, CLI tools.
**Project nature confirmed:** "Sovereign monotonic clock" + persisted tick counter + agent-action chronicle (`chronos.zig`, `phi_timestamp.zig`). The README's threat model explicitly lists *tick rollback*, *tick forgery*, *DoS*, *file tampering*, *priv-esc*. Several of those defenses are not delivered by the code.

Tooling: `qai security .` produced 275 raw findings; this report is the curated, exploitability-ranked subset, plus issues the static scanner missed (concurrency, semantic, protocol).

---

## CRITICAL

### C1. Tick file is truncated before being rewritten — crash window resets clock to 0
- **File:** `chronos.zig:131-142` (`persistTick`)
- **Description:** `openatZ(... .CREAT=true, .TRUNC=true ...)` is followed by a non-checked `c.write`. There is **no atomic temp+rename, no `fsync`, no return-value check**. Any signal/SIGKILL/power loss between `open(O_TRUNC)` and `write()` leaves the on-disk file empty (or short). On restart `loadTickFromFile` reads zero bytes → `error.FileNotFound` path is *not* taken (file exists, just empty) → `read_result <= 0` returns `error.FileNotFound` only because of `<=0` test, but tick reset to 0 occurs through the silent `catch |err| blk: { if (err == error.FileNotFound) break :blk 0; ... }` in `initWithPath` *only* on FileNotFound. On other errors the daemon refuses to start. **However** if the partial write produced a non-numeric byte stream, `parseInt` errors, propagated up, and `chronos.ChronosClock.init` panics — daemons supervised by systemd will then restart, the file is still empty, and you re-init from `0`. The README's first listed mitigation ("Monotonic guarantee + persistence") fails.
- **Exploit:** `kill -9` chronosd between any two `nextTick()` calls (or pull power on a real deployment). On restart, ticks formerly issued (e.g. tick 42) are re-issued. Phi-timestamps `TICK-0000000042` now refer to two distinct events. The "absolute sequencing" guarantee is broken; replay attacks on signed agent logs become trivial.
- **Fix direction:** write to `tick.dat.tmp.<pid>`, `fdatasync`, `rename(tmp, dst)`, `fsync(parent_dir)`. Do this on every `nextTick`. Also persist a high-water-mark in a journal so torn writes can be reconciled.

### C2. macOS variant: same TRUNC pattern + symlink-followed temp file
- **File:** `chronos-stamp-macos.zig:67-83`
- **Description:** Uses `<path>.tmp` (no PID, no random suffix) opened with `CREAT|TRUNC` and **no `O_NOFOLLOW`/`O_EXCL`**. If a hostile local user pre-creates `/tmp/chronos-tick.dat.tmp` as a symlink to any file the chronos UID can write to (e.g. `~/.ssh/authorized_keys`, a log file, even `/var/lib/chronos/tick.dat` itself), `openat(... O_TRUNC)` truncates the target.
- **Exploit:**
  ```
  ln -s ~/.ssh/authorized_keys /tmp/chronos-tick.dat.tmp
  # next chronos-stamp-macos invocation truncates authorized_keys
  ```
  When chronos-stamp-macos runs as a different user (e.g. via launchd plist or sudo), this is a local privesc / data-destruction primitive.
- **Fix direction:** open temp with `O_CREAT|O_EXCL|O_NOFOLLOW`, retry on EEXIST with a fresh random suffix; never use a predictable temp path in a world-writable dir.

### C3. `popen()` with bare command name → PATH-based binary planting (RCE)
- **File:** `chronos-stamp-cognitive-direct.zig:31` (`c.popen(@ptrCast(&cmd_buf), "r")` — `cmd_buf` starts with `"get-cognitive-state"`)
- **File:** `chronos-stamp-cognitive.zig:28` (`libc.popen("get-cognitive-state", "r")`)
- **Description:** `popen()` invokes `/bin/sh -c <command>`, which uses the inherited `$PATH`. Both binaries pass an unqualified program name. If chronos-stamp is run via sudo, a launchd job, a Claude Code hook, or under any caller that retains the invoker's `$PATH`, an attacker that controls (or can prepend to) `$PATH` runs arbitrary code at the privilege of the chronos-stamp process.
- **Exploit:** `PATH=/tmp/evil:$PATH chronos-stamp-cognitive-direct AGENT-X`. `/tmp/evil/get-cognitive-state` is shell-executed.
- **Aggravating factor:** `chronos-stamp` is documented as a hot-path tool wired into Claude Code hooks; hostile process-environment pollution is well within reach.
- **Fix direction:** drop `popen` entirely; use `posix_spawn`/`std.process.Child` with the **absolute** path (`/usr/local/bin/get-cognitive-state`) and `argv` array; sanitize/clear `PATH`, `IFS`, `LD_*`, `DYLD_*` before exec.

### C4. eBPF map-name match → kernel-controlled stack overflow in chronos-stamp
- **File:** `chronos-stamp-cognitive-direct.zig:57-87, 137-162` (`findLatestStateMap`, `readLatestStateFromMap`)
- **Description:** `findLatestStateMap` enumerates *all* BPF maps system-wide and matches `info.name` against substring `"latest_state_by_pid"` — first hit wins. There is **no validation that the map's `value_size` equals `@sizeOf(CognitiveEvent)` (320 bytes)**. `bpf_map_lookup_elem(map_fd, &target_pid, &event)` writes `value_size` bytes into the local `event: CognitiveEvent` on the stack. Any process with `CAP_BPF` (or root in a container) can create a hash map named e.g. `xlatest_state_by_pid` with `value_size = 8192`; the kernel then memcopies 8 KiB into a 320-byte stack frame — classic stack smash.
- **Exploit:** unprivileged-in-container user with CAP_BPF creates a poison map; any process running `chronos-stamp-cognitive-direct` (Claude hooks, etc.) gets RCE via stack overflow.
- **Fix direction:** require an *exact* map name match, *and* call `bpf_obj_get_info_by_fd` and verify `info.value_size == @sizeOf(CognitiveEvent)` *and* `info.key_size == @sizeOf(u32)` before lookup. Better: pin the canonical map under `/sys/fs/bpf/...` and only open by pinned path with owner check.

### C5. `parseInt` failure silently resets tick to 0
- **File:** `chronos-stamp-macos.zig:98` (`return std.fmt.parseInt(u64, tick_str, 10) catch 0;`)
- **Description:** Any unparseable contents in `tick.dat` cause the macOS variant to start fresh at tick 0 instead of erroring. Combined with C2 or any partial write (no fsync), this turns "garbage in tick file" into "deterministic clock rollback".
- **Exploit:** corrupt the tick file by 1 byte → next start re-issues every tick from 0. Combined with any agent-log signing scheme, replay attacks become possible against historical phi-timestamps.
- **Fix direction:** fail closed — refuse to start; require a manual `chronos-ctl reset --force` to set 0.

### C6. Unsigned underflow disables ALL behavioral correlation rules
- **File:** `conductor-daemon.zig:351` (`if (current_time - past_event.timestamp > rule.time_window) continue;`)
- **Description:** Both operands are `u64`. If `past_event.timestamp > current_time` (clock skew, kernel-side monotonic re-ordering, attacker-spoofed kernel event), unsigned subtraction wraps to a huge number; `> rule.time_window` is true → the event is treated as outside *every* time window → no rule ever matches.
- **Exploit:** induce one event whose timestamp is "in the future" relative to the next event (trivial across a clock jump or a multi-CPU scenario where event order isn't strict). Once ingested, **all subsequent correlation is silently disabled** until that future-stamped event ages out — which never happens because `event_history` is unbounded (see H4).
- **Fix direction:** `if (past_event.timestamp > current_time) continue;` *and* compute the difference with `std.math.sub` returning `error.Overflow`. Better: use a saturating signed delta.

### C7. Race-to-bind on `/tmp/chronos.sock` → impostor daemon
- **File:** `chronos_client.zig:58-82` (`ChronosClient.connect`); `chronosd.zig:127`; `conductor-daemon.zig:442`
- **Description:** Production socket path is `/var/run/chronos.sock`, but every shipped daemon currently uses `FALLBACK_SOCKET_PATH = "/tmp/chronos.sock"` and every client falls back to it when the system path is missing. `/tmp` is world-writable; nothing checks `SO_PEERCRED` / `getsockopt(SO_PEERCRED)` on either side. A non-root user that wins the bind race (or simply binds first because the real daemon hasn't started yet) operates a man-in-the-middle daemon answering `STAMP:` / `LOG:` with attacker-chosen ticks.
- **Exploit:** start a 3-line `nc -lU /tmp/chronos.sock` impostor before `chronosd`. All `chronos-stamp` invocations now receive forged Phi timestamps. Tick forgery is the first item in the README's threat model — it is unmitigated.
- **Fix direction:** clients call `getsockopt(sockfd, SOL_SOCKET, SO_PEERCRED, ...)` and verify daemon UID == 0 or `chronos`. Daemons should bind in a directory only writable by themselves (`/run/chronos/` mode 0700) and clients open by absolute path under it. Never fall back to `/tmp`.

### C8. `mkdir` failure path silently re-routes persistent state to `/tmp`
- **File:** `chronos.zig:71-89`
- **Description:** When the system tick directory cannot be created, the only errors handled are `EACCES (13)` and `EPERM (1)`. Every other failure (`EROFS`, `ENOSPC`, `ENOTDIR`, `EIO`) falls through to `initWithPath(allocator, path)` which then blows up later — **but** when permission *is* denied, it silently switches to `FALLBACK_TICK_PATH = "/tmp/chronos-tick.dat"`. A local attacker can make this happen by chmod-restricting `/var/lib/chronos`, or simply by running the daemon under a sandbox that lacks write to `/var/lib`. Once the daemon stores state in `/tmp`:
  - Any local user can read the tick file (file mode `0o644`).
  - Any local user can pre-create `/tmp/chronos-tick.dat` with a chosen value (or symlink it to e.g. `/etc/passwd` for read-truncate damage; `O_TRUNC` strikes again — see C1/C2).
- **Exploit:** combined with C2 → arbitrary file truncation; combined with C7 → forged ticks accepted by clients.
- **Fix direction:** delete the `/tmp` fallback in production builds; if the canonical state dir is unavailable, fail closed.

### C9. Cross-PID session contamination + silent eviction in cognitive watcher
- **File:** `cognitive-watcher.zig:168-181` (`getOrCreateSession`)
- **Description:** When the 8-slot fixed-size session table fills, the function returns `&self.sessions[0]` **without resetting `pid` or flushing the displaced session's data**. The caller (`processCognitiveEvent`, `addTool` at line 622) then attributes the new event's tool calls to the existing session struct — meaning the *first* session's `pid` is preserved while a *different* PID's tools get recorded under it. The "evicted" session is never persisted; data loss + cross-attribution.
- **Exploit:** attacker (or just normal load) starts ≥9 processes named "claude" → tool invocations from process #9 are silently logged to process #1's session. Used downstream as security telemetry, this means an attacker process spinning up agent code can have its actions attributed to a benign process.
- **Fix direction:** when full, pick the least-recently-used session, flush it, then *fully reset* the slot (call `CognitiveSession.init(new_pid)`) before returning.

### C10. eBPF event size not validated → out-of-bounds read of attacker-controlled data
- **File:** `cognitive-watcher.zig:302-313, 545-554`
- **Description:** The libbpf ring-buffer callback is given `size: c_ulong` — the *actual* record length in the buffer. The code does `_ = size;`, then `@ptrCast`s `data` to `*CognitiveEvent` (sizeof = 4+4+4+4+16+256 = 288 bytes). Two separate problems:
  1. If `size < @sizeOf(CognitiveEvent)`, fields read past the record boundary alias adjacent ring-buffer slots (info disclosure across kernel records).
  2. The struct contains `buf_size: u32` which is then trusted: `event.buffer[0..event.buf_size]` (line 554) is sliced. `buf_size` is set kernel-side; if a malicious or buggy eBPF program (CAP_BPF user) writes a record with `buf_size > 256`, this is **out-of-bounds slice into adjacent stack/ring-buffer memory**.
- **Exploit:** any caller able to inject events into the ring buffer (CAP_BPF, or kernel bug) → controlled OOB read of up to 4 GiB of process memory, then sent over D-Bus + written to SQLite. Disclosure of secrets in the watcher process address space.
- **Fix direction:** at the very top of `handleCognitiveEvent`, check `if (size < @sizeOf(CognitiveEvent)) return 0;`. Then clamp `event.buf_size` with `@min(event.buf_size, MAX_BUF_SIZE)` *before* using it.

---

## HIGH

### H1. Wall-clock UTC mixed into a "monotonic" timeline
- **File:** `phi_timestamp.zig:52-56` (`nanoTimestamp` uses `CLOCK.REALTIME`); same in `chronosd-cognitive.zig:42-46`, `chronos-stamp-macos.zig:144-148`, `cognitive-watcher.zig:228, 561`.
- **Description:** The whole product premise is monotonicity. The UTC component of every Phi timestamp comes from `CLOCK_REALTIME` which is *not* monotonic — NTP slew, manual `date -s`, leap-second smearing, and DST transitions all jump it. Two events with `TICK-N+1` < `TICK-N` in UTC ordering are emitted whenever the wall clock moves backward.
- **Exploit / impact:** any consumer ordering events by the UTC field (which the README explicitly suggests for "external correlation") will see paradoxes. SQLite `start_time`/`duration_seconds` rows in `cognitive_sessions` go negative on backward jumps.
- **Fix direction:** keep `CLOCK_REALTIME` *only* for human-facing display, and additionally record `CLOCK_MONOTONIC_RAW` ticks; reject `nextTick` if monotonic clock has gone backward since last increment.

### H2. `nanoTimestamp` returns 0 on `clock_gettime` failure with no error path
- **File:** `phi_timestamp.zig:52-56`; `chronosd-cognitive.zig:42-46`; `chronos-stamp-macos.zig:144-148`
- **Description:** Failure is silent and indistinguishable from a real "epoch=0" timestamp. `phi_timestamp.zig:76` then `@intCast(seconds)` of zero is fine, but every consumer happily emits `1970-01-01T00:00:00.000000000Z`. Used in audit logs that must establish ordering, this is a forgeable nullification.
- **Exploit:** trigger via seccomp filter dropping `clock_gettime` (containerized agents); every Phi-timestamp from inside the container shares the same epoch, breaking ordering.
- **Fix direction:** propagate the error; refuse to issue a timestamp if the clock can't be read.

### H3. JSON log emission is not escaped — log injection / structure forgery
- **File:** `phi_timestamp.zig:180-198` (`PhiLogEntry.toJson`)
- **Description:** `action`, `status`, `details`, and the agent-id baked into `timestamp` are interpolated into JSON via `allocPrint` with no escaping of `"`, `\`, or control characters. Callers route attacker-controlled strings here:
  - `chronosd.zig:238-258` accepts `LOG:agent:action:status:details` from any local connector.
  - `chronosd-dbus.zig:170-205` accepts `LogEvent(agent, action, status, details)` from any D-Bus client.
- **Exploit:** `LOG:CLAUDE-A:ok":"exfil","fake_field":"yes:OK:.` produces JSON that downstream parsers split into fake fields, or terminates a key early so that an entire forged record nests inside `details`. Auditing pipelines (SIEMs) that ingest these JSON lines accept the forgery.
- **Fix direction:** use `std.json.Stringify` or a real JSON encoder; or sanitize input by rejecting `"`, `\`, `\n`, `\r`, control bytes.

### H4. Conductor's event_history and process_chains grow without bound (memory DoS + amplifies C6)
- **File:** `conductor-daemon.zig:163, 184, 292, 339, 350`
- **Description:** Every Oracle event is appended to `event_history` (an `ArrayList(OracleEvent)`, ~280 bytes each); `process_chains` is `AutoHashMap(u32, ProcessChain)` keyed by PID with no eviction. Both grow forever. Worse: the correlation loop at `runBehavioralCorrelation` is O(N²) — for every new event it scans the entire history.
- **Exploit:** any user (or normal load) drives the daemon to OOM in minutes. PID-cycling fork storms blow up the hashmap. The O(N²) scan saturates a CPU long before OOM, freezing detection.
- **Fix direction:** ring-buffer the history, drop entries older than the largest rule window; bound `process_chains` and prune on PID exit (you already have `event_history`, scan it for newer events for the same PID before evicting). Index events by `(event_type, time_bucket)`.

### H5. Memory leaks in conductor-daemon hot path
- **File:** `conductor-daemon.zig:398-402` (`triggerBehavioralAlert`)
- **File:** `conductor-daemon.zig:538, 545` (`handleConnectionFd` GET_TICK / NEXT_TICK)
- **Description:** `try std.fmt.allocPrint(...)` returns a heap allocation that is passed positionally as the `details` arg to `logger.log` *and* as the `result` arg to `formatOk`. Neither callee takes ownership — `formatOk` copies (`socket_protocol.zig:127-129`), and `logger.log` ignores `details` entirely (line 71: `_ = details;`). The original allocation leaks every time. Permanent daemon → unbounded leak.
- **Exploit:** every `GET_TICK`/`NEXT_TICK`/alert leaks ~16-64 bytes; multiply by socket throughput (README claims 100K ticks/sec) → minutes to OOM.
- **Fix direction:** capture the allocation in a local, `defer allocator.free(...)`, then pass the slice. And actually log `details` in `chronos_logger.zig` instead of dropping it.

### H6. `chronos_logger.log` silently drops `details` argument
- **File:** `chronos_logger.zig:70-79` (`_ = details; // Currently unused`)
- **Description:** A logger named "logger" that documents itself as "Log an event with automatic Phi timestamp" but discards the most informative parameter. Combined with H5, callers think they've persisted forensic context that doesn't exist. Audit-trail integrity fails open.
- **Exploit:** any attacker performing `failure(activity, error_msg)` knows their `error_msg` will not appear in any log.
- **Fix direction:** actually pass `details` into a structured log emission; remove the `_ = details;`.

### H7. Single-threaded blocking accept loop = trivial DoS
- **File:** `chronosd.zig:160-176`; `conductor-daemon.zig:483-499`
- **Description:** Both daemons accept a connection, call `handleConnection*` *inline*, then loop. There is no read timeout on the client socket. A connecting client that opens the socket and never sends data blocks the entire daemon — every other client (including legitimate `chronos-stamp` calls in your tooling) blocks indefinitely.
- **Exploit:** `(while :; do nc -U /tmp/chronos.sock; sleep 1; done) &` — the very first connection wedges the daemon. README's "Denial of service: systemd automatic restart" mitigation does *not* address this because the process isn't crashing, it's stuck on `read`.
- **Fix direction:** set `SO_RCVTIMEO` on accepted fd, or move to non-blocking + `poll`/`epoll`, or spawn a worker thread per connection (with a cap).

### H8. `Command.parse` uses `startsWith` — accidental command aliasing
- **File:** `socket_protocol.zig:80-89`
- **Description:** `"NEXT_TICK_AND_LOG"` parses as `next_tick`; `"SHUTDOWNFOO"` parses as `shutdown`. Combined with C7 (impostor daemon), this widens the parser surface. With LOG/STAMP it also means `"LOG:..."` and `"STAMP:..."` accept any trailing data after the recognized prefix; not directly exploitable but invites future regressions.
- **Fix direction:** require a full token match; split on whitespace/colon and dispatch on the first token.

### H9. `std.mem.indexOf(cmdline, "claude")` is not a process-identity check
- **File:** `cognitive-watcher.zig:368-389`; `chronosd-cognitive.zig:184`
- **Description:** Substring match on `/proc/PID/cmdline`. Any process named `evil-claude-spoof`, or any process passing `--name claude` as an argv, satisfies the check. Cognitive state attribution is forgeable by any local process.
- **Exploit:** `bash -c 'exec -a claude /usr/bin/sleep 99999'` registers as a "Claude Code" process; the watcher will then ascribe *its own writes* to that PID via the cognitive oracle.
- **Fix direction:** read `/proc/PID/exe` (a symlink to the real binary), `realpath` it, and compare against the known absolute path; also check exe inode/uid.

### H10. TOCTOU between PID identification and event processing
- **File:** `cognitive-watcher.zig:549` calls `isClaudeCLI(event.pid)` per-event
- **Description:** PIDs are recycled. Between the eBPF event being captured and the `/proc/PID/cmdline` re-check, the original process can have exited and a new attacker-chosen process now occupies that PID. The watcher then either filters out a real Claude event, or attributes attacker data to a recycled PID that *now* says "claude".
- **Exploit:** rapid fork/exec cycles at PID boundary to deflect detection.
- **Fix direction:** read `/proc/PID/stat` `start_time` and include it in the identity comparison; reject events whose start_time has changed.

### H11. `chronos-ctl reset --force` allows arbitrary local rollback
- **File:** `chronos-ctl.zig:148-169`
- **Description:** The "DANGEROUS" gate is a single CLI flag — there is no auth, no lock, no co-signer. Anyone with read+write access to `/var/lib/chronos/tick.dat` (i.e. anyone on a system where the daemon dropped to `/tmp` per C8) can rewind the sovereign clock. README's threat model claims "Tick rollback: Mitigation: Monotonic guarantee + persistence" — `reset` *is* the rollback, in the codebase, by design.
- **Exploit:** `chronos-ctl reset --force` followed by `chronos-ctl next` re-issues TICK-1.
- **Fix direction:** require explicit cryptographic operator credential; gate behind an SSH-key signed challenge or a sealed-on-first-boot capability file. Never reset a clock that has previously emitted ticks; instead, archive and start a new epoch with an epoch-id in the timestamp.

### H12. Signal handling absent → ungraceful exit guarantees lost ticks
- **File:** `chronosd.zig:296-300`; `chronosd-cognitive.zig:373-382`; `cognitive-watcher.zig:798`
- **Description:** Comments admit "proper signal handling requires platform-specific code". On SIGTERM (the normal systemd shutdown path), no `deinit()` runs because `defer` does not execute on signal-induced exit. The deferred `clock.deinit()` (which is supposed to persist the final tick) is bypassed. Combined with C1 (no fsync on every increment), expect chronic small rollbacks on every restart.
- **Fix direction:** install `sigaction` for SIGTERM/SIGINT/SIGHUP that sets `running = false`; ensure persist happens on every `nextTick` (synchronously), not just at shutdown.

### H13. World-readable tick file leaks ordering information; no integrity check
- **File:** `chronos.zig:136` (`0o644`); `chronos-stamp-macos.zig:73` (`0o644`)
- **Description:** Any local user can read the current tick. More importantly, the tick is stored as plaintext decimal — there is *no MAC or signature*. A user with write access (see C8) can alter it freely. The README's "File tampering" mitigation says "StateDirectory with 0700 permissions"; the actual file mode is 0o644 and the directory is created with 0o755.
- **Fix direction:** mode 0o600 on the file, 0o700 on the dir; consider HMAC over `(epoch_id, tick)` with a key only the daemon knows.

### H14. ISO 8601 parser accepts invalid dates → re-parsed timestamps lie about time
- **File:** `phi_timestamp.zig:200-275` (`parseISO8601`)
- **Description:** `if (day < 1 or day > 31)` — accepts Feb 30, Apr 31, etc. `if (... second > 60)` — accepts second=60 in non-leap contexts and adds it un-normalized. Year is `i32` with no upper bound, so very large years overflow `total_days: i64` (multiplications at line 273 with `total_days * 86400 + ...`). 
- **Exploit:** craft a Phi-timestamp string with a wraparound `year` (e.g. `999999999-...`) → `parse` returns a timestamp that the formatter then renders as something else. Attackers replay events with seemingly-valid timestamps that produce a different time on round-trip.
- **Fix direction:** validate days-in-month per month; cap year to a sane range; use checked arithmetic (`std.math.mul`).

### H15. `parseISO8601` agent_id allocation leaks on subsequent error
- **File:** `phi_timestamp.zig:112-119`
- **Description:** `allocator.dupe(u8, agent_id_str)` happens before tick parsing. If the tick parse fails, the duped agent_id is leaked. Not a security primitive on its own but every parser error path leaks O(agent_id_len) bytes — useful as a DoS amplifier when combined with attacker-driven parse calls.
- **Fix direction:** `errdefer allocator.free(agent_id);` after the dupe.

### H16. Concurrent `nextTick` race can persist a stale tick
- **File:** `chronos.zig:117-124`
- **Description:** `fetchAdd` is atomic, but the followup `persistTick` is *not* serialized with other persists. Two threads racing T1 (`fetchAdd → 5`, slow), T2 (`fetchAdd → 6`, fast persist) → final on-disk state can end up as `5` if T1's persist completes after T2's. Tick `6` was returned to a client (and possibly used in a Phi-timestamp) but is not on disk → a crash now rolls back to 5; tick 6 is re-issuable.
- **Note:** the current daemons are single-threaded so this doesn't fire today, but `chronos.zig` is a library import and the next refactor will trip it.
- **Fix direction:** hold a mutex around `(fetchAdd, persist)`; on persist, write `max(loaded, new)` rather than the parameter blindly.

### H17. SQL injection-by-format in cognitive-watcher prepared statements *is* parameterized — but session arguments are unvalidated
- **File:** `cognitive-watcher.zig:235-280`
- **Description:** Bindings *are* parameterized (good), but `state` and `tools_str` are user-controllable strings derived from kernel ring-buffer data. They contain attacker-influenced bytes including newlines (kept by `stripAnsi`, line 357). Any later `SELECT cognitive_state FROM cognitive_sessions WHERE pid=?` consumer that interpolates these into another SQL statement, a shell command, or a JSON document inherits the original injection vector.
- **Fix direction:** length-cap state/tools, reject newlines and `\0`; explicitly document that values are untrusted attacker bytes.

---

## MEDIUM

### M1. `socket_protocol.parseLogArgs` cannot represent fields containing `:`
- **File:** `socket_protocol.zig:108-124`
- **Description:** Splits on `:` with no escaping. Fields with literal colons (timestamps, URLs, error messages) silently truncate. Forensic loss + can be used to smuggle protocol commands inside `details`.

### M2. `STAMP:` agent-id slice is borrowed from the request buffer
- **File:** `socket_protocol.zig:93-98`; consumed in `chronosd.zig:222`
- **Description:** `agent_id` is a slice into `buf` on `handleConnection`'s stack. It's then handed to `handleGetPhiTimestamp` → `PhiGenerator.init` which stores it. On this code path the borrowed lifetime ends when `handleConnection` returns, but later refactors moving the work to a worker thread will introduce use-after-free.

### M3. `client_addr_len = @sizeOf(posix.sockaddr)` is too small for AF_UNIX
- **File:** `chronosd.zig:162`; `conductor-daemon.zig:485`
- **Description:** The kernel writes `socklen_t` bytes back; for AF_UNIX it can be much larger than `sizeof(sockaddr)`. Today nothing reads `client_addr`, but if/when a `SO_PEERCRED` check is added, the truncated length will silently disable it.

### M4. `defer std.c.close(fd)` ignores close errors (NFS, ENOSPC, EIO)
- **Files:** every `posix.openatZ` call site (`chronos.zig:137, 165`, `chronos-stamp-cognitive-direct.zig:103`, etc.)
- **Description:** On NFS, the *real* error from a write is delivered by close(). Ignoring it can mask "failed to persist tick" as success.

### M5. macOS variant timestamp format is invalid ISO 8601
- **File:** `chronos-stamp-macos.zig:121` — `".+{d:0>9}Z"` literally inserts a `+` after the seconds. Output looks like `2026-04-27T22:00:00.+000000000Z`. Phi parser (`phi_timestamp.zig:223`) expects `.NNNNNNNNN`; round-trip parsing of macOS-emitted stamps fails. Cross-platform timeline reconstruction broken.

### M6. `std.mem.split` deprecated in current Zig
- **File:** `phi_timestamp.zig:102` uses `std.mem.split` (renamed). Likely already a build break on the targeted Zig version; security-relevant only insofar as nobody is exercising the parser.

### M7. `getEnv("PWD")` trusts a user-controlled environment variable
- **File:** `chronos-stamp-cognitive-direct.zig:238-241`
- **Description:** `$PWD` is set by the shell and freely overrideable. The "spatial dimension" component of the four-dimensional chronicle can be forged by the caller (`PWD=/etc chronos-stamp ...`). The `chronos-stamp.zig:73-74` variant correctly uses `realpath(".")`; the cognitive variants don't.

### M8. `unlink` of socket path before bind is racy
- **File:** `chronosd.zig:132`; `conductor-daemon.zig:450`
- **Description:** `deleteFile(socket_path) catch {};` has no protection against an attacker re-creating a symlink between unlink and bind. Bind to AF_UNIX through a symlink doesn't follow it, but a hostile pre-existing regular file at the path causes bind to fail; harmless DoS today, footgun later.

### M9. `chronos_client.zig:101` reads only one chunk from the socket
- **Description:** A response longer than `MAX_MESSAGE_LEN` truncates silently; a fragmented short read returns a partial response that is then `parseInt`-ed (for `getTick`) and yields a bogus number that the client trusts.

### M10. `realpath` buffer placed on stack with `std.fs.max_path_bytes`
- **File:** `chronos-stamp.zig:73`
- **Description:** ~4 KiB stack alloc per invocation; not currently a problem but combined with deep call stacks in the cognitive variant, leaves no headroom for signal handling.

### M11. `parseSpinnerStatus` accepts UTF-8 ellipsis only via a 3-byte pattern
- **File:** `cognitive-watcher.zig:524`
- **Description:** Off-by-one OK on the buffer length check, but the test `buffer[end] == 0xE2` will trigger on any byte starting a 3-byte UTF-8 sequence — false positives possible from arbitrary terminal output.

### M12. `chronosd-cognitive.zig:153-227` walks `/proc` every 2 s, no rate limit
- **Description:** For each scan it opens `/proc/PID/cmdline` for every PID. With many short-lived PIDs you bottleneck on procfs. Combined with the `c.read` returning `<= 0` → `continue` (line 179), errors are swallowed silently — no alert if the watcher loses sight of Claude.

### M13. JSON state file path uses `$HOME` from `getenv`
- **File:** `chronosd-cognitive.zig:193` (`const home = if (c.getenv("HOME")) ... else "/home/founder";`)
- **Description:** Daemon trusts caller-controlled HOME *and* hardcodes the developer's home directory as fallback. In a system daemon HOME is typically empty/`/`, so the daemon will silently look in `/home/founder/.cache/...` on production hosts.

### M14. `cognitive-watcher.zig:165` `sessions: undefined`
- **Description:** Init leaves the array undefined; `getOrCreateSession` only initializes the slot it writes (line 175). The eviction path (C9) re-uses the slot at index 0 with leftover state from the prior session — including `state` byte buffer with stale bytes, `tool_lens` array. The `getToolsString` function (line 88) iterates `0..tool_count`, so stale tool *bytes* in evicted slots aren't read for output, but they are read for length comparisons in eviction logic.

### M15. `dbus_bindings.zig` `getString` does not validate the iter type before reading
- **File:** `dbus_bindings.zig:181-200`
- **Description:** `dbus_message_iter_get_basic` is undefined behavior if the current arg's signature doesn't match. The code never calls `dbus_message_iter_get_arg_type` first. A malformed message from any local D-Bus peer can crash the daemon (or worse, on libdbus build variants).

### M16. `chronos_client.connect` does not authenticate response framing
- **File:** `chronos_client.zig:108-119`
- **Description:** Trusts `OK:` / `ERR:` / `PONG` prefixes from whatever bound the socket. With C7's MITM, the impostor daemon can return arbitrary payloads to `parseInt`.

### M17. `runGetCognitiveState` cmd_buf size = 128 limits but doesn't validate `pid_arg`
- **File:** `chronos-stamp-cognitive-direct.zig:21-43`
- **Description:** `pid_arg` is currently always a digit string, but the function takes `?[]const u8`. Any future caller passing a longer or shell-meta string ships RCE atop C3 (no shell quoting either).

### M18. CognitiveEvent.timestamp_ns is u32 → wraps every ~4.3 s
- **File:** `cognitive-watcher.zig:36-42`
- **Description:** Truncated from kernel u64 to save space. Used for ordering events. Within a single 4.3-second window, ordering is fine; across the wrap, ordering is wrong. With C6 in conductor-daemon's similar logic, this can disable correlation rules outright.

---

## LOW / INFO

- `chronos.zig:171` `@intCast(read_result)` after a `<=0` check is fine; comment-noted because the negative-on-error ABI is fragile.
- `phi_timestamp.zig:282` `isLeapYear` correct, but `parseISO8601` doesn't use it for day-of-month validation (see H14).
- `conductor-daemon.zig:274` `@ptrCast(@alignCast(ctx))` does not check for `ctx == null` (only `data == null` is checked). `cognitive-watcher.zig:304` does check both — keep that pattern.
- `chronos-ctl.zig:165` reset uses `.monotonic` ordering for an *atomic store*; semantically OK but `.release` would be the more conventional ordering for the followup persist.
- `chronos_logger.zig:103, 113` `std.heap.c_allocator` chosen for "convenience" — every short-lived ctl invocation calls into libc malloc; harmless, just noted.
- README's threat model table should be updated to reflect that "Tick rollback", "Tick forgery", "DoS", "File tampering", and "Privilege escalation" are NOT mitigated by the current code (see C1, C7, H7, C8, C3 respectively).

---

## Suggested Triage Order

1. **C3** (popen RCE) — biggest blast radius, easiest fix.
2. **C7 + C8** (socket race + state-dir fallback) together — kill the `/tmp` fallbacks.
3. **C1 + C2 + H16** — fix persistence atomicity (temp file with O_EXCL|O_NOFOLLOW + fsync + rename + parent-dir fsync) once, in `chronos.zig`, then have macOS variant call into it.
4. **C4** — exact-match map name + value_size assertion before `bpf_map_lookup_elem`.
5. **C6 + H4** — bound history size and use signed/saturating time deltas in conductor.
6. **C9 + C10** — fix watcher session eviction and validate libbpf record `size`.
7. **H1 / H2** — separate monotonic ordering from wall-clock display.
8. **H3 / H7 / H11 / H12** — log escaping, accept timeouts, reset gating, signal handling.

— end of report —
