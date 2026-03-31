```markdown
# Migration Card: std/math/isnan.zig

## 1) Concept
This file provides NaN detection functions for floating-point types in Zig's standard library. It contains two public functions: `isNan` for general NaN detection and `isSignalNan` for detecting signaling NaNs (non-quiet NaNs). The implementation uses bit manipulation and type-generic programming to work across all floating-point types including f16, f32, f64, f80, f128, and c_longdouble.

Key components include basic NaN detection using the `x != x` identity property and signaling NaN detection by checking the quiet bit in the floating-point representation. The file includes comprehensive tests that verify behavior across different architectures and floating-point types.

## 2) The 0.11 vs 0.16 Diff

**No significant API signature changes detected.** Both functions maintain the same simple interface:

- `isNan(x: anytype) bool` - Takes any floating-point type, returns boolean
- `isSignalNan(x: anytype) bool` - Takes any floating-point type, returns boolean

**Key observations:**
- **No allocator dependencies** - These are pure mathematical functions
- **No I/O interfaces** - Functions operate solely on input parameters
- **Error handling unchanged** - Functions return simple boolean results, not error unions
- **API structure consistent** - Simple function calls without initialization patterns

**Bit manipulation updates:** The code uses newer Zig 0.16 bit operations:
- `@bitCast` instead of older bit-casting patterns
- `meta.Int(.unsigned, @bitSizeOf(T))` for type-safe unsigned integer creation

## 3) The Golden Snippet

```zig
const std = @import("std");
const math = std.math;

test "basic NaN detection" {
    const f: f32 = math.nan(f32);
    try std.testing.expect(math.isNan(f));
    try std.testing.expect(!math.isNan(@as(f32, 1.0)));
    
    const d: f64 = -math.nan(f64);
    try std.testing.expect(math.isNan(d));
}
```

## 4) Dependencies
- `std.math` - Core mathematical constants and functions
- `std.meta` - Type introspection and generic programming utilities  
- `std.testing` - Testing framework and assertions
- `builtin` - Compiler intrinsics and target platform information

**Primary dependency chain:** math → meta → testing → builtin
```

*Note: This file contains stable public mathematical functions that haven't undergone significant API changes between Zig 0.11 and 0.16. The migration impact is minimal, primarily involving updated standard library imports and bit manipulation syntax.*