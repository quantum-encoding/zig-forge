//! Zig Stratum Engine
//! High-performance Bitcoin Stratum mining client showcasing Zig 0.16 capabilities
//!
//! Architecture:
//! - Zero-copy networking (io_uring on Linux)
//! - SIMD-optimized SHA256d (AVX2/AVX-512)
//! - Cache-aware thread pinning
//! - Lock-free work distribution

const std = @import("std");
const linux = std.os.linux;
const types = @import("stratum/types.zig");
const dispatch = @import("crypto/dispatch.zig");
const MiningEngine = @import("engine.zig").MiningEngine;
const EngineConfig = @import("engine.zig").EngineConfig;
const Dispatcher = @import("miner/dispatcher.zig").Dispatcher;
const Midstate = @import("crypto/sha256_midstate.zig").Midstate;
const avx512_midstate = @import("crypto/sha256_avx512_midstate.zig");
const avx2_midstate = @import("crypto/sha256_avx2_midstate.zig");

const VERSION = "0.1.0";

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

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Initialize Io context for Zig 0.16.2187
    var threaded = std.Io.Threaded.init(allocator, .{
        .environ = .{ .block = .{ .slice = @ptrCast(std.mem.span(std.c.environ)) } },
    });
    const io = threaded.io();

    const stdout_file = std.Io.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    try stdout.print(
        \\
        \\╔═══════════════════════════════════════════════════╗
        \\║   ZIG STRATUM ENGINE v{s}                    ║
        \\║   High-Performance Bitcoin Mining Client         ║
        \\║   Built with Zig 0.16 - Bleeding Edge            ║
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

    if (args.len < 4) {
        try printUsage(stdout);
        return;
    }

    const pool_url = args[1];
    const username = args[2];
    const password = args[3];

    try stdout.print("📡 Pool: {s}\n", .{pool_url});
    try stdout.print("👤 Worker: {s}\n\n", .{username});

    // Detect CPU capabilities
    try detectCPUCapabilities(stdout);
    try stdout.print("\n", .{});

    // Flush initial output
    try std.Io.Writer.flush(&stdout_writer.interface);

    // Check for benchmark mode
    if (std.mem.eql(u8, pool_url, "--benchmark")) {
        try runBenchmark(stdout, allocator);
        try std.Io.Writer.flush(&stdout_writer.interface);
        return;
    }

    // Check for demo mode (hash visualization without pool)
    if (std.mem.eql(u8, pool_url, "--demo")) {
        try runDemo(allocator);
        return;
    }

    // Create and run mining engine
    const cpu_count = try std.Thread.getCpuCount();

    const config = EngineConfig{
        .pool_url = pool_url,
        .username = username,
        .password = password,
        .num_threads = @intCast(cpu_count),
    };

    var engine = try MiningEngine.init(allocator, config);
    defer engine.deinit();

    engine.run() catch |err| {
        try stdout.print("\n⚠️  Mining stopped: {s}\n", .{@errorName(err)});
        try std.Io.Writer.flush(&stdout_writer.interface);
        return;
    };
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: stratum-engine <pool_url> <username> <password>
        \\
        \\Arguments:
        \\  pool_url   Mining pool (e.g., stratum+tcp://solo.ckpool.org:3333)
        \\  username   Worker name (usually wallet.workername)
        \\  password   Worker password (often just "x")
        \\
        \\Example:
        \\  stratum-engine stratum+tcp://solo.ckpool.org:3333 bc1qminer.worker1 x
        \\
        \\Options:
        \\  --threads N     Number of mining threads (default: CPU cores)
        \\  --cpu-affinity  Pin threads to physical cores
        \\  --benchmark     Run SHA256d benchmark and exit
        \\  --demo          Run hash visualization demo (no pool connection)
        \\
    );
}

fn detectCPUCapabilities(writer: anytype) !void {
    const cpu_count = try std.Thread.getCpuCount();
    try writer.print("🖥️  CPU Cores: {}\n", .{cpu_count});

    // Initialize dispatcher and detect SIMD level
    dispatch.init();
    const simd_level = dispatch.getLevel();

    try writer.writeAll("📊 CPU Features:\n");
    try writer.print("   ✅ SIMD: {s}\n", .{simd_level.toString()});

    // Zig 0.16 - using compile-time CPU features
    const features = @import("builtin").cpu.features;

    if (features.isEnabled(@intFromEnum(std.Target.x86.Feature.sse4_2))) {
        try writer.writeAll("   ✅ SSE4.2\n");
    }
}

