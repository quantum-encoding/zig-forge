//! Simple TCP echo server to verify stdlib IoUring integration works
//!
//! Run: zig build-exe examples/tcp_echo.zig -I src
//! Test with: echo "hello" | nc localhost 8080

const std = @import("std");
const net = @import("net");

const TcpServer = net.TcpServer;
const BufferPool = net.BufferPool;
const IoUring = net.IoUring;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("Initializing io_uring...\n", .{});
    var ring = try IoUring.init(256, 0);
    defer ring.deinit();

    std.debug.print("Creating buffer pool (4KB x 1024 buffers)...\n", .{});
    var pool = try BufferPool.init(allocator, 4096, 1024);
    defer pool.deinit();

    std.debug.print("Starting TCP server on 127.0.0.1:8080...\n", .{});
    var server = try TcpServer.init(allocator, &ring, &pool, "127.0.0.1", 8080);
    defer server.deinit();

    // Set up echo callback
    server.on_data = &echoCallback;
    server.on_accept = &acceptCallback;
    server.on_close = &closeCallback;

    try server.start();
    std.debug.print("Server listening! Press Ctrl+C to stop.\n", .{});
    std.debug.print("Test with: echo 'hello' | nc localhost 8080\n\n", .{});

    // Event loop
    var count: usize = 0;
    while (true) {
        server.runOnce() catch |err| {
            std.debug.print("Error in event loop: {}\n", .{err});
            continue;
        };
        count += 1;
        if (count % 1000 == 0) {
            const stats = pool.getStats();
            std.debug.print("Stats: {d} buffers in use, {d} events processed\n", .{ stats.in_use, count });
        }
    }
}

fn acceptCallback(fd: std.posix.socket_t) void {
    std.debug.print("[+] Client connected: fd={d}\n", .{fd});
}

fn echoCallback(fd: std.posix.socket_t, data: []u8) void {
    std.debug.print("[→] Received {d} bytes from fd={d}: {s}\n", .{ data.len, fd, data });
    // In a real implementation, we'd call server.send(fd, data) here
    // But for now, just verify we can receive data
}

fn closeCallback(fd: std.posix.socket_t) void {
    std.debug.print("[-] Client disconnected: fd={d}\n", .{fd});
}
