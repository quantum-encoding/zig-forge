```markdown
# Migration Card: /tmp/tmp.4B8VzrxwuA/files/frexp.zig

## 1) Concept
This file implements the `frexp` function and its associated `Frexp` return type for decomposing floating-point numbers into a normalized significand (fraction in [0.5, 1)) and an integral exponent such that `x == significand * 2^exponent`. It handles normal, subnormal, zero, infinity, and NaN cases correctly per IEEE 754 semantics. Key components include:
- `Frexp(T)`: A generic struct with `significand: T` and `exponent: i32` fields.
- `frexp(x: anytype)`: Generic function returning `Frexp(@TypeOf(x))`, using bit manipulation for efficiency across float types (f16, f32, f64, f80, f128).
- Comprehensive tests verifying behavior, including reconstruction via `ldexp`.

The API is pure (no side effects, allocations, or errors) and designed for use in mathematical computations.

## 2) The 0.11 vs 0.16 Diff
- No explicit allocator requirements: Pure function with no `Allocator` dependencies or struct init/factory patterns.
- No I/O interface changes: No streams, file handles, or dependency injection.
- No error handling changes: Returns a value directly; no `error` unions or generic/specific error sets (special cases like NaN/inf handled via undefined/0 exponent).
- API structure stable: `frexp(x: anytype)` signature unchanged; returns struct rather than out-params (consistent with modern Zig math APIs). `Frexp(comptime T: type)` type generator is public but internal-like. No `init`/`open` patterns. Minor internals use updated comptime math helpers (e.g., `math.floatExponentBits`), but public signatures identical to 0.11 patterns.

No breaking public API changes requiring migration.

## 3) The Golden Snippet
```zig
const std = @import("std");
const math = std.math;
const expect = std.testing.expect;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

test "frexp basic usage" {
    const x: f64 = 1.3;
    const r = math.frexp(x);
    try expectApproxEqAbs(0.65, r.significand, 1e-6);
    try expectEqual(1, r.exponent);
    try expectEqual(x, math.ldexp(r.significand, r.exponent));
}
```

## 4) Dependencies
- `std.math` (core: `floatExponentBits`, `floatMantissaBits`, `floatFractionalBits`, `floatExponentMin`, `floatEps`, `floatMax`, `floatMin`, `floatTrueMin`, `inf`, `nan`, `isPositiveZero`, `isNegativeZero`, `isPositiveInf`, `isNegativeInf`, `isNan`, `ldexp`, `shl`)
- `std.meta` (heavily: `Int`)
- `std.testing` (tests only: `expect`, `expectEqual`, `expectApproxEqAbs`)
```

## Footer
SKIP: Internal implementation file - no public migration impact