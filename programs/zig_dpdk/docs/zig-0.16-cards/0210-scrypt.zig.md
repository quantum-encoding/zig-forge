# Migration Card: std/crypto/scrypt.zig

## 1) Concept

This file implements the scrypt password-based key derivation function (KDF) as defined in RFC 7914. It provides cryptographic password hashing functionality with configurable memory and CPU cost parameters. The implementation includes both raw KDF operations and higher-level password hashing interfaces that support two encoding formats: the modular crypt format (traditional Unix-style) and PHC format (modern password hashing competition format).

Key components include:
- `Params` struct for configuring scrypt parameters (N, r, p factors)
- `kdf()` function for raw key derivation
- `strHash()` and `strVerify()` for password hashing/verification
- Two format implementations: `PhcFormatHasher` and `CryptFormatHasher`

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **`kdf()`**: Now requires explicit `mem.Allocator` as first parameter
- **`strHash()`**: Requires allocator via `HashOptions.allocator` field
- **`strVerify()`**: Requires allocator via `VerifyOptions.allocator` field

### API Structure Changes
- **Factory pattern**: `strHash()` and `strVerify()` use options structs instead of direct parameters
- **Error handling**: Uses specific error types (`KdfError`, `HasherError`, `EncodingError`) rather than generic errors
- **Memory management**: All memory allocation is explicit through allocator parameters

### Function Signature Changes
```zig
// 0.16 pattern - explicit allocator requirements
pub fn kdf(
    allocator: mem.Allocator,           // NEW: explicit allocator
    derived_key: []u8,
    password: []const u8,
    salt: []const u8,
    params: Params,
) KdfError!void

pub fn strHash(
    password: []const u8,
    options: HashOptions,               // NEW: options struct with allocator
    out: []u8,
) Error![]const u8

pub fn strVerify(
    str: []const u8,
    password: []const u8,
    options: VerifyOptions,             // NEW: options struct with allocator
) Error!void
```

## 3) The Golden Snippet

```zig
const std = @import("std");
const scrypt = std.crypto.scrypt;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const password = "my_secure_password";
    
    // Hash a password
    var hash_buf: [128]u8 = undefined;
    const hash_str = try scrypt.strHash(
        password,
        .{
            .allocator = allocator,
            .params = scrypt.Params.interactive,
            .encoding = .phc,
        },
        &hash_buf,
    );
    
    // Verify the password
    try scrypt.strVerify(
        hash_str,
        password,
        .{ .allocator = allocator },
    );
    
    std.debug.print("Password hash: {s}\n", .{hash_str});
}
```

## 4) Dependencies

- **`std.mem`** - Memory allocation and manipulation
- **`std.crypto`** - Core cryptographic primitives
- **`std.math`** - Mathematical operations and constants
- **`std.fmt`** - Formatting utilities (for tests)
- **`std.meta`** - Type introspection
- **`phc_encoding.zig`** - PHC format encoding/decoding
- **`std.crypto.pwhash`** - Password hashing base functionality
- **`std.crypto.auth.hmac.sha2.HmacSha256`** - PBKDF2 implementation

The dependency graph shows this module builds on Zig's cryptographic foundations while providing specialized scrypt functionality with modern password hashing interfaces.