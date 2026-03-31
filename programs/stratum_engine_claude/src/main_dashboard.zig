//! Zig Stratum Engine with Mempool Dashboard
//! Combined mining + mempool monitoring interface

const std = @import("std");
const MiningEngine = @import("engine.zig").MiningEngine;
const EngineConfig = @import("engine.zig").EngineConfig;
const MempoolMonitor = @import("bitcoin/mempool.zig").MempoolMonitor;
const Dashboard = @import("dashboard.zig").Dashboard;
const dispatch = @import("crypto/dispatch.zig");

const VERSION = "0.2.0-dashboard";

const linux = std.os.linux;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Use global single-threaded Io context for Zig 0.16.1859
    const io = std.Io.Threaded.global_single_threaded.io();

    const stdout_file = std.Io.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    try stdout.print(
        \\
        \\╔═══════════════════════════════════════════════════╗
        \\║   ZIG STRATUM ENGINE v{s}            ║
        \\║   Mining + Mempool Real-Time Dashboard           ║
        \\║   Built with Zig 0.16 + io_uring                 ║
        \\╚═══════════════════════════════════════════════════╝
        \\
        \\
    , .{VERSION});

    // Parse command line args using new iterator pattern
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    if (args.len < 5) {
        try printUsage(stdout);
        return;
    }

    const pool_url = args[1];
    const username = args[2];
    const password = args[3];
    const bitcoin_node = args[4]; // e.g., "127.0.0.1:8333"

    // Parse bitcoin node address
    const colon_idx = std.mem.indexOf(u8, bitcoin_node, ":") orelse {
        try stdout.writeAll("❌ Invalid Bitcoin node address (expected host:port)\n");
        return;
    };

    const btc_host = bitcoin_node[0..colon_idx];
    const btc_port_str = bitcoin_node[colon_idx + 1 ..];
    const btc_port = try std.fmt.parseInt(u16, btc_port_str, 10);

    try stdout.print("📡 Mining Pool: {s}\n", .{pool_url});
    try stdout.print("👤 Worker: {s}\n", .{username});
    try stdout.print("🔗 Bitcoin Node: {s}:{}\n\n", .{ btc_host, btc_port });

    // Detect CPU capabilities
    dispatch.init();
    const simd_level = dispatch.getLevel();
    const cpu_count = try std.Thread.getCpuCount();

    try stdout.print("🖥️  CPU Cores: {}\n", .{cpu_count});
    try stdout.print("📊 SIMD: {s}\n\n", .{simd_level.toString()});
    try std.Io.Writer.flush(&stdout_writer.interface);

    // Initialize mining engine
    const config = EngineConfig{
        .pool_url = pool_url,
        .username = username,
        .password = password,
        .num_threads = @intCast(cpu_count),
    };

    var engine = try MiningEngine.init(allocator, config);
    defer engine.deinit();

    // Initialize mempool monitor
    var mempool = try MempoolMonitor.init(allocator, btc_host, btc_port);
    defer mempool.deinit();

    // Set transaction callback
    mempool.setCallback(onTransactionSeen);

    // Initialize dashboard
    var dashboard = Dashboard.init(allocator);
    dashboard.setMiningEngine(&engine);
    dashboard.setMempoolMonitor(&mempool);
    dashboard.setRefreshInterval(1); // 1 second refresh

    try stdout.writeAll("🚀 Starting dashboard...\n\n");
    try std.Io.Writer.flush(&stdout_writer.interface);

    // Give user 2 seconds to read startup messages
    var ts: linux.timespec = .{ .sec = 2, .nsec = 0 };
    _ = linux.nanosleep(&ts, null);

    // Start mining engine in background
    const mining_thread = try std.Thread.spawn(.{}, miningThreadFn, .{&engine});
    defer mining_thread.join();

    // Start mempool monitor in background
    const mempool_thread = try std.Thread.spawn(.{}, mempoolThreadFn, .{&mempool});
    defer mempool_thread.join();

    // Run dashboard (blocks until Ctrl+C)
    dashboard.run() catch |err| {
        std.debug.print("\nDashboard error: {}\n", .{err});
    };

    // Cleanup
    dashboard.stop();
    engine.stop();
    mempool.deinit();
}

fn miningThreadFn(engine: *MiningEngine) void {
    engine.run() catch |err| {
        std.debug.print("Mining engine error: {}\n", .{err});
    };
}

fn mempoolThreadFn(monitor: *MempoolMonitor) void {
    monitor.run() catch |err| {
        std.debug.print("Mempool monitor error: {}\n", .{err});
    };
}

/// Callback when new transaction is seen
fn onTransactionSeen(tx_hash: [32]u8) void {
    // In dashboard mode, we don't print individual TXs (would mess up display)
    // Stats are shown in the dashboard instead
    _ = tx_hash;
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: stratum-engine-dashboard <pool_url> <username> <password> <bitcoin_node>
        \\
        \\Arguments:
        \\  pool_url       Mining pool (e.g., stratum+tcp://solo.ckpool.org:3333)
        \\  username       Worker name (usually wallet.workername)
        \\  password       Worker password (often just "x")
        \\  bitcoin_node   Bitcoin node address (e.g., 127.0.0.1:8333)
        \\
        \\Example:
        \\  stratum-engine-dashboard \
        \\    stratum+tcp://139.99.102.106:3333 \
        \\    bc1qminer.worker1 \
        \\    x \
        \\    127.0.0.1:8333
        \\
        \\Requirements:
        \\  - Running Bitcoin Core node (for mempool monitoring)
        \\  - Linux kernel 5.1+ (for io_uring)
        \\
    );
}
