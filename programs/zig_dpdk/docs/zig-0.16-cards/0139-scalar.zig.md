# Migration Card: std/crypto/25519/scalar.zig

## 1) Concept

This file implements scalar arithmetic operations for the Curve25519 elliptic curve cryptography system. It provides essential mathematical operations for working with scalars in the Ed25519 signature scheme and X25519 key exchange protocol. The module handles scalar field operations including reduction, multiplication, addition, subtraction, negation, and inversion modulo the curve's field order.

Key components include:
- `CompressedScalar`: A 32-byte compressed scalar representation
- `Scalar`: An unpacked representation using 5 u64 limbs for arithmetic operations
- `ScalarDouble`: Internal double-precision representation for intermediate calculations
- Core operations: reduce, clamp, mul, add, sub, neg, invert, and random scalar generation

## 2) The 0.11 vs 0.16 Diff

This module shows minimal migration impact from Zig 0.11 to 0.16 patterns:

**No Explicit Allocator Requirements**: All functions operate on stack-allocated fixed-size arrays (`[32]u8`, `[64]u8`) and do not require memory allocators.

**No I/O Interface Changes**: The module is purely computational with no I/O dependencies.

**Error Handling Changes**: Uses specific error type `NonCanonicalError` rather than generic errors:
```zig
// 0.16 pattern - specific error type
pub fn rejectNonCanonical(s: CompressedScalar) NonCanonicalError!void
```

**API Structure Consistency**: Maintains consistent patterns:
- Factory functions: `Scalar.fromBytes()`, `Scalar.fromBytes64()`
- Conversion methods: `scalar.toBytes()`
- Pure functional style: operations return new values rather than modifying in-place

**Type Safety Improvements**: Uses explicit integer casting with `@intCast` and `@truncate` for better type safety.

## 3) The Golden Snippet

```zig
const std = @import("std");
const scalar25519 = std.crypto.scalar.25519;

pub fn main() !void {
    // Create two random scalars
    const a = scalar25519.random();
    const b = scalar25519.random();
    
    // Perform scalar multiplication (mod L)
    const product = scalar25519.mul(a, b);
    
    // Verify the result is canonical
    try scalar25519.rejectNonCanonical(product);
    
    // Use X25519 clamping for key exchange
    var clamped = product;
    scalar25519.clamp(&clamped);
    
    std.debug.print("Clamped scalar: {x}\n", .{std.fmt.fmtSliceHexLower(&clamped)});
}
```

## 4) Dependencies

- `std.mem` - For memory operations and integer serialization
- `std.crypto` - For random number generation
- `std.crypto.errors` - For specific error types (NonCanonicalError)

The module has minimal external dependencies and focuses on pure mathematical operations, making it stable across Zig versions with low migration impact.