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
        /// Arrays that were grown out of. A concurrent `steal()` may still hold
        /// a pointer to the old array after `push` swaps in the grown one, so we
        /// must NOT free the old array at grow time (that is a use-after-free).
        /// Instead we retire it here and free every retired array in `deinit`,
        /// once all worker/stealer threads have joined. This is the classic
        /// Chase-Lev "leak until teardown" strategy; memory is bounded at ~2x the
        /// final capacity. Only the single owner mutates this list (from `push`),
        /// and it is only read in `deinit` after threads have stopped, so it
        /// needs no lock.
        retired: std.ArrayListUnmanaged(*Array),

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const arr = try Array.init(allocator, capacity);

            return Self{
                .allocator = allocator,
                .array = atomic.Value(*Array).init(arr),
                .top = atomic.Value(i64).init(0),
                .bottom = atomic.Value(i64).init(0),
                .retired = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            const arr = self.array.load(.monotonic);
            arr.deinit(self.allocator);
            for (self.retired.items) |old| {
                old.deinit(self.allocator);
            }
            self.retired.deinit(self.allocator);
        }

        /// Push task to bottom (owner only)
        pub fn push(self: *Self, value: T) !void {
            const bottom = self.bottom.load(.monotonic);
            const top = self.top.load(.acquire);
            const arr = self.array.load(.monotonic);

            const current_size = bottom - top;

            if (current_size >= @as(i64, @intCast(arr.capacity))) {
                // Grow array. Retire (do NOT free) the old array: a concurrent
                // stealer may have loaded `arr` before we swap and will read
                // from it after. Retired arrays are freed in `deinit`.
                const new_arr = try arr.grow(self.allocator, bottom, top);
                errdefer new_arr.deinit(self.allocator);
                try self.retired.append(self.allocator, arr);
                self.array.store(new_arr, .release);
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

// Regression test for the grow-path use-after-free (work-order #6): a single
// owner pushes 1..=N (forcing many array doublings) while several stealer threads
// concurrently steal. Before the fix, `push` freed the old array the instant it
// swapped in the grown one, so a stealer that had already loaded the old array
// pointer dereferenced freed memory. With retire-until-deinit the old arrays stay
// live, so this must complete with every value accounted for exactly once (no
// lost, no duplicated items) and clean under the testing allocator.
test "WorkStealDeque - steal under growth (UAF stress)" {
    const testing = std.testing;

    const N: u64 = 20_000;

    var deque = try WorkStealDeque(u64).init(testing.allocator, 8);
    defer deque.deinit();

    const Shared = struct {
        deque: *WorkStealDeque(u64),
        sum: std.atomic.Value(u64) = .init(0),
        count: std.atomic.Value(u64) = .init(0),
        producing: std.atomic.Value(bool) = .init(true),

        fn stealer(self: *@This()) void {
            while (true) {
                if (self.deque.steal()) |v| {
                    _ = self.sum.fetchAdd(v, .monotonic);
                    _ = self.count.fetchAdd(1, .monotonic);
                    continue;
                }
                // Owner drains the remainder via pop() after it stops producing,
                // so a stealer is free to exit once production is finished.
                if (!self.producing.load(.acquire)) break;
                std.atomic.spinLoopHint();
            }
        }
    };

    var shared = Shared{ .deque = &deque };

    var stealers: [4]std.Thread = undefined;
    for (&stealers) |*t| {
        t.* = try std.Thread.spawn(.{}, Shared.stealer, .{&shared});
    }

    // Owner: sole pusher/popper. Push all N (triggering repeated growth), then
    // drain whatever the stealers did not take.
    var i: u64 = 1;
    while (i <= N) : (i += 1) {
        try deque.push(i);
    }
    shared.producing.store(false, .release);
    while (deque.pop()) |v| {
        _ = shared.sum.fetchAdd(v, .monotonic);
        _ = shared.count.fetchAdd(1, .monotonic);
    }

    for (stealers) |t| t.join();

    try testing.expectEqual(N, shared.count.load(.monotonic));
    try testing.expectEqual(N * (N + 1) / 2, shared.sum.load(.monotonic));
}
