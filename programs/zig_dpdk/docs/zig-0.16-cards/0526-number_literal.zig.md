# Migration Analysis: `std/zig/number_literal.zig`

## 1) Concept

This file provides number literal parsing functionality for Zig's standard library. It implements a parser that can handle Zig's various number literal formats including decimal, hexadecimal, binary, and octal representations. The parser supports both integer and floating-point literals with proper validation of Zig's syntax rules like digit separators (`_`), base prefixes (`0x`, `0b`, `0o`), and exponent notation.

Key components include:
- `ParseError` enum for allocation-related errors
- `Base` and `FloatBase` enums for supported numeric bases
- `Result` union that can represent successful integer/float parsing or detailed error information
- `Error` union with comprehensive error variants for different parsing failure scenarios
- The main `parseNumberLiteral` function that performs the actual parsing

## 2) The 0.11 vs 0.16 Diff

This API follows a consistent pattern across Zig versions with minimal breaking changes:

**Allocator Pattern**: No allocator dependency - the function is purely computational and returns a result union without heap allocation.

**Function Signature**: The main API `parseNumberLiteral(bytes: []const u8) Result` remains stable. It takes a byte slice and returns a tagged union, which is a common Zig pattern.

**Error Handling**: Uses a custom result union instead of standard error sets, allowing for detailed error information. This pattern was common in 0.11 and remains relevant in 0.16.

**API Structure**: Simple functional API without constructor patterns - just call the function directly.

The primary migration consideration is handling the `Result` union, which uses the newer `@enumFromInt` syntax instead of the deprecated `@intToEnum`.

## 3) The Golden Snippet

```zig
const std = @import("std");
const parseNumberLiteral = std.zig.number_literal.parseNumberLiteral;

pub fn main() !void {
    const input = "0x1A3F";
    const result = parseNumberLiteral(input);
    
    switch (result) {
        .int => |value| std.debug.print("Parsed integer: {}\n", .{value}),
        .big_int => |base| std.debug.print("Big integer with base: {}\n", .{base}),
        .float => |base| std.debug.print("Float with base: {}\n", .{base}),
        .failure => |err| std.debug.print("Parse error: {}\n", .{err}),
    }
}
```

## 4) Dependencies

- `std` (root import)
- `std.debug.assert` (for internal validation)
- `std.unicode.utf8Decode` (imported but not used in current implementation)
- `std.unicode.utf8Encode` (imported but not used in current implementation)

This module has minimal external dependencies and focuses on core parsing logic without I/O or memory allocation requirements.