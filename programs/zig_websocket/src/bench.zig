//! zig_websocket Benchmarks
//!
//! Performance benchmarks for WebSocket frame encoding/decoding

const std = @import("std");
const websocket = @import("websocket");

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
};

const BenchmarkResult = struct {
    name: []const u8,
    iterations: u32,
    total_ns: u64,
    avg_ns: u64,
    ops_per_sec: u64,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [16384]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("\n╔══════════════════════════════════════════════════════════════╗\n", .{});
    try stdout.print("║         zig_websocket - Performance Benchmarks               ║\n", .{});
    try stdout.print("╚══════════════════════════════════════════════════════════════╝\n\n", .{});

    // Benchmark frame encoding
    try stdout.print("Frame Encoding Benchmarks:\n", .{});
    try stdout.print("─────────────────────────────────────────────────────────────\n", .{});

    var result = try benchmarkFrameEncoding(arena, 10000);
    try printBenchmarkResult(stdout, result);
    arena.free(result.name);

    result = try benchmarkMaskedFrameEncoding(arena, 10000);
    try printBenchmarkResult(stdout, result);
    arena.free(result.name);

    try stdout.print("\n", .{});

    // Benchmark frame decoding
    try stdout.print("Frame Decoding Benchmarks:\n", .{});
    try stdout.print("─────────────────────────────────────────────────────────────\n", .{});

    result = try benchmarkFrameDecoding(arena, 10000);
    try printBenchmarkResult(stdout, result);
    arena.free(result.name);

    result = try benchmarkHandshake(arena, 10000);
    try printBenchmarkResult(stdout, result);
    arena.free(result.name);

    try stdout.print("\n", .{});

    // Benchmark frame header parsing
    try stdout.print("Header Parsing Benchmarks:\n", .{});
    try stdout.print("─────────────────────────────────────────────────────────────\n", .{});

    result = try benchmarkHeaderParsing(arena, 50000);
    try printBenchmarkResult(stdout, result);
    arena.free(result.name);

    try stdout.print("\n", .{});

    // Benchmark masking/unmasking
    try stdout.print("Masking Benchmarks:\n", .{});
    try stdout.print("─────────────────────────────────────────────────────────────\n", .{});

    result = try benchmarkMasking(arena, 50000);
    try printBenchmarkResult(stdout, result);
    arena.free(result.name);

    try stdout.print("\n╚══════════════════════════════════════════════════════════════╝\n", .{});
    try stdout.print("Benchmarks complete!\n\n", .{});

    try stdout.flush();
}

fn printBenchmarkResult(stdout: anytype, result: BenchmarkResult) !void {
    try stdout.print("  {s:<40} ", .{result.name});
    try stdout.print("{d:>10} iterations, ", .{result.iterations});
    try stdout.print("{d:>8.2} µs/op, ", .{@as(f64, @floatFromInt(result.avg_ns)) / 1000.0});
    try stdout.print("{d:>8} ops/s\n", .{result.ops_per_sec});
}

fn benchmarkFrameEncoding(allocator: std.mem.Allocator, iterations: u32) !BenchmarkResult {
    const payload = "Hello, WebSocket!";

    var timer = try Timer.start();
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        var frame = try websocket.Frame.init(allocator, true, .text, payload);
        const bytes = try frame.toBytes(allocator);
        allocator.free(bytes);
        frame.deinit(allocator);
    }
    const elapsed = timer.read();

    return BenchmarkResult{
        .name = try allocator.dupe(u8, "Frame encoding (small text)"),
        .iterations = iterations,
        .total_ns = elapsed,
        .avg_ns = elapsed / iterations,
        .ops_per_sec = @as(u64, @intCast(iterations)) * 1_000_000_000 / elapsed,
    };
}

