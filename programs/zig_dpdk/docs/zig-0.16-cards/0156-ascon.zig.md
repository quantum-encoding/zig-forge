# Migration Card: std/crypto/ascon.zig

## 1) Concept

This file implements the Ascon cryptographic permutation and several cryptographic primitives built on top of it. Ascon is a 320-bit permutation selected as the new standard for lightweight cryptography in the NIST Lightweight Cryptography competition (2019-2023). The file provides implementations for:

- **Ascon State**: The core 320-bit permutation with endianness-aware operations
- **Ascon-AEAD128**: Authenticated encryption with associated data (128-bit security)
- **Ascon-Hash256**: Cryptographic hash function (256-bit output)
- **Ascon-XOF128**: Extendable output function (variable-length output)
- **Ascon-CXOF128**: Customizable extendable output function

The implementation is optimized for timing and side-channel resistance, making it suitable for embedded applications and general-purpose cryptography.

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **No allocator dependencies**: All operations are purely computational and work with fixed-size buffers
- **Stack-based operations**: Functions operate on caller-provided slices without dynamic allocation
- **Zero-allocation patterns**: Uses fixed arrays and slice parameters instead of allocator-based buffers

### I/O Interface Changes
- **Direct buffer manipulation**: Uses `@memcpy` and slice operations instead of reader/writer interfaces
- **Endianness-aware operations**: All cryptographic operations explicitly handle endianness conversion
- **In-place operations**: AEAD encryption/decryption supports in-place operation when input/output buffers overlap

### Error Handling Changes
- **Specific error types**: `AsconAead128.decrypt` returns `crypto.errors.AuthenticationError` specifically
- **Secure error handling**: On authentication failure, output buffer is securely zeroed before returning error
- **No generic error sets**: Each function returns specific, meaningful errors where applicable

### API Structure Changes
- **Factory functions**: `init()`, `initFromWords()`, `initXof()`, `initXofA()` for state initialization
- **Streaming interfaces**: `update()`/`final()` for hash functions, `update()`/`squeeze()` for XOFs
- **One-shot convenience functions**: `hash()` methods that combine init/update/final operations
- **Options structs**: All hash/XOF functions accept `Options` parameter for future extensibility

## 3) The Golden Snippet

```zig
const std = @import("std");
const crypto = std.crypto;

// Ascon-AEAD128 encryption and decryption
pub fn example() !void {
    const key = [_]u8{0x01} ** 16;
    const nonce = [_]u8{0x02} ** 16;
    const plaintext = "Hello, Ascon!";
    const ad = "metadata";
    
    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [16]u8 = undefined;
    
    // Encrypt
    crypto.ascon.AsconAead128.encrypt(
        &ciphertext, 
        &tag, 
        plaintext, 
        ad, 
        nonce, 
        key
    );
    
    // Decrypt
    var decrypted: [plaintext.len]u8 = undefined;
    try crypto.ascon.AsconAead128.decrypt(
        &decrypted, 
        &ciphertext, 
        tag, 
        ad, 
        nonce, 
        key
    );
    
    // Verify decryption matches original
    std.debug.assert(std.mem.eql(u8, plaintext, &decrypted));
}
```

## 4) Dependencies

- **std.mem**: Used extensively for memory operations, endianness conversion, and secure zeroing
- **std.crypto**: For `crypto.secureZero`, `crypto.timing_safe.eql`, and error types
- **std.debug**: For runtime assertions and debugging support
- **std.math**: For `rotr` (rotate right) operations in the permutation
- **std.testing**: For comprehensive test suite with official test vectors

The implementation has no external dependencies beyond the Zig standard library and provides a complete, self-contained cryptographic suite based on the Ascon permutation.