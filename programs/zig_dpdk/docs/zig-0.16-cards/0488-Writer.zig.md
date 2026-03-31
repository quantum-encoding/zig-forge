# Migration Card: std.tar.Writer

## 1) Concept

This file implements a TAR archive writer for Zig's standard library. It provides functionality to create TAR archives by writing files, directories, and symbolic links with proper header formatting. The main components are:

- `Writer`: The primary struct that wraps an underlying I/O writer and provides methods for adding various types of entries to a TAR archive
- `Header`: A 512-byte struct that represents the TAR file format header, handling path encoding, file metadata, and checksum calculation
- `Options`: Configuration for file permissions and modification times

The implementation supports GNU extended headers for long filenames and provides both streaming and buffer-based file writing approaches.

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **No allocator dependency**: The Writer operates purely on provided writers/readers without internal allocation
- **Buffer-based APIs**: Methods like `writeFileBytes` accept pre-allocated slices rather than allocating internally

### I/O Interface Changes
- **Interface-based I/O**: Uses `*Io.Writer` and `*Io.Reader` pointers instead of concrete types
- **Dependency injection**: Underlying writer is injected via struct initialization rather than factory methods
- **File reader abstraction**: `writeFile` accepts `*Io.File.Reader` for file content streaming

### Error Handling Changes
- **Specific error unions**: Methods return composed error sets like `WriteFileError = Io.Writer.FileError || Error || Io.File.Reader.SizeError`
- **Granular error types**: Custom `Error` enum with `WriteFailed`, `OctalOverflow`, `NameTooLong`
- **Streaming error propagation**: `WriteFileStreamError` combines module errors with reader stream errors

### API Structure Changes
- **Direct struct initialization**: Writer created via `Writer{ .underlying_writer = &some_writer }` pattern
- **No factory functions**: No `init()` or `open()` methods - direct struct construction
- **Method-based configuration**: `setRoot()` for prefix configuration rather than constructor parameters

## 3) The Golden Snippet

```zig
const std = @import("std");

pub fn main() !void {
    var buffer: [1024]u8 = undefined;
    var fixed_buffer_stream = std.io.fixedBufferStream(&buffer);
    var writer = fixed_buffer_stream.writer();

    // Create tar writer with direct struct initialization
    var tar_writer: std.tar.Writer = .{ .underlying_writer = &writer };

    // Write directory with options
    try tar_writer.writeDir("mydir", .{ .mode = 0o755, .mtime = 1704067200 });

    // Write file from bytes
    try tar_writer.writeFileBytes("mydir/hello.txt", "Hello, World!\n", .{});

    // Write symbolic link
    try tar_writer.writeLink("mydir/link", "../other.txt", .{});
}
```

## 4) Dependencies

- `std.Io` - Core I/O interfaces and abstractions
- `std.debug` - Assertion functionality
- `std.testing` - Test utilities (test-only)
- `std.mem` - Memory operations (implicit via std import)
- `std.fs` - Filesystem paths (test-only)

**Note**: The heavy use of `std.Io` indicates this module is part of Zig's new I/O stack migration, using interface-based I/O rather than concrete file types.