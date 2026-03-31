//! Arena allocator (bump pointer)
//!
//! Performance: <3ns allocation
//!
//! Zig 0.16 version

const std = @import("std");

pub const ArenaAllocator = struct {
    allocator: std.mem.Allocator,
    buffer: []u8,
    offset: usize,

    pub fn init(allocator: std.mem.Allocator, size: usize) !ArenaAllocator {
        const buffer = try allocator.alloc(u8, size);
        return ArenaAllocator{
            .allocator = allocator,
            .buffer = buffer,
            .offset = 0,
        };
    }

    pub fn deinit(self: *ArenaAllocator) void {
        self.allocator.free(self.buffer);
    }

    pub fn alloc(self: *ArenaAllocator, size: usize, alignment: usize) ![]u8 {
        const aligned_offset = std.mem.alignForward(usize, self.offset, alignment);
        const new_offset = aligned_offset + size;

        if (new_offset > self.buffer.len) {
            return error.OutOfMemory;
        }

        self.offset = new_offset;
        return self.buffer[aligned_offset..new_offset];
    }

    pub fn reset(self: *ArenaAllocator) void {
        self.offset = 0;
    }
};

test "arena - basic allocation" {
    const allocator = std.testing.allocator;

    var arena = try ArenaAllocator.init(allocator, 1024);
    defer arena.deinit();

    const slice1 = try arena.alloc(64, 8);
    try std.testing.expectEqual(@as(usize, 64), slice1.len);

    const slice2 = try arena.alloc(128, 8);
    try std.testing.expectEqual(@as(usize, 128), slice2.len);

    try std.testing.expectEqual(@as(usize, 192), arena.offset);
}

test "arena - alignment handling" {
    const allocator = std.testing.allocator;

    var arena = try ArenaAllocator.init(allocator, 1024);
    defer arena.deinit();

    // Allocate 1 byte (unaligned)
    _ = try arena.alloc(1, 1);
    try std.testing.expectEqual(@as(usize, 1), arena.offset);

    // Allocate with 8-byte alignment - should skip to offset 8
    const slice = try arena.alloc(8, 8);
    try std.testing.expectEqual(@as(usize, 16), arena.offset);

    // Verify alignment
    const addr = @intFromPtr(slice.ptr);
    try std.testing.expectEqual(@as(usize, 0), addr % 8);
}

test "arena - out of memory" {
    const allocator = std.testing.allocator;

    var arena = try ArenaAllocator.init(allocator, 64);
    defer arena.deinit();

    // Fill most of the arena
    _ = try arena.alloc(50, 1);

    // This should fail
    try std.testing.expectError(error.OutOfMemory, arena.alloc(20, 1));
}

test "arena - reset functionality" {
    const allocator = std.testing.allocator;

    var arena = try ArenaAllocator.init(allocator, 512);
    defer arena.deinit();

    _ = try arena.alloc(100, 8);
    _ = try arena.alloc(200, 8);

    try std.testing.expect(arena.offset > 0);

    arena.reset();

    try std.testing.expectEqual(@as(usize, 0), arena.offset);

    // Should be able to allocate again
    const slice = try arena.alloc(256, 8);
    try std.testing.expectEqual(@as(usize, 256), slice.len);
}

test "arena - sequential allocations" {
    const allocator = std.testing.allocator;

    var arena = try ArenaAllocator.init(allocator, 1024);
    defer arena.deinit();

    var expected_offset: usize = 0;

    // Allocate multiple times
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const slice = try arena.alloc(32, 8);
        try std.testing.expectEqual(@as(usize, 32), slice.len);

        expected_offset = std.mem.alignForward(usize, expected_offset, 8) + 32;
    }

    try std.testing.expectEqual(expected_offset, arena.offset);
}

test "arena - large alignment" {
    const allocator = std.testing.allocator;

    var arena = try ArenaAllocator.init(allocator, 4096);
    defer arena.deinit();

    // Allocate 1 byte to offset from alignment
    _ = try arena.alloc(1, 1);

    // Allocate with 64-byte alignment (cache line)
    const slice = try arena.alloc(128, 64);

    const addr = @intFromPtr(slice.ptr);
    try std.testing.expectEqual(@as(usize, 0), addr % 64);
}

test "arena - stress test" {
    const allocator = std.testing.allocator;

    var arena = try ArenaAllocator.init(allocator, 16384);
    defer arena.deinit();

    // Allocate many small objects
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const slice = try arena.alloc(32, 8);
        try std.testing.expectEqual(@as(usize, 32), slice.len);

        // Write to verify writability
        for (slice) |*byte| {
            byte.* = @as(u8, @truncate(i));
        }
    }

    // Reset and do it again
    arena.reset();

    i = 0;
    while (i < 100) : (i += 1) {
        _ = try arena.alloc(64, 16);
    }
}
