//! zig_bloom CLI - Probabilistic Data Structure Demo
//!
//! Demonstrates usage of Bloom filters, Count-Min Sketch, and HyperLogLog.

const std = @import("std");
const Io = std.Io;
const lib = @import("lib.zig");

const BloomFilter = lib.BloomFilter;
const CountingBloomFilter = lib.CountingBloomFilter;
const CountMinSketch = lib.CountMinSketch;
const HyperLogLog = lib.HyperLogLog;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const allocator = init.gpa;

    try stdout.print("\n╔══════════════════════════════════════════════════════════════╗\n", .{});
    try stdout.print("║          zig_bloom - Probabilistic Data Structures           ║\n", .{});
    try stdout.print("╚══════════════════════════════════════════════════════════════╝\n\n", .{});

    // Demo 1: Bloom Filter
    try demoBloomFilter(allocator, stdout);

    // Demo 2: Counting Bloom Filter
    try demoCountingBloomFilter(allocator, stdout);

    // Demo 3: Count-Min Sketch
    try demoCountMinSketch(allocator, stdout);

    // Demo 4: HyperLogLog
    try demoHyperLogLog(allocator, stdout);

    try stdout.print("═══════════════════════════════════════════════════════════════\n", .{});
    try stdout.print("All demos completed successfully!\n\n", .{});
    try stdout.flush();
}

fn demoBloomFilter(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    try stdout.print("│ Demo 1: Bloom Filter                                        │\n", .{});
    try stdout.print("└─────────────────────────────────────────────────────────────┘\n\n", .{});

    // Create bloom filter for ~1000 items with 1% false positive rate
    var bf = try BloomFilter([]const u8).initCapacity(allocator, 1000, 0.01);
    defer bf.deinit();

    // Add some items
    const items = [_][]const u8{
        "apple", "banana", "cherry", "date", "elderberry",
        "fig", "grape", "honeydew", "kiwi", "lemon",
    };

    for (items) |item| {
        bf.add(item);
    }

    try stdout.print("Added {} items to Bloom filter\n", .{items.len});
    try stdout.print("Memory usage: {} bytes ({} bits)\n", .{ (bf.num_bits + 63) / 64 * 8, bf.num_bits });
    try stdout.print("Expected FP rate: {d:.4}%\n\n", .{bf.estimatedFPRate() * 100});

    // Test membership
    try stdout.print("Membership tests:\n", .{});
    for (items) |item| {
        const present = bf.contains(item);
        try stdout.print("  '{s}': {s}\n", .{ item, if (present) "probably yes" else "definitely no" });
    }

    // Test non-members
    try stdout.print("\nNon-member tests:\n", .{});
    const non_items = [_][]const u8{ "zebra", "xylophone", "walrus" };
    for (non_items) |item| {
        const present = bf.contains(item);
        try stdout.print("  '{s}': {s}\n", .{ item, if (present) "false positive!" else "correctly absent" });
    }

    try stdout.print("\n", .{});
}

fn demoCountingBloomFilter(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    try stdout.print("│ Demo 2: Counting Bloom Filter (with deletion)               │\n", .{});
    try stdout.print("└─────────────────────────────────────────────────────────────┘\n\n", .{});

    var cbf = try CountingBloomFilter([]const u8).init(allocator, 10000, 5);
    defer cbf.deinit();

    // Add and remove items
    cbf.add("temporary_item");
    try stdout.print("Added 'temporary_item': {s}\n", .{if (cbf.contains("temporary_item")) "present" else "absent"});

    cbf.remove("temporary_item");
    try stdout.print("Removed 'temporary_item': {s}\n", .{if (cbf.contains("temporary_item")) "still present (FP)" else "correctly absent"});

    // Add item multiple times
    cbf.add("popular_item");
    cbf.add("popular_item");
    cbf.add("popular_item");
    try stdout.print("\nAdded 'popular_item' 3 times: {s}\n", .{if (cbf.contains("popular_item")) "present" else "absent"});

    try stdout.print("Memory usage: {} bytes\n\n", .{cbf.num_counters});
}

fn demoCountMinSketch(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    try stdout.print("│ Demo 3: Count-Min Sketch (frequency estimation)             │\n", .{});
    try stdout.print("└─────────────────────────────────────────────────────────────┘\n\n", .{});

    var cms = try CountMinSketch.init(allocator, 1000, 5);
    defer cms.deinit();

    // Simulate word frequency counting
    const words = [_]struct { word: []const u8, count: u32 }{
        .{ .word = "the", .count = 100 },
        .{ .word = "a", .count = 80 },
        .{ .word = "is", .count = 60 },
        .{ .word = "and", .count = 50 },
        .{ .word = "to", .count = 40 },
        .{ .word = "rare", .count = 3 },
    };

    for (words) |w| {
        var i: u32 = 0;
        while (i < w.count) : (i += 1) {
            cms.add(w.word);
        }
    }

    try stdout.print("Word frequency estimates:\n", .{});
    for (words) |w| {
        const estimate = cms.estimate(w.word);
        try stdout.print("  '{s}': actual={}, estimated={}\n", .{ w.word, w.count, estimate });
    }

    try stdout.print("\nNon-existent word 'xyz': estimated={}\n", .{cms.estimate("xyz")});
    try stdout.print("Memory usage: {} bytes\n\n", .{cms.width * cms.depth * 4});
}

fn demoHyperLogLog(allocator: std.mem.Allocator, stdout: anytype) !void {
    try stdout.print("┌─────────────────────────────────────────────────────────────┐\n", .{});
    try stdout.print("│ Demo 4: HyperLogLog (cardinality estimation)                │\n", .{});
    try stdout.print("└─────────────────────────────────────────────────────────────┘\n\n", .{});

    var hll = try HyperLogLog.init(allocator, 14); // ~0.8% error
    defer hll.deinit();

    // Add unique items
    const unique_count: u64 = 50000;
    var i: u64 = 0;
    while (i < unique_count) : (i += 1) {
        hll.add(i);
    }

    // Add duplicates (shouldn't affect cardinality)
    i = 0;
    while (i < 10000) : (i += 1) {
        hll.add(i % 100);
    }

    const estimate = hll.estimate();
    const error_pct = @as(f64, @floatFromInt(if (estimate > unique_count) estimate - unique_count else unique_count - estimate)) / @as(f64, @floatFromInt(unique_count)) * 100;

    try stdout.print("Actual unique items: {}\n", .{unique_count});
    try stdout.print("Estimated cardinality: {}\n", .{estimate});
    try stdout.print("Error: {d:.2}%\n", .{error_pct});
    try stdout.print("Expected standard error: {d:.2}%\n", .{hll.standardError() * 100});
    try stdout.print("Memory usage: {} bytes (only!)\n\n", .{hll.num_registers});

    // Demonstrate merge
    var hll2 = try HyperLogLog.init(allocator, 14);
    defer hll2.deinit();

    i = 50000;
    while (i < 75000) : (i += 1) {
        hll2.add(i);
    }

    try hll.merge(&hll2);
    try stdout.print("After merging with another HLL (25k more items):\n", .{});
    try stdout.print("Combined estimate: {} (expected ~75000)\n\n", .{hll.estimate()});
}
