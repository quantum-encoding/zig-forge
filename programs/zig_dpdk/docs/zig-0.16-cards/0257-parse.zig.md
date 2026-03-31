# Migration Card: `std.fmt.parse_float.parse.zig`

## 1) Concept

This file implements the core parsing logic for floating-point numbers in Zig's standard library formatting module. It handles both decimal and hexadecimal floating-point literals, parsing them into a structured representation (`Number(T)`) that contains the mantissa, exponent, sign, and other metadata. The code provides optimized parsing paths for common cases (like 8-digit chunks) while supporting scientific notation, underscores in numeric literals, and special values like Infinity and NaN.

Key components include:
- `parseNumber`: Main entry point for parsing regular floating-point numbers
- `parseInfOrNan`: Handles special floating-point values (Infinity and NaN)
- Optimized digit parsing using bit manipulation for performance
- Support for both base-10 and base-16 (hexadecimal) floating-point notation

## 2) The 0.11 vs 0.16 Diff

**No breaking API changes detected** - this file maintains the same public interface patterns:

- **No allocator requirements**: All parsing functions are purely computational with no memory allocation
- **No I/O interface changes**: Functions operate directly on string slices without stream dependencies
- **Error handling unchanged**: Uses optional return types (`?Number(T)`) consistently
- **API structure preserved**: Same function signatures and usage patterns

The public API consists of two simple functions:
- `parseNumber(comptime T: type, s: []const u8, negative: bool) ?Number(T)`
- `parseInfOrNan(comptime T: type, s: []const u8, negative: bool) ?T`

Both functions follow the same pattern: take a float type, string slice, and sign flag, returning an optional parsed value.

## 3) The Golden Snippet

```zig
const std = @import("std");
const parse_float = std.fmt.parse_float;

// Parse a decimal floating-point number
if (parse_float.parseNumber(f64, "3.14159", false)) |number| {
    // number contains parsed mantissa, exponent, etc.
    std.debug.print("Mantissa: {}, Exponent: {}\n", .{number.mantissa, number.exponent});
}

// Parse a hexadecimal floating-point number  
if (parse_float.parseNumber(f64, "0x1.8p+1", false)) |number| {
    // number.hex will be true for hexadecimal notation
    std.debug.print("Hex float: mantissa=0x{x}, exponent={}\n", .{number.mantissa, number.exponent});
}

// Parse special values
if (parse_float.parseInfOrNan(f32, "inf", false)) |special| {
    std.debug.print("Special value: {}\n", .{special});
}
```

## 4) Dependencies

- `std` - Core standard library
- `std.fmt.parse_float.common` - Shared constants and types for float parsing
- `std.fmt.parse_float.FloatStream` - String streaming utility for parsing
- `std.math` - For special float values (inf, nan)
- `std.ascii` - For case-insensitive string comparisons
- `std.debug` - For assertions only (compiled out in release mode)