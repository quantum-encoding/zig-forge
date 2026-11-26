//! Removing a folder and everything in it, for a permanent delete.
//!
//! Recursion is by folder descriptor (`openat` with NOFOLLOW, then
//! `fdopendir`), never by resolving a path again: a link swapped in while the
//! delete runs cannot redirect it. Entries are removed with `unlinkat`, so a
//! link beneath is removed itself, not followed. A folder on another device (a
//! volume mounted inside) is not entered: the delete stops there and says so.

const std = @import("std");
const libc = @import("sys.zig").c;
const pstat = @import("pstat.zig");

/// Remove the folder at `path` and everything beneath it. Null on success,
/// or the errno that stopped it.
pub fn tree(path: [*:0]const u8) ?libc.E {
    const fd = libc.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true }, @as(libc.mode_t, 0));
    if (fd < 0) return libc.errno(@as(c_int, -1));
    const top = pstat.fstat(fd) catch {
        _ = libc.close(fd);
        return .IO;
    };
    // A pass can miss an entry renamed into the folder while it ran, and
    // reading a folder while removing from it is allowed to skip names; the
    // folder is then not empty, and another pass takes what is left.
    var passes: u8 = 0;
    while (true) : (passes += 1) {
        if (children(fd, top.dev)) |errno| {
            _ = libc.close(fd);
            return errno;
        }
        if (libc.rmdir(path) == 0) break;
        const errno = libc.errno(@as(c_int, -1));
        if (errno != .NOTEMPTY or passes == 2) {
            _ = libc.close(fd);
            return errno;
        }
    }
    _ = libc.close(fd);
    return null;
}

/// Empty the folder `dir_fd` refers to, staying on device `dev`. The caller
/// still closes `dir_fd`.
fn children(dir_fd: c_int, dev: u64) ?libc.E {
    // fdopendir takes ownership of the fd it is given, so it gets a copy.
    const dup_fd = libc.dup(dir_fd);
    if (dup_fd < 0) return libc.errno(@as(c_int, -1));
    const dir = libc.fdopendir(dup_fd) orelse {
        _ = libc.close(dup_fd);
        return libc.errno(@as(c_int, -1));
    };
    defer _ = libc.closedir(dir);

    while (libc.readdir(dir)) |entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.span(name_ptr);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        const st = pstat.lstatAt(dir_fd, name_ptr) catch return libc.errno(@as(c_int, -1));
        if (st.isDir()) {
            if (st.dev != dev) return .XDEV;
            const child = libc.openat(dir_fd, name_ptr, .{
                .ACCMODE = .RDONLY,
                .DIRECTORY = true,
                .NOFOLLOW = true,
            }, @as(libc.mode_t, 0));
            if (child < 0) return libc.errno(@as(c_int, -1));
            if (children(child, dev)) |errno| {
                _ = libc.close(child);
                return errno;
            }
            _ = libc.close(child);
            if (libc.unlinkat(dir_fd, name_ptr, @intCast(libc.AT.REMOVEDIR)) != 0) {
                return libc.errno(@as(c_int, -1));
            }
        } else if (libc.unlinkat(dir_fd, name_ptr, 0) != 0) {
            return libc.errno(@as(c_int, -1));
        }
    }
    return null;
}

/// Why a delete stopped, as a phrase about the item: "permission denied".
pub fn reason(err: libc.E) []const u8 {
    return switch (err) {
        .NOENT => "no longer exists",
        .ACCES, .PERM => "permission denied",
        .ISDIR => "is a directory",
        .ROFS => "is on a read-only filesystem",
        .BUSY => "is in use",
        .IO => "an I/O error occurred",
        .XDEV => "holds another volume, which is not deleted",
        .NOTEMPTY => "could not be emptied",
        else => "could not be deleted",
    };
}

const testing = std.testing;
const Scratch = @import("testing_scratch.zig").Scratch;

test "a folder is removed with everything in it, and a link inside is removed, not followed" {
    var scratch = try Scratch.init(testing.allocator, "remove-tree");
    defer scratch.deinit();
    for ([_][]const u8{ "keep", "gone", "gone/a", "gone/a/b" }) |d| try scratch.makeDir(d);
    try scratch.writeFile("keep/precious.txt", "not part of the delete");
    try scratch.writeFile("gone/a/b/deep.bin", "x");
    try scratch.writeFile("gone/top.txt", "y");
    scratch.symLink("../keep", "gone/a/to-keep") catch return error.SkipZigTest;
    const gone = try scratch.joinZ("gone");
    defer testing.allocator.free(gone);

    try testing.expectEqual(@as(?libc.E, null), tree(gone.ptr));
    try testing.expect(!try scratch.exists("gone"));
    try testing.expect(try scratch.exists("keep/precious.txt"));
    // A folder that is not there says so.
    try testing.expectEqual(@as(?libc.E, .NOENT), tree(gone.ptr));
    try testing.expectEqualStrings("no longer exists", reason(.NOENT));
}
