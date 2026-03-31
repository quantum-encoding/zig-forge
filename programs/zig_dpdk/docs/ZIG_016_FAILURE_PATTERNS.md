# Zig 0.16.0-dev.1484 Breaking Change Patterns

Generated: 2025-11-29

This document catalogs the breaking API changes discovered when upgrading from Zig 0.16.0-dev.1303 to 0.16.0-dev.1484.

---

## Pattern 1: `std.time.milliTimestamp()` Removed

### Error Message
```
error: root source file struct 'time' has no member named 'milliTimestamp'
    const start = std.time.milliTimestamp();
```

### Failing Code
```zig
const start = std.time.milliTimestamp();
// ... do work ...
const elapsed = std.time.milliTimestamp() - start;
```

### Affected Files
- `http_sentinel/examples/ai_providers_demo.zig:93`

### Analysis
`std.time.milliTimestamp()` was removed from the standard library. Must use `std.posix.clock_gettime()` instead.

---

## Pattern 2: `std.time.nanoTimestamp()` Removed

### Error Message
```
error: root source file struct 'time' has no member named 'nanoTimestamp'
```

### Failing Code
```zig
const timestamp = std.time.nanoTimestamp();
```

### Analysis
Similar to `milliTimestamp`, `nanoTimestamp` was also removed. Use `std.posix.clock_gettime(std.posix.CLOCK.REALTIME)` as replacement.

---

## Pattern 3: `ArrayList.appendSlice()` Signature Changed

### Error Message
```
error: member function expected 2 argument(s), found 1
                '"' => try result.appendSlice("\\\""),
note: function declared here
        pub fn appendSlice(self: *Self, gpa: Allocator, items: []const T) Allocator.Error!void {
```

### Failing Code
```zig
var result = std.ArrayList(u8){};
defer result.deinit(allocator);

for (input) |char| {
    switch (char) {
        '"' => try result.appendSlice("\\\""),   // ERROR: missing allocator
        '\\' => try result.appendSlice("\\\\"),
        '\n' => try result.appendSlice("\\n"),
        else => try result.append(char),
    }
}
```

### Affected Files
- `http_sentinel/examples/anthropic_client.zig:213-218`

### Analysis
`std.ArrayList` methods (`append`, `appendSlice`, etc.) now require an explicit allocator argument. The allocator is no longer stored in the struct.

**New ArrayList initialization pattern:**
```zig
var result = std.ArrayList(u8).empty;  // Not std.ArrayList(u8){}
```

---

## Pattern 4: `HttpClient.init()` Returns Error Union

### Error Message
```
error: no field or member function named 'get' in '@typeInfo(...).error_union.error_set!http_client.HttpClient'
note: consider using 'try', 'catch', or 'if'
```

### Failing Code
```zig
var client = HttpClient.init(allocator);  // Returns !HttpClient, not HttpClient
defer client.deinit();

var response = try client.get(  // ERROR: client is error union, not unwrapped
    "https://httpbin.org/get",
    &headers,
);
```

### Affected Files
- `http_sentinel/examples/basic.zig:32,40`
- `http_sentinel/examples/ai_conversation.zig:55`
- `http_sentinel/examples/anthropic_client.zig:26`

### Analysis
`HttpClient.init()` returns `!HttpClient` (error union). Must unwrap with `try`:

```zig
var client = try HttpClient.init(allocator);  // Correct
```

---

## Pattern 5: Variable Shadowing Now an Error

### Error Message
```
error: local constant shadows declaration of 'c'
        const c = @cImport({
              ^
note: declared here
const c = @cImport({
```

### Failing Code
```zig
// File-level constant
const c = @cImport({
    @cInclude("mbedtls/net_sockets.h");
    @cInclude("mbedtls/ssl.h");
    // ...
});

// Later in a function...
fn connectWebSocket(...) !void {
    // ...

    // ERROR: shadows the outer 'c'
    const c = @cImport({
        @cInclude("sys/types.h");
        @cInclude("sys/socket.h");
        @cInclude("netdb.h");
    });
    // ...
}
```

