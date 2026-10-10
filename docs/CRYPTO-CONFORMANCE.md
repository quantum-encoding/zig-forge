# Crypto conformance: the Zig crypto the wallets link

Every primitive in the Zig archives that walletcore, CryptoWalletKit, Cifra, Tessera and the
Quantum Vault link, mapped to the official vectors it is checked against, the independent
reference it is diffed against, and the result. Same bar as walletcore's conformance goal.

Run it all with:

```sh
scripts/crypto-conformance.sh          # corpus reproduction + zig build test for all three programs
```

That script regenerates the Rust differential corpora into a temp dir and requires them to match
the committed ones byte-for-byte, then runs `zig build test` in `programs/simd_crypto_ffi`,
`programs/zig-quantum-encryption` and `zig_core_utils/zsss`. It never runs `zig build lib`, so no
consumed archive or stamp is touched. `zig build ct-check` in `programs/zig-quantum-encryption`
is the separate constant-time (KyberSlash) guard.

Status at the head of `m5/C231F69B` (2026-10-10, Apple M-series, Zig 0.16.0):
**simd_crypto_ffi 417/417, zig-quantum-encryption 301/301, zsss 91/91, ct-check OK, corpora
reproduce.**

## What is in scope

| Archive / module | Linked by | Entry points |
|---|---|---|
| `programs/simd_crypto_ffi` → `libquantum_crypto.a` (`libs.toml` row `quantum_crypto`, iOS slices in `programs/ios-libs/`) | walletcore (`src/quantum_crypto.rs`), CryptoWalletKit, Cifra, cosmic-duck-os | `quantum_*` C ABI (`src/ffi-grok.zig`) |
| `programs/zig-quantum-encryption` | Quantum Vault (`quantum-vault-sys`), zigpdf and chronos_ledger (ML-DSA) | `qv_*` C ABI (`src/quantum_vault_ffi.zig`), `ml_kem_api.zig`, `ml_dsa.zig`, `hybrid.zig` |
| `zig_core_utils/zsss` (`libs.toml` row `zsss`) | Cifra, Tessera | `zsss_*` C ABI (`src/lib.zig`) |

## Results by primitive

"Native" is the host CPU build (ARMv8 SHA-2 instructions, NEON); "scalar" is the same CPU with
`sha2`, `sha3`, `aes`, `neon`, `fp_armv8` removed, so std.crypto compiles its portable code. Both
builds of `src/conformance.zig` must reproduce the same expected bytes; the `paths` test asserts
the two really selected different implementations (native: SHA-2 hardware, 4-way NEON ChaCha20,
BLAKE3 SIMD degree 4; scalar: none, degree 1).

### libquantum_crypto.a (`programs/simd_crypto_ffi`)

All of these go through the exported C symbols, declared `extern` exactly as walletcore declares
them, in `src/conformance.zig` (`zig build test`, or `zig build conformance` for just this suite).

