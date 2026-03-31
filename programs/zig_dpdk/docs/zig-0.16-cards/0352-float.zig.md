# Migration Card: std/math/float.zig

## 1) Concept
This file provides low-level floating-point type utilities and constants for Zig's standard library. It contains functions for querying floating-point type properties (exponent bits, mantissa bits, etc.), generating special floating-point values (infinity, NaN), and working with the internal representation of floating-point numbers through the `FloatRepr` type.

Key components include:
- `FloatRepr` type that decomposes floats into sign, exponent, and mantissa components
- Functions to query floating-point type characteristics (`floatExponentBits`, `floatMantissaBits`, etc.)
- Functions to generate special values (`inf`, `nan`, `snan`)
- Constants for floating-point limits (`floatTrueMin`, `floatMax`, `floatEps`, etc.)

## 2) The 0.11 vs 0.16 Diff
This file contains mostly mathematical utilities and type queries that follow consistent patterns across Zig versions. Key observations:

**No Allocator Requirements**: All functions are pure mathematical operations or type queries that don't require memory allocation.

**No I/O Interface Changes**: This is a mathematical utility module with no I/O operations.

**Error Handling**: No error handling changes observed - functions either return values directly or use compile-time assertions.

**API Structure**: The API patterns remain consistent:
- Type queries use `comptime T: type` parameters
- Special value generators (`inf`, `nan`, `snan`) maintain the same signature
- Mathematical constants are computed at compile-time

**Notable Stability**: The public API consists mainly of mathematical constants and type queries, which are inherently stable across Zig versions.

## 3) The Golden Snippet
```zig
const std = @import("std");
const math = std.math;

test "floating point constants" {
    // Get floating point type properties
    const exponent_bits = math.float.floatExponentBits(f32);
    const mantissa_bits = math.float.floatMantissaBits(f32);
    
    // Generate special values
    const inf_val = math.float.inf(f32);
    const nan_val = math.float.nan(f32);
    const snan_val = math.float.snan(f32);
    
    // Get numerical limits
    const min_val = math.float.floatMin(f32);
    const max_val = math.float.floatMax(f32);
    const eps = math.float.floatEps(f32);
    
    try std.testing.expect(exponent_bits == 8);
    try std.testing.expect(mantissa_bits == 23);
    try std.testing.expect(math.isInf(inf_val));
    try std.testing.expect(math.isNan(nan_val));
}
```

## 4) Dependencies
- `std` (root import)
- `builtin` (for compile-time target information)
- `std.debug` (for assertions)
- `std.testing` (for test expectations)
- `std.math` (for Sign enum and math operations)

This file has minimal dependencies and focuses purely on floating-point mathematics without external system dependencies.