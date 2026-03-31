# Migration Card: P384 Scalar Field Operations

## 1) Concept

This file implements arithmetic operations in the scalar field of the P384 elliptic curve. The scalar field represents integers modulo the curve order, which is used for elliptic curve point multiplication and other cryptographic operations. The module provides two main representations: `CompressedScalar` (48-byte canonical encoding) and `Scalar` (unpacked internal representation), with conversion functions between them and arithmetic operations like addition, multiplication, and inversion.

Key components include:
- `CompressedScalar`: Canonical byte representation of scalars
- `Scalar`: Unpacked representation for efficient arithmetic operations
- Arithmetic operations: add, sub, mul, neg, invert, sqrt, etc.
- Serialization/deserialization with endianness support

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements**: No allocator dependencies found in this cryptographic primitive module. All operations are purely mathematical and work with fixed-size arrays.

**I/O Interface Changes**: The API consistently uses explicit endianness parameters (`std.builtin.Endian`) throughout all serialization/deserialization functions, rather than relying on default endianness.

**Error Handling Changes**: Uses specific error types from `std.crypto.errors`:
- `NonCanonicalError` for invalid scalar encodings
- `NotSquareError` for square root operations on non-quadratic residues

**API Structure Changes**: 
- Factory pattern: `Scalar.fromBytes()` returns error union vs direct construction
- Consistent endianness parameter in all public functions
- Mathematical operations return new `Scalar` instances rather than modifying in-place

**Changed Function Signatures**:
- All arithmetic functions (`mul`, `add`, `sub`, `neg`) now require explicit `endian` parameter
- `fromBytes()` returns `NonCanonicalError!Scalar` instead of assuming valid input
- `sqrt()` returns `NotSquareError!Scalar` instead of optional

## 3) The Golden Snippet

```zig
const std = @import("std");
const p384_scalar = @import("std/crypto/pcurves/p384/scalar.zig");

pub fn example() !void {
    const endian = std.builtin.Endian.little;
    
    // Create random scalars
    const a = p384_scalar.random(endian);
    const b = p384_scalar.random(endian);
    
    // Perform scalar multiplication
    const product = try p384_scalar.mul(a, b, endian);
    
    // Unpack to Scalar type for advanced operations
    const scalar_a = try p384_scalar.Scalar.fromBytes(a, endian);
    const scalar_b = try p384_scalar.Scalar.fromBytes(b, endian);
    
    // Compute inverse
    const inv_a = scalar_a.invert();
    const inv_bytes = inv_a.toBytes(endian);
}
```

## 4) Dependencies

- `std.crypto` - Core cryptographic primitives and random number generation
- `std.crypto.errors` - Specific error types (NonCanonicalError, NotSquareError)
- `std.math` - Mathematical utilities
- `std.mem` - Memory operations
- `std.debug` - Debug assertions
- `../common.zig` - Shared field arithmetic implementation
- `p384_scalar_64.zig` - FIAT-generated field arithmetic backend