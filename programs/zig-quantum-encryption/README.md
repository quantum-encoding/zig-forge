# Quantum Vault Post-Quantum Cryptography Library

> **NIST FIPS 203 ML-KEM-768 + FIPS 204 ML-DSA-65 in Zig**

A pure Zig implementation of the Module-Lattice-Based Key-Encapsulation Mechanism (ML-KEM-768, FIPS 203) and the Module-Lattice-Based Digital Signature Algorithm (ML-DSA-65, FIPS 204) for Quantum Vault's post-quantum cryptographic protection, plus a hybrid ML-KEM-768 + X25519 KEM. Both NIST primitives are validated byte-for-byte against NIST ACVP known-answer vectors (`src/ml_kem_tier1_anchors.zig`, `src/ml_dsa_tier1_anchors.zig`); see [Known Answer Tests](#known-answer-tests-kat) for exactly which ACVP modes those vectors cover.

Every claim in this file was checked against the code; the audit trail is in [`docs/CLAIMS-AUDIT.md`](docs/CLAIMS-AUDIT.md). The hybrid wire format and its two combiner versions are specified byte-for-byte in [`docs/HYBRID-V2.md`](docs/HYBRID-V2.md).

## Overview

This library implements NIST's FIPS 203 standard (August 2024) - the first standardized post-quantum key encapsulation mechanism. It provides cryptographic protection against both classical and quantum computer attacks.

### Why Post-Quantum for Quantum Vault?

1. **Future-Proof Security**: Protects seed phrases and backups against "harvest now, decrypt later" attacks
2. **NIST Standardized**: Based on the Module Learning With Errors (MLWE) problem
3. **Hybrid Ready**: Designed to combine with classical X25519 for defense-in-depth
4. **Marketing Differentiator**: "Quantum Vault" becomes a genuine technical claim, not just branding

## Security Levels

| Parameter Set | Security Category | Equivalent Classical | In this library |
|--------------|-------------------|---------------------|----------|
| ML-KEM-512 | 1 | AES-128 | parameters only (`src/ml_kem.zig`), no API |
| **ML-KEM-768** | 3 | AES-192 | **the one exposed** (`src/ml_kem_api.zig`, C ABI) |
| ML-KEM-1024 | 5 | AES-256 | parameters only, no API |

Quantum Vault uses **ML-KEM-768**, Category 3, paired with ML-DSA-65 (also Category 3). There is no runtime parameter-set switch; the other two rows exist so the constants are in one place if that ever changes.

## Architecture

How the Quantum Vault application composes this library. The two KEM boxes and
the ML-DSA-65 box are what ships here; AES-256-GCM and Ed25519 come from the
application's own crypto layer, not from this repository.

```
┌─────────────────────────────────────────────────────────────────┐
│                    QUANTUM VAULT ENCRYPTION                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Seed Encryption (at rest):                                     │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐          │
│  │  ML-KEM-768 │ +  │  X25519     │ =  │  Hybrid KEM │          │
│  │  (Quantum)  │    │  (Classical)│    │             │          │
│  └─────────────┘    └─────────────┘    └─────────────┘          │
│         │                  │                  │                 │
│         └──────────────────┼──────────────────┘                 │
│                            ▼                                    │
│                   ┌─────────────────┐                           │
│                   │  AES-256-GCM    │                           │
│                   │  (Symmetric)    │                           │
│                   └─────────────────┘                           │
│                                                                 │
│  QNFT Backup Signing (future):                                  │
│  ┌─────────────┐    ┌─────────────┐                             │
│  │  ML-DSA-65  │ +  │  Ed25519    │  = Hybrid Signature         │
│  │  (Dilithium)│    │  (Classical)│                             │
│  └─────────────┘    └─────────────┘                             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## API Reference

The ML-KEM-768 primitives below live in `src/ml_kem_api.zig` (`pqc` here is that
source module). `build.zig` does not expose a Zig package module — non-Zig
consumers link the static/shared `quantum_crypto` library and call the C ABI in
`include/quantum_vault.h` (`qv_mlkem768_*`, `qv_mldsa65_*`, `qv_hybrid_*`).

### Key Generation

```zig
const pqc = @import("ml_kem_api.zig");

// Generate a fresh key pair
const keypair = try pqc.keyGen768();

// keypair.ek: EncapsulationKey768 (1184 bytes, public)
// keypair.dk: DecapsulationKey768 (2400 bytes, private)
```

### Encapsulation (Sender)

```zig
// Using recipient's public encapsulation key
const result = try pqc.encaps768(&recipient_ek);

