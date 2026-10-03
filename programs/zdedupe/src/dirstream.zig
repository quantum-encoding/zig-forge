//! One directory's entries, with the stat facts a walk needs wherever the
//! platform hands them over with the listing.
//!
//! macOS reads a directory with `getattrlistbulk`, which returns each entry's
//! type, size, inode, link count, mtime, allocation and flags in the same call
//! that lists it. `readdir` + `fstatat` costs a syscall per file instead, and
//! each of those stats makes the kernel instantiate a vnode for the file: the
//! vnode cache holds a few hundred thousand, so on a tree of millions every
//! stat also recycles one. The bulk call reads the attributes from the
//! directory without creating per-file vnodes.
//!
//! Elsewhere the stream is `readdir`, and an entry's stat is left for the
//! caller to fetch (Linux `statx` relative to the directory is cheap).
//!
//! An entry the bulk call could not describe comes back with `kind ==
//! DT_UNKNOWN` and no stat, so the caller's own stat decides it, exactly as
//! for a filesystem whose `readdir` reports no type.

const std = @import("std");
const builtin = @import("builtin");
const pstat = @import("pstat.zig");
const Stat = pstat.Stat;
const libc = std.c;

const is_darwin = builtin.os.tag.isDarwin();

// d_type constants from dirent.h
pub const DT_UNKNOWN: u8 = 0;
pub const DT_DIR: u8 = 4;
pub const DT_REG: u8 = 8;
pub const DT_LNK: u8 = 10;
/// Anything else (socket, FIFO, device), once classified.
pub const DT_OTHER: u8 = 255;

pub const Entry = struct {
    /// Valid until the next call to `next`.
    name: [*:0]const u8,
    kind: u8,
    /// Present when the listing already carried it (regular files on macOS).
    stat: ?Stat = null,
};

pub const DirStream = if (is_darwin) BulkDirStream else ReaddirStream;

/// POSIX `dirfd`: the descriptor behind an open `DIR*` (not in Zig 0.16's std.c).
extern "c" fn dirfd(dir: *libc.DIR) c_int;

pub const ReaddirStream = struct {
    dir: *libc.DIR,

    pub fn open(path: [*:0]const u8) ?ReaddirStream {
        const dir = libc.opendir(path) orelse return null;
        return .{ .dir = dir };
    }

    pub fn close(self: *ReaddirStream) void {
        _ = libc.closedir(self.dir);
    }

    pub fn fd(self: *const ReaddirStream) c_int {
        return dirfd(self.dir);
    }

    /// The next entry other than `.` and `..`; null at the end. Never fails:
    /// readdir reports a read error as the end of the directory.
    pub fn next(self: *ReaddirStream) error{}!?Entry {
        while (libc.readdir(self.dir)) |entry| {
            const name: [*:0]const u8 = @ptrCast(&entry.name);
            if (isDotOrDotDot(name)) continue;
            return .{ .name = name, .kind = entry.type };
        }
        return null;
    }
};

fn isDotOrDotDot(name: [*:0]const u8) bool {
    return name[0] == '.' and (name[1] == 0 or (name[1] == '.' and name[2] == 0));
}

// sys/attr.h
const AttrList = extern struct {
    bitmapcount: u16 = ATTR_BIT_MAP_COUNT,
    reserved: u16 = 0,
    commonattr: u32 = 0,
    volattr: u32 = 0,
    dirattr: u32 = 0,
    fileattr: u32 = 0,
    forkattr: u32 = 0,
};
const ATTR_BIT_MAP_COUNT: u16 = 5;
const ATTR_CMN_NAME: u32 = 0x00000001;
const ATTR_CMN_DEVID: u32 = 0x00000002;
const ATTR_CMN_OBJTYPE: u32 = 0x00000008;
const ATTR_CMN_MODTIME: u32 = 0x00000400;
const ATTR_CMN_FLAGS: u32 = 0x00040000;
const ATTR_CMN_FILEID: u32 = 0x02000000;
const ATTR_CMN_ERROR: u32 = 0x20000000;
const ATTR_CMN_RETURNED_ATTRS: u32 = 0x80000000;
const ATTR_FILE_LINKCOUNT: u32 = 0x00000001;
const ATTR_FILE_ALLOCSIZE: u32 = 0x00000004;
const ATTR_FILE_DATALENGTH: u32 = 0x00000200;

