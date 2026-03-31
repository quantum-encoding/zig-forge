//! Memory Pool Core - Pure Computational FFI
//!
//! This FFI exposes high-performance memory allocators as a zero-dependency C library.
//!
//! ZERO DEPENDENCIES:
//! - No networking
//! - No file I/O
//! - No global state (except pool instances)
//!
//! Thread Safety:
//! - Fixed pools: Thread-safe if used from single thread per pool
//! - Arenas: Thread-safe if used from single thread per arena
//! - Multiple pools/arenas safe from different threads
//!
//! Performance:
//! - Fixed pool alloc: <10ns latency
//! - Fixed pool free: <5ns latency
//! - Arena alloc: <3ns latency
//! - Arena reset: O(1)

const std = @import("std");
const pool_mod = @import("pool/fixed.zig");
const arena_mod = @import("arena/bump.zig");

// ============================================================================
// Core Types (C-compatible)
// ============================================================================

/// Opaque fixed pool handle
pub const MP_FixedPool = opaque {};

/// Opaque arena allocator handle
pub const MP_Arena = opaque {};

/// Error codes
pub const MP_Error = enum(c_int) {
    SUCCESS = 0,
    OUT_OF_MEMORY = -1,
    INVALID_PARAM = -2,
    INVALID_HANDLE = -3,
};

/// Fixed pool statistics
pub const MP_FixedPoolStats = extern struct {
    object_size: usize,
    capacity: usize,
    allocated: usize,
    available: usize,
};

/// Arena statistics
pub const MP_ArenaStats = extern struct {
    buffer_size: usize,
    offset: usize,
    available: usize,
};

// ============================================================================
// Fixed Pool Operations
// ============================================================================

/// Create a new fixed-size memory pool
///
/// Parameters:
///   object_size - Size of each object in bytes
///   capacity    - Maximum number of objects
///
/// Returns:
///   Pool handle, or NULL on allocation failure
///
/// Performance:
///   ~1µs (initial allocation)
///
/// Thread Safety:
///   Safe to create multiple pools
///
/// Example:
///   // Pool for 256 objects of 64 bytes each
///   MP_FixedPool* pool = mp_fixed_pool_create(64, 256);
export fn mp_fixed_pool_create(object_size: usize, capacity: usize) ?*MP_FixedPool {
    if (object_size == 0 or capacity == 0) return null;

    const allocator = std.heap.c_allocator;

    const pool = allocator.create(pool_mod.FixedPool) catch return null;

    pool.* = pool_mod.FixedPool.init(allocator, object_size, capacity) catch {
        allocator.destroy(pool);
        return null;
    };

    return @ptrCast(pool);
}

/// Destroy fixed pool and free resources
///
/// Parameters:
///   pool - Pool handle (NULL is safe, will be no-op)
///
/// Note:
///   Does NOT free objects allocated from the pool
export fn mp_fixed_pool_destroy(pool: ?*MP_FixedPool) void {
    if (pool) |p| {
        const pool_ptr: *pool_mod.FixedPool = @ptrCast(@alignCast(p));
        pool_ptr.deinit();
        std.heap.c_allocator.destroy(pool_ptr);
    }
}

/// Allocate an object from the fixed pool
///
/// Parameters:
///   pool - Pool handle (must not be NULL)
///
/// Returns:
///   Pointer to object, or NULL if pool is full
///
/// Performance:
///   <10ns per allocation
///
/// Thread Safety:
///   Safe if pool is used from single thread
export fn mp_fixed_pool_alloc(pool: ?*MP_FixedPool) ?*anyopaque {
    const pool_ptr: *pool_mod.FixedPool = @ptrCast(@alignCast(pool orelse return null));
    return pool_ptr.alloc() catch null;
}

