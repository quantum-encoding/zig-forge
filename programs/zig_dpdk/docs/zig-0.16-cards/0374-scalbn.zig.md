# Migration Card: std/math/scalbn.zig

## 1) Concept
This file implements the `scalbn` function for scaling floating-point numbers by powers of the radix. It's a mathematical utility function that operates on IEEE-754 floating-point types. The key insight is that Zig only supports binary base IEEE-754 floats (FLT_RADIX=2), making `scalbn` functionally equivalent to `ldexp`. The implementation is minimal - it simply re-exports the `ldexp` function from another module.

The file contains a single public API (`scalbn`) and corresponding tests that verify the function works correctly across all supported floating-point types (f16, f32, f64, f128).

## 2) The 0.11 vs 0.16 Diff
**No migration changes detected for this specific API.** The function signature and usage pattern remain identical between Zig 0.11 and 0.16:

- **No allocator requirements**: This is a pure mathematical function that doesn't require memory allocation
- **No I/O interface changes**: The function operates solely on numeric inputs/outputs
- **No error handling changes**: The function doesn't return error unions
- **API structure unchanged**: Simple function call pattern remains the same

The function maintains the same signature: `scalbn(x: T, exp: comptime_int) -> T` where T is any floating-point type.

## 3) The Golden Snippet
```zig
const std = @import("std");
const math = std.math;

test "scalbn usage" {
    // Scale 1.5 by 2^4 (16) to get 24.0
    try std.testing.expect(math.scalbn(@as(f64, 1.5), 4) == 24.0);
}
```

## 4) Dependencies
- `std` - Base standard library import
- `std.testing` - Testing utilities (test-only dependency)

**Note**: This file has minimal dependencies as it's a mathematical primitive that delegates implementation to `ldexp.zig`.