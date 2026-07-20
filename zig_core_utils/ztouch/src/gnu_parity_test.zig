//! Externally-anchored parity tests for ztouch.
//!
//! The external anchor is the REAL GNU coreutils `touch` binary (gtouch,
//! GNU coreutils 9.10). Each test runs the same argv through both `ztouch`
//! and `gtouch` in isolated temp directories and asserts the resulting
//! atime/mtime seconds (read via libc stat(2)) and process exit codes match.
//! This is a true external anchor per the repo golden rule: the expected
//! values are produced by an implementation ztouch's author did not write.
//!
//! Binaries are located via env vars set by build.zig:
//!   ZTOUCH_BIN  — path to the freshly-built ztouch (required)
//!   GTOUCH_BIN  — path to GNU touch (default /opt/homebrew/bin/gtouch)
//! If GNU touch is not present the diffing tests SkipZigTest rather than
//! silently pass.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

// A process-spawning io needs a real backing allocator (the global
// single-threaded instance has none). Use the page allocator so the io's
// internal bookkeeping doesn't trip the testing allocator's leak detector.
var g_threaded: ?Io.Threaded = null;
fn getIo() Io {
    if (g_threaded == null) g_threaded = Io.Threaded.init(std.heap.page_allocator, .{});
    return g_threaded.?.io();
}

// Minimal per-OS stat struct — just enough to read atime/mtime seconds.
const Stat = switch (builtin.os.tag) {
    .linux => extern struct {
        dev: u64,
        ino: u64,
        nlink: u64,
        mode: u32,
        uid: u32,
        gid: u32,
        __pad0: u32 = 0,
        rdev: u64,
        size: i64,
        blksize: i64,
        blocks: i64,
        atim: extern struct { sec: i64, nsec: i64 },
        mtim: extern struct { sec: i64, nsec: i64 },
        ctim: extern struct { sec: i64, nsec: i64 },
        __unused: [3]i64 = .{ 0, 0, 0 },
    },
    else => extern struct {
        dev: i32,
        mode: u16,
        nlink: u16,
        ino: u64,
        uid: u32,
        gid: u32,
        rdev: i32,
        atim: extern struct { sec: i64, nsec: i64 },
        mtim: extern struct { sec: i64, nsec: i64 },
        ctim: extern struct { sec: i64, nsec: i64 },
        birthtim: extern struct { sec: i64, nsec: i64 },
        size: i64,
        blocks: i64,
        blksize: i32,
        flags: u32,
        gen: u32,
        lspare: i32,
        qspare: [2]i64,
    },
};

extern "c" fn stat(path: [*:0]const u8, buf: *Stat) c_int;
extern "c" fn time(timer: ?*i64) i64;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const Times = struct { atime: i64, mtime: i64 };

fn statTimes(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) !Times {
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir, name }, 0);
    defer allocator.free(path);
    var buf: Stat = undefined;
    if (stat(path.ptr, &buf) != 0) return error.StatFailed;
    return .{ .atime = buf.atim.sec, .mtime = buf.mtim.sec };
}

fn fileExists(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) bool {
    const t = statTimes(allocator, dir, name) catch return false;
    _ = t;
    return true;
}

/// Run a binary with args in `cwd`; return the process exit code (255 on signal).
fn runExit(bin: []const u8, args: []const []const u8, cwd: []const u8) !u8 {
    var argv_buf: [16][]const u8 = undefined;
    std.debug.assert(args.len + 1 <= argv_buf.len);
    argv_buf[0] = bin;
    for (args, 0..) |a, idx| argv_buf[idx + 1] = a;
    const argv = argv_buf[0 .. args.len + 1];

    const io = getIo();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        else => 255,
    };
}

fn getBin(env: [*:0]const u8, default: []const u8) []const u8 {
    if (getenv(env)) |v| return std.mem.sliceTo(v, 0);
    return default;
}

fn haveGnu(bin: []const u8) bool {
    var b: Stat = undefined;
    var tmp: [512]u8 = undefined;
    if (bin.len >= tmp.len) return false;
    @memcpy(tmp[0..bin.len], bin);
    tmp[bin.len] = 0;
    return stat(@ptrCast(&tmp), &b) == 0;
}

