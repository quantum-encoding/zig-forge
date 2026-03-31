```markdown
# Migration Card: std/fmt/parse_float/common.zig

## 1) Concept
This file provides low-level floating-point parsing utilities used internally by Zig's formatting system. It defines generic types and functions for working with biased floating-point representations (`BiasedFp`) and parsed number components (`Number`). The key components include conversion functions between unsigned integers and floating-point types, digit validation utilities, and mantissa type calculations for different floating-point formats.

## 2) The 0.11 vs 0.16 Diff
This file contains no public API changes requiring migration. All functions are generic type constructors and pure utility functions that:
- Require no explicit allocators
- Use no I/O interfaces
- Have no error handling (all operations are deterministic)
- Maintain the same API structure across versions

The functions are mathematical utilities that operate solely on their parameters without external dependencies or state.

## 3) The Golden Snippet
```zig
const std = @import("std");

// Check if a byte is a valid hexadecimal digit
const is_hex_digit = std.fmt.parse_float.common.isDigit('A', 16);
// Result: true

// Get mantissa type for f32
const MantissaType = std.fmt.parse_float.common.mantissaType(f32);
// MantissaType = u64

// Create zero BiasedFp for f64
const Bfp = std.fmt.parse_float.common.BiasedFp(f64);
const zero_fp = Bfp.zero();
// zero_fp.f = 0, zero_fp.e = 0
```

## 4) Dependencies
- `std` (base import)
- `std.math` (used for floatExponentBits, floatMantissaBits)
- `std.debug` (used for assert in isDigit)

**Note**: This is an internal utility file primarily used by the standard library's float parsing implementation. While its functions are public, they're not typically called directly by user code.
```