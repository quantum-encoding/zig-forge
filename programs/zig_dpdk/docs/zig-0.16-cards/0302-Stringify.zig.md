# Migration Card: std.json.Stringify

## 1) Concept
This file implements a streaming JSON writer that generates RFC8259-compliant JSON data. The `Stringify` struct provides a stateful API for incrementally building JSON documents through method calls that follow a specific grammar. Key components include methods for starting/ending objects and arrays, writing fields and values, and handling various data types with configurable formatting options.

The module supports both direct value serialization via the `write()` method and manual JSON construction through explicit begin/end methods. It includes safety checks for proper API usage, configurable whitespace formatting, and support for streaming large data through raw write methods.

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **`valueAlloc` function** now explicitly requires an allocator parameter: `gpa: Allocator`
- The function signature changed from pattern-based allocation to explicit allocator injection
- Returns `error{OutOfMemory}![]u8` with caller-owned memory

### I/O Interface Changes
- **Writer dependency injection**: All functions now accept `writer: *Writer` parameters
- **Streaming support**: New methods `beginWriteRaw()`/`endWriteRaw()` and `beginObjectFieldRaw()`/`endObjectFieldRaw()` for direct writer access
- **Pointer-based writers**: Functions like `value()` take `*Writer` instead of writer values

### Error Handling Changes
- **Consistent error types**: All methods return `Writer.Error` (propagated from underlying writer)
- **No custom error sets**: Error handling is unified through the writer's error type

### API Structure Changes
- **Factory pattern**: `Stringify` struct initialized directly rather than through factory functions
- **Explicit options**: `Options` struct passed to configure formatting behavior
- **Stateful design**: Maintains internal state for punctuation, indentation, and nesting

## 3) The Golden Snippet

```zig
const std = @import("std");
const json = std.json;

var buffer: [1024]u8 = undefined;
var fixed_writer = std.io.fixedBufferStream(&buffer);
var writer = fixed_writer.writer();

// Serialize a struct to JSON with custom options
const Point = struct { x: i32, y: i32, name: []const u8 };
const point = Point{ .x = 10, .y = 20, .name = "origin" };

try json.Stringify.value(point, .{
    .whitespace = .indent_2,
    .emit_null_optional_fields = false
}, &writer);

const result = fixed_writer.getWritten();
// result contains: {\n  "x": 10,\n  "y": 20,\n  "name": "origin"\n}
```

## 4) Dependencies

- `std.mem` (Allocator, memory operations)
- `std.io` (Writer interface)
- `std.ArrayList` (Dynamic arrays)
- `std.BitStack` (Nesting depth tracking)
- `std.unicode` (UTF-8 validation)
- `std.math` (Number range checking)
- `std.debug` (Assertions)

This is a public API file with significant migration impact due to allocator and I/O interface changes.