| Primitive | Implementation | Official vectors (source) | Differential reference (`testdata/differential/rust_reference.txt`) | SIMD vs scalar | Result |
|---|---|---|---|---|---|
| SHA-256 `quantum_sha256` | std `Sha256` (ARMv8 SHA-2 / x86 SHA-NI when present) | NIST CAVP SHAVS byte-oriented: ShortMsg 65, LongMsg 64, Monte Carlo 100×1000 ([shabytetestvectors.zip](https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents/shs/shabytetestvectors.zip)) | `sha2` 0.10.9, 101 lengths across every 64-byte boundary | agree | **PASS** |
| SHA-256d `quantum_sha256d`, `quantum_sha256d_batch` | two std `Sha256` calls; the batch API is a loop, not a multi-buffer SIMD kernel | no official SHA-256d set; built on the SHAVS-anchored SHA-256; Bitcoin txids/Merkle are anchored separately (block 500000, genesis, Blockstream) | `sha2` twice, 101 lengths; every record also run through the batch in each of the 16 slots | agree | **PASS** |
| SHA-512 `quantum_sha512` | std `Sha512` | SHAVS ShortMsg 129, LongMsg 128, Monte Carlo 100×1000 | `sha2`, 101 lengths | agree | **PASS** |
| HMAC-SHA-256 / -512 `quantum_hmac_sha{256,512}` | std `HmacSha256/512` | NIST CAVP HMAC.rsp L=32 (225) and L=64 (375), truncated tags ([hmactestvectors.zip](https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents/mac/hmactestvectors.zip)); RFC 4231 cases 1-7 | `hmac` 0.12.1, 120 each, keys 0-259 bytes | agree | **PASS** |
| PBKDF2-HMAC-SHA-256 `quantum_pbkdf2_sha256` | std `pbkdf2` | RFC 7914 section 11 (c=1, c=80000) | `pbkdf2` 0.12.2, 40 cases | agree | **PASS** |
| PBKDF2-HMAC-SHA-512 `quantum_pbkdf2_sha512` (BIP-39 seed) | std `pbkdf2` | BIP-0039 Trezor `vectors.json`, all 24 English (mnemonic → seed with "TREZOR" → BIP-32 master xprv) | `pbkdf2`, 40 cases | agree | **PASS** |
| BLAKE3 `quantum_blake3`, `quantum_blake3_variable` | std `Blake3` (SIMD degree 4 on NEON) | BLAKE3 team `test_vectors.json`, all 35 lengths, 32-byte hash and full 131-byte XOF | `blake3` 1.8.5, 107 lengths up to 1 MiB (every SIMD batch size and tree depth), XOF 1-300 bytes | agree | **PASS** |
| ChaCha20 (IETF) `quantum_chacha20_{en,de}crypt` | std `ChaCha20IETF` (4-way NEON, 2/4-way AVX2/AVX-512, else scalar) | RFC 8439 2.4.2, A.1 #1-#5 (keystreams), A.2 #1-#3 | `chacha20` 0.9.1, 81 cases, 0-16 385 bytes, random counters | agree inside the counter space; **disagreed at the 2^32 wrap** (fix 3) | **FAIL → fixed** (`fix/C231F69B-chacha20-counter`) |
| RIPEMD-160 `quantum_ripemd160` | hand-written, `src/bitcoin/bip32.zig` | designers' page: 8 strings + 1 000 000 × "a" (homes.esat.kuleuven.be/~bosselae/ripemd160.html) | `ripemd` 0.1.3, 101 lengths; regression test vs OpenSSL | n/a (no SIMD) | **FAIL → fixed** (`fix/C231F69B-ripemd160`) |
| Hash160 `quantum_bip32_hash160` | RIPEMD-160 ∘ SHA-256 | (via BIP-0032 fingerprints) | `ripemd`∘`sha2` on 200 libsecp256k1 public keys | agree | **PASS** (unaffected by the RIPEMD bug: 33-byte input) |
| secp256k1 public key `quantum_derive_pubkey` | std `Secp256k1` | BIP-0032 vectors (public keys inside every xpub) | libsecp256k1 (via `bitcoin` 0.32.102 / `secp256k1` 0.29.1), 200 keys | agree | **PASS** |
| ECDSA sign `quantum_ecdsa_sign`, `quantum_tx_sign` | RFC 6979 + std scalar arithmetic (`tx_builder.signHash`), low-S DER | BIP-143 Native P2WPKH published signature (Bitcoin Core); tiny-secp256k1 `ecdsa.json`, all 2020 valid fixtures (RFC 6979, low-S) | libsecp256k1 **and** `k256` 0.13.4 (which agree with each other), 200 cases, byte-exact DER; walletcore's own RFC 6979 oracle tests | agree | **FAIL → fixed** (`fix/C231F69B-ecdsa-rfc6979`) |
| BIP-0032 `quantum_bip32_*` | `src/bitcoin/bip32.zig` over std | BIP-0032 vectors 1-4, all 17 nodes, xprv and xpub byte-exact | `bitcoin` 0.32.102, 60 random paths depth 1-5, hardened and normal, 16/32/64-byte seeds | agree | **PASS** |
| Bech32 / Bech32m address encoding `quantum_bip32_p2wpkh_address`, `encodeBech32Address` | hand-written, `bip32.zig` | BIP-0350 valid addresses, all 8 (v0 bech32, v1-v16 bech32m) | `bitcoin` P2WPKH mainnet + testnet, 200 keys | n/a | **PASS** |
| BIP-143 sighash `quantum_tx_compute_sighash*` | `tx_builder.zig` | BIP-143 Native P2WPKH: hashPrevouts, hashSequence, hashOutputs, sigHash (pre-existing test) | — | n/a | **PASS** |
| Constant-time compare `quantum_secure_compare` | XOR-accumulate, branch-free result | — | every single-bit and single-byte difference at every position of 97 bytes | n/a | **PASS** (see constant-time notes) |

