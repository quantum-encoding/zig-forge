//! Portable path stat helper for zdu.
//!
//! The original implementation hard-coded the Linux `statx` syscall
//! (std.os.linux.statx). That compiles on any target but on macOS/BSD the raw
//! statx syscall number is invalid, so every stat either errored
//! ("cannot access: Unexpected") or trapped with SIGSYS. This module uses the
//! libc `fstatat` wrapper (std.c.fstatat), which is available on every libc
//! target Zig supports (Linux, macOS, the BSDs, illumos), so `zdu` now works on
//! the native host it is actually built for.

const std = @import("std");

pub const StatInfo = struct {
    dev: u64,
    ino: u64,
    size: u64,
    blocks: u64,
    nlink: u64,
    is_dir: bool,
};

/// Widen any integer field of a platform `Stat` struct to u64. Fields differ in
/// width and signedness across targets (e.g. darwin `dev` is i32, `blocks` is
/// i64; linux `dev` is u64). Signed values are reinterpreted through the
/// same-width unsigned type so a device number that happens to have its high
/// bit set is preserved rather than triggering an @intCast panic.
inline fn toU64(v: anytype) u64 {
    const T = @TypeOf(v);
    return switch (@typeInfo(T)) {
        .int => |info| if (info.signedness == .signed)
            @as(u64, @as(std.meta.Int(.unsigned, info.bits), @bitCast(v)))
        else
            @as(u64, @intCast(v)),
        else => @intCast(v),
    };
}

/// Stat a path via the portable libc `fstatat` wrapper.
///
/// When `follow_symlinks` is false, uses AT_SYMLINK_NOFOLLOW (lstat semantics),
/// matching GNU du's default of measuring the link itself, not its target.
pub fn statPath(path: []const u8, follow_symlinks: bool) !StatInfo {
    var flags: u32 = 0;
    if (!follow_symlinks) {
        flags |= std.c.AT.SYMLINK_NOFOLLOW;
    }

    // Convert path to null-terminated
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);

    var stat_buf: std.c.Stat = undefined;
    const rc = std.c.fstatat(std.c.AT.FDCWD, path_z, &stat_buf, flags);
    if (rc != 0) {
        return switch (std.c.errno(rc)) {
            .ACCES => error.AccessDenied,
            .NOENT => error.FileNotFound,
            .NOTDIR => error.FileNotFound,
            .LOOP => error.SymLinkLoop,
            .NAMETOOLONG => error.NameTooLong,
            else => error.Unexpected,
        };
    }

    return StatInfo{
        .dev = toU64(stat_buf.dev),
        .ino = toU64(stat_buf.ino),
        .size = toU64(stat_buf.size),
        .blocks = toU64(stat_buf.blocks),
        .nlink = toU64(stat_buf.nlink),
        .is_dir = (stat_buf.mode & std.c.S.IFMT) == std.c.S.IFDIR,
    };
}
