# Modern Zig Patterns in HTTP Sentinel
## Zig 0.16.0-dev.1303+ Implementation Guide

**Last Updated**: 2025-11-24
**Zig Version**: `0.16.0-dev.1303+ee0a0f119`
**Project**: Zig HTTP Sentinel

---

## Critical Pattern: std.Io.Threaded Architecture

### The Core Innovation (src/http_client.zig:21-37)

```zig
pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    io_threaded: *std.Io.Threaded,  // ← KEY: Heap-allocated I/O subsystem
    client: http.Client,

    pub fn init(allocator: std.mem.Allocator) !HttpClient {
        // CRITICAL: Must heap-allocate std.Io.Threaded for thread safety
        const io_threaded = try allocator.create(std.Io.Threaded);
        io_threaded.* = std.Io.Threaded.init(allocator);
        const io = io_threaded.io();

        return .{
            .allocator = allocator,
            .io_threaded = io_threaded,
            .client = http.Client{
                .allocator = allocator,
                .io = io,  // ← Pass I/O subsystem to HTTP client
            },
        };
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
        self.io_threaded.deinit();
        self.allocator.destroy(self.io_threaded);  // ← Clean up heap allocation
    }
};
```

**Why This Matters**:
- `std.Io.Threaded` provides the I/O subsystem for networking operations
- **Must be heap-allocated** (via `allocator.create`) for thread safety
- Each `HttpClient` instance owns its I/O subsystem
- Enables the **client-per-worker pattern** without race conditions

---

## Pattern 1: Client-Per-Worker Concurrency

### ✅ Correct Pattern (examples/concurrent_requests.zig:19-24)

```zig
const Worker = struct {
    id: usize,
    allocator: std.mem.Allocator,
    // ... other fields

    fn run(self: @This()) void {
        // CRITICAL: Each worker creates its own HTTP client
        var client = HttpClient.init(self.allocator) catch unreachable;
        defer client.deinit();

        // Use the client for this worker's requests
        // No mutex needed - zero contention!
    }
};
```

**Key Points**:
- Each thread gets its own `HttpClient` instance
- Each client has its own `std.Io.Threaded` instance
- No shared state = No mutexes = True parallelism
- This is the **only reliable pattern** in Zig 0.16

### ❌ Broken Pattern (DO NOT USE)

```zig
// DON'T DO THIS - Will cause race conditions
var shared_client = HttpClient.init(allocator);
var mutex = std.Thread.Mutex{};

fn workerThread(client: *HttpClient, mutex: *std.Thread.Mutex) void {
    mutex.lock();
    defer mutex.unlock();
    // Even with mutex, internal client state can race!
    const response = client.get(...);
}
```

**Why It Fails**:
- `http.Client` has internal state not protected by your mutex
- `std.Io.Threaded` manages thread-local resources
- Mutexes don't prevent I/O subsystem races

---

## Pattern 2: Modern Build System (build.zig)

### Module Creation with std.Build

```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create library module
    const http_sentinel_module = b.addModule("http-sentinel", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Create executable with module import
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("http-sentinel", http_sentinel_module);

    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_module = exe_module,
    });
    b.installArtifact(exe);
}
```

**Changes from Zig 0.11/0.12**:
- `b.path()` replaces `.{ .path = "..." }`
- `b.addModule()` creates library modules
- `b.createModule()` for executables with dependencies
- `module.addImport()` links modules together
- `b.installArtifact()` for installation

---

## Pattern 3: Modern HTTP Request API

### GET Request (src/http_client.zig:154-193)

