# Migration Card for `std.fmt.parse_float.convert_slow.zig`

## 1) Concept

This file implements a fallback algorithm for precise floating-point number parsing. It handles the slow path of converting string representations to floating-point values, specifically designed to accurately process "near half-way cases" where values are exactly between two consecutive machine floats. The algorithm uses big-integer arithmetic to determine proper rounding according to round-nearest, tie-even rules.

Key components include the `getShift` helper function for power-of-10 shifting and the main `convertSlow` function that processes decimal digits through a series of left/right shifts and rounding operations to produce a biased floating-point representation.

## 2) The 0.11 vs 0.16 Diff

**Public API Changes:**
- `convertSlow(comptime T: type, s: []const u8) BiasedFp(T)`
  - Uses explicit type parameters with `comptime T: type`
  - Returns `BiasedFp(T)` struct directly rather than error union
  - No allocator parameter - operates entirely on stack
  - Pure computational function with no I/O dependencies

**Error Handling Pattern:**
- Returns structured `BiasedFp` with zero/infinity sentinel values instead of error unions
- Early returns for edge cases (empty input, out-of-range exponents)
- No error propagation - all error conditions handled internally

**Type Safety:**
- Extensive use of `@as()` for explicit type casting
- `@intCast` for safe integer conversions
- `@branchHint(.cold)` for optimization hints

## 3) The Golden Snippet

```zig
const std = @import("std");
const convert_slow = @import("std/fmt/parse_float/convert_slow.zig");

pub fn parseFloatSlow(comptime T: type, input: []const u8) void {
    const result = convert_slow.convertSlow(T, input);
    // result is a BiasedFp(T) containing .f (mantissa) and .e (exponent)
    std.debug.print("Mantissa: {}, Exponent: {}\n", .{result.f, result.e});
}

// Usage example:
parseFloatSlow(f64, "123.456");
```

## 4) Dependencies

- `std.math` - Used for floating-point type properties (`floatExponentBits`, `floatFractionalBits`, `floatMantissaBits`)
- Local modules:
  - `common.zig` - Provides `BiasedFp` type and `mantissaType`
  - `decimal.zig` - Provides `Decimal` type for big-integer decimal arithmetic

This is a computational utility with no external I/O dependencies, making it suitable for constrained environments.