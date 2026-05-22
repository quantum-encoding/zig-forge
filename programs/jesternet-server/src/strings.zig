// FixedString — shared fixed-size string type.
//
// Used by both auth/pipeline.zig (TokenRow, AuthContext) and
// store/types.zig (ApiTokenRow, EventRow, etc.). Lives here so
// neither module depends on the other; the pipeline's TokenStore
// interface stays clean (no store types leaking in) and store rows
// can be passed across module boundaries by value without lifetime
// hazards.
//
// Bounded inline buffer + length tag. Copying is a memcpy, slicing
// is a pointer + length — stable for the life of the containing
// struct.

const std = @import("std");

pub fn FixedString(comptime max_len: usize) type {
    return struct {
        buf: [max_len]u8 = .{0} ** max_len,
        len: u16 = 0,

        const Self = @This();

        pub fn fromSlice(s: []const u8) Self {
            var result = Self{};
            const copy_len = @min(s.len, max_len);
            @memcpy(result.buf[0..copy_len], s[0..copy_len]);
            result.len = @intCast(copy_len);
            return result;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn eql(self: *const Self, other: []const u8) bool {
            return std.mem.eql(u8, self.slice(), other);
        }
    };
}

pub const FixedStr16 = FixedString(16);
pub const FixedStr32 = FixedString(32);
pub const FixedStr64 = FixedString(64);
pub const FixedStr128 = FixedString(128);
pub const FixedStr256 = FixedString(256);
pub const FixedStr512 = FixedString(512);

test "fromSlice + slice round-trip" {
    const s = FixedStr64.fromSlice("hello");
    try std.testing.expectEqualStrings("hello", s.slice());
}

test "truncation on too-long input" {
    const too_long = "x" ** 100;
    const s = FixedStr64.fromSlice(too_long);
    try std.testing.expectEqual(@as(usize, 64), s.slice().len);
}

test "eql comparison" {
    const s = FixedStr64.fromSlice("foo");
    try std.testing.expect(s.eql("foo"));
    try std.testing.expect(!s.eql("bar"));
}
