# Migration Card: std.compress.xz.Decompress

## 1) Concept

This file implements an XZ decompression stream reader that can decompress data in the XZ file format. It provides a streaming interface that reads compressed data from an underlying `Reader` and outputs decompressed data through its own `Reader` interface. The implementation handles XZ container format parsing, checksum validation, and delegates the actual LZMA2 decompression to the `std.compress.lzma2` module.

Key components include the `Decompress` struct that maintains decompression state, support for multiple checksum types (CRC32, CRC64, SHA256), and block-by-block processing of the XZ stream format with proper header validation and error handling.

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **Factory function pattern**: `init()` takes explicit `Allocator` parameter (`gpa`) and requires caller to provide initial buffer
- **Ownership model**: Takes ownership of provided buffer and manages resizing via allocator
- **Cleanup**: `deinit()` and `takeBuffer()` methods for explicit resource management

### I/O Interface Changes
- **Dependency injection**: `init()` takes `*Reader` for compressed input source
- **VTable-based readers**: Uses `std.Io.Reader` with custom vtable implementation (`stream`, `readVec`, `discard`)
- **Writer allocation pattern**: Uses `Writer.Allocating` for dynamic buffer management during decompression

### Error Handling Changes
- **Specific error types**: Separate `InitError` for initialization failures vs general `Error` for decompression
- **Error state tracking**: `err` field stores persistent error state for streaming operations
- **Error translation**: Maps internal errors to `Reader.Error` for interface compliance

### API Structure Changes
- **No open/close pattern**: Uses `init/deinit` lifecycle with explicit buffer management
- **Stream-oriented**: Designed for streaming decompression rather than one-shot operations
- **Buffer reuse**: `takeBuffer()` allows buffer reuse across multiple decompressor instances

## 3) The Golden Snippet

```zig
const std = @import("std");
const xz = std.compress.xz;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    // Create input source (e.g., from file or memory)
    var input_stream = std.io.fixedBufferStream(compressed_data);
    const input_reader = input_stream.reader();
    
    // Initialize decompressor with initial buffer
    var buffer = try allocator.alloc(u8, 4096);
    var decompressor = try xz.Decompress.init(input_reader, allocator, buffer);
    defer {
        const buf = decompressor.takeBuffer();
        allocator.free(buf);
        decompressor.deinit();
    }
    
    // Read decompressed data
    var output: [8192]u8 = undefined;
    const bytes_read = try decompressor.reader.read(&output);
    
    // Use decompressed data...
}
```

## 4) Dependencies

- `std.mem` (Allocator, memory operations)
- `std.hash` (Crc32, Crc64Xz for checksums)
- `std.crypto.hash.sha2` (Sha256 for integrity checking)
- `std.compress.lzma2` (Core decompression algorithm)
- `std.Io` (Reader/Writer interfaces and streaming)
- `std.ArrayList` (Dynamic buffer management)
- `std.debug` (Assertions)
- `std.math` (Integer bounds and calculations)