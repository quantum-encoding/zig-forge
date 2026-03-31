const std = @import("std");
const humanize = @import("humanize.zig");

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

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const stdout = std.debug;

    stdout.print("=== Zig Humanize Benchmarks ===\n\n", .{});

    // Warm up
    for (0..100) |_| {
        const result = try humanize.formatBytes(allocator, 1234567890);
        allocator.free(result);
    }

    const iterations = 10000;

    // Benchmark formatBytes
    {
        var timer = try Timer.start();
        for (0..iterations) |_| {
            const result = try humanize.formatBytes(allocator, 1234567890);
            allocator.free(result);
        }
        const elapsed = timer.read();
        const avg_ns = elapsed / iterations;
        stdout.print("formatBytes (10000 iterations):\n", .{});
        stdout.print("  Total: {d}ns\n", .{elapsed});
        stdout.print("  Average: {d}ns\n\n", .{avg_ns});
    }

    // Benchmark formatDuration
    {
        var timer = try Timer.start();
        for (0..iterations) |_| {
            const result = try humanize.formatDuration(allocator, 7530000);
            allocator.free(result);
        }
        const elapsed = timer.read();
        const avg_ns = elapsed / iterations;
        stdout.print("formatDuration (10000 iterations):\n", .{});
        stdout.print("  Total: {d}ns\n", .{elapsed});
        stdout.print("  Average: {d}ns\n\n", .{avg_ns});
    }

    // Benchmark formatNumber
    {
        var timer = try Timer.start();
        for (0..iterations) |_| {
            const result = try humanize.formatNumber(allocator, 1234567);
            allocator.free(result);
        }
        const elapsed = timer.read();
        const avg_ns = elapsed / iterations;
        stdout.print("formatNumber (10000 iterations):\n", .{});
        stdout.print("  Total: {d}ns\n", .{elapsed});
        stdout.print("  Average: {d}ns\n\n", .{avg_ns});
    }

    // Benchmark ordinalSuffix (fast, no allocation)
    {
        var timer = try Timer.start();
        var result: []const u8 = undefined;
        for (0..iterations) |i| {
            result = humanize.ordinalSuffix(21 + i);
        }
        const elapsed = timer.read();
        const avg_ns = elapsed / iterations;
        stdout.print("ordinalSuffix (10000 iterations):\n", .{});
        stdout.print("  Total: {d}ns\n", .{elapsed});
        stdout.print("  Average: {d}ns\n", .{avg_ns});
        stdout.print("  (Sample result: {s})\n\n", .{result});
    }

    // Benchmark formatOrdinal
    {
        var timer = try Timer.start();
        for (0..iterations) |_| {
            const result = try humanize.formatOrdinal(allocator, 42);
            allocator.free(result);
        }
        const elapsed = timer.read();
        const avg_ns = elapsed / iterations;
        stdout.print("formatOrdinal (10000 iterations):\n", .{});
        stdout.print("  Total: {d}ns\n", .{elapsed});
        stdout.print("  Average: {d}ns\n\n", .{avg_ns});
    }

    // Benchmark formatPercentage
    {
        var timer = try Timer.start();
        for (0..iterations) |_| {
            const result = try humanize.formatPercentage(allocator, 33.33);
            allocator.free(result);
        }
        const elapsed = timer.read();
        const avg_ns = elapsed / iterations;
        stdout.print("formatPercentage (10000 iterations):\n", .{});
        stdout.print("  Total: {d}ns\n", .{elapsed});
        stdout.print("  Average: {d}ns\n\n", .{avg_ns});
    }

    // Benchmark formatRelativeTime
    {
        var timer = try Timer.start();
        for (0..iterations) |_| {
            const result = try humanize.formatRelativeTime(allocator, 7200, .{});
            allocator.free(result);
        }
        const elapsed = timer.read();
        const avg_ns = elapsed / iterations;
        stdout.print("formatRelativeTime (10000 iterations):\n", .{});
        stdout.print("  Total: {d}ns\n", .{elapsed});
        stdout.print("  Average: {d}ns\n\n", .{avg_ns});
    }

    // Benchmark formatList
    {
        const items = [_][]const u8{ "apple", "banana", "cherry" };
        var timer = try Timer.start();
        for (0..iterations) |_| {
            const result = try humanize.formatList(allocator, &items);
            allocator.free(result);
        }
        const elapsed = timer.read();
        const avg_ns = elapsed / iterations;
        stdout.print("formatList (10000 iterations):\n", .{});
        stdout.print("  Total: {d}ns\n", .{elapsed});
        stdout.print("  Average: {d}ns\n\n", .{avg_ns});
    }

    stdout.print("Benchmarking complete!\n", .{});
}
