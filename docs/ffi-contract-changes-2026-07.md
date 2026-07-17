# FFI contract changes — simd_crypto_ffi (libquantum_crypto) — 2026-07

_Handoff bulletin for the teams/agents that consume `libquantum_crypto` so each app can
update itself. Companion to `docs/ffi-migration-plan.md` (the full ABI spec)._

**Producer:** `zig-forge/programs/simd_crypto_ffi` → `libquantum_crypto.a`
**Version string:** `quantum_version()` bumped `quantum-crypto-1.0.0` → **`quantum-crypto-1.1.0`**.

There are two contract changes. **2.1 is landed** (this bulletin). **2.2 is pending** — its
spec is here so you can prepare, but nothing about 2.2 has shipped yet.

---

## 2.1 — `CMerkleProof` gains a `tx_count` field (LANDED, ABI-breaking, verified)

### What changed
`CMerkleProof` grew a 4th field. **Struct size 1032 → 1036 bytes.**

```
// BEFORE (1032 bytes)                 // AFTER (1036 bytes)
struct CMerkleProof {                  struct CMerkleProof {
  uint8_t hashes[32][32];  // 1024       uint8_t hashes[32][32];  // 1024
  uint32_t hash_count;                   uint32_t hash_count;
  uint32_t index;                        uint32_t index;
}                                        uint32_t tx_count;  // NEW @ offset 1032
                                       }
```

`tx_count` is the **total transactions in the block**, caller-supplied. It pins the required
Merkle depth (CVE-2012-2459). The two SPV verify functions previously *synthesized*
`tx_count = 1 << hash_count` and ignored any caller value, which made the depth check
tautological at the FFI boundary — a valid-root proof could be replayed at the wrong block
shape. The verify functions now use `proof.tx_count` and **reject `tx_count == 0`**
(`invalid_input`). Function signatures are unchanged (the struct is passed by pointer);
`quantum_spv_proof_size()` now returns 1036.

### Who must do what

| Consumer | Action | Reason |
|---|---|---|
| **walletcore** (`src/quantum_crypto.rs`) | ✅ **DONE this session** | Sole code consumer: mirrored the field in `#[repr(C)] CMerkleProof` + `Default`, added `tx_count` to the high-level `MerkleProof` + `to_c_proof`, added a compile-time `size_of == 1036` assert **and** a runtime `size_of::<CMerkleProof>() == quantum_spv_proof_size()` test (binds the mirror to the actually-linked `.a`), plus an FFI depth-pin test on the Zig side. |
| **quantum_vault** (`src-tauri`) | **Rebuild + repack the vendored `.a` only. NO source change.** | Links `libquantum_crypto` but does **not** declare `CMerkleProof` or call the SPV verify fns (its SPV use is `CBlockHeader`/`quantum_spv_verify_pow`/`block_hash` only). C links by symbol name; the symbols it uses are unchanged. |
| **CosmicDuckOS** (iOS/macOS app) | **Rebuild `libquantum_crypto.a` + `libwalletcore.a` for its targets, repack the macOS `.a`, relink. NO Swift change.** | `walletcore.h` exposes no SPV/merkle symbols; `WalletCoreFFI.swift` doesn't call SPV. Only the vendored archives need refreshing. |
| **Android** (`build-android-libs.sh`) | **Rebuild the ARM64 archive** (NDK — Linux task). | Same as above: no code references the struct; just refresh the packaged `.a`. |

### The rule that makes this safe
Only **walletcore** references `CMerkleProof` (verified: `rg CMerkleProof` across walletcore,
quantum_vault, CosmicDuckOS returns hits only in simd_crypto_ffi + walletcore). Every other
consumer just relinks the new archive. **If you ever hand-copy a vendored `.a`, the new
runtime test `test_cmerkleproof_layout_matches_linked_zig_lib` will fail loudly on a stale
(1032-byte) archive instead of silently reading 4 bytes past the struct** — run
`cargo test -p walletcore quantum_crypto::tests::test_cmerkleproof_layout` after any relink.

### Repack reminder (Apple platforms)
Every rebuilt Zig `.a` consumed on macOS/iOS **must** go through
`zig-forge/scripts/repack-for-xcode.sh` before linking — Zig 0.16 emits 2-byte-aligned
Mach-O members; Apple's ld-prime needs 8-byte, else you get `not 8-byte aligned` link
errors. (This bit us repeatedly this session; it applies to `lipo` too — repack each
per-arch slice *before* `lipo -create`.)