fn benchmarkMaskedFrameEncoding(allocator: std.mem.Allocator, iterations: u32) !BenchmarkResult {
    const payload = "Hello, WebSocket!";

    var timer = try Timer.start();
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        var frame = try websocket.Frame.initMasked(allocator, true, .text, payload);
        const bytes = try frame.toBytes(allocator);
        allocator.free(bytes);
        frame.deinit(allocator);
    }
    const elapsed = timer.read();

    return BenchmarkResult{
        .name = try allocator.dupe(u8, "Masked frame encoding (small text)"),
        .iterations = iterations,
        .total_ns = elapsed,
        .avg_ns = elapsed / iterations,
        .ops_per_sec = @as(u64, @intCast(iterations)) * 1_000_000_000 / elapsed,
    };
}

fn benchmarkFrameDecoding(allocator: std.mem.Allocator, iterations: u32) !BenchmarkResult {
    const payload = "Hello, WebSocket!";
    var frame = try websocket.Frame.init(allocator, true, .text, payload);
    const bytes = try frame.toBytes(allocator);
    frame.deinit(allocator);

    var timer = try Timer.start();
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        const result = try websocket.Frame.fromBytes(allocator, bytes);
        allocator.free(result.frame.payload);
    }
    const elapsed = timer.read();

    allocator.free(bytes);

    return BenchmarkResult{
        .name = try allocator.dupe(u8, "Frame decoding (small text)"),
        .iterations = iterations,
        .total_ns = elapsed,
        .avg_ns = elapsed / iterations,
        .ops_per_sec = @as(u64, @intCast(iterations)) * 1_000_000_000 / elapsed,
    };
}

fn benchmarkHandshake(allocator: std.mem.Allocator, iterations: u32) !BenchmarkResult {
    const key = "dGhlIHNhbXBsZSBub25jZQ==";

    var timer = try Timer.start();
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        const accept = try websocket.Handshake.generateAccept(allocator, key);
        allocator.free(accept);
    }
    const elapsed = timer.read();

    return BenchmarkResult{
        .name = try allocator.dupe(u8, "Handshake accept generation"),
        .iterations = iterations,
        .total_ns = elapsed,
        .avg_ns = elapsed / iterations,
        .ops_per_sec = @as(u64, @intCast(iterations)) * 1_000_000_000 / elapsed,
    };
}

fn benchmarkHeaderParsing(allocator: std.mem.Allocator, iterations: u32) !BenchmarkResult {
    const payload = "Hello, WebSocket!";
    var frame = try websocket.Frame.init(allocator, true, .text, payload);
    const bytes = try frame.toBytes(allocator);
    frame.deinit(allocator);

    var timer = try Timer.start();
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        _ = try websocket.FrameHeader.fromBytes(bytes);
    }
    const elapsed = timer.read();

    allocator.free(bytes);

    return BenchmarkResult{
        .name = try allocator.dupe(u8, "Frame header parsing"),
        .iterations = iterations,
        .total_ns = elapsed,
        .avg_ns = elapsed / iterations,
        .ops_per_sec = @as(u64, @intCast(iterations)) * 1_000_000_000 / elapsed,
    };
}

fn benchmarkMasking(allocator: std.mem.Allocator, iterations: u32) !BenchmarkResult {
    const payload = "Hello, WebSocket!";
    var frame = try websocket.Frame.initMasked(allocator, true, .text, payload);
    const frame_bytes = try frame.toBytes(allocator);
    frame.deinit(allocator);

    var timer = try Timer.start();
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        const result = try websocket.Frame.fromBytes(allocator, frame_bytes);
        allocator.free(result.frame.payload);
    }
    const elapsed = timer.read();

    allocator.free(frame_bytes);

    return BenchmarkResult{
        .name = try allocator.dupe(u8, "Mask/unmask operation"),
        .iterations = iterations,
        .total_ns = elapsed,
        .avg_ns = elapsed / iterations,
        .ops_per_sec = @as(u64, @intCast(iterations)) * 1_000_000_000 / elapsed,
    };
}
