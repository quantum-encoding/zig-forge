//! zig_ratelimit CLI Demo
//!
//! Demonstrates usage of various rate limiting algorithms.

const std = @import("std");
const lib = @import("ratelimit");

const TokenBucket = lib.TokenBucket;
const LeakyBucket = lib.LeakyBucket;
const GCRA = lib.GCRA;
const SlidingWindowCounter = lib.SlidingWindowCounter;
const FixedWindowCounter = lib.FixedWindowCounter;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);

    const allocator = init.gpa;

    try stdout_writer.interface.print("\n╔══════════════════════════════════════════════════════════════╗\n", .{});
    try stdout_writer.interface.print("║            zig_ratelimit - Rate Limiting Demo                ║\n", .{});
    try stdout_writer.interface.print("╚══════════════════════════════════════════════════════════════╝\n\n", .{});

    try demoTokenBucket(&stdout_writer.interface);
    try demoLeakyBucket(&stdout_writer.interface);
    try demoGCRA(&stdout_writer.interface);
    try demoSlidingWindow(allocator, &stdout_writer.interface);
    try demoComparison(allocator, &stdout_writer.interface);

    try stdout_writer.interface.print("═══════════════════════════════════════════════════════════════\n", .{});
    try stdout_writer.interface.print("All demos completed!\n\n", .{});
    try stdout_writer.flush();
}

fn demoTokenBucket(stdout: *std.Io.Writer) !void {
    try stdout.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    try stdout.print("│ Demo 1: Token Bucket                                        │\n", .{});
    try stdout.print("│ (Allows bursts, refills at constant rate)                   │\n", .{});
    try stdout.print("└─────────────────────────────────────────────────────────────┘\n\n", .{});

    var bucket = TokenBucket.init(10, 5); // 10 tokens max, 5 tokens/sec

    try stdout.print("Configuration: capacity=10, rate=5/sec\n\n", .{});

    // Simulate burst of requests
    try stdout.print("Simulating burst of 15 requests:\n", .{});
    var allowed: usize = 0;
    var denied: usize = 0;

    for (0..15) |i| {
        if (bucket.tryAcquire(1)) {
            allowed += 1;
            try stdout.print("  Request {d:2}: ✓ allowed (tokens: {d:.1})\n", .{ i + 1, bucket.available() });
        } else {
            denied += 1;
            try stdout.print("  Request {d:2}: ✗ denied  (tokens: {d:.1})\n", .{ i + 1, bucket.available() });
        }
    }

    try stdout.print("\nResults: {} allowed, {} denied\n", .{ allowed, denied });
    try stdout.print("Fill ratio: {d:.0}%\n\n", .{bucket.fillRatio() * 100});
}

fn demoLeakyBucket(stdout: *std.Io.Writer) !void {
    try stdout.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    try stdout.print("│ Demo 2: Leaky Bucket                                        │\n", .{});
    try stdout.print("│ (Smooth output rate, requests queue up)                     │\n", .{});
    try stdout.print("└─────────────────────────────────────────────────────────────┘\n\n", .{});

    var bucket = LeakyBucket.init(5, 10); // 5 queue capacity, 10/sec leak rate

    try stdout.print("Configuration: capacity=5, leak_rate=10/sec\n\n", .{});

    try stdout.print("Simulating requests:\n", .{});
    for (0..8) |i| {
        if (bucket.tryAcquire()) {
            try stdout.print("  Request {}: ✓ queued (pending: {d:.1})\n", .{ i + 1, bucket.pending() });
        } else {
            try stdout.print("  Request {}: ✗ dropped (queue full)\n", .{i + 1});
        }
    }

    try stdout.print("\nBucket fill: {d:.0}%\n\n", .{bucket.fillRatio() * 100});
}

fn demoGCRA(stdout: *std.Io.Writer) !void {
    try stdout.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    try stdout.print("│ Demo 3: GCRA (Generic Cell Rate Algorithm)                  │\n", .{});
    try stdout.print("│ (Precise burst control, used in network QoS)                │\n", .{});
    try stdout.print("└─────────────────────────────────────────────────────────────┘\n\n", .{});

    var gcra = GCRA.init(100, 5); // 100/sec, burst of 5

    try stdout.print("Configuration: rate=100/sec, burst=5\n\n", .{});

    try stdout.print("Initial burst test:\n", .{});
    var burst_allowed: usize = 0;
    for (0..10) |_| {
        if (gcra.tryAcquire()) {
            burst_allowed += 1;
        }
    }
    try stdout.print("  Burst: {}/10 requests allowed immediately\n\n", .{burst_allowed});
}

fn demoSlidingWindow(allocator: std.mem.Allocator, stdout: *std.Io.Writer) !void {
    try stdout.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    try stdout.print("│ Demo 4: Sliding Window Counter                              │\n", .{});
    try stdout.print("│ (Approximate tracking with O(1) memory)                     │\n", .{});
    try stdout.print("└─────────────────────────────────────────────────────────────┘\n\n", .{});

    _ = allocator;

    var counter = SlidingWindowCounter.init(10, 1000); // 10 per second

    try stdout.print("Configuration: limit=10/sec\n\n", .{});

    try stdout.print("Simulating requests:\n", .{});
    var allowed: usize = 0;
    for (0..15) |i| {
        if (counter.tryAcquire()) {
            allowed += 1;
            try stdout.print("  Request {d:2}: ✓ (rate: {d:.1})\n", .{ i + 1, counter.currentRate() });
        } else {
            try stdout.print("  Request {d:2}: ✗ rate limited\n", .{i + 1});
        }
    }

    try stdout.print("\n{} of 15 requests allowed\n\n", .{allowed});
}

fn demoComparison(allocator: std.mem.Allocator, stdout: *std.Io.Writer) !void {
    try stdout.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    try stdout.print("│ Demo 5: Algorithm Comparison                                │\n", .{});
    try stdout.print("└─────────────────────────────────────────────────────────────┘\n\n", .{});

    _ = allocator;

    const rate: f64 = 10; // 10 requests per second
    const requests: usize = 20;

    var token = TokenBucket.init(10, rate);
    var leaky = LeakyBucket.init(10, rate);
    var fixed = FixedWindowCounter.init(10, 1000);
    var sliding = SlidingWindowCounter.init(10, 1000);

    var token_allowed: usize = 0;
    var leaky_allowed: usize = 0;
    var fixed_allowed: usize = 0;
    var sliding_allowed: usize = 0;

    for (0..requests) |_| {
        if (token.tryAcquire(1)) token_allowed += 1;
        if (leaky.tryAcquire()) leaky_allowed += 1;
        if (fixed.tryAcquire()) fixed_allowed += 1;
        if (sliding.tryAcquire()) sliding_allowed += 1;
    }

    try stdout.print("Instant burst of {} requests (limit=10):\n\n", .{requests});
    try stdout.print("  Token Bucket:          {d:2}/{} allowed\n", .{ token_allowed, requests });
    try stdout.print("  Leaky Bucket:          {d:2}/{} allowed\n", .{ leaky_allowed, requests });
    try stdout.print("  Fixed Window:          {d:2}/{} allowed\n", .{ fixed_allowed, requests });
    try stdout.print("  Sliding Window:        {d:2}/{} allowed\n\n", .{ sliding_allowed, requests });

    try stdout.print("Key differences:\n", .{});
    try stdout.print("  • Token/Leaky: Allow initial burst up to capacity\n", .{});
    try stdout.print("  • Window-based: Strictly enforce per-window limit\n\n", .{});
}
