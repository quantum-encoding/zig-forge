# Migration Card: FloatInfo.zig

## 1) Concept

This file defines a compile-time configuration structure `FloatInfo` that contains floating-point type metadata used by the float parsing algorithms in Zig's standard library. It provides type-specific constants for various floating-point formats (f16, f32, f64, f80, f128) including fast-path exponent ranges, mantissa sizes, power-of-ten bounds, and rounding parameters. The structure is used internally by the float parsing infrastructure to determine optimal parsing strategies (fast-path vs Eisel-Lemire algorithm) based on the specific characteristics of each floating-point type.

## 2) The 0.11 vs 0.16 Diff

**No significant public API migration changes detected.** This file contains a compile-time factory function that follows consistent patterns between Zig 0.11 and 0.16:

- **Factory Pattern**: The `from` function uses a compile-time switch to return pre-computed struct instances, which is compatible with both versions
- **No Allocator Changes**: No memory allocation is required as all values are compile-time constants
- **No I/O Interface Changes**: This is purely a mathematical configuration structure without I/O dependencies
- **Error Handling**: Uses `unreachable` for unsupported types, consistent with both versions
- **API Structure**: Simple factory function pattern that hasn't changed between versions

## 3) The Golden Snippet

```zig
const std = @import("std");

// Get float configuration for f32 type
const f32_info = std.fmt.parse_float.FloatInfo.from(f32);

// Access configuration values
const min_exp_fast = f32_info.min_exponent_fast_path;
const max_exp_fast = f32_info.max_exponent_fast_path;
const mantissa_bits = f32_info.mantissa_explicit_bits;
```

## 4) Dependencies

- `std` (base import)
- `std.math` (used for `floatMantissaBits` and `floatFractionalBits`)

This is a low-level mathematical configuration file with minimal dependencies, primarily relying on `std.math` for floating-point type information.