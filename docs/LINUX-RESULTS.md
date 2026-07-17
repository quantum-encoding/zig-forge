# Linux verification results

_Companion to `docs/LINUX-TODO.md`. Host: Arch Linux x86_64, Zig 0.16.0 (`~/zig-0.16.0-stable/zig`), GCC 16 / glibc, cargo 1.97.0. This file is the running record across sessions — the P1 zig_jail + distributed_kv fixes were made by an earlier session; the Tier 2 FFI confirmations, the guardian_shield fixes, and the P2/P3 sweep were added after the Tier 2 migration was pulled._

## Host toolchain blocker (read first)

**Zig 0.16's self-hosted ELF linker cannot link this host's system `crt1.o`.** GCC 16 / recent glibc ship `/usr/lib/crt1.o` with an `.sframe` section carrying `R_X86_64_PC64` relocations; Zig 0.16's default linker aborts (`fatal linker error: unhandled relocation type R_X86_64_PC64 ... in crt1.o:.sframe`). Hits any native build that links libc into an exe/test. **Not a code defect** — system `cc` (GNU ld) and `-fllvm` (ld.lld) and `-target x86_64-linux-musl` all link the same code fine.

**Sanctioned fix:** set `.use_llvm = true` on the affected `build.zig` targets (LLD handles `.sframe`). Already applied to `distributed_kv` (earlier session) and now `zig_jail`. Alternative for ad-hoc runs: `-Dtarget=x86_64-linux-musl` (kernel behaviour like seccomp/`/proc`/WAL is libc-flavour-independent). Second artifact: the build runner's `--listen=-` IPC prints a spurious "failed command" when a test **forks a child** (e.g. the seccomp SIGSYS test) — the overall step still exits 0 and the test binary passes when run directly.

---

## Tier 2 — wallet-signing FFI (2.1 CMerkleProof + 2.2 tx-builder handle) — CONFIRMED

Producer `simd_crypto_ffi` on Linux:

| Check | Result |
|---|---|
| `zig build` (host lib) | ✓ clean |
| `zig build test` (module tests) | ✓ 66/66 module tests pass (the FFI test-*exe* link hits the `.sframe` blocker; not a code failure) |
| New symbols in `libquantum_crypto.a` | ✓ `quantum_spv_proof_size`, `quantum_tx_builder_new`, `quantum_tx_builder_free`, `quantum_tx_sign_ctx`, `quantum_version` exported |
| Runtime values (probe linked via system `cc`) | ✓ `proof_size = 1036`, `version = quantum-crypto-1.1.0`, `tx_builder_new/_free` OK |
| 2.2 legacy shims retained (additive) | ✓ `quantum_tx_builder_init/_add_input`, `quantum_tx_sign` exported alongside `_ctx` variants |
| Android ARM64 (`zig build android`) | ✓ AArch64 ELF archive carries `proof_size`, `tx_builder_new`, `tx_sign_ctx` |

> **⚠️ Do NOT run the optional 2.2 legacy-shim removal.** The public `quantum_vault` links the **legacy threadlocal** builder API directly — deleting the shims breaks its link. Coordinate first.

### 2.1 — the public `quantum_vault` is a MISSED lockstep consumer (contradicts the docs)

The migration docs describe the Mac poly-repo `quantum_vault` (walletcore-mediated, "does not declare CMerkleProof, no source change"). **The public GitHub `quantum_vault` (cloned here) is a different, older architecture: NO walletcore; `src-tauri/src/core/quantum_crypto.rs` is an inline FFI binding that DOES declare `CMerkleProof` and calls the SPV verify fns.** Its `CMerkleProof` was the **old 1032-byte** layout (no `tx_count`) — linking it against the fresh 1036-byte producer is a real ABI mismatch (reads 4 bytes past the Rust struct, rejects `tx_count==0`). Its only size test (`proof_size > 1000`) stays green at 1036 — the exact silent-drift hazard the plan warned about.

**Fix applied to `quantum_vault` (committed locally in `~/quantum_vault`, NOT pushed):** added `tx_count` to `#[repr(C)] CMerkleProof` + `Default`, to the high-level `MerkleProof` + `to_c_proof`; added compile-time `assert!(size_of::<CMerkleProof>()==1036)` and upgraded the runtime size test to bind to `quantum_spv_proof_size()`; set `tx_count: 2` in the 3 (2-leaf) SPV test literals.

**Validated** by a standalone crate mirroring the *fixed* binding against the fresh producer — 6/6: size==proof_size==1036, version 1.1.0, 2-leaf proof verifies, wrong-root rejected, `tx_count==0` rejected, and **CVE-2012-2459 depth-pin** (1 hash, `tx_count=1000`) rejected.

**Full desktop `cargo build` not completed** — `build.rs` points its Linux `zig_forge_base` at a **stale March pre-Tier-2 checkout** (`/home/founder/github_public/quantum-zig-forge/programs`, still on this box), links ~11 zig libs, and hardcodes `/usr/lib/clang/21` (this host has **clang 22**). See notes at bottom.

---

## P1 — Security-critical

### zig_jail — build ✓ / test ✓ (43/43) — [earlier session; re-verified + hardened here]

