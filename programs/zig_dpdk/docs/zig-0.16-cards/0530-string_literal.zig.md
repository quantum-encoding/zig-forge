# Migration Card: `std/zig/string_literal.zig`

## 1) Concept

This file provides parsing utilities for Zig string and character literals. It handles escape sequence decoding, Unicode codepoint validation, and literal syntax validation. The key components include:

- Character literal parsing (`parseCharLiteral`) that handles single-quoted character literals with various escape sequences
- String literal parsing (`parseWrite`, `parseAlloc`) that processes double-quoted string literals
- Detailed error reporting with specific error types for different parsing failures
- Support for escape sequences including `\n`, `\r`, `\t`, `\x`, `\u`, and Unicode escapes

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- `parseAlloc` now requires an explicit `std.mem.Allocator` parameter, migrating from potential implicit allocation patterns in 0.11

**I/O Interface Changes:**
- `parseWrite` uses dependency injection with `*Writer` interface rather than concrete stream types
- Uses `std.Io.Writer` pattern which is part of the new I/O stack

**Error Handling Changes:**
- Returns union types (`ParsedCharLiteral`, `Result`) instead of simple error unions
- Detailed error categorization with specific error variants rather than generic error codes
- Error formatting uses the new `std.fmt.Alt` pattern

**API Structure:**
- No `init`/`open` pattern - functions are stateless and operate directly on input
- `parseWrite` follows the writer-based output pattern common in 0.16
- `parseAlloc` follows the explicit allocator + return slice pattern

## 3) The Golden Snippet

```zig
const std = @import("std");
const string_literal = std.zig.string_literal;

test "parse string literal with allocator" {
    const allocator = std.testing.allocator;
    
    // Parse a string literal with escape sequences
    const result = try string_literal.parseAlloc(allocator, "\"Hello\\nWorld\\u{1f600}\"");
    defer allocator.free(result);
    
    // result now contains: "Hello\nWorld😀"
}
```

## 4) Dependencies

- `std.mem` (for Allocator in parseAlloc)
- `std.unicode` (for utf8Encode and UTF-8 decoding functions)
- `std.Io` (for Writer interface)
- `std.debug` (for assertions)
- `std.fmt` (for error formatting)