# Zig 0.16 Crypto Module Migration Card

## 1) Concept

This file is the main entry point for Zig's standard cryptography library (`std.crypto`). It serves as a comprehensive collection of cryptographic primitives and algorithms organized into logical categories. The module provides authenticated encryption (AEAD), hash functions, digital signatures, key exchange mechanisms, password hashing, stream ciphers, and various cryptographic utilities.

Key components include AEAD constructions like ChaCha20-Poly1305 and AES-GCM, hash functions (SHA-2, SHA-3, BLAKE3), elliptic curve cryptography (Curve25519, P-256), digital signatures (Ed25519, ML-DSA), and password hashing algorithms (Argon2, bcrypt, scrypt). The module also provides a thread-local cryptographically secure pseudo-random number generator and side-channel mitigation configurations.

## 2) The 0.11 vs 0.16 Diff

This file primarily serves as a module organization layer that re-exports cryptographic implementations from submodules. The public API patterns show several migration-relevant changes:

**Explicit Allocator Requirements:**
- Password hashing functions (`pwhash`) explicitly require allocators and have structured error types that include `error{AllocatorRequired}`
- The `pwhash.KdfError` type includes `std.mem.Allocator.Error` and `std.Thread.SpawnError`, indicating memory and threading dependencies

**Error Handling Changes:**
- Structured error type hierarchies (e.g., `pwhash.Error`, `pwhash.HasherError`, `pwhash.KdfError`)
- Specific error types for different cryptographic operations rather than generic error sets

**API Structure Changes:**
- Consistent use of init/final patterns for hash functions and AEAD constructions
- Factory-style initialization for cryptographic primitives (e.g., `Hasher.init(.{})` pattern shown in tests)
- Side-channel mitigation configuration through enum types (`SideChannelsMitigations`)

**Threading and Memory Safety:**
- Thread-local CSPRNG (`random`) replaces global state
- Explicit memory zeroing with `secureZero` function using volatile semantics

## 3) The Golden Snippet

```zig
const std = @import("std");
const crypto = std.crypto;

// Using the thread-local CSPRNG
const random_value = crypto.random.int(u64);

// Secure memory zeroing
var sensitive_data = [_]u8{0xde, 0xad, 0xbe, 0xef} ** 16;
crypto.secureZero(u8, &sensitive_data);

// Hash computation with init/update/final pattern
var hasher = crypto.hash.sha2.Sha256.init(.{});
hasher.update("hello");
hasher.update(" world");
var hash: [32]u8 = undefined;
hasher.final(&hash);
```

## 4) Dependencies

- `std.mem` - Memory operations and allocator interfaces
- `std.Thread` - Threading support for password hashing operations
- Internal crypto submodules (`crypto/` directory) - All cryptographic implementations
- `std.testing` - Test framework for verification

**Note**: This analysis focuses on the public API structure. The actual migration impact for specific cryptographic algorithms would require examining the individual implementation files in the `crypto/` subdirectory.