### zig-quantum-encryption

| Primitive | Implementation | Official vectors (source) | Differential reference | Result |
|---|---|---|---|---|
| ML-KEM-768 keyGen / encaps / decaps / key checks | `ml_kem_api.zig` | NIST ACVP-Server `975de31e`, every ML-KEM-768 case: keyGen 25, encapsulation 25, decapsulation VAL 10 (incl. implicit rejection), decapsulationKeyCheck 10, encapsulationKeyCheck 10 (`src/acvp_kats.zig`) | std `ml_kem` (independent FIPS 203), `src/differential_std.zig` | **PASS** |
| ML-DSA-65 keyGen / sign / verify | `ml_dsa.zig` | ACVP keyGen 25; sigGen 60 = pure external and internal × deterministic and hedged (`rnd` supplied through the new `signInternalWithRnd` / `signWithContextRnd`); sigVer 30 incl. every reject reason | std `mldsa`, 2000 mutated-signature verdicts | **PASS** |
| X25519 (hybrid classical half) | std `X25519` | RFC 7748 5.2 (2 vectors, 1 and 1000 iterations) and 6.1; Wycheproof `x25519_test.json`, all 518 | `x25519-dalek` 2.0.1, 100 cases | **PASS** |
| SHA3-256 (combiner v1, ML-KEM H/J) | std `Sha3_256` | ACVP SHA3-256 AFT, all 151 byte-aligned messages, and the standard Monte Carlo test | `sha3` 0.10.9 (via the combiner) | **PASS** |
| HMAC-SHA3-256 / HKDF-SHA3-256 (combiner v2) | std `Hkdf(Hmac(Sha3_256))` | ACVP HMAC-SHA3-256 AFT, all 150; no published HKDF-SHA3 vectors exist | `hkdf` 0.12.4 + `sha3`, 100 v2 combiner cases | **PASS** |
| Hybrid combiners v1 / v2 | `hybrid.zig` | own KATs computed with Python hashlib (docs/HYBRID-V2.md) — drift locks, not anchors | `sha3` / `hkdf`, 100 cases each | **PASS** |
| SHAKE128 / SHAKE256 | std | exercised only inside the ML-KEM / ML-DSA ACVP vectors | — | **PASS (indirect)** |

### zsss

| Primitive | Official vectors | Result |
|---|---|---|
| SLIP-0039 generate / combine | Trezor `python-shamir-mnemonic` `vectors.json`, all 45 incl. the negative ones, plus the BIP-32 master xprv of each (`src/slip39_vectors_test.zig`, pre-existing) | **PASS** |
| Plain Shamir split/combine `zsss_split` / `zsss_combine` | no standard defines this format; covered by `gnu_parity_test.zig` and round trips only | **N/A (no external anchor)** |

## Findings and fixes

Each fix is its own branch off `m5/C231F69B`, merged back with `--no-ff`; every one has a test that
was red on the old code and a recorded mutation.

1. **RIPEMD-160 wrong digests** — `fix/C231F69B-ripemd160` (`8f041f0`). `Ripemd160.buffer_len`
   was a `u6`. `final()` overflowed for every message of length 63 mod 64 and `update()` could
   never see a full 64-byte buffer. In the shipped ReleaseSmall archive `quantum_ripemd160(63 ×
   'a')` returned `41216bf9…` instead of `e6400412…`, and 32+32 incremental bytes hashed wrong.
   Hash160 of 33/65-byte public keys, which is every address this library derives, was not
   affected; walletcore's general `ripemd160()` / `hash160()` over arbitrary data was.
2. **ECDSA nonce was not RFC 6979** — `fix/C231F69B-ecdsa-rfc6979` (`130775e`). `signHash` used
   std's `signPrehashed(…, null)`, whose deterministic nonce HMACs a 32-byte zero noise block into
   the DRBG seed. The signatures were valid but matched no other wallet's, while the C ABI said
   RFC 6979. Now byte-exact with Bitcoin Core (BIP-143), libsecp256k1, k256 and tiny-secp256k1.
   walletcore had already pinned this as a known deviation
   (`tests/conformance_signatures.rs`: `zig_ecdsa_sign_is_rfc6979` and
   `zig_txbuilder_sign_is_rfc6979` are `#[ignore]`d, `zig_nonce_is_the_zig_std_variant_not_rfc6979`
   pins the old nonce). Against a scratch build of this branch the two ignored tests pass and
   the pin fails, as it should; see "After merging" below.
