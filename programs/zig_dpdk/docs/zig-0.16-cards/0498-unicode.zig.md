# Migration Card: std.unicode.zig

## 1) Concept
This file provides comprehensive Unicode encoding/decoding utilities for Zig's standard library. It implements UTF-8 and UTF-16 encoding/decoding with support for both standard Unicode and WTF-8/WTF-16 (Web Text Format) encodings. Key components include:

- Low-level UTF-8/UTF-16 encoding and decoding functions
- Validation functions for UTF-8 and WTF-8 strings  
- Iterator types for traversing Unicode strings (`Utf8View`, `Wtf8View`, `Utf16LeIterator`)
- Conversion functions between UTF-8, UTF-16, WTF-8, and WTF-16
- Lossy conversion utilities for handling malformed Unicode data
- Compile-time Unicode operations

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- All allocation-based functions now require explicit `Allocator` parameters
- Functions like `utf16LeToUtf8Alloc`, `utf8ToUtf16LeAlloc`, `wtf16LeToWtf8Alloc` take `allocator: Allocator` as first parameter
- ArrayList-based functions (`*ArrayList`) work with pre-initialized array lists rather than creating them internally

**Error Handling Changes:**
- Specific error sets used throughout rather than generic errors
- `Utf8DecodeError`, `Utf16LeToUtf8Error`, `CalcUtf16LeLenError` etc.
- Clear separation between UTF-8 and WTF-8 validation errors

**API Structure Changes:**
- Consistent use of `init()` pattern for view types (`Utf8View.init()`, `Wtf8View.init()`)
- Iterator creation via `iterator()` method on views rather than direct construction
- Explicit error handling for validation operations

**Key Public API Changes:**
- `utf8Decode()` marked as deprecated with awkward API comment
- All conversion functions follow consistent naming: `*To*Alloc`, `*To*ArrayList`
- Added comprehensive WTF-8/WTF-16 support alongside standard UTF encodings

## 3) The Golden Snippet

```zig
const std = @import("std");
const unicode = std.unicode;

// Convert UTF-8 to UTF-16 with allocation
pub fn example() !void {
    const allocator = std.heap.page_allocator;
    const utf8_string = "Hello, 世界!";
    
    // Convert to UTF-16
    const utf16_slice = try unicode.utf8ToUtf16LeAlloc(allocator, utf8_string);
    defer allocator.free(utf16_slice);
    
    // Iterate through UTF-8 codepoints
    const view = try unicode.Utf8View.init(utf8_string);
    var iter = view.iterator();
    
    while (iter.nextCodepoint()) |codepoint| {
        std.debug.print("Codepoint: {x}\n", .{codepoint});
    }
}
```

## 4) Dependencies

**Heavily Used Modules:**
- `std.mem` - Memory operations, slicing, reading integers
- `std.debug` - Assertions
- `std.testing` - Test utilities
- `std.simd` - Vectorized operations for performance
- `std.math` - Mathematical operations
- `std.array_list` - Dynamic array management for conversions
- `std.fmt` - Formatting utilities

**Key Type Dependencies:**
- `Allocator = std.mem.Allocator`
- `std.array_list.Managed` for conversion buffers
- `std.Io.Writer` for formatting functions

This module provides foundational Unicode support with comprehensive error handling and modern Zig patterns, requiring minimal migration effort for most use cases beyond updating to explicit allocator patterns.