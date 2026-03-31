# Zig 0.16 Migration Guide: dev.1859 to dev.2187

API changes for migrating Zig 0.16.0-dev.1859 code to 0.16.0-dev.2187 (~300 commits of breaking changes).

## Quick Reference

| Old (1859) | New (2187) |
|------------|------------|
| `std.process.argsAlloc(allocator)` | `init.minimal.args.toSlice(allocator)` or `Args.Iterator` |
| `std.crypto.random.bytes(&buf)` | `std.c.arc4random_buf(&buf, buf.len)` (macOS) |
| `std.posix.socket()` | `std.c.socket()` or `net.IpAddress.bind()` |
| `std.posix.bind()` | `std.c.bind()` |
| `std.posix.listen()` | `std.c.listen()` |
| `std.posix.connect()` | `std.c.connect()` |
| `std.posix.sendto()` | `socket.send(io, &dest, data)` |
| `std.posix.recvfrom()` | `socket.receive(io, buf)` |
| `std.posix.nanosleep()` | `io.sleep(.fromMilliseconds(N), .awake)` |
| `std.posix.open(path, flags, mode)` | `std.posix.openatZ(c.AT.FDCWD, path, flags, mode)` |
| `std.posix.write(fd, slice)` | `std.c.write(fd, slice.ptr, slice.len)` |
| `std.posix.getenv("VAR")` | `std.c.getenv("VAR")` + `std.mem.sliceTo(ptr, 0)` |
| `std.posix.fork()` | `std.c.fork()` |
| `std.posix.execvpeZ()` | `std.c.execve()` |
| `std.posix.dup2()` | `std.c.dup2()` |
| `std.posix.setsid()` | `std.c.setsid()` |
| `std.posix.waitpid()` | `std.c.waitpid()` |
| `std.posix.epoll_*()` | `std.os.linux.epoll_*()` |
| `std.posix.send(sock, data, flags)` | `linux.sendto(sock, data.ptr, data.len, flags, null, 0)` |
| `std.posix.recv(sock, buf, flags)` | `linux.recvfrom(sock, buf.ptr, buf.len, flags, null, null)` |
| `std.c.lseek64(fd, off, whence)` | `std.c.lseek(fd, off, whence)` (portable) |
| `std.posix.sockaddr.un` | `std.c.sockaddr.un` |
| `std.posix.AF.UNIX` | `std.c.AF.UNIX` |
| `std.posix.SOCK.STREAM` | `std.c.SOCK.STREAM` |
| `std.posix.W.NOHANG` | `std.c.W.NOHANG` |
| `ArrayList.init(allocator)` | `.empty` literal, pass allocator to methods |
| `std.fs.cwd()` | Use `std.c.AT.FDCWD` with `openat` |
| `std.process.Child.init(argv, alloc)` | `std.process.spawn(io, .{ .argv = argv })` |

---

## 1. Main Function Signature

### Old
```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
}
```

### New
```zig
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Option A: Allocate slice (simpler)
    const args = try init.minimal.args.toSlice(allocator);

    // Option B: Iterator (zero allocation)
    var iter = std.process.Args.Iterator.init(init.minimal.args);
    while (iter.next()) |arg| {
        // use arg
    }
}
```

### Minimal main (no io needed)
```zig
pub fn main(init: std.process.Init.Minimal) void {
    var iter = std.process.Args.Iterator.init(init.args);
    // ...
}
```

---

## 2. Sleep / Time

### Old
```zig
std.posix.nanosleep(.{ .sec = 1, .nsec = 0 }, null);
std.time.sleep(1_000_000_000);
```

### New
```zig
// Preferred - clean, uses io
io.sleep(.fromSeconds(1), .awake) catch {};
io.sleep(.fromMilliseconds(100), .awake) catch {};

// Alternative - explicit namespace
std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};

// Verbose stdlib canonical
std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromMilliseconds(100) }, io);
```

