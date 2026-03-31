//! Mining Engine - Main coordinator
//! Connects Stratum client with worker threads for live mining

const std = @import("std");
const linux = std.os.linux;
const types = @import("stratum/types.zig");
const StratumClient = @import("stratum/client.zig").StratumClient;
const Dispatcher = @import("miner/dispatcher.zig").Dispatcher;
const MiningStats = @import("metrics/stats.zig").MiningStats;

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

pub const EngineConfig = struct {
    pool_url: []const u8,
    username: []const u8,
    password: []const u8,
    num_threads: u32,
};

pub const MiningEngine = struct {
    allocator: std.mem.Allocator,
    config: EngineConfig,

    stratum: StratumClient,
    dispatcher: Dispatcher,
    stats: MiningStats,

    running: std.atomic.Value(bool),
    stats_thread: ?std.Thread,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: EngineConfig) !Self {
        const credentials = types.Credentials{
            .url = config.pool_url,
            .username = config.username,
            .password = config.password,
        };

        return .{
            .allocator = allocator,
            .config = config,
            .stratum = try StratumClient.init(allocator, credentials),
            .dispatcher = try Dispatcher.init(allocator, config.num_threads),
            .stats = MiningStats.init(),
            .running = std.atomic.Value(bool).init(false),
            .stats_thread = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stratum.deinit();
        self.dispatcher.deinit();
    }

    /// Main mining loop - connects to pool and starts mining
    pub fn run(self: *Self) !void {
        self.running.store(true, .release);

        // io_uring client connects during init
        // Use global single-threaded Io context for Zig 0.16.1859
        const io = std.Io.Threaded.global_single_threaded.io();

        const stdout_file = std.Io.File.stdout();
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer = stdout_file.writer(io, &stdout_buf);
        const stdout = &stdout_writer.interface;

        try stdout.print("✅ Connected via io_uring!\n", .{});

        // Step 2: Subscribe
        try stdout.print("📝 Subscribing to mining...\n", .{});

        self.stratum.subscribe() catch |err| {
            try stdout.print("❌ Subscribe failed: {}\n", .{err});
            return err;
        };

        try stdout.print("✅ Subscribed!\n", .{});

        // Step 3: Authorize
        try stdout.print("🔐 Authorizing worker: {s}\n", .{self.config.username});

        self.stratum.authorize() catch |err| {
            try stdout.print("❌ Authorization failed: {}\n", .{err});
            return err;
        };

        try stdout.print("✅ Authorized!\n\n", .{});

        // Step 4: Start mining threads
        try stdout.print("⛏️  Starting {} mining threads...\n", .{self.config.num_threads});
        try self.dispatcher.start();
        try stdout.print("✅ Mining started!\n\n", .{});

        // Step 5: Start statistics thread
        self.stats_thread = try std.Thread.spawn(.{}, statsLoop, .{self});

        // Flush output
        try std.Io.Writer.flush(&stdout_writer.interface);

        // Main loop: receive jobs and distribute to workers
        var job_count: u32 = 0;
        while (self.running.load(.acquire)) {
            // Try to receive a job from pool
            const job_result = self.stratum.receiveJob() catch |err| {
                // Handle disconnection gracefully
                std.debug.print("⚠️ receiveJob error: {s} (after {} jobs)\n", .{ @errorName(err), job_count });
                self.stop();
                return err;
            };

            if (job_result) |job| {
                job_count += 1;
                std.debug.print("✅ Job #{} received, dispatching to workers...\n", .{job_count});
                const target = types.Target.fromNBits(job.nbits);
                self.dispatcher.updateJob(job, target);
            }

            // Small sleep to avoid busy loop (100ms)
            var ts1: linux.timespec = .{ .sec = 0, .nsec = 100_000_000 };
            _ = linux.nanosleep(&ts1, null);
        }
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
        self.dispatcher.stop();

        if (self.stats_thread) |thread| {
            thread.join();
        }
    }

    /// Background thread for printing statistics
    fn statsLoop(self: *Self) void {
        var last_hashes: u64 = 0;
        var uptime_seconds: u64 = 0;
        var timer = Timer.start() catch return;

        while (self.running.load(.acquire)) {
            // Sleep for 5 seconds
            var ts2: linux.timespec = .{ .sec = 5, .nsec = 0 };
            _ = linux.nanosleep(&ts2, null);
            uptime_seconds += 5;

            // Calculate hashrate
            const current_hashes = self.dispatcher.global_stats.hashes.load(.monotonic);
            const elapsed_ns = timer.read();
            const hashes_delta = current_hashes - last_hashes;

            const hashrate = if (elapsed_ns > 0)
                @as(f64, @floatFromInt(hashes_delta)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0)
            else
                0.0;

            // Get shares stats
            const shares = self.dispatcher.getSharesFound();

            // Get latency metrics
            const avg_latency = self.stratum.getAverageLatencyUs(10);

            // Determine unit and scale hashrate
            var scaled_rate: f64 = hashrate;
            var unit: []const u8 = "H/s";
            if (hashrate >= 1_000_000_000) {
                scaled_rate = hashrate / 1_000_000_000.0;
                unit = "GH/s";
            } else if (hashrate >= 1_000_000) {
                scaled_rate = hashrate / 1_000_000.0;
                unit = "MH/s";
            } else if (hashrate >= 1_000) {
                scaled_rate = hashrate / 1_000.0;
                unit = "KH/s";
            }

            // Output JSON stats for dashboard integration
            std.debug.print(
                \\{{"type":"stats","hashrate":{d:.2},"unit":"{s}","accepted":{},"rejected":0,"uptime":{},"threads":{},"latency_us":{d:.2}}}
                \\
            , .{
                scaled_rate,
                unit,
                shares,
                uptime_seconds,
                self.config.num_threads,
                avg_latency,
            });

            last_hashes = current_hashes;
            timer.reset();
        }
    }
};
