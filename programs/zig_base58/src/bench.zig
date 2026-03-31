//! Base58 Benchmarks
//!
//! Run with: zig build bench

const std = @import("std");
const Io = std.Io;
const base58 = @import("base58");

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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("\n=== Base58 Benchmarks ===\n\n", .{});

    // Benchmark small data encode
    try benchmarkEncode(arena, stdout, "encode small (16 bytes)", "0123456789abcdef");

    // Benchmark medium data encode
    try benchmarkEncode(arena, stdout, "encode medium (64 bytes)", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");

    // Benchmark large data encode
    var large_buf: [1024]u8 = undefined;
    for (0..large_buf.len) |i| {
        large_buf[i] = @as(u8, @intCast(i % 256));
    }
    try benchmarkEncode(arena, stdout, "encode large (1KB)", &large_buf);

    // Benchmark decode
    try benchmarkDecode(arena, stdout);

    // Benchmark Base58Check
    try benchmarkBase58Check(arena, stdout);

    try stdout.print("\n", .{});
    try stdout.flush();
}

fn benchmarkEncode(allocator: std.mem.Allocator, writer: anytype, name: []const u8, data: []const u8) !void {
    const iterations = 10000;
    var timer = try Timer.start();

    for (0..iterations) |_| {
        const encoded = try base58.encode(allocator, data);
        allocator.free(encoded);
    }

    const elapsed = timer.read();
    const per_iter_us = @as(f64, @floatFromInt(elapsed)) / (@as(f64, @floatFromInt(iterations)) * 1000.0);

    try writer.print("{s:30} | {d:.3} μs/iter | {d} iterations\n", .{ name, per_iter_us, iterations });
}

fn benchmarkDecode(allocator: std.mem.Allocator, writer: anytype) !void {
    const test_data = "9Ajdvzr";
    const iterations = 10000;

    var timer = try Timer.start();

    for (0..iterations) |_| {
        const decoded = try base58.decode(allocator, test_data);
        allocator.free(decoded);
    }

    const elapsed = timer.read();
    const per_iter_us = @as(f64, @floatFromInt(elapsed)) / (@as(f64, @floatFromInt(iterations)) * 1000.0);

    try writer.print("{s:30} | {d:.3} μs/iter | {d} iterations\n", .{ "decode (7 chars)", per_iter_us, iterations });
}

fn benchmarkBase58Check(allocator: std.mem.Allocator, writer: anytype) !void {
    const test_data = "Payment data";
    const iterations = 5000;

    var timer = try Timer.start();

    for (0..iterations) |_| {
        const encoded = try base58.encodeCheck(allocator, test_data);
        allocator.free(encoded);
    }

    const elapsed = timer.read();
    const per_iter_us = @as(f64, @floatFromInt(elapsed)) / (@as(f64, @floatFromInt(iterations)) * 1000.0);

    try writer.print("{s:30} | {d:.3} μs/iter | {d} iterations\n", .{ "check-encode", per_iter_us, iterations });
}
