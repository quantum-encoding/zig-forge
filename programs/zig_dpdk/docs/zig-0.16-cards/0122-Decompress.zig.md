# Migration Card: std/compress/flate/Decompress.zig

## 1) Concept

This file implements a DEFLATE decompressor that supports multiple compression formats including raw DEFLATE, zlib, and gzip. The core component is the `Decompress` struct which wraps an input reader and provides a reader interface for decompressed data output. It handles all three DEFLATE block types (stored, fixed Huffman, dynamic Huffman) and manages the decompression state machine across different container formats.

Key components include:
- `Decompress` struct managing decompression state and buffers
- Huffman decoders for literal/length and distance codes
- Bit-level reading with proper alignment handling
- Support for all three container formats (raw, zlib, gzip)

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **No allocator parameter**: The `init` function doesn't require an allocator, instead taking a pre-allocated buffer
- **Buffer management**: Users must provide their own buffer with `flate.max_window_len` capacity or use zero-length for direct streaming

### I/O Interface Changes
- **Reader-based design**: The API centers around `std.Io.Reader` interfaces rather than direct byte arrays
- **Dependency injection**: The decompressor takes a `*Reader` input and provides its own `Reader` for output
- **Stream-based processing**: Uses `streamRemaining` and `readVec` patterns instead of one-shot decompression

### Error Handling Changes
- **Specific error sets**: Uses detailed error types like `error.InvalidCode`, `error.OversubscribedHuffmanTree`, etc.
- **Error state preservation**: Errors are stored in `err` field for diagnostic purposes
- **Stream error wrapping**: Internal errors are wrapped in `error.ReadFailed` when surfaced through reader interface

### API Structure Changes
- **Factory pattern**: Uses `init()` rather than `open()` naming convention
- **Container enum**: Takes `Container` parameter (raw/zlib/gzip) instead of separate constructors
- **Reader composition**: Returns a reader interface rather than requiring callback-based processing

## 3) The Golden Snippet

```zig
const std = @import("std");
const flate = std.compress.flate;

// Decompress zlib data
fn decompressZlibData(allocator: std.mem.Allocator, compressed_data: []const u8) ![]const u8 {
    var in_reader = std.io.fixedBufferStream(compressed_data).reader();
    
    var decompress_buffer: [flate.max_window_len]u8 = undefined;
    var decompressor = flate.decompress.Decompress.init(
        &in_reader, 
        .zlib, 
        &decompress_buffer
    );
    
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    
    _ = try decompressor.reader.streamRemaining(&output.writer());
    
    return output.toOwnedSlice();
}
```

## 4) Dependencies

- `std.mem` (for memory operations and varint reading)
- `std.io` (for Reader/Writer interfaces and streaming)
- `std.compress.flate` (for container types and constants)
- `std.debug` (for assertions)
- `std.testing` (for test utilities)

**Note**: This is a public API file that developers would use directly for DEFLATE decompression across multiple formats.