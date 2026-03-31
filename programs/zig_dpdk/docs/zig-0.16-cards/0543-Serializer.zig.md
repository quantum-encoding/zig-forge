# Migration Card: `std.zon.Serializer`

## 1) Concept

This file implements a low-level ZON (Zig Object Notation) serializer that provides fine-grained control over serialization output. It's designed for use cases where you need manual control over field serialization, want to write ZON objects that don't exist in memory, or need custom representation of values.

Key components include:
- **Serializer**: The main struct that holds serialization state and options
- **Container types**: `Struct` and `Tuple` for manual serialization of container types
- **Value serialization**: Methods for serializing specific types (integers, floats, strings, etc.)
- **Depth control**: Support for recursive types with configurable depth limits

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **No allocator dependency**: The serializer operates purely on a writer interface and doesn't require an allocator
- **Writer-based**: All output goes through a `std.Io.Writer` interface rather than returning allocated strings

### I/O Interface Changes
- **Dependency injection**: The serializer takes a `*Writer` in its initialization rather than managing its own output buffer
- **No file operations**: This is purely a serialization layer - file I/O must be handled externally

### Error Handling Changes
- **Generic error sets**: Uses `Writer.Error` and extends it with serializer-specific errors
- **Specific error types**: 
  - `CodePointError = Error || error{InvalidCodepoint}`
  - `MultilineStringError = Error || error{InnerCarriageReturn}`
  - `DepthError = Error || error{ExceededMaxDepth}`

### API Structure Changes
- **Factory pattern**: Create serializer instances directly via struct initialization
- **Container lifecycle**: Explicit `beginStruct`/`beginTuple` and `end()` methods
- **Depth variants**: Multiple versions for different depth handling (`value`, `valueMaxDepth`, `valueArbitraryDepth`)

## 3) The Golden Snippet

```zig
const std = @import("std");

pub fn main() !void {
    var buffer: [1024]u8 = undefined;
    var fixed_buffer_stream = std.io.fixedBufferStream(&buffer);
    const writer = fixed_buffer_stream.writer();

    var serializer = std.zon.Serializer{
        .writer = &writer,
        .options = .{ .whitespace = true },
    };

    // Serialize a simple struct
    var my_struct = try serializer.beginStruct(.{
        .whitespace_style = .{ .fields = 2 }
    });
    try my_struct.field("name", "Alice", .{});
    try my_struct.field("age", 30, .{});
    try my_struct.end();

    const result = fixed_buffer_stream.getWritten();
    std.debug.print("Serialized: {s}\n", .{result});
}
```

## 4) Dependencies

- `std.debug` (for assertions)
- `std.io` (for Writer interface)
- `std.math` (for float checks and casting)
- `std.unicode` (for UTF-8 validation)
- `std.ascii` (for printable character checks)
- `std.zig` (for identifier and string formatting utilities)
- `std.mem` (used in tests for equality comparisons)

**Note**: The serializer has minimal dependencies and focuses on pure serialization logic without I/O or memory management concerns.