// result.K: SharedSecret (32 bytes) - use for symmetric encryption
// result.c: Ciphertext768 (1088 bytes) - send to recipient
```

### Decapsulation (Recipient)

```zig
// Using your private decapsulation key
const K = pqc.decaps768(&my_dk, &ciphertext);

// K: SharedSecret (32 bytes) - matches sender's K
```

## Building

### Prerequisites

- Zig 0.16.0 (the source uses 0.16 idioms: `std.process.Init`, `std.debug.FullPanic`, `std.Io`)
- No external dependencies (pure Zig implementation)

### Build Commands

```bash
# Build library
zig build

# Run tests
zig build test

# Run benchmarks
zig build bench
```

### Cross-Compilation for Quantum Vault Targets

```bash
# Every shipped slice in one go (macOS arm64/x86_64, Linux x86_64,
# Windows x86_64, iOS arm64, Android arm64/arm32) -> zig-out/lib/libquantum_crypto_<target>.a
zig build cross

# A single target by hand
zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseSafe   # Android ARM64
zig build -Dtarget=aarch64-ios -Doptimize=ReleaseFast             # iOS ARM64 (aarch64-macos is macOS, not iOS)

# Native desktop
zig build -Doptimize=ReleaseSafe

# WASM (Cloudflare Workers / browser) -> zig-out/bin/quantum_vault.wasm
zig build wasm
```

On macOS, repack any `.a` you hand to Xcode with `scripts/repack-for-xcode.sh`
(repo root): Zig 0.16 emits 2-byte-aligned archive members and ld-prime wants 8.

## Integration with Quantum Vault

### Phase 1: Seed Encryption (Current)

The master seed is protected with the hybrid KEM in `src/hybrid.zig` (C ABI:
`qv_hybrid_*`). Keys and ciphertexts are plain concatenations — 1216-byte
`ek = ek_M ‖ pk_X`, 2432-byte `dk = dk_M ‖ sk_X`, 1120-byte `ct = ct_M ‖ ct_X` —
and the 32-byte shared secret comes out of one of two combiners:

| Version | Shared secret | Use |
|---|---|---|
| **v2** (default for new data) | `HKDF-SHA3-256(salt = "", IKM = ss_M ‖ ss_X ‖ ct_X ‖ pk_X, info = "HYBRID-ML-KEM-768-X25519-v2", L = 32)` — RFC 5869 over HMAC-SHA3-256; the four inputs in X-Wing's order (draft-connolly-cfrg-xwing-kem-10 §5.3), so both X25519 public keys are bound into the secret | `encapsV2` / `decapsV2`, `qv_hybrid_encaps_v2` / `qv_hybrid_decaps_v2` |
| v1 (legacy) | `SHA3-256("HYBRID-ML-KEM-768-X25519-v1" ‖ ss_M ‖ ss_X)` — binds only the two shared secrets | `encaps` / `decaps`, `qv_hybrid_encaps` / `qv_hybrid_decaps`; kept so data already written with it still opens |

The ciphertext does not carry a version byte — the two versions share one
layout and the caller picks the version explicitly. The reasoning, the exact
byte-level definitions and checked-in test vectors (combiner-only and full
path) are in [`docs/HYBRID-V2.md`](docs/HYBRID-V2.md).

```zig
const hybrid = @import("hybrid.zig");