// sys/vnode.h `enum vtype`
const VREG: u32 = 1;
const VDIR: u32 = 2;
const VLNK: u32 = 5;

const SF_DATALESS: u32 = 0x40000000;

extern "c" fn getattrlistbulk(dirfd: c_int, attr_list: *const AttrList, attr_buf: *anyopaque, attr_buf_size: usize, options: u64) c_int;

const bulk_attrs: AttrList = .{
    .commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_DEVID |
        ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FLAGS | ATTR_CMN_FILEID,
    .fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH,
};

/// sys/mount.h `struct statfs` (the 64-bit-inode layout).
const Statfs = extern struct {
    f_bsize: u32,
    f_iosize: i32,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_owner: u32,
    f_type: u32,
    f_flags: u32,
    f_fssubtype: u32,
    f_fstypename: [16]u8,
    f_mntonname: [1024]u8,
    f_mntfromname: [1024]u8,
    f_flags_ext: u32,
    f_reserved: [7]u32,
};
const fstatfs = @extern(*const fn (fd: c_int, buf: *Statfs) callconv(.c) c_int, .{
    .name = if (builtin.cpu.arch == .x86_64) "fstatfs$INODE64" else "fstatfs",
});

/// The bulk call is used on the filesystems that implement it natively.
/// Others get it through a kernel emulation that some refuse partway
/// through a listing (FSKit's devicefs, mounted for a connected iPhone,
/// answers EINVAL), and a listing cut short cannot be resumed: they are
/// read with readdir.
fn bulkNative(dir_fd: c_int) bool {
    var sfs: Statfs = undefined;
    if (fstatfs(dir_fd, &sfs) != 0) return false;
    const name = std.mem.sliceTo(&sfs.f_fstypename, 0);
    return std.mem.eql(u8, name, "apfs") or std.mem.eql(u8, name, "hfs");
}