Earlier session made the real fixes (test code + build wiring only, no production logic): wired the module test blocks into `main.zig` (they weren't collected, so the seccomp proof never ran on any host), fixed 5 const-literal→`var` test sites, ported `std.posix.fork/waitpid/W`→`std.os.linux.*` in the Linux-gated runtime test, and `dupe`'d the `CapabilityConfig` test's `keep` slice (deinit frees each element — was a segfault). **This session:** added `.use_llvm = true` to the exe and test targets (host `.sframe` blocker) → **native `zig build` and `zig build test` both exit 0**. Test 20 `seccomp: blocked syscall traps at runtime (Linux/x86_64)` passes — child with `getpid` blocked dies SIGSYS. The Wave-1 seccomp denylist fix is behaviourally verified on a real kernel.

### distributed_kv — build ✓ / test ✓ (20/20) — [earlier session; re-verified here]

Native `zig build test` = exit 0, 20/20. Both WAL tests (`wal write and read`, `wal recovery`, `wal checksum`) pass — the 2/20 macOS failures are platform-only. Earlier session fixed the `.sframe` blocker with `.use_llvm = true` on the test artifact (in `build.zig`, committed). Confirms the Wave-1 dangling-init fix.

### guardian_shield — `zig build` ✓ (was ✗) / test ◑ 16/18 — [this session; supersedes the earlier stale note]

_(The Tier 2 pull rewrote `guardian_shield/build.zig`, trimming the missing-test-file references the earlier session hit; work below is on the post-pull tree.)_

**Fixes applied (committed to zig-forge) — `zig build` is now green:**
- Zig 0.16 ArrayList drift `.{}`→`.empty`: `warden.zig:109`, `grimoire.zig:912`, `zig_sentinel/main.zig:684`.
- `json.ObjectMap` now unmanaged (`wardenctl/main.zig:438-453`): `.init(alloc)`→`: json.ObjectMap = .empty` + `put(alloc, …)`.
- never-mutated `var`→`const` (`correlation.zig:429`).
- **SECURITY BUG — emoji steganography bypass** (`emoji_sanitizer.zig` `sanitizeText`): window loop broke at the variation-selector start byte (`0xEF`), splitting an emoji from its `\x00\x00<payload>` so it was never redacted. Aligned it with the correct window logic already in `detectAnomalies`. Test `sanitize malicious text` now passes.
- **MEMORY-SAFETY BUG — invalid free / SIGABRT** (`grimoire.zig` `getProcessBinaryName`): `getOrPut(pid)` created a cache slot but the `ProcessNotFound` error path (any nonexistent pid) returned leaving `value_ptr` undefined; `deinit` later `free`d that garbage. Added `errdefer _ = self.binary_cache.remove(pid)`. The `detect reverse shell pattern` test no longer crashes.

**Pre-existing failures surfaced, NOT fixed (outside the compile-drift [FIX] scope; non-Linux-specific; in code that never compiled/ran before — flagged for a focused pass):**
- `grimoire: pattern struct size` asserts `@sizeOf(GrimoirePattern) <= 1024`; actual **1272** (struct comment claims "~512 max"). The real guardrail `hot patterns fit in L1` (`total <= 8192`) passes at 6360. Stale heuristic — not weakened.
- `grimoire: detect reverse shell pattern` runs (no longer crashes) but the pattern doesn't fire for the synthetic pid — a functional gap in the pattern engine.
- Orphan-test re-wiring (`warden.zig`, `zig_http_sentinel/config.zig`, `zig_sentinel/correlation.zig`) left TODO-commented in `build.zig`: `warden.zig` + `correlation.zig` tests compile+pass but **leak memory** (`warden.zig:126`, `correlation.zig:527` — un-freed `dupe`s), and **`config.zig` has further Io drift** (`Dir.createFile` now takes an `io` param, `config.zig:132`). Re-wiring would turn `zig build test` red on these — left for focused work.

---

## P2 — Linux-pinned build sweep

Clean `zig build`: **`stratum_engine_grok`** (io_uring), **`duck_cache_scribe`** (inotify), **`zigix_desktop`**, **`zig_tui`**.

Blocked on missing **system deps** (install, then rebuild): `audio_forge` (`libasound`/ALSA), `chronos_engine` (`dbus-1`), `stratum_engine_claude` (`mbedtls` — installed as a glibc `.so`; build native, not musl).

Need a **native-glibc + LLD** build to confirm (musl gave false negatives on glibc-only symbols/libs): `zero_copy_net`, `zigix_monitor` (musl `timespec` cimport), `cognitive_telemetry_kit` (hits `.sframe` — add `use_llvm`).

## P3

`zig_dpdk` (x86_64 host qualifies): needs native build (`pread64` is glibc-only; musl false-negative). `hydra`: `zig build` ok; CUDA bench target needs an NVIDIA box (not linked here).

---

## quantum_vault build notes (for whoever owns quantum_vault)

- `src-tauri/build.rs` Linux `zig_forge_base` = `/home/founder/github_public/quantum-zig-forge/programs` (**stale March pre-Tier-2 checkout**). Point it at `/home/founder/zig-forge/programs` and rebuild the ~11 dep libs to link against the real Tier-2 tree.
- `build.rs:131` hardcodes `/usr/lib/clang/21/lib/linux` for `clang_rt.builtins`; this host has **clang 22**.
- No walletcore anywhere in the repo — the crypto is an inline binding (`src-tauri/src/core/quantum_crypto.rs`) + `quantum-vault-sys`. The docs' walletcore-mediation assumptions do not apply here.
