# Migration Card: AES-GCM Implementation

## 1) Concept

This file implements AES-GCM (Galois/Counter Mode) authenticated encryption for AES-128 and AES-256. It provides a pure cryptographic implementation without any I/O or memory allocation dependencies. The key components include:

- Two main public types: `Aes128Gcm` and `Aes256Gcm` which are instances of a generic AES-GCM implementation
- Core `encrypt` and `decrypt` functions that operate on slices with fixed-size keys, nonces, and authentication tags
- The implementation uses counter mode (CTR) for encryption and GHASH for authentication, following the standard AES-GCM specification

## 2) The 0.11 vs 0.16 Diff

**No significant migration changes detected** - this implementation follows consistent patterns:

- **No Allocator Requirements**: Functions operate directly on provided slices without dynamic memory allocation
- **No I/O Interface Changes**: Pure cryptographic functions with no file/stream dependencies
- **Error Handling**: Uses specific `AuthenticationError` for decryption failures, consistent with 0.11 patterns
- **API Structure**: Static functions with explicit parameters, no instance-based patterns or factory functions

The function signatures remain stable:
- `encrypt(c: []u8, tag: *[tag_length]u8, m: []const u8, ad: []const u8, npub: [nonce_length]u8, key: [key_length]u8) void`
- `decrypt(m: []u8, c: []const u8, tag: [tag_length]u8, ad: []const u8, npub: [nonce_length]u8, key: [key_length]u8) AuthenticationError!void`

## 3) The Golden Snippet

```zig
const std = @import("std");
const Aes256Gcm = std.crypto.aes_gcm.Aes256Gcm;

// Encrypt and decrypt a message
const key: [Aes256Gcm.key_length]u8 = [_]u8{0x69} ** Aes256Gcm.key_length;
const nonce: [Aes256Gcm.nonce_length]u8 = [_]u8{0x42} ** Aes256Gcm.nonce_length;
const message = "Test message";
const ad = "Associated data";

var ciphertext: [message.len]u8 = undefined;
var tag: [Aes256Gcm.tag_length]u8 = undefined;
var decrypted: [message.len]u8 = undefined;

// Encrypt
Aes256Gcm.encrypt(&ciphertext, &tag, message, ad, nonce, key);

// Decrypt  
try Aes256Gcm.decrypt(&decrypted, &ciphertext, tag, ad, nonce, key);
```

## 4) Dependencies

- `std.mem` - for memory operations and integer writing
- `std.math` - for block count calculations
- `std.crypto.core.modes` - for CTR mode implementation
- `std.crypto.onetimeauth.Ghash` - for GHASH authentication
- `std.crypto.core.aes` - for underlying AES encryption
- `std.crypto.timing_safe` - for constant-time tag comparison
- `std.debug` - for assertions

This is a self-contained cryptographic module with no external dependencies beyond the Zig standard library's crypto core components.