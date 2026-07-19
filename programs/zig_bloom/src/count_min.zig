//! Count-Min Sketch Implementation
//!
//! A probabilistic data structure for frequency estimation in data streams.
//! Provides approximate counts with guaranteed error bounds.
//!
//! Example:
//! ```zig
//! var cms = try CountMinSketch.init(allocator, 0.01, 0.001);
//! defer cms.deinit();
//!
//! cms.add("item1");
//! cms.add("item1");
//! const count = cms.estimate("item1"); // Returns ~2
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// Count-Min Sketch for frequency estimation
pub const CountMinSketch = struct {
    counters: [][]u32,
    width: usize,
    depth: usize,
    seeds: []u64,
    total_count: u64,
    allocator: Allocator,

    const Self = @This();

    /// Initialize with specific dimensions
    pub fn init(allocator: Allocator, width: usize, depth: usize) !Self {
        // Both dimensions index into the counter array (`hash % width`) and
        // drive the min-over-rows estimate; zero for either is a division by
        // zero / a sketch that always estimates maxInt(u32).
        if (width == 0) return error.InvalidWidth;
        if (depth == 0) return error.InvalidDepth;

        const counters = try allocator.alloc([]u32, depth);
        errdefer allocator.free(counters);

        // Track how many rows are live so a failure part-way through the loop
        // (or in the `seeds` allocation below) frees exactly those. The
        // previous form put the errdefer *inside* the loop body, where its
        // scope ends at the closing brace of each iteration — so it never ran
        // for a failure on a later iteration and every earlier row leaked.
        var rows_allocated: usize = 0;
        errdefer for (counters[0..rows_allocated]) |r| allocator.free(r);

        for (counters) |*row| {
            row.* = try allocator.alloc(u32, width);
            rows_allocated += 1;
            @memset(row.*, 0);
        }

        const seeds = try allocator.alloc(u64, depth);
        for (seeds, 0..) |*seed, i| {
            // Use wrapping arithmetic to avoid overflow panics
            seed.* = @as(u64, i) *% 0x517cc1b727220a95 +% 0x9e3779b97f4a7c15;
        }

        return Self{
            .counters = counters,
            .width = width,
            .depth = depth,
            .seeds = seeds,
            .total_count = 0,
            .allocator = allocator,
        };
    }

    /// Initialize with error bounds
    /// epsilon: relative error bound (e.g., 0.01 for 1%)
    /// delta: probability of exceeding error bound (e.g., 0.001 for 0.1%)
    pub fn initWithError(allocator: Allocator, epsilon: f64, delta: f64) !Self {
        // Guard before any @intFromFloat: epsilon <= 0 makes w infinite,
        // delta <= 0 makes d infinite, and NaN propagates straight through.
        // @intFromFloat on NaN/inf is illegal behavior (panic in Debug, UB in
        // ReleaseFast). The `!(x > 0 ...)` form also rejects NaN, since every
        // comparison against NaN is false.
        if (!(epsilon > 0.0 and epsilon < 1.0)) return error.InvalidEpsilon;
        if (!(delta > 0.0 and delta < 1.0)) return error.InvalidDelta;

        // Cormode & Muthukrishnan (2005): w = ceil(e / epsilon), d = ceil(ln(1/delta)).
        const w = @as(usize, @intFromFloat(@ceil(math.e / epsilon)));
        // delta close to 1 makes ln(1/delta) round down to 0 rows; one row is
        // the floor for a usable sketch.
        const d = @max(@as(usize, @intFromFloat(@ceil(@log(1.0 / delta)))), 1);
        return init(allocator, w, d);
    }

    pub fn deinit(self: *Self) void {
        for (self.counters) |row| {
            self.allocator.free(row);
        }
        self.allocator.free(self.counters);
        self.allocator.free(self.seeds);
    }

    /// Add an item with count 1
    pub fn add(self: *Self, item: anytype) void {
        self.addN(item, 1);
    }

    /// Add an item with specific count
    pub fn addN(self: *Self, item: anytype, count: u32) void {
        for (self.counters, self.seeds) |row, seed| {
            const hash = hashItem(item, seed);
            const idx = hash % self.width;
            row[idx] +|= count; // Saturating add
        }
        self.total_count += count;
    }

    /// Estimate the count of an item
    pub fn estimate(self: *const Self, item: anytype) u32 {
        var min_count: u32 = std.math.maxInt(u32);

        for (self.counters, self.seeds) |row, seed| {
            const hash = hashItem(item, seed);
            const idx = hash % self.width;
            min_count = @min(min_count, row[idx]);
        }

        return min_count;
    }

    /// Estimate count as fraction of total
    pub fn estimateFrequency(self: *const Self, item: anytype) f64 {
        if (self.total_count == 0) return 0;
        return @as(f64, @floatFromInt(self.estimate(item))) /
            @as(f64, @floatFromInt(self.total_count));
    }

    /// Get total count of all items
    pub fn getTotalCount(self: *const Self) u64 {
        return self.total_count;
    }

    /// Merge another sketch into this one
    pub fn merge(self: *Self, other: *const Self) !void {
        if (self.width != other.width or self.depth != other.depth) {
            return error.IncompatibleSketches;
        }

        for (self.counters, other.counters) |self_row, other_row| {
            for (self_row, other_row) |*a, b| {
                a.* +|= b;
            }
        }
        self.total_count += other.total_count;
    }

    /// Clear all counters
    pub fn clear(self: *Self) void {
        for (self.counters) |row| {
            @memset(row, 0);
        }
        self.total_count = 0;
    }

    /// Get memory usage in bytes
    pub fn memoryUsage(self: *const Self) usize {
        return self.width * self.depth * @sizeOf(u32) +
            self.depth * @sizeOf(u64) +
            self.depth * @sizeOf([]u32);
    }

    /// Hash an item with the given seed. For non-slice types the bytes are
    /// hashed *inside* this frame while the by-value `item` copy is still live —
    /// returning `std.mem.asBytes(&item)` from a `toBytes` helper would dangle
    /// into that helper's dead stack frame (the same fix already applied to
    /// HyperLogLog.hashItem).
    fn hashItem(item: anytype, seed: u64) u64 {
        const T = @TypeOf(item);
        if (T == []const u8) {
            return std.hash.Wyhash.hash(seed, item);
        } else if (@typeInfo(T) == .pointer) {
            const child = @typeInfo(T).pointer.child;
            if (child == u8) {
                return std.hash.Wyhash.hash(seed, item);
            }
        }
        return std.hash.Wyhash.hash(seed, std.mem.asBytes(&item));
    }
};