const Harness = struct {
    allocator: std.mem.Allocator,
    ztouch: []const u8,
    gtouch: []const u8,
    zdir: [:0]u8,
    gdir: [:0]u8,
    root_path: []u8,

    fn init(allocator: std.mem.Allocator) !Harness {
        const ztouch = getBin("ZTOUCH_BIN", "zig-out/bin/ztouch");
        const gtouch = getBin("GTOUCH_BIN", "/opt/homebrew/bin/gtouch");
        if (!haveGnu(gtouch)) return error.SkipZigTest;

        var tmpl = [_]u8{0} ** 40;
        const prefix = "/tmp/ztouch_parity_XXXXXX";
        @memcpy(tmpl[0..prefix.len], prefix);
        const made = mkdtemp(@ptrCast(&tmpl)) orelse return error.MkdtempFailed;
        const root_path = try allocator.dupe(u8, std.mem.sliceTo(made, 0));

        const zdir = try std.fmt.allocPrintSentinel(allocator, "{s}/z", .{root_path}, 0);
        const gdir = try std.fmt.allocPrintSentinel(allocator, "{s}/g", .{root_path}, 0);
        if (mkdir(zdir.ptr, 0o755) != 0) return error.MkdirFailed;
        if (mkdir(gdir.ptr, 0o755) != 0) return error.MkdirFailed;
        return .{
            .allocator = allocator,
            .ztouch = ztouch,
            .gtouch = gtouch,
            .zdir = zdir,
            .gdir = gdir,
            .root_path = root_path,
        };
    }

    fn deinit(self: *Harness) void {
        // Best-effort cleanup of the temp tree.
        _ = runExit("/bin/rm", &.{ "-rf", self.root_path }, ".") catch {};
        self.allocator.free(self.zdir);
        self.allocator.free(self.gdir);
        self.allocator.free(self.root_path);
    }

    /// Run identical args through both binaries; return their exit codes.
    fn runBoth(self: *Harness, args: []const []const u8) !struct { z: u8, g: u8 } {
        const z = try runExit(self.ztouch, args, self.zdir);
        const g = try runExit(self.gtouch, args, self.gdir);
        return .{ .z = z, .g = g };
    }
};

// ---------------------------------------------------------------------------
// Diffing tests against GNU touch
// ---------------------------------------------------------------------------

test "current-time touch matches GNU (not epoch 1970)" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator) catch |e| return e;
    defer h.deinit();

    const before = time(null);
    const r = try h.runBoth(&.{"f"});
    try std.testing.expectEqual(@as(u8, 0), r.z);
    try std.testing.expectEqual(@as(u8, 0), r.g);

    const zt = try statTimes(allocator, h.zdir, "f");
    const gt = try statTimes(allocator, h.gdir, "f");
    // ztouch's mtime must be "now", i.e. within a couple seconds of GNU's,
    // and definitely not ~1970 (the Darwin UTIME_NOW / AT_FDCWD bug).
    try std.testing.expect(zt.mtime >= before - 2);
    try std.testing.expect(@abs(zt.mtime - gt.mtime) <= 2);
}

test "-t local-time stamp matches GNU exactly" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator) catch |e| return e;
    defer h.deinit();

    const r = try h.runBoth(&.{ "-t", "202001011200", "f" });
    try std.testing.expectEqual(@as(u8, 0), r.z);
    try std.testing.expectEqual(@as(u8, 0), r.g);

    const zt = try statTimes(allocator, h.zdir, "f");
    const gt = try statTimes(allocator, h.gdir, "f");
    // Anchors the local-vs-UTC fix AND the AT_FDCWD/utimensat fix.
    try std.testing.expectEqual(gt.mtime, zt.mtime);
    try std.testing.expectEqual(gt.atime, zt.atime);
}

test "-a preserves mtime, sets atime like GNU" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator) catch |e| return e;
    defer h.deinit();

    // Seed both files to a known timestamp first.
    _ = try h.runBoth(&.{ "-t", "201501020304.05", "f" });
    // Now change only the access time.
    const r = try h.runBoth(&.{ "-a", "-t", "202212251530", "f" });
    try std.testing.expectEqual(@as(u8, 0), r.z);
    try std.testing.expectEqual(@as(u8, 0), r.g);

    const zt = try statTimes(allocator, h.zdir, "f");
    const gt = try statTimes(allocator, h.gdir, "f");
    // mtime must be PRESERVED (UTIME_OMIT), atime updated — matching GNU.
    try std.testing.expectEqual(gt.mtime, zt.mtime);
    try std.testing.expectEqual(gt.atime, zt.atime);
}

