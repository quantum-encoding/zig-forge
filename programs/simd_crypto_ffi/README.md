# simd_crypto_ffi — Bitcoin wallet crypto core (`libquantum_crypto.a`)

C-ABI Bitcoin wallet core (hashing, BIP32/39 HD derivation, BIP143 SegWit signing, transaction parse/txid, SPV proof verification, and coin selection) built as the static library `libquantum_crypto.a`.

> Naming note: despite the directory name, there is **no SIMD/AVX-512 code here**. Every primitive delegates to the audited Zig standard-library implementations (`std.crypto.hash.sha2`, `Blake3`, `ChaCha20IETF`, `ecdsa.Ecdsa(Secp256k1, Sha256)`). The earlier "AVX-512 accelerated primitives" README and the `hash/`, `cipher/`, `Sha256`/`Blake3`/`ChaCha20` module stubs it documented were non-functional (they returned all-zero digests and wrote no ciphertext) and have been removed.

## What it is

The Bitcoin crypto core for the `quantum_vault` / `walletcore` / CosmicDuckOS stack. It exports ~70 `quantum_*` C symbols. Consumers hand-declare the ABI (no `include/*.h` is shipped yet).

Groups:

- **Hashing** — `quantum_sha256/sha256d/sha512/blake3[_variable]/ripemd160`, `quantum_hmac_sha256/512`, `quantum_pbkdf2_sha256/512`
- **Symmetric** — `quantum_chacha20_encrypt/decrypt` (ChaCha20-IETF, caller-managed nonce)
- **Secure memory** — `quantum_secure_zero`, `quantum_secure_compare` (constant-time)
- **Mining/batch** — `quantum_sha256d_batch`, `quantum_merkle_root[_from_txs]`
- **Tx parsing** — `quantum_bitcoin_parse_tx`, `quantum_bitcoin_detect_script_type`, `quantum_bitcoin_txid` (BIP141 witness-stripped, correct for legacy and SegWit)
- **SPV** — `quantum_spv_verify_merkle_proof/parse_header/block_hash/verify_linkage/verify_pow/verify_payment/difficulty` (merkle proofs are depth-pinned via caller-supplied `tx_count` — CVE-2012-2459)
- **BIP32** — `quantum_bip32_from_seed/derive_child/derive_path/neuter/serialize/p2wpkh_address/hash160`
- **Tx building/signing** — threadlocal-singleton builder and a handle-based `quantum_tx_builder_*_ctx` API, `quantum_tx_sign`, `quantum_tx_compute_sighash`, `quantum_ecdsa_sign` (low-S DER per BIP62), `quantum_derive_pubkey`
- **Coin selection** — `quantum_coin_select[_largest_first|_smallest_first]` (Branch-and-Bound with greedy fallback), fee helpers

The C ABI is defined in `src/ffi-grok.zig` (the build root). In-tree Zig projects can consume the audited Bitcoin building blocks directly as a module:

```zig
const bitcoin = @import("simd_crypto").bitcoin; // transaction, tx_builder, coin_select, bip32, spv
```

## Test posture

Tests are externally anchored (NIST FIPS 180-4, RFC 4231, official BLAKE3 vectors, BIP32/39/84 published vectors, the BIP143 Native-P2WPKH worked example verified through a consensus oracle, SPV/compact-target vectors, and Blockstream-anchored mainnet txids). A comptime guard refuses to build with side-channel mitigations disabled.

## Build

```bash
zig build          # host static lib -> zig-out/lib/libquantum_crypto.a
zig build android  # aarch64-linux-android (PIC, for the Tauri cdylib) -> zig-out/lib/android-arm64/
zig build test     # FFI + Zig-module unit tests
```

> macOS consumers: after rebuilding, repack the `.a` for Xcode via `zig-forge/scripts/repack-for-xcode.sh` (Zig 0.16 emits 2-byte-aligned Mach-O members; Apple's ld-prime needs 8-byte).
