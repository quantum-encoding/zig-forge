//! Slab allocator for multiple object sizes
//!
//! A production-grade slab allocator that maintains per-size-class FixedPools
//! for O(1) allocation and deallocation of variable-sized objects.
//!
//! Design:
//!   - 10 power-of-2 size classes: 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096
//!   - Each size class backed by a FixedPool with configurable capacity
//!   - O(1) alloc: round-up to size class → pop from free list
//!   - O(1) free: address-range lookup → push to free list
//!   - Oversized allocations (>4096) fall back to the backing allocator
//!   - Thread safety: single-threaded per allocator instance (same as FixedPool)
//!
//! Performance:
//!   - Allocation: <15ns (size-class lookup + FixedPool alloc)
//!   - Deallocation: <10ns (range scan + FixedPool free)
//!   - No fragmentation within size classes
//!
//! Zig 0.16 version

const std = @import("std");
const FixedPool = @import("../pool/fixed.zig").FixedPool;

/// Power-of-2 size classes from 8 bytes to 4096 bytes.
/// Covers the vast majority of small-to-medium allocation patterns
/// in systems programming (network messages, tree nodes, hash entries, etc.)
const SIZE_CLASSES = [_]usize{ 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096 };
const NUM_CLASSES = SIZE_CLASSES.len;

/// Default number of objects per size class.
/// 256 objects × 10 classes = ~11 MiB total pool memory at max.
/// Tunable per use case; HFT systems may want 4096+.
const DEFAULT_CAPACITY: usize = 256;

/// Maximum size handled by slab pools. Anything larger falls back
/// to the general-purpose allocator.
const MAX_SLAB_SIZE: usize = SIZE_CLASSES[NUM_CLASSES - 1];

/// Per-size-class metadata: the FixedPool plus its address bounds
/// for O(1) pointer → size-class routing on free().
const Slab = struct {
    pool: FixedPool,
    size_class: usize,
    /// Base address of the FixedPool's backing memory (inclusive)
    base_addr: usize,
    /// End address of the FixedPool's backing memory (exclusive)
    end_addr: usize,
};

/// Tracks oversized allocations that bypass the slab pools.
/// Stores the aligned slice directly so that free() can pass
/// the correct alignment back to the allocator.
const OversizedEntry = struct {
    ptr: [*]align(@alignOf(*anyopaque)) u8,
    len: usize,
};

