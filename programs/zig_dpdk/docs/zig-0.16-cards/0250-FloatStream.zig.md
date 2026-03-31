# Migration Card: FloatStream.zig

## 1) Concept

This file implements a `FloatStream` type - a stateful wrapper around a byte slice specifically designed for parsing string floating-point values. It provides cursor-based navigation through the input string while tracking the current offset and handling underscore characters (which are commonly used as numeric separators in many programming languages). The stream maintains both the raw offset and a "true offset" that excludes underscores, making it easier to parse numeric literals with digit separators.

Key components include methods for peeking at characters, checking character properties, advancing through the stream, scanning digits in different bases, and reading binary data. The implementation is focused on efficient forward-only parsing with minimal allocation overhead.

## 2) The 0.11 vs 0.16 Diff

**No breaking API changes detected** - this appears to be a stable internal utility type:

- **Initialization Pattern**: Uses simple struct initialization with `init()` function - no allocator requirements
- **I/O Interface**: Works directly with byte slices - no dependency injection patterns
- **Error Handling**: Uses optional returns (`?u8`) and boolean checks rather than error sets
- **API Structure**: Consistent naming with `init()`, `first()`, `advance()`, etc.

The API follows Zig's standard patterns for stream/reader interfaces and maintains backward compatibility from 0.11 patterns.

## 3) The Golden Snippet

```zig
const std = @import("std");
const FloatStream = @import("std/fmt/parse_float/FloatStream.zig").FloatStream;

pub fn main() void {
    var stream = FloatStream.init("123_456.78e-9");
    
    // Skip initial digits and underscores
    stream.skipChars("0123456789_");
    
    // Check if next character is a decimal point
    if (stream.firstIs(".")) {
        stream.advance(1);
        
        // Scan hexadecimal digits after decimal
        while (stream.scanDigit(16)) |digit| {
            // Process each digit
            _ = digit;
        }
    }
    
    const true_offset = stream.offsetTrue();
    // true_offset now represents position excluding underscores
}
```

## 4) Dependencies

- **`std.mem`** - Used for `readInt` operation in `readU64Unchecked()`
- **`std.debug`** - Used for compile-time assertions in validation functions
- **Local `common.zig`** - Provides `isDigit` utility function for digit validation

The dependency graph shows this is a lightweight utility with minimal external dependencies, primarily relying on memory operations and basic debugging utilities.