### Thread sleep (no Io available)
```zig
// Linux only - for threads without Io context
const linux = std.os.linux;
fn sleepNs(ns: u64) void {
    const req = linux.timespec{
        .sec = @intCast(ns / 1_000_000_000),
        .nsec = @intCast(ns % 1_000_000_000),
    };
    _ = linux.nanosleep(&req, null);
}
```

---

## 3. Cryptographic Random Bytes

### Old
```zig
var buf: [32]u8 = undefined;
std.crypto.random.bytes(&buf);
```

### New (macOS)
```zig
var buf: [32]u8 = undefined;
std.c.arc4random_buf(&buf, buf.len);
```

### New (Linux)
```zig
var buf: [32]u8 = undefined;
// Use getrandom syscall or /dev/urandom
const ret = std.os.linux.getrandom(&buf, buf.len, 0);
if (ret < 0) return error.RandomFailed;
```

---

## 4. Networking (UDP)

### Old
```zig
const std = @import("std");
const posix = std.posix;

// Create socket
const sock = try posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
defer posix.close(sock);

// Bind
const bind_addr = posix.sockaddr.in{
    .family = posix.AF.INET,
    .port = std.mem.nativeToBig(u16, port),
    .addr = 0,
};
try posix.bind(sock, @ptrCast(&bind_addr), @sizeOf(@TypeOf(bind_addr)));

// Send
try posix.sendto(sock, data, 0, &dest_addr, @sizeOf(@TypeOf(dest_addr)));

// Receive
const len = try posix.recvfrom(sock, &buf, 0, &src_addr, &addr_len);
```

### New
```zig
const std = @import("std");
const net = std.Io.net;
const Io = std.Io;

// Create and bind socket
const bind_addr = net.IpAddress{ .ip4 = net.Ip4Address.unspecified(port) };
const socket = try net.IpAddress.bind(&bind_addr, io, .{
    .mode = .dgram,
    .protocol = .udp,
});
defer socket.close(io);

// Send
const dest = net.IpAddress{ .ip4 = .{ .bytes = ip_bytes, .port = port } };
try socket.send(io, &dest, data);

// Receive (blocking)
const message = try socket.receive(io, &buf);
const len = message.data.len;
const from = message.from;  // IpAddress

// Receive with timeout
const message = socket.receiveTimeout(io, &buf, .{
    .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake },
}) catch |err| switch (err) {
    error.Timeout => continue,
    else => return err,
};
```

---

## 5. Standard Output

### Old
```zig
const stdout = std.io.getStdOut().writer();
try stdout.print("Hello {s}\n", .{name});

// Or direct
try std.io.getStdOut().writeAll("Hello\n");
```

### New
```zig
// Using std.c.write directly
const msg = "Hello\n";
_ = std.c.write(std.posix.STDOUT_FILENO, msg.ptr, msg.len);

// With formatting - use a buffer
var buf: [256]u8 = undefined;
const written = std.fmt.bufPrint(&buf, "Hello {s}\n", .{name}) catch return;
_ = std.c.write(std.posix.STDOUT_FILENO, written.ptr, written.len);

// Debug output still works
std.debug.print("Hello {s}\n", .{name});
```

---

## 6. File System

### Old
```zig
const cwd = std.fs.cwd();
const file = try cwd.openFile("path/to/file", .{});
```

### New
```zig
// Use AT.FDCWD for current directory
const fd = try std.posix.openat(std.c.AT.FDCWD, "path/to/file", .{}, 0);
defer std.posix.close(fd);

// Or use Io.Dir if available
// (API still evolving - check std/Io/Dir.zig)
```

---

## 7. Testing with Io

### Old
```zig
test "my test" {
    var session = try MySession.init(std.testing.allocator);
    defer session.deinit();
}
```

### New
```zig
test "my test" {
    // std.testing.io is available in test context
    var session = try MySession.init(std.testing.allocator, std.testing.io);
    defer session.deinit();
}
```