---

## 2.2 — tx-builder: threadlocal singleton → opaque handle (LANDED on producer + walletcore, additive)

The stateful transaction builder was a hidden `threadlocal` global in `ffi-grok.zig`
(`quantum_tx_builder_init()` + 14 state-mutating fns with no handle) — finding 5 (hidden
global state). It now has an explicit caller-owned handle API, added **additively**
alongside the legacy fns (legacy still works; deleted in a later shim-removal pass).

### New symbols (additive — legacy untouched)
- `quantum_tx_builder_new() -> void*`, `quantum_tx_builder_free(void*)`.
- `_ctx`-suffixed variants of the 13 stateful fns, each taking the handle as their **first
  parameter**: `quantum_tx_builder_add_input_ctx`, `…_add_p2wpkh_output_ctx`,
  `…_add_p2pkh_output_ctx`, `…_add_p2tr_output_ctx`, `…_add_op_return_ctx`,
  `…_total_input_ctx`, `…_total_output_ctx`, `…_fee_ctx`, `…_estimate_vsize_ctx`,
  `…_input_count_ctx`, `…_output_count_ctx`, `quantum_tx_sign_ctx`,
  `quantum_tx_compute_sighash_ctx`. Each handle is one independent builder.
- **Why new names (not same-name-new-arity):** C links by symbol name. A name-preserving
  arity change would let a stale wallet binary silently pass garbage as the handle
  (money corruption). New names make a stale binary fail to *link* (loud) instead.

### Who must do what

| Consumer | Action | Reason |
|---|---|---|
| **walletcore** (`src/quantum_crypto.rs`) | ✅ **DONE this session** | Migrated `TxBuilder`'s internals to the handle API: struct holds an opaque `handle: *mut c_void`, all 13 methods call the `_ctx` variants, an `impl Drop` frees the handle on every path (scope/panic/cancel), the mutex is retained as a now-harmless serialization guard, and `TxBuilder` stays `!Send + !Sync` (raw pointer — **no `unsafe impl Send/Sync`**). **The public Rust API of `TxBuilder` is unchanged** (`new`, `try_acquire`, all methods keep their signatures). 87/87 tests incl. the 5 RAII/concurrency property tests. |
| **quantum_vault** (`bitcoin.rs:629`, `litecoin.rs:688`) | **No source change; `cargo build`.** | Uses walletcore's `TxBuilder` **Rust type**, whose public API is unchanged. cargo recompiles walletcore (path dep) against the new Zig `.a`. Confirmed compiling this session. |
| **CosmicDuckOS** (iOS) / **Android** | **Rebuild + repack the vendored archives. No source change.** | No app-level code calls the builder FFI symbols directly (verified); they consume it only through walletcore's stable Rust API. |

### Remaining (small): legacy shim removal
The legacy threadlocal fns (`quantum_tx_builder_init` + the 14 no-handle fns) and the hidden
`threadlocal` global remain in the producer as an unused safety net, plus their now-unused
`extern` decls in walletcore. Once every platform (iOS/Android/quantum_vault) is confirmed
on the new API, a follow-up deletes them — a pure deletion, no consumer change (walletcore
already uses only the `_ctx` API).

---

## Verification status (2.1)

- Producer `simd_crypto_ffi`: `zig build` ✓, `zig build test` ✓ (98/98 — includes the new
  `quantum_spv_verify_merkle_proof honors caller tx_count` FFI test).
- walletcore: `cargo test -p walletcore quantum_crypto::tests` ✓ (62/62), including
  `test_cmerkleproof_layout_matches_linked_zig_lib` — the compile-time `size_of == 1036`
  and the runtime `size_of == quantum_spv_proof_size()` (linked-lib) assert both pass on
  the freshly rebuilt + repacked macOS archive.
- quantum_vault: pending on its host. Note: quantum_vault depends on the **walletcore
  crate** (path dependency) and links `libquantum_crypto`, so `cargo build` recompiles
  walletcore from source automatically — the only manual step is ensuring the rebuilt
  `simd_crypto_ffi` `.a` is repacked (`repack-for-xcode.sh`) and in the link dir. No
  quantum_vault source change.
- CosmicDuckOS (iOS) / Android: rebuild+repack the vendored archives on each host (see
  table). No source change.
