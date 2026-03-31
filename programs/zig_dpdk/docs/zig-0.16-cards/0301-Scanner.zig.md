# Migration Card: std.json.Scanner

## 1) Concept

This file implements a low-level JSON parsing API that supports both streaming and complete input parsing with minimal memory footprint. The key components are:

- **Scanner**: The core JSON tokenizer that operates on input buffers and emits tokens representing JSON structure and values. It maintains parsing state and can handle partial input buffers for streaming scenarios.

- **Reader**: A higher-level wrapper that combines Scanner with an I/O reader interface, automatically handling buffer refills and providing a more convenient API for reading from streams.

The scanner is designed to be memory efficient (O(d) where d is nesting depth) and supports both allocation-free operation for simple cases and allocator-based operations for complex values that span multiple buffers.

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **Factory functions require allocators**: Both `initStreaming()` and `initCompleteInput()` now explicitly require an `Allocator` parameter for managing nesting depth tracking
- **Memory management**: The scanner uses `BitStack` internally which requires allocator for tracking container nesting levels
- **Value allocation**: Methods like `nextAlloc()` and `allocNextIntoArrayList()` require explicit allocators for handling string/number values that need concatenation

### I/O Interface Changes
- **Reader dependency injection**: The `Reader` struct now takes a `*std.Io.Reader` interface instead of concrete reader types, enabling better dependency injection
- **Streaming API**: The `feedInput()`/`endInput()` pattern supports streaming parsing with explicit buffer management

### Error Handling Changes
- **Specific error sets**: Functions return specific error sets like `NextError`, `AllocError`, `PeekError` that combine parsing errors with allocator and buffer underrun errors
- **Error categorization**: Clear separation between `SyntaxError` (malformed JSON) and `UnexpectedEndOfInput` (truncated but valid JSON)

### API Structure Changes
- **Multiple initialization patterns**: `initStreaming()` for streaming input vs `initCompleteInput()` for single-buffer parsing
- **Allocation strategies**: `AllocWhen` enum parameter controls when allocation occurs (.alloc_if_needed vs .alloc_always)
- **Value size limits**: Default 4MiB limit on allocated values with configurable maximums via `nextAllocMax()`

## 3) The Golden Snippet

```zig
const std = @import("std");
const json = std.json;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Parse complete JSON input
    const input = 
        \\{"name": "Alice", "age": 30, "is_student": false}
    ;
    
    var scanner = json.Scanner.initCompleteInput(allocator, input);
    defer scanner.deinit();

    // Read tokens until end of document
    while (true) {
        const token = try scanner.next();
        switch (token) {
            .object_begin => std.debug.print("Start object\n", .{}),
            .object_end => std.debug.print("End object\n", .{}),
            .string => |s| std.debug.print("String: {s}\n", .{s}),
            .number => |n| std.debug.print("Number: {s}\n", .{n}),
            .true => std.debug.print("true\n", .{}),
            .false => std.debug.print("false\n", .{}),
            .null => std.debug.print("null\n", .{}),
            .end_of_document => break,
            else => {}, // Handle partial tokens if needed
        }
    }
}
```

## 4) Dependencies

- **std.mem** - For allocator types and memory management
- **std.array_list** - For managed array lists used in value concatenation
- **std.unicode** - For UTF-8/UTF-16 encoding/decoding validation
- **std.BitStack** - For efficient tracking of JSON container nesting depth
- **std.Io** - For reader interface in the Reader wrapper

The scanner has minimal dependencies focused on memory management and Unicode handling, making it suitable for embedded systems and performance-critical applications.