/// Free an object back to the fixed pool
///
/// Parameters:
///   pool - Pool handle (must not be NULL)
///   ptr  - Object pointer (must have been allocated from this pool)
///
/// Performance:
///   <5ns per free
///
/// Thread Safety:
///   Safe if pool is used from single thread
export fn mp_fixed_pool_free(pool: ?*MP_FixedPool, ptr: ?*anyopaque) void {
    const pool_ptr: *pool_mod.FixedPool = @ptrCast(@alignCast(pool orelse return));
    if (ptr) |p| {
        pool_ptr.free(p);
    }
}

/// Reset the fixed pool (free all objects)
///
/// Parameters:
///   pool - Pool handle (must not be NULL)
///
/// Note:
///   Invalidates all previously allocated pointers
///   O(capacity) operation
export fn mp_fixed_pool_reset(pool: ?*MP_FixedPool) void {
    const pool_ptr: *pool_mod.FixedPool = @ptrCast(@alignCast(pool orelse return));
    pool_ptr.reset();
}

/// Get fixed pool statistics
///
/// Parameters:
///   pool      - Pool handle (must not be NULL)
///   stats_out - Output statistics
///
/// Returns:
///   SUCCESS or INVALID_HANDLE
export fn mp_fixed_pool_stats(
    pool: ?*const MP_FixedPool,
    stats_out: *MP_FixedPoolStats,
) MP_Error {
    const pool_ptr: *const pool_mod.FixedPool = @ptrCast(@alignCast(pool orelse return .INVALID_HANDLE));

    stats_out.* = .{
        .object_size = pool_ptr.object_size,
        .capacity = pool_ptr.capacity,
        .allocated = pool_ptr.allocated,
        .available = pool_ptr.capacity - pool_ptr.allocated,
    };

    return .SUCCESS;
}

// ============================================================================
// Arena Allocator Operations
// ============================================================================

/// Create a new arena allocator
///
/// Parameters:
///   size - Total buffer size in bytes
///
/// Returns:
///   Arena handle, or NULL on allocation failure
///
/// Performance:
///   ~1µs (initial allocation)
///
/// Thread Safety:
///   Safe to create multiple arenas
///
/// Example:
///   // Arena with 1MB buffer
///   MP_Arena* arena = mp_arena_create(1024 * 1024);
export fn mp_arena_create(size: usize) ?*MP_Arena {
    if (size == 0) return null;

    const allocator = std.heap.c_allocator;

    const arena = allocator.create(arena_mod.ArenaAllocator) catch return null;

    arena.* = arena_mod.ArenaAllocator.init(allocator, size) catch {
        allocator.destroy(arena);
        return null;
    };

    return @ptrCast(arena);
}

/// Destroy arena and free resources
///
/// Parameters:
///   arena - Arena handle (NULL is safe, will be no-op)
///
/// Note:
///   Frees all memory allocated from the arena
export fn mp_arena_destroy(arena: ?*MP_Arena) void {
    if (arena) |a| {
        const arena_ptr: *arena_mod.ArenaAllocator = @ptrCast(@alignCast(a));
        arena_ptr.deinit();
        std.heap.c_allocator.destroy(arena_ptr);
    }
}

/// Allocate memory from the arena
///
/// Parameters:
///   arena     - Arena handle (must not be NULL)
///   size      - Allocation size in bytes
///   alignment - Alignment requirement (must be power of 2)
///
/// Returns:
///   Pointer to allocated memory, or NULL if arena is full
///
/// Performance:
///   <3ns per allocation
///
/// Thread Safety:
///   Safe if arena is used from single thread
export fn mp_arena_alloc(arena: ?*MP_Arena, size: usize, alignment: usize) ?*anyopaque {
    const arena_ptr: *arena_mod.ArenaAllocator = @ptrCast(@alignCast(arena orelse return null));
    const slice = arena_ptr.alloc(size, alignment) catch return null;
    return @ptrCast(slice.ptr);
}

