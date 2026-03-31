//! Benchmark Suite for zig_hal
//!
//! Performance benchmarks for HAL operations.
//! These benchmarks measure the overhead of various abstraction layers.

const std = @import("std");
const bitfield = @import("bitfield.zig");

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

fn runBench(comptime name: []const u8, comptime iterations: u64, comptime func: fn () void) BenchResult {
    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;

    // Warmup
    for (0..100) |_| {
        func();
    }

    // Benchmark
    for (0..iterations) |_| {
        const start = std.time.nanoTimestamp();
        func();
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
        \\  Total: {d}ns
        \\  Average: {d}ns
        \\  Min: {d}ns
        \\  Max: {d}ns
        \\
    , .{
        result.name,
        result.iterations,
        result.total_ns,
        result.avg_ns,
        result.min_ns,
        result.max_ns,
    });
}

// ============================================================================
// Benchmarks
// ============================================================================

var bench_value: u32 = 0;

fn benchBitMask() void {
    bench_value = bitfield.bitMask(0, 7);
    bench_value = bitfield.bitMask(8, 15);
    bench_value = bitfield.bitMask(16, 23);
    bench_value = bitfield.bitMask(24, 31);
}

fn benchExtractBits() void {
    bench_value = bitfield.extractBits(0xDEADBEEF, 0, 7);
    bench_value = bitfield.extractBits(0xDEADBEEF, 8, 15);
    bench_value = bitfield.extractBits(0xDEADBEEF, 16, 23);
    bench_value = bitfield.extractBits(0xDEADBEEF, 24, 31);
}

fn benchInsertBits() void {
    bench_value = bitfield.insertBits(0, 0xFF, 0, 7);
    bench_value = bitfield.insertBits(bench_value, 0xAB, 8, 15);
    bench_value = bitfield.insertBits(bench_value, 0xCD, 16, 23);
    bench_value = bitfield.insertBits(bench_value, 0xEF, 24, 31);
}

fn benchPackedStructAccess() void {
    const Reg = packed struct {
        field1: u8,
        field2: u8,
        field3: u8,
        field4: u8,
    };

    var reg: Reg = @bitCast(@as(u32, 0));
    reg.field1 = 0xAA;
    reg.field2 = 0xBB;
    reg.field3 = 0xCC;
    reg.field4 = 0xDD;
    bench_value = @bitCast(reg);
}

fn benchPackedStructBitCast() void {
    const Reg = packed struct {
        a: u4,
        b: u4,
        c: u8,
        d: u16,
    };

    const reg: Reg = @bitCast(@as(u32, 0xDEADBEEF));
    bench_value = @as(u32, reg.a) + @as(u32, reg.b) + @as(u32, reg.c) + @as(u32, reg.d);
}

// ============================================================================
// Benchmark Runner
// ============================================================================

pub fn runAllBenchmarks() void {
    std.debug.print("\n=== zig_hal Benchmarks ===\n\n", .{});

    const results = [_]BenchResult{
        runBench("bitMask operations", 100000, benchBitMask),
        runBench("extractBits operations", 100000, benchExtractBits),
        runBench("insertBits operations", 100000, benchInsertBits),
        runBench("packed struct access", 100000, benchPackedStructAccess),
        runBench("packed struct bitCast", 100000, benchPackedStructBitCast),
    };

    for (results) |result| {
        printResult(result);
        std.debug.print("\n", .{});
    }

    // Prevent optimization of bench_value
    if (bench_value == 0xDEADBEEF) {
        std.debug.print("Unexpected value\n", .{});
    }
}

test "benchmark compiles" {
    // Just verify everything compiles
    _ = benchBitMask;
    _ = benchExtractBits;
    _ = benchInsertBits;
    _ = benchPackedStructAccess;
    _ = benchPackedStructBitCast;
}
