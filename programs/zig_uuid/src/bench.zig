//! UUID Generation Benchmarks

const std = @import("std");
const Io = std.Io;
const uuid = @import("uuid");

/// Custom Timer implementation using std.c.clock_gettime for Zig 0.16 compatibility
const Timer = struct {
    start_time: std.c.timespec,

    pub fn start() !Timer {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) {
            return error.ClockGetTimeFailed;
        }
        return Timer{ .start_time = ts };
    }

    pub fn read(self: *Timer) u64 {
        var now: std.c.timespec = undefined;
        if (std.c.clock_gettime(.MONOTONIC, &now) != 0) {
            return 0;
        }
        const start_ns: i128 = @as(i128, self.start_time.sec) * 1_000_000_000 + self.start_time.nsec;
        const now_ns: i128 = @as(i128, now.sec) * 1_000_000_000 + now.nsec;
        return @intCast(now_ns - start_ns);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("\n=== UUID Generation Benchmarks ===\n\n", .{});

    // Warm up
    for (0..10000) |_| {
        _ = uuid.v4();
    }

    const iterations: usize = 1_000_000;

    // Benchmark v4
    {
        var timer = try Timer.start();
        for (0..iterations) |_| {
            _ = uuid.v4();
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("UUID v4:       {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Benchmark v7
    {
        var timer = try Timer.start();
        for (0..iterations) |_| {
            _ = uuid.v7();
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("UUID v7:       {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Benchmark v1
    {
        var timer = try Timer.start();
        for (0..iterations) |_| {
            _ = uuid.v1();
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("UUID v1:       {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Benchmark batch v4
    {
        var uuids: [1000]uuid.UUID = undefined;
        const batch_iterations = iterations / 1000;
        var timer = try Timer.start();
        for (0..batch_iterations) |_| {
            uuid.v4Batch(&uuids);
        }
        const elapsed = timer.read();
        const total_uuids = batch_iterations * 1000;
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(total_uuids));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("UUID v4 batch: {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Benchmark v7 batch
    {
        var uuids: [1000]uuid.UUID = undefined;
        const batch_iterations = iterations / 1000;
        var timer = try Timer.start();
        for (0..batch_iterations) |_| {
            uuid.v7Batch(&uuids);
        }
        const elapsed = timer.read();
        const total_uuids = batch_iterations * 1000;
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(total_uuids));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("UUID v7 batch: {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Benchmark parsing
    {
        var timer = try Timer.start();
        for (0..iterations) |_| {
            _ = uuid.parse("550e8400-e29b-41d4-a716-446655440000") catch unreachable;
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("UUID parse:    {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    // Benchmark toString
    {
        const id = uuid.v4();
        var timer = try Timer.start();
        for (0..iterations) |_| {
            _ = id.toString();
        }
        const elapsed = timer.read();
        const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iterations));
        const ops_per_sec = 1_000_000_000.0 / ns_per_op;
        try stdout.print("UUID toString: {d:.1} ns/op  ({d:.2}M/sec)\n", .{ ns_per_op, ops_per_sec / 1_000_000 });
    }

    try stdout.print("\n", .{});
    try stdout.flush();
}
