//! Benchmark Suite for zig_silicon
//!
//! Performance benchmarks for visualization generation.

const std = @import("std");
const bitfield_viz = @import("bitfield_viz.zig");

// ============================================================================
// Benchmark Utilities
// ============================================================================

const BenchResult = struct {
    name: []const u8,
    iterations: u64,
    total_ns: u64,
    avg_ns: u64,
    min_ns: u64,
    max_ns: u64,
};

fn runBenchAlloc(
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    comptime iterations: u64,
    func: *const fn (std.mem.Allocator) anyerror!void,
) BenchResult {
    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    // Warmup
    for (0..10) |_| {
        func(allocator) catch {};
    }

    // Benchmark
    for (0..iterations) |_| {
        const start = std.time.nanoTimestamp();
        func(allocator) catch {};
        const end = std.time.nanoTimestamp();

        const elapsed: u64 = @intCast(end - start);
        total_ns += elapsed;
        min_ns = @min(min_ns, elapsed);
        max_ns = @max(max_ns, elapsed);
    }

    return .{
        .name = name,
        .iterations = iterations,
        .total_ns = total_ns,
        .avg_ns = total_ns / iterations,
        .min_ns = min_ns,
        .max_ns = max_ns,
    };
}

fn printResult(result: BenchResult) void {
    std.debug.print(
        \\{s}:
        \\  Iterations: {d}
        \\  Total: {d}ns ({d:.2}ms)
        \\  Average: {d}ns ({d:.3}ms)
        \\  Min: {d}ns
        \\  Max: {d}ns
        \\
    , .{
        result.name,
        result.iterations,
        result.total_ns,
        @as(f64, @floatFromInt(result.total_ns)) / 1_000_000.0,
        result.avg_ns,
        @as(f64, @floatFromInt(result.avg_ns)) / 1_000_000.0,
        result.min_ns,
        result.max_ns,
    });
}

// ============================================================================
// Benchmarks
// ============================================================================

fn benchSmallSvg(allocator: std.mem.Allocator) !void {
    const fields = [_]bitfield_viz.Field{
        .{ .name = "enable", .bits = 1 },
        .{ .name = "mode", .bits = 2 },
        .{ .name = "reserved", .bits = 5 },
    };

    const output = try bitfield_viz.generateSvg(allocator, "SMALL_REG", &fields);
    allocator.free(output);
}

fn benchMediumSvg(allocator: std.mem.Allocator) !void {
    const fields = [_]bitfield_viz.Field{
        .{ .name = "F0", .bits = 1 },
        .{ .name = "F1", .bits = 1 },
        .{ .name = "F2", .bits = 1 },
        .{ .name = "F3", .bits = 1 },
        .{ .name = "F4", .bits = 1 },
        .{ .name = "F5", .bits = 1 },
        .{ .name = "F6", .bits = 1 },
        .{ .name = "F7", .bits = 1 },
        .{ .name = "reserved", .bits = 8 },
    };

    const output = try bitfield_viz.generateSvg(allocator, "MEDIUM_REG", &fields);
    allocator.free(output);
}

fn benchLargeSvg(allocator: std.mem.Allocator) !void {
    const fields = [_]bitfield_viz.Field{
        .{ .name = "MODE0", .bits = 2 },
        .{ .name = "MODE1", .bits = 2 },
        .{ .name = "MODE2", .bits = 2 },
        .{ .name = "MODE3", .bits = 2 },
        .{ .name = "MODE4", .bits = 2 },
        .{ .name = "MODE5", .bits = 2 },
        .{ .name = "MODE6", .bits = 2 },
        .{ .name = "MODE7", .bits = 2 },
        .{ .name = "MODE8", .bits = 2 },
        .{ .name = "MODE9", .bits = 2 },
        .{ .name = "MODE10", .bits = 2 },
        .{ .name = "MODE11", .bits = 2 },
        .{ .name = "MODE12", .bits = 2 },
        .{ .name = "MODE13", .bits = 2 },
        .{ .name = "MODE14", .bits = 2 },
        .{ .name = "MODE15", .bits = 2 },
    };

    const output = try bitfield_viz.generateSvg(allocator, "GPIO_MODER", &fields);
    allocator.free(output);
}

// ============================================================================
// Benchmark Runner
// ============================================================================

pub fn runAllBenchmarks(allocator: std.mem.Allocator) void {
    std.debug.print("\n=== zig_silicon Benchmarks ===\n\n", .{});

    const results = [_]BenchResult{
        runBenchAlloc(allocator, "Small SVG (8-bit)", 1000, benchSmallSvg),
        runBenchAlloc(allocator, "Medium SVG (16-bit)", 1000, benchMediumSvg),
        runBenchAlloc(allocator, "Large SVG (32-bit MODER)", 1000, benchLargeSvg),
    };

    for (results) |result| {
        printResult(result);
        std.debug.print("\n", .{});
    }
}

test "benchmark compiles" {
    const allocator = std.testing.allocator;
    try benchSmallSvg(allocator);
    try benchMediumSvg(allocator);
    try benchLargeSvg(allocator);
}