---

## 8. Timeout Patterns

### Old
```zig
// Various ad-hoc patterns
```

### New
```zig
// Timeout struct format
const timeout = Io.Timeout{
    .duration = .{
        .raw = .fromMilliseconds(100),
        .clock = .awake,  // or .monotonic
    },
};

// Common durations
.fromMilliseconds(100)  // 100ms
.fromSeconds(5)         // 5s
.{ .nanoseconds = N }   // raw nanoseconds
```

---

## 9. Socket Options (still uses posix)

Some low-level socket options still use posix:

```zig
const posix = std.posix;

// Get raw fd from socket
const fd = socket.fd;

// Set socket option
const IP_ADD_MEMBERSHIP: u32 = switch (@import("builtin").os.tag) {
    .macos => 12,
    .linux => 35,
    else => 35,
};

const mreq = extern struct {
    multiaddr: [4]u8,
    interface: [4]u8,
}{
    .multiaddr = multicast_addr,
    .interface = .{ 0, 0, 0, 0 },
};

try posix.setsockopt(fd, posix.IPPROTO.IP, IP_ADD_MEMBERSHIP, std.mem.asBytes(&mreq));
```

---

## 10. Error Handling Changes

### Removed errors
- `error.WouldBlock` - new API handles blocking internally

### New error patterns
```zig
// Timeout handling
socket.receiveTimeout(...) catch |err| switch (err) {
    error.Timeout => { /* handle timeout */ },
    error.Canceled => { /* operation canceled */ },
    else => return err,
};
```

---

## 11. Unix Domain Sockets

### Old
```zig
const posix = std.posix;

const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
errdefer posix.close(fd);

var addr: posix.sockaddr.un = .{
    .family = posix.AF.UNIX,
    .path = undefined,
};
@memset(&addr.path, 0);
@memcpy(addr.path[0..path.len], path);

try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
try posix.listen(fd, 16);
```

### New
```zig
const c = std.c;
const posix = std.posix;

const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
if (fd < 0) return error.SocketCreateFailed;
errdefer posix.close(fd);

var addr: c.sockaddr.un = .{
    .family = c.AF.UNIX,
    .path = undefined,
};
@memset(&addr.path, 0);
@memcpy(addr.path[0..path.len], path);

if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) < 0) return error.BindFailed;
if (c.listen(fd, 16) < 0) return error.ListenFailed;
```

---

## 12. Environment Variables

### Old
```zig
const shell = posix.getenv("SHELL") orelse "/bin/bash";
```

### New
```zig
const shell = if (std.c.getenv("SHELL")) |ptr|
    std.mem.sliceTo(ptr, 0)
else
    "/bin/bash";
```

---

## 13. File Open

### Old
```zig
const fd = try posix.open("/path/to/file", .{
    .ACCMODE = .RDWR,
    .NOCTTY = true,
}, 0);
```

### New
```zig
const c = std.c;
const fd = try posix.openatZ(c.AT.FDCWD, "/path/to/file", .{
    .ACCMODE = .RDWR,
    .NOCTTY = true,
}, 0);
```

---

## 14. Process Creation (fork/exec)

### Old
```zig
const pid = try posix.fork();
if (pid == 0) {
    // Child
    posix.execvpeZ(argv[0], @ptrCast(argv.ptr), envp) catch {};
    std.c._exit(127);
} else {
    // Parent
    self.child_pid = pid;
}
```

### New
```zig
const c = std.c;

const pid = c.fork();
if (pid < 0) {
    return error.ForkFailed;
} else if (pid == 0) {
    // Child
    _ = c.execve(argv[0], @ptrCast(argv.ptr), envp);
    std.c._exit(127);
} else {
    // Parent
    self.child_pid = pid;
}
```

---

## 15. Process Control (setsid, dup2, waitpid)

