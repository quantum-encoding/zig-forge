# Migration Analysis: `std/crypto/aes/armcrypto.zig`

## 1) Concept

This file provides ARM-optimized implementations of AES (Advanced Encryption Standard) cryptographic operations using ARMv8 Crypto Extension instructions. It implements both single-block and parallel block operations for AES-128 and AES-256 encryption/decryption.

Key components include:
- `Block`: Represents a single 16-byte AES block with encryption/decryption operations using ARM assembly instructions (`aese`, `aesd`, `aesmc`, `aesimc`)
- `BlockVec`: A generic type for fixed-size vectors of AES blocks supporting parallel operations
- `AesEncryptCtx`/`AesDecryptCtx`: Context types for performing encryption/decryption with standard key schedules
- `Aes128`/`Aes256`: Convenient wrapper structs for specific AES variants

## 2) The 0.11 vs 0.16 Diff

This file demonstrates several Zig 0.16 patterns:

**No Allocator Requirements**: All operations are allocation-free and use stack-based types. Context initialization takes key bytes directly without allocator parameters.

**Comptime Generic Patterns**: Heavy use of `comptime` parameters for block counts and type generation:
```zig
pub fn encryptWide(ctx: Self, comptime count: usize, dst: *[16 * count]u8, src: *const [16 * count]u8) void
```

**Struct-based API Design**: Context creation uses factory functions rather than direct struct initialization:
```zig
// 0.16 pattern
const enc_ctx = Aes128.initEnc(key);
const dec_ctx = Aes128.initDec(key);
```

**Inline Assembly Syntax**: Uses Zig's inline assembly with explicit input/output constraints:
```zig
.repr = (asm (
    \\ mov   %[out].16b, %[in].16b
    \\ aese  %[out].16b, %[zero].16b
    : [out] "=&x" (-> Repr),
    : [in] "x" (block.repr),
      [zero] "x" (zero),
))
```

## 3) The Golden Snippet

```zig
const std = @import("std");
const aes = std.crypto.aes;

// AES-128 encryption example
pub fn encrypt_example() void {
    const key = [16]u8{0x00} ** 16; // 128-bit key
    const plaintext = [16]u8{0x01} ** 16;
    var ciphertext: [16]u8 = undefined;
    
    const enc_ctx = aes.Aes128.initEnc(key);
    enc_ctx.encrypt(&ciphertext, &plaintext);
    
    // Decrypt to verify
    var decrypted: [16]u8 = undefined;
    const dec_ctx = aes.Aes128.initDec(key);
    dec_ctx.decrypt(&decrypted, &ciphertext);
    
    // decrypted should equal plaintext
}
```

## 4) Dependencies

- `std.mem`: Used for `bytesToValue`, `toBytes` operations
- `std.debug`: Used for assertions and debugging
- No external I/O or network dependencies
- Heavy reliance on ARM-specific assembly instructions and vector types

The API is designed for cryptographic operations with minimal dependencies, focusing on performance through ARM crypto extensions and compile-time optimization.