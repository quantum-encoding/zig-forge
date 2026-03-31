# Migration Card: std/compress/flate.zig

## 1) Concept

This file provides the core implementation of DEFLATE compression/decompression algorithms and container formats (raw, gzip, zlib). It serves as the main entry point for DEFLATE-based compression in Zig's standard library, re-exporting the actual compression and decompression implementations from submodules while defining the container format specifications and validation logic.

Key components include:
- `Compress` and `Decompress` types for compression/decompression operations
- `Container` enum defining supported formats (raw, gzip, zlib) with associated metadata and validation
- Constants for window sizes and history buffers required by DEFLATE algorithm
- Checksum implementations (CRC32, Adler32) for different container formats

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- No explicit allocator patterns found in this file's public API
- Container operations are stateless and don't require memory allocation

### I/O Interface Changes
- Uses `*std.Io.Writer` interface for output operations
- The `Hasher.writeFooter` method demonstrates the dependency injection pattern by accepting a generic writer

### Error Handling Changes
- Container-specific error sets with granular error types:
  ```zig
  pub const Error = error{
      BadGzipHeader,
      BadZlibHeader,
      WrongGzipChecksum,
      WrongGzipSize,
      WrongZlibChecksum,
  };
  ```
- No generic error sets - each error case is explicitly defined

### API Structure Changes
- Factory pattern with `init()` methods for `Hasher` and `Metadata`
- Container format selection via enum rather than separate types
- Stateless utility functions for header/footer sizes

## 3) The Golden Snippet

```zig
const std = @import("std");
const flate = std.compress.flate;

// Create a gzip container hasher
var hasher = flate.Container.Hasher.init(.gzip);

// Update hasher with data
const data = "Hello, World!";
hasher.update(data);

// Write footer to a writer
var buffer = std.io.fixedBufferStream(&[_]u8{});
try hasher.writeFooter(&buffer.writer());

// Get container format from hasher
const container_type = hasher.container();
```

## 4) Dependencies

- `std` (root import)
- `std.hash` (for CRC32 and Adler32 implementations)
- `std.io` (for Writer interface)

This file primarily provides container format handling while delegating actual compression/decompression to imported submodules, making it a coordination layer rather than implementation-heavy.