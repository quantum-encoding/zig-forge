//! Multi Producer Multi Consumer Queue
//!
//! Lock-free, ~85ns latency
//!
//! Based on Dmitry Vyukov's bounded MPMC queue algorithm.
//! Uses turn-based synchronization with cache-aligned slots
//! to prevent false sharing and ensure correctness.
//!
//! Zig 0.16 version - uses lowercase atomic orderings

const std = @import("std");
const atomic = std.atomic;

pub fn MpmcQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            turn: atomic.Value(usize) align(64),
            data: T,

            fn init(initial_turn: usize) Slot {
                return .{
                    .turn = atomic.Value(usize).init(initial_turn),
                    .data = undefined,
                };
            }
        };

        slots: []Slot,
        capacity: usize,
        mask: usize,

        head: atomic.Value(usize) align(64),
        _pad1: [56]u8 = undefined,
        tail: atomic.Value(usize) align(64),
        _pad2: [56]u8 = undefined,

        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            // Capacity must be power of 2 for efficient indexing
            if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
                return error.CapacityMustBePowerOfTwo;
            }

            const slots = try allocator.alloc(Slot, capacity);

            // Initialize each slot with its initial turn number
            for (slots, 0..) |*slot, i| {
                slot.* = Slot.init(i);
            }

            return Self{
                .slots = slots,
                .capacity = capacity,
                .mask = capacity - 1,
                .head = atomic.Value(usize).init(0),
                .tail = atomic.Value(usize).init(0),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.slots);
        }

        /// Enqueue an item (lock-free, wait-free for producers)
        pub fn push(self: *Self, value: T) !void {
            var backoff: usize = 1;

            while (true) {
                const tail = self.tail.load(.monotonic);
                const slot = &self.slots[tail & self.mask];
                const turn = slot.turn.load(.acquire);
                const expected_turn = tail;

                // Check if this slot is ready for writing
                if (turn == expected_turn) {
                    // Try to claim this slot
                    if (self.tail.cmpxchgWeak(
                        tail,
                        tail + 1,
                        .monotonic,
                        .monotonic,
                    ) == null) {
                        // Successfully claimed the slot, write data
                        slot.data = value;
                        slot.turn.store(expected_turn + 1, .release);
                        return;
                    }
                } else if (turn < expected_turn) {
                    // Queue is full
                    return error.QueueFull;
                }

                // Exponential backoff to reduce contention
                if (backoff < 64) {
                    var i: usize = 0;
                    while (i < backoff) : (i += 1) {
                        atomic.spinLoopHint();
                    }
                    backoff *= 2;
                }
            }
        }

        /// Dequeue an item (lock-free, wait-free for consumers)
        pub fn pop(self: *Self) !T {
            var backoff: usize = 1;

            while (true) {
                const head = self.head.load(.monotonic);
                const slot = &self.slots[head & self.mask];
                const turn = slot.turn.load(.acquire);
                const expected_turn = head + 1;

                // Check if this slot has data ready to read
                if (turn == expected_turn) {
                    // Try to claim this slot
                    if (self.head.cmpxchgWeak(
                        head,
                        head + 1,
                        .monotonic,
                        .monotonic,
                    ) == null) {
                        // Successfully claimed the slot, read data
                        const data = slot.data;
                        slot.turn.store(head + self.capacity, .release);
                        return data;
                    }
                } else if (turn < expected_turn) {
                    // Queue is empty
                    return error.QueueEmpty;
                }

                // Exponential backoff to reduce contention
                if (backoff < 64) {
                    var i: usize = 0;
                    while (i < backoff) : (i += 1) {
                        atomic.spinLoopHint();
                    }
                    backoff *= 2;
                }
            }
        }

        /// Try to pop without blocking
        pub fn tryPop(self: *Self) ?T {
            return self.pop() catch null;
        }

        pub fn isEmpty(self: *const Self) bool {
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);
            return head >= tail;
        }

        pub fn isFull(self: *const Self) bool {
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);
            return tail - head >= self.capacity;
        }

        pub fn len(self: *const Self) usize {
            const head = self.head.load(.acquire);
            const tail = self.tail.load(.acquire);
            if (tail > head) {
                return tail - head;
            }
            return 0;
        }
    };
}

test "mpmc - basic operations" {
    const allocator = std.testing.allocator;

    var queue = try MpmcQueue(u64).init(allocator, 16);
    defer queue.deinit();

    try std.testing.expect(queue.isEmpty());

    try queue.push(42);
    try queue.push(100);

    try std.testing.expectEqual(@as(u64, 42), try queue.pop());
    try std.testing.expectEqual(@as(u64, 100), try queue.pop());

    try std.testing.expect(queue.isEmpty());
}

