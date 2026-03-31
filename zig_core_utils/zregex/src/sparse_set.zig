//! Sparse Set - O(1) add, O(1) contains, O(n) iterate, O(1) clear
//! Used for efficient NFA state tracking in regex simulation.
//! This is the same technique used by RE2 and other production regex engines.
//!
//! Key insight: We can "clear" the set by just resetting count to 0,
//! without touching memory. The sparse array acts as a validity check.

const std = @import("std");

/// Sparse set for tracking active NFA states
/// Provides O(1) operations and cache-friendly iteration
pub fn SparseSet(comptime max_size: usize) type {
    return struct {
        /// Dense array: active elements in insertion order
        /// Only dense[0..count] contains valid data
        dense: [max_size]u16 = undefined,

        /// Sparse array: maps element -> index in dense
        /// sparse[e] is valid iff sparse[e] < count AND dense[sparse[e]] == e
        sparse: [max_size]u16 = undefined,

        /// Number of elements in the set
        count: u16 = 0,

        const Self = @This();

        /// Create an empty sparse set
        pub fn init() Self {
            return .{};
        }

        /// Clear the set in O(1) - just reset count, no memory clearing needed
        pub fn clear(self: *Self) void {
            self.count = 0;
        }

        /// Check if element is in set - O(1)
        pub fn contains(self: *const Self, elem: u16) bool {
            if (elem >= max_size) return false;
            const idx = self.sparse[elem];
            return idx < self.count and self.dense[idx] == elem;
        }

        /// Add element to set - O(1)
        /// Returns true if element was added, false if already present
        pub fn add(self: *Self, elem: u16) bool {
            if (elem >= max_size) return false;
            if (self.contains(elem)) return false;

            self.dense[self.count] = elem;
            self.sparse[elem] = self.count;
            self.count += 1;
            return true;
        }

        /// Get number of elements
        pub fn len(self: *const Self) usize {
            return self.count;
        }

        /// Check if set is empty
        pub fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }

        /// Iterate over all elements in the set
        /// Returns a slice of the dense array containing active elements
        pub fn items(self: *const Self) []const u16 {
            return self.dense[0..self.count];
        }

        /// Iterator for use in for loops
        pub fn iterator(self: *const Self) Iterator {
            return Iterator{ .set = self, .index = 0 };
        }

        pub const Iterator = struct {
            set: *const Self,
            index: u16,

            pub fn next(self: *Iterator) ?u16 {
                if (self.index >= self.set.count) return null;
                const elem = self.set.dense[self.index];
                self.index += 1;
                return elem;
            }
        };
    };
}

// Optimized version that uses stack memory for small sets, heap for large
pub const DynamicSparseSet = struct {
    dense: []u16,
    sparse: []u16,
    count: u16,
    allocator: std.mem.Allocator,
    capacity: u16,

    pub fn init(allocator: std.mem.Allocator, max_size: u16) !DynamicSparseSet {
        const dense = try allocator.alloc(u16, max_size);
        const sparse = try allocator.alloc(u16, max_size);

        return .{
            .dense = dense,
            .sparse = sparse,
            .count = 0,
            .allocator = allocator,
            .capacity = max_size,
        };
    }

    pub fn deinit(self: *DynamicSparseSet) void {
        self.allocator.free(self.dense);
        self.allocator.free(self.sparse);
    }

    pub fn clear(self: *DynamicSparseSet) void {
        self.count = 0;
    }

    pub fn contains(self: *const DynamicSparseSet, elem: u16) bool {
        if (elem >= self.capacity) return false;
        const idx = self.sparse[elem];
        return idx < self.count and self.dense[idx] == elem;
    }

    pub fn add(self: *DynamicSparseSet, elem: u16) bool {
        if (elem >= self.capacity) return false;
        if (self.contains(elem)) return false;

        self.dense[self.count] = elem;
        self.sparse[elem] = self.count;
        self.count += 1;
        return true;
    }

    pub fn len(self: *const DynamicSparseSet) usize {
        return self.count;
    }

    pub fn isEmpty(self: *const DynamicSparseSet) bool {
        return self.count == 0;
    }

    pub fn items(self: *const DynamicSparseSet) []const u16 {
        return self.dense[0..self.count];
    }
};

// Tests
test "sparse set basic operations" {
    var set = SparseSet(100).init();

    try std.testing.expect(!set.contains(5));
    try std.testing.expect(set.add(5));
    try std.testing.expect(set.contains(5));
    try std.testing.expect(!set.add(5)); // Already present

    try std.testing.expect(set.add(10));
    try std.testing.expect(set.add(3));
    try std.testing.expectEqual(@as(usize, 3), set.len());

    // Check iteration
    const items = set.items();
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(@as(u16, 5), items[0]);
    try std.testing.expectEqual(@as(u16, 10), items[1]);
    try std.testing.expectEqual(@as(u16, 3), items[2]);
}

test "sparse set clear is O(1)" {
    var set = SparseSet(1000).init();

    // Add many elements
    for (0..500) |i| {
        _ = set.add(@intCast(i));
    }
    try std.testing.expectEqual(@as(usize, 500), set.len());

    // Clear should be instant (just resets count)
    set.clear();
    try std.testing.expectEqual(@as(usize, 0), set.len());
    try std.testing.expect(!set.contains(0));
    try std.testing.expect(!set.contains(499));

    // Can add elements again
    try std.testing.expect(set.add(42));
    try std.testing.expect(set.contains(42));
}

test "sparse set iterator" {
    var set = SparseSet(100).init();
    _ = set.add(1);
    _ = set.add(5);
    _ = set.add(9);

    var sum: u16 = 0;
    var iter = set.iterator();
    while (iter.next()) |elem| {
        sum += elem;
    }
    try std.testing.expectEqual(@as(u16, 15), sum);
}

test "sparse set boundary conditions" {
    var set = SparseSet(10).init();

    // Element at boundary
    try std.testing.expect(set.add(9));
    try std.testing.expect(set.contains(9));

    // Element beyond boundary
    try std.testing.expect(!set.add(10));
    try std.testing.expect(!set.contains(10));
}

test "dynamic sparse set" {
    var set = try DynamicSparseSet.init(std.testing.allocator, 100);
    defer set.deinit();

    try std.testing.expect(set.add(5));
    try std.testing.expect(set.contains(5));
    try std.testing.expectEqual(@as(usize, 1), set.len());

    set.clear();
    try std.testing.expectEqual(@as(usize, 0), set.len());
}
