//! Fixed-size memory pool
//!
//! Performance: <10ns allocation, <5ns deallocation

const std = @import("std");

pub const FixedPool = struct {
    allocator: std.mem.Allocator,
    object_size: usize,
    capacity: usize,
    memory: []align(slot_align) u8,
    free_list: ?*Node,
    allocated: usize,
    /// When true, `free` zeroes the slot payload and `deinit`/`reset` wipe the
    /// whole backing buffer with `std.crypto.secureZero`. For secret-bearing
    /// consumers (quantum_vault) so freed key material does not linger in the
    /// pool until the slot is reused. Off by default (no hot-path cost).
    secure: bool,

    const Node = struct {
        next: ?*Node,
    };

    /// Slot alignment (and slot-size granularity). Raised to 16 for malloc
    /// parity so SIMD / `long double` payloads coming from C callers are
    /// correctly aligned. Must be >= @alignOf(*Node). This is the pool's whole
    /// alignment guarantee: callers needing more must not use it.
    pub const slot_align = 16;

    pub fn init(allocator: std.mem.Allocator, object_size: usize, capacity: usize) !FixedPool {
        return initOptions(allocator, object_size, capacity, false);
    }

    /// Like `init`, but slots are zeroed on free and the buffer is securely
    /// wiped on `deinit`/`reset`. See the `secure` field.
    pub fn initSecure(allocator: std.mem.Allocator, object_size: usize, capacity: usize) !FixedPool {
        return initOptions(allocator, object_size, capacity, true);
    }

    fn initOptions(allocator: std.mem.Allocator, object_size: usize, capacity: usize, secure: bool) !FixedPool {
        // Ensure object_size is at least pointer-sized for the free-list link,
        // then round the slot size UP to slot_align. Without the round-up, an
        // object_size not a multiple of the alignment (e.g. 12) places later
        // slots at mis-aligned offsets, making the @alignCast to *Node UB.
        const min_size = @max(object_size, @sizeOf(*Node));
        const actual_size = std.mem.alignForward(usize, min_size, slot_align);

        // Guard the total-size multiply against overflow (UB in ReleaseFast).
        const total_size = try std.math.mul(usize, actual_size, capacity);

        // Allocate memory for all objects, base-aligned to slot_align so every
        // slot (base + i*actual_size) is slot_align-aligned.
        const memory = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(slot_align), total_size);

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
            .secure = secure,
        };
    }

    pub fn deinit(self: *FixedPool) void {
        if (self.secure) std.crypto.secureZero(u8, self.memory);
        self.allocator.free(self.memory);
    }

    /// True if `ptr` addresses the start of a slot in this pool's backing
    /// buffer. Used to reject foreign / mis-aligned pointers at the free path.
    fn ownsSlot(self: *const FixedPool, ptr: *anyopaque) bool {
        const addr = @intFromPtr(ptr);
        const base = @intFromPtr(self.memory.ptr);
        if (addr < base or addr >= base + self.memory.len) return false;
        return (addr - base) % self.object_size == 0;
    }

    pub fn alloc(self: *FixedPool) !*anyopaque {
        const node = self.free_list orelse return error.OutOfMemory;
        self.free_list = node.next;
        self.allocated += 1;
        return @as(*anyopaque, @ptrCast(node));
    }

    pub fn free(self: *FixedPool, ptr: *anyopaque) void {
        // Reject foreign / mis-aligned pointers in safe builds; in ReleaseFast
        // the @alignCast below would otherwise be UB. (Compiled out in
        // ReleaseFast, so no cost to the vault's hot path.)
        std.debug.assert(self.ownsSlot(ptr));

        // A free with nothing outstanding is a spurious / double-free-everything
        // pattern; pushing would still corrupt the free list, but at minimum
        // refuse to underflow `allocated` (which feeds `available =
        // capacity - allocated` in the stats and would wrap to garbage).
        if (self.allocated == 0) return;

        // Optionally wipe the payload before the slot re-enters the free list,
        // so secret material does not survive until the slot is reused.
        if (self.secure) {
            const slot: [*]u8 = @ptrCast(ptr);
            std.crypto.secureZero(u8, slot[0..self.object_size]);
        }

        const node = @as(*Node, @ptrCast(@alignCast(ptr)));
        node.next = self.free_list;
        self.free_list = node;
        self.allocated -= 1;
    }

    pub fn reset(self: *FixedPool) void {
        // Wipe live payloads before the slots are recycled (secure mode only).
        if (self.secure) std.crypto.secureZero(u8, self.memory);
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

test "fixed pool - free-when-empty does not underflow allocated" {
    const allocator = std.testing.allocator;

    var pool_inst = try FixedPool.init(allocator, 32, 4);
    defer pool_inst.deinit();

    const ptr = try pool_inst.alloc();
    pool_inst.free(ptr);
    try std.testing.expectEqual(@as(usize, 0), pool_inst.allocated);

    // Double-free of the last outstanding slot: the guard must refuse to
    // underflow `allocated` (which would wrap `available` in the stats).
    pool_inst.free(ptr);
    try std.testing.expectEqual(@as(usize, 0), pool_inst.allocated);
}

test "fixed pool - secure mode zeroes freed payload" {
    const allocator = std.testing.allocator;

    // Slot size 64 (multiple of slot_align, so object_size stays 64).
    var pool_inst = try FixedPool.initSecure(allocator, 64, 4);
    defer pool_inst.deinit();

    const ptr = try pool_inst.alloc();
    const bytes: [*]u8 = @ptrCast(ptr);
    // Fill the whole slot with a recognizable secret pattern.
    @memset(bytes[0..64], 0xAB);

    pool_inst.free(ptr);

    // Everything past the free-list link (first @sizeOf(*Node) bytes, which the
    // free list overwrites) must be wiped; none of the 0xAB secret survives.
    const link = @sizeOf(*FixedPool.Node);
    for (bytes[link..64]) |b| {
        try std.testing.expectEqual(@as(u8, 0), b);
    }
}

test "fixed pool - non-secure mode leaves payload (contrast)" {
    const allocator = std.testing.allocator;

    var pool_inst = try FixedPool.init(allocator, 64, 4);
    defer pool_inst.deinit();

    const ptr = try pool_inst.alloc();
    const bytes: [*]u8 = @ptrCast(ptr);
    @memset(bytes[0..64], 0xAB);
    pool_inst.free(ptr);

    // Default pools do NOT wipe: the tail bytes still hold the pattern.
    try std.testing.expectEqual(@as(u8, 0xAB), bytes[63]);
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

// ============================================================================
// Address-alignment property tests (misaligned backing buffers)
//
// FixedPool's contract is that every slot address is a multiple of
// `slot_align` (16, malloc parity) whatever its backing allocator hands back
// for an unaligned request. The backing here is a FixedBufferAllocator whose
// buffer starts 1, 3, 7, 9 or 15 bytes past an 8192-byte boundary, so an
// implementation that took the base pointer's alignment for granted would
// fail. Every object size 1..4096 is checked.
// ============================================================================

const misaligned_offsets = [_]usize{ 1, 3, 7, 9, 15 };
const backing_align = 8192;

fn expectSlotsSound(p: *const FixedPool, region: []const u8, requested: usize, slots: []const usize) !void {
    const base = @intFromPtr(p.memory.ptr);
    const end = base + p.memory.len;
    // Pool memory lies inside the backing region.
    try std.testing.expect(base >= @intFromPtr(region.ptr));
    try std.testing.expect(end <= @intFromPtr(region.ptr) + region.len);
    for (slots, 0..) |addr, i| {
        // Every alignment the pool promises (1, 2, 4, 8, 16).
        var a: usize = 1;
        while (a <= FixedPool.slot_align) : (a *= 2) {
            try std.testing.expectEqual(@as(usize, 0), addr % a);
        }
        // In bounds for the requested size and for the full slot.
        try std.testing.expect(addr >= base);
        try std.testing.expect(addr + @max(requested, p.object_size) <= end);
        // Disjoint from every other live slot.
        for (slots[0..i]) |other| {
            const lo = @min(addr, other);
            const hi = @max(addr, other);
            try std.testing.expect(hi - lo >= p.object_size);
        }
    }
}

test "fixed pool - slot alignment on misaligned backing, every object size 1..4096" {
    const backing = try std.testing.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(backing_align), 32 * 1024);
    defer std.testing.allocator.free(backing);

    const cap = 3;
    for (misaligned_offsets) |k| {
        const region = backing[k..];
        try std.testing.expectEqual(k, @intFromPtr(region.ptr) % backing_align);
        var size: usize = 1;
        while (size <= 4096) : (size += 1) {
            var fba = std.heap.FixedBufferAllocator.init(region);
            var p = try FixedPool.init(fba.allocator(), size, cap);
            defer p.deinit();

            var slots: [cap]usize = undefined;
            for (&slots) |*s| s.* = @intFromPtr(try p.alloc());
            try expectSlotsSound(&p, region, size, &slots);
            try std.testing.expectError(error.OutOfMemory, p.alloc());
        }
    }
}

test "fixed pool - backing that exactly fits is accepted, one byte less refused" {
    const backing = try std.testing.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(backing_align), 4096);
    defer std.testing.allocator.free(backing);

    const cap = 5;
    for (misaligned_offsets) |k| {
        for ([_]usize{ 1, 12, 16, 33, 100 }) |size| {
            const slot = std.mem.alignForward(usize, @max(size, @sizeOf(*FixedPool.Node)), FixedPool.slot_align);
            const start = @intFromPtr(backing.ptr) + k;
            const pad = std.mem.alignForward(usize, start, FixedPool.slot_align) - start;
            const need = pad + slot * cap;

            var short = std.heap.FixedBufferAllocator.init(backing[k .. k + need - 1]);
            try std.testing.expectError(error.OutOfMemory, FixedPool.init(short.allocator(), size, cap));

            var exact = std.heap.FixedBufferAllocator.init(backing[k .. k + need]);
            var p = try FixedPool.init(exact.allocator(), size, cap);
            defer p.deinit();
            var slots: [cap]usize = undefined;
            for (&slots) |*s| s.* = @intFromPtr(try p.alloc());
            try expectSlotsSound(&p, backing[k .. k + need], size, &slots);
            // The last slot ends exactly at the end of the backing region.
            try std.testing.expectEqual(start + need, @intFromPtr(p.memory.ptr) + p.memory.len);
            try std.testing.expectError(error.OutOfMemory, p.alloc());
        }
    }
}

