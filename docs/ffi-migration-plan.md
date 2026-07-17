# Tier 2 FFI-Breaking Migration Plan

_Generated 2026-07-17 from an investigation-only mapping pass over the audited Tier 2 items. This is a **pre-change checkpoint**: it records the exact ABI diff, every verified consumer, and the safe lockstep edit order for each FFI-breaking change **before** any code is touched, so the migration can be paused and resumed without re-deriving anything._

**Repo rule:** an FFI contract (exported symbol names, signatures, struct layouts, header contents) may not change unless every consumer is updated in the same change. Each item below lists its consumers and the order that never leaves a consumer linking an incompatible ABI.

**Status:** none of these have been applied yet. Check the box when landed.

| # | Program | Change | Consumers | Status |
|---|---|---|---|---|
| 2.1 | `simd_crypto_ffi` | CMerkleProof +tx_count (1032->1036) | 6 | ✅ LANDED simd_crypto_ffi efffe284 + walletcore 292e5b3 (verify pending: quantum_vault/iOS/Android) |
| 2.2 | `simd_crypto_ffi` | quantum_tx_builder_new (NEW) | 8 | ☐ not started |
| 2.3 | `financial_engine` | FfiTradingSignal (Rust mirror) f64 -> i64 | 10 | ✅ LANDED quantum_vault 5a703cef (consumer-only) |
| 2.4 | `zig_lens` | ZIG_LENS_LANG_GO=5 | 7 | ✅ LANDED zig-forge 7802b349 (in-tree binding only) |
| 2.5 | `zdedupe` | remove 7 unused C exports | 7 | ✅ LANDED zig-forge 688ada1f + zdedupe b500aca (iOS xcframework refresh deferred, harmless) |
| 2.6 | `zig_ratelimit` | (moot — see below) | — | ✅ N/A |

---

## 2.1 — `simd_crypto_ffi`

### Current ABI
```
PRODUCER — /Users/director/work/poly-repo/zig-forge/programs/simd_crypto_ffi/src/ffi-grok.zig
Struct (ffi-grok.zig:1616-1623), extern struct, C ABI, size = 1032 bytes, align = 4, no padding:
  pub const CMerkleProof = extern struct {
      hashes: [MAX_MERKLE_PROOF_DEPTH][32]u8,  // 1024 bytes (MAX_MERKLE_PROOF_DEPTH=32, ffi-grok.zig:1603)
      hash_count: u32,                         // +1024 = offset 1024
      index: u32,                              // +1028 = offset 1028
  };
Synthesis sites (the vulnerability — both fabricate tx_count from hash_count so the depth-pin is tautological):
  ffi-grok.zig:1672 (in quantum_spv_verify_merkle_proof, exported :1645-1681):
     .tx_count = if (proof.hash_count == 0) 1 else (@as(u32, 1) << @intCast(proof.hash_count)),
  ffi-grok.zig:1906 (in quantum_spv_verify_payment, exported :1864-1931):
     .tx_count = if (proof.hash_count == 0) 1 else (@as(u32, 1) << @intCast(proof.hash_count)),
Exported signatures (UNCHANGED by this fix — pointer-to-struct only):
  export fn quantum_spv_verify_merkle_proof(tx_hash: [*c]const u8, merkle_root: [*c]const u8, proof: *const CMerkleProof) c_int
  export fn quantum_spv_verify_payment(tx_hash: [*c]const u8, proof: *const CMerkleProof, header: *const CBlockHeader, prev_hash: [*c]const u8, check_pow: bool) c_int
  export fn quantum_spv_proof_size() usize { return @sizeOf(CMerkleProof); }  // ffi-grok.zig:1939-1941, auto-tracks size
  export fn quantum_version() [*:0]const u8 { return "quantum-crypto-1.0.0"; }  // ffi-grok.zig:588-589
INTERNAL (already correct, NO change): src/bitcoin/spv.zig MerkleProof already HAS tx_count:u32 (spv.zig:131-142); verifyMerkleProof rejects tx_count==0 and enforces hashes.len==requiredMerkleDepth(tx_count) (spv.zig:307-317); requiredMerkleDepth at :147-149.
No C header ships from this program (consumers hand-mirror the ABI).
```

### Proposed ABI
```
PRODUCER ffi-grok.zig — append tx_count after index (new size = 1036 bytes, align 4, no padding):
  pub const CMerkleProof = extern struct {
      hashes: [MAX_MERKLE_PROOF_DEPTH][32]u8,  // offset 0,  1024 bytes
      hash_count: u32,                         // offset 1024
      index: u32,                              // offset 1028
      tx_count: u32,                           // offset 1032  <-- NEW: total tx count in the block, caller-supplied
  };
Both synthesis sites (ffi-grok.zig:1672 and :1906) become:
      .tx_count = proof.tx_count,
Add an explicit guard near the existing depth check in BOTH verify fns (after the hash_count>MAX check at :1654 / :1879):
      if (proof.tx_count == 0) { setLastError("SPV: tx_count must be non-zero"); return @intFromEnum(SpvResult.invalid_input); }
Bump quantum_version() -> "quantum-crypto-1.1.0" (ffi-grok.zig:589). Signatures of the two verify fns and quantum_spv_proof_size are textually unchanged; the ABI change is purely the struct layout (1032 -> 1036) that flows through the *const CMerkleProof parameter.
Add a NEW FFI-level test (none exists today) asserting a valid-root/wrong-depth proof with attacker-chosen tx_count is rejected — e.g. build the 2-leaf example, then call quantum_spv_verify_merkle_proof with hash_count matching but tx_count claiming a deeper tree, expect invalid_merkle_proof.

CONSUMER walletcore/src/quantum_crypto.rs — #[repr(C)] mirror gains the field in the same order:
  #[repr(C)] pub struct CMerkleProof { pub hashes: [[u8;32]; MAX_MERKLE_PROOF_DEPTH], pub hash_count: u32, pub index: u32, pub tx_count: u32 }
  Default impl adds tx_count: 0 (quantum_crypto.rs:701-709).
  High-level pub struct MerkleProof (quantum_crypto.rs:1083-1088) gains `pub tx_count: u32`.
  to_c_proof (quantum_crypto.rs:1092-1106) sets `c_proof.tx_count = self.tx_count;`.
  (extern fn decls at :155-181 and :183 are unchanged — pointer args only.)
```

### Symbols whose ABI changes
- `CMerkleProof (extern/#[repr(C)] struct layout: 1032->1036 bytes, new u32 field tx_count at offset 1032)`
- `quantum_spv_verify_merkle_proof (param struct layout only; signature text unchanged)`
- `quantum_spv_verify_payment (param struct layout only; signature text unchanged)`
- `quantum_spv_proof_size (return value changes 1032->1036)`
- `quantum_version (string bump 1.0.0->1.1.0)`

