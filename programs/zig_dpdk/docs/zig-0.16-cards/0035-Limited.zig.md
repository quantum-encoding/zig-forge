# Migration Card: std.Io.Reader.Limited

## 1) Concept

This file implements a limited reader wrapper that restricts how many bytes can be read from an underlying reader. It's part of Zig's I/O abstraction layer and provides a way to impose read limits on any reader implementation without modifying the original reader.

The key components are:
- A `Limited` struct that wraps an unlimited reader and tracks remaining bytes
- A reader interface implementation with `stream` and `discard` methods
- The wrapper transparently delegates to the underlying reader while enforcing the byte limit

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements**: No allocator dependencies - uses caller-provided buffers
**I/O Interface Changes**: Uses dependency injection via VTable pattern for reader interface
**Error Handling Changes**: Uses generic error types (`Reader.StreamError`, `Reader.Error`) 
**API Structure Changes**: Factory pattern with `init()` function rather than direct struct initialization

Key signature differences:
- `init(reader: *Reader, limit: Limit, buffer: []u8) Limited` - factory function pattern
- Interface methods use `@fieldParentPtr` for context tracking
- Limit parameter uses enum type `Limit` instead of raw integers

## 3) The Golden Snippet

```zig
const std = @import("std");

// Create a fixed reader from a string
var data = "hello world";
var fixed_reader: std.Io.Reader = .{ .fixed = &data };

// Create a limited reader that only allows reading 5 bytes
var buffer: [1]u8 = undefined;
var limited = std.Io.Reader.Limited.init(&fixed_reader, .{ .limited = 5 }, &buffer);

// Use the limited interface
var output: [10]u8 = undefined;
var writer: std.Io.Writer = .{ .fixed = &output };
const bytes_read = try limited.interface.stream(&writer, .{ .limited = 10 });
```

## 4) Dependencies

- `std.Io.Reader` - Core reader interface
- `std.Io.Writer` - Writer interface for stream operations  
- `std.Io.Limit` - Limit enumeration type
- `std.testing` - Test utilities (test-only dependency)

**Note**: This is a wrapper type that depends entirely on the Zig I/O abstraction layer rather than concrete implementations.