//! HyperLogLog Implementation
//!
//! A probabilistic cardinality estimator using only O(log log n) space.
//! Estimates the number of distinct elements in a stream.
//!
//! Example:
//! ```zig
//! var hll = try HyperLogLog.init(allocator, 14); // 2^14 = 16384 registers
//! defer hll.deinit();
//!
//! hll.add("item1");
//! hll.add("item2");
//! hll.add("item1"); // duplicate
//! const cardinality = hll.estimate(); // Returns ~2
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

/// HyperLogLog cardinality estimator
pub const HyperLogLog = struct {
    registers: []u8,
    precision: u6, // p: number of bits for register index (typically 4-18)
    num_registers: usize, // m = 2^p
    alpha: f64, // correction constant
    allocator: Allocator,

    const Self = @This();

    /// Initialize with given precision (4-18)
    /// Higher precision = more memory but more accuracy
    /// Typical values: 12 (4KB, ~1.6% error), 14 (16KB, ~0.8% error)
    pub fn init(allocator: Allocator, precision: u6) !Self {
        if (precision < 4 or precision > 18) {
            return error.InvalidPrecision;
        }

        const num_registers = @as(usize, 1) << precision;
        const registers = try allocator.alloc(u8, num_registers);
        @memset(registers, 0);

        // Alpha correction constant
        const alpha: f64 = switch (precision) {
            4 => 0.673,
            5 => 0.697,
            6 => 0.709,
            else => 0.7213 / (1.0 + 1.079 / @as(f64, @floatFromInt(num_registers))),
        };

        return Self{
            .registers = registers,
            .precision = precision,
            .num_registers = num_registers,
            .alpha = alpha,
            .allocator = allocator,
        };
    }

    /// Initialize with target error rate
    /// error_rate: desired relative error (e.g., 0.01 for 1%)
    pub fn initWithError(allocator: Allocator, error_rate: f64) !Self {
        // Standard error ≈ 1.04 / sqrt(m)
        // m = (1.04 / error_rate)^2
        const m = @as(f64, 1.04) / error_rate;
        const m_sq = m * m;
        const p = @as(u6, @intFromFloat(@ceil(@log2(m_sq))));
        return init(allocator, @max(p, 4));
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.registers);
    }

    /// Add an item to the estimator
    pub fn add(self: *Self, item: anytype) void {
        // Hash directly to avoid slice lifetime issues with toBytes
        const hash = hashItem(item);

        // First p bits determine the register
        const p: u8 = @as(u8, self.precision);
        const shift_right: u6 = @intCast(64 - @as(u8, p));
        const register_idx = hash >> shift_right;

        // Remaining bits determine the rank (position of first 1-bit)
        const shift_left: u6 = @intCast(p);
        const remaining = hash << shift_left;
        const clz_val: u8 = @intCast(@clz(remaining));
        const rank: u8 = if (remaining == 0)
            65 - p
        else
            clz_val + 1;

        // Update register with max
        self.registers[register_idx] = @max(self.registers[register_idx], rank);
    }

    /// Estimate cardinality
    pub fn estimate(self: *const Self) u64 {
        const m = @as(f64, @floatFromInt(self.num_registers));

        // Compute harmonic mean of 2^(-register[i])
        var sum: f64 = 0;
        var zeros: usize = 0;

        for (self.registers) |reg| {
            if (reg == 0) zeros += 1;
            sum += math.pow(f64, 2.0, -@as(f64, @floatFromInt(reg)));
        }

        // Raw estimate
        var estimate_val = self.alpha * m * m / sum;

        // Apply corrections
        if (estimate_val <= 2.5 * m) {
            // Small range correction (linear counting)
            if (zeros > 0) {
                estimate_val = m * @log(m / @as(f64, @floatFromInt(zeros)));
            }
        } else if (estimate_val > (1.0 / 30.0) * math.pow(f64, 2.0, 32.0)) {
            // Large range correction
            estimate_val = -math.pow(f64, 2.0, 32.0) *
                @log(1.0 - estimate_val / math.pow(f64, 2.0, 32.0));
        }

        return @intFromFloat(@max(estimate_val, 0));
    }

    /// Get relative standard error
    pub fn standardError(self: *const Self) f64 {
        return 1.04 / @sqrt(@as(f64, @floatFromInt(self.num_registers)));
    }

    /// Merge another HyperLogLog into this one
    pub fn merge(self: *Self, other: *const Self) !void {
        if (self.precision != other.precision) {
            return error.IncompatiblePrecision;
        }

        for (self.registers, other.registers) |*a, b| {
            a.* = @max(a.*, b);
        }
    }

    /// Clear the estimator
    pub fn clear(self: *Self) void {
        @memset(self.registers, 0);
    }

    /// Get memory usage in bytes
    pub fn memoryUsage(self: *const Self) usize {
        return self.num_registers;
    }

    /// Serialize registers
    pub fn serialize(self: *const Self) []const u8 {
        return self.registers;
    }

    /// Deserialize registers
    pub fn deserialize(self: *Self, data: []const u8) !void {
        if (data.len != self.num_registers) {
            return error.InvalidData;
        }
        @memcpy(self.registers, data);
    }

    fn hashItem(item: anytype) u64 {
        const T = @TypeOf(item);
        if (T == []const u8) {
            return std.hash.Wyhash.hash(0, item);
        } else if (@typeInfo(T) == .pointer) {
            const child = @typeInfo(T).pointer.child;
            if (child == u8) {
                return std.hash.Wyhash.hash(0, item);
            }
        }
        // For non-slice types, hash the bytes directly while they're still in scope
        const bytes = std.mem.asBytes(&item);
        return std.hash.Wyhash.hash(0, bytes);
    }
};