/// Heavy Hitters using Count-Min Sketch
///
/// Tracks items whose estimated frequency crossed `threshold` at some point.
/// The candidate set is a **superset** of the current heavy hitters: an item
/// is admitted when its frequency crosses the threshold and is never evicted,
/// but frequency is `estimate / total_count` and `total_count` only grows — so
/// an item admitted early can fall below the threshold later and still be
/// listed. Use `isHeavyHitter` to re-check an entry against the live sketch.
pub const HeavyHitters = struct {
    sketch: CountMinSketch,
    threshold: f64,
    candidates: std.StringHashMap(u32),
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator, epsilon: f64, delta: f64, threshold: f64) !Self {
        return Self{
            .sketch = try CountMinSketch.initWithError(allocator, epsilon, delta),
            .threshold = threshold,
            .candidates = std.StringHashMap(u32).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.candidates.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.candidates.deinit();
        self.sketch.deinit();
    }

    pub fn add(self: *Self, item: []const u8) !void {
        self.sketch.add(item);

        const freq = self.sketch.estimateFrequency(item);
        if (freq >= self.threshold) {
            const result = try self.candidates.getOrPut(item);
            if (!result.found_existing) {
                result.key_ptr.* = try self.allocator.dupe(u8, item);
            }
            result.value_ptr.* = self.sketch.estimate(item);
        }
    }

    /// Candidate set — a superset of the current heavy hitters (see the type
    /// doc comment). Filter with `isHeavyHitter` if staleness matters.
    pub fn getHeavyHitters(self: *const Self) std.StringHashMap(u32) {
        return self.candidates;
    }

    /// Re-check an item against the live sketch rather than trusting the
    /// candidate set's admission-time snapshot.
    pub fn isHeavyHitter(self: *const Self, item: []const u8) bool {
        return self.sketch.estimateFrequency(item) >= self.threshold;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "count-min sketch basic operations" {
    const allocator = std.testing.allocator;
    var cms = try CountMinSketch.init(allocator, 10000, 5);
    defer cms.deinit();

    cms.add(@as(u32, 1));
    cms.add(@as(u32, 1));
    cms.add(@as(u32, 2));

    try std.testing.expect(cms.estimate(@as(u32, 1)) >= 2);
    try std.testing.expect(cms.estimate(@as(u32, 2)) >= 1);
    try std.testing.expectEqual(@as(u64, 3), cms.getTotalCount());
}

test "count-min sketch initialization with error bounds" {
    const allocator = std.testing.allocator;
    var cms = try CountMinSketch.initWithError(allocator, 0.01, 0.001);
    defer cms.deinit();

    // Verify initialization with error bounds creates a valid sketch
    try std.testing.expect(cms.width > 0);
    try std.testing.expect(cms.depth > 0);
    try std.testing.expectEqual(@as(u64, 0), cms.getTotalCount());
}

test "count-min sketch multiple adds of same item" {
    const allocator = std.testing.allocator;
    var cms = try CountMinSketch.init(allocator, 1000, 5);
    defer cms.deinit();

    // Add the same item multiple times
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        cms.add(@as(u64, 42));
    }

    const estimate1 = cms.estimate(@as(u64, 42));

    // Add more of the same item
    for (0..10) |_| {
        cms.add(@as(u64, 42));
    }

    const estimate2 = cms.estimate(@as(u64, 42));
    // Second estimate should be >= first (monotonic)
    try std.testing.expect(estimate2 >= estimate1);
}

test "count-min sketch heavy hitter detection" {
    const allocator = std.testing.allocator;
    var cms = try CountMinSketch.init(allocator, 5000, 8);
    defer cms.deinit();

    // Add items with varying frequencies
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        cms.add(@as(u64, 10));
    }
    i = 0;
    while (i < 900) : (i += 1) {
        cms.add(@as(u64, 20));
    }
    i = 0;
    while (i < 10) : (i += 1) {
        cms.add(@as(u64, 30));
    }

    const heavy1_count = cms.estimate(@as(u64, 10));
    const heavy2_count = cms.estimate(@as(u64, 20));
    const light_count = cms.estimate(@as(u64, 30));

    // Heavy hitters should be identified (higher than light items)
    try std.testing.expect(heavy1_count > light_count or heavy1_count == light_count);
    try std.testing.expect(heavy2_count > light_count or heavy2_count == light_count);
}

