//! Portable `stat`/`lstat` wrapper.
//!
//! zdedupe previously carried four hand-rolled `extern struct Stat` definitions
//! plus unsuffixed `extern "c" fn lstat/stat` declarations. On x86_64 macOS the
//! unsuffixed `lstat`/`stat` symbols are the *legacy 32-bit-inode* variants with
//! a different struct layout than the one those definitions described (the
//! 64-bit ones are `lstat$INODE64` / `stat$INODE64`), so every stat field read
//! on an Intel Mac was garbage. `std.c.stat` / `std.c.fstatat` select the
//! `$INODE64` symbols per-arch, so routing through them removes the whole class.
//!
//! On Linux `std.c.Stat` is `void` (Zig 0.16 dropped the struct-stat ABI in
//! favour of `statx`), so the Linux backend here is `statx` — which is also
//! architecture-independent, unlike the hand-rolled struct it replaces (that
//! layout was x86_64-only and would have mis-parsed on aarch64 Linux).

const std = @import("std");
const builtin = @import("builtin");

const is_linux = builtin.os.tag == .linux;

pub const Error = error{StatFailed};

/// Normalized subset of `struct stat` — the only fields zdedupe consumes.
pub const Stat = struct {
    /// Device id. On Linux this is `(major << 32) | minor`, packed losslessly so
    /// two files on different devices can never collide into one `FileId`.
    dev: u64,
    ino: u64,
    mode: u32,
    size: u64,
    mtime_sec: i64,

    pub const IFMT: u32 = 0o170000;
    pub const IFREG: u32 = 0o100000;
    pub const IFDIR: u32 = 0o040000;
    pub const IFLNK: u32 = 0o120000;

    pub fn isFile(self: Stat) bool {
        return self.mode & IFMT == IFREG;
    }

    pub fn isDir(self: Stat) bool {
        return self.mode & IFMT == IFDIR;
    }

    pub fn isLink(self: Stat) bool {
        return self.mode & IFMT == IFLNK;
    }
};

// ---------------------------------------------------------------------------
// Linux backend: statx
// ---------------------------------------------------------------------------

const Statx = extern struct {
    stx_mask: u32,
    stx_blksize: u32,
    stx_attributes: u64,
    stx_nlink: u32,
    stx_uid: u32,
    stx_gid: u32,
    stx_mode: u16,
    __spare0: u16,
    stx_ino: u64,
    stx_size: u64,
    stx_blocks: u64,
    stx_attributes_mask: u64,
    stx_atime: StatxTimestamp,
    stx_btime: StatxTimestamp,
    stx_ctime: StatxTimestamp,
    stx_mtime: StatxTimestamp,
    stx_rdev_major: u32,
    stx_rdev_minor: u32,
    stx_dev_major: u32,
    stx_dev_minor: u32,
    stx_mnt_id: u64,
    stx_dio_mem_align: u32,
    stx_dio_offset_align: u32,
    __spare3: [12]u64,
};

const StatxTimestamp = extern struct { sec: i64, nsec: u32, __pad: i32 };

/// statx mask flags — request only the fields we read.
const STATX_TYPE: u32 = 0x001;
const STATX_MODE: u32 = 0x002;
const STATX_MTIME: u32 = 0x040;
const STATX_INO: u32 = 0x100;
const STATX_SIZE: u32 = 0x200;
const STATX_NEEDED: u32 = STATX_TYPE | STATX_MODE | STATX_MTIME | STATX_INO | STATX_SIZE;

const AT_FDCWD: c_int = -100;
const AT_SYMLINK_NOFOLLOW: c_int = 0x100;
/// statx on the dirfd itself when path is "".
const AT_EMPTY_PATH: c_int = 0x1000;
/// Don't force a writeback sync — faster for read-only queries.
const AT_STATX_DONT_SYNC: c_int = 0x4000;

extern "c" fn statx(dirfd: c_int, path: [*:0]const u8, flags: c_int, mask: u32, buf: *Statx) c_int;

fn statxTo(stx: *const Statx) Stat {
    return .{
        .dev = (@as(u64, stx.stx_dev_major) << 32) | @as(u64, stx.stx_dev_minor),
        .ino = stx.stx_ino,
        .mode = stx.stx_mode,
        .size = stx.stx_size,
        .mtime_sec = stx.stx_mtime.sec,
    };
}

