//! Moving an item to the system Trash: recoverable, never a delete.
//!
//! **macOS.** `-[NSFileManager trashItemAtURL:resultingItemURL:error:]`,
//! reached through the Objective-C runtime. Foundation is loaded with
//! `dlopen` on first use, so nothing here links against a framework and the
//! core still cross-compiles without an Apple SDK. The item goes where Finder
//! would put it, and the answer says where that is.
//!
//! **Linux.** The freedesktop Trash specification 1.0
//! (specifications.freedesktop.org/trash-spec/latest): the item is renamed
//! into `files/` of a trash directory on its own filesystem, after
//! `info/<name>.trashinfo` recording where it came from has been created
//! exclusively (which is what reserves the name). The home trash
//! (`$XDG_DATA_HOME/Trash`) serves its own filesystem; any other filesystem
//! uses `$topdir/.Trash/$uid` when an administrator made a sticky
//! `$topdir/.Trash`, else `$topdir/.Trash-$uid`. Nothing is ever copied
//! across filesystems: an item with no usable trash directory on its own
//! filesystem stays where it is.
//!
//! **Elsewhere** (Windows): unsupported, said as such.
//!
//! Not thread-safe: call from one thread at a time.

const std = @import("std");
const builtin = @import("builtin");
const libc = @import("sys.zig").c;
const pstat = @import("pstat.zig");
const filters = @import("filters.zig");

const Allocator = std.mem.Allocator;

pub const Outcome = union(enum) {
    /// Where the item is now, inside the Trash.
    moved: []const u8,
    /// Why it was not moved; it is untouched.
    failed: []const u8,
};

/// Whether this platform has a Trash this module can use.
pub const supported = builtin.os.tag.isDarwin() or builtin.os.tag == .linux;

/// Move `path` (absolute, exact bytes) to the Trash. `is_dir` says what it is.
/// Strings in the outcome are allocated in `arena`.
pub fn moveToTrash(arena: Allocator, path: []const u8, is_dir: bool) Outcome {
    if (!filters.isAbsolute(path) or filters.isRoot(path)) return .{ .failed = "not an absolute path below the root" };
    if (comptime builtin.os.tag.isDarwin()) return darwinTrash(arena, path, is_dir);
    if (comptime builtin.os.tag == .linux) return freedesktop.trash(arena, path, freedesktop.homeTrash(arena));
    return .{ .failed = "the Trash is not supported on this platform" };
}

// ===========================================================================
// macOS: NSFileManager through the Objective-C runtime
// ===========================================================================

const Id = ?*anyopaque;
const Sel = ?*anyopaque;
/// Objective-C BOOL: `bool` on arm64, `signed char` on x86_64.
const Bool = if (builtin.cpu.arch == .aarch64) bool else i8;
const yes: Bool = if (Bool == bool) true else 1;
const no: Bool = if (Bool == bool) false else 0;

const Objc = struct {
    get_class: *const fn ([*:0]const u8) callconv(.c) Id,
    register_name: *const fn ([*:0]const u8) callconv(.c) Sel,
    msg_send: *const anyopaque,
    pool_push: *const fn () callconv(.c) ?*anyopaque,
    pool_pop: *const fn (?*anyopaque) callconv(.c) void,

    fn send(self: *const Objc, comptime Fn: type) Fn {
        return @ptrCast(@alignCast(self.msg_send));
    }
};

var objc_cache: ?Objc = null;
var objc_failed = false;

fn loadObjc() ?*const Objc {
    if (objc_cache) |*o| return o;
    if (objc_failed) return null;
    if (comptime !builtin.os.tag.isDarwin()) return null;
    objc_failed = true;
    // Both live in the dyld shared cache, so they load whether or not the
    // files exist on disk.
    _ = libc.dlopen("/System/Library/Frameworks/Foundation.framework/Foundation", .{ .NOW = true }) orelse return null;
    const lib = libc.dlopen("/usr/lib/libobjc.A.dylib", .{ .NOW = true }) orelse return null;
    objc_cache = .{
        .get_class = @ptrCast(@alignCast(libc.dlsym(lib, "objc_getClass") orelse return null)),
        .register_name = @ptrCast(@alignCast(libc.dlsym(lib, "sel_registerName") orelse return null)),
        .msg_send = libc.dlsym(lib, "objc_msgSend") orelse return null,
        .pool_push = @ptrCast(@alignCast(libc.dlsym(lib, "objc_autoreleasePoolPush") orelse return null)),
        .pool_pop = @ptrCast(@alignCast(libc.dlsym(lib, "objc_autoreleasePoolPop") orelse return null)),
    };
    objc_failed = false;
    return &objc_cache.?;
}

