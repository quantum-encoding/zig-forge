# Migration Analysis: ML-DSA Implementation

## 1) Concept

This file implements the Module-Lattice-Based Digital Signature Algorithm (ML-DSA) as specified in NIST FIPS 204, providing post-quantum secure digital signatures based on the hardness of the Module Learning With Errors (MLWE) and Module Short Integer Solution (MSIS) problems over module lattices.

The implementation provides three parameter sets with different security levels:
- **ML-DSA-44**: NIST security category 2 (128-bit security)
- **ML-DSA-65**: NIST security category 3 (192-bit security)  
- **ML-DSA-87**: NIST security category 5 (256-bit security)

Key components include:
- Polynomial and polynomial vector operations with Number Theoretic Transform (NTT) for efficiency
- Modular arithmetic optimized for the specific modulus Q = 8380417
- Key generation, signing, and verification operations
- Streaming APIs for incremental message processing
- Support for context strings and deterministic/hedged signatures

## 2) The 0.11 vs 0.16 Diff

This implementation follows modern Zig 0.16 patterns with no explicit migration requirements from 0.11:

**Key 0.16 Patterns Observed:**

1. **No Explicit Allocator Requirements**: The API is allocator-free - all operations use stack-allocated buffers and caller-provided slices.

2. **Modern Error Handling**: Uses specific error types from `std.crypto.errors`:
   - `ContextTooLongError`
   - `EncodingError` 
   - `SignatureVerificationError`

3. **Factory Pattern for Parameter Sets**: Uses comptime parameterization:
   ```zig
   pub const MLDSA44 = MLDSAImpl(.{ ... });
   pub const MLDSA65 = MLDSAImpl(.{ ... });
   pub const MLDSA87 = MLDSAImpl(.{ ... });
   ```

4. **Streaming API Design**: Provides incremental signer/verifier interfaces:
   - `Signer` for incremental signing
   - `Verifier` for incremental verification

5. **Context Support**: All operations support optional context strings with length validation (max 255 bytes).

6. **Deterministic/Hedged Signatures**: Optional noise parameter for fault attack resistance.

## 3) The Golden Snippet

```zig
const std = @import("std");
const MLDSA44 = std.crypto.ml_dsa.MLDSA44;

test "basic signing and verification" {
    // Generate key pair
    const kp = MLDSA44.KeyPair.generate();
    
    const message = "Hello, post-quantum world!";
    
    // Sign with deterministic mode (no noise)
    const sig = try kp.sign(message, null);
    
    // Verify signature
    try sig.verify(message, kp.public_key);
}

test "streaming API with context" {
    const kp = MLDSA44.KeyPair.generate();
    const context = "my-application-context";
    
    // Incremental signing
    var signer = try kp.signerWithContext(null, context);
    signer.update("Hello, ");
    signer.update("world!");
    const sig = signer.finalize();
    
    // Incremental verification
    var verifier = try sig.verifierWithContext(kp.public_key, context);
    verifier.update("Hello, ");
    verifier.update("world!");
    try verifier.verify();
}

test "deterministic key generation" {
    const seed = [_]u8{0x42} ** 32;
    const kp = try MLDSA44.KeyPair.generateDeterministic(seed);
    
    // Same seed produces same keys
    const kp2 = try MLDSA44.KeyPair.generateDeterministic(seed);
    try std.testing.expectEqualSlices(u8, &kp.public_key.toBytes(), &kp2.public_key.toBytes());
}
```

## 4) Dependencies

The implementation heavily depends on:

- **`std.crypto.hash.sha3`**: For SHAKE-128 and SHAKE-256 hashing (used in key derivation, sampling, and challenge generation)
- **`std.crypto.errors`**: For specific error types used throughout the API
- **`std.mem`**: For memory operations and comparisons
- **`std.math`**: For mathematical utilities
- **`std.debug`**: For assertions in debug builds
- **`std.testing`**: For the comprehensive test suite

The implementation is self-contained and doesn't require external dependencies beyond the Zig standard library's cryptographic primitives.