# Migration Analysis: `std.http.Server`

## 1) Concept

This file implements an HTTP/1.x server that handles the complete lifecycle of a single HTTP connection. It provides the core types and functions for parsing HTTP requests, sending responses, and managing connection state. The key components are:

- `Server`: Manages the connection state with input/output streams
- `Request`: Represents a parsed HTTP request with headers, method, target, etc.
- `WebSocket`: Handles WebSocket protocol after HTTP upgrade
- Head parsing and validation for HTTP/1.0 and HTTP/1.1 protocols

The server supports persistent connections, chunked transfer encoding, request body streaming, and WebSocket upgrades while maintaining protocol compliance.

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **No explicit allocator dependency**: The server operates entirely on provided buffers and I/O streams without requiring a memory allocator
- **Buffer management**: All buffers are provided by the caller through the Reader/Writer interfaces

### I/O Interface Changes
- **Dependency injection patterns**: Server initialization takes explicit `*Reader` and `*Writer` parameters:
  ```zig
  pub fn init(in: *Reader, out: *Writer) Server
  ```
- **Stream-based I/O**: Uses the new `std.Io` module's Reader/Writer interfaces instead of old stream types

### Error Handling Changes
- **Specific error sets**: Functions return precise error unions like `ReceiveHeadError` and `ExpectContinueError`
- **Protocol-specific errors**: Error sets include HTTP-specific errors like `HttpHeadersInvalid`, `HttpExpectationFailed`

### API Structure Changes
- **Stateful initialization**: `Server.init()` creates a ready-to-use server instance
- **Request lifecycle**: `receiveHead()` → `Request` → response methods
- **Response variants**: Multiple response patterns (`respond`, `respondStreaming`, `respondWebSocket`)
- **WebSocket integration**: Built-in WebSocket upgrade handling

## 3) The Golden Snippet

```zig
const std = @import("std");
const http = std.http;

// Assuming you have network streams from a TCP connection
var server = http.Server.init(&tcp_reader, &tcp_writer);

// Receive and parse HTTP request
var request = try server.receiveHead();

// Send simple response
try request.respond("Hello, World!", .{
    .status = .ok,
    .keep_alive = true,
});

// Or handle WebSocket upgrade
if (request.upgradeRequested()) |upgrade| {
    if (upgrade == .websocket) {
        var ws = try request.respondWebSocket(.{
            .key = upgrade.websocket.?,
        });
        try ws.flush();
        // Continue with WebSocket communication
    }
}
```

## 4) Dependencies

- `std.mem` - String manipulation and memory operations
- `std.http` - HTTP protocol constants and types
- `std.Io` - I/O stream interfaces (Reader/Writer)
- `std.crypto.hash.Sha1` - WebSocket handshake computation
- `std.base64` - WebSocket accept header encoding
- `std.debug` - Runtime assertions
- `std.testing` - Unit test framework

The module has minimal dependencies and focuses on protocol implementation rather than network transport, making it suitable for various I/O backends.