### Old
```zig
_ = try posix.setsid();
try posix.dup2(slave_fd, 0);
try posix.dup2(slave_fd, 1);
try posix.dup2(slave_fd, 2);

const result = posix.waitpid(pid, posix.W.NOHANG);
if (result.pid == 0) { /* still running */ }
```

### New
```zig
const c = std.c;

if (c.setsid() < 0) return error.SetsidFailed;
if (c.dup2(slave_fd, 0) < 0) return error.Dup2Failed;
if (c.dup2(slave_fd, 1) < 0) return error.Dup2Failed;
if (c.dup2(slave_fd, 2) < 0) return error.Dup2Failed;

const result = c.waitpid(pid, null, c.W.NOHANG);
if (result == 0) { /* still running */ }

// With status extraction:
var status: c_int = 0;
_ = c.waitpid(pid, &status, 0);
const signal = status & 0x7f;  // WTERMSIG equivalent
```

---

## 16. Epoll (Linux)

### Old
```zig
const epoll_fd = try posix.epoll_create1(0);
defer posix.close(epoll_fd);

var event = std.os.linux.epoll_event{
    .events = std.os.linux.EPOLL.IN,
    .data = .{ .fd = my_fd },
};
try posix.epoll_ctl(epoll_fd, std.os.linux.EPOLL.CTL_ADD, my_fd, &event);

const n_events = posix.epoll_wait(epoll_fd, &events, 100);
```

### New
```zig
const linux = std.os.linux;
const posix = std.posix;

const epoll_ret = linux.epoll_create1(0);
if (epoll_ret > std.math.maxInt(isize)) return error.EpollCreateFailed;
const epoll_fd: i32 = @intCast(epoll_ret);
defer posix.close(epoll_fd);

var event = linux.epoll_event{
    .events = linux.EPOLL.IN,
    .data = .{ .fd = my_fd },
};
_ = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, my_fd, &event);

const wait_ret = linux.epoll_wait(epoll_fd, &events, events.len, 100);
if (wait_ret > std.math.maxInt(isize)) continue; // Error
const n_events: usize = wait_ret;
```

---

## 17. ArrayList

### Old
```zig
var list = std.ArrayList(u8).init(allocator);
defer list.deinit();
try list.append(item);
```

### New
```zig
var list: std.ArrayList(u8) = .empty;
defer list.deinit(allocator);
try list.append(allocator, item);
```

---

## Migration Checklist

- [ ] Update main signature to accept `std.process.Init`
- [ ] Replace `std.process.argsAlloc` with `init.minimal.args`
- [ ] Replace `std.crypto.random.bytes` with platform-specific alternative
- [ ] Replace `std.posix.socket/bind/listen/connect` with `std.c.*` or `linux.*`
- [ ] Replace `std.posix.send/recv` with `linux.sendto/recvfrom` wrappers
- [ ] Replace `std.posix.open()` with `std.posix.openatZ(c.AT.FDCWD, ...)`
- [ ] Replace `std.posix.write()` with `std.c.write(fd, ptr, len)` or `linux.write`
- [ ] Replace `std.posix.read()` with `std.c.read(fd, ptr, len)` or `linux.read`
- [ ] Replace `std.c.lseek64` with `std.c.lseek` (portable across macOS/Linux)
- [ ] Replace `std.posix.getenv()` with `std.c.getenv()` + `sliceTo`
- [ ] Replace `std.posix.fork/setsid/dup2/waitpid` with `std.c.*`
- [ ] Replace `std.posix.epoll_*` with `std.os.linux.epoll_*`
- [ ] Replace `std.posix.nanosleep` with `io.sleep()` or `linux.nanosleep`
- [ ] Replace `ArrayList.init(allocator)` with `.empty` literal
- [ ] Update socket address types: `posix.sockaddr.*` → `std.c.sockaddr.*`
- [ ] Update socket constants: `posix.AF.*` → `std.c.AF.*`
- [ ] Update tests to pass `std.testing.io` where needed
- [ ] Replace any `error.WouldBlock` handling
- [ ] Add `link_libc = true` to build.zig when using `std.c.*` functions
- [ ] Add `.environ = .{ .block = std.mem.span(std.c.environ) }` for `std.Io.Threaded`
- [ ] Replace `std.process.Child.init()` with `std.process.spawn(io, options)`