/// HyperLogLog++ with sparse representation for small cardinalities
pub const HyperLogLogPlusPlus = struct {
    hll: ?HyperLogLog,
    sparse: ?std.AutoHashMap(u64, u8),
    precision: u6,
    sparse_threshold: usize,
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator, precision: u6) !Self {
        return Self{
            .hll = null,
            .sparse = std.AutoHashMap(u64, u8).init(allocator),
            .precision = precision,
            .sparse_threshold = @as(usize, 1) << @min(precision, 10),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.hll) |*hll| hll.deinit();
        if (self.sparse) |*sparse| sparse.deinit();
    }

    pub fn add(self: *Self, item: anytype) !void {
        const hash = hashItem(item);

        if (self.sparse) |*sparse| {
            const p: u8 = @as(u8, self.precision);
            const shift_right: u6 = @intCast(64 - @as(u8, p));
            const register_idx = hash >> shift_right;
            const shift_left: u6 = @intCast(p);
            const remaining = hash << shift_left;
            const clz_val: u8 = @intCast(@clz(remaining));
            const rank: u8 = if (remaining == 0)
                65 - p
            else
                clz_val + 1;

            const result = try sparse.getOrPut(register_idx);
            if (!result.found_existing or result.value_ptr.* < rank) {
                result.value_ptr.* = rank;
            }

            // Convert to dense if threshold exceeded
            if (sparse.count() > self.sparse_threshold) {
                try self.convertToDense();
            }
        } else if (self.hll) |*hll| {
            hll.add(item);
        }
    }

    pub fn estimate(self: *const Self) u64 {
        if (self.hll) |*hll| {
            return hll.estimate();
        } else if (self.sparse) |sparse| {
            // Linear counting for sparse mode
            return sparse.count();
        }
        return 0;
    }

    fn convertToDense(self: *Self) !void {
        var hll = try HyperLogLog.init(self.allocator, self.precision);

        if (self.sparse) |*sparse| {
            var it = sparse.iterator();
            while (it.next()) |entry| {
                hll.registers[entry.key_ptr.*] = entry.value_ptr.*;
            }
            sparse.deinit();
            self.sparse = null;
        }

        self.hll = hll;
    }

    fn hashItem(item: anytype) u64 {
        const T = @TypeOf(item);
        if (T == []const u8) {
            return std.hash.Wyhash.hash(0, item);
        } else if (@typeInfo(T) == .pointer) {
            const child = @typeInfo(T).pointer.child;
            if (child == u8) {
                return std.hash.Wyhash.hash(0, item);
            }
        }
        // For non-slice types, hash the bytes directly while they're still in scope
        const bytes = std.mem.asBytes(&item);
        return std.hash.Wyhash.hash(0, bytes);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "hyperloglog basic cardinality" {
    const allocator = std.testing.allocator;
    var hll = try HyperLogLog.init(allocator, 14);
    defer hll.deinit();

    // Add unique items
    var i: u64 = 0;
    while (i < 10000) : (i += 1) {
        hll.add(i);
    }

    const estimate = hll.estimate();
    // Should be within 5% of actual
    try std.testing.expect(estimate >= 9500 and estimate <= 10500);
}

test "hyperloglog with duplicates" {
    const allocator = std.testing.allocator;
    var hll = try HyperLogLog.init(allocator, 12);
    defer hll.deinit();

    // Add items with many duplicates
    var i: u64 = 0;
    while (i < 100000) : (i += 1) {
        hll.add(i % 1000); // Only 1000 unique items
    }

    const estimate = hll.estimate();
    // Should be close to 1000
    try std.testing.expect(estimate >= 900 and estimate <= 1100);
}

test "hyperloglog merge" {
    const allocator = std.testing.allocator;
    var hll1 = try HyperLogLog.init(allocator, 12);
    defer hll1.deinit();
    var hll2 = try HyperLogLog.init(allocator, 12);
    defer hll2.deinit();

    // Add different items to each
    var i: u64 = 0;
    while (i < 5000) : (i += 1) {
        hll1.add(i);
        hll2.add(i + 5000);
    }

    try hll1.merge(&hll2);
    const estimate = hll1.estimate();

    // Should be close to 10000
    try std.testing.expect(estimate >= 9000 and estimate <= 11000);
}

test "hyperloglog standard error" {
    const allocator = std.testing.allocator;
    var hll = try HyperLogLog.init(allocator, 14);
    defer hll.deinit();

    const error_rate = hll.standardError();
    // p=14 should give ~0.8% error
    try std.testing.expect(error_rate < 0.01);
}

test "hyperloglog empty cardinality" {
    const allocator = std.testing.allocator;
    var hll = try HyperLogLog.init(allocator, 14);
    defer hll.deinit();

    // Empty HLL should estimate near zero
    const estimate = hll.estimate();
    try std.testing.expect(estimate == 0 or estimate <= 10);
}

test "hyperloglog single element" {
    const allocator = std.testing.allocator;
    var hll = try HyperLogLog.init(allocator, 14);
    defer hll.deinit();

    hll.add("single");

    const estimate = hll.estimate();
    // Should estimate ~1 element
    try std.testing.expect(estimate >= 1 and estimate <= 5);
}

test "hyperloglog known cardinality" {
    const allocator = std.testing.allocator;
    var hll = try HyperLogLog.init(allocator, 12);
    defer hll.deinit();

    const num_items: u64 = 5000;
    var i: u64 = 0;
    while (i < num_items) : (i += 1) {
        hll.add(i);
    }

    const estimate = hll.estimate();
    const error_bound = @as(f64, @floatFromInt(num_items)) * 0.1; // 10% error margin

    try std.testing.expect(estimate >= @as(u64, @intFromFloat(@as(f64, @floatFromInt(num_items)) - error_bound)));
    try std.testing.expect(estimate <= @as(u64, @intFromFloat(@as(f64, @floatFromInt(num_items)) + error_bound)));
}

test "hyperloglog duplicate element handling" {
    const allocator = std.testing.allocator;
    var hll = try HyperLogLog.init(allocator, 14);
    defer hll.deinit();

    // Add the same element multiple times
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        hll.add("duplicate");
    }

    const estimate = hll.estimate();
    // Should still estimate ~1 element
    try std.testing.expect(estimate == 1 or estimate <= 5);
}

