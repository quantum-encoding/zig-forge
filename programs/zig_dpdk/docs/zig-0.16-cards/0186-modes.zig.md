# Migration Card: `std/crypto/modes.zig`

## 1) Concept

This file implements Counter Mode (CTR) encryption for block ciphers in Zig's standard library crypto module. It provides two public functions: `ctr` for standard counter mode and `ctrSlice` for extended counter mode with configurable counter position and size. The implementation creates a key stream by encrypting an incrementing counter using a block cipher and XORing it with the source material.

Key components include:
- Standard CTR mode using the entire block as counter
- Extended CTR mode supporting custom counter positions/sizes (useful for modes like AES-GCM-SIV)
- Optimized parallel processing for large inputs using `xorWide` operations
- Support for both big-endian and little-endian counter incrementing

## 2) The 0.11 vs 0.16 Diff

**No significant migration changes detected.** This file maintains consistent patterns:

- **No allocator requirements**: Functions operate directly on provided slices without memory allocation
- **No I/O interface changes**: Pure computational functions with no file/stream dependencies  
- **No error handling changes**: Functions are `void`-returning with no error sets
- **Consistent API structure**: Both functions follow the same parameter pattern

The public API signatures remain stable:
```zig
// Standard CTR mode
pub fn ctr(comptime BlockCipher: anytype, block_cipher: BlockCipher, 
           dst: []u8, src: []const u8, iv: [BlockCipher.block_length]u8, 
           endian: std.builtin.Endian) void

// Extended CTR mode with configurable counter
pub fn ctrSlice(comptime BlockCipher: anytype, block_cipher: BlockCipher,
                dst: []u8, src: []const u8, iv: [BlockCipher.block_length]u8,
                endian: std.builtin.Endian, comptime counter_offset: usize, 
                comptime counter_size: usize) void
```

## 3) The Golden Snippet

```zig
const std = @import("std");
const aes = std.crypto.core.aes;

// Setup
const key = [_]u8{ 0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6, 0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c };
const iv = [_]u8{ 0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff };
const ctx = aes.Aes128.initEnc(key);

// Encryption
const plaintext = "Hello, World!";
var ciphertext: [plaintext.len]u8 = undefined;
std.crypto.modes.ctr(aes.AesEncryptCtx(aes.Aes128), ctx, &ciphertext, plaintext, iv, std.builtin.Endian.big);

// Decryption (CTR is symmetric)
var decrypted: [plaintext.len]u8 = undefined;
std.crypto.modes.ctr(aes.AesEncryptCtx(aes.Aes128), ctx, &decrypted, &ciphertext, iv, std.builtin.Endian.big);
```

## 4) Dependencies

- `std` (root import)
- `std.mem` (for `readInt`, `writeInt`, `@memcpy`)
- `std.debug` (for assertions)
- `std.crypto.core.aes` (in tests for AES implementation)
- `std.testing` (in tests only)

**Note**: This is a stable cryptographic utility module with minimal external dependencies beyond core memory operations and the underlying block cipher implementations.