test "fixed pool - free and reset keep slots aligned on misaligned backing" {
    const backing = try std.testing.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(backing_align), 8192);
    defer std.testing.allocator.free(backing);

    const cap = 8;
    for (misaligned_offsets) |k| {
        var fba = std.heap.FixedBufferAllocator.init(backing[k..]);
        var p = try FixedPool.initSecure(fba.allocator(), 24, cap);
        defer p.deinit();

        var slots: [cap]usize = undefined;
        for (&slots) |*s| s.* = @intFromPtr(try p.alloc());
        try expectSlotsSound(&p, backing[k..], 24, &slots);

        // Free every other slot, re-allocate: the same aligned slots return.
        var i: usize = 0;
        while (i < cap) : (i += 2) p.free(@ptrFromInt(slots[i]));
        i = 0;
        while (i < cap) : (i += 2) {
            const again = @intFromPtr(try p.alloc());
            try std.testing.expectEqual(@as(usize, 0), again % FixedPool.slot_align);
            var found = false;
            for (slots) |s| found = found or s == again;
            try std.testing.expect(found);
        }
        try std.testing.expectError(error.OutOfMemory, p.alloc());

        // Reset: the full capacity is available again, all aligned and sound.
        p.reset();
        try std.testing.expectEqual(@as(usize, 0), p.allocated);
        for (&slots) |*s| s.* = @intFromPtr(try p.alloc());
        try expectSlotsSound(&p, backing[k..], 24, &slots);
        try std.testing.expectError(error.OutOfMemory, p.alloc());
    }
}
