const std = @import("std");

/// Generic fixed-size object pool.
/// Manages a contiguous memory region divided into equal-sized objects.
/// Free list is maintained by embedding a next-pointer in the first 8 bytes
/// of each free object (safe because free objects are unused).
///
/// Thread-safety: NONE. Each pool is owned by exactly one core.
pub const MemPool = struct {
    base: [*]u8,
    elem_size: usize,
    capacity: u32,
    free_count: u32,
    free_head: usize, // byte offset from base, or SENTINEL if empty
    total_size: usize,

    const SENTINEL: usize = std.math.maxInt(usize);

    /// Initialize a pool over pre-allocated memory.
    /// `elem_size` must be >= 8 (to fit the free-list link) and a multiple of 8.
    pub fn init(memory: [*]u8, total_size: usize, elem_size: usize) MemPool {
        std.debug.assert(elem_size >= 8);
        std.debug.assert(elem_size % 8 == 0);

        const count: u32 = @intCast(total_size / elem_size);
        var pool = MemPool{
            .base = memory,
            .elem_size = elem_size,
            .capacity = count,
            .free_count = 0,
            .free_head = SENTINEL,
            .total_size = total_size,
        };

        // Build free list in reverse so first get() returns element 0
        var i: u32 = count;
        while (i > 0) {
            i -= 1;
            const offset = @as(usize, i) * elem_size;
            const link: *usize = @ptrCast(@alignCast(memory + offset));
            link.* = pool.free_head;
            pool.free_head = offset;
            pool.free_count += 1;
        }

        return pool;
    }

    /// Allocate one object. Returns null if pool is empty.
    pub fn get(self: *MemPool) ?[*]u8 {
        if (self.free_head == SENTINEL) return null;
        const offset = self.free_head;
        const ptr = self.base + offset;
        const link: *const usize = @ptrCast(@alignCast(ptr));
        self.free_head = link.*;
        self.free_count -= 1;
        return ptr;
    }

    /// Return one object to the pool.
    pub fn put(self: *MemPool, ptr: [*]u8) void {
        const offset = @intFromPtr(ptr) - @intFromPtr(self.base);
        std.debug.assert(offset < self.total_size);
        std.debug.assert(offset % self.elem_size == 0);

        const link: *usize = @ptrCast(@alignCast(ptr));
        link.* = self.free_head;
        self.free_head = offset;
        self.free_count += 1;
    }

    pub fn availableCount(self: *const MemPool) u32 {
        return self.free_count;
    }

    pub fn isEmpty(self: *const MemPool) bool {
        return self.free_head == SENTINEL;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "MemPool: init and alloc/free cycle" {
    const elem_size: usize = 64;
    const count: usize = 8;
    var backing: [elem_size * count]u8 align(8) = undefined;

    var pool = MemPool.init(&backing, backing.len, elem_size);
    try testing.expectEqual(@as(u32, 8), pool.availableCount());

    // Allocate all objects
    var ptrs: [count]*u8 = undefined;
    for (0..count) |i| {
        const ptr = pool.get() orelse return error.TestUnexpectedResult;
        ptrs[i] = @ptrCast(ptr);
    }
    try testing.expectEqual(@as(u32, 0), pool.availableCount());
    try testing.expect(pool.isEmpty());
    try testing.expect(pool.get() == null);

    // Free all objects
    for (0..count) |i| {
        pool.put(@ptrCast(ptrs[i]));
    }
    try testing.expectEqual(@as(u32, 8), pool.availableCount());
}

test "MemPool: objects are distinct" {
    const elem_size: usize = 32;
    const count: usize = 4;
    var backing: [elem_size * count]u8 align(8) = undefined;

    var pool = MemPool.init(&backing, backing.len, elem_size);

    const a = pool.get().?;
    const b = pool.get().?;
    const c = pool.get().?;

    // All pointers should be distinct and within the backing region
    try testing.expect(@intFromPtr(a) != @intFromPtr(b));
    try testing.expect(@intFromPtr(b) != @intFromPtr(c));
    try testing.expect(@intFromPtr(a) >= @intFromPtr(&backing));
    try testing.expect(@intFromPtr(c) < @intFromPtr(&backing) + backing.len);
}