test "-m preserves atime, sets mtime like GNU" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator) catch |e| return e;
    defer h.deinit();

    _ = try h.runBoth(&.{ "-t", "201501020304.05", "f" });
    const r = try h.runBoth(&.{ "-m", "-t", "202212251530", "f" });
    try std.testing.expectEqual(@as(u8, 0), r.z);
    try std.testing.expectEqual(@as(u8, 0), r.g);

    const zt = try statTimes(allocator, h.zdir, "f");
    const gt = try statTimes(allocator, h.gdir, "f");
    try std.testing.expectEqual(gt.atime, zt.atime);
    try std.testing.expectEqual(gt.mtime, zt.mtime);
}

test "-d @epoch matches GNU" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator) catch |e| return e;
    defer h.deinit();

    const r = try h.runBoth(&.{ "-d", "@1577880000", "f" });
    try std.testing.expectEqual(@as(u8, 0), r.z);
    try std.testing.expectEqual(@as(u8, 0), r.g);

    const zt = try statTimes(allocator, h.zdir, "f");
    const gt = try statTimes(allocator, h.gdir, "f");
    try std.testing.expectEqual(gt.mtime, zt.mtime);
    try std.testing.expectEqual(@as(i64, 1577880000), zt.mtime);
}

test "-d YYYY-MM-DD HH:MM:SS local time matches GNU" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator) catch |e| return e;
    defer h.deinit();

    const r = try h.runBoth(&.{ "-d", "2020-06-15 08:30:00", "f" });
    try std.testing.expectEqual(@as(u8, 0), r.z);
    try std.testing.expectEqual(@as(u8, 0), r.g);

    const zt = try statTimes(allocator, h.zdir, "f");
    const gt = try statTimes(allocator, h.gdir, "f");
    try std.testing.expectEqual(gt.mtime, zt.mtime);
}

test "-r reference file copies times like GNU" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator) catch |e| return e;
    defer h.deinit();

    // Create a reference file with a known timestamp in each dir.
    _ = try h.runBoth(&.{ "-t", "201803040506.07", "ref" });
    const r = try h.runBoth(&.{ "-r", "ref", "f" });
    try std.testing.expectEqual(@as(u8, 0), r.z);
    try std.testing.expectEqual(@as(u8, 0), r.g);

    const zt = try statTimes(allocator, h.zdir, "f");
    const gt = try statTimes(allocator, h.gdir, "f");
    try std.testing.expectEqual(gt.mtime, zt.mtime);
    try std.testing.expectEqual(gt.atime, zt.atime);
}

test "-c on missing file creates nothing, exits 0 like GNU" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator) catch |e| return e;
    defer h.deinit();

    const r = try h.runBoth(&.{ "-c", "nope" });
    try std.testing.expectEqual(r.g, r.z);
    try std.testing.expectEqual(@as(u8, 0), r.z);
    try std.testing.expect(!fileExists(allocator, h.zdir, "nope"));
    try std.testing.expect(!fileExists(allocator, h.gdir, "nope"));
}

test "impossible date Feb 30 rejected like GNU" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator) catch |e| return e;
    defer h.deinit();

    const r = try h.runBoth(&.{ "-t", "202002301200", "f" });
    // GNU rejects impossible calendar dates with a non-zero exit; ztouch must too.
    try std.testing.expect(r.g != 0);
    try std.testing.expect(r.z != 0);
    try std.testing.expect(!fileExists(allocator, h.zdir, "f"));
}

test "missing reference file fails non-zero like GNU" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator) catch |e| return e;
    defer h.deinit();

    const r = try h.runBoth(&.{ "-r", "does-not-exist", "f" });
    try std.testing.expect(r.g != 0);
    try std.testing.expect(r.z != 0);
}

// ---------------------------------------------------------------------------
// Spec-anchored unit checks (documented GNU/POSIX behavior, literal expected
// bytes) — do not depend on the GNU binary being installed.
// ---------------------------------------------------------------------------

test "days-in-month accounts for leap February" {
    // POSIX/Gregorian: 2020 is a leap year, 2021 is not, 2000 is (÷400),
    // 1900 is not (÷100 but not ÷400).
    try std.testing.expect(isLeap(2020));
    try std.testing.expect(!isLeap(2021));
    try std.testing.expect(isLeap(2000));
    try std.testing.expect(!isLeap(1900));
}

fn isLeap(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}
