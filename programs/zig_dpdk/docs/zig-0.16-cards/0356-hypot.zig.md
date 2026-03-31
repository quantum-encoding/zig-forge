# Migration Card: std/math/hypot.zig

## 1) Concept
This file implements the `hypot` function for computing the Euclidean distance (√(x² + y²)) in a numerically stable manner. The implementation handles special cases like infinities and NaNs, avoids overflow/underflow through scaling techniques, and provides different algorithms (fused vs unfused) depending on the floating-point type capabilities. Key components include the main `hypot` function with type polymorphism, helper functions for fused/unfused calculations, and comprehensive test coverage across different floating-point types.

The implementation is mathematically sophisticated, using scaling factors and different algorithms based on the input magnitude and floating-point type characteristics. It handles edge cases like infinity and NaN inputs according to IEEE standards and provides precision-optimized paths for different floating-point widths.

## 2) The 0.11 vs 0.16 Diff
This file contains a pure mathematical function with no breaking API changes between Zig 0.11 and 0.16 patterns:

- **No allocator requirements**: This is a pure computational function that doesn't require memory allocation
- **No I/O interface changes**: The function operates solely on numeric inputs
- **No error handling changes**: Returns normal numeric results or special float values (inf/nan) rather than error sets
- **API structure unchanged**: Simple function call pattern remains consistent

The function signature `hypot(x: anytype, y: anytype) @TypeOf(x, y)` uses Zig's generic type system which has remained stable. The implementation relies on builtin functions like `@mulAdd`, `@sqrt`, and `@abs` that are core language features.

## 3) The Golden Snippet
```zig
const std = @import("std");
const math = std.math;

test "basic hypot usage" {
    // Compute Euclidean distance between two points
    const distance = math.hypot(3.0, 4.0);
    try std.testing.expect(distance == 5.0);
    
    // Handles special cases automatically
    const inf_result = math.hypot(math.inf(f64), 5.0);
    try std.testing.expect(math.isPositiveInf(inf_result));
}
```

## 4) Dependencies
- `std.math` - Core mathematical constants and functions (isNan, isInf, inf, nan, floatEpsAt, etc.)
- `std.testing` - Testing framework utilities (only in test blocks)

The implementation is self-contained within the math module and doesn't require external dependencies beyond basic floating-point operations and mathematical constants.