//! Ownership of memory that libc `malloc`ed and the caller must `free`.
//!
//! Apple's C APIs often return arrays through out-parameters the caller owns
//! (`es_subscriptions`, `es_muted_processes`, `proc_listpids` and friends).
//! Two shapes cover every case met so far:
//!   * `Slice(T)` borrows the C buffer and frees it on `deinit` (zero-copy);
//!   * `take` copies into a Zig allocator and frees the C buffer immediately,
//!     for data that must outlive the call site with ordinary ownership.

const std = @import("std");

/// A `malloc`ed array of `T` with `count` elements, freed by `deinit`.
pub fn Slice(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []T,
        base: ?*anyopaque,

        /// Wrap what a C out-parameter pair `(ptr, count)` returned. A null
        /// pointer or zero count yields an empty slice that frees nothing
        /// but a non-null pointer, matching what libc `free(NULL)` allows.
        pub fn fromRaw(ptr: ?[*]T, count: usize) Self {
            if (ptr) |p| {
                return .{ .items = p[0..count], .base = @ptrCast(p) };
            }
            return .{ .items = &.{}, .base = null };
        }

        pub fn deinit(self: *Self) void {
            if (self.base) |b| std.c.free(b);
            self.* = .{ .items = &.{}, .base = null };
        }
    };
}

/// Copy a `malloc`ed array into `allocator` memory and free the original.
/// The C buffer is freed even when the copy fails.
pub fn take(comptime T: type, allocator: std.mem.Allocator, ptr: ?[*]T, count: usize) error{OutOfMemory}![]T {
    var borrowed = Slice(T).fromRaw(ptr, count);
    defer borrowed.deinit();
    return allocator.dupe(T, borrowed.items);
}

/// A `malloc`ed NUL-terminated string (from `strdup`, `realpath(NULL)`, ...).
pub const CString = struct {
    ptr: ?[*:0]u8,

    pub fn slice(self: CString) [:0]const u8 {
        return if (self.ptr) |p| std.mem.span(p) else "";
    }

    pub fn deinit(self: *CString) void {
        if (self.ptr) |p| std.c.free(p);
        self.ptr = null;
    }
};

/// Copy a `malloc`ed C string into `allocator` memory and free the original.
pub fn takeString(allocator: std.mem.Allocator, ptr: ?[*:0]u8) error{OutOfMemory}![:0]u8 {
    var s = CString{ .ptr = ptr };
    defer s.deinit();
    return allocator.dupeZ(u8, s.slice());
}

// ───────────────────────────── tests ─────────────────────────────

extern "c" fn strdup(s: [*:0]const u8) ?[*:0]u8;

test "Slice borrows and frees a malloc'd array" {
    const raw: [*]u32 = @ptrCast(@alignCast(std.c.malloc(4 * @sizeOf(u32)) orelse return error.OutOfMemory));
    for (0..4) |i| raw[i] = @intCast(i * 10);
    var s = Slice(u32).fromRaw(raw, 4);
    try std.testing.expectEqualSlices(u32, &.{ 0, 10, 20, 30 }, s.items);
    s.deinit();
    try std.testing.expectEqual(@as(usize, 0), s.items.len);
    s.deinit(); // idempotent
}

test "Slice from a null pointer is empty" {
    var s = Slice(u8).fromRaw(null, 0);
    try std.testing.expectEqual(@as(usize, 0), s.items.len);
    s.deinit();
}

test "take copies into the allocator" {
    const raw: [*]u16 = @ptrCast(@alignCast(std.c.malloc(3 * @sizeOf(u16)) orelse return error.OutOfMemory));
    raw[0] = 1;
    raw[1] = 2;
    raw[2] = 3;
    const owned = try take(u16, std.testing.allocator, raw, 3);
    defer std.testing.allocator.free(owned);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 3 }, owned);
}

test "CString and takeString" {
    var s = CString{ .ptr = strdup("hello") };
    try std.testing.expectEqualStrings("hello", s.slice());
    s.deinit();
    try std.testing.expectEqualStrings("", s.slice());

    const owned = try takeString(std.testing.allocator, strdup("world"));
    defer std.testing.allocator.free(owned);
    try std.testing.expectEqualStrings("world", owned);
}