### Consumers (lockstep)
| Path | What it mirrors / calls |
|---|---|
| `/Users/director/work/poly-repo/walletcore/src/quantum_crypto.rs` | ONLY code consumer that mirrors the struct and calls the verify fns. #[repr(C)] CMerkleProof mirror at :690-699 (+ Default at :701-709); externs quantum_spv_verify_merkle_proof :155-159, quantum_spv_verify_payment :175-181, quantum_spv_proof_size :183; high-level MerkleProof struct :1083-1088 (NO tx_count today); to_c_proof :1092-1106 (sets hash_count/index, must set tx_count); safe wrappers verify_merkle_proof :1759-1775 and verify_spv_payment :1806-1831; in-crate tests constructing MerkleProof literals need tx_count added: :3626-3629, :3641-3644, :3685-3688; size test assert!(proof_size>1000) at :3544-3551 still passes at 1036. NOTE: no compile-time assert ties size_of::<CMerkleProof>() to quantum_spv_proof_size() — layout drift would be SILENT; recommend adding one. |
| `/Users/director/work/poly-repo/walletcore/build.rs` | Links static=quantum_crypto from per-target dirs (:18-48): host apple-darwin -> simd_crypto_ffi/zig-out/lib; aarch64-apple-ios -> ios-libs/ios-arm64; ios-sim/x86_64-ios -> ios-libs/ios-sim-arm64; aarch64-linux-android -> simd_crypto_ffi/zig-out/lib/android-arm64. Must relink the rebuilt .a (no edit needed). |
| `/Users/director/work/poly-repo/quantum-encoding-ecosystem/quantum_vault/src-tauri/build.rs` | REBUILD-ONLY. Links static=quantum_crypto (:65-69) from simd_crypto_ffi/zig-out/lib. Does NOT declare CMerkleProof and does NOT call the verify fns — its SPV usage is CBlockHeader/quantum_spv_verify_pow/block_hash only (fuzz/src/lib.rs:227, fuzz_targets/fuzz_spv_header.rs:37). Symbol names unchanged, so it only needs the fresh .a; no source edit. |
| `/Users/director/work/poly-repo/quantum-encoding-ecosystem/quantum_vault/AUDIT_SURFACE_INVENTORY.md` | Doc only. H-2 row (:201) explicitly tracks this as 'FFI struct wire-through (CMerkleProof.tx_count) pending — defer to Diff C' = confirms change not yet applied. Update status after landing. |
| `/Users/director/work/poly-repo/CosmicDuckOS/CosmicDuckOS.xcodeproj/project.pbxproj` | REBUILD+REPACK-ONLY. Directly links libquantum_crypto.a (:760, :886) and libwalletcore.a (:759, :885) and includes walletcore/include (:704 etc). walletcore.h exposes NO SPV/merkle symbols and the Swift side (Services/Wallet/WalletCoreFFI.swift) does not call SPV — so no source edit, but both static libs must be refreshed and the macOS .a repacked. |
| `/Users/director/work/quantum-zig-forge/monorepo-lens.json` | Scanner artifact (zig_lens output), not a build input. Ignore; it will regenerate. |

### Safe update order
1. 1. Edit PRODUCER ffi-grok.zig in one commit: add `tx_count: u32` to CMerkleProof after `index` (:1616-1623); replace both synthesis expressions (:1672, :1906) with `.tx_count = proof.tx_count`; add `if (proof.tx_count == 0) return invalid_input` guard in both verify fns; add the new FFI wrong-depth rejection test; bump quantum_version to 1.1.0 (:589).
2. 2. Edit CONSUMER walletcore/src/quantum_crypto.rs in the SAME commit (source edits land together so no built pair is ever mismatched): add `tx_count: u32` to #[repr(C)] CMerkleProof (:692-699) and Default (:701-709); add `pub tx_count: u32` to high-level MerkleProof (:1083-1088); set `c_proof.tx_count = self.tx_count` in to_c_proof (:1092-1106); add tx_count to the three test literals (:3626, :3641, :3685); optionally add `const _: () = assert!(size_of::<CMerkleProof>() == 1036)` or a runtime test tying it to quantum_spv_proof_size().
3. 3. Rebuild libquantum_crypto.a for every target: `cd programs/simd_crypto_ffi && zig build` (host -> zig-out/lib), `zig build android` (-> zig-out/lib/android-arm64), and the iOS ios-libs build (-> ios-libs/ios-arm64 + ios-libs/ios-sim-arm64).
4. 4. Repack the macOS host archive: /Users/director/work/poly-repo/zig-forge/scripts/repack-for-xcode.sh /Users/director/work/poly-repo/zig-forge/programs/simd_crypto_ffi/zig-out/lib/libquantum_crypto.a (Zig 0.16 emits 2-byte-aligned Mach-O members; Apple ld-prime needs 8-byte).
5. 5. Rebuild libwalletcore.a against the new .a and run `cargo test` in walletcore (host) — the new wrong-depth path is now exercised; repeat cargo build for ios/android targets used downstream.
6. 6. Rebuild quantum_vault (`cargo build` in src-tauri + the fuzz crate) — picks up the fresh .a; no source change needed.
7. 7. Refresh CosmicDuckOS: copy/rebuild the updated libquantum_crypto.a and libwalletcore.a into the pbxproj-referenced paths (:760/:886, :759/:885), repack the macOS .a via repack-for-xcode.sh, and rebuild in Xcode. No Swift edits.
8. 8. Update quantum_vault/AUDIT_SURFACE_INVENTORY.md H-2 to 'landed', and commit/push each repo (chronos `git push "msg"`).