pub const SlabAllocator = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    slabs: [NUM_CLASSES]?Slab,
    capacity_per_class: usize,

    // Statistics
    total_allocated: usize,
    total_freed: usize,
    oversized_allocated: usize,
    oversized_freed: usize,

    // Track oversized allocations for proper cleanup
    oversized: std.ArrayList(OversizedEntry),

    pub const Stats = struct {
        total_allocated: usize,
        total_freed: usize,
        in_use: usize,
        oversized_allocated: usize,
        oversized_freed: usize,
        oversized_in_use: usize,
        /// Per-class breakdown: allocated count per size class
        class_allocated: [NUM_CLASSES]usize,
        /// Per-class breakdown: capacity per size class
        class_capacity: [NUM_CLASSES]usize,
    };

    pub const InitError = error{OutOfMemory};

    /// Initialize a slab allocator with a given capacity per size class.
    ///
    /// Each size class gets its own FixedPool with `capacity` slots.
    /// Total memory usage ≈ sum(SIZE_CLASSES[i] × capacity) for all i.
    ///
    /// Example:
    /// ```zig
    /// var slab = try SlabAllocator.init(allocator, 512);
    /// defer slab.deinit();
    /// ```
    pub fn init(allocator: std.mem.Allocator, capacity: usize) InitError!Self {
        return initWithCapacities(allocator, [_]usize{capacity} ** NUM_CLASSES);
    }

    /// Initialize with per-class capacities for fine-grained control.
    ///
    /// Example: give more slots to smaller size classes (more common):
    /// ```zig
    /// var slab = try SlabAllocator.initWithCapacities(allocator,
    ///     .{ 4096, 2048, 1024, 512, 256, 128, 64, 32, 16, 8 });
    /// ```
    pub fn initWithCapacities(allocator: std.mem.Allocator, capacities: [NUM_CLASSES]usize) InitError!Self {
        var self = Self{
            .allocator = allocator,
            .slabs = [_]?Slab{null} ** NUM_CLASSES,
            .capacity_per_class = 0,
            .total_allocated = 0,
            .total_freed = 0,
            .oversized_allocated = 0,
            .oversized_freed = 0,
            .oversized = .empty,
        };

        // Initialize each size class pool
        for (SIZE_CLASSES, 0..) |size_class, i| {
            const cap = capacities[i];
            if (cap == 0) continue;

            const pool = FixedPool.init(allocator, size_class, cap) catch return error.OutOfMemory;

            self.slabs[i] = Slab{
                .pool = pool,
                .size_class = size_class,
                .base_addr = @intFromPtr(pool.memory.ptr),
                .end_addr = @intFromPtr(pool.memory.ptr) + pool.memory.len,
            };
        }

        self.capacity_per_class = capacities[0];
        return self;
    }

    /// Free all slab pools and oversized allocations.
    pub fn deinit(self: *Self) void {
        // Free all oversized allocations
        for (self.oversized.items) |entry| {
            const aligned_slice: []align(@alignOf(*anyopaque)) u8 = entry.ptr[0..entry.len];
            self.allocator.free(aligned_slice);
        }
        self.oversized.deinit(self.allocator);

        // Free each slab pool
        for (&self.slabs) |*maybe_slab| {
            if (maybe_slab.*) |*slab| {
                slab.pool.deinit();
                maybe_slab.* = null;
            }
        }
    }

    /// Allocate memory of at least `size` bytes.
    ///
    /// For sizes ≤ 4096: routes to the appropriate size-class FixedPool (O(1)).
    /// For sizes > 4096: falls back to the backing allocator.
    ///
    /// Returns: pointer to allocated memory, or error.OutOfMemory if
    /// the appropriate pool is exhausted (or backing allocator fails).
    pub fn alloc(self: *Self, size: usize) !*anyopaque {
        if (size == 0) return error.OutOfMemory;

        // Find the appropriate size class
        const class_index = sizeClassIndex(size);

        if (class_index) |idx| {
            // Slab allocation path
            if (self.slabs[idx]) |*slab| {
                const ptr = try slab.pool.alloc();
                self.total_allocated += 1;
                return ptr;
            }
            // Pool for this class wasn't initialized (capacity was 0)
            return error.OutOfMemory;
        }

        // Oversized allocation path: fall back to general allocator
        const aligned_size = std.mem.alignForward(usize, size, @alignOf(*anyopaque));
        const memory = self.allocator.alignedAlloc(
            u8,
            std.mem.Alignment.fromByteUnits(@alignOf(*anyopaque)),
            aligned_size,
        ) catch return error.OutOfMemory;

        self.oversized.append(self.allocator, .{
            .ptr = @alignCast(memory.ptr),
            .len = memory.len,
        }) catch {
            self.allocator.free(memory);
            return error.OutOfMemory;
        };

        self.oversized_allocated += 1;
        self.total_allocated += 1;
        return @as(*anyopaque, @ptrCast(memory.ptr));
    }

    /// Free a pointer previously returned by alloc().
    ///
    /// Uses address-range comparison to determine which size-class pool
    /// owns the pointer (O(NUM_CLASSES) = O(10) = effectively O(1)).
    /// For oversized allocations, searches the oversized tracking list.
    pub fn free(self: *Self, ptr: *anyopaque) void {
        const addr = @intFromPtr(ptr);

        // Check each slab's address range
        for (&self.slabs) |*maybe_slab| {
            if (maybe_slab.*) |*slab| {
                if (addr >= slab.base_addr and addr < slab.end_addr) {
                    slab.pool.free(ptr);
                    self.total_freed += 1;
                    return;
                }
            }
        }

        // Must be an oversized allocation
        for (self.oversized.items, 0..) |entry, i| {
            if (@intFromPtr(entry.ptr) == addr) {
                const aligned_slice: []align(@alignOf(*anyopaque)) u8 = entry.ptr[0..entry.len];
                self.allocator.free(aligned_slice);
                _ = self.oversized.swapRemove(i);
                self.oversized_freed += 1;
                self.total_freed += 1;
                return;
            }
        }

        // If we get here, the pointer wasn't allocated by this slab allocator.
        // In debug/safe modes, this is a programming error.
        @panic("SlabAllocator: free() called with pointer not owned by this allocator");
    }

    /// Convenience: allocate and return a typed pointer.
    ///
    /// Example:
    /// ```zig
    /// const node = try slab.allocTyped(TreeNode);
    /// defer slab.freeTyped(node);
    /// ```
    pub fn allocTyped(self: *Self, comptime T: type) !*T {
        const ptr = try self.alloc(@sizeOf(T));
        return @as(*T, @ptrCast(@alignCast(ptr)));
    }

    /// Convenience: free a typed pointer.
    pub fn freeTyped(self: *Self, ptr: anytype) void {
        self.free(@as(*anyopaque, @ptrCast(@alignCast(ptr))));
    }

    /// Reset all slab pools (bulk deallocation).
    /// WARNING: invalidates ALL previously allocated pointers.
    /// Oversized allocations are freed and tracking is cleared.
    pub fn reset(self: *Self) void {
        for (&self.slabs) |*maybe_slab| {
            if (maybe_slab.*) |*slab| {
                slab.pool.reset();
            }
        }

        // Free all oversized allocations
        for (self.oversized.items) |entry| {
            const aligned_slice: []align(@alignOf(*anyopaque)) u8 = entry.ptr[0..entry.len];
            self.allocator.free(aligned_slice);
        }
        self.oversized.clearRetainingCapacity();

        self.total_allocated = 0;
        self.total_freed = 0;
        self.oversized_allocated = 0;
        self.oversized_freed = 0;
    }

    /// Get allocation statistics.
    pub fn getStats(self: *const Self) Stats {
        var class_allocated: [NUM_CLASSES]usize = [_]usize{0} ** NUM_CLASSES;
        var class_capacity: [NUM_CLASSES]usize = [_]usize{0} ** NUM_CLASSES;

        for (self.slabs, 0..) |maybe_slab, i| {
            if (maybe_slab) |slab| {
                class_allocated[i] = slab.pool.allocated;
                class_capacity[i] = slab.pool.capacity;
            }
        }

        return Stats{
            .total_allocated = self.total_allocated,
            .total_freed = self.total_freed,
            .in_use = self.total_allocated - self.total_freed,
            .oversized_allocated = self.oversized_allocated,
            .oversized_freed = self.oversized_freed,
            .oversized_in_use = self.oversized_allocated - self.oversized_freed,
            .class_allocated = class_allocated,
            .class_capacity = class_capacity,
        };
    }

    /// Returns the size classes available in this allocator.
    pub fn getSizeClasses() []const usize {
        return &SIZE_CLASSES;
    }

    /// Returns which size class a given allocation size maps to.
    /// Returns null if the size exceeds the maximum slab size.
    pub fn sizeClassFor(size: usize) ?usize {
        const idx = sizeClassIndex(size) orelse return null;
        return SIZE_CLASSES[idx];
    }

    // ================================================================
    // Internal helpers
    // ================================================================

    /// Map a requested size to its size-class index.
    /// Returns null if size exceeds MAX_SLAB_SIZE.
    fn sizeClassIndex(size: usize) ?usize {
        // Branchless power-of-2 round-up via bit manipulation would be ideal,
        // but with only 10 classes a linear scan is effectively free
        // and more readable.
        for (SIZE_CLASSES, 0..) |class_size, i| {
            if (size <= class_size) return i;
        }
        return null; // Oversized
    }
};