### Affected Files
- `stratum_engine_claude/src/execution/exchange_client.zig:18,443`

### Analysis
Zig 0.16 now treats variable shadowing as a compile error. Previously this was allowed. Must rename inner declarations to avoid collision.

---

## Pattern 6: `posix.accept()` Error Set Changed

### Error Message
```
error: expected type 'error{BlockedByFirewall,Canceled,ConnectionAborted,NetworkDown,
ProcessFdQuotaExceeded,ProtocolFailure,SystemFdQuotaExceeded,SystemResources,Unexpected,WouldBlock}',
found 'error{SocketNotListening}'
                .INVAL => return error.SocketNotListening,
```

### Failing Code
```zig
const client_fd = posix.accept(sockfd, &client_addr, &client_addr_len, 0) catch {
    std.debug.print("⚠️  Accept error\n", .{});
    continue;
};
```

### Affected Files
- `chronos_engine/src/conductor-daemon.zig:478`
- `quantum_curl/bench/echo_server.zig:86`

### Analysis
The error set for `posix.accept()` changed. `SocketNotListening` is a new error that's not in the expected union. This is a standard library internal change - user code using `catch` blocks should still work, but code that explicitly handles specific errors may need updating.

The existing `catch` pattern above should work - this error appears to be in std lib internal error handling. May need to wait for stdlib stabilization or use `catch |_|` pattern.

---

## Pattern 7: `std.fs.File.readAll()` Removed

### Error Message
```
error: no field or member function named 'readAll' in 'fs.File'
```

### Failing Code
```zig
var buf: [1024 * 1024]u8 = undefined;
const bytes_read = try child.stdout.?.readAll(&buf);
```

### Analysis
`readAll` was removed from `std.fs.File`. Must use a manual read loop:

```zig
var buf: [1024 * 1024]u8 = undefined;
var total_read: usize = 0;
while (true) {
    const bytes_read = try child.stdout.?.read(buf[total_read..]);
    if (bytes_read == 0) break;
    total_read += bytes_read;
}
```

---

## Pattern 8: `std.time.timestamp()` Removed

### Error Message
```
error: root source file struct 'time' has no member named 'timestamp'
```

### Failing Code
```zig
const now = std.time.timestamp();
```

### Affected Files
- `financial_engine/src/runaway_protection.zig`

### Solution
Create a helper function using `clock_gettime`:

```zig
fn getTimestamp() i64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch return 0;
    return ts.sec;
}
```

---

## Pattern 9: `std.Thread.sleep()` Removed

### Error Message
```
error: root source file struct 'Thread' has no member named 'sleep'
```

### Failing Code
```zig
std.Thread.sleep(1 * std.time.ns_per_ms);  // Sleep for 1ms
```

### Affected Files
- `financial_engine/src/hft_alpaca_real.zig`
- `financial_engine/src/alpaca_websocket_real.zig`

### Solution
Use `std.posix.nanosleep()`:

```zig
std.posix.nanosleep(0, 1 * std.time.ns_per_ms);  // (seconds, nanoseconds)
```

---

## Summary of Breaking Changes

| API | Status | Replacement |
|-----|--------|-------------|
| `std.time.milliTimestamp()` | Removed | `std.posix.clock_gettime()` |
| `std.time.nanoTimestamp()` | Removed | `std.posix.clock_gettime()` |
| `std.time.timestamp()` | Removed | `std.posix.clock_gettime().sec` |
| `std.Thread.sleep(ns)` | Removed | `std.posix.nanosleep(0, ns)` |
| `ArrayList.appendSlice(items)` | Signature changed | `ArrayList.appendSlice(allocator, items)` |
| `ArrayList.append(item)` | Signature changed | `ArrayList.append(allocator, item)` |
| `ArrayList{}` initialization | Changed | `ArrayList.empty` |
| `std.fs.File.readAll()` | Removed | Manual read loop |
| Variable shadowing | Now error | Rename variables |
| `posix.accept()` error set | Changed | stdlib internal - may resolve |