---

## 18. TCP Sockets (Low-Level Linux Syscalls)

When the high-level `std.Io.net` API doesn't fit your use case (e.g., thread-per-connection servers, custom connection pools), use direct Linux syscalls:

### Socket Wrapper Functions

```zig
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const SocketError = error{
    SocketCreationFailed,
    BindFailed,
    ListenFailed,
    AcceptFailed,
    ConnectionFailed,
    SendFailed,
    RecvFailed,
};

fn createSocket() SocketError!posix.fd_t {
    const result = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    if (@as(isize, @bitCast(result)) < 0) return SocketError.SocketCreationFailed;
    return @intCast(result);
}

fn bindSocket(sock: posix.fd_t, addr: anytype, addrlen: u32) SocketError!void {
    const result = linux.bind(@intCast(sock), @ptrCast(addr), addrlen);
    if (@as(isize, @bitCast(result)) < 0) return SocketError.BindFailed;
}

fn listenSocket(sock: posix.fd_t, backlog: u31) SocketError!void {
    const result = linux.listen(@intCast(sock), backlog);
    if (@as(isize, @bitCast(result)) < 0) return SocketError.ListenFailed;
}

fn acceptSocket(sock: posix.fd_t) SocketError!posix.fd_t {
    const result = linux.accept(@intCast(sock), null, null);
    if (@as(isize, @bitCast(result)) < 0) return SocketError.AcceptFailed;
    return @intCast(result);
}

fn connectSocket(sock: posix.fd_t, addr: anytype, addrlen: u32) SocketError!void {
    const result = linux.connect(@intCast(sock), @ptrCast(addr), addrlen);
    if (@as(isize, @bitCast(result)) < 0) return SocketError.ConnectionFailed;
}

fn setsockoptReuseAddr(sock: posix.fd_t) void {
    const opt_val: c_int = 1;
    _ = linux.setsockopt(
        @intCast(sock),
        linux.SOL.SOCKET,
        linux.SO.REUSEADDR,
        std.mem.asBytes(&opt_val),
        @sizeOf(c_int),
    );
}
```

### Send/Recv Wrappers

```zig
fn sendAll(sock: posix.fd_t, data: []const u8) !void {
    var sent: usize = 0;
    while (sent < data.len) {
        const result = linux.sendto(@intCast(sock), data[sent..].ptr, data.len - sent, 0, null, 0);
        const n: isize = @bitCast(result);
        if (n <= 0) return error.SendFailed;
        sent += @intCast(result);
    }
}

fn recvAll(sock: posix.fd_t, buf: []u8) !usize {
    const result = linux.recvfrom(@intCast(sock), buf.ptr, buf.len, 0, null, null);
    const n: isize = @bitCast(result);
    if (n < 0) return error.RecvFailed;
    return @intCast(result);
}
```

### Server Example

```zig
pub fn startServer(port: u16) !void {
    const sockfd = try createSocket();
    defer posix.close(sockfd);

    setsockoptReuseAddr(sockfd);

    const addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0, // INADDR_ANY
    };
    try bindSocket(sockfd, &addr, @sizeOf(@TypeOf(addr)));
    try listenSocket(sockfd, 128);

    while (true) {
        const client_fd = try acceptSocket(sockfd);
        // Handle client...
        posix.close(client_fd);
    }
}
```

---

## 19. File I/O (Low-Level Linux Syscalls)

### Read/Write Wrappers

