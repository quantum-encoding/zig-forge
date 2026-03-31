# Migration Analysis: `std/crypto/pcurves/common.zig`

## 1) Concept

This file implements a generic finite field arithmetic module for elliptic curve cryptography in Zig. It provides a type constructor `Field` that creates field element types parameterized by cryptographic field parameters (order, bit size, etc.). The implementation uses Montgomery representation for efficient modular arithmetic and includes comprehensive field operations including addition, multiplication, inversion, square roots, and serialization/deserialization with canonical encoding validation.

Key components include:
- `FieldParams` struct defining field characteristics
- `Field()` type constructor returning a complete field arithmetic implementation
- Montgomery domain arithmetic operations via external `fiat` crypto primitives
- Endian-aware serialization with canonical encoding checks
- Specialized implementations for common cryptographic fields (P-256, P-384, secp256k1)

## 2) The 0.11 vs 0.16 Diff

**No breaking API changes identified** for this cryptographic field implementation:

- **No Allocator Requirements**: All operations are pure computations without heap allocation
- **No I/O Interface Changes**: Serialization uses direct byte arrays, no stream interfaces
- **Error Handling Consistency**: Uses specific error types (`NonCanonicalError`, `NotSquareError`) consistently
- **API Structure**: Factory pattern (`fromBytes`, `fromInt`) remains unchanged from 0.11 patterns

The API maintains functional purity with value semantics - all operations take and return field elements by value, making it allocation-free and compatible with Zig's evolving memory management patterns.

## 3) The Golden Snippet

```zig
const std = @import("std");
const common = std.crypto.pcurves.common;

// Assuming we have field parameters for a specific curve
const MyFieldParams = common.FieldParams{
    .fiat = my_fiat_type,           // External crypto primitives
    .field_order = 0xFFFFFFFF...,   // Field modulus
    .field_bits = 256,
    .saturated_bits = 256, 
    .encoded_length = 32,
};

const MyField = common.Field(MyFieldParams);

// Usage example
pub fn example() !void {
    // Deserialize from bytes with canonical encoding check
    const bytes = [_]u8{0x01} ++ [_]u8{0} ** 31;
    const a = try MyField.fromBytes(bytes, .little);
    
    // Field arithmetic
    const b = MyField.one;
    const c = a.add(b);
    const d = c.mul(a);
    
    // Check properties
    const is_square = d.isSquare();
    const is_zero = a.isZero();
    
    // Serialize back to bytes
    const output = d.toBytes(.little);
}
```

## 4) Dependencies

- `std.mem` - Zero initialization, byte order operations, memory comparison
- `std.meta` - Type introspection and integer type construction
- `std.crypto` - Timing-safe comparisons and error types
- `std.debug` - Debug utilities (minimal usage)

**Migration Impact: LOW** - This is a stable, mathematical API with no allocator dependencies or I/O interfaces that would be affected by Zig 0.16 changes.