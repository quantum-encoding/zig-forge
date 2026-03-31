//! Hydra GPU Benchmark
//!
//! Measures GPU throughput for the brute-force search engine.

const std = @import("std");
const queen = @import("queen");
const work_unit = @import("work_unit");
const gpu_kernel = @import("gpu_kernel");
const simd_batch = @import("simd_batch");

/// Instant using clock_gettime (Instant removed in Zig 0.16)
const Instant = struct {
    ts: std.c.timespec,

    pub fn now() error{}!Instant {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return Instant{ .ts = ts };
    }

    pub fn since(self: Instant, earlier: Instant) u64 {
        const self_ns: i128 = @as(i128, self.ts.sec) * 1_000_000_000 + self.ts.nsec;
        const earlier_ns: i128 = @as(i128, earlier.ts.sec) * 1_000_000_000 + earlier.ts.nsec;
        const diff = self_ns - earlier_ns;
        return if (diff > 0) @intCast(diff) else 0;
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("\n", .{});
    std.debug.print("HYDRA GPU BENCHMARK\n", .{});
    std.debug.print("===================\n", .{});
    std.debug.print("\n", .{});

    // Initialize GPU
    const device = try gpu_kernel.GpuDevice.init();
    device.printInfo();

    // Run benchmark with increasing search space
    const test_sizes = [_]u64{ 1_000_000, 10_000_000, 100_000_000 };
    const target = [_]u8{0xFF} ** 32; // Impossible target = no early exit

    for (test_sizes) |size| {
        std.debug.print("Benchmark: {} candidates\n", .{size});

        var q = try queen.Queen.init(allocator, 0, size, .numeric_hash, &target);
        defer q.deinit();

        const start = Instant.now() catch unreachable;
        q.run() catch |err| {
            std.debug.print("  Error: {}\n", .{err});
            continue;
        };
        const end = Instant.now() catch unreachable;

        const elapsed_ms = @as(f64, @floatFromInt(end.since(start))) / 1e6;
        const stats = q.getStats();
        const throughput = stats.throughput() / 1e6;

        std.debug.print("  Time: {d:.2} ms\n", .{elapsed_ms});
        std.debug.print("  Throughput: {d:.2}M/sec\n", .{throughput});
        std.debug.print("\n", .{});
    }
}