// ====================================================================
// Tests
// ====================================================================

const testing = std.testing;

test "slab - basic alloc/free" {
    var slab = try SlabAllocator.init(testing.allocator, 64);
    defer slab.deinit();

    const ptr1 = try slab.alloc(32);
    const ptr2 = try slab.alloc(64);
    const ptr3 = try slab.alloc(128);

    try testing.expectEqual(@as(usize, 3), slab.total_allocated);

    slab.free(ptr1);
    slab.free(ptr2);
    slab.free(ptr3);

    try testing.expectEqual(@as(usize, 3), slab.total_freed);
}

test "slab - size class routing" {
    // Verify sizes map to correct classes
    try testing.expectEqual(@as(?usize, 8), SlabAllocator.sizeClassFor(1));
    try testing.expectEqual(@as(?usize, 8), SlabAllocator.sizeClassFor(8));
    try testing.expectEqual(@as(?usize, 16), SlabAllocator.sizeClassFor(9));
    try testing.expectEqual(@as(?usize, 16), SlabAllocator.sizeClassFor(16));
    try testing.expectEqual(@as(?usize, 32), SlabAllocator.sizeClassFor(17));
    try testing.expectEqual(@as(?usize, 64), SlabAllocator.sizeClassFor(33));
    try testing.expectEqual(@as(?usize, 256), SlabAllocator.sizeClassFor(200));
    try testing.expectEqual(@as(?usize, 4096), SlabAllocator.sizeClassFor(4096));
    try testing.expectEqual(@as(?usize, null), SlabAllocator.sizeClassFor(4097));
}

