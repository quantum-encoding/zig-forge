# Migration Card: P256 Scalar Operations

## 1) Concept

This file implements scalar operations for the P256 elliptic curve, providing arithmetic operations in the scalar field of the curve. It handles operations like addition, multiplication, and inversion modulo the curve's scalar field order. The key components include:

- `CompressedScalar`: A 32-byte array representing a scalar in canonical compressed form
- `Scalar`: An unpacked representation of a scalar with full arithmetic operations
- Various utility functions for scalar reduction, arithmetic operations, and validation

The implementation provides both compressed operations (working directly with byte arrays) and unpacked operations (working with the internal field element representation), supporting both big and little endian encodings.

## 2) The 0.11 vs 0.16 Diff

**No major API signature changes requiring migration** were found in this file. The analysis reveals:

- **No explicit allocator requirements**: All operations are purely computational and don't require memory allocation
- **No I/O interface changes**: The API doesn't involve I/O operations
- **Consistent error handling**: Uses specific error types (`NonCanonicalError`, `NotSquareError`) consistently
- **Stable API structure**: Functions maintain consistent naming and parameter patterns

The key migration patterns observed in Zig 0.16 (explicit allocators, dependency injection) are not applicable to this cryptographic primitive implementation, which remains allocation-free and uses direct mathematical operations.

## 3) The Golden Snippet

```zig
const std = @import("std");
const scalar = std.crypto.pcurves.p256.scalar;

pub fn example() !void {
    const endian = .little;
    
    // Generate a random scalar
    const random_scalar = scalar.random(endian);
    
    // Perform scalar multiplication
    const a: scalar.CompressedScalar = [32]u8{0x01} ** 32;
    const b: scalar.CompressedScalar = [32]u8{0x02} ** 32;
    const product = try scalar.mul(a, b, endian);
    
    // Verify canonical encoding
    try scalar.rejectNonCanonical(product, endian);
    
    // Work with unpacked representation
    const unpacked = try scalar.Scalar.fromBytes(product, endian);
    const doubled = scalar.Scalar.dbl(unpacked);
    const result_bytes = scalar.Scalar.toBytes(doubled, endian);
}
```

## 4) Dependencies

- `std.crypto` - Core cryptographic utilities and random number generation
- `std.debug` - Debug assertions and runtime checks
- `std.math` - Mathematical operations and constants
- `std.mem` - Memory operations and byte manipulation
- `../common.zig` - Shared field arithmetic implementation

**Note**: This is a pure computational module with no external I/O dependencies, making it highly portable and suitable for constrained environments.