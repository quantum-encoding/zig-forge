# Migration Analysis: `std/crypto/pcurves/secp256k1/scalar.zig`

## 1) Concept

This file implements scalar arithmetic operations for the secp256k1 elliptic curve, which is used in cryptographic applications like Bitcoin and Ethereum. It provides two main representations of scalars:
- **CompressedScalar**: A 32-byte canonical encoding suitable for storage/transmission
- **Scalar**: An unpacked internal representation for mathematical operations

Key components include modular arithmetic operations (add, subtract, multiply, negate), scalar reduction from larger inputs (48/64 bytes), random scalar generation, and square root operations. The implementation uses field arithmetic backed by FIAT-generated code for constant-time operations.

## 2) The 0.11 vs 0.16 Diff

**Error Handling Changes:**
- Explicit error types: `NonCanonicalError` and `NotSquareError` replace generic error sets
- Functions like `mul()`, `add()`, `sub()` now return `NonCanonicalError!CompressedScalar` instead of generic error unions

**API Structure Changes:**
- **Endianness injection**: All public functions now require explicit `endian: std.builtin.Endian` parameter
- **No allocator dependencies**: All operations are purely computational with no memory allocation
- **Factory pattern**: `Scalar.fromBytes()` returns error union, requiring explicit error handling
- **Functional API**: Operations on `CompressedScalar` return new values rather than modifying in-place

**Function Signature Migrations:**
- `mul(a, b)` → `mul(a, b, endian)`
- `add(a, b)` → `add(a, b, endian)`  
- `fromBytes(s)` → `fromBytes(s, endian)`
- All operations now return error unions for canonical form validation

## 3) The Golden Snippet

```zig
const std = @import("std");
const scalar = std.crypto.pcurves.secp256k1.scalar;

pub fn main() !void {
    const endian = .little;
    
    // Generate random scalars
    const a = scalar.random(endian);
    const b = scalar.random(endian);
    
    // Multiply scalars with error handling
    const product = try scalar.mul(a, b, endian);
    
    // Unpack and verify result
    const unpacked = try scalar.Scalar.fromBytes(product, endian);
    std.debug.print("Scalar product computed successfully: {}\n", .{!unpacked.isZero()});
}
```

## 4) Dependencies

- `std.mem` - Memory operations and byte manipulation
- `std.math` - Mathematical utilities
- `std.debug` - Debug assertions and runtime checks
- `std.crypto` - Cryptographic primitives and random number generation
- `std.crypto.errors` - Specific error types for cryptographic operations
- Internal: `../common.zig` - Shared field arithmetic implementation
- Internal: `secp256k1_scalar_64.zig` - FIAT-generated field operations