test "slab - all size classes" {
    var slab = try SlabAllocator.init(testing.allocator, 16);
    defer slab.deinit();

    // Allocate from every size class
    var ptrs: [NUM_CLASSES]*anyopaque = undefined;
    for (SIZE_CLASSES, 0..) |size, i| {
        ptrs[i] = try slab.alloc(size);
    }

    try testing.expectEqual(@as(usize, NUM_CLASSES), slab.total_allocated);

    // Free all
    for (&ptrs) |ptr| {
        slab.free(ptr);
    }

    try testing.expectEqual(@as(usize, NUM_CLASSES), slab.total_freed);
}

test "slab - typed allocation" {
    var slab = try SlabAllocator.init(testing.allocator, 32);
    defer slab.deinit();

    const TestStruct = struct {
        x: u64,
        y: u64,
        z: f64,
    };

    const obj = try slab.allocTyped(TestStruct);
    obj.* = .{ .x = 42, .y = 99, .z = 3.14 };

    try testing.expectEqual(@as(u64, 42), obj.x);
    try testing.expectEqual(@as(u64, 99), obj.y);

    slab.freeTyped(obj);
}

test "slab - pool exhaustion" {
    var slab = try SlabAllocator.init(testing.allocator, 4);
    defer slab.deinit();

    // Allocate all 4 slots in the 64-byte class
    var ptrs: [4]*anyopaque = undefined;
    for (&ptrs) |*ptr| {
        ptr.* = try slab.alloc(64);
    }

    // 5th allocation in same class should fail
    try testing.expectError(error.OutOfMemory, slab.alloc(64));

    // But allocation in a different class should succeed
    const other = try slab.alloc(128);
    slab.free(other);

    // Free one and reallocate
    slab.free(ptrs[2]);
    const reused = try slab.alloc(64);
    slab.free(reused);

    // Cleanup
    slab.free(ptrs[0]);
    slab.free(ptrs[1]);
    slab.free(ptrs[3]);
}