---

## Winning Patterns (Verified Solutions)

These are the replacement patterns that have been tested and confirmed working:

### Timestamp Replacement Pattern

**Before (broken):**
```zig
const now = std.time.timestamp();
const millis = std.time.milliTimestamp();
const nanos = std.time.nanoTimestamp();
```

**After (working):**
```zig
fn getTimestamp() i64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch return 0;
    return ts.sec;
}

fn getMilliTimestamp() i64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch return 0;
    return ts.sec * 1000 + @divFloor(ts.nsec, 1_000_000);
}

fn getNanoTimestamp() i128 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch return 0;
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}
```

### Sleep Replacement Pattern

**Before (broken):**
```zig
std.Thread.sleep(100 * std.time.ns_per_ms);  // Sleep 100ms
```

**After (working):**
```zig
std.posix.nanosleep(0, 100 * std.time.ns_per_ms);  // (seconds, nanoseconds)
```

### ArrayList Initialization and Method Pattern

**Before (broken):**
```zig
var list = std.ArrayList(u8){};
defer list.deinit(allocator);
try list.append('a');
try list.appendSlice("hello");
```

**After (working):**
```zig
var list = std.ArrayList(u8).empty;
defer list.deinit(allocator);
try list.append(allocator, 'a');
try list.appendSlice(allocator, "hello");
```

### Variable Shadowing Fix

**Before (broken):**
```zig
const c = @cImport({ @cInclude("mbedtls/ssl.h"); });

fn foo() void {
    const c = @cImport({ @cInclude("netdb.h"); });  // ERROR: shadows outer 'c'
}
```

**After (working):**
```zig
const c = @cImport({ @cInclude("mbedtls/ssl.h"); });

fn foo() void {
    const dns_c = @cImport({ @cInclude("netdb.h"); });  // Renamed to avoid shadowing
}
```

### Accept Error Set - Stdlib Patch Required

For `SocketNotListening` error, patch the Zig stdlib at `lib/std/Io/net.zig`:

```zig
pub const AcceptError = error{
    // ... existing errors ...
    /// The socket is not listening for connections (EINVAL on accept).
    SocketNotListening,
} || Io.UnexpectedError || Io.Cancelable;
```

### Connect Timeout - Stdlib Patch Required

For posix connect timeout support, add to `lib/std/Io/Threaded.zig`:

```zig
fn posixConnectWithTimeout(
    t: *Threaded,
    socket_fd: posix.socket_t,
    addr: *const posix.sockaddr,
    addr_len: posix.socklen_t,
    timeout_ns: u64,
) !void {
    // Set socket to non-blocking
    const flags = posix.fcntl(socket_fd, .F_GETFL, 0);
    _ = posix.fcntl(socket_fd, .F_SETFL, @as(u32, @bitCast(flags)) | posix.O.NONBLOCK);

    // Initiate connection
    posix.connect(socket_fd, addr, addr_len) catch |err| switch (err) {
        error.WouldBlock => {
            // Wait for connection with poll
            var fds = [1]posix.pollfd{.{
                .fd = socket_fd,
                .events = posix.POLL.OUT,
                .revents = 0,
            }};
            const timeout_ms: i32 = @intCast(@divFloor(timeout_ns, std.time.ns_per_ms));
            const poll_result = posix.poll(&fds, timeout_ms) catch return error.NetworkUnreachable;
            if (poll_result == 0) return error.ConnectionTimedOut;

            // Check for errors via getsockopt
            var err_code: i32 = 0;
            var err_len: posix.socklen_t = @sizeOf(i32);
            _ = posix.getsockopt(socket_fd, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&err_code), &err_len) catch return error.NetworkUnreachable;
            if (err_code != 0) return error.ConnectionRefused;
        },
        else => return err,
    };

    // Restore blocking mode
    _ = posix.fcntl(socket_fd, .F_SETFL, flags);
}
```
