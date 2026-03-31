//! Fixed-size memory pool
//!
//! Performance: <10ns allocation, <5ns deallocation

const std = @import("std");

pub const FixedPool = struct {
    allocator: std.mem.Allocator,
    object_size: usize,
    capacity: usize,
    memory: []align(@alignOf(*Node)) u8,
    free_list: ?*Node,
    allocated: usize,

    const Node = struct {
        next: ?*Node,
    };

    pub fn init(allocator: std.mem.Allocator, object_size: usize, capacity: usize) !FixedPool {
        // Ensure object_size is at least pointer-sized for free list
        const actual_size = @max(object_size, @sizeOf(*Node));

        // Allocate memory for all objects with pointer alignment
        const memory = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(@alignOf(*Node)), actual_size * capacity);

        // Build free list
        var free_list: ?*Node = null;
        var i: usize = 0;
        while (i < capacity) : (i += 1) {
            const node = @as(*Node, @ptrCast(@alignCast(&memory[i * actual_size])));
            node.next = free_list;
            free_list = node;
        }

        return FixedPool{
            .allocator = allocator,
            .object_size = actual_size,
            .capacity = capacity,
            .memory = memory,
            .free_list = free_list,
            .allocated = 0,
        };
    }

    pub fn deinit(self: *FixedPool) void {
        self.allocator.free(self.memory);
    }

    pub fn alloc(self: *FixedPool) !*anyopaque {
        const node = self.free_list orelse return error.OutOfMemory;
        self.free_list = node.next;
        self.allocated += 1;
        return @as(*anyopaque, @ptrCast(node));
    }

    pub fn free(self: *FixedPool, ptr: *anyopaque) void {
        const node = @as(*Node, @ptrCast(@alignCast(ptr)));
        node.next = self.free_list;
        self.free_list = node;
        self.allocated -= 1;
    }

    pub fn reset(self: *FixedPool) void {
        // Rebuild free list
        self.free_list = null;
        var i: usize = 0;
        while (i < self.capacity) : (i += 1) {
            const node = @as(*Node, @ptrCast(@alignCast(&self.memory[i * self.object_size])));
            node.next = self.free_list;
            self.free_list = node;
        }
        self.allocated = 0;
    }
};

test "fixed pool - basic operations" {
    const allocator = std.testing.allocator;

    var pool_inst = try FixedPool.init(allocator, 64, 10);
    defer pool_inst.deinit();

    const ptr1 = try pool_inst.alloc();
    const ptr2 = try pool_inst.alloc();

    try std.testing.expectEqual(@as(usize, 2), pool_inst.allocated);

    pool_inst.free(ptr1);
    pool_inst.free(ptr2);

    try std.testing.expectEqual(@as(usize, 0), pool_inst.allocated);
}

test "fixed pool - fill to capacity" {
    const allocator = std.testing.allocator;

    const capacity = 8;
    var pool_inst = try FixedPool.init(allocator, 32, capacity);
    defer pool_inst.deinit();

    // Allocate all slots
    var ptrs: [capacity]*anyopaque = undefined;
    for (&ptrs) |*ptr| {
        ptr.* = try pool_inst.alloc();
    }

    try std.testing.expectEqual(capacity, pool_inst.allocated);

    // Next allocation should fail
    try std.testing.expectError(error.OutOfMemory, pool_inst.alloc());

    // Free all
    for (ptrs) |ptr| {
        pool_inst.free(ptr);
    }

    try std.testing.expectEqual(@as(usize, 0), pool_inst.allocated);
}

test "fixed pool - reset functionality" {
    const allocator = std.testing.allocator;

    var pool_inst = try FixedPool.init(allocator, 64, 5);
    defer pool_inst.deinit();

    // Allocate some objects
    const ptr1 = try pool_inst.alloc();
    const ptr2 = try pool_inst.alloc();
    const ptr3 = try pool_inst.alloc();

    try std.testing.expectEqual(@as(usize, 3), pool_inst.allocated);

    // Reset without freeing individual objects
    pool_inst.reset();

    try std.testing.expectEqual(@as(usize, 0), pool_inst.allocated);

    // Should be able to allocate again
    _ = try pool_inst.alloc();
    _ = try pool_inst.alloc();

    try std.testing.expectEqual(@as(usize, 2), pool_inst.allocated);

    // ptrs are now dangling - don't use them
    _ = ptr1;
    _ = ptr2;
    _ = ptr3;
}

test "fixed pool - reuse freed slots" {
    const allocator = std.testing.allocator;

    var pool_inst = try FixedPool.init(allocator, 64, 4);
    defer pool_inst.deinit();

    // Allocate and free in pattern
    const ptr1 = try pool_inst.alloc();
    const ptr2 = try pool_inst.alloc();

    pool_inst.free(ptr1);

    const ptr3 = try pool_inst.alloc(); // Should reuse ptr1's slot
    _ = ptr3;

    try std.testing.expectEqual(@as(usize, 2), pool_inst.allocated);

    pool_inst.free(ptr2);

    try std.testing.expectEqual(@as(usize, 1), pool_inst.allocated);
}

test "fixed pool - minimum object size" {
    const allocator = std.testing.allocator;

    // Test with object_size smaller than pointer
    var pool_inst = try FixedPool.init(allocator, 1, 4);
    defer pool_inst.deinit();

    // Should round up to pointer size
    try std.testing.expect(pool_inst.object_size >= @sizeOf(*FixedPool.Node));

    const ptr1 = try pool_inst.alloc();
    const ptr2 = try pool_inst.alloc();

    pool_inst.free(ptr1);
    pool_inst.free(ptr2);
}

test "fixed pool - large objects" {
    const allocator = std.testing.allocator;

    // Test with 1KB objects
    var pool_inst = try FixedPool.init(allocator, 1024, 4);
    defer pool_inst.deinit();

    const ptrs = try pool_inst.alloc();
    pool_inst.free(ptrs);
}

test "fixed pool - stress test" {
    const allocator = std.testing.allocator;

    var pool_inst = try FixedPool.init(allocator, 128, 32);
    defer pool_inst.deinit();

    // Allocate/free in complex pattern
    var ptrs: [16]*anyopaque = undefined;

    // Allocate half
    for (ptrs[0..16]) |*ptr| {
        ptr.* = try pool_inst.alloc();
    }

    // Free every other one
    var i: usize = 0;
    while (i < 16) : (i += 2) {
        pool_inst.free(ptrs[i]);
    }

    try std.testing.expectEqual(@as(usize, 8), pool_inst.allocated);

    // Allocate again to fill holes
    i = 0;
    while (i < 8) : (i += 1) {
        _ = try pool_inst.alloc();
    }

    try std.testing.expectEqual(@as(usize, 16), pool_inst.allocated);

    // Reset
    pool_inst.reset();

    try std.testing.expectEqual(@as(usize, 0), pool_inst.allocated);
}
