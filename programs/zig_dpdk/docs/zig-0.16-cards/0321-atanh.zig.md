# Migration Card: std/math/atanh.zig

## 1) Concept

This file implements the inverse hyperbolic tangent (atanh) mathematical function for Zig's standard library. It provides a generic `atanh` function that works with both `f32` and `f64` floating-point types, with separate optimized implementations for each type (`atanh_32` and `atanh_64`). The code is ported from musl libc and handles special cases according to IEEE 754 standards, including proper handling of ±1, NaN values, and out-of-range inputs.

Key components include:
- Public generic `atanh` function that dispatches to type-specific implementations
- Private `atanh_32` and `atanh_64` functions implementing the core algorithm
- Comprehensive test coverage including normal values and edge cases

## 2) The 0.11 vs 0.16 Diff

**No significant API migration changes detected.** This mathematical utility function maintains a stable interface:

- **No allocator requirements**: Pure mathematical computation with no memory allocation
- **No I/O interface changes**: No file or network operations
- **No error handling changes**: Function returns mathematical results directly, no error sets
- **API structure unchanged**: Simple function call pattern remains consistent

The function signature `pub fn atanh(x: anytype) @TypeOf(x)` follows the same pattern that would have been used in Zig 0.11 - a generic mathematical function that preserves the input type.

## 3) The Golden Snippet

```zig
const std = @import("std");
const math = std.math;

test "basic atanh usage" {
    const result = math.atanh(@as(f32, 0.5));
    // result is approximately 0.54930615
}
```

## 4) Dependencies

- `std.math` (for mathematical constants and utilities: `copysign`, `inf`, `log1p`, `isNan`)
- `std.mem` (for `doNotOptimizeAway` compiler optimization barrier)
- `std.testing` (for test assertions: `expect`)

**Note**: This file represents a stable mathematical utility with no breaking API changes between Zig 0.11 and 0.16. The implementation uses low-level bit manipulation and mathematical algorithms that remain consistent across Zig versions.