fn runBenchmark(writer: anytype, allocator: std.mem.Allocator) !void {
    _ = allocator;

    try writer.writeAll("🔥 Running SHA256d SIMD benchmark...\n\n");

    const hasher = dispatch.Hasher.init();
    const simd_level = dispatch.getLevel();

    try writer.print("Active SIMD Level: {s}\n", .{simd_level.toString()});
    try writer.print("Batch Size: {}\n\n", .{hasher.getBatchSize()});

    const iterations: u64 = 1_000_000;

    // Benchmark based on detected SIMD level
    switch (simd_level) {
        .avx512 => {
            try writer.writeAll("🚀 Benchmarking AVX-512 (16-way parallel)...\n");
            var headers: [16][80]u8 = undefined;
            var hashes: [16][32]u8 = undefined;

            for (0..16) |i| {
                @memset(&headers[i], 0);
            }

            var timer = try Timer.start();
            const start = timer.read();

            var i: u64 = 0;
            while (i < iterations / 16) : (i += 1) {
                hasher.hash16(&headers, &hashes);
            }

            const elapsed = timer.read() - start;
            const total_hashes = iterations;
            const hashes_per_sec = @as(f64, @floatFromInt(total_hashes)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

            try writer.print("   ✅ {d:.2} MH/s ({} hashes in {d:.2}s)\n", .{
                hashes_per_sec / 1_000_000.0,
                total_hashes,
                @as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0,
            });

            try writer.print("\n🎯 Hash sample: ", .{});
            for (hashes[0][0..8]) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
            try writer.writeAll("...\n\n");
        },
        .avx2 => {
            try writer.writeAll("🚀 Benchmarking AVX2 (8-way parallel)...\n");
            var headers: [8][80]u8 = undefined;
            var hashes: [8][32]u8 = undefined;

            for (0..8) |i| {
                @memset(&headers[i], 0);
            }

            var timer = try Timer.start();
            const start = timer.read();

            var i: u64 = 0;
            while (i < iterations / 8) : (i += 1) {
                hasher.hash8(&headers, &hashes);
            }

            const elapsed = timer.read() - start;
            const total_hashes = iterations;
            const hashes_per_sec = @as(f64, @floatFromInt(total_hashes)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

            try writer.print("   ✅ {d:.2} MH/s ({} hashes in {d:.2}s)\n", .{
                hashes_per_sec / 1_000_000.0,
                total_hashes,
                @as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0,
            });

            try writer.print("\n🎯 Hash sample: ", .{});
            for (hashes[0][0..8]) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
            try writer.writeAll("...\n\n");
        },
        .scalar => {
            try writer.writeAll("⚠️  Benchmarking scalar (no SIMD)...\n");
            var header = [_]u8{0} ** 80;
            var hash: [32]u8 = undefined;

            var timer = try Timer.start();
            const start = timer.read();

            var i: u64 = 0;
            while (i < iterations) : (i += 1) {
                hasher.hashOne(&header, &hash);
            }

            const elapsed = timer.read() - start;
            const hashes_per_sec = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

            try writer.print("   ✅ {d:.2} MH/s ({} hashes in {d:.2}s)\n", .{
                hashes_per_sec / 1_000_000.0,
                iterations,
                @as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0,
            });

            try writer.print("\n🎯 Hash sample: ", .{});
            for (hash[0..8]) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
            try writer.writeAll("...\n\n");
        },
    }

    // Benchmark MIDSTATE optimization (skips Block 1 = ~33% faster)
    try writer.writeAll("\n🔥 Benchmarking MIDSTATE optimization...\n\n");

    // Create a test header and midstate
    var test_header: [80]u8 = undefined;
    for (0..80) |i| {
        test_header[i] = @intCast(i * 7 % 256);
    }
    const midstate = Midstate.init(&test_header);

    switch (simd_level) {
        .avx512 => {
            try writer.writeAll("🚀 Midstate AVX-512 (16-way parallel, Block 1 skipped)...\n");
            var hashes: [16][32]u8 = undefined;

            var timer = try Timer.start();
            const start = timer.read();

            var nonce: u32 = 0;
            var i: u64 = 0;
            while (i < iterations / 16) : (i += 1) {
                avx512_midstate.hashBatchWithMidstate(&midstate, nonce, &hashes);
                nonce +%= 16;
            }

            const elapsed = timer.read() - start;
            const total_hashes = iterations;
            const hashes_per_sec = @as(f64, @floatFromInt(total_hashes)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

            try writer.print("   ✅ {d:.2} MH/s ({} hashes in {d:.2}s)\n", .{
                hashes_per_sec / 1_000_000.0,
                total_hashes,
                @as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0,
            });

            try writer.print("\n🎯 Hash sample: ", .{});
            for (hashes[0][0..8]) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
            try writer.writeAll("...\n\n");
        },
        .avx2 => {
            try writer.writeAll("🚀 Midstate AVX2 (8-way parallel, Block 1 skipped)...\n");
            var hashes: [8][32]u8 = undefined;

            var timer = try Timer.start();
            const start = timer.read();

            var nonce: u32 = 0;
            var i: u64 = 0;
            while (i < iterations / 8) : (i += 1) {
                avx2_midstate.hashBatchWithMidstate(&midstate, nonce, &hashes);
                nonce +%= 8;
            }

            const elapsed = timer.read() - start;
            const total_hashes = iterations;
            const hashes_per_sec = @as(f64, @floatFromInt(total_hashes)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

            try writer.print("   ✅ {d:.2} MH/s ({} hashes in {d:.2}s)\n", .{
                hashes_per_sec / 1_000_000.0,
                total_hashes,
                @as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0,
            });

            try writer.print("\n🎯 Hash sample: ", .{});
            for (hashes[0][0..8]) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
            try writer.writeAll("...\n\n");
        },
        .scalar => {
            try writer.writeAll("⚠️  Midstate scalar (no SIMD, Block 1 skipped)...\n");
            var hash: [32]u8 = undefined;

            var timer = try Timer.start();
            const start = timer.read();

            var nonce: u32 = 0;
            var i: u64 = 0;
            while (i < iterations) : (i += 1) {
                midstate.hash(nonce, &hash);
                nonce +%= 1;
            }

            const elapsed = timer.read() - start;
            const hashes_per_sec = @as(f64, @floatFromInt(iterations)) / (@as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0);

            try writer.print("   ✅ {d:.2} MH/s ({} hashes in {d:.2}s)\n", .{
                hashes_per_sec / 1_000_000.0,
                iterations,
                @as(f64, @floatFromInt(elapsed)) / 1_000_000_000.0,
            });

            try writer.print("\n🎯 Hash sample: ", .{});
            for (hash[0..8]) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
            try writer.writeAll("...\n\n");
        },
    }
}

/// Demo mode - runs workers without pool connection for hash visualization
fn runDemo(allocator: std.mem.Allocator) !void {
    std.debug.print("🎮 Demo Mode - Hash Visualization\n", .{});
    std.debug.print("   Workers will hash and emit JSON events for interesting hashes\n\n", .{});

    const cpu_count = try std.Thread.getCpuCount();
    const num_threads: u32 = @intCast(cpu_count);

    std.debug.print("⛏️  Starting {} mining threads...\n", .{num_threads});

    var dispatcher = try Dispatcher.init(allocator, num_threads);
    defer dispatcher.deinit();

    // Start workers (they'll hash with null job = dummy headers)
    try dispatcher.start();
    std.debug.print("✅ Mining started! Watching for hashes with 16+ leading zero bits...\n\n", .{});

    // Stats reporting thread (inline)
    var last_hashes: u64 = 0;
    var uptime_seconds: u64 = 0;
    var timer = try Timer.start();

    // Run for ~60 seconds or until interrupted
    var iterations: u32 = 0;
    while (iterations < 12) : (iterations += 1) {
        var ts: linux.timespec = .{ .sec = 5, .nsec = 0 };
        _ = linux.nanosleep(&ts, null);
        uptime_seconds += 5;

        const current_hashes = dispatcher.global_stats.hashes.load(.monotonic);
        const elapsed_ns = timer.read();
        const hashes_delta = current_hashes - last_hashes;

        const hashrate = if (elapsed_ns > 0)
            @as(f64, @floatFromInt(hashes_delta)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0)
        else
            0.0;

        const shares = dispatcher.getSharesFound();

        // Scale hashrate
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

        std.debug.print(
            \\{{"type":"stats","hashrate":{d:.2},"unit":"{s}","accepted":{},"rejected":0,"uptime":{},"threads":{}}}
            \\
        , .{ scaled_rate, unit, shares, uptime_seconds, num_threads });

        last_hashes = current_hashes;
        timer.reset();
    }

    std.debug.print("\n🛑 Demo complete. Stopping workers...\n", .{});
    dispatcher.stop();
}

test "basic functionality" {
    const testing = std.testing;

    // Test target calculation
    const target = types.Target.fromNBits(0x1d00ffff);
    try testing.expect(target.bits.len == 32);

    // Test method parsing
    const method = types.Method.fromString("mining.subscribe");
    try testing.expectEqual(types.Method.mining_subscribe, method);
}