3. **ChaCha20 counter wrap** — `fix/C231F69B-chacha20-counter` (`f14d390`). A (counter, length)
   that runs past block 2^32 − 1 reached std's ChaCha20 unchecked. The NEON/AVX path carries
   into the first nonce word (the keystream of nonce + 1, which is a reuse), the scalar path wraps
   to block 0 (also a reuse), and safety-checked builds abort the host. The FFI now returns
   `invalid_input`; the last block of the counter space is still allowed. walletcore's
   `chacha20_encrypt`/`decrypt` wrappers pass the caller's counter through; the only in-tree
   callers are its tests, with counter 0, so no current caller changes behaviour.

Smaller changes made along the way: `ml_dsa.zig` gained `signInternalWithRnd` /
`signWithContextRnd` (the existing entry points now route through them; their outputs are
unchanged, and the deterministic ACVP cases check both); `hybrid.hexToArray` decodes at compile
time, which clears the program's one gating `zig-lens --strict` finding.

## Mutation evidence

Each anchor was broken on purpose, seen red, reverted, and seen green again (fresh `--cache-dir`
per run):

| Mutation | Went red |
|---|---|
| ML-DSA `signFramedRnd` ignores the caller's `rnd` | ACVP sigGen (hedged) |
| `validateEncapsulationKey768` always true | ACVP encapsulationKeyCheck (+2 existing) |
| RIPEMD-160 `buffer_len` back to `u6` | bip32 regression test, designers' vectors, differential |
| `signHash` back to std's nonce | BIP-143 signature, tiny-secp256k1, libsecp256k1/k256 differential |
| RFC 6979 DRBG seeded without the digest | same three |
| ChaCha20 counter guard removed | counter-limit test, native and scalar |
| PBKDF2-SHA512 iterations + 1 | BIP-0039 vectors, PBKDF2 differential (+2 existing) |
| BLAKE3 XOF capped at 64 bytes | BLAKE3 official 131-byte XOF, BLAKE3 differential |
| bech32m only for witness v2+ | BIP-0350 addresses |
| SHA-256d second round re-hashes the input | SHA-256d differential (+ existing abc KAT) |
| `sha256d_batch` second round re-hashes the input | batched differential (+2 existing) |
| hybrid v2 IKM with ct_X and pk_X swapped | combiner differential (+4 existing KATs) |

## Constant-time notes

- **secp256k1 signing and key derivation**: std's `Secp256k1.basePoint.mul` and scalar
  `mul`/`invert` are constant-time while `std.options.side_channels_mitigations` is not `.none`.
  Both `ffi-grok.zig` and `tx_builder.zig` refuse to compile otherwise. In the new `signHash` the
  only data-dependent branch is RFC 6979's rejection of a candidate k ≥ n, which happens with
  probability about 2^-128 and only for a value that is then discarded. The private scalar, k
  and the DRBG state are scrubbed with `secureZero` on every exit.
- **ML-KEM / ML-DSA**: `zig build ct-check` finds no divide instruction in any secret-handling
  function across wasm32, aarch64 (Linux, macOS), x86_64 and arm32 in ReleaseSmall, ReleaseFast
  and ReleaseSafe (the KyberSlash class). Decapsulation uses implicit rejection, and the ACVP
  VAL cases check its output byte for byte.
- **`quantum_secure_compare` / `qv_constant_time_eq`**: accumulate XOR over the full length with
  no early exit. The length is public (caller-supplied) by design. `qv_constant_time_eq` takes no
  length check either, so callers must pass equal-length buffers.
- **HMAC / PBKDF2 / ChaCha20 / BLAKE3 / SHA-2 / SHA-3 / X25519**: std implementations; no
  secret-dependent branches or table lookups in the paths used here. RIPEMD-160 is only ever
  applied to public data (public keys, scripts).
