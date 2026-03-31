# Migration Card: Ristretto255

## 1) Concept

This file implements the Ristretto255 group operations, which provide a prime-order group abstraction over Edwards25519. Ristretto255 solves the cofactor issues of Edwards curves by defining a quotient group that eliminates the 8-torsion component, making it suitable for cryptographic protocols requiring a prime-order group.

Key components include:
- Encoding/decoding functions to convert between byte representations and group elements
- Elligator 2 mapping for uniform encoding of random strings to group elements
- Standard elliptic curve operations (point addition, doubling, scalar multiplication)
- Equivalence checking for group elements
- Rejection of identity elements and non-canonical encodings

## 2) The 0.11 vs 0.16 Diff

**No major API signature changes detected** - this file maintains consistent patterns:

- **No explicit allocator requirements**: All operations are purely computational with no dynamic memory allocation
- **No I/O interface changes**: The API works directly with byte arrays and field elements
- **Error handling consistency**: Uses specific error types from `std.crypto.errors` (NonCanonicalError, EncodingError, IdentityElementError, WeakPublicKeyError)
- **API structure stability**: Factory pattern using `fromBytes()` and `fromUniform()` with no init/open changes

The public API maintains the same structure as would be expected in 0.11:
- Static construction: `fromBytes()`, `fromUniform()`
- Instance methods: `toBytes()`, `dbl()`, `add()`, `sub()`, `mul()`, `equivalent()`
- Constant properties: `basePoint`, `encoded_length`

## 3) The Golden Snippet

```zig
const std = @import("std");
const Ristretto255 = std.crypto.25519.Ristretto255;

// Decode from bytes and perform operations
pub fn example() !void {
    const base = Ristretto255.basePoint;
    
    // Encode to bytes
    const encoded = base.toBytes();
    
    // Decode from bytes
    const decoded = try Ristretto255.fromBytes(encoded);
    
    // Scalar multiplication
    const scalar = [_]u8{15} ++ [_]u8{0} ** 31;
    const multiplied = try base.mul(scalar);
    
    // Verify equivalence
    const is_equivalent = base.equivalent(decoded);
}
```

## 4) Dependencies

- **`std.crypto.errors`** - Error types (EncodingError, IdentityElementError, NonCanonicalError, WeakPublicKeyError)
- **`std.crypto.25519.edwards25519`** - Underlying curve implementation via `Curve` type
- **`std.fmt`** - Formatting utilities (used in tests only)

The implementation is mathematically focused with minimal external dependencies, primarily relying on the underlying Edwards25519 curve implementation and cryptographic error definitions.