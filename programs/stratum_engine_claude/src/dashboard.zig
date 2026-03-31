//! Combined Mining + Mempool Dashboard
//! Real-time statistics display for Zig Stratum Engine

const std = @import("std");
const linux = std.os.linux;
const MiningEngine = @import("engine.zig").MiningEngine;
const MempoolMonitor = @import("bitcoin/mempool.zig").MempoolMonitor;
const MempoolStats = @import("bitcoin/mempool.zig").MempoolStats;

// Zig 0.16 compatible Timer using clock_gettime
const Timer = struct {
    start_time: i128,

    pub fn start() !Timer {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return Timer{
            .start_time = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec,
        };
    }

    pub fn read(self: Timer) u64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        const now = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
        return @intCast(now - self.start_time);
    }

    pub fn reset(self: *Timer) void {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        self.start_time = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
    }
};

pub const Dashboard = struct {
    allocator: std.mem.Allocator,
    mining_engine: ?*MiningEngine,
    mempool_monitor: ?*MempoolMonitor,
    running: std.atomic.Value(bool),
    refresh_interval_ns: u64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .mining_engine = null,
            .mempool_monitor = null,
            .running = std.atomic.Value(bool).init(false),
            .refresh_interval_ns = 1_000_000_000, // 1 second default
        };
    }

    pub fn setMiningEngine(self: *Self, engine: *MiningEngine) void {
        self.mining_engine = engine;
    }

    pub fn setMempoolMonitor(self: *Self, monitor: *MempoolMonitor) void {
        self.mempool_monitor = monitor;
    }

    pub fn setRefreshInterval(self: *Self, seconds: u64) void {
        self.refresh_interval_ns = seconds * 1_000_000_000;
    }

    /// Main dashboard loop - runs in dedicated thread
    pub fn run(self: *Self) !void {
        self.running.store(true, .release);

        // Use global single-threaded Io context for Zig 0.16.1859
        const io = std.Io.Threaded.global_single_threaded.io();

        const stdout_file = std.Io.File.stdout();
        var stdout_buf: [8192]u8 = undefined;
        var stdout_writer = stdout_file.writer(io, &stdout_buf);
        const stdout = &stdout_writer.interface;

        var last_mining_hashes: u64 = 0;
        var last_mempool_tx: u64 = 0;
        var timer = try Timer.start();

        // Clear screen and hide cursor
        try stdout.writeAll("\x1b[2J\x1b[?25l");
        try std.Io.Writer.flush(&stdout_writer.interface);

        while (self.running.load(.acquire)) {
            // Move cursor to home
            try stdout.writeAll("\x1b[H");

            // Print header
            try self.printHeader(stdout);

            // Print mining stats
            if (self.mining_engine) |engine| {
                try self.printMiningStats(stdout, engine, &last_mining_hashes, &timer);
            }

            // Print mempool stats
            if (self.mempool_monitor) |monitor| {
                try self.printMempoolStats(stdout, monitor, &last_mempool_tx, &timer);
            }

            // Print footer
            try self.printFooter(stdout);

            try std.Io.Writer.flush(&stdout_writer.interface);

            // Sleep until next refresh
            var ts: linux.timespec = .{ .sec = 0, .nsec = @intCast(self.refresh_interval_ns) };
            _ = linux.nanosleep(&ts, null);
        }

        // Show cursor on exit
        try stdout.writeAll("\x1b[?25h");
        try std.Io.Writer.flush(&stdout_writer.interface);
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
    }

    fn printHeader(self: *Self, writer: anytype) !void {
        _ = self;
        try writer.writeAll(
            \\╔═══════════════════════════════════════════════════════════════════════════╗
            \\║                    ZIG STRATUM ENGINE DASHBOARD                           ║
            \\║                 Mining + Mempool Real-Time Monitor                        ║
            \\╚═══════════════════════════════════════════════════════════════════════════╝
            \\
            \\
        );
    }

    fn printMiningStats(self: *Self, writer: anytype, engine: *MiningEngine, last_hashes: *u64, timer: *Timer) !void {
        _ = self;

        try writer.writeAll("┌─ MINING STATISTICS ────────────────────────────────────────────────────┐\n");

        // Get current stats
        const current_hashes = engine.dispatcher.global_stats.hashes.load(.monotonic);
        const shares = engine.dispatcher.getSharesFound();
        const elapsed_ns = timer.read();

        // Calculate hashrate
        const hashes_delta = current_hashes - last_hashes.*;
        const hashrate = if (elapsed_ns > 0)
            @as(f64, @floatFromInt(hashes_delta)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0)
        else
            0.0;

        // Get latency
        const avg_latency = engine.stratum.getAverageLatencyUs(10);

        try writer.print(
            \\│ Hashrate:       {d:>10.2} MH/s                                         │
            \\│ Total Hashes:   {d:>10}                                                │
            \\│ Shares Found:   {d:>10}                                                │
            \\│ Mining Threads: {d:>10}                                                │
            \\│ Network Latency:{d:>10.2} µs                                           │
            \\└────────────────────────────────────────────────────────────────────────┘
            \\
            \\
        , .{
            hashrate / 1_000_000.0,
            current_hashes,
            shares,
            engine.config.num_threads,
            avg_latency,
        });

        last_hashes.* = current_hashes;
        timer.reset();
    }

    fn printMempoolStats(self: *Self, writer: anytype, monitor: *MempoolMonitor, last_tx: *u64, timer: *Timer) !void {
        _ = self;

        try writer.writeAll("┌─ MEMPOOL STATISTICS ───────────────────────────────────────────────────┐\n");

        const current_tx = monitor.stats.tx_seen.load(.monotonic);
        const blocks = monitor.stats.blocks_seen.load(.monotonic);
        const bytes = monitor.stats.bytes_received.load(.monotonic);
        const elapsed_ns = timer.read();

        // Calculate TX rate
        const tx_delta = current_tx - last_tx.*;
        const tx_rate = if (elapsed_ns > 0)
            @as(f64, @floatFromInt(tx_delta)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0)
        else
            0.0;

        try writer.print(
            \\│ TX Rate:        {d:>10.2} tx/s                                         │
            \\│ Total TX Seen:  {d:>10}                                                │
            \\│ Blocks Seen:    {d:>10}                                                │
            \\│ Bytes Received: {d:>10.2} MB                                           │
            \\└────────────────────────────────────────────────────────────────────────┘
            \\
            \\
        , .{
            tx_rate,
            current_tx,
            blocks,
            @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0),
        });

        last_tx.* = current_tx;
    }

    fn printFooter(self: *Self, writer: anytype) !void {
        _ = self;

        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        const timestamp = ts.sec;

        try writer.print(
            \\┌─ SYSTEM INFO ──────────────────────────────────────────────────────────┐
            \\│ Timestamp: {d}                                                     │
            \\│ Press Ctrl+C to stop                                                   │
            \\└────────────────────────────────────────────────────────────────────────┘
            \\
        , .{timestamp});
    }
};