const kp = try hybrid.keyGen();               // kp.ek: [1216]u8, kp.dk: [2432]u8
const enc = try hybrid.encapsV2(&kp.ek);      // enc.K: [32]u8, enc.ct: [1120]u8
const K = hybrid.decapsV2(&kp.dk, &enc.ct);   // == enc.K
```

### QNFT Backup Signing (ML-DSA-65)

ML-DSA-65 (FIPS 204) is implemented in `src/ml_dsa.zig` and exported over the C ABI as
`qv_mldsa65_*`. There are two signing interfaces, and **which one you call decides whether
anyone else can verify the result**:

| | Message representative | Interoperable | Zig | C ABI |
|---|---|---|---|---|
| **v2 — standard `ML-DSA.Sign`** | `μ = H(tr ‖ 0x00 ‖ len(ctx) ‖ ctx ‖ M)` | **yes** — OpenSSL, BoringSSL, liboqs, Zig `std.crypto` | `signWithContext` / `verifyWithContext` | `qv_mldsa65_sign_v2` / `qv_mldsa65_verify_v2` |
| v1 — `ML-DSA.Sign_internal` | `μ = H(tr ‖ M)` | no — verifies only with its own v1 counterpart | `sign` / `verify` | `qv_mldsa65_sign` / `qv_mldsa65_verify` |

Use v2 for everything new. `ctx` is a domain-separation string of at most 255 bytes and may be
empty. v1 is kept byte-for-byte because data already signed with it must keep verifying, and
because it is what the ACVP internal-interface vectors exercise. Key, signature and secret-key
layouts are identical; a signature does not record its framing, so the verifier must call the
matching function. HashML-DSA (pre-hash) is not implemented.

Both interfaces offer hedged (`randomized = true`, recommended) and deterministic signing.
`keyGen` and deterministic v1 `sign` are byte-exact against the NIST ACVP KATs; v2 is byte-exact
against Zig's independent `std.crypto.sign.mldsa` on every tested seed, message and context
(`src/differential_std.zig`), and each verifier accepts the other's signatures. Hybrid
ML-DSA + Ed25519 signing is not yet implemented.

### Phase 3: Guardian Multi-Sig (Future)

Post-quantum threshold signatures for guardian recovery.

## Performance

`zig build bench` runs `bench.zig` on the machine in front of you; that output
is the only performance figure this repository stands behind. As an order of
magnitude, ML-KEM-768 keyGen / encaps / decaps each take a fraction of a
millisecond on current 64-bit phones and laptops; no measured Cortex-A78 numbers
are checked in.

Memory usage:
- Heap: none — no allocator is taken anywhere in `src/` (stack-only implementation)
- Stack: fixed-size arrays sized by the FIPS parameters; a few KB per operation

## Security Considerations

### Constant-Time Implementation

What is done:
- **No division on secret data, on any target.** Every reduction in ML-KEM goes through
  `ml_kem.modQ`, and every one in ML-DSA through `ml_dsa.modReduce`, `decompose`, `power2Round`
  and `centerReduce`: multiplies, arithmetic shifts and masks only. A `/`, `%` or `@mod` by a
  constant is only constant-time if the compiler lowers it to a multiply, and LLVM does not do
  that on wasm32 in any mode, nor at `-Oz` elsewhere — the precondition for the KyberSlash
  attacks. Each replacement is proven equal to its mathematical definition by exhaustive test.
- **`zig build ct-check` enforces it.** It compiles every secret-handling entry point for nine
  target/mode pairs, reads the emitted assembly, and fails on any divide instruction or
  software-divide call in cryptographic code. (The only divides it permits are `std.crypto`'s
  Keccak sponge dividing a public byte count by its rate.) Run against the code before this
  change it reports 15 such divides in the shipped wasm32 build and 108 in wasm32 ReleaseFast.
- ML-KEM decapsulation compares the re-encrypted ciphertext with `constantTimeCompare` and picks
  the real or implicit-rejection secret with `constantTimeSelect`, so a tampered ciphertext is
  not distinguishable by timing at that step
- ML-DSA's norm check and signature packing centre coefficients and take absolute values with
  masks: no branch on the sign of a secret coefficient
- ML-DSA signing scrubs unpacked secret polynomials, the masking seed and the per-signature
  randomness on every exit path; ML-KEM and the hybrid KEM scrub their intermediate secrets the
  same way (`std.crypto.secureZero`)

What is not claimed:
- ML-DSA signing contains the rejection-sampling loops FIPS 204 mandates; their iteration count
  depends on secret data by design, as in every ML-DSA implementation
- `ct-check` looks for divides. It does not detect secret-dependent branches or memory access in
  general, and no ctgrind / dudect / valgrind taint run has been made, so a blanket "constant
  time" statement is still not one this repository can back
- **Debug builds are not constant-time and must not be shipped**; `zig build` without
  `-Doptimize=` is Debug. `zig build cross` and `zig build wasm` pick release modes themselves

### Input Validation

- `encaps768` and `encapsInternal768` run the FIPS 203 §7.2 modulus check and reject a
  non-canonical encapsulation key.
- `validateDecapsulationKey768` / `decaps768Checked` run the FIPS 203 §7.3 check: the stored
  `H(ek)` must match the embedded key, and that key must itself be canonical. A corrupt
  decapsulation key otherwise yields a well-formed but wrong secret for every ciphertext with no
  error, because implicit rejection looks like success by design. The C ABI checks on every
  call (`QV_MLKEM_INVALID_DK`, `QV_HYBRID_INVALID_SK`); Zig callers that validated a key once at
  import may keep using `decaps768`, as FIPS 203 permits.

### Decapsulation Failure Rate

| Parameter Set | Failure Probability |
|--------------|-------------------|
| ML-KEM-512 | 2^-138.8 |
| ML-KEM-768 | 2^-164.8 |
| ML-KEM-1024 | 2^-174.8 |

### Implicit Rejection

If decapsulation detects tampering, it returns a pseudorandom value derived from the secret `z` rather than failing. This prevents oracle attacks.

## Testing

### Unit Tests

```bash
zig build test
```

Covers:
- Barrett reduction correctness
- NTT round-trip (f = NTT^-1(NTT(f)))
- Compress/decompress approximation
- Key generation validity
- Encapsulation/decapsulation round-trip

On a host whose glibc startup objects carry `.sframe` relocations (current Arch Linux), Zig
0.16's linker cannot link the native test executables; use `zig build test
-Dtarget=x86_64-linux-musl`. The library itself is unaffected.

### Differential Tests

`src/differential_std.zig` drives this library and Zig's independent `std.crypto` ML-KEM-768 and
ML-DSA-65 with the same seeds and demands byte-for-byte agreement: keys, ciphertexts, shared
secrets, cross-decapsulation, implicit-rejection secrets, deterministic v2 signatures across
contexts, cross-verification both ways, and identical accept/reject verdicts on 2000 mutated
signatures. It also pins the fact that v1 signatures are *not* accepted by a standard verifier.
`std` is a test-only dependency.

### Constant-Time Guard

```bash
zig build ct-check      # needs python3; ~1 minute
```

See [Constant-Time Implementation](#constant-time-implementation).

### Known Answer Tests (KAT)

NIST provides official test vectors at:
https://csrc.nist.gov/projects/cryptographic-algorithm-validation-program

NIST ACVP KATs (from the `usnistgov/ACVP-Server` gen-val JSON) are integrated
and run under `zig build test`:
- `src/ml_kem_tier1_anchors.zig` — FIPS 203 ML-KEM-768 keyGen (`d, z → ek, dk`),
  encaps (`ek, m → c, K`) and decaps (`dk, c → K`), byte-exact, plus a decaps
  implicit-rejection negative vector.
- `src/ml_dsa_tier1_anchors.zig` — FIPS 204 ML-DSA-65 keyGen (`ξ → pk, sk`,
  `ML-DSA-keyGen-FIPS204` tcId 26) and sigGen from
  `ML-DSA-sigGen-FIPS204/internalProjection.json` **tgId 10 = deterministic,
  internal interface, externalMu = false** (tcId 136), byte-exact, plus the
  matching verify and three verify-reject vectors (tampered sig / message / key).
- `src/nist_vectors.zig` — a second independent ACVP decaps vector and FIPS 203
  size assertions.

What "internal interface" means for ML-DSA, stated precisely: this library
implements `ML-DSA.Sign_internal` / `ML-DSA.Verify_internal` (FIPS 204
Algorithms 7 and 8) directly on the caller's message, i.e. `μ = H(tr ‖ M)`.
It does **not** implement the external `ML-DSA.Sign(sk, M, ctx)` framing
(`μ = H(tr ‖ 0x00 ‖ len(ctx) ‖ ctx ‖ M`, Algorithms 2 and 3), HashML-DSA, or
any ACVP `externalMu = true` mode, and no KAT here covers those. A verifier
that expects the external interface with an empty context will **not** accept
these signatures (the framing bytes differ). Randomized signing (`rnd` from
the system RNG) is round-trip tested only, since it cannot be byte-checked.

The hybrid KEM has its own checked-in vectors — combiner-only ones verified
against an independent Python implementation, and a full-path fixed-seed
vector — in [`docs/HYBRID-V2.md`](docs/HYBRID-V2.md); `zig build
hybrid-vectors` regenerates them.

## References

1. **FIPS 203**: Module-Lattice-Based Key-Encapsulation Mechanism Standard
   https://doi.org/10.6028/NIST.FIPS.203

2. **CRYSTALS-Kyber**: Original submission to NIST PQC competition
   https://pq-crystals.org/kyber/

3. **SP 800-227**: Recommendations for Key-Encapsulation Mechanisms
   https://csrc.nist.gov/publications/detail/sp/800-227/final

## License

MIT License - See LICENSE file

## Acknowledgments

- NIST Post-Quantum Cryptography Standardization Project
- CRYSTALS-Kyber design team
- Trezor Safe 7 for pioneering consumer PQC adoption

---

**Quantum Vault** - *Protecting your keys for the quantum era*

*Part of the Quantum Encoding ecosystem*
