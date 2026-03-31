# Migration Card: std.http.ChunkParser

## 1) Concept

This file implements a state machine parser for HTTP chunked transfer encoding. The `ChunkParser` struct tracks parsing state through a finite state machine that processes chunk headers (containing chunk size in hexadecimal) and chunk data. The key components are the state enum tracking parsing progress, chunk length storage, and the main `feed` method that incrementally processes input bytes.

The parser handles the chunked encoding format where data is sent in chunks prefixed with their size in hex, followed by optional extensions, CRLF, the actual data, and finally another CRLF. It validates syntax and transitions between states for header parsing, data reading, and suffix processing.

## 2) The 0.11 vs 0.16 Diff

**Explicit Allocator Requirements**: No allocator dependencies - this is a pure state machine parser that operates on input slices without memory allocation.

**I/O Interface Changes**: No I/O interfaces - operates directly on byte slices. The `feed` method processes bytes incrementally, making it suitable for streaming scenarios.

**Error Handling Changes**: Uses state-based error indication rather than Zig's error types. The parser transitions to `.invalid` state on syntax errors instead of returning error values.

**API Structure Changes**: 
- Uses struct instance initialization (`init` constant) rather than factory functions
- Maintains internal state across multiple `feed` calls for incremental parsing
- No `open`/`close` methods - simple state machine lifecycle

The main public API difference from typical 0.11 patterns is the use of a constant `init` instance rather than an `init()` function, and state-based error handling instead of error return types.

## 3) The Golden Snippet

```zig
const std = @import("std");

pub fn main() void {
    var parser = std.http.ChunkParser.init;
    const chunk_data = "1A\r\nThis is 26 bytes of data\r\n";
    
    const bytes_consumed = parser.feed(chunk_data);
    
    // After feeding header, parser is ready for chunk data
    if (parser.state == .data) {
        std.debug.print("Chunk size: {}\n", .{parser.chunk_len});
        std.debug.print("Header consumed {} bytes\n", .{bytes_consumed});
    }
}
```

## 4) Dependencies

- `std` (root import only)
- `std.testing` (test-only dependency)

No heavy external dependencies - this is a self-contained parser implementation.