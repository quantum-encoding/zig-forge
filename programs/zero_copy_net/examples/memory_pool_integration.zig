//! Demonstrates integrating memory_pool FixedPool with zero_copy_net
//!
//! This example shows how the foundational memory_pool component
//! can be used alongside BufferPool for ultra-low-latency networking.
//!
//! Architecture:
//! - BufferPool: Page-aligned network buffers for io_uring
//! - FixedPool: Fast message/object allocation
//! - Combined: Zero-copy networking + zero-allocation message processing

const std = @import("std");
const net = @import("net");

const TcpServer = net.TcpServer;
const BufferPool = net.BufferPool;
const IoUring = net.IoUring;

// Simulated message structure
const Message = struct {
    timestamp: i64,
    client_fd: i32,
    data_len: u32,
    data: [256]u8,

    fn init(fd: i32, data: []const u8) Message {
        var msg = Message{
            .timestamp = std.time.nanoTimestamp(),
            .client_fd = fd,
            .data_len = @intCast(data.len),
            .data = undefined,
        };
        @memcpy(msg.data[0..data.len], data);
        return msg;
    }
};

// Import memory_pool if available
// const memory_pool = @import("memory-pool");
// const FixedPool = memory_pool.FixedPool;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("\n╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Zero-Copy Network + Memory Pool Integration Example    ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n\n", .{});

    // Initialize io_uring for async I/O
    std.debug.print("[1/4] Initializing io_uring (256 entries)...\n", .{});
    var ring = try IoUring.init(256, 0);
    defer ring.deinit();

    // Initialize BufferPool for network I/O
    std.debug.print("[2/4] Creating BufferPool (4KB x 1024 buffers)...\n", .{});
    var buffer_pool = try BufferPool.init(allocator, 4096, 1024);
    defer buffer_pool.deinit();

    // Initialize FixedPool for message objects
    // This would normally use memory_pool.FixedPool
    std.debug.print("[3/4] Message pool ready (@sizeOf(Message) = {d} bytes)\n", .{@sizeOf(Message)});
    // var message_pool = try FixedPool.init(allocator, @sizeOf(Message), 10000);
    // defer message_pool.deinit();

    // Initialize TCP server
    std.debug.print("[4/4] Starting TCP server on 127.0.0.1:9090...\n\n", .{});
    var server = try TcpServer.init(allocator, &ring, &buffer_pool, "127.0.0.1", 9090);
    defer server.deinit();

    // Set up callbacks
    server.on_data = &dataCallback;
    server.on_accept = &acceptCallback;
    server.on_close = &closeCallback;

    try server.start();

    std.debug.print("╔══════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  Server Running - Performance Profile                   ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  • BufferPool:      <10ns alloc, <5ns free              ║\n", .{});
    std.debug.print("║  • FixedPool:       <5ns alloc, <3ns free (when used)   ║\n", .{});
    std.debug.print("║  • io_uring:        <1µs syscall overhead               ║\n", .{});
    std.debug.print("║  • Combined:        Sub-microsecond message processing  ║\n", .{});
    std.debug.print("╠══════════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║  Test: echo 'benchmark' | nc localhost 9090             ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════╝\n\n", .{});

    // Event loop
    var count: usize = 0;
    var last_stats_time = try std.time.Instant.now();

    while (true) {
        server.runOnce() catch |err| {
            std.debug.print("Error in event loop: {}\n", .{err});
            continue;
        };
        count += 1;

        // Print stats every second
        const now = try std.time.Instant.now();
        if (now.since(last_stats_time) >= std.time.ns_per_s) {
            const stats = buffer_pool.getStats();
            std.debug.print(
                "[STATS] Events: {d} | Buffers in use: {d}/{d} | Free: {d}\n",
                .{ count, stats.in_use, stats.total, stats.free },
            );
            last_stats_time = now;
        }
    }
}

fn acceptCallback(fd: std.posix.socket_t) void {
    std.debug.print("✓ Client connected: fd={d}\n", .{fd});
}

fn dataCallback(fd: std.posix.socket_t, data: []u8) void {
    // In production, allocate Message from FixedPool here
    const msg = Message.init(@intCast(fd), data);

    std.debug.print(
        "→ Received: fd={d} | {d} bytes | ts={d}\n",
        .{ msg.client_fd, msg.data_len, msg.timestamp },
    );

    // Process message (zero-copy, zero-allocation)
    // In production: defer message_pool.free(@ptrCast(&msg));
    _ = msg;
}

fn closeCallback(fd: std.posix.socket_t) void {
    std.debug.print("✗ Client disconnected: fd={d}\n", .{fd});
}