fn darwinTrash(arena: Allocator, path: []const u8, is_dir: bool) Outcome {
    const objc = loadObjc() orelse return .{ .failed = "Foundation could not be loaded" };
    const path_z = arena.dupeSentinel(u8, path, 0) catch return .{ .failed = "out of memory" };

    const pool = objc.pool_push();
    defer objc.pool_pop(pool);

    const send0 = objc.send(*const fn (Id, Sel) callconv(.c) Id);
    const send_cstr = objc.send(*const fn (Id, Sel) callconv(.c) ?[*:0]const u8);
    const send_url = objc.send(*const fn (Id, Sel, [*:0]const u8, Bool, Id) callconv(.c) Id);
    const send_trash = objc.send(*const fn (Id, Sel, Id, *Id, *Id) callconv(.c) Bool);

    const manager = send0(objc.get_class("NSFileManager"), objc.register_name("defaultManager")) orelse
        return .{ .failed = "NSFileManager is unavailable" };
    // The exact bytes, not a decoded string: what was scanned is what goes.
    const url = send_url(
        objc.get_class("NSURL"),
        objc.register_name("fileURLWithFileSystemRepresentation:isDirectory:relativeToURL:"),
        path_z.ptr,
        if (is_dir) yes else no,
        null,
    ) orelse return .{ .failed = "the path cannot be expressed as a file URL" };

    var resulting: Id = null;
    var err: Id = null;
    const ok = send_trash(manager, objc.register_name("trashItemAtURL:resultingItemURL:error:"), url, &resulting, &err);
    if (ok == no) {
        if (err != null) {
            const desc = send0(err, objc.register_name("localizedDescription"));
            if (desc != null) {
                if (send_cstr(desc, objc.register_name("UTF8String"))) |text| {
                    return .{ .failed = arena.dupe(u8, std.mem.span(text)) catch "could not be moved to the Trash" };
                }
            }
        }
        return .{ .failed = "could not be moved to the Trash" };
    }
    if (resulting != null) {
        if (send_cstr(resulting, objc.register_name("fileSystemRepresentation"))) |where| {
            return .{ .moved = arena.dupe(u8, std.mem.span(where)) catch "the Trash" };
        }
    }
    return .{ .moved = "the Trash" };
}

// ===========================================================================
// Linux: the freedesktop Trash specification
// ===========================================================================

