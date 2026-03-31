# Migration Card: std.http.HeaderIterator

## 1) Concept

This file implements a `HeaderIterator` type for parsing HTTP headers from a byte buffer. It's a stateful iterator that sequentially processes HTTP headers from raw byte data, handling both regular headers and trailer headers (headers that come after the message body in chunked transfers). The iterator maintains position state and can differentiate between normal headers and trailer headers separated by `\r\n\r\n` boundaries.

Key components include:
- **State tracking**: Current position in the byte buffer and whether we're processing trailer headers
- **Header parsing**: Splits each line on `:` to separate header names from values
- **Value trimming**: Automatically trims whitespace from header values
- **Boundary detection**: Identifies the transition from regular headers to trailer headers

## 2) The 0.11 vs 0.16 Diff

**No significant API signature changes detected** - this appears to maintain Zig's modern patterns:

- **No explicit allocator**: The iterator works directly on provided byte slices without memory allocation
- **Simple initialization**: `init()` function takes only the byte buffer parameter
- **Iterator pattern**: Uses the conventional Zig iterator pattern with `next()` method
- **No I/O dependencies**: Pure parsing logic without file/network dependencies
- **Error handling**: Uses optional returns (`?Header`) rather than error unions

The API structure is consistent with Zig 0.16 patterns:
- Factory function: `init(bytes: []const u8) HeaderIterator`
- Iterator method: `next(it: *HeaderIterator) ?Header`
- No resource management required (no `deinit` needed)

## 3) The Golden Snippet

```zig
const std = @import("std");

// Parse headers from HTTP response data
const response_data = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 42\r\n\r\n";
var iter = std.http.HeaderIterator.init(response_data);

while (iter.next()) |header| {
    std.debug.print("Header: {s}: {s}\n", .{header.name, header.value});
}
```

## 4) Dependencies

- **std.mem**: Used extensively for string operations:
  - `indexOfPosLinear` - finding header boundaries
  - `splitScalar` - splitting name/value pairs
  - `trim` - cleaning up header values

- **std.http**: For the `Header` type definition (not directly imported in this file)

- **std.testing**: Used in test cases for validation

This module has minimal external dependencies and focuses purely on header parsing logic.