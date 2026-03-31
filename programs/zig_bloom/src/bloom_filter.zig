//! Bloom Filter Implementation
//!
//! A space-efficient probabilistic data structure for membership testing.
//! Supports: may be in set (with false positive rate) or definitely not in set.
//!
//! Features:
//! - Configurable false positive rate
//! - Automatic optimal sizing
//! - Union and intersection operations
//! - Serialization support
//!
//! Example:
//! ```zig
//! // Create bloom filter for 10000 items with 1% false positive rate
//! var bf = try BloomFilter.initCapacity(allocator, 10000, 0.01);
//! defer bf.deinit();
//!
//! bf.add("hello");
//! if (bf.contains("hello")) { ... }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// Standard Bloom Filter
pub fn BloomFilter(comptime T: type) type {
    return struct {
        bits: []u64,
        num_bits: usize,
        num_hashes: u32,
        count: usize,
        allocator: Allocator,

        const Self = @This();
        const BITS_PER_WORD: usize = 64;

        /// Initialize with specific bit count and hash count
        pub fn init(allocator: Allocator, num_bits: usize, num_hashes: u32) !Self {
            const num_words = (num_bits + BITS_PER_WORD - 1) / BITS_PER_WORD;
            const bits = try allocator.alloc(u64, num_words);
            @memset(bits, 0);

            return Self{
                .bits = bits,
                .num_bits = num_bits,
                .num_hashes = num_hashes,
                .count = 0,
                .allocator = allocator,
            };
        }

        /// Initialize with expected capacity and desired false positive rate
        pub fn initCapacity(allocator: Allocator, expected_items: usize, fp_rate: f64) !Self {
            // Optimal number of bits: m = -n * ln(p) / (ln(2)^2)
            const n = @as(f64, @floatFromInt(expected_items));
            const ln2_sq = @log(@as(f64, 2.0)) * @log(@as(f64, 2.0));
            const m = @as(usize, @intFromFloat(-n * @log(fp_rate) / ln2_sq));

            // Optimal number of hash functions: k = (m/n) * ln(2)
            const k = @as(u32, @intFromFloat(@as(f64, @floatFromInt(m)) / n * @log(@as(f64, 2.0))));

            return init(allocator, @max(m, 64), @max(k, 1));
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.bits);
        }

        /// Add an item to the filter
        pub fn add(self: *Self, item: T) void {
            self.addBytes(toBytes(item));
        }

        /// Add raw bytes to the filter
        pub fn addBytes(self: *Self, data: []const u8) void {
            var h1: u64 = undefined;
            var h2: u64 = undefined;
            doubleHash(data, &h1, &h2);

            var i: u32 = 0;
            while (i < self.num_hashes) : (i += 1) {
                const combined = h1 +% @as(u64, i) *% h2;
                const bit_idx = combined % self.num_bits;
                self.setBit(bit_idx);
            }
            self.count += 1;
        }

        /// Check if an item may be in the filter
        /// Returns true if item may be present, false if definitely not present
        pub fn contains(self: *const Self, item: T) bool {
            return self.containsBytes(toBytes(item));
        }

        /// Check if raw bytes may be in the filter
        pub fn containsBytes(self: *const Self, data: []const u8) bool {
            var h1: u64 = undefined;
            var h2: u64 = undefined;
            doubleHash(data, &h1, &h2);

            var i: u32 = 0;
            while (i < self.num_hashes) : (i += 1) {
                const combined = h1 +% @as(u64, i) *% h2;
                const bit_idx = combined % self.num_bits;
                if (!self.getBit(bit_idx)) return false;
            }
            return true;
        }

        /// Get the current estimated false positive rate
        pub fn estimatedFPRate(self: *const Self) f64 {
            const m = @as(f64, @floatFromInt(self.num_bits));
            const n = @as(f64, @floatFromInt(self.count));
            const k = @as(f64, @floatFromInt(self.num_hashes));

            // FP rate ≈ (1 - e^(-kn/m))^k
            const exponent = -k * n / m;
            return math.pow(f64, 1.0 - @exp(exponent), k);
        }

        /// Get fill ratio (bits set / total bits)
        pub fn fillRatio(self: *const Self) f64 {
            var set_bits: usize = 0;
            for (self.bits) |word| {
                set_bits += @popCount(word);
            }
            return @as(f64, @floatFromInt(set_bits)) / @as(f64, @floatFromInt(self.num_bits));
        }

        /// Union of two bloom filters (modifies self)
        pub fn unionWith(self: *Self, other: *const Self) !void {
            if (self.num_bits != other.num_bits or self.num_hashes != other.num_hashes) {
                return error.IncompatibleFilters;
            }
            for (self.bits, other.bits) |*a, b| {
                a.* |= b;
            }
        }

        /// Intersection of two bloom filters (modifies self)
        pub fn intersectWith(self: *Self, other: *const Self) !void {
            if (self.num_bits != other.num_bits or self.num_hashes != other.num_hashes) {
                return error.IncompatibleFilters;
            }
            for (self.bits, other.bits) |*a, b| {
                a.* &= b;
            }
        }

        /// Clear the filter
        pub fn clear(self: *Self) void {
            @memset(self.bits, 0);
            self.count = 0;
        }

        /// Serialize to bytes
        pub fn serialize(self: *const Self) []const u8 {
            return std.mem.sliceAsBytes(self.bits);
        }

        // Internal helpers
        fn setBit(self: *Self, bit_idx: usize) void {
            const word_idx = bit_idx / BITS_PER_WORD;
            const bit_offset: u6 = @intCast(bit_idx % BITS_PER_WORD);
            self.bits[word_idx] |= @as(u64, 1) << bit_offset;
        }

        fn getBit(self: *const Self, bit_idx: usize) bool {
            const word_idx = bit_idx / BITS_PER_WORD;
            const bit_offset: u6 = @intCast(bit_idx % BITS_PER_WORD);
            return (self.bits[word_idx] & (@as(u64, 1) << bit_offset)) != 0;
        }

        fn toBytes(item: T) []const u8 {
            if (T == []const u8) {
                return item;
            } else if (@typeInfo(T) == .pointer) {
                const child = @typeInfo(T).pointer.child;
                if (child == u8) {
                    return item;
                }
            }
            return std.mem.asBytes(&item);
        }

        fn doubleHash(data: []const u8, h1: *u64, h2: *u64) void {
            // Use two different hash functions
            h1.* = std.hash.Wyhash.hash(0, data);
            h2.* = std.hash.Wyhash.hash(0x517cc1b727220a95, data);
        }
    };
}

