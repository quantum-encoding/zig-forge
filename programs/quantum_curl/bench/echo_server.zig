// Copyright (c) 2025 QUANTUM ENCODING LTD
// High-Performance HTTP Echo Server for Benchmarking
//
// Thread-per-connection model optimized for throughput.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

// Pre-built HTTP response - minimal overhead
const RESPONSE =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: application/json\r\n" ++
    "Content-Length: 23\r\n" ++
    "Connection: close\r\n" ++
    "\r\n" ++
    "{\"status\":\"ok\",\"id\":1}";

var request_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var start_time_ns: i128 = 0;

/// Get monotonic time in nanoseconds using clock_gettime (Zig 0.16 compatible)
fn getMonotonicNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

// Socket wrappers for Zig 0.16
fn createSocket() !posix.fd_t {
    const result = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    if (@as(isize, @bitCast(result)) < 0) return error.SocketCreationFailed;
    return @intCast(result);
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

fn bindSocket(sock: posix.fd_t, addr: anytype, addrlen: u32) !void {
    const result = linux.bind(@intCast(sock), @ptrCast(addr), addrlen);
    if (@as(isize, @bitCast(result)) < 0) return error.BindFailed;
}

fn listenSocket(sock: posix.fd_t, backlog: u31) !void {
    const result = linux.listen(@intCast(sock), backlog);
    if (@as(isize, @bitCast(result)) < 0) return error.ListenFailed;
}

fn acceptSocket(sock: posix.fd_t) !posix.fd_t {
    const result = linux.accept(@intCast(sock), null, null);
    if (@as(isize, @bitCast(result)) < 0) return error.AcceptFailed;
    return @intCast(result);
}

fn readSocket(sock: posix.fd_t, buf: []u8) !usize {
    const result = linux.read(@intCast(sock), buf.ptr, buf.len);
    const n: isize = @bitCast(result);
    if (n < 0) return error.ReadFailed;
    return @intCast(result);
}

fn writeSocket(sock: posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const result = linux.write(@intCast(sock), data[written..].ptr, data.len - written);
        const n: isize = @bitCast(result);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(result);
    }
}

fn handleClient(client_fd: posix.fd_t) void {
    defer _ = std.c.close(client_fd);

    // Read request (drain it)
    var buf: [1024]u8 = undefined;
    _ = readSocket(client_fd, &buf) catch return;

    // Send response
    writeSocket(client_fd, RESPONSE) catch return;

    // Increment counter atomically
    const count = request_count.fetchAdd(1, .monotonic) + 1;

    // Print stats every 10000 requests
    if (count % 10000 == 0) {
        const now_ns = getMonotonicNs();
        const elapsed_ns: u64 = @intCast(now_ns - start_time_ns);
        const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
        const rps = if (elapsed_ms > 0)
            @as(f64, @floatFromInt(count)) / (@as(f64, @floatFromInt(elapsed_ms)) / 1000.0)
        else
            0;
        std.debug.print("Requests: {d} | RPS: {d:.0}\n", .{ count, rps });
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Collect args into array for indexed access
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    const port: u16 = if (args.len > 1)
        try std.fmt.parseInt(u16, args[1], 10)
    else
        8888;

    // Create socket
    const sockfd = try createSocket();
    defer _ = std.c.close(sockfd);

    // Set SO_REUSEADDR
    setsockoptReuseAddr(sockfd);

    // Bind
    const addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0, // INADDR_ANY
    };
    try bindSocket(sockfd, &addr, @sizeOf(@TypeOf(addr)));

    // Listen with large backlog
    try listenSocket(sockfd, 8192);

    std.debug.print("Echo server listening on http://127.0.0.1:{d}\n", .{port});
    std.debug.print("Press Ctrl+C to stop\n\n", .{});

    start_time_ns = getMonotonicNs();

    // Accept loop with thread per connection
    while (true) {
        const client_fd = acceptSocket(sockfd) catch |err| {
            std.debug.print("Accept error: {}\n", .{err});
            continue;
        };

        // Spawn detached thread
        const thread = std.Thread.spawn(.{}, handleClient, .{client_fd}) catch {
            handleClient(client_fd);
            continue;
        };
        thread.detach();
    }
}
