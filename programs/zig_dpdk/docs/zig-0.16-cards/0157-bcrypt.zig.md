# Migration Card: std/crypto/bcrypt.zig

## 1) Concept

This file implements the bcrypt password hashing algorithm and related key derivation functions for Zig's standard crypto library. It provides secure password storage and verification capabilities through multiple interfaces:

- Core bcrypt password hashing with configurable cost parameters
- Two key derivation functions: `pbkdf` (bcrypt-pbkdf) and `opensshKdf` (OpenSSH-compatible)
- Dual encoding support: traditional modular crypt format and modern PHC format
- Automatic password truncation handling with configurable behavior

Key components include the `State` struct implementing the Blowfish cipher core, `Params` for bcrypt configuration, and two format-specific hasher implementations (`PhcFormatHasher` and `CryptFormatHasher`).

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **No allocator dependency**: The public API functions (`strHash`, `strVerify`, `pbkdf`, `opensshKdf`) don't require allocators, even when provided in options
- **Buffer-based output**: All functions accept pre-allocated output buffers rather than allocating internally

### API Structure Changes
- **Structured configuration**: Uses `HashOptions` and `VerifyOptions` structs instead of individual parameters
- **Encoding selection**: Explicit encoding choice (.phc vs .crypt) in `HashOptions`
- **Factory pattern**: `strHash`/`strVerify` as primary interface rather than direct bcrypt calls

### Error Handling
- **Specific error types**: Returns `pwhash.Error` which includes verification failures and encoding errors
- **No generic error sets**: Well-defined error cases for password verification and format parsing

### Key Public API Changes
```zig
// 0.16 pattern - structured options, buffer output
pub fn strHash(password: []const u8, options: HashOptions, out: []u8) Error![]const u8
pub fn strVerify(str: []const u8, password: []const u8, options: VerifyOptions) Error!void
```

## 3) The Golden Snippet

```zig
const std = @import("std");
const bcrypt = std.crypto.bcrypt;

test "bcrypt password hashing example" {
    // Hash a password
    var hash_buf: [bcrypt.hash_length]u8 = undefined;
    const hash = try bcrypt.strHash("my password", .{
        .params = .{ 
            .rounds_log = 5, 
            .silently_truncate_password = false 
        },
        .encoding = .crypt,
    }, &hash_buf);

    // Verify the password
    try bcrypt.strVerify(hash, "my password", .{
        .silently_truncate_password = false
    });

    // If the password is wrong, it should fail
    try std.testing.expectError(
        error.PasswordVerificationFailed,
        bcrypt.strVerify(hash, "wrong password", .{
            .silently_truncate_password = false
        })
    );
}
```

## 4) Dependencies

**Heavy Dependencies:**
- `std.mem` - memory operations, zeroing, comparisons
- `std.crypto` - core crypto primitives, random bytes, secureZero
- `std.base64` - custom bcrypt base64 encoding/decoding
- `std.fmt` - string formatting for hash output

**Crypto-specific:**
- `std.crypto.pwhash` - password hashing interface and error types
- `std.crypto.auth.hmac.sha2.HmacSha512` - pre-hashing for long passwords
- `std.crypto.hash.sha2.Sha512` - SHA-512 for key derivation

**Supporting:**
- `std.math` - mathematical operations
- `std.debug` - assertions
- `phc_encoding.zig` - PHC format serialization/deserialization