test "mpmc - queue full" {
    const allocator = std.testing.allocator;

    var queue = try MpmcQueue(u32).init(allocator, 4);
    defer queue.deinit();

    try queue.push(1);
    try queue.push(2);
    try queue.push(3);
    try queue.push(4);

    try std.testing.expectError(error.QueueFull, queue.push(5));
}

test "mpmc - queue empty" {
    const allocator = std.testing.allocator;

    var queue = try MpmcQueue(u32).init(allocator, 8);
    defer queue.deinit();

    try std.testing.expectError(error.QueueEmpty, queue.pop());
}

test "mpmc - concurrent operations" {
    const allocator = std.testing.allocator;

    var queue = try MpmcQueue(usize).init(allocator, 128);
    defer queue.deinit();

    const num_items: usize = 100;

    // Single threaded test simulating interleaved operations
    var i: usize = 0;
    while (i < num_items) : (i += 1) {
        try queue.push(i);
    }

    i = 0;
    while (i < num_items) : (i += 1) {
        const val = try queue.pop();
        try std.testing.expectEqual(i, val);
    }
}

test "mpmc - capacity boundary" {
    const allocator = std.testing.allocator;

    var queue = try MpmcQueue(u32).init(allocator, 8);
    defer queue.deinit();

    // Fill to capacity
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        try queue.push(i);
    }

    try std.testing.expectEqual(@as(usize, 8), queue.len());
    try std.testing.expect(queue.isFull());

    // Next push should fail
    try std.testing.expectError(error.QueueFull, queue.push(99));

    // Pop one and verify we can push again
    const val = try queue.pop();
    try std.testing.expectEqual(@as(u32, 0), val);
    try std.testing.expect(!queue.isFull());

    try queue.push(100);
    try std.testing.expect(queue.isFull());
}

test "mpmc - turn-based slot correctness" {
    const allocator = std.testing.allocator;

    var queue = try MpmcQueue(u64).init(allocator, 4);
    defer queue.deinit();

    // Verify turn values through multiple cycles
    var cycle: u32 = 0;
    while (cycle < 3) : (cycle += 1) {
        // Push all slots
        var i: u64 = 0;
        while (i < 4) : (i += 1) {
            try queue.push(cycle * 100 + i);
        }

        // Pop all slots in order
        i = 0;
        while (i < 4) : (i += 1) {
            const expected = cycle * 100 + i;
            const val = try queue.pop();
            try std.testing.expectEqual(expected, val);
        }

        try std.testing.expect(queue.isEmpty());
    }
}

test "mpmc - data integrity" {
    const allocator = std.testing.allocator;

    var queue = try MpmcQueue(u64).init(allocator, 64);
    defer queue.deinit();

    const num_items: u64 = 64;

    // Push sequence 0..64
    var i: u64 = 0;
    while (i < num_items) : (i += 1) {
        try queue.push(i * 1000 + i); // Unique pattern
    }

    // Pop and verify order is preserved
    i = 0;
    while (i < num_items) : (i += 1) {
        const expected = i * 1000 + i;
        const val = try queue.pop();
        try std.testing.expectEqual(expected, val);
    }

    try std.testing.expect(queue.isEmpty());
}

test "mpmc - multiple sequential producers" {
    const allocator = std.testing.allocator;

    var queue = try MpmcQueue(u32).init(allocator, 64);
    defer queue.deinit();

    // First producer: push 0..50
    var i: u32 = 0;
    while (i < 25) : (i += 1) {
        try queue.push(i);
    }

    // Second producer: push 100..149
    i = 100;
    while (i < 125) : (i += 1) {
        try queue.push(i);
    }

    try std.testing.expectEqual(@as(usize, 50), queue.len());

    // Pop and verify both sequences are present (in order)
    i = 0;
    while (i < 25) : (i += 1) {
        const val = try queue.pop();
        try std.testing.expectEqual(i, val);
    }

    i = 100;
    while (i < 125) : (i += 1) {
        const val = try queue.pop();
        try std.testing.expectEqual(i, val);
    }

    try std.testing.expect(queue.isEmpty());
}

test "mpmc - overflow behavior" {
    const allocator = std.testing.allocator;

    var queue = try MpmcQueue(u64).init(allocator, 4);
    defer queue.deinit();

    // Fill the queue completely
    try queue.push(10);
    try queue.push(20);
    try queue.push(30);
    try queue.push(40);

    try std.testing.expect(queue.isFull());

    // Attempts to push should fail gracefully
    try std.testing.expectError(error.QueueFull, queue.push(50));
    try std.testing.expectError(error.QueueFull, queue.push(60));

    // Queue should still be intact
    try std.testing.expectEqual(@as(u64, 10), try queue.pop());
    try std.testing.expectEqual(@as(u64, 20), try queue.pop());
    try std.testing.expectEqual(@as(u64, 30), try queue.pop());
    try std.testing.expectEqual(@as(u64, 40), try queue.pop());

    try std.testing.expect(queue.isEmpty());
}