test "hyperloglog merge same items" {
    const allocator = std.testing.allocator;
    var hll1 = try HyperLogLog.init(allocator, 12);
    defer hll1.deinit();
    var hll2 = try HyperLogLog.init(allocator, 12);
    defer hll2.deinit();

    // Add same items to both HLLs
    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        hll1.add(i);
        hll2.add(i);
    }

    try hll1.merge(&hll2);
    const estimate = hll1.estimate();

    // After merge, should still be ~1000
    try std.testing.expect(estimate >= 900 and estimate <= 1100);
}

test "hyperloglog large cardinality" {
    const allocator = std.testing.allocator;
    var hll = try HyperLogLog.init(allocator, 14);
    defer hll.deinit();

    const num_items: u64 = 50000;
    var i: u64 = 0;
    while (i < num_items) : (i += 1) {
        hll.add(i);
    }

    const estimate = hll.estimate();
    const error_rate = hll.standardError();
    const error_bound = @as(f64, @floatFromInt(num_items)) * error_rate * 2.0; // 2-sigma

    try std.testing.expect(estimate >= @as(u64, @intFromFloat(@as(f64, @floatFromInt(num_items)) - error_bound)));
    try std.testing.expect(estimate <= @as(u64, @intFromFloat(@as(f64, @floatFromInt(num_items)) + error_bound)));
}

test "hyperloglog precision bounds" {
    const allocator = std.testing.allocator;

    // Test precision 4 (minimum)
    var hll_p4 = try HyperLogLog.init(allocator, 4);
    defer hll_p4.deinit();
    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        hll_p4.add(i);
    }
    try std.testing.expect(hll_p4.estimate() > 0);

    // Test precision 18 (maximum)
    var hll_p18 = try HyperLogLog.init(allocator, 18);
    defer hll_p18.deinit();
    i = 0;
    while (i < 100) : (i += 1) {
        hll_p18.add(i);
    }
    try std.testing.expect(hll_p18.estimate() > 0);
    // Higher precision should have lower error
    try std.testing.expect(hll_p18.standardError() < hll_p4.standardError());
}

test "hyperloglog with string items" {
    const allocator = std.testing.allocator;
    var hll = try HyperLogLog.init(allocator, 12);
    defer hll.deinit();

    hll.add("hello");
    hll.add("world");
    hll.add("hello"); // duplicate
    hll.add("test");

    const estimate = hll.estimate();
    // Should estimate ~3 unique items
    try std.testing.expect(estimate >= 2 and estimate <= 5);
}

test "hyperloglog clear operation" {
    const allocator = std.testing.allocator;
    var hll = try HyperLogLog.init(allocator, 14);
    defer hll.deinit();

    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        hll.add(i);
    }

    try std.testing.expect(hll.estimate() > 100);

    hll.clear();
    try std.testing.expect(hll.estimate() == 0 or hll.estimate() <= 10);
}