```zig
const linux = std.os.linux;

fn writeAll(fd: posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const result = linux.write(@intCast(fd), data[written..].ptr, data.len - written);
        const n: isize = @bitCast(result);
        if (n <= 0) return error.IoError;
        written += @intCast(result);
    }
}

fn readBytes(fd: posix.fd_t, buf: []u8) !usize {
    const result = linux.read(@intCast(fd), buf.ptr, buf.len);
    const n: isize = @bitCast(result);
    if (n < 0) return error.IoError;
    return @intCast(result);
}
```

### File Seek (Cross-Platform)

```zig
// Use std.c.lseek (NOT lseek64) for cross-platform compatibility
fn getFileSize(fd: posix.fd_t) !u64 {
    const end = std.c.lseek(fd, 0, std.c.SEEK.END);
    if (end < 0) return error.IoError;
    return @intCast(end);
}

fn seekToOffset(fd: posix.fd_t, offset: i64) !void {
    const result = std.c.lseek(fd, offset, std.c.SEEK.SET);
    if (result < 0) return error.IoError;
}
```

**Note:** Use `std.c.lseek` instead of `std.c.lseek64`. The `lseek64` function doesn't exist on macOS and causes compilation failures.

---

## 20. Build Configuration

### Linking libc

When using `std.c.*` functions, you **must** enable libc linking in `build.zig`:

```zig
const exe_module = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,  // Required for std.c.* functions
});
```

This applies when using:
- `std.c.socket/bind/listen/accept/connect`
- `std.c.write/read`
- `std.c.lseek`
- `std.c.fork/execve/dup2/setsid/waitpid`
- `std.c.getenv`
- `std.c.arc4random_buf` (macOS)
- `std.c.environ`

### Environment for std.Io.Threaded

When creating `std.Io.Threaded`, you must provide the environment:

```zig
var io_impl = std.Io.Threaded.init(allocator, .{
    .environ = .{ .block = std.mem.span(std.c.environ) },
});
defer io_impl.deinit();
const io = io_impl.io();
```

---

## 21. Thread-Safe nanosleep (Linux)

For threads that don't have access to an `io` context:

```zig
const linux = std.os.linux;

fn nanosleepMs(ms: u64) void {
    var ts: linux.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = linux.nanosleep(&ts, null);
}

fn nanosleepNs(ns: u64) void {
    var ts: linux.timespec = .{
        .sec = @intCast(ns / 1_000_000_000),
        .nsec = @intCast(ns % 1_000_000_000),
    };
    _ = linux.nanosleep(&ts, null);
}

// Usage in a worker thread
fn workerThread() void {
    while (running.load(.monotonic)) {
        // Do work...
        nanosleepMs(10); // Sleep 10ms between iterations
    }
}
```

---

## 22. Argument Parsing Pattern

The new `std.process.Init` provides arguments differently. Here's the standard pattern:

```zig
pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Collect args into array for indexed access
    var args_list = std.ArrayListUnmanaged([]const u8){};
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    // Now use args[0], args[1], etc.
    if (args.len > 1) {
        // Process args[1]...
    }
}
```

---

## 23. Cross-Platform Random Bytes

### Old
```zig
var buf: [32]u8 = undefined;
std.crypto.random.bytes(&buf);
```

### New (Cross-Platform Helper)
```zig
const builtin = @import("builtin");

fn getRandomBytes(buf: []u8) void {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos => {
            std.c.arc4random_buf(buf.ptr, buf.len);
        },
        .linux => {
            _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
        },
        else => {
            for (buf) |*b| b.* = 0; // Fallback
        },
    }
}

// Usage
var nonce: [12]u8 = undefined;
getRandomBytes(&nonce);
```

---

## 24. File Size (fstat → lseek)

### Old
```zig
const stat = try std.posix.fstat(fd);
const size = stat.size;
```

### New
```zig
// Use lseek to get file size (more portable)
const end_pos = std.c.lseek(fd, 0, std.c.SEEK.END);
if (end_pos < 0) return 0;
const size: u64 = @intCast(end_pos);
```

