# Linux verification & follow-up queue

_Created 2026-07-17 by the macOS session that ran the 88-program audit + Tier 1A/1B/quick-win fix waves + the Tier 2 FFI migration._

This file exists because the fix waves ran on an **aarch64 macOS** host. A number of
programs are Linux-pinned (io_uring, seccomp, inotify, `/proc`, ALSA, eBPF, x86-only
asm) or need specific hardware, so their landed fixes **could not be build/tested here**.
This is the to-do list for a Claude running on Linux to pick up.

## Ground rules

- **Toolchain: Zig `0.16.0` ONLY.** Do not use 0.15 — the tree uses 0.16 idioms
  (`std.Io.Writer`, `.empty` ArrayLists, `std.c.arc4random_buf`, no `std.crypto.random.bytes`,
  no `std.time.sleep`). Invoke it by an absolute path if a stale `zig` shadows it.
- **All fixes referenced below are already on `origin/main`.** Your job is mostly to
  *verify* them build+test on Linux, plus a few genuine fixes flagged **[FIX]**.
- **The per-program audit reports and wave-results are gitignored** (kept local on the
  macOS host), so you will NOT get them from `git pull`. Everything you need is inlined
  here. `docs/ffi-migration-plan.md` **is** tracked — read it for the Tier 2 work.
- **Report back**: append results to a new `docs/LINUX-RESULTS.md` (commit it) — per item:
  build ✓/✗, test ✓/✗, and anything you had to fix. Do **not** weaken/skip a test to go green.
- Standard guardrails from `CLAUDE.md` apply: no FFI signature/struct/header changes without
  updating every consumer in lockstep; no hand-rolled crypto/parsers; never disable a
  security check to compile.

---

## P1 — Security-critical (verify the fix actually enforces on Linux)

### zig_jail — seccomp enforcement (THE proof is a Linux/x86_64 runtime test)
Wave 1 made `buildSeccompFilter` emit `KILL` rows for the parsed `blocked` list (was a
no-op) and added an x32/high-nr guard. On macOS the runtime test is `SkipZigTest`.
- **Run on x86_64 Linux**: `zig build test` in `programs/zig_jail`.
- **Verify**: the test "seccomp: blocked syscall traps at runtime (Linux/x86_64)" actually
  runs and passes — it forks a child with `default_action=allow` + `getpid` blocked and
  asserts the child dies with `SIGSYS`. This is the only test that proves the fix works.

### guardian_shield — self-preservation bypass fix (security product, Linux-pinned)
`build.zig` cross-pins to `x86_64-linux-gnu.2.39`, so nothing builds/runs on aarch64 macOS.
Wave 1 fixed `shouldBypassAllProtection` to use `startsWith` (prefix) instead of
`indexOf` (substring) at `src/libwarden/main.zig:272-273`.
- **Verify on x86_64 Linux**: `zig build` and `zig build test`.
- **[FIX]** The macOS session **trimmed** the QW6 orphan-test wiring in `build.zig` to only
  the 3 files that compile (`filter_engine.zig`, `emoji_database.zig`, `emoji_sanitizer.zig`).
  Three orphan test files carry pre-existing Zig-0.16 API drift and are TODO-commented out
  of `orphan_test_sources`: `src/warden/warden.zig`, `src/zig_http_sentinel/config.zig`,
  `src/zig_sentinel/correlation.zig`. Also pre-existing: `grimoire.zig:912` (ArrayList API
  drift, missing struct fields) and `wardenctl/main.zig:438` (`json.ObjectMap.init` arity).
  Fix the 0.16 drift, re-add the 3 files to `orphan_test_sources`, and get `zig build test` green.

### distributed_kv — dangling-init fix + WAL tests
Wave 1 fixed a use-after-return where `getStateMachine()/getTransport()` stored `&local`
into the heap node (`src/lib.zig:143-148`). On macOS 2/20 tests fail: `wal.zig` "wal write
and read" and "wal recovery" use Linux-only raw syscalls (`std.os.linux.write/read`).
- **Run on Linux**: `zig build test` in `programs/distributed_kv` — expect **20/20** (the 2
  WAL failures are macOS-only). If they still fail on Linux, that's a real WAL bug to fix.

