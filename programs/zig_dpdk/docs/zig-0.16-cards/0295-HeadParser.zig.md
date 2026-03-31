# Migration Card: std.http.HeadParser

## 1) Concept

This file implements an HTTP header parser that finds the end of HTTP headers in a byte stream. It's a state machine that processes incoming bytes to detect the CRLF-CRLF sequence (`\r\n\r\n`) that marks the end of HTTP headers. The parser operates efficiently by processing multiple bytes at once using SIMD operations when possible, and handles various edge cases in the state transitions between carriage returns and line feeds.

Key components include:
- A `State` enum tracking parser progress through different header termination patterns
- The main `feed` function that processes bytes and returns how many were consumed
- Helper functions for converting byte arrays to integers with proper endianness handling

## 2) The 0.11 vs 0.16 Diff

**No Breaking API Changes Detected**

This is a stable, self-contained parser with minimal external dependencies:

- **No Allocator Requirements**: The parser is stack-allocated and doesn't require memory allocation
- **No I/O Interface Changes**: It operates on byte slices directly without file/stream dependencies
- **No Error Handling Changes**: The `feed` function doesn't return errors, only a count of consumed bytes
- **Consistent Initialization**: Uses direct struct initialization (`HeadParser{}`) without factory functions

The implementation uses newer Zig 0.16 features like `@select` for SIMD operations and updated builtin imports, but the public API remains unchanged from previous versions.

## 3) The Golden Snippet

```zig
const std = @import("std");
const HeadParser = std.http.HeadParser;

// Initialize parser
var parser = HeadParser{};

// Feed HTTP header data
const data = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nBody content";
const bytes_consumed = parser.feed(data);

// bytes_consumed will be the index where headers end and body begins
const headers = data[0..bytes_consumed];
const body = data[bytes_consumed..];
```

## 4) Dependencies

- `std` (base standard library imports)
- `std.simd` (for vector operations)
- `builtin` (for endianness detection)

This module has minimal dependencies and is primarily self-contained, focusing on byte processing without network, memory allocation, or complex I/O requirements.