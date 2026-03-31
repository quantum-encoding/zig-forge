# Migration Card: std/compress/zstd/Decompress.zig

## 1) Concept
This file implements a Zstandard decompression reader for Zig's standard library. It provides streaming decompression of Zstandard-compressed data through a `Reader` interface. The main component is the `Decompress` struct that wraps an input reader and exposes a decompressed output reader.

Key components include:
- `Decompress` struct managing decompression state and I/O
- Frame parsing for Zstandard and skippable frames
- Block decoding for raw, RLE, and compressed blocks
- Literals and sequences sections handling
- FSE table decoding and Huffman tree processing
- Bit-level readers for reverse and forward bit streams

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements:**
- No allocator parameter in public API - uses caller-provided buffers
- `init()` function requires explicit buffer allocation by caller
- Buffer size assertions based on `window_len + zstd.block_size_max`

**I/O Interface Changes:**
- Uses new `std.Io.Reader` and `std.Io.Writer` interfaces
- Direct and indirect reader vtables for different buffering strategies
- `Limit` type for bounded I/O operations
- Error handling through reader/writer error sets

**Error Handling Changes:**
- Specific Zstandard error set (`Decompress.Error`) with 30+ error cases
- No generic error unions - specific error types for different operations
- Error propagation through reader interface

**API Structure Changes:**
- Factory pattern: `Decompress.init(input, buffer, options)` instead of direct struct initialization
- Options struct for configuration (`verify_checksum`, `window_len`)
- State machine approach with explicit frame handling

## 3) The Golden Snippet

```zig
const std = @import("std");
const zstd = std.compress.zstd;

// Create input reader from compressed data
var input_stream = std.io.fixedBufferStream(compressed_data);
const input_reader = input_stream.reader();

// Prepare decompression buffer (must be at least window_len + block_size_max)
var buffer: [1024 * 1024]u8 = undefined;

// Initialize decompressor
var decompressor = zstd.Decompress.init(
    input_reader, 
    &buffer, 
    .{
        .verify_checksum = false, // Note: true will panic (not implemented)
        .window_len = zstd.default_window_len,
    }
);

// Use decompressor.reader to read decompressed data
var output: [8192]u8 = undefined;
const bytes_read = try decompressor.reader.read(&output);
```

## 4) Dependencies

**Heavily Imported Modules:**
- `std.Io` (Reader, Writer, Limit)
- `std.mem` (memory operations, sorting)
- `std.math` (logarithm, power calculations)
- `std.hash` (XxHash64 for checksum verification)
- `std.debug` (assertions)

**Internal Dependencies:**
- `../zstd.zig` (constants and common types)
- Various compression-specific types (Frame, LiteralsSection, SequencesSection, Table)

**Key Dependencies for Migration:**
- `std.Io` module for all I/O operations
- `std.mem` for buffer management
- `std.math` for bit manipulation and calculations