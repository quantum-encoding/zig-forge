//! Memory Pool Benchmarks
//!
//! Compares FixedPool and Arena against std.heap.c_allocator

const std = @import("std");
const memory_pool = @import("memory-pool");
const FixedPool = memory_pool.FixedPool;
const ArenaAllocator = memory_pool.ArenaAllocator;

const NUM_ITERATIONS: usize = 1_000_000;
const OBJECT_SIZE: usize = 64;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("\n╔══════════════════════════════════════╗\n", .{});
    std.debug.print("║  Memory Pool Benchmarks (Zig 0.16)  ║\n", .{});
    std.debug.print("╚══════════════════════════════════════╝\n\n", .{});

    std.debug.print("Iterations: {d}\n", .{NUM_ITERATIONS});
    std.debug.print("Object Size: {d} bytes\n\n", .{OBJECT_SIZE});

    // Benchmark FixedPool
    try benchmarkFixedPool(allocator);

    // Benchmark Arena
    try benchmarkArena(allocator);

    // Benchmark malloc (GPA)
    try benchmarkMalloc(allocator);

    std.debug.print("\n╔══════════════════════════════════════╗\n", .{});
    std.debug.print("║  Benchmarks Complete                 ║\n", .{});
    std.debug.print("╚══════════════════════════════════════╝\n", .{});
}

fn benchmarkFixedPool(allocator: std.mem.Allocator) !void {
    std.debug.print("=== FixedPool Benchmark ===\n", .{});

    var pool = try FixedPool.init(allocator, OBJECT_SIZE, NUM_ITERATIONS);
    defer pool.deinit();

    var timer = try std.time.Timer.start();

    // Allocate all
    var i: usize = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        _ = try pool.alloc();
    }

    const alloc_time = timer.read();

    // Reset and reallocate to measure pure allocation
    pool.reset();
    timer.reset();

    i = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        _ = try pool.alloc();
    }

    const realloc_time = timer.read();

    // Measure alloc+free pattern
    pool.reset();
    timer.reset();

    i = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        const ptr = try pool.alloc();
        pool.free(ptr);
    }

    const roundtrip_time = timer.read();

    const alloc_ns = alloc_time / NUM_ITERATIONS;
    const realloc_ns = realloc_time / NUM_ITERATIONS;
    const roundtrip_ns = roundtrip_time / NUM_ITERATIONS;

    std.debug.print("  Allocation:         {d} ns/op\n", .{alloc_ns});
    std.debug.print("  Re-allocation:      {d} ns/op\n", .{realloc_ns});
    std.debug.print("  Alloc+Free:         {d} ns/op\n", .{roundtrip_ns});
    std.debug.print("  Throughput:         {d:.2} M ops/sec\n\n", .{@as(f64, @floatFromInt(NUM_ITERATIONS)) / @as(f64, @floatFromInt(roundtrip_time)) * 1_000.0});
}

fn benchmarkArena(allocator: std.mem.Allocator) !void {
    std.debug.print("=== Arena Benchmark ===\n", .{});

    const arena_size = OBJECT_SIZE * NUM_ITERATIONS + (NUM_ITERATIONS * 64); // Extra space for alignment
    var arena_alloc = try ArenaAllocator.init(allocator, arena_size);
    defer arena_alloc.deinit();

    var timer = try std.time.Timer.start();

    // Allocate all
    var i: usize = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        _ = try arena_alloc.alloc(OBJECT_SIZE, 8);
    }

    const alloc_time = timer.read();

    // Reset and reallocate
    arena_alloc.reset();
    timer.reset();

    i = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        _ = try arena_alloc.alloc(OBJECT_SIZE, 8);
    }

    const realloc_time = timer.read();

    const alloc_ns = alloc_time / NUM_ITERATIONS;
    const realloc_ns = realloc_time / NUM_ITERATIONS;

    std.debug.print("  Allocation:         {d} ns/op\n", .{alloc_ns});
    std.debug.print("  Re-allocation:      {d} ns/op\n", .{realloc_ns});
    std.debug.print("  Throughput:         {d:.2} M ops/sec\n", .{@as(f64, @floatFromInt(NUM_ITERATIONS)) / @as(f64, @floatFromInt(realloc_time)) * 1_000.0});
    std.debug.print("  Note: Arena doesn't support free()\n\n", .{});
}

fn benchmarkMalloc(allocator: std.mem.Allocator) !void {
    std.debug.print("=== Malloc (GPA) Baseline ===\n", .{});

    var timer = try std.time.Timer.start();

    // Allocate+free pattern
    var i: usize = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        const slice = try allocator.alloc(u8, OBJECT_SIZE);
        allocator.free(slice);
    }

    const roundtrip_time = timer.read();
    const roundtrip_ns = roundtrip_time / NUM_ITERATIONS;

    std.debug.print("  Alloc+Free:         {d} ns/op\n", .{roundtrip_ns});
    std.debug.print("  Throughput:         {d:.2} M ops/sec\n\n", .{@as(f64, @floatFromInt(NUM_ITERATIONS)) / @as(f64, @floatFromInt(roundtrip_time)) * 1_000.0});
}
