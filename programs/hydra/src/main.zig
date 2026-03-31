//! Hydra - GPU-Accelerated Variable Tester
//!
//! "A CPU is a general, a GPU is an army."
//!
//! This is the main entry point for the Hydra GPU brute-force search engine.
//! It combines the CPU Queen (orchestrator) with the GPU Hydra (parallel executor)
//! to achieve massive throughput on search problems.
//!
//! Usage:
//!   hydra --start <N> --end <M> --target <hash>
//!   hydra --benchmark
//!
//! Example:
//!   hydra --start 0 --end 1000000000 --target deadbeef

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

const banner =
    \\
    \\  ██╗  ██╗██╗   ██╗██████╗ ██████╗  █████╗
    \\  ██║  ██║╚██╗ ██╔╝██╔══██╗██╔══██╗██╔══██╗
    \\  ███████║ ╚████╔╝ ██║  ██║██████╔╝███████║
    \\  ██╔══██║  ╚██╔╝  ██║  ██║██╔══██╗██╔══██║
    \\  ██║  ██║   ██║   ██████╔╝██║  ██║██║  ██║
    \\  ╚═╝  ╚═╝   ╚═╝   ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝
    \\
    \\  GPU-Accelerated Brute-Force Search Engine
    \\  "A CPU is a general, a GPU is an army."
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("{s}\n", .{banner});

    // Parse command line arguments using new iterator pattern
    var args = std.process.Args.Iterator.init(init.minimal.args);

    var start_val: u64 = 0;
    var end_val: u64 = 100_000_000; // Default: 100 million
    var target_hash: [32]u8 = .{0} ** 32;
    var benchmark_mode = false;
    var show_help = false;

    _ = args.skip(); // Skip program name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "--benchmark") or std.mem.eql(u8, arg, "-b")) {
            benchmark_mode = true;
        } else if (std.mem.eql(u8, arg, "--start")) {
            if (args.next()) |val| {
                start_val = try std.fmt.parseInt(u64, val, 10);
            }
        } else if (std.mem.eql(u8, arg, "--end")) {
            if (args.next()) |val| {
                end_val = try std.fmt.parseInt(u64, val, 10);
            }
        } else if (std.mem.eql(u8, arg, "--target")) {
            if (args.next()) |val| {
                // Parse hex target
                const len = @min(val.len / 2, 32);
                for (0..len) |i| {
                    target_hash[i] = std.fmt.parseInt(u8, val[i * 2 ..][0..2], 16) catch 0;
                }
            }
        }
    }

    if (show_help) {
        printHelp();
        return;
    }

    // Print system info
    printSystemInfo();

    if (benchmark_mode) {
        try runBenchmark(allocator);
    } else {
        try runSearch(allocator, start_val, end_val, &target_hash);
    }
}

fn printHelp() void {
    std.debug.print(
        \\Usage: hydra [OPTIONS]
        \\
        \\Options:
        \\  --start <N>       Starting value for search (default: 0)
        \\  --end <M>         Ending value for search (default: 100000000)
        \\  --target <hex>    Target hash to find (hex string)
        \\  --benchmark, -b   Run performance benchmark
        \\  --help, -h        Show this help message
        \\
        \\Examples:
        \\  hydra --start 0 --end 1000000000 --target deadbeef
        \\  hydra --benchmark
        \\
    , .{});
}

fn printSystemInfo() void {
    std.debug.print("System Information:\n", .{});

    // Check SIMD capabilities
    std.debug.print("  SIMD: ", .{});
    if (simd_batch.hasAvx512()) {
        std.debug.print("AVX-512 available\n", .{});
    } else if (simd_batch.hasAvx2()) {
        std.debug.print("AVX2 available (no AVX-512)\n", .{});
    } else {
        std.debug.print("Basic SSE only\n", .{});
    }

    // CPU cores
    const cpu_count = std.Thread.getCpuCount() catch 1;
    std.debug.print("  CPU Cores: {}\n", .{cpu_count});

    std.debug.print("\n", .{});
}

fn runSearch(allocator: std.mem.Allocator, start: u64, end: u64, target: []const u8) !void {
    std.debug.print("Search Configuration:\n", .{});
    std.debug.print("  Range: {} to {}\n", .{ start, end });
    std.debug.print("  Target (first 8 bytes): ", .{});
    for (target[0..8]) |b| {
        std.debug.print("{x:0>2}", .{b});
    }
    std.debug.print("\n", .{});

    var q = try queen.Queen.init(allocator, start, end, .numeric_hash, target);
    defer q.deinit();

    q.run() catch |err| {
        std.debug.print("Search error: {}\n", .{err});
        return;
    };

    // Print matches
    const matches = q.getMatches();
    if (matches.len > 0) {
        std.debug.print("\nMatches Found:\n", .{});
        for (matches) |m| {
            std.debug.print("  Value: {} (index: {})\n", .{ m.value, m.global_index });
        }
    }
}

fn runBenchmark(allocator: std.mem.Allocator) !void {
    std.debug.print("Running Performance Benchmark...\n", .{});
    std.debug.print("\n", .{});

    // SIMD benchmark
    std.debug.print("1. SIMD Hash Benchmark (1M iterations):\n", .{});
    const simd_results = simd_batch.benchmarkHash(1_000_000);
    std.debug.print("   SIMD (8x parallel): {} ns\n", .{simd_results.simd_ns});
    std.debug.print("   Scalar: {} ns\n", .{simd_results.scalar_ns});
    std.debug.print("   SIMD Speedup: {d:.2}x\n", .{simd_results.speedup});
    std.debug.print("\n", .{});

    // GPU benchmark
    std.debug.print("2. GPU Kernel Benchmark:\n", .{});

    var gpu_device = gpu_kernel.GpuDevice.init() catch |err| {
        std.debug.print("   GPU not available: {}\n", .{err});
        std.debug.print("   Skipping GPU benchmark\n", .{});
        return;
    };

    // Create a dummy search to benchmark
    const target = [_]u8{0xDE, 0xAD, 0xBE, 0xEF} ++ ([_]u8{0} ** 28);
    var q = try queen.Queen.init(allocator, 0, 10_000_000, .numeric_hash, &target);
    defer q.deinit();

    const start_time = Instant.now() catch unreachable;
    q.run() catch {};
    const end_time = Instant.now() catch unreachable;

    const elapsed_ms = @as(f64, @floatFromInt(end_time.since(start_time))) / 1e6;
    const stats = q.getStats();

    std.debug.print("   Candidates processed: {}\n", .{stats.candidates_processed});
    std.debug.print("   Time: {d:.2} ms\n", .{elapsed_ms});
    std.debug.print("   Throughput: {d:.2}M candidates/sec\n", .{stats.throughput() / 1e6});
    std.debug.print("   GPU Utilization: {d:.1}%\n", .{stats.gpuUtilization()});
    std.debug.print("\n", .{});

    // Comparison with theoretical max
    std.debug.print("3. Performance Analysis:\n", .{});
    const theoretical_max = @as(f64, @floatFromInt(gpu_device.multiprocessor_count)) *
        @as(f64, @floatFromInt(gpu_device.warp_size)) *
        1e9; // Assuming 1 hash per cycle at 1GHz
    const efficiency = stats.throughput() / theoretical_max * 100;
    std.debug.print("   Theoretical max: {d:.2}M/sec\n", .{theoretical_max / 1e6});
    std.debug.print("   Achieved: {d:.2}M/sec\n", .{stats.throughput() / 1e6});
    std.debug.print("   Efficiency: {d:.1}%\n", .{efficiency});
}
