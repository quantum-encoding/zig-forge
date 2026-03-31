//! zig_ratelimit Benchmarks

const std = @import("std");
const lib = @import("ratelimit");
const compat = @import("compat.zig");

const TokenBucket = lib.TokenBucket;
const AtomicTokenBucket = lib.AtomicTokenBucket;
const LeakyBucket = lib.LeakyBucket;
const GCRA = lib.GCRA;
const SlidingWindowLog = lib.SlidingWindowLog;
const SlidingWindowCounter = lib.SlidingWindowCounter;
const FixedWindowCounter = lib.FixedWindowCounter;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);

    const allocator = init.gpa;

    try stdout_writer.interface.print("\n=== zig_ratelimit Benchmarks ===\n\n", .{});

    const iterations: usize = 10_000_000;

    // Token Bucket
    {
        try stdout_writer.interface.print("--- Token Bucket ---\n", .{});
        var bucket = TokenBucket.init(1_000_000_000, 1_000_000_000); // Very high limits

        // Warmup
        for (0..10000) |_| {
            _ = bucket.tryAcquire(1);
        }
        bucket.reset();

        var timer = compat.Timer.start();
        for (0..iterations) |_| {
            _ = bucket.tryAcquire(1);
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout_writer.interface.print("tryAcquire:   {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Atomic Token Bucket
    {
        try stdout_writer.interface.print("\n--- Atomic Token Bucket ---\n", .{});
        var bucket = AtomicTokenBucket.init(1_000_000_000, 1_000_000_000);

        var timer = compat.Timer.start();
        for (0..iterations) |_| {
            _ = bucket.tryAcquire(1);
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout_writer.interface.print("tryAcquire:   {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Leaky Bucket
    {
        try stdout_writer.interface.print("\n--- Leaky Bucket ---\n", .{});
        var bucket = LeakyBucket.init(1_000_000_000, 1_000_000_000);

        var timer = compat.Timer.start();
        for (0..iterations) |_| {
            _ = bucket.tryAcquire();
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout_writer.interface.print("tryAcquire:   {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // GCRA
    {
        try stdout_writer.interface.print("\n--- GCRA ---\n", .{});
        var gcra = GCRA.init(1_000_000_000, 1_000_000_000);

        var timer = compat.Timer.start();
        for (0..iterations) |_| {
            _ = gcra.tryAcquire();
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout_writer.interface.print("tryAcquire:   {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Sliding Window Log
    {
        try stdout_writer.interface.print("\n--- Sliding Window Log ---\n", .{});
        var swl = try SlidingWindowLog.init(allocator, 10_000_000, 60000); // 60 sec window
        defer swl.deinit();

        const swl_iterations: usize = 1_000_000;
        var timer = compat.Timer.start();
        for (0..swl_iterations) |_| {
            _ = swl.tryAcquire();
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(swl_iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout_writer.interface.print("tryAcquire:   {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Sliding Window Counter
    {
        try stdout_writer.interface.print("\n--- Sliding Window Counter ---\n", .{});
        var swc = SlidingWindowCounter.init(1_000_000_000, 60000);

        var timer = compat.Timer.start();
        for (0..iterations) |_| {
            _ = swc.tryAcquire();
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout_writer.interface.print("tryAcquire:   {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Fixed Window Counter
    {
        try stdout_writer.interface.print("\n--- Fixed Window Counter ---\n", .{});
        var fwc = FixedWindowCounter.init(1_000_000_000, 60000);

        var timer = compat.Timer.start();
        for (0..iterations) |_| {
            _ = fwc.tryAcquire();
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout_writer.interface.print("tryAcquire:   {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    try stdout_writer.interface.print("\n=== Summary ===\n", .{});
    try stdout_writer.interface.print("All limiters benchmarked with {} iterations\n", .{iterations});
    try stdout_writer.interface.print("O(1) algorithms: Token, Leaky, GCRA, Sliding Counter, Fixed Window\n", .{});
    try stdout_writer.interface.print("O(n) algorithms: Sliding Window Log\n\n", .{});
    try stdout_writer.flush();
}