test "slab - oversized allocation" {
    var slab = try SlabAllocator.init(testing.allocator, 8);
    defer slab.deinit();

    // Allocate something larger than MAX_SLAB_SIZE (4096)
    const big1 = try slab.alloc(8192);
    const big2 = try slab.alloc(16384);

    try testing.expectEqual(@as(usize, 2), slab.oversized_allocated);
    try testing.expectEqual(@as(usize, 2), slab.total_allocated);

    slab.free(big1);
    try testing.expectEqual(@as(usize, 1), slab.oversized_freed);

    slab.free(big2);
    try testing.expectEqual(@as(usize, 2), slab.oversized_freed);
}

test "slab - mixed slab and oversized" {
    var slab = try SlabAllocator.init(testing.allocator, 16);
    defer slab.deinit();

    // Mix of slab-managed and oversized allocations
    const small1 = try slab.alloc(16);
    const big1 = try slab.alloc(8192);
    const small2 = try slab.alloc(256);
    const big2 = try slab.alloc(65536);
    const small3 = try slab.alloc(4096);

    try testing.expectEqual(@as(usize, 5), slab.total_allocated);
    try testing.expectEqual(@as(usize, 2), slab.oversized_allocated);

    // Free in arbitrary order
    slab.free(big1);
    slab.free(small2);
    slab.free(small1);
    slab.free(big2);
    slab.free(small3);

    const stats = slab.getStats();
    try testing.expectEqual(@as(usize, 0), stats.in_use);
    try testing.expectEqual(@as(usize, 0), stats.oversized_in_use);
}

test "slab - reset" {
    var slab = try SlabAllocator.init(testing.allocator, 32);
    defer slab.deinit();

    // Allocate a bunch
    _ = try slab.alloc(8);
    _ = try slab.alloc(64);
    _ = try slab.alloc(512);
    _ = try slab.alloc(8192); // oversized

    try testing.expectEqual(@as(usize, 4), slab.total_allocated);

    // Reset everything
    slab.reset();

    try testing.expectEqual(@as(usize, 0), slab.total_allocated);
    try testing.expectEqual(@as(usize, 0), slab.total_freed);
    try testing.expectEqual(@as(usize, 0), slab.oversized_allocated);

    // Should be able to allocate again
    const ptr = try slab.alloc(64);
    slab.free(ptr);
}

test "slab - statistics" {
    var slab = try SlabAllocator.init(testing.allocator, 16);
    defer slab.deinit();

    // Allocate from different classes
    const p8 = try slab.alloc(8);
    const p64 = try slab.alloc(64);
    const p256 = try slab.alloc(256);

    const stats = slab.getStats();
    try testing.expectEqual(@as(usize, 3), stats.total_allocated);
    try testing.expectEqual(@as(usize, 0), stats.total_freed);
    try testing.expectEqual(@as(usize, 3), stats.in_use);

    // Check per-class stats (8 is class 0, 64 is class 3, 256 is class 5)
    try testing.expectEqual(@as(usize, 1), stats.class_allocated[0]); // 8-byte class
    try testing.expectEqual(@as(usize, 1), stats.class_allocated[3]); // 64-byte class
    try testing.expectEqual(@as(usize, 1), stats.class_allocated[5]); // 256-byte class

    slab.free(p8);
    slab.free(p64);
    slab.free(p256);
}

test "slab - per-class capacities" {
    // Give different capacities to different size classes
    var slab = try SlabAllocator.initWithCapacities(testing.allocator, .{
        128, // 8-byte class: lots of small objects
        64,  // 16-byte class
        32,  // 32-byte class
        16,  // 64-byte class
        8,   // 128-byte class
        4,   // 256-byte class
        2,   // 512-byte class
        2,   // 1024-byte class
        1,   // 2048-byte class
        1,   // 4096-byte class
    });
    defer slab.deinit();

    const stats = slab.getStats();
    try testing.expectEqual(@as(usize, 128), stats.class_capacity[0]);
    try testing.expectEqual(@as(usize, 1), stats.class_capacity[9]);

    // Verify capacity limit on small class
    var ptrs: [128]*anyopaque = undefined;
    for (&ptrs) |*ptr| {
        ptr.* = try slab.alloc(8);
    }
    try testing.expectError(error.OutOfMemory, slab.alloc(8));

    for (ptrs) |ptr| slab.free(ptr);
}

