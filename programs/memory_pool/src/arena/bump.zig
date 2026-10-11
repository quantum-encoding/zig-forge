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
        // Alignment must be a non-zero power of two. A zero alignment makes
        // alignForward produce garbage (and, at the FFI boundary, aligned_offset=0
        // aliasing live data); a non-power-of-2 silently mis-aligns.
        if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) {
            return error.InvalidAlignment;
        }

        // Align the ADDRESS that is handed out, not the cursor. The backing
        // buffer is only as aligned as its allocator made it (malloc: 16;
        // a u8 slice from an arbitrary Allocator or an FFI buffer: 1), so
        // aligning `offset` alone yields `buffer.ptr + offset`, which is
        // misaligned whenever `alignment` exceeds the base pointer's alignment.
        //
        // `padding` is computed from the current address and is < alignment,
        // so nothing is formed past the buffer and no address arithmetic can
        // wrap. The bump uses checked addition: with size == SIZE_MAX,
        // aligned_offset + size would wrap below buffer.len and pass the
        // bounds check, yielding a reversed-bounds slice (UB in ReleaseFast).
        // The end-of-buffer check is made against the aligned start.
        const cursor = @intFromPtr(self.buffer.ptr) + self.offset;
        const padding = (alignment - (cursor & (alignment - 1))) & (alignment - 1);
        const aligned_offset = std.math.add(usize, self.offset, padding) catch return error.OutOfMemory;
        const new_offset = std.math.add(usize, aligned_offset, size) catch return error.OutOfMemory;

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

// ============================================================================
// Address-alignment property tests (misaligned backing buffers)
//
// The arena's base pointer is only as aligned as its backing allocator made
// it. These tests hand the arena a backing buffer that starts 1, 3, 7, 9 or 15
// bytes past an 8192-byte boundary (through a FixedBufferAllocator, so the
// real `init` path is used) and check the ADDRESS of every allocation, not the
// offset. Inputs are independent of the allocator under test: the expected
// property is the definition of alignment (`addr % a == 0`) and of a bump
// allocator (in bounds, disjoint, monotone).
// ============================================================================

const misaligned_offsets = [_]usize{ 1, 3, 7, 9, 15 };
const backing_align = 8192;

fn expectInside(arena: *const ArenaAllocator, s: []const u8) !void {
    const base = @intFromPtr(arena.buffer.ptr);
    const start = @intFromPtr(s.ptr);
    try std.testing.expect(start >= base);
    try std.testing.expect(start + s.len <= base + arena.buffer.len);
}

test "arena - address alignment on misaligned backing, every alignment 1..4096" {
    const backing = try std.testing.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(backing_align), 48 * 1024);
    defer std.testing.allocator.free(backing);

    for (misaligned_offsets) |k| {
        var fba = std.heap.FixedBufferAllocator.init(backing[k..]);
        var arena = try ArenaAllocator.init(fba.allocator(), 32 * 1024);
        defer arena.deinit();

        // The test is only meaningful if the base really is misaligned.
        try std.testing.expectEqual(k, @intFromPtr(arena.buffer.ptr) % backing_align);

        var a: usize = 1;
        while (a <= 4096) : (a += 1) {
            arena.reset();
            if (!std.math.isPowerOfTwo(a)) {
                try std.testing.expectError(error.InvalidAlignment, arena.alloc(8, a));
                try std.testing.expectEqual(@as(usize, 0), arena.offset);
                continue;
            }
            const sizes = [_]usize{ 1, 7, a, 3 };
            var prev_end: usize = @intFromPtr(arena.buffer.ptr);
            for (sizes) |size| {
                const s = try arena.alloc(size, a);
                const addr = @intFromPtr(s.ptr);
                try std.testing.expectEqual(@as(usize, 0), addr % a);
                try std.testing.expectEqual(size, s.len);
                try expectInside(&arena, s);
                // Disjoint from (and after) everything handed out before.
                try std.testing.expect(addr >= prev_end);
                // Minimal padding: the arena skips fewer than `a` bytes.
                try std.testing.expect(addr - prev_end < a);
                prev_end = addr + s.len;
                try std.testing.expectEqual(prev_end - @intFromPtr(arena.buffer.ptr), arena.offset);
            }
        }
    }
}

test "arena - last fitting aligned allocation accepted, next refused" {
    const backing = try std.testing.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(backing_align), 4096);
    defer std.testing.allocator.free(backing);

    const n = 256;
    for (misaligned_offsets) |k| {
        var fba = std.heap.FixedBufferAllocator.init(backing[k..]);
        var arena = try ArenaAllocator.init(fba.allocator(), n);
        defer arena.deinit();

        _ = try arena.alloc(1, 1);
        // Padding the arena must insert to reach the next 64-aligned ADDRESS.
        const cursor = @intFromPtr(arena.buffer.ptr) + 1;
        const pad = std.mem.alignForward(usize, cursor, 64) - cursor;
        const fits = n - 1 - pad;

        // One byte too many: refused, and the cursor does not move.
        try std.testing.expectError(error.OutOfMemory, arena.alloc(fits + 1, 64));
        try std.testing.expectEqual(@as(usize, 1), arena.offset);

        // Exactly what fits from the aligned start: accepted, ends at the end.
        const s = try arena.alloc(fits, 64);
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(s.ptr) % 64);
        try std.testing.expectEqual(@intFromPtr(arena.buffer.ptr) + n, @intFromPtr(s.ptr) + s.len);
        try std.testing.expectEqual(@as(usize, n), arena.offset);

        // Full: even one byte at alignment 1 is refused.
        try std.testing.expectError(error.OutOfMemory, arena.alloc(1, 1));
    }
}

test "arena - reset after aligned allocations" {
    const backing = try std.testing.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(backing_align), 16 * 1024);
    defer std.testing.allocator.free(backing);

    for (misaligned_offsets) |k| {
        var fba = std.heap.FixedBufferAllocator.init(backing[k..]);
        var arena = try ArenaAllocator.init(fba.allocator(), 8192);
        defer arena.deinit();

        const first = try arena.alloc(100, 512);
        @memset(first, 0x11);
        const second = try arena.alloc(200, 4096);
        @memset(second, 0x22);
        // No overlap: writing the second left the first intact.
        for (first) |b| try std.testing.expectEqual(@as(u8, 0x11), b);

        arena.reset();
        try std.testing.expectEqual(@as(usize, 0), arena.offset);

        // The same request after reset lands at the same aligned address.
        const again = try arena.alloc(100, 512);
        try std.testing.expectEqual(@intFromPtr(first.ptr), @intFromPtr(again.ptr));

        // After reset the whole buffer minus the alignment padding is usable.
        arena.reset();
        const base = @intFromPtr(arena.buffer.ptr);
        const pad = std.mem.alignForward(usize, base, 4096) - base;
        const whole = try arena.alloc(arena.buffer.len - pad, 4096);
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(whole.ptr) % 4096);
        try expectInside(&arena, whole);
        try std.testing.expectError(error.OutOfMemory, arena.alloc(1, 1));
    }
}
