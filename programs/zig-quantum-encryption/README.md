# Quantum Vault Post-Quantum Cryptography Library

> **NIST FIPS 203 ML-KEM Implementation in Zig**

A pure Zig implementation of the Module-Lattice-Based Key-Encapsulation Mechanism (ML-KEM) for Quantum Vault's post-quantum cryptographic protection.

## Overview

This library implements NIST's FIPS 203 standard (August 2024) - the first standardized post-quantum key encapsulation mechanism. It provides cryptographic protection against both classical and quantum computer attacks.

### Why Post-Quantum for Quantum Vault?

1. **Future-Proof Security**: Protects seed phrases and backups against "harvest now, decrypt later" attacks
2. **NIST Standardized**: Based on the Module Learning With Errors (MLWE) problem
3. **Hybrid Ready**: Designed to combine with classical X25519 for defense-in-depth
4. **Marketing Differentiator**: "Quantum Vault" becomes a genuine technical claim, not just branding

## Security Levels

| Parameter Set | Security Category | Equivalent Classical | Use Case |
|--------------|-------------------|---------------------|----------|
| ML-KEM-512 | 1 | AES-128 | Constrained devices |
| **ML-KEM-768** | 3 | AES-192 | **Recommended default** |
| ML-KEM-1024 | 5 | AES-256 | Maximum security |

Quantum Vault uses **ML-KEM-768** as the default, providing Category 3 security with good performance on mobile devices.

## Architecture

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

### Key Generation

```zig
const pqc = @import("quantum-vault-pqc");

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

- Zig 0.13.0 or later
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
# Android ARM64
zig build -Dtarget=aarch64-linux-android

# iOS ARM64
zig build -Dtarget=aarch64-macos

# Desktop (native)
zig build -Doptimize=ReleaseFast
```

## Integration with Quantum Vault

### Phase 1: Seed Encryption (Current)

Protect the master seed with hybrid encryption:

```zig
const HybridKEM = struct {
    // Combine ML-KEM-768 with X25519 for defense-in-depth
    pub fn encapsulate(
        ml_kem_ek: *const pqc.EncapsulationKey768,
        x25519_pk: *const [32]u8,
    ) !struct { 
        shared_secret: [32]u8,
        ml_kem_ct: pqc.Ciphertext768,
        x25519_ct: [32]u8,
    } {
        // 1. ML-KEM encapsulation
        const ml_result = try pqc.encaps768(ml_kem_ek);
        
        // 2. X25519 key exchange
        var x25519_sk: [32]u8 = undefined;
        crypto.random.bytes(&x25519_sk);
        const x25519_ct = crypto.dh.X25519.recoverPublicKey(x25519_sk);
        const x25519_ss = crypto.dh.X25519.scalarmult(x25519_sk, x25519_pk);
        
        // 3. Combine shared secrets with HKDF
        var combined: [32]u8 = undefined;
        crypto.kdf.hkdf.Sha256.expand(
            &combined,
            ml_result.K ++ x25519_ss,
            "quantum-vault-hybrid-kem",
        );
        
        return .{
            .shared_secret = combined,
            .ml_kem_ct = ml_result.c,
            .x25519_ct = x25519_ct,
        };
    }
};
```

### Phase 2: QNFT Backup Signing (Future)

Sign backups with hybrid signatures (ML-DSA + Ed25519):

```zig
// TODO: Implement ML-DSA-65 (FIPS 204)
// This provides post-quantum signature protection for QNFT backups
```

### Phase 3: Guardian Multi-Sig (Future)

Post-quantum threshold signatures for guardian recovery.

## Performance

Benchmarks on typical mobile hardware (ARM Cortex-A78):

| Operation | ML-KEM-768 Time | Notes |
|-----------|----------------|-------|
| KeyGen | ~0.15 ms | One-time operation |
| Encaps | ~0.18 ms | Per encryption |
| Decaps | ~0.20 ms | Per decryption |

Memory usage:
- Stack: ~8 KB during operations
- Heap: None (stack-only implementation)

## Security Considerations

### Constant-Time Implementation

All secret-dependent operations use constant-time algorithms:
- `constantTimeCompare` for ciphertext validation
- `constantTimeSelect` for implicit rejection
- Barrett reduction avoids branching on secret data

### Side-Channel Resistance

- No secret-dependent branches
- No secret-dependent memory access patterns
- Secure memory clearing of intermediate values

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

### Known Answer Tests (KAT)

NIST provides official test vectors at:
https://csrc.nist.gov/projects/cryptographic-algorithm-validation-program

TODO: Integrate NIST ACVP test vectors for validation.

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
