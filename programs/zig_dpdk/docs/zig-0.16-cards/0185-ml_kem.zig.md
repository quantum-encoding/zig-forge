# Migration Card: ML-KEM/Crystals-Kyber Implementation

## 1) Concept

This file implements the IND-CCA2 post-quantum secure Key Encapsulation Mechanism (KEM) for both ML-KEM (NIST FIPS-203) and CRYSTALS-Kyber (v3.02/"draft00" CFRG draft). The implementation provides two namespaces: `d00` for the CFRG draft version and `nist` for the FIPS-203 publication, each with three security levels (512, 768, 1024).

Key components include:
- Public/Secret key types with serialization methods
- Key generation (deterministic and random)
- Encapsulation/decapsulation operations
- Inner PKE scheme for the underlying IND-CPA encryption
- Polynomial arithmetic with NTT optimizations
- Compression/decompression functions for space efficiency

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
**No allocator dependencies found.** This implementation is entirely allocator-free:
- Key generation uses stack-allocated arrays
- Serialization/deserialization work with fixed-size buffers
- All operations are deterministic with no dynamic memory allocation

### I/O Interface Changes
**No traditional I/O interfaces.** The API uses:
- Fixed-size byte arrays for all inputs/outputs
- Cryptographic hash functions (SHA3, Shake256) for deterministic operations
- Random number generation via `crypto.random` for non-deterministic operations

### Error Handling Changes
**Specific error types:**
```zig
pub fn fromBytes(buf: *const [bytes_length]u8) errors.NonCanonicalError!PublicKey
```
- Uses `errors.NonCanonicalError` for deserialization failures
- Error handling is minimal and specific to canonical representation checks

### API Structure Changes
**Modern Zig patterns:**
- Factory functions: `KeyPair.generate()` and `KeyPair.generateDeterministic()`
- Method-based API: `public_key.encaps()`, `secret_key.decaps()`
- Fixed-size array returns: `[shared_length]u8`, `[ciphertext_length]u8`
- Comptime parameterization for different security levels

## 3) The Golden Snippet

```zig
const std = @import("std");
const kyber = std.crypto.ml_kem.d00.Kyber512;

// Generate a key pair
const kp = kyber.KeyPair.generate();

// Encapsulate a shared secret for the public key
const encapsulated = kp.public_key.encaps(null);

// Decapsulate the shared secret using the secret key
const shared_secret = try kp.secret_key.decaps(&encapsulated.ciphertext);

// Verify the shared secrets match
std.debug.assert(std.mem.eql(u8, &shared_secret, &encapsulated.shared_secret));
```

## 4) Dependencies

- **`std.crypto`** - Core cryptographic primitives (SHA3, Shake256, random)
- **`std.mem`** - Memory operations and comparisons
- **`std.math`** - Mathematical utilities
- **`std.debug`** - Assertions and debugging
- **`std.testing`** - Test utilities

**Key Crypto Dependencies:**
- `std.crypto.hash.sha3` - SHA3-256/512 for hashing
- `std.crypto.hash.shake256` - Extensible output function
- `std.crypto.timing_safe` - Constant-time comparisons
- `std.Random.DefaultPrng` - Random number generation

This implementation shows Zig 0.16's focus on compile-time parameterization, allocator-free designs, and type-safe fixed-size buffers for cryptographic operations.