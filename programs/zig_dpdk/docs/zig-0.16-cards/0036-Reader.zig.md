# Migration Card: std.Io.Reader

## 1) Concept

This file implements a buffered reader interface for Zig's I/O system. It provides a generic reader abstraction with configurable buffering behavior through a virtual table (VTable) system. The reader supports various operations including streaming data to writers, discarding bytes, reading into multiple buffers, and handling different data types with endian awareness.

Key components include:
- The main `Reader` struct with buffer management and seek tracking
- A `VTable` interface for custom reader implementations
- Comprehensive reading operations (bytes, integers, structs, delimited data)
- Memory allocation integration for reading into allocated buffers
- Error handling with specific error sets for different operations

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **Allocator passing**: Functions like `allocRemaining`, `appendRemaining`, `readAlloc`, and `readSliceEndianAlloc` now require explicit `Allocator` parameters
- **Error set changes**: Functions returning allocated memory include `Allocator.Error` in their error sets
- **ArrayList integration**: Uses `ArrayList` and aligned array lists for buffer management

### I/O Interface Changes
- **VTable-based architecture**: Uses function pointer tables for stream operations rather than interface inheritance
- **Writer dependency injection**: `stream*` functions accept `*Writer` parameters for output
- **Limit-based operations**: Uses `Limit` type for bounded reading operations

### Error Handling Changes
- **Specific error sets**: Different operations have tailored error sets (`StreamError`, `Error`, `ShortError`, `RebaseError`)
- **EndOfStream handling**: Explicit end-of-stream detection rather than relying on return values
- **StreamTooLong errors**: For operations with size limits

### API Structure Changes
- **Factory functions**: `fixed()` and `limited()` constructors instead of direct struct initialization
- **VTable implementation**: Custom readers implement VTable functions rather than overriding methods
- **Buffer management**: Explicit buffer passing in constructors rather than internal allocation

## 3) The Golden Snippet

```zig
const std = @import("std");

// Create a reader from fixed data
var reader = std.Io.Reader.fixed("Hello, World!");

// Read bytes one by one
const first_byte = try reader.takeByte();
const second_byte = try reader.takeByte();

// Read a specific number of bytes
const remaining = try reader.take(11);

// Use with allocator for dynamic reading
var buffer = std.ArrayList(u8).init(std.heap.page_allocator);
defer buffer.deinit();

try reader.appendRemainingUnlimited(std.heap.page_allocator, &buffer);
```

## 4) Dependencies

- `std.mem` - For allocator interface and memory operations
- `std.array_list` - For aligned buffer management
- `std.debug` - For assertions
- `std.testing` - For test utilities
- `std.math` - For mathematical operations and casting
- `std.builtin` - For endianness and type information

This file represents a significant evolution in Zig's I/O system, moving from simpler reader interfaces to a more flexible, VTable-based architecture with explicit memory management and comprehensive error handling.