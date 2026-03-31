# Migration Card: AES-GCM-SIV Implementation

## 1) Concept

This file implements AES-GCM-SIV (Galois/Counter Mode with Synthetic Initialization Vector), an authenticated encryption algorithm defined in RFC 8452. The key innovation of AES-GCM-SIV is that it provides security even when nonces are accidentally reused, unlike regular AES-GCM which becomes catastrophically broken with nonce reuse. The implementation provides two variants: `Aes128GcmSiv` for 128-bit keys and `Aes256GcmSiv` for 256-bit keys.

The core components include key derivation using the master key and nonce, POLYVAL-based authentication (similar to GHASH), and CTR mode encryption. The algorithm derives separate authentication and encryption keys for each encryption operation, making it resistant to nonce reuse while maintaining the performance characteristics of AES-GCM.

## 2) The 0.11 vs 0.16 Diff

**No significant API changes detected** - this cryptographic primitive follows a consistent pattern:

- **No allocator requirements**: Both `encrypt` and `decrypt` functions operate on pre-allocated buffers without dynamic memory allocation
- **No I/O interface changes**: Pure computational API with no file/stream dependencies
- **Error handling consistency**: The `decrypt` function returns `AuthenticationError!void` with specific authentication failure handling
- **API structure stability**: Direct function calls with explicit parameters rather than instance-based patterns

The public API maintains the same signature pattern:
```zig
// Encryption
encrypt(c: []u8, tag: *[tag_length]u8, m: []const u8, ad: []const u8, npub: [nonce_length]u8, key: [key_length]u8) void

// Decryption  
decrypt(m: []u8, c: []const u8, tag: [tag_length]u8, ad: []const u8, npub: [nonce_length]u8, key: [key_length]u8) AuthenticationError!void
```

## 3) The Golden Snippet

```zig
const std = @import("std");
const crypto = std.crypto;

// Example using AES-128-GCM-SIV
const key: [16]u8 = [_]u8{0x01} ** 16;
const nonce: [12]u8 = [_]u8{0x03} ** 12;
const plaintext = "Hello, World!";
const associated_data = "metadata";

var ciphertext: [plaintext.len]u8 = undefined;
var tag: [16]u8 = undefined;

// Encrypt
crypto.aes_gcm_siv.Aes128GcmSiv.encrypt(
    &ciphertext, 
    &tag, 
    plaintext, 
    associated_data, 
    nonce, 
    key
);

// Decrypt  
var decrypted: [plaintext.len]u8 = undefined;
try crypto.aes_gcm_siv.Aes128GcmSiv.decrypt(
    &decrypted, 
    &ciphertext, 
    tag, 
    associated_data, 
    nonce, 
    key
);
```

## 4) Dependencies

- `std.mem` - Memory operations and integer serialization
- `std.math` - Block count calculations
- `std.crypto.core.aes` - AES block cipher implementation
- `std.crypto.modes` - CTR mode encryption
- `std.crypto.ghash_polyval` - POLYVAL authentication
- `std.crypto.errors` - Authentication error types
- `std.crypto.timing_safe` - Constant-time comparisons
- `std.debug` - Runtime assertions