### Risk notes
Struct grows 1032 -> 1036 bytes (single u32 appended, align stays 4, no padding). Blast radius is narrow: walletcore/src/quantum_crypto.rs is the ONLY place that mirrors CMerkleProof or calls the two verify fns, so the memory-corruption risk (Rust passing a 1032-byte struct to a fn now reading 1036) is confined to the producer<->walletcore pair and is avoided by editing both in one commit before rebuilding. quantum_vault and CosmicDuckOS neither declare the struct nor call the verify fns (exported symbol names are unchanged), so stale linkage would still resolve — but rebuild them anyway so any future SPV use gets the fix. Silent-drift hazard: walletcore has NO compile-time assertion binding size_of::<CMerkleProof>() to quantum_spv_proof_size(); the only size test (assert!(proof_size>1000), quantum_crypto.rs:3544-3551) stays green at 1036, so a forgotten Rust-side edit would NOT fail CI — add an explicit size/offset assert as part of the change. Semantic risk: callers must now supply the REAL block tx_count; the high-level Rust MerkleProof gains a required field (source-breaking for any struct-literal constructor — only 3 in-tree tests today). Internal spv.zig already enforces index<tx_count and hashes.len==requiredMerkleDepth(tx_count), so a wrong tx_count now correctly rejects instead of silently passing. Build/packaging: needs `zig build` + `zig build android` + iOS ios-libs build; macOS static libs (libquantum_crypto.a and downstream libwalletcore.a) MUST be run through zig-forge/scripts/repack-for-xcode.sh or Xcode/cargo linking fails with 'not 8-byte aligned'. Watch the chronos build-artifact trap: do not let zig-out/*.a get staged by tick commits.

---

## 2.2 — `simd_crypto_ffi`

### Current ABI
```
The stateful tx-builder is a hidden threadlocal singleton declared in the FFI layer, NOT in tx_builder.zig (the roadmap's "removes the hidden global (tx_builder.zig)" is imprecise — tx_builder.zig's `TxBuilder` struct already takes `*Self` on every method and needs no change; the global lives in ffi-grok.zig).

PRODUCER — /Users/director/work/poly-repo/zig-forge/programs/simd_crypto_ffi/src/ffi-grok.zig
- Hidden global (the thing being removed):
  :2273  const TxBuilderHandle = *tx_builder.TxBuilder;   // unused alias
  :2277  threadlocal var tx_builder_storage: tx_builder.TxBuilder = tx_builder.TxBuilder.init();
  :2278  threadlocal var tx_builder_initialized: bool = false;
- 14 exported C-ABI functions that read/write that global (all take NO handle today):
  :2286  export fn quantum_tx_builder_init() c_int
  :2298  export fn quantum_tx_builder_add_input(utxo: *const CSpendableUtxo) c_int
  :2335  export fn quantum_tx_builder_add_p2wpkh_output(value: u64, pubkey_hash: [*c]const u8) c_int
  :2369  export fn quantum_tx_builder_add_p2pkh_output(value: u64, pubkey_hash: [*c]const u8) c_int
  :2406  export fn quantum_tx_builder_add_p2tr_output(value: u64, x_only_pubkey: [*c]const u8) c_int
  :2440  export fn quantum_tx_builder_add_op_return(data: [*c]const u8, data_len: usize) c_int
  :2469  export fn quantum_tx_builder_total_input() u64
  :2477  export fn quantum_tx_builder_total_output() u64
  :2485  export fn quantum_tx_builder_fee() u64
  :2493  export fn quantum_tx_builder_estimate_vsize() usize
  :2499  export fn quantum_tx_builder_input_count() usize
  :2505  export fn quantum_tx_builder_output_count() usize
  :2526  export fn quantum_tx_sign(private_keys: [*c]const [32]u8, key_count: usize, out_tx: [*c]u8, out_tx_size: usize, actual_size: *usize) c_int
  :2584  export fn quantum_tx_compute_sighash(input_index: usize, private_key: [*c]const u8, sighash_out: [*c]u8) c_int
- STATELESS exports that do NOT touch the builder and MUST remain byte-identical (do not add a handle):
  :2629 quantum_ecdsa_sign, :2680 quantum_derive_pubkey, :2704 quantum_tx_dust_limit, :2709 quantum_tx_sighash_all, :2714 quantum_tx_utxo_size
- Related extern struct (UNCHANGED by this item — it is item 2.1/CMerkleProof that moves a struct; CSpendableUtxo stays):
  :2242 CSpendableUtxo extern struct { txid:[32]u8, vout:u32, value:u64, pubkey_hash:[20]u8, derivation_index:u32 }
- Allocator available for heap handles: ffi-grok already uses std.heap.page_allocator (ffi-grok.zig:1102,1266). TxBuilder is a large fixed-capacity struct (256 inputs + 256 outputs + 256×64 script bytes, ~50KB) — heap, not stack.
- No C header exists in this program; every consumer hand-declares the ABI in a Rust extern block.
```

### Proposed ABI
```
Opaque-handle model. All state moves into a caller-owned heap object; the threadlocal global and the `_init`/`initialized` pair are deleted.

New/changed exports in ffi-grok.zig (recommended: additive new symbols so a safe intermediate exists — see update_order):
  // lifecycle (replaces quantum_tx_builder_init)
  export fn quantum_tx_builder_new() ?*anyopaque   // page_allocator.create(TxBuilder), *=init(); returns null on OOM
  export fn quantum_tx_builder_free(handle: ?*anyopaque) void   // page_allocator.destroy; null-safe

  // every stateful call gains `handle` as the FIRST parameter:
  export fn quantum_tx_builder_add_input(handle: ?*anyopaque, utxo: *const CSpendableUtxo) c_int
  export fn quantum_tx_builder_add_p2wpkh_output(handle: ?*anyopaque, value: u64, pubkey_hash: [*c]const u8) c_int
  export fn quantum_tx_builder_add_p2pkh_output(handle: ?*anyopaque, value: u64, pubkey_hash: [*c]const u8) c_int
  export fn quantum_tx_builder_add_p2tr_output(handle: ?*anyopaque, value: u64, x_only_pubkey: [*c]const u8) c_int
  export fn quantum_tx_builder_add_op_return(handle: ?*anyopaque, data: [*c]const u8, data_len: usize) c_int
  export fn quantum_tx_builder_total_input(handle: ?*anyopaque) u64
  export fn quantum_tx_builder_total_output(handle: ?*anyopaque) u64
  export fn quantum_tx_builder_fee(handle: ?*anyopaque) u64
  export fn quantum_tx_builder_estimate_vsize(handle: ?*anyopaque) usize
  export fn quantum_tx_builder_input_count(handle: ?*anyopaque) usize
  export fn quantum_tx_builder_output_count(handle: ?*anyopaque) usize
  export fn quantum_tx_sign(handle: ?*anyopaque, private_keys: [*c]const [32]u8, key_count: usize, out_tx: [*c]u8, out_tx_size: usize, actual_size: *usize) c_int
  export fn quantum_tx_compute_sighash(handle: ?*anyopaque, input_index: usize, private_key: [*c]const u8, sighash_out: [*c]u8) c_int

Body: each fn does `const b: *tx_builder.TxBuilder = @ptrCast(@alignCast(handle orelse return null_pointer)); ...` then calls the SAME `b.addInput(...)` / `tx_builder.signTransaction(b, ...)` / `tx_builder.computeSighashBip143(b, ...)` it calls today (those already take a *TxBuilder), dropping every `tx_builder_initialized` guard. Delete lines 2273, 2277-2278.
STATELESS exports (quantum_ecdsa_sign, quantum_derive_pubkey, quantum_tx_dust_limit, quantum_tx_sighash_all, quantum_tx_utxo_size) are untouched.

Rust mirror after cutover (walletcore & fuzz): externs gain a leading `handle: *mut c_void`; the walletcore `TxBuilder` struct stores the raw handle, `new()` = `quantum_tx_builder_new()`, `Drop` = `quantum_tx_builder_free(self.handle)`; the process-wide `TX_BUILDER_LOCK` mutex + RAII guard machinery (quantum_crypto.rs:2322-2372) becomes unnecessary and can be deleted (or kept, harmless).
```

### Symbols whose ABI changes
- `quantum_tx_builder_new (NEW)`
- `quantum_tx_builder_free (NEW)`
- `quantum_tx_builder_init (REMOVED — replaced by _new/_free)`
- `quantum_tx_builder_add_input (arity +1: handle)`
- `quantum_tx_builder_add_p2wpkh_output (arity +1)`
- `quantum_tx_builder_add_p2pkh_output (arity +1)`
- `quantum_tx_builder_add_p2tr_output (arity +1)`
- `quantum_tx_builder_add_op_return (arity +1)`
- `quantum_tx_builder_total_input (arity +1)`
- `quantum_tx_builder_total_output (arity +1)`
- `quantum_tx_builder_fee (arity +1)`
- `quantum_tx_builder_estimate_vsize (arity +1)`
- `quantum_tx_builder_input_count (arity +1)`
- `quantum_tx_builder_output_count (arity +1)`
- `quantum_tx_sign (arity +1: handle first)`
- `quantum_tx_compute_sighash (arity +1: handle first)`

### Consumers (lockstep)
| Path | What it mirrors / calls |
|---|---|
| `/Users/director/work/poly-repo/walletcore/src/quantum_crypto.rs` | PRIMARY ABI MIRROR. extern "C" block hand-declares all 14 builder/sign fns at lines 229-262 (init:229, add_input:230, add_p2wpkh:231, add_p2pkh:232, add_p2tr:233, add_op_return:234, total_input:235, total_output:236, fee:237, estimate_vsize:238, input_count:239, output_count:240, tx_sign:241-247, compute_sighash:248-252). Safe Rust wrapper `TxBuilder` (struct :2324-2329) with process-wide `TX_BUILDER_LOCK` mutex + RAII guard (:2322-2372), new()/try_acquire() call quantum_tx_builder_init (:2350,:2369), add_input builds CSpendableUtxo & calls _add_input (:2384), sign() at :2472, compute_sighash() at :2494. CSpendableUtxo #[repr(C)] mirror at :444-455 (UNCHANGED by this item). Links static=quantum_crypto in build.rs:24,36 (host + android-arm64). All 14 externs + the wrapper must move to handle model; the mutex becomes redundant once state is per-handle. |
| `/Users/director/work/poly-repo/quantum-encoding-ecosystem/quantum_vault/src-tauri/fuzz/src/lib.rs` | SECOND ABI MIRROR (fuzz crate). extern "C" block declares the builder/sign fns at :232-256 (init:232, add_input:233, add_p2wpkh:234, add_p2pkh:235, add_p2tr:236, add_op_return:237, tx_sign:238-244, compute_sighash:245-249, ecdsa_sign:250-255, derive_pubkey:256). CSpendableUtxo #[repr(C)] mirror at :263-271. Comment at :229-231 documents the non-reentrant threadlocal contract — update when the handle model lands. |
| `/Users/director/work/poly-repo/quantum-encoding-ecosystem/quantum_vault/src-tauri/fuzz/fuzz_targets/fuzz_tx_signing.rs` | DRIVER using the fuzz externs: quantum_tx_builder_init() :57, quantum_derive_pubkey :75, CSpendableUtxo build :87, quantum_tx_builder_add_input :95, add_p2wpkh/p2pkh/p2tr/op_return :106-115, quantum_tx_sign :137. Every call site needs the handle threaded through (create at :57, free at end of iteration). |
| `/Users/director/work/poly-repo/quantum-encoding-ecosystem/quantum_vault/src-tauri/fuzz/build.rs` | LINK ONLY. Locates libquantum_crypto.a (forge_base host-absolute) and emits rustc-link-lib=static=quantum_crypto (:around 30-33). No code change; rebuild after lib rebuild. |
| `/Users/director/work/poly-repo/quantum-encoding-ecosystem/quantum_vault/src-tauri/build.rs` | LINK ONLY. build.rs:65-69 sets link-search to simd_crypto_ffi/zig-out/lib and rustc-link-lib=static=quantum_crypto. No tx_builder code here; the app reaches the builder THROUGH walletcore (Cargo.toml:132 `walletcore = { path = ... }`). Rebuild after lib+walletcore. |
| `/Users/director/work/poly-repo/quantum-encoding-ecosystem/quantum_vault/src-tauri/quantum-crypto-sys` | NOT a tx-builder consumer (roadmap 2.1 names it imprecisely). This subcrate is the ML-DSA/ML-KEM post-quantum sys crate (src/{mldsa,mlkem,hybrid,layout,secure,bindings}.rs); it links static=quantum_crypto in build.rs:49,53 but grep for quantum_tx_*/CSpendableUtxo returns ZERO hits. Only needs a relink, no ABI edit. |
| `/Users/director/work/poly-repo/CosmicDuckOS` | INDIRECT (relink/repack only). Swift app links libwalletcore.a + libquantum_crypto.a and calls the higher-level walletcore_* API (roundtrip.swift uses walletcore_version/walletcore_eth_address_from_mnemonic, not quantum_tx_*). grep for quantum_tx_builder/CSpendableUtxo across the repo = ZERO hits. Bridging header CosmicDuckOS-Bridging-Header.h references the bound libquantum_crypto.a (:21). No source change; rebuild/repack the static libs after walletcore updates. |
| `/Users/director/work/quantum-zig-forge/monorepo-lens.json` | Scanner artifact only (zig_lens output listing the symbols). Not a consumer; ignore. |