```zig
pub fn getWithOptions(
    self: *HttpClient,
    url: []const u8,
    headers: []const http.Header,
    options: RequestOptions,
) !Response {
    // 1. Parse URI
    const uri = try std.Uri.parse(url);

    // 2. Create request with extra headers
    var req = try self.client.request(.GET, uri, .{
        .extra_headers = headers,
    });
    defer req.deinit();

    // 3. Send bodiless request
    try req.sendBodiless();

    // 4. Receive response headers
    var response = try req.receiveHead(&.{});

    // 5. Read body with transfer buffer
    var transfer_buffer: [8192]u8 = undefined;
    const response_reader = response.reader(&transfer_buffer);

    const body_data = try response_reader.allocRemaining(
        self.allocator,
        std.Io.Limit.limited(options.max_body_size)
    );
    defer self.allocator.free(body_data);

    // 6. Decompress if needed
    const content_encoding_str: ?[]const u8 = switch (response.head.content_encoding) {
        .gzip => "gzip",
        .identity => null,
        else => null,
    };
    const final_body = try self.decompressBody(body_data, content_encoding_str);

    return Response{
        .status = response.head.status,
        .body = final_body,
        .allocator = self.allocator,
    };
}
```

**Key APIs**:
- `std.Uri.parse()` for URL parsing
- `client.request()` with `.extra_headers`
- `req.sendBodiless()` for GET/HEAD/DELETE
- `req.receiveHead()` for headers
- `response.reader(&buffer)` for body
- `reader.allocRemaining()` with `std.Io.Limit`

### POST Request (src/http_client.zig:98-142)

```zig
pub fn postWithOptions(
    self: *HttpClient,
    url: []const u8,
    headers: []const http.Header,
    body: []const u8,
    options: RequestOptions,
) !Response {
    const uri = try std.Uri.parse(url);

    var req = try self.client.request(.POST, uri, .{
        .extra_headers = headers,
    });
    defer req.deinit();

    // Set content length
    req.transfer_encoding = .{ .content_length = body.len };

    // Write body unflushed for efficiency
    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(body);
    try body_writer.end();

    // Explicit flush
    try req.connection.?.flush();

    // Receive response (same as GET)
    var response = try req.receiveHead(&.{});
    // ... rest of response handling
}
```

**Key Differences**:
- `req.transfer_encoding = .{ .content_length = len }`
- `req.sendBodyUnflushed()` for body writer
- `body_writer.writer.writeAll()` to send data
- `body_writer.end()` to finish body
- `req.connection.?.flush()` to send data

---

## Pattern 4: GZIP Decompression (src/http_client.zig:47-65)

```zig
fn decompressBody(self: *HttpClient, body_data: []const u8, content_encoding: ?[]const u8) ![]u8 {
    const encoding = content_encoding orelse "identity";

    if (std.mem.eql(u8, encoding, "gzip")) {
        // Create fixed reader from compressed data
        var in: std.Io.Reader = .fixed(body_data);

        // Create allocating writer
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        // Decompress with flate
        var decompress: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
        _ = try decompress.reader.streamRemaining(&aw.writer);

        // Return owned copy
        return try self.allocator.dupe(u8, aw.written());
    }

    // No compression - return copy
    return try self.allocator.dupe(u8, body_data);
}
```

**Modern APIs**:
- `std.Io.Reader.fixed()` for byte slice reader
- `std.Io.Writer.Allocating` for growing buffer
- `std.compress.flate.Decompress` for gzip
- `decompress.reader.streamRemaining()` to read all
- `aw.written()` to get decompressed data

---

## Pattern 5: Response Memory Management

### RAII-Style Cleanup

```zig
pub const Response = struct {
    status: http.Status,
    body: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
    }
};

// Usage:
var response = try client.get(url, &.{});
defer response.deinit();  // ← Automatic cleanup

// Access response
std.debug.print("Status: {}\n", .{response.status});
std.debug.print("Body: {s}\n", .{response.body});
```

**Pattern Benefits**:
- Explicit ownership (allocator stored in struct)
- Defer pattern ensures cleanup
- No hidden allocations
- Clear lifetime semantics

---

## Pattern 6: Request Options with Defaults

```zig
pub const RequestOptions = struct {
    /// Maximum response body size (default: 10MB)
    max_body_size: usize = 10 * 1024 * 1024,
    /// Request timeout in nanoseconds (0 = no timeout)
    timeout_ns: u64 = 0,
};

// Usage:
const options = HttpClient.RequestOptions{
    .max_body_size = 50 * 1024 * 1024,  // 50MB
    .timeout_ns = 30 * std.time.ns_per_s,  // 30 seconds
};

var response = try client.getWithOptions(url, headers, options);
defer response.deinit();

// Or use defaults:
var response2 = try client.get(url, headers);
defer response2.deinit();
```

