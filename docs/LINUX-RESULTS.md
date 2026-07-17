# Linux verification results

_Companion to `docs/LINUX-TODO.md`. Host: Arch Linux x86_64 (Acer Nitro AN515-57), Zig 0.16.0._

## P1 — Security-critical

### zig_jail — build ✓ / test ✓ (43/43) — **required fixes**

The headline P1 check passed, but only after real fixes: **`zig build test` was green
vacuously — the test root ran 0 tests.** `main.zig` imported the modules but never
referenced their test blocks, so no module test (including the seccomp SIGSYS proof)
was in the build graph — on this host **or on macOS**. The "SkipZigTest on macOS"
observation was itself never exercised.

Fixes applied (all in test code / build wiring — no production logic touched):

1. `src/main.zig`: added a `test { _ = profile_mod; _ = seccomp_mod; ... }` block so
   the imported modules' tests are actually collected.
2. `src/seccomp.zig`, `src/profile.zig`: five test sites passed `&[_][]const u8{...}`
   const literals into `[][]const u8` (mutable) Profile/SyscallConfig fields —
   rewritten as `var` arrays. (Compile error; only surfaced once the tests entered
   the graph on a Linux host, since the sites are Linux-gated or newly analyzed.)
3. `src/seccomp.zig` runtime test: Zig 0.16 API drift — `std.posix.fork/exit/waitpid/W`
   no longer exist. Ported to `std.os.linux.fork/exit/wait4/W` (test is already
   gated to .linux/.x86_64, so no portability loss). `W.TERMSIG` now returns the
   `SIG` enum; comparison updated.
4. `src/profile.zig` "CapabilityConfig structure" test: **segfaulted** —
   filled the allocated `keep` slice with string literals, then called
   `deinit`, which frees every element (its contract with the profile parser).
   Elements are now `allocator.dupe`'d. (Never-before-run test; coredump confirmed
   `profile.CapabilityConfig.deinit` → `allocator.free(literal)`.)

**Verdict**: `zig build test` → 43/43. Test 20 —
`seccomp: blocked syscall traps at runtime (Linux/x86_64)` — **ran on a real kernel
and passed**: forked child with `default_action=allow` + `getpid` blocked died with
SIGSYS. The Wave-1 `buildSeccompFilter` denylist fix is behaviorally verified.

### distributed_kv — build ✓ / test ✓ (20/20)

Both WAL tests (`wal write and read`, `wal recovery`) pass on Linux — the 2/20
macOS failures are confirmed platform-only, not a WAL bug.

One host issue found: the default (self-hosted x86_64) backend fails with
`fatal linker error: unhandled relocation type R_X86_64_PC64` compiling the test
module. Toolchain limitation, not a code defect. Fix applied: `build.zig` test
artifact sets `.use_llvm = true` (with comment). `zig build test` now green.

### guardian_shield — build ✗ / test ✗ — IN PROGRESS

`zig build` currently fails on this host:

- `src/zig_sentinel/test-oracle-advanced.zig` and `src/zig_sentinel/test-inquisitor.zig`
  are referenced by `build.zig` but **do not exist in the repo** (FileNotFound) —
  either never committed from the macOS host or paths drifted.
- Pre-existing 0.16 drift exactly as LINUX-TODO flagged: `src/warden/warden.zig:109`
  (ArrayList `items` field), `src/wardenctl/main.zig:438` (`json.ObjectMap.init` arity).

Separately: the **deployed** `/usr/local/lib/security/libwarden.so` (V7.1) has an
intermittent nested-panic bug — `config.loadConfig`'s stderr banner print hits an
out-of-bounds in `Io.Writer` when stderr is a pipe in the wrong state, the panic
handler re-enters the same writer, and the interposed process dies with SIGABRT
(coredumps observed for `git update-index` and unrelated binaries; this also broke
Claude Code's npm postinstall → the recurring "claude native binary not installed").
Root-causing against `src/libwarden/main.zig` is queued with the build fixes.

## P2 — pending

Not started yet: audio_forge, zero_copy_net, stratum_engine_grok/claude,
duck_cache_scribe, zigix_monitor, zigix_desktop, zig_tui, chronos_engine,
cognitive_telemetry_kit.

## P3 — pending

zig_dpdk (this host qualifies: x86_64). hydra requires NVIDIA+CUDA — this host has
an RTX-class GPU (Nitro AN515-57); to be attempted after P2.