fn statxCall(path: [*:0]const u8, flags: c_int) Error!Stat {
    var stx: Statx = undefined;
    if (statx(AT_FDCWD, path, flags | AT_STATX_DONT_SYNC, STATX_NEEDED, &stx) != 0) {
        return error.StatFailed;
    }
    return statxTo(&stx);
}

// ---------------------------------------------------------------------------
// libc backend (Darwin / BSD): std.c, which maps the $INODE64 symbols
// ---------------------------------------------------------------------------

fn cStatTo(st: *const std.c.Stat) Stat {
    return .{
        // dev_t is signed on Darwin/BSD; reinterpret rather than @intCast so a
        // negative device id widens instead of panicking. The value is only
        // ever used as an identity key, never as a number.
        .dev = @bitCast(@as(i64, st.dev)),
        .ino = @intCast(st.ino),
        .mode = st.mode,
        // off_t is signed. A negative size is nonsense; clamp to 0 rather than
        // panic, and let the size filter drop it.
        .size = if (st.size > 0) @intCast(st.size) else 0,
        .mtime_sec = st.mtime().sec,
    };
}

/// `stat()` semantics: follow symlinks, report the target.
///
/// Routed through `fstatat` rather than `std.c.stat` because Zig 0.16 only
/// declares the `stat$INODE64` private symbol for x86_64 Darwin — `std.c.stat`
/// does not compile on arm64 macOS. `fstatat` is declared for both.
pub fn stat(path: [*:0]const u8) Error!Stat {
    if (is_linux) return statxCall(path, 0);
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, path, &st, 0) != 0) return error.StatFailed;
    return cStatTo(&st);
}

/// `fstat()` semantics: stat an already-open descriptor. Used to verify the
/// file a hasher actually opened is a regular file — the walk-time type check
/// cannot guarantee that, since the path can be replaced (e.g. by a FIFO)
/// between walk and hash.
pub fn fstat(fd: c_int) Error!Stat {
    if (is_linux) {
        var stx: Statx = undefined;
        if (statx(fd, "", AT_EMPTY_PATH | AT_STATX_DONT_SYNC, STATX_NEEDED, &stx) != 0) {
            return error.StatFailed;
        }
        return statxTo(&stx);
    }
    var st: std.c.Stat = undefined;
    if (std.c.fstat(fd, &st) != 0) return error.StatFailed;
    return cStatTo(&st);
}

/// `lstat()` semantics: do not follow symlinks, report the link itself.
pub fn lstat(path: [*:0]const u8) Error!Stat {
    if (is_linux) return statxCall(path, AT_SYMLINK_NOFOLLOW);
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, path, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) {
        return error.StatFailed;
    }
    return cStatTo(&st);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Scratch = @import("testing_scratch.zig").Scratch;

test "stat of a known file reports the byte count written" {
    const testing = std.testing;
    var scratch = try Scratch.init(testing.allocator, "pstat-size");
    defer scratch.deinit();

    const payload = "abcdefghij"; // 10 bytes
    try scratch.writeFile("sized.bin", payload);

    const full = try scratch.joinZ("sized.bin");
    defer testing.allocator.free(full);

    const st = try stat(full.ptr);
    try testing.expectEqual(@as(u64, payload.len), st.size);
    try testing.expect(st.isFile());
    try testing.expect(!st.isDir());
    try testing.expect(st.ino != 0);
}

test "lstat reports the link, stat reports the target" {
    const testing = std.testing;
    var scratch = try Scratch.init(testing.allocator, "pstat-link");
    defer scratch.deinit();

    try scratch.writeFile("target.bin", "0123456789abcdef");
    try scratch.symLink("target.bin", "link.bin");

    const link_path = try scratch.joinZ("link.bin");
    defer testing.allocator.free(link_path);

    const via_lstat = try lstat(link_path.ptr);
    try testing.expect(via_lstat.isLink());

    const via_stat = try stat(link_path.ptr);
    try testing.expect(via_stat.isFile());
    try testing.expectEqual(@as(u64, 16), via_stat.size);
}

test "stat of a missing path fails rather than returning garbage" {
    try std.testing.expectError(error.StatFailed, stat("/nonexistent/zdedupe/path"));
    try std.testing.expectError(error.StatFailed, lstat("/nonexistent/zdedupe/path"));
}