- **ChaCha20 is unauthenticated**: `quantum_chacha20_*` is the raw stream cipher. There is no
  Poly1305 or AEAD in `libquantum_crypto.a`, so integrity has to come from the caller.
- **X25519 low-order points**: std returns `IdentityElement` for the 31 Wycheproof inputs whose
  shared secret is all-zero. `hybrid.decaps` maps that to a zero `ss_X` and still binds ct_X/pk_X
  under v2; this is pinned by test.

## Gaps and N/A

| Item | Why | What would close it |
|---|---|---|
| x86_64 SIMD paths (SHA-NI, AVX2/AVX-512 ChaCha20 and BLAKE3) | The native and scalar x86_64 variants compile (`zig build conformance -Dtarget=x86_64-macos -Dcpu=haswell`), but this Apple-silicon Mac cannot execute them (no Rosetta, and nothing may be installed system-wide) | Run `zig build conformance` on an Intel Mac or x86_64 Linux host |
| ML-KEM-512/1024, ML-DSA-44/87 | not exposed (parameter constants only) | — |
| HashML-DSA (preHash) and externalMu ACVP groups | not implemented | implement, then extend `tools/extract_acvp.py` |
| SHA3-256 bit-oriented ACVP messages (1043) and LDT (8-64 GiB) | std hashes bytes; LDT is too large for a unit test | — |
| BLAKE3 keyed_hash / derive_key | not exported by `quantum_crypto` | — |
| BIP-0032 vector 5, bech32 decoding, BIP-0350 invalid addresses | no deserialiser or decoder in the C ABI (walletcore decodes in Rust) | — |
| ECDSA verification | not exported; `std` verify refuses a zero digest (noted; the test uses a textbook verifier) | — |
| HKDF-SHA3-256 published vectors | none exist; covered by ACVP HMAC-SHA3-256 + Rust `hkdf` differential | — |
| Plain `zsss_split` format | not a standard | — |
| `rng.zig` / `quantum_*` randomness | not KAT-testable; ML-DSA hedged signing now takes injected `rnd` for tests | — |
| RustCrypto `ml-kem` / `ml-dsa` as a third ML-KEM/ML-DSA reference | std's independent implementation plus full ACVP was judged enough | add to `tools/crypto-refgen` |

## Provenance and regeneration

- `programs/simd_crypto_ffi/testdata/SOURCES.md` and
  `programs/zig-quantum-encryption/testdata/acvp/SOURCES.md` list every download URL with its
  SHA-256 (fetched 2026-10-10; ACVP-Server commit `975de31eb83d87039ec88934fdc47d8c312b892d`).
- `tools/extract_vectors.py`, `tools/extract_acvp.py` and `tools/extract_classical.py` rebuild the
  vector files from those downloads. NIST `.rsp` and JSON sets are copied byte-for-byte. RFC, BIP
  and RIPEMD-160 page vectors are parsed out of the published text, never retyped.
- `tools/crypto-refgen` (Rust, test-only, exact crate pins, `Cargo.lock` committed) writes the
  differential corpora. Inputs are SplitMix64 expansions of per-record seeds, mirrored in each
  program's `src/test_records.zig`. `scripts/crypto-conformance.sh --regen` rewrites them after a
  deliberate crate bump.

## After merging (consumed artifacts)

This work changes source under `programs/simd_crypto_ffi` and `programs/zig-quantum-encryption/src`,
so the source-id stamps go stale. Nothing here rebuilt or restamped an archive (only `zig build lib`
writes them, 906659bc):

- `quantum_crypto`: the stamp reads `a1ac0944…`; the source now hashes to `4890c632…`. Run
  `scripts/build-consumed-libs.sh quantum_crypto` and `programs/build-ios-libs.sh quantum_crypto`,
  then Cifra's `check-zig-slices.sh`.
- `zigpdf` and `chronos_ledger` read `programs/zig-quantum-encryption/src` (ML-DSA): restamp them.
- walletcore, once its archive carries the RFC 6979 fix: remove `#[ignore]` from
  `zig_ecdsa_sign_is_rfc6979` and `zig_txbuilder_sign_is_rfc6979`, and delete or invert
  `zig_nonce_is_the_zig_std_variant_not_rfc6979` (`tests/conformance_signatures.rs`). The rest of
  walletcore's suite already passes against a scratch build of this branch.
