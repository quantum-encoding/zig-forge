# Migration Card: `std/math/iszero.zig`

## 1) Concept
This file provides utility functions for detecting positive and negative zero values in floating-point numbers. It contains two public functions that use bit-level operations to distinguish between regular floating-point values and the special cases of positive/negative zero. The implementation works by casting floating-point values to their unsigned integer representations and comparing against known bit patterns for zero values.

Key components:
- `isPositiveZero()` - detects positive zero (0.0)
- `isNegativeZero()` - detects negative zero (-0.0)
- Comprehensive test coverage for all major floating-point types (f16, f32, f64, f80, f128)

## 2) The 0.11 vs 0.16 Diff

**No Breaking Changes Identified**

This file contains pure mathematical utility functions with stable APIs:

- **No allocator dependencies**: Functions are pure computations without memory allocation
- **No I/O interface changes**: No file/stream operations present
- **No error handling changes**: Functions return simple boolean results
- **API structure unchanged**: Function signatures remain simple and consistent

The functions use generic type parameters (`anytype`) and bit manipulation patterns that have remained stable across Zig versions. The testing approach using `inline for` over type lists is also consistent.

## 3) The Golden Snippet

```zig
const std = @import("std");
const math = std.math;

pub fn main() void {
    const x: f32 = 0.0;
    const y: f32 = -0.0;
    
    std.debug.print("x is positive zero: {}\n", .{math.isPositiveZero(x)});
    std.debug.print("y is negative zero: {}\n", .{math.isNegativeZero(y)});
    
    // Output:
    // x is positive zero: true
    // y is negative zero: true
}
```

## 4) Dependencies

- `std` (root import)
- `std.math` (for mathematical constants in tests)
- `std.testing` (for test assertions)
- `std.meta` (implicitly for type introspection via `@typeInfo`)

**Migration Impact: LOW** - No migration changes required. This is a stable utility module.