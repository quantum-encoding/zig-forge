# Migration Card: std/math/ilogb.zig

## 1) Concept
This file implements integer logarithm base 2 functions (`ilogb`) for floating-point types in Zig's standard library. The functions return the binary exponent of a floating-point number as an integer value. The implementation is ported from musl libc and handles special cases including infinity, zero, and NaN values according to IEEE 754 standards.

Key components include a public `ilogb` function that dispatches to type-specific implementations, constants for special case return values (`fp_ilogbnan` and `fp_ilogb0`), and comprehensive test coverage for all floating-point types (f16, f32, f64, f80, f128).

## 2) The 0.11 vs 0.16 Diff
**No significant API changes detected** for this mathematical utility function. The public interface remains stable:

- **Function Signature**: `pub fn ilogb(x: anytype) i32` - Uses Zig's generic type system with `anytype`
- **No Allocator Requirements**: Pure mathematical computation without memory allocation
- **No I/O Changes**: No file or stream operations involved
- **Error Handling**: Uses `math.raiseInvalid()` for floating-point exceptions internally, but doesn't expose error types
- **API Structure**: Simple functional API without init/open patterns

The function maintains the same calling pattern across versions - it's a pure mathematical operation that takes a floating-point value and returns an integer exponent.

## 3) The Golden Snippet
```zig
const std = @import("std");
const math = std.math;

// Calculate binary exponent of floating-point numbers
const exp1 = math.ilogb(@as(f32, 10.0));        // Returns: 3
const exp2 = math.ilogb(@as(f64, 0.5));         // Returns: -1
const exp3 = math.ilogb(@as(f16, 2398.23));     // Returns: 11

// Handle special cases
const inf_exp = math.ilogb(math.inf(f32));      // Returns: maxInt(i32)
const zero_exp = math.ilogb(@as(f64, 0.0));     // Returns: minInt(i32)
const nan_exp = math.ilogb(math.nan(f64));      // Returns: minInt(i32)
```

## 4) Dependencies
- `std.math` - Core mathematical functions and constants
- `std.meta` - Used for type introspection with `std.meta.Int`
- `std.testing` - Test framework (test-only dependency)

**Note**: This is a stable mathematical utility with minimal dependencies and no breaking API changes between Zig 0.11 and 0.16.