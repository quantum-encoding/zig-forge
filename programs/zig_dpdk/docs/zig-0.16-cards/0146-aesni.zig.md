# Migration Card: `std/crypto/aes/aesni.zig`

## 1) Concept

This file provides AES (Advanced Encryption Standard) encryption and decryption implementations optimized for x86_64 processors with AES-NI (AES New Instructions) support. It exposes public APIs for single-block operations, parallel block processing using SIMD instructions, and complete AES-128/AES-256 encryption contexts with standard key scheduling.

Key components include:
- `Block`: A single AES block (16 bytes) with encryption/decryption operations using VAES instructions
- `BlockVec`: A vector type for parallel processing of multiple AES blocks using SIMD
- `AesEncryptCtx`/`AesDecryptCtx`: Complete encryption/decryption contexts with key scheduling
- `Aes128`/`Aes256`: Convenient wrapper types for standard AES variants

## 2) The 0.11 vs 0.16 Diff

This file follows modern Zig patterns with no significant migration changes from 0.11:

- **No explicit allocator requirements**: All operations are stack-based with fixed-size buffers
- **No I/O interface changes**: Operates directly on byte arrays without dependency injection
- **No error handling changes**: Functions don't return errors - all operations are deterministic
- **Modern API structure**: Uses `initEnc`/`initDec` factory pattern consistently
- **Comptime-driven design**: Heavy use of `comptime` parameters for block counts and type generation
- **SIMD integration**: Leverages inline assembly for AES-NI instructions with vector types

The API follows current Zig conventions with pure functions and explicit type parameters.

## 3) The Golden Snippet

```zig
const std = @import("std");
const aesni = std.crypto.aes.aesni;

// AES-128 encryption example
pub fn example() void {
    const key = [_]u8{0x00} ** 16; // 128-bit key
    const plaintext = [_]u8{0x00} ** 16;
    var ciphertext: [16]u8 = undefined;
    
    const encrypt_ctx = aesni.Aes128.initEnc(key);
    encrypt_ctx.encrypt(&ciphertext, &plaintext);
    
    // Decrypt back
    const decrypt_ctx = aesni.Aes128.initDec(key);
    var decrypted: [16]u8 = undefined;
    decrypt_ctx.decrypt(&decrypted, &ciphertext);
    
    // decrypted should equal plaintext
}
```

## 4) Dependencies

- `std.mem` - For byte conversions and memory operations
- `std.debug` - For runtime assertions
- `builtin` - For CPU feature detection and architecture checks
- `std.Target.x86.cpu` - For CPU model-specific optimizations

This is a public API file with significant migration impact for cryptographic applications using AES with hardware acceleration.