pub const freedesktop = struct {
    /// `$XDG_DATA_HOME/Trash`, or `$HOME/.local/share/Trash`; null when
    /// neither is known.
    pub fn homeTrash(arena: Allocator) ?[]const u8 {
        if (libc.getenv("XDG_DATA_HOME")) |x| {
            const dir = std.mem.span(x);
            if (filters.isAbsolute(dir)) return std.fmt.allocPrint(arena, "{s}/Trash", .{filters.trimSep(dir)}) catch null;
        }
        const home = std.mem.span(libc.getenv("HOME") orelse return null);
        if (!filters.isAbsolute(home)) return null;
        return std.fmt.allocPrint(arena, "{s}/.local/share/Trash", .{filters.trimSep(home)}) catch null;
    }

    /// Trash `path` into `home_trash` when that is on the item's filesystem,
    /// else into its filesystem's own trash directory.
    pub fn trash(arena: Allocator, path: []const u8, home_trash: ?[]const u8) Outcome {
        if (comptime builtin.os.tag == .windows) return .{ .failed = "the Trash is not supported on this platform" };
        const path_z = arena.dupeSentinel(u8, path, 0) catch return .{ .failed = "out of memory" };
        const item = pstat.lstat(path_z.ptr) catch return .{ .failed = "no longer exists" };
        const parent = filters.parentDir(path) orelse return .{ .failed = "has no parent folder" };
        const parent_st = statPath(arena, parent) orelse return .{ .failed = "its folder cannot be read" };
        if (parent_st.dev != item.dev) return .{ .failed = "is a mount point" };

        const use_home = if (home_trash) |ht| sameDevice(arena, ht, item.dev) else false;
        const target: Target = if (use_home) home: {
            if (!makeDirs(arena, home_trash.?)) return .{ .failed = "the home Trash cannot be created" };
            break :home .{ .dir = home_trash.?, .topdir = null };
        } else top: {
            const topdir = mountTop(arena, path, item.dev) orelse return .{ .failed = "its filesystem cannot be read" };
            const dir = topTrash(arena, topdir, libc.getuid()) orelse
                return .{ .failed = "its filesystem has no Trash this account can use" };
            break :top .{ .dir = dir, .topdir = topdir };
        };
        return moveInto(arena, path_z, target);
    }

    const Target = struct {
        dir: []const u8,
        /// The filesystem top of a `$topdir` trash; null for the home trash.
        topdir: ?[]const u8,
    };

    fn statPath(arena: Allocator, path: []const u8) ?pstat.Stat {
        const z = arena.dupeSentinel(u8, path, 0) catch return null;
        return pstat.stat(z.ptr) catch null;
    }

    fn lstatPath(arena: Allocator, path: []const u8) ?pstat.Stat {
        const z = arena.dupeSentinel(u8, path, 0) catch return null;
        return pstat.lstat(z.ptr) catch null;
    }

    /// `dir`, or its nearest existing ancestor, is on device `dev`.
    fn sameDevice(arena: Allocator, dir: []const u8, dev: u64) bool {
        var probe: []const u8 = dir;
        while (true) {
            if (statPath(arena, probe)) |st| return st.dev == dev;
            probe = filters.parentDir(probe) orelse return false;
        }
    }

    /// The topmost folder above `path` on device `dev`: its mount point.
    fn mountTop(arena: Allocator, path: []const u8, dev: u64) ?[]const u8 {
        var top = filters.parentDir(path) orelse return null;
        while (filters.parentDir(top)) |up| {
            const st = statPath(arena, up) orelse return null;
            if (st.dev != dev) break;
            top = up;
        }
        return top;
    }

    /// `$topdir/.Trash/$uid` under an administrator's sticky, real
    /// `$topdir/.Trash`; otherwise `$topdir/.Trash-$uid`, which must be this
    /// account's own folder and not a link.
    fn topTrash(arena: Allocator, topdir: []const u8, uid: u32) ?[]const u8 {
        const base = if (filters.isRoot(topdir)) "" else filters.trimSep(topdir);
        const shared = std.fmt.allocPrint(arena, "{s}/.Trash", .{base}) catch return null;
        if (lstatPath(arena, shared)) |st| {
            const sticky = st.mode & 0o1000 != 0;
            if (st.isDir() and sticky) {
                const mine = std.fmt.allocPrint(arena, "{s}/{d}", .{ shared, uid }) catch return null;
                if (ownedDir(arena, mine, uid, true)) return mine;
            }
        }
        const own = std.fmt.allocPrint(arena, "{s}/.Trash-{d}", .{ base, uid }) catch return null;
        if (ownedDir(arena, own, uid, true)) return own;
        return null;
    }

    /// `path` is (after creating it, when `create`) a real folder owned by `uid`.
    fn ownedDir(arena: Allocator, path: []const u8, uid: u32, create: bool) bool {
        const z = arena.dupeSentinel(u8, path, 0) catch return false;
        if (create) _ = libc.mkdir(z.ptr, 0o700);
        const st = pstat.lstat(z.ptr) catch return false;
        return st.isDir() and st.uid == uid;
    }

    /// `mkdir -p` with mode 0700; true when `dir` ends up a folder.
    fn makeDirs(arena: Allocator, dir: []const u8) bool {
        if (lstatPath(arena, dir)) |st| return st.isDir();
        const parent = filters.parentDir(dir) orelse return false;
        if (!makeDirs(arena, parent)) return false;
        const z = arena.dupeSentinel(u8, dir, 0) catch return false;
        _ = libc.mkdir(z.ptr, 0o700);
        const st = pstat.lstat(z.ptr) catch return false;
        return st.isDir();
    }

    fn moveInto(arena: Allocator, path_z: [:0]const u8, target: Target) Outcome {
        const uid = libc.getuid();
        const files_dir = std.fmt.allocPrint(arena, "{s}/files", .{target.dir}) catch return .{ .failed = "out of memory" };
        const info_dir = std.fmt.allocPrint(arena, "{s}/info", .{target.dir}) catch return .{ .failed = "out of memory" };
        if (!ownedDir(arena, files_dir, uid, true) or !ownedDir(arena, info_dir, uid, true))
            return .{ .failed = "the Trash folders cannot be created" };

        const path = path_z[0..path_z.len];
        const original = if (target.topdir) |top| relativeTo(path, top) else path;
        const info_text = infoFile(arena, original, deletionDate()) catch return .{ .failed = "out of memory" };
        const base = filters.baseName(path);

        var n: usize = 1;
        while (n <= 10_000) : (n += 1) {
            const name = trashName(arena, base, n) catch return .{ .failed = "out of memory" };
            const info_path = std.fmt.allocPrintSentinel(arena, "{s}/{s}.trashinfo", .{ info_dir, name }, 0) catch return .{ .failed = "out of memory" };
            const fd = libc.open(info_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(libc.mode_t, 0o600));
            if (fd < 0) {
                if (libc.errno(fd) == .EXIST) continue;
                return .{ .failed = "the Trash info file cannot be written" };
            }
            const written = writeAll(fd, info_text);
            _ = libc.close(fd);
            const dest = std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ files_dir, name }, 0) catch {
                _ = libc.unlink(info_path.ptr);
                return .{ .failed = "out of memory" };
            };
            if (!written) {
                _ = libc.unlink(info_path.ptr);
                return .{ .failed = "the Trash info file cannot be written" };
            }
            // A name taken in files/ without its info file is someone else's.
            if (pstat.lstat(dest.ptr)) |_| {
                _ = libc.unlink(info_path.ptr);
                continue;
            } else |_| {}
            if (libc.rename(path_z.ptr, dest.ptr) != 0) {
                const e = libc.errno(@as(c_int, -1));
                _ = libc.unlink(info_path.ptr);
                return .{ .failed = switch (e) {
                    .ACCES, .PERM => "permission denied",
                    .NOENT => "no longer exists",
                    .XDEV => "the Trash is on another filesystem",
                    .BUSY => "is in use",
                    else => "could not be moved to the Trash",
                } };
            }
            return .{ .moved = dest[0..dest.len] };
        }
        return .{ .failed = "no free name in the Trash" };
    }

    fn writeAll(fd: c_int, bytes: []const u8) bool {
        var done: usize = 0;
        while (done < bytes.len) {
            const n = libc.write(fd, bytes.ptr + done, bytes.len - done);
            if (n <= 0) return false;
            done += @intCast(n);
        }
        return true;
    }

    fn relativeTo(path: []const u8, top: []const u8) []const u8 {
        if (filters.isRoot(top)) return path[1..];
        return path[filters.trimSep(top).len + 1 ..];
    }
};

