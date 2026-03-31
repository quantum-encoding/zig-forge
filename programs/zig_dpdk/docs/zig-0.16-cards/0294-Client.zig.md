# Zig HTTP Client Migration Analysis

## 1) Concept

This file implements a comprehensive HTTP(S) client for Zig's standard library. It provides connection pooling, TLS support, proxy handling, and both low-level request/response APIs as well as high-level convenience functions. The client manages connections in a thread-safe manner while individual requests are not thread-safe.

Key components include:
- **Connection pooling** with LRU cache for connection reuse
- **TLS support** (configurably disabled) with certificate bundle management
- **Proxy support** for both HTTP and HTTPS traffic
- **Request/Response abstraction** with support for chunked encoding, compression, and redirects
- **High-level `fetch` API** for simple one-shot requests

## 2) The 0.11 vs 0.16 Diff

### Explicit Allocator Requirements
- **Client struct requires allocator**: The `Client` struct now has an `allocator: Allocator` field that must be provided during initialization
- **Connection pooling allocates**: Connection pool operations require an allocator for resizing and cleanup
- **Memory management**: All connection buffers, host names, and TLS structures are explicitly allocated

### I/O Interface Changes
- **Dependency injection**: The `Client` struct requires an `io: Io` field, moving away from global I/O
- **Stream-based I/O**: Uses `Io.net.Stream` with reader/writer interfaces instead of file descriptors
- **Timeout support**: Connect operations support `Io.Timeout` parameters

### API Structure Changes
- **Factory pattern**: Connections are created via `connectTcp`, `connectUnix`, `connectProxied` methods rather than direct struct initialization
- **Request lifecycle**: `request()` returns a `Request` that must be explicitly `deinit()`ed
- **Response streaming**: Body reading uses reader interfaces with explicit buffer management

### Error Handling Changes
- **Specific error sets**: Each public function has well-defined error sets (e.g., `ConnectTcpError`, `RequestError`, `FetchError`)
- **TLS error propagation**: TLS initialization failures are explicitly handled rather than panicking

## 3) The Golden Snippet

```zig
const std = @import("std");
const http = std.http;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var io = try std.Io.init(.{});
    defer io.deinit();
    
    var client = http.Client{
        .allocator = allocator,
        .io = io,
    };
    defer client.deinit();
    
    const uri = try std.Uri.parse("https://httpbin.org/json");
    var req = try client.request(.GET, uri, .{});
    defer req.deinit();
    
    try req.sendBodiless();
    
    var redirect_buffer: [8192]u8 = undefined;
    const response = try req.receiveHead(&redirect_buffer);
    
    std.debug.print("Status: {}\n", .{response.head.status});
    std.debug.print("Content-Type: {?s}\n", .{response.head.content_type});
    
    var body_reader = response.reader(&.{});
    const body = try body_reader.readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(body);
    
    std.debug.print("Body: {s}\n", .{body});
}
```

## 4) Dependencies

- **std.mem** - Memory allocation and manipulation
- **std.Io** - I/O operations and stream interfaces
- **std.Uri** - URI parsing and manipulation
- **std.http** - HTTP protocol constants and types
- **std.net** - Network operations (via std.Io.net)
- **std.crypto** - TLS implementation and certificate handling
- **std.Thread** - Mutex for thread-safe connection pooling
- **std.debug** - Assertions and runtime safety checks

The HTTP client demonstrates Zig 0.16's emphasis on explicit resource management, dependency injection, and comprehensive error handling while maintaining high performance through connection pooling and efficient buffer management.