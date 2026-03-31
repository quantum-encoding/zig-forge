const std = @import("std");

/// Generic fixed-size ring buffer.
/// Power-of-two size for branchless modular indexing via bitmask.
/// Single-owner: no atomics, no locking. For multi-core, use SPSC queue.
///
/// Two usage modes:
///   1. FIFO queue — enqueue/dequeue for passing items between pipeline stages
///   2. Indexed access — at() for direct descriptor slot manipulation by NIC drivers
pub fn Ring(comptime T: type) type {
    return struct {
        const Self = @This();

        entries: [*]T,
        size: u32,
        mask: u32,
        head: u32,
        tail: u32,

        /// Initialize ring over pre-allocated memory.
        /// `ring_size` MUST be a power of two.
        pub fn init(buffer: [*]T, ring_size: u32) Self {
            std.debug.assert(ring_size > 0 and std.math.isPowerOfTwo(ring_size));
            return .{
                .entries = buffer,
                .size = ring_size,
                .mask = ring_size - 1,
                .head = 0,
                .tail = 0,
            };
        }

        // ── Indexed access (for NIC descriptor rings) ─────────────────────

        /// Direct access by absolute index (wraps via mask).
        pub inline fn at(self: *Self, index: u32) *T {
            return &self.entries[index & self.mask];
        }

        pub inline fn constAt(self: *const Self, index: u32) *const T {
            return &self.entries[index & self.mask];
        }

        // ── FIFO operations ───────────────────────────────────────────────

        /// Push one item. Returns false if ring is full.
        pub fn enqueue(self: *Self, item: T) bool {
            if (self.isFull()) return false;
            self.entries[self.head & self.mask] = item;
            self.head +%= 1;
            return true;
        }

        /// Pop one item. Returns null if ring is empty.
        pub fn dequeue(self: *Self) ?T {
            if (self.isEmpty()) return null;
            const item = self.entries[self.tail & self.mask];
            self.tail +%= 1;
            return item;
        }

        /// Bulk enqueue. Returns number of items actually enqueued.
        pub fn enqueueBulk(self: *Self, items: []const T) u32 {
            const avail = self.freeCount();
            const n: u32 = @intCast(@min(items.len, avail));
            for (0..n) |i| {
                self.entries[(self.head +% @as(u32, @intCast(i))) & self.mask] = items[i];
            }
            self.head +%= n;
            return n;
        }

        /// Bulk dequeue into caller's buffer. Returns number actually dequeued.
        pub fn dequeueBulk(self: *Self, out: []T) u32 {
            const avail = self.count();
            const n: u32 = @intCast(@min(out.len, avail));
            for (0..n) |i| {
                out[i] = self.entries[(self.tail +% @as(u32, @intCast(i))) & self.mask];
            }
            self.tail +%= n;
            return n;
        }

        // ── Status (all branchless single-expression) ─────────────────────

        /// Number of items currently in the ring.
        pub inline fn count(self: *const Self) u32 {
            return self.head -% self.tail;
        }

        /// Number of free slots.
        pub inline fn freeCount(self: *const Self) u32 {
            return self.size - self.count();
        }

        pub inline fn isEmpty(self: *const Self) bool {
            return self.head == self.tail;
        }

        pub inline fn isFull(self: *const Self) bool {
            return self.count() == self.size;
        }

        /// Reset head and tail to zero. Does NOT clear entries.
        pub fn reset(self: *Self) void {
            self.head = 0;
            self.tail = 0;
        }
    };
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Ring: init and empty state" {
    var buf: [8]u32 = undefined;
    var ring = Ring(u32).init(&buf, 8);

    try testing.expect(ring.isEmpty());
    try testing.expect(!ring.isFull());
    try testing.expectEqual(@as(u32, 0), ring.count());
    try testing.expectEqual(@as(u32, 8), ring.freeCount());
}