---

## P2 — Linux-pinned programs (fixes landed; build+test to confirm)

For each: `cd programs/<name> && zig build && zig build test`. Note the platform reason and
what to sanity-check. Install the noted system deps first.

| Program | Platform dep | Landed fix to confirm | Notes |
|---|---|---|---|
| `audio_forge` | ALSA (`libasound-dev`) | QW1/QW5 packaging; audit also flagged dangling `AudioEngine.init` self-ptrs + WAV div0/OOB (Tier 1A — check if applied) | `zig build` fails on macOS purely on `linkSystemLibrary("asound")` |
| `zero_copy_net` | io_uring (kernel ≥5.1, `liburing`?) | QW1/QW8; Tier 1B BufferPool→Treiber-stack rewrite (verify landed) | `zig build` is a no-op skip on macOS; real suite only runs on Linux |
| `stratum_engine_grok` | io_uring | Wave 2: JSON-arena UAF + io_uring send-buffer UAF fixes (`protocol.zig:60-62`, `client.zig:101-107`) + test step | verify the UAF fixes under the real io_uring path |
| `stratum_engine_claude` | io_uring | Wave 1: JSON-IN-FMT → `std.json.Stringify` in `proxy/websocket.zig` + `sanitizeWorkerName` ingress | proxy files are gated out of the macOS test graph; compile + run on Linux |
| `duck_cache_scribe` | inotify | Wave 2: non-NUL `inotify_add_watch` path fixed (`[:0]const u8`/`dupeZ`), Linux exe gated to Linux, recursive watch added | verify recursive inotify watch actually fires |
| `zigix_monitor` | `/proc` | Wave 1B: `clock_gettime` return checks (3 sites), bounded epoch math, shared robust `/proc` reader | 9/9 tests pass on macOS but `/proc` behavior is only meaningful on Linux |
| `zigix_desktop` | Linux syscalls | Wave 2: `isProcessAlive` via `waitpid(WNOHANG)`, fd-hygiene + non-NULL argv/envp on fork | **no test step** — verify build + process-reap behavior manually |
| `zig_tui` | (was Linux-only) | Wave 2: replaced Linux `ioctl 0x5413` with portable `std.posix` + fixed UTF-8/CSI parser | fix restored macOS; confirm it still builds+runs on Linux |
| `chronos_engine` | eBPF/PTY | Wave 1: `popen`→absolute-path argv (RCE fix) | eBPF telemetry stack only builds on Linux; verify |
| `cognitive_telemetry_kit` | eBPF (`vmlinux.h`/BTF) | Wave 1: parameterized export SQL (`sqlite3_bind_text`), dropped `root:root` default | `chronos-hook` needs kernel BTF; wire its tests on Linux |

---

## P3 — Hardware-specific

### zig_dpdk — needs x86_64 (has x86-only inline asm)
QW1/QW5 landed. `src/drivers/zigix.zig:29` `compilerFence()` uses x86-only inline-asm
clobber syntax that Zig 0.16 rejects on aarch64; reached via the test root.
- **On x86_64 Linux**: `zig build test`.
- **[FIX]** If it still fails to compile: fix the `compilerFence` clobber to the 0.16
  `asm volatile ("" ::: .{ .memory = true })` form, or arch-gate it. Do not delete the fence.

### hydra — needs NVIDIA GPU + CUDA
Wave 1B added a test step + fixed a real latent `@alignCast` unaligned-load bug in
`simd_batch.zig`. The `hydra-bench` target hard-links `-lcuda -lcudart -lnvrtc`.
- **On a Linux + NVIDIA box with CUDA**: `zig build` (full, incl. bench) + `zig build test`.
- **Verify**: `gpu_kernel.zig` queries the device compute capability at runtime instead of
  the old hardcoded `compute_86`.

---

## Tier 2 — wallet-signing FFI (2.1 + 2.2): DONE on macOS, Linux just confirms