/// Reset the arena (free all allocations)
///
/// Parameters:
///   arena - Arena handle (must not be NULL)
///
/// Note:
///   Invalidates all previously allocated pointers
///   O(1) operation
export fn mp_arena_reset(arena: ?*MP_Arena) void {
    const arena_ptr: *arena_mod.ArenaAllocator = @ptrCast(@alignCast(arena orelse return));
    arena_ptr.reset();
}

/// Get arena statistics
///
/// Parameters:
///   arena     - Arena handle (must not be NULL)
///   stats_out - Output statistics
///
/// Returns:
///   SUCCESS or INVALID_HANDLE
export fn mp_arena_stats(
    arena: ?*const MP_Arena,
    stats_out: *MP_ArenaStats,
) MP_Error {
    const arena_ptr: *const arena_mod.ArenaAllocator = @ptrCast(@alignCast(arena orelse return .INVALID_HANDLE));

    stats_out.* = .{
        .buffer_size = arena_ptr.buffer.len,
        .offset = arena_ptr.offset,
        .available = arena_ptr.buffer.len - arena_ptr.offset,
    };

    return .SUCCESS;
}

// ============================================================================
// Slab Allocator Operations
// ============================================================================

const slab_mod = @import("slab/allocator.zig");

/// Opaque slab allocator handle
pub const MP_Slab = opaque {};

/// Slab allocator statistics
pub const MP_SlabStats = extern struct {
    total_allocated: usize,
    total_freed: usize,
    in_use: usize,
    oversized_in_use: usize,
};

/// Create a new slab allocator with uniform capacity per size class
///
/// Parameters:
///   capacity - Number of objects per size class (10 classes: 8..4096 bytes)
///
/// Returns:
///   Slab handle, or NULL on allocation failure
///
/// Performance:
///   ~10µs (allocates 10 FixedPools)
export fn mp_slab_create(capacity: usize) ?*MP_Slab {
    if (capacity == 0) return null;

    const allocator = std.heap.c_allocator;
    const slab = allocator.create(slab_mod.SlabAllocator) catch return null;

    slab.* = slab_mod.SlabAllocator.init(allocator, capacity) catch {
        allocator.destroy(slab);
        return null;
    };

    return @ptrCast(slab);
}

/// Destroy slab allocator and free all resources
///
/// Parameters:
///   slab - Slab handle (NULL is safe, will be no-op)
export fn mp_slab_destroy(slab: ?*MP_Slab) void {
    if (slab) |s| {
        const slab_ptr: *slab_mod.SlabAllocator = @ptrCast(@alignCast(s));
        slab_ptr.deinit();
        std.heap.c_allocator.destroy(slab_ptr);
    }
}

/// Allocate memory from the slab allocator
///
/// Parameters:
///   slab - Slab handle (must not be NULL)
///   size - Requested size in bytes
///
/// Returns:
///   Pointer to allocated memory, or NULL if pool exhausted
///
/// Performance:
///   <15ns for sizes <= 4096 (slab path)
///   Fallback to malloc for sizes > 4096
export fn mp_slab_alloc(slab: ?*MP_Slab, size: usize) ?*anyopaque {
    const slab_ptr: *slab_mod.SlabAllocator = @ptrCast(@alignCast(slab orelse return null));
    return slab_ptr.alloc(size) catch null;
}

/// Free memory back to the slab allocator
///
/// Parameters:
///   slab - Slab handle (must not be NULL)
///   ptr  - Pointer previously returned by mp_slab_alloc
export fn mp_slab_free(slab: ?*MP_Slab, ptr: ?*anyopaque) void {
    const slab_ptr: *slab_mod.SlabAllocator = @ptrCast(@alignCast(slab orelse return));
    if (ptr) |p| {
        slab_ptr.free(p);
    }
}

/// Reset slab allocator (free all allocations)
///
/// Parameters:
///   slab - Slab handle (must not be NULL)
///
/// Note:
///   Invalidates all previously allocated pointers
export fn mp_slab_reset(slab: ?*MP_Slab) void {
    const slab_ptr: *slab_mod.SlabAllocator = @ptrCast(@alignCast(slab orelse return));
    slab_ptr.reset();
}