/// Counting Bloom Filter (supports deletion)
pub fn CountingBloomFilter(comptime T: type) type {
    return struct {
        counters: []u8,
        num_counters: usize,
        num_hashes: u32,
        count: usize,
        allocator: Allocator,

        const Self = @This();
        const MAX_COUNT: u8 = 255;

        pub fn init(allocator: Allocator, num_counters: usize, num_hashes: u32) !Self {
            const counters = try allocator.alloc(u8, num_counters);
            @memset(counters, 0);

            return Self{
                .counters = counters,
                .num_counters = num_counters,
                .num_hashes = num_hashes,
                .count = 0,
                .allocator = allocator,
            };
        }

        pub fn initCapacity(allocator: Allocator, expected_items: usize, fp_rate: f64) !Self {
            const n = @as(f64, @floatFromInt(expected_items));
            const ln2_sq = @log(@as(f64, 2.0)) * @log(@as(f64, 2.0));
            const m = @as(usize, @intFromFloat(-n * @log(fp_rate) / ln2_sq));
            const k = @as(u32, @intFromFloat(@as(f64, @floatFromInt(m)) / n * @log(@as(f64, 2.0))));

            return init(allocator, @max(m, 64), @max(k, 1));
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.counters);
        }

        pub fn add(self: *Self, item: T) void {
            self.addBytes(toBytes(item));
        }

        pub fn addBytes(self: *Self, data: []const u8) void {
            var h1: u64 = undefined;
            var h2: u64 = undefined;
            doubleHash(data, &h1, &h2);

            var i: u32 = 0;
            while (i < self.num_hashes) : (i += 1) {
                const combined = h1 +% @as(u64, i) *% h2;
                const idx = combined % self.num_counters;
                if (self.counters[idx] < MAX_COUNT) {
                    self.counters[idx] += 1;
                }
            }
            self.count += 1;
        }

        /// Remove an item (may cause false negatives if counter saturated)
        pub fn remove(self: *Self, item: T) void {
            self.removeBytes(toBytes(item));
        }

        pub fn removeBytes(self: *Self, data: []const u8) void {
            var h1: u64 = undefined;
            var h2: u64 = undefined;
            doubleHash(data, &h1, &h2);

            var i: u32 = 0;
            while (i < self.num_hashes) : (i += 1) {
                const combined = h1 +% @as(u64, i) *% h2;
                const idx = combined % self.num_counters;
                if (self.counters[idx] > 0) {
                    self.counters[idx] -= 1;
                }
            }
            if (self.count > 0) self.count -= 1;
        }

        pub fn contains(self: *const Self, item: T) bool {
            return self.containsBytes(toBytes(item));
        }

        pub fn containsBytes(self: *const Self, data: []const u8) bool {
            var h1: u64 = undefined;
            var h2: u64 = undefined;
            doubleHash(data, &h1, &h2);

            var i: u32 = 0;
            while (i < self.num_hashes) : (i += 1) {
                const combined = h1 +% @as(u64, i) *% h2;
                const idx = combined % self.num_counters;
                if (self.counters[idx] == 0) return false;
            }
            return true;
        }

        pub fn clear(self: *Self) void {
            @memset(self.counters, 0);
            self.count = 0;
        }

        fn toBytes(item: T) []const u8 {
            if (T == []const u8) {
                return item;
            } else if (@typeInfo(T) == .pointer) {
                const child = @typeInfo(T).pointer.child;
                if (child == u8) {
                    return item;
                }
            }
            return std.mem.asBytes(&item);
        }

        fn doubleHash(data: []const u8, h1: *u64, h2: *u64) void {
            h1.* = std.hash.Wyhash.hash(0, data);
            h2.* = std.hash.Wyhash.hash(0x517cc1b727220a95, data);
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "bloom filter basic operations" {
    const allocator = std.testing.allocator;
    var bf = try BloomFilter([]const u8).initCapacity(allocator, 1000, 0.01);
    defer bf.deinit();

    bf.add("hello");
    bf.add("world");

    try std.testing.expect(bf.contains("hello"));
    try std.testing.expect(bf.contains("world"));
    try std.testing.expect(!bf.contains("nothere"));
}

test "bloom filter false positive rate" {
    const allocator = std.testing.allocator;
    var bf = try BloomFilter(u64).initCapacity(allocator, 10000, 0.01);
    defer bf.deinit();

    // Add items
    var i: u64 = 0;
    while (i < 10000) : (i += 1) {
        bf.add(i);
    }

    // Check false positive rate
    var false_positives: usize = 0;
    i = 10000;
    while (i < 20000) : (i += 1) {
        if (bf.contains(i)) false_positives += 1;
    }

    const actual_fp_rate = @as(f64, @floatFromInt(false_positives)) / 10000.0;
    // Allow some margin for statistical variance
    try std.testing.expect(actual_fp_rate < 0.03);
}

test "counting bloom filter deletion" {
    const allocator = std.testing.allocator;
    var cbf = try CountingBloomFilter([]const u8).initCapacity(allocator, 1000, 0.01);
    defer cbf.deinit();

    cbf.add("hello");
    try std.testing.expect(cbf.contains("hello"));

    cbf.remove("hello");
    try std.testing.expect(!cbf.contains("hello"));
}