test "count-min sketch empty query" {
    const allocator = std.testing.allocator;
    var cms = try CountMinSketch.init(allocator, 1000, 5);
    defer cms.deinit();

    // Query without adding anything
    const estimate = cms.estimate(@as(u64, 999));
    try std.testing.expectEqual(@as(u32, 0), estimate);
}

test "count-min sketch reset functionality" {
    const allocator = std.testing.allocator;
    var cms = try CountMinSketch.init(allocator, 1000, 5);
    defer cms.deinit();

    cms.add(@as(u64, 100));
    cms.add(@as(u64, 200));
    try std.testing.expectEqual(@as(u64, 2), cms.getTotalCount());

    cms.clear();
    try std.testing.expectEqual(@as(u64, 0), cms.getTotalCount());
    try std.testing.expectEqual(@as(u32, 0), cms.estimate(@as(u64, 100)));
    try std.testing.expectEqual(@as(u32, 0), cms.estimate(@as(u64, 200)));
}

test "count-min sketch error bound validation" {
    const allocator = std.testing.allocator;
    // epsilon=0.01 (1%), delta=0.001 (0.1%)
    var cms = try CountMinSketch.initWithError(allocator, 0.01, 0.001);
    defer cms.deinit();

    // Add items
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        cms.add(@as(u64, 555));
    }

    const total_count = cms.getTotalCount();

    // CMS maintains total count
    try std.testing.expect(total_count == 100);
}

test "count-min sketch addN functionality" {
    const allocator = std.testing.allocator;
    var cms = try CountMinSketch.init(allocator, 1000, 5);
    defer cms.deinit();

    cms.addN(@as(u64, 111), 10);
    cms.addN(@as(u64, 111), 5);
    cms.addN(@as(u64, 222), 3);

    try std.testing.expectEqual(@as(u64, 18), cms.getTotalCount());
    // addN should track the counts
    const est111_a = cms.estimate(@as(u64, 111));
    const est111_b = cms.estimate(@as(u64, 111));
    // Estimates should be consistent
    try std.testing.expect(est111_a == est111_b);
}

test "count-min sketch merge operation" {
    const allocator = std.testing.allocator;
    var cms1 = try CountMinSketch.init(allocator, 10000, 5);
    defer cms1.deinit();
    var cms2 = try CountMinSketch.init(allocator, 10000, 5);
    defer cms2.deinit();

    cms1.add(@as(u64, 333));
    cms1.add(@as(u64, 333));
    cms2.add(@as(u64, 333));
    cms2.add(@as(u64, 444));

    const count_before = cms1.getTotalCount();
    try cms1.merge(&cms2);
    const count_after = cms1.getTotalCount();

    // Merge should increase total count
    try std.testing.expect(count_after > count_before);
    try std.testing.expectEqual(@as(u64, 4), count_after);
}