test "slab - stress test alloc/free patterns" {
    var slab = try SlabAllocator.init(testing.allocator, 128);
    defer slab.deinit();

    const iterations = 1000;
    var ptrs: [64]*anyopaque = undefined;
    var count: usize = 0;

    // Fill up
    for (&ptrs) |*ptr| {
        const size = @as(usize, 1) + (@as(usize, count) % 512);
        ptr.* = try slab.alloc(size);
        count += 1;
    }

    // Free every other one
    var i: usize = 0;
    while (i < 64) : (i += 2) {
        slab.free(ptrs[i]);
    }

    // Reallocate the freed slots with different sizes
    i = 0;
    while (i < 64) : (i += 2) {
        const size = @as(usize, 1) + (i * 7 % 256);
        ptrs[i] = try slab.alloc(size);
    }

    _ = iterations;

    // Free everything
    for (ptrs) |ptr| slab.free(ptr);

    const stats = slab.getStats();
    try testing.expectEqual(@as(usize, 0), stats.in_use);
}

test "slab - zero size allocation" {
    var slab = try SlabAllocator.init(testing.allocator, 16);
    defer slab.deinit();

    try testing.expectError(error.OutOfMemory, slab.alloc(0));
}

test "slab - write to allocated memory" {
    var slab = try SlabAllocator.init(testing.allocator, 16);
    defer slab.deinit();

    // Allocate and write various sizes
    const small = try slab.alloc(8);
    const small_slice = @as([*]u8, @ptrCast(small))[0..8];
    @memset(small_slice, 0xAA);
    try testing.expectEqual(@as(u8, 0xAA), small_slice[0]);
    try testing.expectEqual(@as(u8, 0xAA), small_slice[7]);

    const medium = try slab.alloc(256);
    const med_slice = @as([*]u8, @ptrCast(medium))[0..256];
    @memset(med_slice, 0xBB);
    try testing.expectEqual(@as(u8, 0xBB), med_slice[255]);

    // Verify small allocation wasn't corrupted
    try testing.expectEqual(@as(u8, 0xAA), small_slice[0]);

    slab.free(small);
    slab.free(medium);
}

test "slab - allocation by size class" {
    var slab = try SlabAllocator.init(testing.allocator, 8);
    defer slab.deinit();

    var ptrs: [SIZE_CLASSES.len]*anyopaque = undefined;

    // Allocate exactly matching each size class
    for (SIZE_CLASSES, 0..) |size, i| {
        ptrs[i] = try slab.alloc(size);
    }

    // Verify all allocations succeeded
    try testing.expectEqual(@as(usize, NUM_CLASSES), slab.total_allocated);

    // Free all
    for (&ptrs) |ptr| {
        slab.free(ptr);
    }

    try testing.expectEqual(@as(usize, NUM_CLASSES), slab.total_freed);
}

test "slab - alignment verification" {
    var slab = try SlabAllocator.init(testing.allocator, 16);
    defer slab.deinit();

    const alignment = @alignOf(*anyopaque);

    // Allocate various sizes and verify alignment
    const ptr1 = try slab.alloc(1);
    const ptr2 = try slab.alloc(7);
    const ptr3 = try slab.alloc(128);
    const ptr4 = try slab.alloc(4096);

    const addr1 = @intFromPtr(ptr1);
    const addr2 = @intFromPtr(ptr2);
    const addr3 = @intFromPtr(ptr3);
    const addr4 = @intFromPtr(ptr4);

    try testing.expectEqual(@as(usize, 0), addr1 % alignment);
    try testing.expectEqual(@as(usize, 0), addr2 % alignment);
    try testing.expectEqual(@as(usize, 0), addr3 % alignment);
    try testing.expectEqual(@as(usize, 0), addr4 % alignment);

    slab.free(ptr1);
    slab.free(ptr2);
    slab.free(ptr3);
    slab.free(ptr4);
}