**Update 2026-07-17:** 2.1 (CMerkleProof `tx_count`) and 2.2 (tx-builder opaque handle) are
**landed and verified on macOS** — see `docs/ffi-contract-changes-2026-07.md` for the full
bulletin. Producer (`simd_crypto_ffi`) 99/99, walletcore 87/87 (incl. RAII/concurrency
tests), quantum_vault compiles unchanged, and the iOS + Android `quantum_crypto` archives
were rebuilt from source on the Mac and confirmed to carry the new symbols. **Linux's only
Tier-2 job:** run `programs/build-android-libs.sh quantum_crypto` (pure Zig cross-compile —
already confirmed to work from macOS, so it will from Linux), then confirm the Android app
(`cargo-ndk` / Tauri) links + runs. No source changes remain (2.2's legacy-shim removal is a
later, optional pure-deletion follow-up). The original spec below is retained for reference.

---

### Original spec (reference)

**Read `docs/ffi-migration-plan.md` first** (it IS in the repo) — it has the exact ABI diff,
every verified consumer with line numbers, and the lockstep order. Status: 2.3/2.4/2.5 landed;
**2.1 + 2.2 are the remaining pair** and were deliberately NOT started because they touch live
wallet signing across three consumer repos and the macOS host could not verify the iOS/Android
archive consumers.

- **2.1** `CMerkleProof` gains `tx_count: u32` (struct 1032→1036) + a non-zero guard; restores
  CVE-2012-2459 depth-pinning. Consumer: `walletcore/src/quantum_crypto.rs` (mirror the field
  in the `#[repr(C)]` struct + `Default` + `to_c_proof`). Add BOTH a compile-time
  `assert!(size_of::<CMerkleProof>()==1036)` **and** a runtime test asserting
  `size_of::<CMerkleProof>() == unsafe { quantum_spv_proof_size() }` (binds the mirror to the
  actually-linked `.a`, catches a stale per-target archive).
- **2.2** Replace the threadlocal tx-builder singleton with an opaque handle: add
  `quantum_tx_builder_new/_free`, give the 14 stateful fns a `handle` first param. Use
  **additive-then-cutover** (add new symbols alongside the kept legacy ones, migrate
  walletcore's ~32 tx-build refs, rebuild/relink, verify, THEN a later shim-removal pass).
  Do **NOT** add `unsafe impl Send/Sync` on the Rust `TxBuilder` — keep it `!Send + !Sync`
  and document "one handle per thread". Wrap the handle in an RAII guard in the fuzz driver
  so error-path early-returns don't leak ~50 KB/builder.

**Linux's part of this**: after the Zig producer + walletcore edits land, the **Android**
archives are rebuilt via `programs/build-android-libs.sh` (needs the Android NDK — a Linux
task). The **iOS** archives + macOS `.a` repack need macOS+Xcode, so this item must be
coordinated across a Linux box (Android + Rust consumer build/test) and a macOS box (iOS).
Every rebuilt Zig `.a` consumed on Apple platforms must be run through
`scripts/repack-for-xcode.sh` (Zig 0.16 emits 2-byte-aligned Mach-O members; Apple ld-prime
needs 8) — see the migration plan.

Recommend doing 2.1+2.2 as one focused pass with device/CI access to the wallet flows, not
as a blind ABI change.

---

## Also filed as brain-todos (macOS-side, listed here for visibility)

- **zdedupe iOS xcframework refresh** — `tauri_apps/zdedupe/scripts/build-zig-xcframework.sh`
  omits `repack-for-xcode.sh` before `lipo`, so `lipo` rejects Zig-0.16 archives as "empty".
  Fix: repack each per-arch `.a` before `lipo`, then rerun with source
  `programs/zdedupe` to refresh the iOS slices (they currently carry the 7 removed-but-
  unreferenced C exports — harmless dead weight). This is a **macOS** task (needs `xcodebuild`).
- **zig_ai default build** — pre-existing `config.zig`↔`zig_toml` Array-API drift
  (`config.zig:102,151`) keeps `zig build` red (the test step is green). Own fix, either host.