/// The name an item takes in `files/`: its own, then `name.2`, `name.3`, ...
pub fn trashName(arena: Allocator, base: []const u8, n: usize) ![]const u8 {
    if (n == 1) return base;
    return std.fmt.allocPrint(arena, "{s}.{d}", .{ base, n });
}

/// A `.trashinfo` file: where the item was (percent-encoded) and when.
pub fn infoFile(arena: Allocator, original: []const u8, date: [19]u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(arena, "[Trash Info]\nPath=");
    for (original) |c| {
        const plain = std.ascii.isAlphanumeric(c) or switch (c) {
            '/', '-', '_', '.', '~' => true,
            else => false,
        };
        if (plain) {
            try out.append(arena, c);
        } else {
            const hex = "0123456789ABCDEF";
            try out.appendSlice(arena, &.{ '%', hex[c >> 4], hex[c & 15] });
        }
    }
    try out.appendSlice(arena, "\nDeletionDate=");
    try out.appendSlice(arena, &date);
    try out.append(arena, '\n');
    return out.items;
}

/// Local time as `YYYY-MM-DDThh:mm:ss`, as the specification asks.
fn deletionDate() [19]u8 {
    var out: [19]u8 = "1970-01-01T00:00:00".*;
    if (comptime builtin.os.tag != .linux) return out;
    var ts: libc.timespec = undefined;
    if (libc.clock_gettime(.REALTIME, &ts) != 0) return out;
    const now: i64 = ts.sec;
    var tm: Tm = undefined;
    if (localtime_r(&now, &tm) == null) return out;
    _ = std.fmt.bufPrint(&out, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(tm.year + 1900)), @as(u32, @intCast(tm.mon + 1)), @as(u32, @intCast(tm.mday)),
        @as(u32, @intCast(tm.hour)),        @as(u32, @intCast(tm.min)),     @as(u32, @intCast(tm.sec)),
    }) catch {};
    return out;
}

