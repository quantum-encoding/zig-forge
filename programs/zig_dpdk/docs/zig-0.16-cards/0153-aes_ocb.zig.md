# Migration Card: `std/crypto/aes_ocb.zig`

## 1) Concept

This file implements AES-OCB (Offset Codebook Mode) authenticated encryption for AES-128 and AES-256. It provides a cryptographic implementation following RFC 7253, offering both encryption and decryption with built-in authentication. The key components include:

- Two main public types: `Aes128Ocb` and `Aes256Ocb` for different key sizes
- Authenticated encryption/decryption functions that process messages with associated data
- Hardware-accelerated implementations for x86_64 (AES-NI) and AArch64 (ARM AES) when available
- Internal Lx table management for OCB offset calculations and wide-block processing optimizations

## 2) The 0.11 vs 0.16 Diff

This crypto module follows a stateless, pure-function pattern that remains consistent between Zig versions:

**No Breaking Changes Identified:**
- **No Allocator Requirements**: Functions operate on pre-allocated slices without dynamic allocation
- **Stateless Design**: All context is passed explicitly through function parameters
- **Error Handling**: Uses specific `AuthenticationError` for decryption failures
- **API Structure**: Simple function-based API without init/open patterns

**Function Signatures (Unchanged Pattern):**
```zig
// Encryption - takes output buffers, input data, and cryptographic parameters
pub fn encrypt(c: []u8, tag: *[tag_length]u8, m: []const u8, ad: []const u8, 
               npub: [nonce_length]u8, key: [key_length]u8) void

// Decryption - returns AuthenticationError on verification failure  
pub fn decrypt(m: []u8, c: []const u8, tag: [tag_length]u8, ad: []const u8,
               npub: [nonce_length]u8, key: [key_length]u8) AuthenticationError!void
```

## 3) The Golden Snippet

```zig
const std = @import("std");
const Aes128Ocb = std.crypto.Aes128Ocb;

// Example: Encrypt and decrypt a message with associated data
fn example() !void {
    const key: [Aes128Ocb.key_length]u8 = .{0x00} ** 16; // 16-byte key
    const nonce: [Aes128Ocb.nonce_length]u8 = .{0x00} ** 12; // 12-byte nonce
    
    const message = "Hello, World!";
    const associated_data = "meta-data";
    
    var ciphertext: [message.len]u8 = undefined;
    var tag: [Aes128Ocb.tag_length]u8 = undefined;
    
    // Encrypt
    Aes128Ocb.encrypt(&ciphertext, &tag, message, associated_data, nonce, key);
    
    // Decrypt  
    var decrypted: [message.len]u8 = undefined;
    try Aes128Ocb.decrypt(&decrypted, &ciphertext, tag, associated_data, nonce, key);
    
    // decrypted now contains "Hello, World!"
}
```

## 4) Dependencies

**Heavy Dependencies:**
- `std.mem` - memory operations, slicing, and comparison
- `std.crypto.core.aes` - underlying AES cipher implementation
- `std.math` - mathematical utilities like `log2_int`

**Light Dependencies:**
- `std.debug` - assertions for input validation
- `std.crypto.errors` - authentication error type
- `std.crypto.timing_safe` - constant-time comparisons
- `builtin` - CPU feature detection for hardware acceleration

**Test Dependencies:**
- `std.fmt` - hex conversion for test vectors
- `std.testing` - test framework utilities