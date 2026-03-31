# Migration Card: std/crypto/pcurves/secp256k1/field.zig

## 1) Concept

This file defines the finite field arithmetic implementation for the secp256k1 elliptic curve used in Bitcoin and other cryptocurrencies. It creates a `Fe` (field element) type using a generic field constructor from the common crypto utilities. The field is configured with specific secp256k1 parameters including the field order (a 256-bit prime), bit sizes, and encoding length of 32 bytes. The actual field arithmetic operations are provided by the fiat-crypto generated implementation in `secp256k1_64.zig`.

## 2) The 0.11 vs 0.16 Diff

**No breaking API changes detected in this file.** The public API consists of:

- `Fe` type definition via `Field` constructor
- Compile-time configuration using struct literals
- No explicit allocator requirements (stack-based operations)
- No I/O interface dependencies
- No error handling changes visible at this abstraction level

The pattern follows Zig 0.16's preference for compile-time configuration and generic type construction. The `Field` function acts as a type factory that returns a complete field implementation type configured for secp256k1 parameters.

## 3) The Golden Snippet

```zig
const std = @import("std");
const secp256k1_field = @import("std/crypto/pcurves/secp256k1/field.zig");

pub fn main() void {
    // The Fe type represents a secp256k1 field element
    const Fe = secp256k1_field.Fe;
    
    // Field elements can be created and manipulated using the Fe type
    // (actual usage depends on methods provided by the Field implementation)
    std.debug.print("Field element type configured for secp256k1\n", .{});
}
```

## 4) Dependencies

- `std` - Standard library base
- `../common.zig` - Common cryptographic field utilities
- `secp256k1_64.zig` - Fiat-crypto generated 64-bit field arithmetic implementation

**Note:** This is a foundational cryptographic primitive - most usage will be through higher-level curve operations rather than direct field element manipulation.