---

## 25. Cross-Platform Socket Wrappers

For code that needs to work on both Linux and macOS:

```zig
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;

fn createSocket(sock_type: u32) !posix.fd_t {
    switch (builtin.os.tag) {
        .linux => {
            const result = linux.socket(linux.AF.INET, sock_type, 0);
            if (@as(isize, @bitCast(result)) < 0) return error.SocketCreationFailed;
            return @intCast(result);
        },
        else => {
            const fd = std.c.socket(std.c.AF.INET, sock_type, 0);
            if (fd < 0) return error.SocketCreationFailed;
            return fd;
        },
    }
}

fn recvFrom(sock: posix.fd_t, buf: []u8, addr: *posix.sockaddr, addr_len: *posix.socklen_t) !usize {
    switch (builtin.os.tag) {
        .linux => {
            const result = linux.recvfrom(@intCast(sock), buf.ptr, buf.len, 0,
                @ptrCast(@alignCast(addr)), addr_len);
            const n: isize = @bitCast(result);
            if (n < 0) return error.RecvFailed;
            return @intCast(result);
        },
        else => {
            const result = std.c.recvfrom(sock, buf.ptr, buf.len, 0, @ptrCast(addr), addr_len);
            if (result < 0) return error.RecvFailed;
            return @intCast(result);
        },
    }
}
```

---

## 26. Process Spawning (std.process.Child)

### Old
```zig
var child = std.process.Child.init(
    &[_][]const u8{ "/bin/sh", "-c", cmd },
    allocator,
);
child.stdout_behavior = .Ignore;
child.stderr_behavior = .Ignore;

try child.spawn(io);
_ = try child.wait(io);
```

### New
```zig
var child = try std.process.spawn(io, .{
    .argv = &[_][]const u8{ "/bin/sh", "-c", cmd },
    .stdout = .ignore,
    .stderr = .ignore,
});

_ = try child.wait(io);
```

**Key Changes:**
- `Child.init()` → `std.process.spawn(io, options)`
- `.stdout_behavior` / `.stderr_behavior` → `.stdout` / `.stderr` in options
- `.Ignore` → `.ignore`
- Spawn happens directly in the constructor, not as a separate step

---

## Platform Notes

### macOS
- Use `std.c.arc4random_buf()` for random bytes
- Use kqueue for event-driven I/O (equivalent to epoll)
- STUN/mDNS networking works with new API
- Use `std.c.lseek` (NOT `lseek64` - doesn't exist on macOS)

### Linux
- Use `std.os.linux.getrandom()` for random bytes
- Use `std.os.linux.epoll_*` for event-driven I/O
- Can use `linux.nanosleep()` in threads without Io context
- Use `std.os.linux.*` syscalls for low-level socket/file I/O
- PTY operations available via `/dev/ptmx`

---

## Programs Migrated

| Program | Status | Notes |
|---------|--------|-------|
| warp_gate | ✅ | UDP networking, STUN |
| chronos-stamp-macos | ✅ | Timestamps, no D-Bus |
| duck-cache-scribe-macos | ✅ | kqueue file watching |
| terminal_mux | ✅ | PTY, epoll, Unix sockets |
| chronos_engine | ✅ | Core timing/event engine |
| http_sentinel | ✅ | HTTP client library |
| distributed_kv | ✅ | TCP sockets, RPC, WAL (Linux syscall wrappers) |
| audio_forge | ✅ | ALSA audio (Linux only, macOS N/A) |
| quantum_curl | ✅ | HTTP curl-like tool, benchmarks |
| zig_port_scanner | ✅ | Simple args fix |
| zig_reverse_proxy | ✅ | link_libc added |
| warp_gate | ✅ | Cross-platform random, lseek for fstat |
| zig_dns_server | ✅ | Cross-platform socket wrappers, environ fix |

---

*Last updated: 2026-01-15 for Zig 0.16.0-dev.2187*
