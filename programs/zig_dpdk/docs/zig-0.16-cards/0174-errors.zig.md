# Migration Card: `std/crypto/errors.zig`

## 1) Concept

This file defines a comprehensive set of error types for cryptographic operations in Zig's standard library. It serves as a centralized error definition module for the crypto package, providing specific error types for various cryptographic failure scenarios. The file exports 14 distinct error sets, each representing a specific cryptographic error condition, and combines them into a single `Error` union type that encompasses all possible crypto-related errors.

Key components include individual error sets for authentication failures, output length violations, identity element issues, encoding problems, signature verification failures, and various security-related errors. The `Error` type acts as a catch-all union that developers can use to handle any crypto error scenario.

## 2) The 0.11 vs 0.16 Diff

This file contains only error type definitions with no functional changes between versions. The error definition patterns shown are consistent across Zig 0.11 and 0.16:

- **Error Type Definitions**: All errors use the standard Zig error set syntax (`error{ErrorName}`) which remains unchanged
- **Error Union Pattern**: The final `Error` type uses the `||` union operator to combine all specific error sets, a pattern that works identically in both versions
- **No Allocator Changes**: No allocator parameters or memory management concerns
- **No I/O Interface Changes**: Pure error type definitions without I/O operations
- **No API Structure Changes**: Simple type definitions without functions or complex APIs

The migration impact is minimal - these error definitions are forward-compatible and require no changes when migrating from 0.11 to 0.16.

## 3) The Golden Snippet

```zig
const std = @import("std");
const crypto_errors = std.crypto.errors;

// Function that may return crypto errors
fn verify_signature(public_key: []const u8, signature: []const u8, message: []const u8) crypto_errors.Error!void {
    // Simulate signature verification failure
    return crypto_errors.SignatureVerificationError.SignatureVerificationFailed;
}

// Usage pattern
pub fn main() void {
    const result = verify_signature("pub_key", "sig", "msg");
    if (result) |_| {
        std.debug.print("Signature verified\n", .{});
    } else |err| switch (err) {
        crypto_errors.SignatureVerificationError.SignatureVerificationFailed => {
            std.debug.print("Invalid signature\n", .{});
        },
        // Handle other crypto errors as needed
        else => unreachable,
    }
}
```

## 4) Dependencies

This file has **no imports** - it's a self-contained error definition module that only uses Zig's built-in language features. The absence of dependencies makes it highly portable and stable across Zig versions.

The crypto errors module serves as a foundational dependency for other crypto components rather than depending on other modules itself.