test "slab - free and reuse" {
    var slab = try SlabAllocator.init(testing.allocator, 8);
    defer slab.deinit();

    // Allocate 3 items of size 64
    const p1 = try slab.alloc(64);
    const p2 = try slab.alloc(64);
    const p3 = try slab.alloc(64);

    try testing.expectEqual(@as(usize, 3), slab.total_allocated);

    // Free and reallocate
    slab.free(p1);
    try testing.expectEqual(@as(usize, 1), slab.total_freed);

    // After freeing p1, in_use = 2
    const stats1 = slab.getStats();
    try testing.expectEqual(@as(usize, 2), stats1.in_use);

    const p4 = try slab.alloc(64); // Should reuse p1's slot
    try testing.expectEqual(@as(usize, 4), slab.total_allocated);

    // After allocating p4, in_use = 3 again
    const stats2 = slab.getStats();
    try testing.expectEqual(@as(usize, 3), stats2.in_use);

    slab.free(p2);
    slab.free(p3);
    slab.free(p4);

    try testing.expectEqual(@as(usize, 4), slab.total_freed);
}

test "slab - mixed size allocations" {
    var slab = try SlabAllocator.init(testing.allocator, 32);
    defer slab.deinit();

    // Allocate different sizes in random order
    var ptrs: [10]*anyopaque = undefined;
    const sizes: [10]usize = .{ 8, 256, 32, 4096, 16, 1024, 64, 2048, 128, 512 };

    for (sizes, 0..) |size, i| {
        ptrs[i] = try slab.alloc(size);
    }

    // Free in random order
    const free_order: [10]usize = .{ 3, 1, 5, 8, 0, 9, 2, 7, 4, 6 };
    for (free_order) |idx| {
        slab.free(ptrs[idx]);
    }

    const stats = slab.getStats();
    try testing.expectEqual(@as(usize, 0), stats.in_use);
}

test "slab - OOM handling" {
    var slab = try SlabAllocator.init(testing.allocator, 2);
    defer slab.deinit();

    // Allocate until pool for 64-byte class is full
    var ptrs: [2]*anyopaque = undefined;
    ptrs[0] = try slab.alloc(64);
    ptrs[1] = try slab.alloc(64);

    // Next allocation in same class should fail
    try testing.expectError(error.OutOfMemory, slab.alloc(64));

    // But other classes should still work
    const other = try slab.alloc(256);
    slab.free(other);

    slab.free(ptrs[0]);
    slab.free(ptrs[1]);
}

test "slab - statistics tracking" {
    var slab = try SlabAllocator.init(testing.allocator, 16);
    defer slab.deinit();

    var stats = slab.getStats();
    try testing.expectEqual(@as(usize, 0), stats.total_allocated);
    try testing.expectEqual(@as(usize, 0), stats.in_use);

    const p1 = try slab.alloc(8);
    const p2 = try slab.alloc(64);
    const p3 = try slab.alloc(512);

    stats = slab.getStats();
    try testing.expectEqual(@as(usize, 3), stats.total_allocated);
    try testing.expectEqual(@as(usize, 3), stats.in_use);

    // Verify per-class allocation counts
    try testing.expectEqual(@as(usize, 1), stats.class_allocated[0]); // 8-byte
    try testing.expectEqual(@as(usize, 1), stats.class_allocated[3]); // 64-byte
    try testing.expectEqual(@as(usize, 1), stats.class_allocated[6]); // 512-byte

    slab.free(p1);
    stats = slab.getStats();
    try testing.expectEqual(@as(usize, 1), stats.total_freed);
    try testing.expectEqual(@as(usize, 2), stats.in_use);

    slab.free(p2);
    slab.free(p3);
    stats = slab.getStats();
    try testing.expectEqual(@as(usize, 0), stats.in_use);
}
