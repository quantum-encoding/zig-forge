# Migration Analysis: `std/math/ldexp.zig`

## 1) Concept

This file implements the `ldexp` (load exponent) function for floating-point types in Zig's standard library. The `ldexp` function multiplies a floating-point number `x` by 2 raised to the power `n` (x × 2ⁿ), which is equivalent to efficiently scaling a floating-point value by a power of two.

The implementation handles various edge cases including:
- Special values (NaN, infinity)
- Normal and subnormal number ranges
- Overflow and underflow conditions
- Different floating-point types (f16, f32, f64, f80, f128)
- Rounding behavior for exact ties

## 2) The 0.11 vs 0.16 Diff

**No significant API migration changes detected.** This is a pure mathematical utility function with stable interface:

- **Function signature stability**: `pub fn ldexp(x: anytype, n: i32) @TypeOf(x)` remains consistent
- **No allocator requirements**: Pure computational function, no memory allocation
- **No I/O interfaces**: Mathematical computation only, no file/network operations
- **Error handling**: Uses standard floating-point semantics (NaN, infinity) rather than Zig error types
- **API structure**: Simple function call pattern unchanged

The implementation uses Zig 0.16 features like:
- `@TypeOf()` for generic type handling
- `@bitCast` for type-punning operations
- `@intCast` for explicit integer conversions
- `std.meta.Int` for type-safe bit manipulation

## 3) The Golden Snippet

```zig
const std = @import("std");
const math = std.math;

// Multiply 1.5 by 2^4 (16) to get 24.0
const result = math.ldexp(@as(f64, 1.5), 4);
// result == 24.0

// Handle edge cases like subnormal numbers
const min_value = math.ldexp(math.floatTrueMin(f32), 0);
// min_value > 0.0 (smallest positive denormal)

// Overflow to infinity
const overflow = math.ldexp(math.floatMax(f32), std.math.maxInt(i32));
// overflow == math.inf(f32)
```

## 4) Dependencies

- **`std.math`** - Core mathematical constants and utilities
- **`std.meta`** - Type introspection and generic programming
- **`std.debug`** - Assertion support (testing only)
- **`std.testing`** - Test framework (testing only)

**Primary dependencies for migration:** `std.math`, `std.meta`

This file represents a stable mathematical utility with no breaking API changes between Zig 0.11 and 0.16. The migration impact is minimal - developers can continue using the same function signature and patterns.