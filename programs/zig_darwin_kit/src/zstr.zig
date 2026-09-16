//! NUL-terminating byte slices for `const char *` parameters.
//!
//! Strings that come back from the kernel (ES `es_string_token_t`, muted-path
//! listings) are length-prefixed and not guaranteed to end in NUL, while the
//! functions that accept paths (`es_mute_path`, `open`, `stat`) require it.
//! `pathZ` does the conversion on the stack for anything up to PATH_MAX;
//! `dupeZ` does it on the heap for arbitrary lengths. Both stop at the first
//! embedded NUL, since that is where C would stop reading anyway.

const std = @import("std");

pub const max_path = std.c.PATH_MAX; // 1024 on Darwin

/// A stack NUL-terminated copy of `bytes`, cut at the first embedded NUL.
/// Pass `&result` where a `[*:0]const u8` is expected.
pub fn pathZ(bytes: []const u8) error{NameTooLong}![max_path - 1:0]u8 {
    const s = std.mem.sliceTo(bytes, 0);
    if (s.len >= max_path) return error.NameTooLong;
    var out: [max_path - 1:0]u8 = undefined;
    @memcpy(out[0..s.len], s);
    out[s.len] = 0;
    return out;
}

/// A heap NUL-terminated copy of `bytes`, cut at the first embedded NUL.
pub fn dupeZ(allocator: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}![:0]u8 {
    return allocator.dupeZ(u8, std.mem.sliceTo(bytes, 0));
}

/// Length of the C string a `[*:0]`-typed pointer holds, without allocating.
pub fn len(ptr: [*:0]const u8) usize {
    return std.mem.len(ptr);
}

// ───────────────────────────── tests ─────────────────────────────

test "pathZ terminates and cuts at embedded NUL" {
    const z = try pathZ("/usr/local");
    try std.testing.expectEqualStrings("/usr/local", std.mem.sliceTo(&z, 0));
    try std.testing.expectEqual(@as(usize, 10), std.mem.len(@as([*:0]const u8, &z)));

    const cut = try pathZ("/a/b\x00/ignored");
    try std.testing.expectEqualStrings("/a/b", std.mem.sliceTo(&cut, 0));
}

test "pathZ rejects PATH_MAX and longer" {
    const long = [_]u8{'x'} ** max_path;
    try std.testing.expectError(error.NameTooLong, pathZ(&long));
    const ok = [_]u8{'x'} ** (max_path - 1);
    _ = try pathZ(&ok);
}

test "dupeZ" {
    const z = try dupeZ(std.testing.allocator, "abc\x00def");
    defer std.testing.allocator.free(z);
    try std.testing.expectEqualStrings("abc", z);
    try std.testing.expectEqual(@as(u8, 0), z[z.len]);
}