/// Get slab allocator statistics
export fn mp_slab_stats(
    slab: ?*const MP_Slab,
    stats_out: *MP_SlabStats,
) MP_Error {
    const slab_ptr: *const slab_mod.SlabAllocator = @ptrCast(@alignCast(slab orelse return .INVALID_HANDLE));
    const stats = slab_ptr.getStats();

    stats_out.* = .{
        .total_allocated = stats.total_allocated,
        .total_freed = stats.total_freed,
        .in_use = stats.in_use,
        .oversized_in_use = stats.oversized_in_use,
    };

    return .SUCCESS;
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Get human-readable error string
export fn mp_error_string(error_code: MP_Error) [*:0]const u8 {
    return switch (error_code) {
        .SUCCESS => "Success",
        .OUT_OF_MEMORY => "Out of memory",
        .INVALID_PARAM => "Invalid parameter",
        .INVALID_HANDLE => "Invalid handle",
    };
}

/// Get library version
export fn mp_version() [*:0]const u8 {
    return "2.0.0-core";
}

/// Get performance info string
export fn mp_performance_info() [*:0]const u8 {
    return "Fixed: <10ns alloc | Arena: <3ns alloc | Slab: <15ns alloc";
}

// ============================================================================
// Tests
// ============================================================================

test "memory_pool_core - fixed pool create/destroy lifecycle" {
    const pool = mp_fixed_pool_create(64, 32);
    try std.testing.expect(pool != null);

    mp_fixed_pool_destroy(pool);
    // Test that destroy(null) is safe
    mp_fixed_pool_destroy(null);
}

test "memory_pool_core - fixed pool alloc/free" {
    const pool = mp_fixed_pool_create(256, 16) orelse return;
    defer mp_fixed_pool_destroy(pool);

    const ptr1 = mp_fixed_pool_alloc(pool);
    try std.testing.expect(ptr1 != null);

    const ptr2 = mp_fixed_pool_alloc(pool);
    try std.testing.expect(ptr2 != null);

    mp_fixed_pool_free(pool, ptr1);
    mp_fixed_pool_free(pool, ptr2);

    // Test that free(null) is safe
    mp_fixed_pool_free(pool, null);
}

test "memory_pool_core - fixed pool exhaustion" {
    const pool = mp_fixed_pool_create(64, 4) orelse return;
    defer mp_fixed_pool_destroy(pool);

    var ptrs: [4]?*anyopaque = undefined;

    // Allocate all slots
    for (&ptrs) |*ptr| {
        ptr.* = mp_fixed_pool_alloc(pool);
        try std.testing.expect(ptr.* != null);
    }

    // Next allocation should fail (return null)
    const overflow = mp_fixed_pool_alloc(pool);
    try std.testing.expect(overflow == null);

    // Free and verify we can allocate again
    mp_fixed_pool_free(pool, ptrs[0]);
    const reused = mp_fixed_pool_alloc(pool);
    try std.testing.expect(reused != null);

    for (&ptrs) |ptr| {
        mp_fixed_pool_free(pool, ptr);
    }
    mp_fixed_pool_free(pool, reused);
}

test "memory_pool_core - fixed pool stats" {
    const pool = mp_fixed_pool_create(128, 8) orelse return;
    defer mp_fixed_pool_destroy(pool);

    var stats: MP_FixedPoolStats = undefined;
    var err = mp_fixed_pool_stats(pool, &stats);
    try std.testing.expectEqual(MP_Error.SUCCESS, err);

    try std.testing.expectEqual(@as(usize, 128), stats.object_size);
    try std.testing.expectEqual(@as(usize, 8), stats.capacity);
    try std.testing.expectEqual(@as(usize, 0), stats.allocated);
    try std.testing.expectEqual(@as(usize, 8), stats.available);

    // Allocate one
    const ptr = mp_fixed_pool_alloc(pool);
    err = mp_fixed_pool_stats(pool, &stats);
    try std.testing.expectEqual(MP_Error.SUCCESS, err);
    try std.testing.expectEqual(@as(usize, 1), stats.allocated);
    try std.testing.expectEqual(@as(usize, 7), stats.available);

    mp_fixed_pool_free(pool, ptr);
}

test "memory_pool_core - arena create/destroy lifecycle" {
    const arena = mp_arena_create(4096);
    try std.testing.expect(arena != null);

    mp_arena_destroy(arena);
    // Test that destroy(null) is safe
    mp_arena_destroy(null);
}

test "memory_pool_core - arena alloc" {
    const arena = mp_arena_create(1024) orelse return;
    defer mp_arena_destroy(arena);

    const ptr1 = mp_arena_alloc(arena, 128, 8);
    try std.testing.expect(ptr1 != null);

    const ptr2 = mp_arena_alloc(arena, 256, 16);
    try std.testing.expect(ptr2 != null);

    // Verify alignment
    const addr1 = @intFromPtr(ptr1);
    const addr2 = @intFromPtr(ptr2);
    try std.testing.expectEqual(@as(usize, 0), addr1 % 8);
    try std.testing.expectEqual(@as(usize, 0), addr2 % 16);
}

test "memory_pool_core - arena exhaustion" {
    const arena = mp_arena_create(256) orelse return;
    defer mp_arena_destroy(arena);

    // Allocate most of the arena
    const ptr1 = mp_arena_alloc(arena, 200, 1);
    try std.testing.expect(ptr1 != null);

    // Next allocation should fail
    const ptr2 = mp_arena_alloc(arena, 100, 1);
    try std.testing.expect(ptr2 == null);
}

test "memory_pool_core - arena reset" {
    const arena = mp_arena_create(512) orelse return;
    defer mp_arena_destroy(arena);

    // Allocate
    _ = mp_arena_alloc(arena, 100, 1);
    _ = mp_arena_alloc(arena, 200, 1);

    var stats: MP_ArenaStats = undefined;
    var err = mp_arena_stats(arena, &stats);
    try std.testing.expectEqual(MP_Error.SUCCESS, err);
    try std.testing.expect(stats.offset > 0);

    // Reset
    mp_arena_reset(arena);

    err = mp_arena_stats(arena, &stats);
    try std.testing.expectEqual(MP_Error.SUCCESS, err);
    try std.testing.expectEqual(@as(usize, 0), stats.offset);
    try std.testing.expectEqual(@as(usize, 512), stats.available);
}

test "memory_pool_core - arena stats" {
    const arena = mp_arena_create(1024) orelse return;
    defer mp_arena_destroy(arena);

    var stats: MP_ArenaStats = undefined;
    var err = mp_arena_stats(arena, &stats);
    try std.testing.expectEqual(MP_Error.SUCCESS, err);

    try std.testing.expectEqual(@as(usize, 1024), stats.buffer_size);
    try std.testing.expectEqual(@as(usize, 0), stats.offset);
    try std.testing.expectEqual(@as(usize, 1024), stats.available);

    _ = mp_arena_alloc(arena, 300, 1);
    err = mp_arena_stats(arena, &stats);
    try std.testing.expectEqual(MP_Error.SUCCESS, err);
    try std.testing.expectEqual(@as(usize, 300), stats.offset);
    try std.testing.expectEqual(@as(usize, 724), stats.available);
}

test "memory_pool_core - slab create/destroy lifecycle" {
    const slab = mp_slab_create(64);
    try std.testing.expect(slab != null);

    mp_slab_destroy(slab);
    // Test that destroy(null) is safe
    mp_slab_destroy(null);
}

test "memory_pool_core - slab alloc/free" {
    const slab = mp_slab_create(16) orelse return;
    defer mp_slab_destroy(slab);

    const ptr1 = mp_slab_alloc(slab, 32);
    try std.testing.expect(ptr1 != null);

    const ptr2 = mp_slab_alloc(slab, 512);
    try std.testing.expect(ptr2 != null);

    mp_slab_free(slab, ptr1);
    mp_slab_free(slab, ptr2);

    // Test that free(null) is safe
    mp_slab_free(slab, null);
}

test "memory_pool_core - slab all size classes" {
    const slab = mp_slab_create(8) orelse return;
    defer mp_slab_destroy(slab);

    // Allocate from each size class (8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096)
    var ptrs: [10]?*anyopaque = undefined;
    const sizes: [10]usize = .{ 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096 };

    for (sizes, 0..) |size, i| {
        ptrs[i] = mp_slab_alloc(slab, size);
        try std.testing.expect(ptrs[i] != null);
    }

    for (&ptrs) |ptr| {
        mp_slab_free(slab, ptr);
    }
}

test "memory_pool_core - slab oversized allocation" {
    const slab = mp_slab_create(8) orelse return;
    defer mp_slab_destroy(slab);

    // Allocate larger than maximum slab size (4096)
    const big = mp_slab_alloc(slab, 8192);
    try std.testing.expect(big != null);

    mp_slab_free(slab, big);
}

test "memory_pool_core - slab reset" {
    const slab = mp_slab_create(16) orelse return;
    defer mp_slab_destroy(slab);

    // Allocate
    _ = mp_slab_alloc(slab, 64);
    _ = mp_slab_alloc(slab, 256);
    _ = mp_slab_alloc(slab, 2048);

    var stats: MP_SlabStats = undefined;
    var err = mp_slab_stats(slab, &stats);
    try std.testing.expectEqual(MP_Error.SUCCESS, err);
    try std.testing.expectEqual(@as(usize, 3), stats.total_allocated);

    // Reset
    mp_slab_reset(slab);

    err = mp_slab_stats(slab, &stats);
    try std.testing.expectEqual(MP_Error.SUCCESS, err);
    try std.testing.expectEqual(@as(usize, 0), stats.total_allocated);
    try std.testing.expectEqual(@as(usize, 0), stats.in_use);
}

test "memory_pool_core - slab stats" {
    const slab = mp_slab_create(32) orelse return;
    defer mp_slab_destroy(slab);

    var stats: MP_SlabStats = undefined;
    var err = mp_slab_stats(slab, &stats);
    try std.testing.expectEqual(MP_Error.SUCCESS, err);
    try std.testing.expectEqual(@as(usize, 0), stats.in_use);

    const p1 = mp_slab_alloc(slab, 64);
    const p2 = mp_slab_alloc(slab, 256);
    const p3 = mp_slab_alloc(slab, 8192); // oversized

    err = mp_slab_stats(slab, &stats);
    try std.testing.expectEqual(MP_Error.SUCCESS, err);
    try std.testing.expectEqual(@as(usize, 3), stats.total_allocated);
    try std.testing.expectEqual(@as(usize, 3), stats.in_use);
    try std.testing.expectEqual(@as(usize, 1), stats.oversized_in_use);

    mp_slab_free(slab, p1);
    err = mp_slab_stats(slab, &stats);
    try std.testing.expectEqual(@as(usize, 2), stats.in_use);

    mp_slab_free(slab, p2);
    mp_slab_free(slab, p3);
    err = mp_slab_stats(slab, &stats);
    try std.testing.expectEqual(@as(usize, 0), stats.in_use);
}

test "memory_pool_core - error strings and version" {
    const success_str = std.mem.span(mp_error_string(MP_Error.SUCCESS));
    try std.testing.expect(success_str.len > 0);

    const version = std.mem.span(mp_version());
    try std.testing.expect(version.len > 0);

    const perf = std.mem.span(mp_performance_info());
    try std.testing.expect(perf.len > 0);
}
