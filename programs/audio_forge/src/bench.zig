//! Audio Forge Benchmarks
//!
//! Performance benchmarks for critical audio components.

const std = @import("std");
const ring_buffer = @import("ring_buffer.zig");

const AudioRingBuffer = ring_buffer.AudioRingBuffer;

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("\n", .{});
    std.debug.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║              AUDIO FORGE PERFORMANCE BENCHMARKS              ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});

    try benchRingBuffer(allocator);
}

fn benchRingBuffer(allocator: std.mem.Allocator) !void {
    std.debug.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    std.debug.print("│ Ring Buffer Operations                                      │\n", .{});
    std.debug.print("└─────────────────────────────────────────────────────────────┘\n", .{});

    const iterations: usize = 1_000_000;
    const channels: u8 = 2;
    const frame_size: usize = 256;
    const samples_per_op = frame_size * channels;

    var rb = try AudioRingBuffer.init(allocator, 8192, channels);
    defer rb.deinit(allocator);

    var write_buf: [512]f32 = undefined;
    var read_buf: [512]f32 = undefined;

    // Fill write buffer with test data
    for (&write_buf, 0..) |*s, i| {
        s.* = @as(f32, @floatFromInt(i)) / 512.0;
    }

    // Benchmark write operations
    const write_start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        _ = rb.write(write_buf[0..samples_per_op]);
        _ = rb.read(read_buf[0..samples_per_op]);
    }
    const write_end = std.time.nanoTimestamp();

    const total_ns = write_end - write_start;
    const ns_per_op = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iterations * 2));
    const ops_per_sec = 1_000_000_000.0 / ns_per_op;

    std.debug.print("  Write+Read:  {d:.1} ns/op  ({d:.1}M ops/sec)\n", .{
        ns_per_op,
        ops_per_sec / 1_000_000.0,
    });

    // Benchmark write-only
    rb.reset();
    const write_only_start = std.time.nanoTimestamp();
    for (0..iterations) |i| {
        _ = rb.write(write_buf[0..samples_per_op]);
        // Periodically drain to avoid filling buffer
        if (i % 16 == 15) {
            while (rb.availableRead() > 0) {
                _ = rb.read(read_buf[0..samples_per_op]);
            }
        }
    }
    const write_only_end = std.time.nanoTimestamp();

    const write_ns = @as(f64, @floatFromInt(write_only_end - write_only_start)) / @as(f64, @floatFromInt(iterations));
    std.debug.print("  Write only:  {d:.1} ns/op  ({d:.1}M ops/sec)\n", .{
        write_ns,
        1_000_000_000.0 / write_ns / 1_000_000.0,
    });

    // Target check
    std.debug.print("\n", .{});
    if (ns_per_op < 100) {
        std.debug.print("  ✓ Target: <100ns per operation - PASSED\n", .{});
    } else {
        std.debug.print("  ✗ Target: <100ns per operation - FAILED ({d:.1}ns)\n", .{ns_per_op});
    }

    std.debug.print("\n", .{});
}

test "bench compiles" {
    _ = ring_buffer;
}
