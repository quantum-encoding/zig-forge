# Quantum Vault Post-Quantum Cryptography Suite

Pure Zig implementation of NIST FIPS 203 (ML-KEM) and FIPS 204 (ML-DSA) post-quantum cryptographic algorithms for the Quantum Vault cryptocurrency wallet.

## Overview

This library provides production-ready implementations of:

| Algorithm | Standard | Type | Security Level | Use Case |
|-----------|----------|------|----------------|----------|
| **ML-KEM-768** | FIPS 203 | Key Encapsulation | Level 3 (192-bit) | Seed phrase encryption |
| **ML-DSA-65** | FIPS 204 | Digital Signature | Level 3 (192-bit) | QNFT authentication |

## Key Sizes

### ML-KEM-768 (Key Encapsulation)
| Component | Size |
|-----------|------|
| Encapsulation Key (Public) | 1,184 bytes |
| Decapsulation Key (Private) | 2,400 bytes |
| Ciphertext | 1,088 bytes |
| Shared Secret | 32 bytes |

### ML-DSA-65 (Digital Signatures)
| Component | Size |
|-----------|------|
| Public Key | 1,952 bytes |
| Private Key | 4,032 bytes |
| Signature | 3,309 bytes |

## Building

```bash
# Build all libraries
zig build

# Run all tests
zig build test

# Run benchmarks
zig build bench

# Build release optimized
zig build -Doptimize=ReleaseFast
```

## ML-DSA-65 Implementation Details

### FIPS 204 Parameters (Table 1)
```
q  = 8380417      # Prime modulus: 2^23 - 2^13 + 1
n  = 256          # Polynomial degree  
k  = 6            # Matrix rows
l  = 5            # Matrix columns
η  = 4            # Secret key coefficient bound: [-4, 4]
γ1 = 2^19         # Mask coefficient bound
γ2 = (q-1)/32     # Low-order rounding range: 261888
τ  = 49           # Challenge weight (number of ±1s)
β  = τ·η = 196    # Signature bound
ω  = 55           # Maximum hint weight
d  = 13           # Dropped bits from t
```

### Algorithms Implemented

| FIPS 204 Algorithm | Function | Description |
|--------------------|----------|-------------|
| Algorithm 1 | `keyGen()` | ML-DSA key generation |
| Algorithm 2 | `sign()` | ML-DSA signing with rejection sampling |
| Algorithm 3 | `verify()` | ML-DSA signature verification |
| Algorithm 26 | `expandA()` | Matrix generation from seed via SHAKE128 |
| Algorithm 28 | `sampleEta()` | Sample polynomial with bounded coefficients |
| Algorithm 29 | `sampleGamma1()` | Sample mask polynomial |
| Algorithm 30 | `sampleInBall()` | Generate sparse challenge polynomial |
| Algorithm 35-36 | `decompose()` | Coefficient decomposition |
| Algorithm 39-40 | `makeHint()`/`useHint()` | Hint computation and usage |
| Algorithm 41-42 | `nttForward()`/`nttInverse()` | Number Theoretic Transform |

### Rejection Sampling

The signing algorithm implements proper rejection sampling as required by FIPS 204:

1. **Check ‖z‖∞ < γ1 - β**: Prevents leakage of secret key s1
2. **Check ‖r0‖∞ < γ2 - β**: Ensures signature compactness
3. **Check ‖c·t0‖∞ < γ2**: Prevents hint overflow
4. **Check hint count ≤ ω**: Limits hint vector weight

Average signing requires ~4-7 rejection loop iterations.

## C FFI API

The library exports a C-compatible API for integration with Rust/Tauri:

```c
#include "ml_dsa_65.h"

// Key generation
MlDsaKeyPair keypair;
ml_dsa_65_keygen_random(&keypair);

// Signing
MlDsaSignature signature;
ml_dsa_65_sign_randomized(&signature, &keypair.secret_key, msg, msg_len);

// Verification
MlDsaError result = ml_dsa_65_verify(
    &keypair.public_key, 
    msg, msg_len, 
    &signature
);
if (result == ML_DSA_SUCCESS) {
    // Signature valid
}
```

## Integration with Quantum Vault

### Seed Phrase Encryption (ML-KEM-768)

```
User Password → Argon2id → Key Encryption Key
                                ↓
ML-KEM-768 KeyGen → (Encapsulation Key, Decapsulation Key)
                                ↓
ML-KEM-768 Encaps → Shared Secret + Ciphertext
                                ↓
AES-256-GCM(Shared Secret, Seed Phrase) → Encrypted Seed
```

### QNFT Authentication (ML-DSA-65)

```
Wallet Creation:
  ML-DSA-65 KeyGen → (Public Key, Private Key)
  Store: Public Key on-chain, Private Key encrypted locally

QNFT Minting:
  ML-DSA-65 Sign(Private Key, QNFT Metadata) → Signature
  On-chain: Verify(Public Key, Metadata, Signature)
```

## Security Considerations

### Constant-Time Operations
- NTT uses precomputed zeta powers to avoid data-dependent branching
- Montgomery reduction uses fixed-time arithmetic
- Signature comparison uses constant-time XOR accumulation

### Side-Channel Resistance
- No secret-dependent array indexing
- All rejection sampling based on public bounds
- Memory is zeroed after use via `ml_dsa_secure_zero()`

### Implicit Rejection
- Invalid ciphertexts produce random-looking shared secrets (ML-KEM)
- Prevents distinguishing valid from invalid decapsulations

## Performance (Expected)

| Operation | Desktop (Apple M2) | Mobile (ARM Cortex-A76) |
|-----------|-------------------|------------------------|
| ML-DSA KeyGen | ~100-150 µs | ~300-500 µs |
| ML-DSA Sign | ~300-800 µs | ~1-2 ms |
| ML-DSA Verify | ~150-200 µs | ~400-600 µs |
| ML-KEM KeyGen | ~40-50 µs | ~100-150 µs |
| ML-KEM Encaps | ~40-50 µs | ~100-150 µs |
| ML-KEM Decaps | ~45-55 µs | ~120-180 µs |

## File Structure

```
src/
├── ml_kem.zig           # ML-KEM-768 core (NTT, sampling, arithmetic)
├── ml_kem_api.zig       # ML-KEM-768 high-level API
├── ml_dsa_complete.zig  # ML-DSA-65 complete implementation
├── ml_dsa_ffi.zig       # C FFI exports for Tauri integration
├── bench.zig            # ML-KEM benchmarks
└── bench_dsa.zig        # ML-DSA benchmarks
```

## Zig 0.14 → 0.16 Migration Notes

For Claude Code integration, the following API changes may be needed:

1. **Module system**: Zig 0.16 may have different module import syntax
2. **Build API**: `b.createModule()` and `addImport()` patterns may change
3. **Hash APIs**: `std.crypto.hash.sha3` interfaces may be updated

## References

- [NIST FIPS 203: Module-Lattice-Based Key-Encapsulation Mechanism Standard](https://doi.org/10.6028/NIST.FIPS.203)
- [NIST FIPS 204: Module-Lattice-Based Digital Signature Standard](https://doi.org/10.6028/NIST.FIPS.204)
- [CRYSTALS-Dilithium Algorithm Specifications](https://pq-crystals.org/dilithium/)
- [CRYSTALS-Kyber Algorithm Specifications](https://pq-crystals.org/kyber/)

## License

MIT License - Quantum Encoding Ltd

## Author

Implemented for Quantum Vault by Claude (Anthropic) in collaboration with Rich (Quantum Encoding).