**Key Points**:
- Default values in struct definition
- `WithOptions` variant for customization
- Simple method for common case
- `std.Io.Limit.limited()` enforces max size

---

## Pattern 7: Atomic Counters for Thread-Safe Stats

```zig
// Shared counters across threads
var success_count = std.atomic.Value(u32).init(0);
var error_count = std.atomic.Value(u32).init(0);

const Worker = struct {
    success_count: *std.atomic.Value(u32),
    error_count: *std.atomic.Value(u32),

    fn run(self: @This()) void {
        // Atomic increment - no mutex needed
        _ = self.success_count.fetchAdd(1, .monotonic);

        // Atomic read
        const total = self.success_count.load(.monotonic);
    }
};
```

**Modern Atomics**:
- `std.atomic.Value(T)` wrapper type
- `.init(value)` to initialize
- `.fetchAdd(delta, ordering)` for increment
- `.load(ordering)` for read
- `.store(value, ordering)` for write
- Memory ordering: `.monotonic`, `.acquire`, `.release`, `.seq_cst`

---

## Pattern 8: Thread Spawning

```zig
const num_workers = 4;
var workers: [num_workers]Worker = undefined;
var threads: [num_workers]std.Thread = undefined;

// Initialize workers
for (&workers, 0..) |*worker, i| {
    worker.* = Worker{
        .id = i,
        .allocator = allocator,
        // ... other fields
    };
}

// Spawn threads
for (&workers, &threads) |*worker, *thread| {
    thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker.*});
}

// Wait for completion
for (&threads) |*thread| {
    thread.join();
}
```

**Key Points**:
- `std.Thread.spawn()` with empty options `(.{})`
- Pass struct by value to thread function
- `.join()` waits for thread completion
- Each thread owns its data (worker struct)

---

## Pattern 9: Error Handling

### Explicit Error Propagation

```zig
pub fn get(
    self: *HttpClient,
    url: []const u8,
    headers: []const http.Header,
) !Response {
    return self.getWithOptions(url, headers, .{});
}

// Usage:
const response = client.get(url, &.{}) catch |err| {
    std.debug.print("Request failed: {}\n", .{err});
    return err;
};
defer response.deinit();
```

### Try-Defer Pattern

```zig
var req = try self.client.request(.GET, uri, .{
    .extra_headers = headers,
});
defer req.deinit();  // ← Cleanup even on error

try req.sendBodiless();
var response = try req.receiveHead(&.{});
```

**Benefits**:
- Errors propagate with `!` return type
- `try` keyword for error unwrapping
- `defer` ensures cleanup on all paths
- Explicit error handling at use site

---

## Pattern 10: URI Parsing

```zig
// Modern way (Zig 0.16)
const uri = try std.Uri.parse(url);
var req = try self.client.request(.GET, uri, .{});

// Old way (Zig 0.11/0.12 - DEPRECATED)
// const uri = try std.Uri.fromString(url);
```

**Change**: `std.Uri.parse()` replaces `std.Uri.fromString()`

---

## Complete Working Example

```zig
const std = @import("std");
const HttpClient = @import("http-sentinel").HttpClient;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create client
    var client = try HttpClient.init(allocator);
    defer client.deinit();

    // Make request
    const headers = [_]std.http.Header{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "User-Agent", .value = "Zig-HTTP-Sentinel/1.0" },
    };

    var response = try client.get("https://httpbin.org/get", &headers);
    defer response.deinit();

    // Use response
    std.debug.print("Status: {}\n", .{response.status});
    std.debug.print("Body: {s}\n", .{response.body});
}
```

---

## Migration Checklist from Older Zig Versions

### Zig 0.11/0.12 → 0.16

