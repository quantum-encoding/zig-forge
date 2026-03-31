# Migration Card: std/math/complex/ldexp.zig

## 1) Concept

This file implements complex exponential functions with scaling to avoid overflow, ported from musl libc. It provides `ldexp_cexp` which computes exp(z) scaled by 2^expt to prevent overflow in intermediate calculations. The implementation handles both 32-bit and 64-bit floating point types through type switching and uses bit manipulation for precise scaling control.

Key components include the main public function `ldexp_cexp` and helper functions `frexp_exp32/frexp_exp64` that handle the exponent extraction and scaling logic separately for each floating-point precision.

## 2) The 0.11 vs 0.16 Diff

**No significant public API migration changes detected:**

- **No allocator requirements**: This is a pure mathematical function with no memory allocation
- **No I/O interface changes**: Function operates purely on numerical inputs
- **No error handling changes**: Uses unreachable for unsupported types rather than error sets
- **API structure unchanged**: Simple function signature with complex number and exponent parameters

The public function signature follows consistent patterns:
```zig
pub fn ldexp_cexp(z: anytype, expt: i32) Complex(@TypeOf(z.re, z.im))
```

The implementation uses modern Zig 0.16 features like:
- `@bitCast` for type-punning between floats and integers
- `@divTrunc` for integer division
- `@intCast` for explicit integer size conversions
- Type functions like `@TypeOf(z.re, z.im)` for type deduction

## 3) The Golden Snippet

```zig
const std = @import("std");
const math = std.math;

// Compute exp(1.0 + 2.0i) scaled by 2^3
const z = math.Complex(f32).init(1.0, 2.0);
const result = math.complex.ldexp_cexp(z, 3);
// result now contains exp(1.0 + 2.0i) * 2^3
```

## 4) Dependencies

- `std.debug` - Debug utilities (unused in public API)
- `std.math` - Mathematical functions and complex number types
- `std.testing` - Testing utilities (test-only dependency)
- `std.math.complex` - Complex number operations

**Primary Public Dependency**: `std.math.complex` for the `Complex` type and related functionality.