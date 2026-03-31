# Migration Card: `std.fmt.parse_float`

## 1) Concept
This file implements a floating-point number parser for Zig's standard library. It provides a unified interface `parseFloat` that can parse strings into various floating-point types (f16, f32, f64, f80, f128) while handling both decimal and hexadecimal notation, special values (NaN, infinity), and edge cases like denormalized numbers.

The implementation uses a sophisticated multi-stage parsing approach: it first parses the number structure, then attempts fast path conversions, falls back to the Eisel-Lemire algorithm for common cases, and finally uses a slower but more robust algorithm when needed. The parser supports scientific notation, underscores for digit separation, and properly handles rounding and edge cases.

## 2) The 0.11 vs 0.16 Diff

**No significant API changes detected** - this appears to be a stable utility function:

- **No allocator requirements**: The `parseFloat` function is purely computational and doesn't require or use any memory allocator
- **No I/O interface changes**: This is a string parsing function, not file/stream I/O
- **Error handling unchanged**: Uses a simple, specific error set (`ParseFloatError`) with only `InvalidCharacter`
- **API structure consistent**: Simple static function pattern without initialization complexity
- **Compile-time type safety**: Uses `@compileError` to enforce that `T` must be a float type

The function signature remains clean and straightforward:
```zig
pub fn parseFloat(comptime T: type, s: []const u8) ParseFloatError!T
```

## 3) The Golden Snippet

```zig
const std = @import("std");

// Parse various float formats
const a: f32 = try std.fmt.parseFloat(f32, "3.141");
const b: f64 = try std.fmt.parseFloat(f64, "-2.718e-10");
const c: f16 = try std.fmt.parseFloat(f16, "0x1.ffcp+15"); // hexadecimal
const d: f32 = try std.fmt.parseFloat(f32, "inf"); // special value
const e: f64 = try std.fmt.parseFloat(f64, "nan"); // not-a-number

// Error handling
if (std.fmt.parseFloat(f32, "invalid")) |value| {
    // Success case
} else |err| switch (err) {
    error.InvalidCharacter => {
        // Handle parsing error
    },
}
```

## 4) Dependencies

- **`std.math`** - Used for float constants (inf, nan), comparisons, and mathematical operations
- **`std.testing`** - Used extensively for test assertions and validation
- **Internal parse_float submodules**:
  - `parse_float/parse.zig` - Core number parsing logic
  - `parse_float/convert_hex.zig` - Hexadecimal float conversion
  - `parse_float/convert_fast.zig` - Fast path conversion
  - `parse_float/convert_eisel_lemire.zig` - Eisel-Lemire algorithm
  - `parse_float/convert_slow.zig` - Fallback slow conversion

**Note**: This is a self-contained parsing module with no external dependencies beyond core math utilities.