//! Work-stealing deque for task scheduler
//!
//! Lock-free deque that allows:
//! - Owner pushes/pops from bottom (LIFO for cache locality)
//! - Stealers pop from top (FIFO for load balancing)
//!
//! Based on Chase-Lev algorithm for optimal performance

const std = @import("std");
const atomic = std.atomic;

pub fn WorkStealDeque(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Circular array for storing tasks
        const Array = struct {
            buffer: []T,
            capacity: usize,

            pub fn init(allocator: std.mem.Allocator, capacity: usize) !*Array {
                const arr = try allocator.create(Array);
                arr.buffer = try allocator.alloc(T, capacity);
                arr.capacity = capacity;
                return arr;
            }

            pub fn deinit(self: *Array, allocator: std.mem.Allocator) void {
                allocator.free(self.buffer);
                allocator.destroy(self);
            }

            pub fn get(self: *const Array, index: i64) T {
                return self.buffer[@as(usize, @intCast(@mod(index, @as(i64, @intCast(self.capacity)))))];
            }

            pub fn put(self: *Array, index: i64, value: T) void {
                self.buffer[@as(usize, @intCast(@mod(index, @as(i64, @intCast(self.capacity)))))] = value;
            }

            pub fn grow(self: *Array, allocator: std.mem.Allocator, bottom: i64, top: i64) !*Array {
                const new_capacity = self.capacity * 2;
                const new_arr = try Array.init(allocator, new_capacity);

                var i = top;
                while (i < bottom) : (i += 1) {
                    new_arr.put(i, self.get(i));
                }

                return new_arr;
            }
        };

        allocator: std.mem.Allocator,
        array: atomic.Value(*Array),
        top: atomic.Value(i64),
        bottom: atomic.Value(i64),

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const arr = try Array.init(allocator, capacity);

            return Self{
                .allocator = allocator,
                .array = atomic.Value(*Array).init(arr),
                .top = atomic.Value(i64).init(0),
                .bottom = atomic.Value(i64).init(0),
            };
        }

        pub fn deinit(self: *Self) void {
            const arr = self.array.load(.monotonic);
            arr.deinit(self.allocator);
        }

        /// Push task to bottom (owner only)
        pub fn push(self: *Self, value: T) !void {
            const bottom = self.bottom.load(.monotonic);
            const top = self.top.load(.acquire);
            const arr = self.array.load(.monotonic);

            const current_size = bottom - top;

            if (current_size >= @as(i64, @intCast(arr.capacity))) {
                // Grow array
                const new_arr = try arr.grow(self.allocator, bottom, top);
                self.array.store(new_arr, .release);
                arr.deinit(self.allocator);
                new_arr.put(bottom, value);
            } else {
                arr.put(bottom, value);
            }

            self.bottom.store(bottom + 1, .release);
        }

        /// Pop task from bottom (owner only)
        /// Returns null if deque is empty
        pub fn pop(self: *Self) ?T {
            const bottom = self.bottom.load(.monotonic) - 1;
            const arr = self.array.load(.monotonic);
            self.bottom.store(bottom, .seq_cst);

            const top = self.top.load(.seq_cst);

            if (top < bottom) {
                // Non-empty deque
                return arr.get(bottom);
            }

            if (top == bottom) {
                // Last element - race with stealers
                const value = arr.get(bottom);

                if (self.top.cmpxchgWeak(
                    top,
                    top + 1,
                    .seq_cst,
                    .monotonic,
                )) |_| {
                    // Lost race to stealer
                    self.bottom.store(bottom + 1, .release);
                    return null;
                }

                self.bottom.store(bottom + 1, .release);
                return value;
            }

            // Empty deque
            self.bottom.store(bottom + 1, .release);
            return null;
        }

        /// Steal task from top (any thread)
        /// Returns null if deque is empty or contention occurred
        pub fn steal(self: *Self) ?T {
            const top = self.top.load(.seq_cst);
            const bottom = self.bottom.load(.seq_cst);

            if (top >= bottom) {
                // Empty deque
                return null;
            }

            const arr = self.array.load(.monotonic);
            const value = arr.get(top);

            if (self.top.cmpxchgWeak(
                top,
                top + 1,
                .seq_cst,
                .monotonic,
            )) |_| {
                // Failed to steal (contention)
                return null;
            }

            return value;
        }

        /// Get current size (approximate, for debugging)
        pub fn size(self: *const Self) usize {
            const bottom = self.bottom.load(.monotonic);
            const top = self.top.load(.monotonic);
            const sz = bottom - top;
            return if (sz < 0) 0 else @intCast(sz);
        }
    };
}

test "WorkStealDeque - basic push/pop" {
    const testing = std.testing;

    var deque = try WorkStealDeque(u32).init(testing.allocator, 4);
    defer deque.deinit();

    try deque.push(1);
    try deque.push(2);
    try deque.push(3);

    try testing.expectEqual(@as(?u32, 3), deque.pop());
    try testing.expectEqual(@as(?u32, 2), deque.pop());
    try testing.expectEqual(@as(?u32, 1), deque.pop());
    try testing.expectEqual(@as(?u32, null), deque.pop());
}

test "WorkStealDeque - steal" {
    const testing = std.testing;

    var deque = try WorkStealDeque(u32).init(testing.allocator, 4);
    defer deque.deinit();

    try deque.push(10);
    try deque.push(20);
    try deque.push(30);

    // Steal from top (FIFO)
    try testing.expectEqual(@as(?u32, 10), deque.steal());
    try testing.expectEqual(@as(?u32, 20), deque.steal());

    // Pop from bottom (LIFO)
    try testing.expectEqual(@as(?u32, 30), deque.pop());

    try testing.expectEqual(@as(?u32, null), deque.steal());
}

test "WorkStealDeque - grow" {
    const testing = std.testing;

    var deque = try WorkStealDeque(u32).init(testing.allocator, 2);
    defer deque.deinit();

    // Push beyond initial capacity
    try deque.push(1);
    try deque.push(2);
    try deque.push(3);
    try deque.push(4);
    try deque.push(5);

    try testing.expectEqual(@as(?u32, 5), deque.pop());
    try testing.expectEqual(@as(?u32, 4), deque.pop());
    try testing.expectEqual(@as(?u32, 3), deque.pop());
    try testing.expectEqual(@as(?u32, 2), deque.pop());
    try testing.expectEqual(@as(?u32, 1), deque.pop());
}

test "WorkStealDeque - concurrent push/steal" {
    const testing = std.testing;

    var deque = try WorkStealDeque(u32).init(testing.allocator, 8);
    defer deque.deinit();

    // Simulate producer-consumer pattern
    try deque.push(100);
    try deque.push(200);

    const stolen1 = deque.steal();
    try testing.expect(stolen1 != null);

    try deque.push(300);

    const popped = deque.pop();
    try testing.expect(popped != null);

    // Should still have one item
    const stolen2 = deque.steal();
    try testing.expect(stolen2 != null);
}