### Safe update order
1. APPROACH: additive-then-cutover (strongly preferred over a hard same-name arity swap, because these are SEPARATE repos linked by host-absolute path — there is no workspace to rebuild atomically, so a hard swap has no safe intermediate; the audit report's upgrade #7 also recommends shims for one release).
2. 1. PRODUCER (additive): in ffi-grok.zig add quantum_tx_builder_new()/quantum_tx_builder_free() plus handle-first variants of all 14 fns. Keep the existing threadlocal symbols (init + no-handle variants) working as-is for now so current consumers still link. Delete nothing yet. `cd zig-forge/programs/simd_crypto_ffi && zig build` and `zig build android`. On macOS repack: `zig-forge/scripts/repack-for-xcode.sh zig-out/lib/libquantum_crypto.a`. The lib now exports BOTH ABIs; every existing consumer still builds unchanged.
3. 2. WALLETCORE: rewrite the extern block (quantum_crypto.rs:229-262) to the handle-taking signatures, store the raw handle in the `TxBuilder` struct, wire new()=quantum_tx_builder_new / Drop=quantum_tx_builder_free, drop (or leave) TX_BUILDER_LOCK. Its PUBLIC Rust API (`TxBuilder`, `sign`, `compute_sighash`) keeps the same signatures, so downstream (quantum_vault app, CosmicDuckOS) source is untouched. `cargo build` + `cargo test` walletcore against the rebuilt lib.
4. 3. QUANTUM_VAULT FUZZ: update fuzz/src/lib.rs externs (:232-256) and fuzz_targets/fuzz_tx_signing.rs (:57 create handle, thread it through :95-137, free per iteration) to the handle model. Rebuild the fuzz crate.
5. 4. APP + SWIFT RELINK: rebuild quantum_vault/src-tauri (picks up new walletcore + lib) and CosmicDuckOS (relink libwalletcore.a + libquantum_crypto.a). Rebuild iOS/Android archives via programs/build-ios-libs.sh and programs/build-android-libs.sh; repack macOS .a again if the build produced a fresh one. Verify a real send/sign flow end-to-end.
6. 5. REMOVE SHIMS: once every consumer is on the handle API and verified, delete the threadlocal globals (ffi-grok.zig:2273,2277-2278), quantum_tx_builder_init, and the no-handle export variants. `zig build` + `zig build android` + repack. Final rebuild/relink of walletcore, quantum_vault, fuzz, CosmicDuckOS. Bump quantum_version().
7. ALTERNATIVE (hard swap, only if you accept a broken intermediate): edit producer + walletcore externs + fuzz externs + fuzz driver in one change, rebuild lib+repack first, then rebuild all Rust consumers together, then relink Swift. No intermediate is linkable — do it on a branch across all repos and land together.

### Risk notes
BLAST RADIUS is contained: only TWO repos hand-mirror this ABI (walletcore/src/quantum_crypto.rs and quantum_vault fuzz). CosmicDuckOS and the quantum_vault app reach the builder only through walletcore's stable Rust wrapper, so keeping that wrapper's public signatures identical means their SOURCE never changes — they only relink. quantum-crypto-sys links the lib but touches none of these symbols.

SAFETY NUANCE for still_needed: the correctness danger the audit flagged (finding 5: tokio thread migration on the threadlocal singleton) is ALREADY MITIGATED in walletcore by a process-wide std::sync::Mutex + RAII guard (quantum_crypto.rs:2322-2372) that serializes the whole new→add→sign sequence and is `!Send` across .await by design. So this change is NOT an urgent security fix in the shipping consumer — it is an API-cleanliness / true-concurrency improvement that also lets the mutex be deleted. still_needed=true because the threadlocal global still exists in source and the roadmap lists 2.2 as an open Tier 2 item, but it can be sequenced calmly.

tx_builder.zig NEEDS NO CHANGE: its `TxBuilder` methods already take `*Self` and signTransaction/computeSighashBip143 already take a `*TxBuilder` argument — the whole change is in the ffi-grok.zig FFI shim. The roadmap's phrasing "removes the hidden global (tx_builder.zig)" points at the wrong file; the global is ffi-grok.zig:2277-2278.

REBUILD/REPACK GOTCHAS: (a) macOS static libs MUST be repacked via zig-forge/scripts/repack-for-xcode.sh after every `zig build` (Zig 0.16 emits 2-byte-aligned Mach-O members; Apple ld-prime needs 8-byte). (b) Android needs `zig build android` producing zig-out/lib/android-arm64/libquantum_crypto.a (PIC already set in build.zig:63). (c) iOS/Android app archives rebuilt via programs/build-ios-libs.sh / build-android-libs.sh. (d) Handle must be page_allocator-heap (TxBuilder ~50KB fixed-capacity: 256 inputs + 256 outputs + 256×64 script bytes) — do not stack-allocate. (e) Null-handle defense: every handle-taking fn must reject a null/NPE handle with TxResult.null_pointer, replacing today's `!tx_builder_initialized` guards. (f) This item is independent of 2.1 (CMerkleProof/tx_count) but shares the same rebuild+repack pipeline and the same lockstep consumer set — landing 2.1 and 2.2 in one coordinated release halves the number of repack/relink cycles.

---

## 2.3 — `financial_engine`

### Current ABI
```
TARGET = signal_broadcast TradingSignal wire struct (96-byte packed), the only float-carrying extern/wire struct in the whole financial_engine FFI surface.

PRODUCER (Zig) src/signal_broadcast.zig:62-89, ALREADY post-Batch-31 (commit 71028c2d, 2026-05-28): signal_id:u64(:64), timestamp_ns:i64(:65), sequence:u64(:66), flags:u32(:67), _pad:u32(:68), symbol:[16]u8(:71), action:SignalAction=u8(:74), asset_class:u8(:75), time_horizon:u8(:76), confidence:u8(:77), current_price:i64(:78), target_price:i64(:79), stop_loss:i64(:80) [nano-USD, 1e9 scale — ALREADY i64; were f64 pre-Batch-31], suggested_size_pct:f32(:83), max_leverage:f32(:84), risk_score:f32(:85), expires_in_ms:u32(:86). comptime sizeof==96 at :126-130; implicit 4-byte pad after confidence (header names it _pad2[4]) 8-aligns the i64 trio.

C HEADER include/signal_broadcast.h:63-92 — ALREADY in sync with Zig: int64_t current/target/stop (:80-82), float risk params (:85-87), _Static_assert(sizeof==96) (:92).

RUST MIRROR (consumer) quantum_vault/src-tauri/src/trading/sentient_network/ffi.rs:53-84 — OUT OF SYNC, live shipped ABI bug: FfiTradingSignal declares current_price:f64(:72), target_price:f64(:73), stop_loss:f64(:74) while producer+header are i64. size assert :84 PASSES because f64 and i64 are both 8 bytes, so it does NOT catch the mismatch; only the bit interpretation is wrong (Zig writes int 95000e9; Rust reads those 8 bytes as an IEEE-754 f64 denormal ~4.7e-310 -> all money garbage across the boundary). Masked by the Rust-only roundtrip test ffi.rs:561-582. All exported fns pass the struct by pointer — NO function signature changes for this item.
```

### Proposed ABI
```
RECOMMENDED (fix the live bug; do NOT go to i128): make the Rust mirror match the already-shipped i64 producer.

ffi.rs FfiTradingSignal:72-74 change f64 -> i64: current_price:i64, target_price:i64, stop_loss:i64 (struct stays 96 bytes; size assert :84 unchanged).
ffi.rs to_ffi():475-477 scale high-level f64 USD -> i64 nano-USD: (self.current_price*1e9) as i64, (target.unwrap_or(0.0)*1e9) as i64, (stop.unwrap_or(0.0)*1e9) as i64.
ffi.rs from_ffi():504-506 read_unaligned::<i64> and :534-536 divide by 1e9 back to f64 USD, keep the >0 Option gating on target/stop.
Producer Zig + signal_broadcast.h need NO change (already i64).

NOT RECOMMENDED alt (the literal roadmap 'f64->i128'): make current/target/stop __int128 (16 bytes each) -> that region grows 24->48 bytes, struct 96->120 bytes, breaks the cache-line design and _Static_assert(==96), forces a full 4-way lockstep rebuild. i64 nano-USD already covers +/-9.22e9 USD per unit; i128 range is unneeded for a per-unit wire price. Only pick i128 if the wire must byte-match the internal Decimal (i128 @ 9dp) — nothing requires that.
```

### Symbols whose ABI changes
- `FfiTradingSignal (Rust mirror) — current_price/target_price/stop_loss f64 -> i64`
- `TradingSignal (Zig extern struct / C header) — NO change needed, already i64`
- `No exported function signatures change (struct passed by pointer; size stays 96)`

### Consumers (lockstep)
| Path | What it mirrors / calls |
|---|---|
| `/Users/director/work/poly-repo/quantum-encoding-ecosystem/quantum_vault/src-tauri/src/trading/sentient_network/ffi.rs` | PRIMARY binary-ABI mirror: FfiTradingSignal :55-81 (f64 fields :72-74 = the bug); to_ffi :462-496 (writes prices :475-477); from_ffi :500-544 (read_unaligned f64 :504-506, gate :534-536); extern block :102-133; size assert :84; roundtrip test :561-582 |
| `/Users/director/work/poly-repo/quantum-encoding-ecosystem/quantum_vault/src-tauri/src/trading/sentient_network/types.rs` | High-level TradingSignal (serde, NOT binary ABI): current_price:f64 :127, target_price:Option<f64> :130, stop_loss:Option<f64> :133. Recommend it STAYS f64 (UI/JSON facing); scaling confined to ffi.rs |
| `/Users/director/work/poly-repo/quantum-encoding-ecosystem/quantum_vault/src-tauri/src/trading/sentient_network/filter.rs` | Reads high-level f64 prices: current_price arithmetic :220-225, target gating :213-227. Unaffected if types.rs stays f64; recheck if types.rs also converted |
| `/Users/director/work/poly-repo/quantum-encoding-ecosystem/quantum_vault/src-tauri/src/trading/sentient_network/publisher.rs` | Publisher wrapper + stats (signals_per_second:f64 :34); no price fields; unaffected |
| `/Users/director/work/poly-repo/quantum-encoding-ecosystem/quantum_vault/src-tauri/src/trading/sentient_network/subscriber.rs` | Subscriber wrapper + stats (avg_latency_ms:f64 :51); no price fields; unaffected |
| `/Users/director/work/poly-repo/quantum-encoding-ecosystem/quantum_vault/src-tauri/src/commands/sentient.rs` | Builds high-level TradingSignal via ::new/.with_target/.with_stop_loss with f64 USD (:516-538); unaffected if types.rs stays f64 |
| `/Users/director/work/poly-repo/quantum-encoding-ecosystem/quantum_vault/src/lib/types/index.ts` | TS TradingSignal type at the JSON/serde (Tauri command) boundary, NOT binary ABI; only changes if types.rs JSON shape changes — recommended plan keeps f64, so no TS change |
| `/Users/director/work/poly-repo/quantum-encoding-ecosystem/quantum_vault/src/lib/components/SentientNetwork.svelte` | UI consuming the TS JSON; not a binary consumer; no change under recommended plan |
| `/Users/director/work/poly-repo/quantum-encoding-ecosystem/quantum_vault/src-tauri/build.rs` | Links libsignal_broadcast.a static: :197-227 (link-lib=static=signal_broadcast :200, rerun-if-changed :227); financial_core/engine/coinbase_fix :92-113. Lib must be rebuilt+in place for the link |
| `/Users/director/work/poly-repo/zig-forge/programs/build-android-libs.sh` | Android ARM64 packaging of signal_broadcast (gated on zig-ffi cargo feature ~:187). Zig struct unchanged under recommended plan, so no re-pack required unless the Zig side is touched |

### Safe update order
1. 0. Producer change already shipped: Zig src/signal_broadcast.zig and include/signal_broadcast.h are already i64 — NO producer edit for the recommended fix. f64 and i64 are both 8 bytes so struct size never changes; the tree is ALREADY in the broken state, so the consumer fix strictly repairs it (no incompatible intermediate).
2. 1. Edit ffi.rs:72-74 f64 -> i64 (FfiTradingSignal current/target/stop).
3. 2. Edit ffi.rs to_ffi():475-477 to multiply f64 USD by 1e9 and cast i64; from_ffi():504-506 read_unaligned::<i64> and :534-536 divide by 1e9 back to f64 (keep >0 Option gating).
4. 3. Update roundtrip test ffi.rs:561-582 to assert the i64 wire value (e.g. current_price==95000_000_000_000) so it can no longer pass with a type mismatch — the external-anchor guard the current test lacks.
5. 4. Leave types.rs/filter.rs/commands/sentient.rs/index.ts/Svelte on f64 (UI facing); scaling stays inside ffi.rs. If instead types.rs is also converted to integer nano-USD, do it in the SAME commit and recheck filter.rs:213-227 and the TS type.
6. 5. cargo build -p quantum_vault (desktop) + cargo test the sentient_network module; libsignal_broadcast.a unchanged so no Zig rebuild needed.
7. 6. NOT-RECOMMENDED i128 variant only: (a) Zig struct + assert to i128/new size, (b) header __int128 + _Static_assert new size, (c) Rust mirror to i128, (d) zig build signal_broadcast lib, (e) macOS: run /Users/director/work/poly-repo/zig-forge/scripts/repack-for-xcode.sh on rebuilt libsignal_broadcast.a (Zig 0.16 emits 2-byte-aligned Mach-O members; ld-prime needs 8-byte), (f) rebuild Android libs via build-android-libs.sh, (g) rebuild Rust consumer — all land together.

### Risk notes
Narrow blast radius: ONE binary ABI struct (TradingSignal) across ONE FFI boundary (libsignal_broadcast.a -> quantum_vault ffi.rs). KEY CORRECTION to the roadmap: item 2.3 as written ('f64 -> i128 in the signal_broadcast extern struct') is MOOT on the producer side — Zig struct and C header are already i64 (Batch 31). What is still_needed is the CONSUMER sync: Rust ffi.rs:72-74 still f64 = a live, shipped silent-money-corruption bug (Zig i64 bits reinterpreted as f64), masked because the size assert only checks bytes (8==8) and the only test is a Rust-internal f64 roundtrip that never crosses into Zig. Recommended fix is i64 (matches shipped producer, keeps 96-byte cache line, consumer-only, no Zig/header/repack/Android churn). i128 is NOT recommended: breaks the 96-byte design and _Static_assert, needs full 4-way lockstep + macOS repack-for-xcode.sh + Android re-pack, and buys range i64 nano-USD does not need. Also: the roadmap phrase 'risk/tenant wire structs' is imprecise — praetorian_guard.zig / multi_tenant_engine.zig / runaway_protection.zig carry f64 INTERNALLY only; none is an extern/FFI struct (verified: the only extern structs are FC_*, HFT_*, C*, coinbase CExecutionResult/Order, TradingSignal — all already i128/i64 fixed-point except f32 confidence/risk fractions, which are non-money). So there is NO additional FFI-breaking wire struct beyond TradingSignal; purging f64 from those three files is a separate non-ABI refactor. The f32 risk fractions (suggested_size_pct/max_leverage/risk_score) are consistent Zig<->Rust and are NOT money — leave them.

---

## 2.4 — `zig_lens`

### Current ABI
```
Three pieces are out of sync in current source (all verified present today):

1. C HEADER — /Users/director/work/poly-repo/zig-forge/programs/zig_lens/include/zig_lens.h:62-66
   Language codes stop at JAVASCRIPT=4; NO ZIG_LENS_LANG_GO:
     #define ZIG_LENS_LANG_ZIG         0
     #define ZIG_LENS_LANG_RUST        1
     #define ZIG_LENS_LANG_C           2
     #define ZIG_LENS_LANG_PYTHON      3
     #define ZIG_LENS_LANG_JAVASCRIPT  4

2. ZIG FFI — /Users/director/work/poly-repo/zig-forge/programs/zig_lens/src/ffi.zig
   LangCode enum (lines 59-66) ALREADY has `go = 5`; toLangCode (79-89) ALREADY maps `5 => .go`; zig_lens_analyze_source (562) ALREADY handles `.go`; buildProjectReport switch (233) ALREADY includes `.go`. The ONLY Zig gap is isSingleFile (156-167), which lists .zig/.rs/.c/.h/.py/.js/.ts/.tsx/.jsx/.svelte but OMITS .go — so a single .go path is misrouted to scanner.scanDirectory. (main.zig:184-189 has the same list and DOES include .go at :189 — ffi.zig has drifted.)

3. RUST BINDING — /Users/director/work/poly-repo/zig-forge/programs/zig_lens/bindings/rust/src/lib.rs
   Re-export consts stop at LANG_JAVASCRIPT (lib.rs:38-42); enum Language (68-74) has Zig/Rust/C/Python/JavaScript only, no Go; as_c_int (77-85) has no Go arm. bindgen output (bindings.rs) is generated to OUT_DIR at build time from the header (build.rs:22-34, allowlist_var "ZIG_LENS_.*") — NOT checked in, so no committed bindings file to edit; it regenerates from the header.
```

### Proposed ABI
```
1. HEADER — insert after zig_lens.h:66:
     #define ZIG_LENS_LANG_GO          5

2. ffi.zig isSingleFile — add one clause inside the return (after the .svelte line at :166):
     or std.mem.endsWith(u8, path, ".go")
   (No enum/signature change; go=5 already exists in LangCode.)

3. Rust lib.rs — three edits:
   a. After lib.rs:42 add:  pub const LANG_GO: c_int = ZIG_LENS_LANG_GO as c_int;
   b. Add `Go,` to enum Language (after JavaScript, lib.rs:73).
   c. Add match arm to as_c_int (after JavaScript, lib.rs:83):  Language::Go => LANG_GO,

Change is purely ADDITIVE — appends discriminant 5, reorders/renumbers nothing. No struct field-order or function-signature change; every existing symbol keeps its value. bindgen auto-emits the new ZIG_LENS_LANG_GO const once the header defines it.
```

### Symbols whose ABI changes
- `ZIG_LENS_LANG_GO (new C macro = 5)`
- `LangCode.go (already present in ffi.zig, no change)`
- `zig_lens_sys::LANG_GO (new Rust const)`
- `zig_lens_sys::Language::Go (new enum variant)`

### Consumers (lockstep)
| Path | What it mirrors / calls |
|---|---|
| `/Users/director/work/poly-repo/zig-forge/programs/zig_lens/bindings/rust/src/lib.rs` | THE ONLY ABI CONSUMER. zig-lens-sys crate. Mirrors header language codes as consts (lib.rs:38-42) + enum Language (68-74) + as_c_int (77-85). bindgen regenerates raw ZIG_LENS_* from header at build (build.rs:22-34). Must add LANG_GO const + Go variant + as_c_int arm in lockstep. |
| `/Users/director/work/poly-repo/zig-forge/programs/zig_lens/bindings/rust/build.rs` | Links static=zig_lens from ../../zig-out/lib (build.rs:10-15), reruns on header change (:18-19), bindgen allowlist_var ZIG_LENS_.* (:26) auto-picks-up the new GO define. No edit needed; just rebuild. |
| `/Users/director/work/tauri_apps/quantum-ace-v2/src-tauri/src/commands/tools.rs` | NOT an ABI consumer. run_zig_lens (tools.rs:20) spawns the zig-lens BINARY via tokio Command (:27), passing --format/--compile/--compact strings — never a language code, never links libzig_lens.a. Unaffected by this change. |
| `/Users/director/work/rust_programs/rust-security/src/language_analyzers/zig_analyzer.rs` | NOT a consumer. Line 39 is a comment ('from zig_lens unsafe_ops.zig') — reimplemented catalog, no link/FFI. |
| `/Users/director/work/rust_programs/rust-security/src/tree_sitter_security.rs` | NOT a consumer. Line 1366 comment reference only. |
| `/Users/director/work/quantum-zig-forge/monorepo-lens.json` | NOT a consumer — it is generated OUTPUT from a zig-lens scan. |
| `/Users/director/work/poly-repo/zig-forge/build.zig` | Umbrella build. Only buildProgram/testProgram("zig_lens") (:74,:160) — builds & tests, no ABI surface. |

### Safe update order
1. 1. (independent, do first) Edit ffi.zig isSingleFile (:166) to add `or std.mem.endsWith(u8, path, ".go")`. Pure Zig, no ABI impact; fixes the single-.go-file misrouting bug and re-syncs with main.zig:189.
2. 2. Edit include/zig_lens.h — insert `#define ZIG_LENS_LANG_GO 5` after line 66. Header MUST change before the Rust build so bindgen emits the ZIG_LENS_LANG_GO const the new Rust code references.
3. 3. Rebuild the static lib: `cd programs/zig_lens && zig build lib` (and `zig build android` if the Android arm64 archive is redistributed). Producer must be rebuilt before any consumer links it.
4. 4. macOS repack: run `/Users/director/work/poly-repo/zig-forge/scripts/repack-for-xcode.sh programs/zig_lens/zig-out/lib/libzig_lens.a` so the Rust cargo link doesn't hit the Zig-0.16 2-byte-alignment 'not 8-byte aligned' ld error (per CLAUDE.md).
5. 5. Edit bindings/rust/src/lib.rs: add `pub const LANG_GO` (after :42), `Go` variant in enum Language (after :73), `Language::Go => LANG_GO` in as_c_int (after :83).
6. 6. `cd programs/zig_lens/bindings/rust && cargo build` — bindgen regenerates bindings.rs into OUT_DIR from the updated header (picks up ZIG_LENS_LANG_GO), then compiles the new enum arm. Verify no unresolved-const error.
7. 7. Optional: `zig build test-ffi` still green; add an isSingleFile("x.go") test assertion in ffi.zig (:728 test block) to lock the fix.
8. Ordering note: header (step 2) must precede the Rust build (step 6); steps 1 and 5 are edit-only and can be staged anytime before their respective builds. Because the change only appends discriminant 5, no intermediate state leaves an existing caller linking a shifted ABI.

### Risk notes
Low blast radius. Sole ABI consumer is the in-tree sibling crate bindings/rust (zig-lens-sys); no foreign Rust/Swift/Go/C/TS project links libzig_lens.a or vendors zig_lens.h (verified tree-wide). The tauri quantum-ace-v2 app uses the CLI binary via subprocess, not the FFI, so it is entirely unaffected. Change is additive (new enum value 5, nothing renumbered), so it is 'FFI-breaking' only in the lockstep-regenerate sense — old compiled callers keep working; a stale Rust binding simply lacks the Go variant. No checked-in bindgen output exists (generated to OUT_DIR), so there is no third file to keep in sync. Rebuild steps: `zig build lib` (+`android` if shipped) then repack-for-xcode.sh on macOS before `cargo build`. The pre-existing FFI security-scan gap and thread-safety of the global ruleset (roadmap items 1/6) are NOT touched by this change and remain separate work.

---

## 2.5 — `zdedupe`

### Current ABI
```
Producer: /Users/director/work/poly-repo/zig-forge/programs/zdedupe/src/lib.zig exports 21 C symbols total. 14 are declared in the shipped header include/zdedupe.h: zdedupe_init(:86), zdedupe_free(:91), zdedupe_add_path(:100), zdedupe_set_mode(:112), zdedupe_set_min_size(:118), zdedupe_set_max_size(:124), zdedupe_set_include_hidden(:130), zdedupe_set_follow_symlinks(:136), zdedupe_set_threads(:142), zdedupe_use_sha256(:148), zdedupe_run_sync(:156), zdedupe_delete_file(:229), zdedupe_move_file(:234), zdedupe_version(:239).
The 7 UNDECLARED exports (target of item 2.5), all in lib.zig:
  1. export fn zdedupe_list_dir(path: [*:0]const u8) ?*ZDedupeResult  — lib.zig:263
  2. export fn zdedupe_get_metadata(path: [*:0]const u8, include_hash: bool) ?*ZDedupeResult  — lib.zig:340
  3. export fn zdedupe_result_json(result: ?*ZDedupeResult) ?[*:0]const u8  — lib.zig:403
  4. export fn zdedupe_free_result(result: ?*ZDedupeResult) void  — lib.zig:412
  5. export fn zdedupe_batch_delete(paths: [*]const [*:0]const u8, count: usize) c_int  — lib.zig:425
  6. export fn zdedupe_batch_move(paths: [*]const [*:0]const u8, count: usize, dest_dir: [*:0]const u8) c_int  — lib.zig:439 (basename-clobber data-loss bug 439-465)
  7. export fn zdedupe_batch_delete_detailed(paths: [*]const [*:0]const u8, count: usize) ?*ZDedupeResult  — lib.zig:469
Support code that exists ONLY for the 7: pub const ZDedupeResult = opaque{} (lib.zig:248); const ResultContext (lib.zig:250-258); fn listDirJson (285-336); fn getMetadataJson (362-400); fn batchDeleteJson (493-518); extern \"c\" var errno: c_int (491, Darwin-wrong); const Stat = switch(...) (528-567) and extern \"c\" fn lstat (569) — used only by listDirJson:314 + getMetadataJson:367; fn writeJsonStr (578-580) — called only at 331,369,384,510 (all inside the 3 removed helpers). NOTE: unlink extern (226) and rename extern (227) are ALSO used by kept symbols zdedupe_delete_file:230 / zdedupe_move_file:235 — KEEP them.
Header include/zdedupe.h (2026-01-28) declares only the 14; ends at zdedupe_version (:197). Byte-identical vendored copies at 3 source locations + 3 xcframework Headers copies (verified by diff).
Verified in shipped archive (nm -g src-tauri/zdedupe/lib/libzdedupe.a): all 7 present as exported T symbols (_zdedupe_list_dir, _zdedupe_get_metadata, _zdedupe_result_json, _zdedupe_free_result, _zdedupe_batch_delete, _zdedupe_batch_move, _zdedupe_batch_delete_detailed) — compiled in but unreferenced.
```

### Proposed ABI
```
RECOMMENDED = REMOVE (zero consumers verified; batch_move carries a live data-loss bug and errno is Darwin-broken — do not document/ship them).
After change, producer exports exactly the 14 header symbols. Concrete edits to lib.zig:
  - Delete the 7 export fns: zdedupe_list_dir (263-283), zdedupe_get_metadata (340-360), zdedupe_result_json (403-409), zdedupe_free_result (412-417), zdedupe_batch_delete (425-433), zdedupe_batch_move (439-465), zdedupe_batch_delete_detailed (469-488), plus their doc-comment blocks and the two section banners at 243-245 / 419-421.
  - Delete now-dead support: ZDedupeResult opaque (247-248), ResultContext (250-258), listDirJson (260-336 incl. doc comment), getMetadataJson (338-400), batchDeleteJson (493-518), extern \"c\" var errno (490-491), const Stat block (527-567), extern \"c\" fn lstat (569), fn writeJsonStr (571-580).
  - KEEP: extern unlink (226) + extern rename (227) (used by kept delete_file/move_file); the `const libc = std.c;` and `const builtin` decls only if still referenced after removal (builtin becomes unused → delete; libc unused → delete).
Header include/zdedupe.h: NO CHANGE (the 14 it declares are exactly what remains). build.zig: NO CHANGE (test_modules list does not reference these symbols).
ALTERNATIVE = DOCUMENT (not recommended): would instead ADD 7 prototypes + a typedef `zdedupe_result` opaque to include/zdedupe.h and mirror byte-identically to all 6 vendored header copies — but this locks in the batch_move clobber + Darwin errno bugs and expands ABI surface for no consumer. Reject unless a consumer is planned.
```

### Symbols whose ABI changes
- `zdedupe_list_dir`
- `zdedupe_get_metadata`
- `zdedupe_result_json`
- `zdedupe_free_result`
- `zdedupe_batch_delete`
- `zdedupe_batch_move`
- `zdedupe_batch_delete_detailed`

### Consumers (lockstep)
| Path | What it mirrors / calls |
|---|---|
| `/Users/director/work/tauri_apps/zdedupe/src-tauri/src/ffi.rs` | Rust extern "C" block ffi.rs:6-22 declares exactly the 14 header symbols; NONE of the 7. Links via #[link(name="zdedupe", kind="static")]. Zero references to any removed symbol — no edit needed. |
| `/Users/director/work/tauri_apps/zdedupe/src-tauri/build.rs` | build.rs:3-4 cargo:rustc-link-search=native=zdedupe/lib + rustc-link-lib=static=zdedupe; rerun-if-changed on zdedupe/lib/libzdedupe.a (:14) and include/zdedupe.h (:15). Links the whole archive but references no removed symbol — safe. |
| `/Users/director/work/tauri_apps/zdedupe/zdedupe-app/zdedupe/Services/ZDedupeEngine.swift` | Swift consumer via `import CZdedupe`; calls only version/init/free/set_mode/set_min_size/set_max_size/set_include_hidden/set_follow_symlinks/set_threads/use_sha256/add_path/run_sync (12 of the 14). NONE of the 7. JSONDecoder decodes run_sync output into DuplicateResult/CompareResult — wire-shape unaffected by this change. |
| `/Users/director/work/tauri_apps/zdedupe/src-tauri/zdedupe/include/zdedupe.h` | Vendored header, byte-identical to canonical (verified diff). Already lacks the 7 — no edit needed if removing. |
| `/Users/director/work/tauri_apps/zdedupe/Packages/CZdedupe/Sources/CZdedupe/include/zdedupe.h` | Swift module-map vendored header, byte-identical to canonical (verified diff). Already lacks the 7. |
| `/Users/director/work/tauri_apps/zdedupe/Packages/CZdedupe/libzdedupe.xcframework/{macos-arm64_x86_64,ios-arm64_x86_64-simulator,ios-arm64}/Headers/zdedupe.h` | 3 xcframework Headers copies; found by `find`, same canonical header. Already lacks the 7 — refreshed when xcframework is rebuilt. |
| `/Users/director/work/tauri_apps/zdedupe/src-tauri/zdedupe/lib/libzdedupe.a + Packages/CZdedupe/libzdedupe.xcframework/*/libzdedupe.a` | Prebuilt archives that DO contain the 7 as exported T symbols (nm confirmed) but nothing references them. Must be re-copied/rebuilt from the new producer build so the shipped binary matches source. |

### Safe update order
1. No consumer references any of the 7 symbols (verified: rg across /Users/director/work/tauri_apps/zdedupe returned zero hits for all 7; scoped rg across zig-forge finds them only in src/lib.zig). Removing an UNREFERENCED exported symbol never breaks a link, so there is no broken intermediate state and producer-first is safe.
2. STEP 1 (producer): Edit /Users/director/work/poly-repo/zig-forge/programs/zdedupe/src/lib.zig — delete the 7 export fns + dead support code per proposed_abi (ZDedupeResult, ResultContext, listDirJson, getMetadataJson, batchDeleteJson, errno extern, Stat block, lstat extern, writeJsonStr, and now-unused libc/builtin decls). Keep unlink+rename externs.
3. STEP 2: Rebuild the static lib: `cd /Users/director/work/poly-repo/zig-forge/programs/zdedupe && zig build` (produces zig-out/lib/libzdedupe.a). Optionally `zig build test` to confirm the 3 lib.zig tests still pass. Header needs no change (`zig build header` still emits the same 14-symbol header).
4. STEP 3 (macOS alignment repack — REQUIRED before any Xcode/cargo link): run /Users/director/work/poly-repo/zig-forge/scripts/repack-for-xcode.sh on the freshly built libzdedupe.a (Zig 0.16 emits 2-byte-aligned Mach-O members; Apple ld-prime needs 8-byte, else cargo/xcodebuild fail with 'not 8-byte aligned').
5. STEP 4 (Rust/Tauri consumer): copy the repacked libzdedupe.a into /Users/director/work/tauri_apps/zdedupe/src-tauri/zdedupe/lib/libzdedupe.a (header already matches). `cargo build` in src-tauri — links cleanly (no removed symbol referenced).
6. STEP 5 (Swift consumer): rebuild the xcframework via /Users/director/work/tauri_apps/zdedupe/scripts/build-zig-xcframework.sh — it regenerates the 3 arch .a slices + Headers under Packages/CZdedupe/libzdedupe.xcframework (and handles per-arch repack). Then build the Swift app (xcodebuild) — compiles fine, no removed symbol used.
7. STEP 6 (commit lockstep): commit the producer edit in zig-forge and the refreshed vendored binaries in tauri_apps/zdedupe together (two repos). Because the header was already free of the 7, no header edits are needed in either repo; the only diffs are lib.zig + the rebuilt .a artifacts.
8. OPTIONAL cleanup that travels with 2.5 (per roadmap): if instead DOCUMENTING rather than removing, first fix batch_move basename-clobber (lib.zig:439-465, use renamex_np/RENAME_EXCL on Darwin, renameat2/RENAME_NOREPLACE on Linux) and replace `extern "c" var errno` (491) with __error()-based access — otherwise removal moots both bugs.

### Risk notes
LOW blast radius. Verified zero consumers for all 7 symbols: rg across /Users/director/work/tauri_apps/zdedupe (the only consumer tree) returned no hits; scoped rg across zig-forge finds them only in programs/zdedupe/src/lib.zig. Rust ffi.rs and Swift ZDedupeEngine.swift both declare/call only a subset of the 14 header symbols. All 6 vendored headers are byte-identical to canonical and already omit the 7, so removal requires NO header edits and cannot desync consumers. Removing unreferenced exported symbols cannot cause a link failure, so ordering is forgiving (producer-first is safe; no broken intermediate). The ONE real gotcha is macOS static-lib alignment: any rebuilt .a must go through scripts/repack-for-xcode.sh before cargo/xcodebuild link, else 'not 8-byte aligned' errors. Two-repo change (zig-forge producer + tauri_apps/zdedupe vendored .a) must be committed together. Do NOT touch the 14 header symbols or the run_sync JSON wire-shape (Swift JSONDecoder + Tauri frontend depend on field names). Note: the earlier JSON-injection concern in these helpers is already independently fixed (writeJsonStr at lib.zig:578 now delegates to std.json.Stringify.encodeJsonString), so removal loses no security fix. still_needed=true: the 7 exports still exist in current lib.zig, still absent from the header, still zero-consumer; batch_move clobber (439-465) and Darwin errno (491) bugs are still live and are cleanly mooted by removal.

---

## Dropped items

### 2.6 — `zig_ratelimit` — NO LONGER NEEDED

MOOT / still_needed=false. Wave 1 (Tier 1A #18) already shipped the roadmap's own preferred non-breaking alternative: TokenBucket.init clamps invalid config fail-closed (sanitizeRate/sanitizeCapacity, token_bucket.zig:46-56,85-93) and the AtomicTokenBucket CAS race is fixed (GCRA single-word, token_bucket.zig:216-289). Every safety defect Tier 2 2.6 aimed to prevent — `1e9/0`→`@intFromFloat(inf)` trap, negative-capacity underflow, div-by-zero — is already eliminated WITHOUT changing the return type. The roadmap text itself (UPGRADE-ROADMAP.md:191-193) says 'prefer that [clamp] unless strict validation is required,' and a clamp only ever TIGHTENS a rate limit (admits less, never more) — the safe direction for a security component. The sole remaining rationale for 2.6 is a policy preference to REJECT bad config loudly rather than silently clamp; that is a design call, not a correctness fix. Blast radius if pursued anyway is minimal and fully contained: ONE consumer (zig_token_service), ONE call site needing `try` (lib.zig:72, inside an already-`!Self` fn), zero C/Swift/Rust/Go/TS/WASM FFI consumers, source path-dependency so no ABI/link/repack risk. Note the audit report's 'no README' and 'minimum_zig_version 0.14.0' remarks are now stale (README.md exists; zon says 0.16.0).

Reason it is moot: Only relevant IF a future maintainer chooses strict-reject over the shipped clamp (a policy preference, NOT a safety need — see risk_notes). The strict form would make constructors fallible:
- token_bucket.zig:85  `pub fn init(capacity: f64, rate: f64) error{InvalidRate,InvalidCapacity}!Self` — return error.InvalidRate when `!(rate>0) or !isFinite(rate)`, error.InvalidCapacity when `isNan(capacity) or capacity<0` (delete the sanitizeRate/sanitizeCapacity clamps, or keep MAX_CAPACITY clamp only).
- token_bucket.zig:96  `pub fn initWithTokens(...) error{InvalidRate,InvalidCapacity}!Self`
- token