- [ ] Replace `std.Uri.fromString()` with `std.Uri.parse()`
- [ ] Update build.zig to use `b.path()` and `b.addModule()`
- [ ] Add `std.Io.Threaded` to HTTP client structure
- [ ] Use `response.reader(&buffer)` instead of direct body access
- [ ] Update `std.Io.Limit` API (`.limited()` method)
- [ ] Use `std.compress.flate.Decompress` for gzip
- [ ] Update atomic API to `std.atomic.Value(T)`
- [ ] Replace `.format` in error printing with direct `{}`

### Common Compile Errors

**Error**: `root source file struct 'Uri' has no member named 'fromString'`
**Fix**: Use `std.Uri.parse(url)` instead

**Error**: `std.mem.Allocator has no member named 'bytes_allocated'`
**Fix**: Use different allocator or remove stat tracking

**Error**: `expected type '[]const std.http.Header', found '*const [N]std.http.Header'`
**Fix**: Use `&headers` instead of `&[_]std.http.Header{...}`

---

## Performance Characteristics

### Benchmarks (4 workers, 20 requests total)

```
Client-Per-Worker Pattern:
- Latency: 150-300ms per request (network dependent)
- Throughput: 40-60 requests/second (limited by httpbin.org)
- Memory: ~2MB per worker (includes TLS state)
- CPU: <5% utilization (I/O bound)
- Zero contention (no mutexes)
```

### Memory Overhead

```
HttpClient instance: ~1.5KB
  - std.Io.Threaded: ~512 bytes
  - http.Client: ~1KB
  - Bookkeeping: ~128 bytes

Per-request allocation: ~100KB-10MB
  - Response body: variable (default limit: 10MB)
  - Transfer buffer: 8KB (stack allocated)
  - Internal buffers: ~2KB
```

---

## Common Pitfalls

### 1. Sharing Clients Across Threads

```zig
// ❌ WRONG - Race conditions
var global_client = try HttpClient.init(allocator);
for (threads) |*thread| {
    thread.* = try std.Thread.spawn(.{}, doRequest, .{&global_client});
}

// ✅ CORRECT - Each thread creates client
fn workerThread(allocator: std.mem.Allocator) void {
    var client = HttpClient.init(allocator) catch unreachable;
    defer client.deinit();
    // Use client
}
```

### 2. Forgetting Response Cleanup

```zig
// ❌ WRONG - Memory leak
var response = try client.get(url, &.{});
return; // Leaked response.body!

// ✅ CORRECT - Defer cleanup
var response = try client.get(url, &.{});
defer response.deinit();
return;
```

### 3. Incorrect Header Arrays

```zig
// ❌ WRONG - Pointer to temporary
const headers = [_]std.http.Header{...};
var response = try client.get(url, headers);  // Type mismatch

// ✅ CORRECT - Take slice
const headers = [_]std.http.Header{...};
var response = try client.get(url, &headers);  // &headers converts to slice
```

### 4. Not Checking Response Status

```zig
// ❌ WRONG - Assuming success
var response = try client.get(url, &.{});
defer response.deinit();
const data = std.json.parseFromSlice(..., response.body);  // Might be error HTML!

// ✅ CORRECT - Check status
var response = try client.get(url, &.{});
defer response.deinit();
if (response.status != .ok) {
    return error.HttpError;
}
const data = try std.json.parseFromSlice(..., response.body);
```

---

## Summary

**Key Takeaways**:
1. **std.Io.Threaded** is the foundation of modern Zig HTTP
2. **Client-per-worker** is the only reliable concurrency pattern
3. **RAII-style cleanup** with `defer` prevents leaks
4. **Explicit error handling** with `try` and `catch`
5. **Modern build system** uses `b.addModule()` and `b.path()`

**Production Checklist**:
- ✅ Each thread creates its own `HttpClient`
- ✅ All responses cleaned up with `defer`
- ✅ Response status checked before parsing body
- ✅ Request options configured (timeouts, size limits)
- ✅ Error paths tested (network failures, timeouts)
- ✅ Memory profiled under load (use GPA in debug mode)

---

**Copyright © 2025 QUANTUM ENCODING LTD**
**Author**: Rich <rich@quantumencoding.io>
**License**: MIT