/// `struct tm` as glibc and musl lay it out.
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};

/// 64-bit `time_t`, as on every 64-bit Linux.
extern "c" fn localtime_r(t: *const i64, out: *Tm) ?*Tm;

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const Scratch = @import("testing_scratch.zig").Scratch;

test "trash info files percent-encode the original path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try infoFile(arena, "/home/u/a b/50%/node_modules", "2026-10-18T09:05:00".*);
    try testing.expectEqualStrings(
        "[Trash Info]\nPath=/home/u/a%20b/50%25/node_modules\nDeletionDate=2026-10-18T09:05:00\n",
        text,
    );
    try testing.expectEqualStrings("x", try trashName(arena, "x", 1));
    try testing.expectEqualStrings("x.3", try trashName(arena, "x", 3));
}

test "a relative or root path is never trashed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expect(moveToTrash(arena_state.allocator(), "relative/dir", true) == .failed);
    try testing.expect(moveToTrash(arena_state.allocator(), "/", true) == .failed);
}

test "freedesktop: a folder goes to the home trash with its info file, names never collide" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch = try Scratch.init(testing.allocator, "trash-fd");
    defer scratch.deinit();

    try scratch.makeDir("a");
    try scratch.makeDir("a/node_modules");
    try scratch.writeFile("a/node_modules/x.js", "1");
    try scratch.makeDir("b");
    try scratch.makeDir("b/node_modules");
    try scratch.writeFile("b/node_modules/y.js", "2");
    const home_trash = try scratch.join("Trash");
    defer testing.allocator.free(home_trash);

    const first = try scratch.join("a/node_modules");
    defer testing.allocator.free(first);
    const second = try scratch.join("b/node_modules");
    defer testing.allocator.free(second);

    const one = freedesktop.trash(arena, first, home_trash);
    try testing.expect(one == .moved);
    try testing.expect(!try scratch.exists("a/node_modules"));
    try testing.expect(try scratch.exists("Trash/files/node_modules/x.js"));
    try testing.expect(try scratch.exists("Trash/info/node_modules.trashinfo"));

    const two = freedesktop.trash(arena, second, home_trash);
    try testing.expect(two == .moved);
    try testing.expect(try scratch.exists("Trash/files/node_modules.2/y.js"));
    try testing.expect(try scratch.exists("Trash/info/node_modules.2.trashinfo"));

    // The info file names the exact original location.
    const info_path = try scratch.joinZ("Trash/info/node_modules.2.trashinfo");
    defer testing.allocator.free(info_path);
    const fd = libc.open(info_path.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    try testing.expect(fd >= 0);
    defer _ = libc.close(fd);
    var buf: [4096]u8 = undefined;
    const n = libc.read(fd, &buf, buf.len);
    try testing.expect(n > 0);
    const text = buf[0..@intCast(n)];
    const expected_line = try std.fmt.allocPrint(arena, "Path={s}\n", .{second});
    try testing.expect(std.mem.indexOf(u8, text, expected_line) != null);
    try testing.expect(std.mem.startsWith(u8, text, "[Trash Info]\n"));
}

test "macOS: a folder goes to the Trash and the answer says where" {
    if (comptime !builtin.os.tag.isDarwin()) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch = try Scratch.init(testing.allocator, "trash-mac");
    defer scratch.deinit();

    try scratch.makeDir("zig-out");
    try scratch.writeFile("zig-out/bin", "built");
    const path = try scratch.join("zig-out");
    defer testing.allocator.free(path);

    const outcome = moveToTrash(arena, path, true);
    switch (outcome) {
        .failed => |why| {
            std.debug.print("system Trash refused the fixture: {s}\n", .{why});
            return error.TestUnexpectedResult;
        },
        .moved => |where| {
            const where_z = try arena.dupeSentinel(u8, where, 0);
            // The fixture is taken back out of the Trash whatever happens.
            defer {
                @import("testing_scratch.zig").removeTree(testing.allocator, where);
                if (pstat.lstat(where_z.ptr)) |_| std.debug.print("left in the Trash: {s}\n", .{where}) else |_| {}
            }
            try testing.expect(!try scratch.exists("zig-out"));
            const bin = try std.fmt.allocPrintSentinel(arena, "{s}/bin", .{where}, 0);
            const st = try pstat.lstat(bin.ptr);
            try testing.expect(st.isFile());
        },
    }
}