test "Ring: enqueue and dequeue" {
    var buf: [4]u32 = undefined;
    var ring = Ring(u32).init(&buf, 4);

    try testing.expect(ring.enqueue(10));
    try testing.expect(ring.enqueue(20));
    try testing.expect(ring.enqueue(30));
    try testing.expect(ring.enqueue(40));
    try testing.expect(!ring.enqueue(50)); // full

    try testing.expect(ring.isFull());
    try testing.expectEqual(@as(u32, 4), ring.count());

    try testing.expectEqual(@as(u32, 10), ring.dequeue().?);
    try testing.expectEqual(@as(u32, 20), ring.dequeue().?);
    try testing.expectEqual(@as(u32, 2), ring.count());

    // Can enqueue again after dequeue
    try testing.expect(ring.enqueue(50));
    try testing.expect(ring.enqueue(60));
    try testing.expect(ring.isFull());

    try testing.expectEqual(@as(u32, 30), ring.dequeue().?);
    try testing.expectEqual(@as(u32, 40), ring.dequeue().?);
    try testing.expectEqual(@as(u32, 50), ring.dequeue().?);
    try testing.expectEqual(@as(u32, 60), ring.dequeue().?);
    try testing.expect(ring.isEmpty());
    try testing.expectEqual(@as(?u32, null), ring.dequeue());
}

test "Ring: bulk operations" {
    var buf: [8]u32 = undefined;
    var ring = Ring(u32).init(&buf, 8);

    const items = [_]u32{ 1, 2, 3, 4, 5 };
    try testing.expectEqual(@as(u32, 5), ring.enqueueBulk(&items));
    try testing.expectEqual(@as(u32, 5), ring.count());

    var out: [3]u32 = undefined;
    try testing.expectEqual(@as(u32, 3), ring.dequeueBulk(&out));
    try testing.expectEqual(@as(u32, 1), out[0]);
    try testing.expectEqual(@as(u32, 2), out[1]);
    try testing.expectEqual(@as(u32, 3), out[2]);
    try testing.expectEqual(@as(u32, 2), ring.count());
}

test "Ring: wrap-around stress" {
    var buf: [4]u32 = undefined;
    var ring = Ring(u32).init(&buf, 4);

    // Fill and drain multiple times to exercise wrap-around
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try testing.expect(ring.enqueue(i));
        try testing.expectEqual(i, ring.dequeue().?);
    }
    try testing.expect(ring.isEmpty());
}

test "Ring: indexed access" {
    var buf = [_]u32{ 10, 20, 30, 40 };
    var ring = Ring(u32).init(&buf, 4);

    try testing.expectEqual(@as(u32, 10), ring.at(0).*);
    try testing.expectEqual(@as(u32, 20), ring.at(1).*);
    try testing.expectEqual(@as(u32, 30), ring.at(2).*);
    try testing.expectEqual(@as(u32, 40), ring.at(3).*);
    // Wraps around
    try testing.expectEqual(@as(u32, 10), ring.at(4).*);
    try testing.expectEqual(@as(u32, 20), ring.at(5).*);

    // Modify via at()
    ring.at(0).* = 100;
    try testing.expectEqual(@as(u32, 100), ring.at(4).*); // same slot
}

test "Ring: u32 overflow wrap" {
    var buf: [4]u32 = undefined;
    var ring = Ring(u32).init(&buf, 4);

    // Advance head/tail near u32 max to test wrapping arithmetic
    ring.head = std.math.maxInt(u32) - 1;
    ring.tail = std.math.maxInt(u32) - 1;

    try testing.expect(ring.isEmpty());
    try testing.expect(ring.enqueue(1));
    try testing.expect(ring.enqueue(2));
    try testing.expectEqual(@as(u32, 2), ring.count());
    try testing.expectEqual(@as(u32, 1), ring.dequeue().?);
    try testing.expectEqual(@as(u32, 2), ring.dequeue().?);
    try testing.expect(ring.isEmpty());
}

test "Ring: bulk enqueue overflow" {
    var buf: [4]u32 = undefined;
    var ring = Ring(u32).init(&buf, 4);

    const items = [_]u32{ 1, 2, 3, 4, 5, 6 };
    // Only 4 fit
    try testing.expectEqual(@as(u32, 4), ring.enqueueBulk(&items));
    try testing.expect(ring.isFull());

    var out: [8]u32 = undefined;
    // Only 4 available
    try testing.expectEqual(@as(u32, 4), ring.dequeueBulk(&out));
    try testing.expectEqual(@as(u32, 1), out[0]);
    try testing.expectEqual(@as(u32, 4), out[3]);
    try testing.expect(ring.isEmpty());
}