pub const BulkDirStream = struct {
    dir_fd: c_int,
    /// Set when the directory is listed with readdir instead (see
    /// `bulkNative`), or when the bulk call is refused before it returned
    /// anything.
    fallback: ?ReaddirStream = null,
    /// Whether the bulk call has returned entries; a failure after that is
    /// a failed read, not an unsupported filesystem.
    listed: bool = false,
    /// Entries left in `buf` from the last call, and where the next starts.
    remaining: usize = 0,
    cursor: usize = 0,
    buf: [32 * 1024]u8 align(8) = undefined,

    pub fn open(path: [*:0]const u8) ?BulkDirStream {
        const dir_fd = libc.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, @as(libc.mode_t, 0));
        if (dir_fd < 0) return null;
        var stream: BulkDirStream = .{ .dir_fd = dir_fd };
        if (!bulkNative(dir_fd) and !stream.fallBack()) {
            _ = libc.close(dir_fd);
            return null;
        }
        return stream;
    }

    /// Switch to readdir on the same directory.
    fn fallBack(self: *BulkDirStream) bool {
        // fdopendir owns the descriptor it is given: a copy.
        const copy = libc.dup(self.dir_fd);
        if (copy < 0) return false;
        const dir = libc.fdopendir(copy) orelse {
            _ = libc.close(copy);
            return false;
        };
        self.fallback = .{ .dir = dir };
        return true;
    }

    pub fn close(self: *BulkDirStream) void {
        if (self.fallback) |*f| f.close();
        _ = libc.close(self.dir_fd);
    }

    pub fn fd(self: *const BulkDirStream) c_int {
        return self.dir_fd;
    }

    /// The next entry; null at the end. A failed read of the directory is
    /// an error, so the caller can mark the directory incomplete instead of
    /// taking a partial listing for the whole.
    pub fn next(self: *BulkDirStream) error{ReadDirFailed}!?Entry {
        if (self.fallback) |*f| return f.next() catch unreachable;
        if (self.remaining == 0) {
            while (true) {
                const n = getattrlistbulk(self.dir_fd, &bulk_attrs, &self.buf, self.buf.len, 0);
                if (n > 0) {
                    self.remaining = @intCast(n);
                    self.cursor = 0;
                    self.listed = true;
                    break;
                }
                if (n == 0) return null;
                switch (libc.errno(n)) {
                    .INTR => continue,
                    .INVAL, .OPNOTSUPP => if (!self.listed) {
                        if (!self.fallBack()) return error.ReadDirFailed;
                        return self.fallback.?.next() catch unreachable;
                    },
                    else => {},
                }
                return error.ReadDirFailed;
            }
        }
        self.remaining -= 1;
        return self.parse();
    }

    fn parse(self: *BulkDirStream) Entry {
        const start = self.cursor;
        var r: Reader = .{ .bytes = &self.buf, .pos = start };
        const length = r.int(u32);
        self.cursor = start + length;

        const common = r.int(u32);
        _ = r.int(u32); // volattr
        _ = r.int(u32); // dirattr
        const file = r.int(u32);
        _ = r.int(u32); // forkattr

        var err: u32 = 0;
        if (common & ATTR_CMN_ERROR != 0) err = r.int(u32);

        // The name is always returned (it is how the entry is identified),
        // as an offset relative to the attrreference itself.
        const name_ref = r.pos;
        const name_offset = r.int(i32);
        _ = r.int(u32); // length, including the NUL
        const name: [*:0]const u8 = @ptrCast(&self.buf[@intCast(@as(isize, @intCast(name_ref)) + name_offset)]);

        if (err != 0) return .{ .name = name, .kind = DT_UNKNOWN };

        var st: Stat = .{ .dev = 0, .ino = 0, .mode = 0, .size = 0, .mtime_sec = 0 };
        var obj_type: u32 = 0;
        if (common & ATTR_CMN_DEVID != 0) st.dev = @bitCast(@as(i64, r.int(i32)));
        if (common & ATTR_CMN_OBJTYPE != 0) obj_type = r.int(u32) else return .{ .name = name, .kind = DT_UNKNOWN };
        if (common & ATTR_CMN_MODTIME != 0) {
            st.mtime_sec = r.int(i64);
            _ = r.int(i64); // nsec
        }
        if (common & ATTR_CMN_FLAGS != 0) st.dataless = r.int(u32) & SF_DATALESS != 0;
        const have_ino = common & ATTR_CMN_FILEID != 0;
        if (have_ino) st.ino = r.int(u64);

        switch (obj_type) {
            VDIR => return .{ .name = name, .kind = DT_DIR },
            VLNK => return .{ .name = name, .kind = DT_LNK },
            VREG => {},
            else => return .{ .name = name, .kind = DT_OTHER },
        }

        // A file whose identity or size did not come back is left to stat.
        const need = ATTR_FILE_LINKCOUNT | ATTR_FILE_DATALENGTH;
        if (!have_ino or common & ATTR_CMN_DEVID == 0 or file & need != need) {
            return .{ .name = name, .kind = DT_UNKNOWN };
        }
        st.mode = Stat.IFREG;
        st.nlink = r.int(u32);
        // Every fork, as st_blocks counts them (a resource fork included).
        if (file & ATTR_FILE_ALLOCSIZE != 0) {
            const alloc = r.int(i64);
            st.allocated = if (alloc > 0) @intCast(alloc) else 0;
        }
        const size = r.int(i64);
        st.size = if (size > 0) @intCast(size) else 0;
        return .{ .name = name, .kind = DT_REG, .stat = st };
    }
};

/// Reads the packed attribute buffer. Attributes are 4-byte aligned, 64-bit
/// ones included, so every read is unaligned-safe.
const Reader = struct {
    bytes: []const u8,
    pos: usize,

    fn int(self: *Reader, comptime T: type) T {
        const size = @sizeOf(T);
        const value = std.mem.readInt(T, self.bytes[self.pos..][0..size], .little);
        self.pos += size;
        return value;
    }
};

