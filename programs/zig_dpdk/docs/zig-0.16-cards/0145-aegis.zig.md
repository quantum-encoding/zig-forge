# Migration Card: AEGIS Crypto Implementation

## 1) Concept
This file implements the AEGIS authenticated encryption system, a high-performance AES-based encryption family. It provides multiple variants with different security levels and performance characteristics:

- **AEGIS-128*** variants: 128-bit keys and nonces (Aegis128L, Aegis128X2, Aegis128X4)
- **AEGIS-256*** variants: 256-bit keys and nonces (Aegis256, Aegis256X2, Aegis256X4)
- **Tag sizes**: 128-bit and 256-bit authentication tags
- **MAC variants**: Message authentication code implementations built on top of the encryption variants

The implementation uses SIMD-optimized AES operations for parallel processing, with different "degree" parameters controlling the level of parallelism (1, 2, or 4).

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **No allocator dependencies**: All operations work directly on provided buffers
- **Stack-based operations**: Uses fixed-size arrays and slices without dynamic allocation
- **Zero heap usage**: The API is completely allocator-free

### I/O Interface Changes
- **Direct buffer manipulation**: Functions operate directly on byte slices without stream interfaces
- **No dependency injection**: Pure cryptographic functions without I/O abstraction layers
- **Alignment requirements**: Some internal operations require aligned buffers (via `align(alignment)`)

### Error Handling Changes
- **Specific error type**: Uses `crypto.errors.AuthenticationError` for authentication failures
- **Single error case**: Only returns `error.AuthenticationFailed` on tag verification failure
- **Timing-safe comparison**: Uses `crypto.timing_safe.eql` for tag verification

### API Structure Changes
- **Static functions only**: No instance-based API - all operations are module-level functions
- **Parameter ordering**: Consistent `(output, tag, input, associated_data, nonce, key)` pattern
- **Tag handling**: Separate tag parameter rather than embedded in ciphertext

## 3) The Golden Snippet

```zig
const std = @import("std");
const Aegis128L = std.crypto.aegis.Aegis128L;

test "AEGIS-128L encryption example" {
    const key = [_]u8{0x10, 0x01} ++ [_]u8{0x00} ** 14;
    const nonce = [_]u8{0x10, 0x00, 0x02} ++ [_]u8{0x00} ** 13;
    const ad = [_]u8{0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07};
    const message = "Hello, AEGIS! This is a test message.";

    var ciphertext: [message.len]u8 = undefined;
    var decrypted: [message.len]u8 = undefined;
    var tag: [Aegis128L.tag_length]u8 = undefined;

    // Encrypt
    Aegis128L.encrypt(&ciphertext, &tag, message, &ad, nonce, key);

    // Decrypt and verify
    try Aegis128L.decrypt(&decrypted, &ciphertext, tag, &ad, nonce, key);

    // Verify decryption matches original
    try std.testing.expectEqualSlices(u8, message, &decrypted);
}
```

## 4) Dependencies

- **std.mem**: For memory operations (`writeInt`, `secureZero`)
- **std.crypto**: Core crypto primitives and error types
- **std.crypto.core.aes**: AES block operations for the underlying cipher
- **std.crypto.timing_safe**: Timing-safe comparisons
- **std.debug**: For assertions

**Note**: This implementation has no external dependencies beyond the Zig standard library's crypto module and uses no allocator, making it suitable for constrained environments.