//! zig_bloom Benchmarks
//!
//! Performance benchmarks for probabilistic data structures.

const std = @import("std");
const Io = std.Io;
const lib = @import("lib.zig");

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
};

const BloomFilter = lib.BloomFilter;
const CountingBloomFilter = lib.CountingBloomFilter;
const CountMinSketch = lib.CountMinSketch;
const HyperLogLog = lib.HyperLogLog;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const allocator = init.gpa;

    try stdout.print("\n=== zig_bloom Benchmarks ===\n\n", .{});

    try benchBloomFilter(allocator, stdout);
    try benchCountingBloomFilter(allocator, stdout);
    try benchCountMinSketch(allocator, stdout);
    try benchHyperLogLog(allocator, stdout);

    try stdout.print("\n", .{});
    try stdout.flush();
}

fn benchBloomFilter(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("--- Bloom Filter ---\n", .{});

    const iterations: usize = 1_000_000;

    // Benchmark add
    {
        var bf = try BloomFilter([]const u8).initCapacity(allocator, 1_000_000, 0.01);
        defer bf.deinit();

        var timer = try Timer.start();
        for (0..iterations) |i| {
            bf.add(std.mem.asBytes(&i));
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("add:          {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Benchmark lookup
    {
        var bf = try BloomFilter([]const u8).initCapacity(allocator, 100_000, 0.01);
        defer bf.deinit();

        // Pre-populate
        for (0..50_000) |i| {
            bf.add(std.mem.asBytes(&i));
        }

        var timer = try Timer.start();
        for (0..iterations) |i| {
            _ = bf.contains(std.mem.asBytes(&i));
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("contains: {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    try stdout.print("\n", .{});
}

fn benchCountingBloomFilter(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("--- Counting Bloom Filter ---\n", .{});

    const iterations: usize = 1_000_000;

    var cbf = try CountingBloomFilter([]const u8).init(allocator, 1_000_000, 5);
    defer cbf.deinit();

    // Benchmark add
    {
        var timer = try Timer.start();
        for (0..iterations) |i| {
            cbf.add(std.mem.asBytes(&i));
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("add:          {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Benchmark lookup
    {
        var timer = try Timer.start();
        for (0..iterations) |i| {
            _ = cbf.contains(std.mem.asBytes(&i));
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("contains: {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Benchmark remove
    {
        var timer = try Timer.start();
        for (0..iterations) |i| {
            cbf.remove(std.mem.asBytes(&i));
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("remove:       {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    try stdout.print("\n", .{});
}

fn benchCountMinSketch(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("--- Count-Min Sketch ---\n", .{});

    const iterations: usize = 1_000_000;

    var cms = try CountMinSketch.init(allocator, 10000, 5);
    defer cms.deinit();

    // Benchmark add
    {
        var timer = try Timer.start();
        for (0..iterations) |i| {
            cms.add(std.mem.asBytes(&i));
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("add:          {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Benchmark estimate
    {
        var timer = try Timer.start();
        for (0..iterations) |i| {
            _ = cms.estimate(std.mem.asBytes(&i));
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("estimate:     {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    try stdout.print("\n", .{});
}

fn benchHyperLogLog(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("--- HyperLogLog ---\n", .{});

    const iterations: usize = 1_000_000;

    // Benchmark with different precisions
    inline for ([_]u6{ 10, 12, 14, 16 }) |precision| {
        var hll = try HyperLogLog.init(allocator, precision);
        defer hll.deinit();

        // Benchmark add
        var timer = try Timer.start();
        for (0..iterations) |i| {
            hll.add(i);
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;

        try stdout.print("p={d:2} add:     {d:.1} ns/op  ({d:.2}M/sec)  mem={}B  err={d:.2}%\n", .{
            precision,
            ns_per_op,
            ops_per_sec / 1_000_000,
            hll.num_registers,
            hll.standardError() * 100,
        });
    }

    // Benchmark estimate
    {
        var hll = try HyperLogLog.init(allocator, 14);
        defer hll.deinit();

        for (0..iterations) |i| {
            hll.add(i);
        }

        var timer = try Timer.start();
        const estimate_iterations: usize = 100_000;
        for (0..estimate_iterations) |_| {
            _ = hll.estimate();
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(estimate_iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;

        try stdout.print("estimate:     {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Benchmark merge
    {
        var hll1 = try HyperLogLog.init(allocator, 14);
        defer hll1.deinit();
        var hll2 = try HyperLogLog.init(allocator, 14);
        defer hll2.deinit();

        for (0..100_000) |i| {
            hll1.add(i);
            hll2.add(i + 100_000);
        }

        const merge_iterations: usize = 10_000;
        var timer = try Timer.start();
        for (0..merge_iterations) |_| {
            var temp = try HyperLogLog.init(allocator, 14);
            @memcpy(temp.registers, hll1.registers);
            try temp.merge(&hll2);
            temp.deinit();
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(merge_iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;

        try stdout.print("merge:        {d:.1} ns/op  ({d:.2}K/sec)\n", .{ ns_per_op, ops_per_sec / 1_000 });
    }
}