/// Every entry of `dir_path` as the stream gives it, checked against lstat:
/// the kind must agree, and a stat the listing carried must equal lstat's in
/// every field the walk uses. Recurses into subdirectories when `recurse`.
/// Returns the number of regular files whose stat came from the listing.
fn expectListingMatchesLstat(dir_path: [:0]const u8, recurse: bool) !u64 {
    const allocator = std.testing.allocator;
    var stream = DirStream.open(dir_path) orelse return 0; // unreadable: nothing to compare
    defer stream.close();
    var from_listing: u64 = 0;
    while (stream.next() catch |err| {
        // Reported, not fatal: the walk marks such a directory incomplete.
        std.debug.print("{s}: listing failed: {s}\n", .{ dir_path, @errorName(err) });
        return from_listing;
    }) |entry| {
        const st = pstat.lstatAt(stream.fd(), entry.name) catch continue; // gone meanwhile
        const want: u8 = if (st.isFile()) DT_REG else if (st.isDir()) DT_DIR else if (st.isLink()) DT_LNK else DT_OTHER;
        if (entry.kind != DT_UNKNOWN) {
            // readdir reports a FIFO as DT_FIFO, not DT_OTHER; only the bulk
            // stream folds the special files together.
            if (!(entry.kind != DT_REG and entry.kind != DT_DIR and entry.kind != DT_LNK and want == DT_OTHER)) {
                std.testing.expectEqual(want, entry.kind) catch |err| {
                    std.debug.print("kind mismatch: {s}/{s}\n", .{ dir_path, entry.name });
                    return err;
                };
            }
        }
        if (entry.stat) |got| {
            from_listing += 1;
            inline for (.{ "dev", "ino", "mode", "size", "mtime_sec", "nlink", "allocated", "dataless" }) |field| {
                const lhs = @field(st, field);
                const rhs = @field(got, field);
                // Only the type bits of `mode` come from the listing.
                const equal = if (comptime std.mem.eql(u8, field, "mode")) lhs & Stat.IFMT == rhs else lhs == rhs;
                if (!equal) {
                    std.debug.print("{s} mismatch: {s}/{s}: lstat {any} listing {any}\n", .{ field, dir_path, entry.name, lhs, rhs });
                    return error.TestExpectedEqual;
                }
            }
        }
        if (recurse and entry.kind == DT_DIR) {
            const child = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir_path, entry.name }, 0);
            defer allocator.free(child);
            from_listing += try expectListingMatchesLstat(child, true);
        }
    }
    return from_listing;
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: libc.mode_t) c_int;

test "a directory listing's stats agree with lstat, across several bulk reads" {
    const Scratch = @import("testing_scratch.zig").Scratch;
    const allocator = std.testing.allocator;
    var scratch = try Scratch.init(allocator, "dirstream");
    defer scratch.deinit();

    try scratch.writeFile("empty", "");
    try scratch.writeFile("small", "payload");
    try scratch.writeFile(".hidden", "hidden");
    const big = try allocator.alloc(u8, 3 * 1024 * 1024 + 17);
    defer allocator.free(big);
    @memset(big, 0xA5);
    try scratch.writeFile("big", big);
    try scratch.hardLink("small", "small-link");
    try scratch.symLink("small", "to-small");
    try scratch.makeDir("sub");
    try scratch.symLink("sub", "to-sub");
    const fifo = try scratch.joinZ("fifo");
    defer allocator.free(fifo);
    try std.testing.expectEqual(@as(c_int, 0), mkfifo(fifo, 0o600));
    // Long names, so the listing takes more than one 32 KB read.
    var name_buf: [300]u8 = undefined;
    for (0..400) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "sub/{s}-{d}", .{ "n" ** 200, i });
        try scratch.writeFile(name, name);
    }

    const from_listing = try expectListingMatchesLstat(scratch.path, true);
    if (is_darwin) try std.testing.expectEqual(@as(u64, 4 + 1 + 400), from_listing);

    // Every entry is listed once, `.` and `..` never.
    const sub = try scratch.joinZ("sub");
    defer allocator.free(sub);
    var stream = DirStream.open(sub).?;
    defer stream.close();
    var count: usize = 0;
    while (try stream.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 400), count);
}

test "listing stats agree with lstat over a real tree (ZDEDUPE_DIRSTREAM_TREE)" {
    const root = libc.getenv("ZDEDUPE_DIRSTREAM_TREE") orelse return error.SkipZigTest;
    const from_listing = try expectListingMatchesLstat(std.mem.span(root), true);
    std.debug.print("dirstream: {d} files compared against lstat under {s}\n", .{ from_listing, root });
}
