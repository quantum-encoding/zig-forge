//! Externally-anchored parity tests for zchmod.
//!
//! The external anchor is the REAL GNU coreutils `chmod` binary (gchmod,
//! GNU coreutils 9.10). Each test runs the same argv through both `zchmod`
//! and `gchmod` against identical files laid out in isolated temp directories,
//! then asserts the resulting st_mode permission bits (read via libc lstat(2))
//! AND the process exit codes match. This is a true external anchor per the
//! repo golden rule: the expected values are produced by an implementation
//! zchmod's author did not write. No roundtrip-only assertions exist here.
//!
//! Binaries are located via env vars set by build.zig:
//!   ZCHMOD_BIN  — path to the freshly-built zchmod (required)
//!   GCHMOD_BIN  — path to GNU chmod (default /opt/homebrew/bin/gchmod)
//! If GNU chmod is not present the diffing tests SkipZigTest rather than
//! silently pass.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

// A process-spawning io needs a real backing allocator. Use the page
// allocator so the io's internal bookkeeping doesn't trip the testing
// allocator's leak detector.
var g_threaded: ?Io.Threaded = null;
fn getIo() Io {
    if (g_threaded == null) g_threaded = Io.Threaded.init(std.heap.page_allocator, .{});
    return g_threaded.?.io();
}

// Minimal per-OS stat struct — just enough to read st_mode.
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

extern "c" fn lstat(path: [*:0]const u8, buf: *Stat) c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn symlink(target: [*:0]const u8, linkpath: [*:0]const u8) c_int;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;

const O_CREAT: c_int = if (builtin.os.tag == .linux) 0o100 else 0x0200;
const O_WRONLY: c_int = 0x0001;

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
    return lstat(@ptrCast(&tmp), &b) == 0;
}

/// low 12 mode bits (permissions + setuid/setgid/sticky) of `dir/name`, via
/// lstat so we measure the entry itself (never a symlink's target).
fn permBits(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) !u16 {
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir, name }, 0);
    defer allocator.free(path);
    var buf: Stat = undefined;
    if (lstat(path.ptr, &buf) != 0) return error.StatFailed;
    return @as(u16, @intCast(@as(u32, buf.mode) & 0o7777));
}

fn makeFile(allocator: std.mem.Allocator, dir: []const u8, name: []const u8, mode: c_uint) !void {
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir, name }, 0);
    defer allocator.free(path);
    // A prior case may have left this name at mode 000 (unopenable even by the
    // owner on macOS); make it writable again before reusing it. Ignored if it
    // does not yet exist.
    _ = chmod(path.ptr, 0o600);
    const fd = open(path.ptr, O_CREAT | O_WRONLY, mode);
    if (fd < 0) return error.OpenFailed;
    _ = close(fd);
    // open() honours umask; force the exact starting mode.
    if (chmod(path.ptr, mode) != 0) return error.ChmodFailed;
}

fn makeDir(allocator: std.mem.Allocator, dir: []const u8, name: []const u8, mode: c_uint) !void {
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir, name }, 0);
    defer allocator.free(path);
    if (mkdir(path.ptr, mode) != 0) return error.MkdirFailed;
    if (chmod(path.ptr, mode) != 0) return error.ChmodFailed;
}

fn makeSymlink(allocator: std.mem.Allocator, dir: []const u8, name: []const u8, target: []const u8) !void {
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir, name }, 0);
    defer allocator.free(path);
    const tgt = try allocator.dupeZ(u8, target);
    defer allocator.free(tgt);
    if (symlink(tgt.ptr, path.ptr) != 0) return error.SymlinkFailed;
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

const Harness = struct {
    allocator: std.mem.Allocator,
    zchmod: []const u8,
    gchmod: []const u8,
    zdir: []const u8,
    gdir: []const u8,
    root_path: []const u8,

    fn init(allocator: std.mem.Allocator) !Harness {
        const zchmod = getBin("ZCHMOD_BIN", "zig-out/bin/zchmod");
        const gchmod = getBin("GCHMOD_BIN", "/opt/homebrew/bin/gchmod");
        if (!haveGnu(gchmod)) return error.SkipZigTest;

        var tmpl = [_]u8{0} ** 48;
        const prefix = "/tmp/zchmod_parity_XXXXXX";
        @memcpy(tmpl[0..prefix.len], prefix);
        const made = mkdtemp(@ptrCast(&tmpl)) orelse return error.MkdtempFailed;
        const root_path = try allocator.dupe(u8, std.mem.sliceTo(made, 0));

        const zdir = try std.fmt.allocPrint(allocator, "{s}/z", .{root_path});
        const gdir = try std.fmt.allocPrint(allocator, "{s}/g", .{root_path});
        try makeDir(allocator, root_path, "z", 0o755);
        try makeDir(allocator, root_path, "g", 0o755);
        return .{
            .allocator = allocator,
            .zchmod = zchmod,
            .gchmod = gchmod,
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
        const z = try runExit(self.zchmod, args, self.zdir);
        const g = try runExit(self.gchmod, args, self.gdir);
        return .{ .z = z, .g = g };
    }
};

// ---------------------------------------------------------------------------
// Case 1: single regular file, octal & symbolic modes.
// For each (start_mode, mode_arg) we assert zchmod and gchmod agree on both
// the resulting permission bits and the exit code.
// ---------------------------------------------------------------------------

const FileCase = struct { start: c_uint, arg: []const u8 };

test "single-file mode changes match GNU chmod" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator) catch |e| return e;
    defer h.deinit();

    const cases = [_]FileCase{
        // valid octal (incl. leading zeros GNU accepts)
        .{ .start = 0o644, .arg = "755" },
        .{ .start = 0o644, .arg = "0755" },
        .{ .start = 0o644, .arg = "00755" },
        .{ .start = 0o777, .arg = "000" },
        .{ .start = 0o644, .arg = "7777" },
        .{ .start = 0o600, .arg = "4755" },
        .{ .start = 0o600, .arg = "2755" },
        .{ .start = 0o600, .arg = "1777" },
        // symbolic
        .{ .start = 0o644, .arg = "u+x" },
        .{ .start = 0o644, .arg = "ugo+x" },
        .{ .start = 0o644, .arg = "go-w" },
        .{ .start = 0o644, .arg = "a=rw" },
        .{ .start = 0o777, .arg = "a-x" },
        .{ .start = 0o000, .arg = "u+rwx" },
        .{ .start = 0o644, .arg = "u+x,g-r" },
        .{ .start = 0o755, .arg = "+t" },
        .{ .start = 0o755, .arg = "u+s" },
        .{ .start = 0o755, .arg = "g+s" },
        // 'X' on a NON-executable regular file: no execute added (GNU parity)
        .{ .start = 0o644, .arg = "a+X" },
        // 'X' on an already-executable file: execute added
        .{ .start = 0o744, .arg = "go+X" },
    };

    for (cases) |c| {
        try makeFile(allocator, h.zdir, "f", c.start);
        try makeFile(allocator, h.gdir, "f", c.start);
        const r = try h.runBoth(&.{ c.arg, "f" });
        const zb = try permBits(allocator, h.zdir, "f");
        const gb = try permBits(allocator, h.gdir, "f");
        std.testing.expectEqual(gb, zb) catch |e| {
            std.debug.print("mode mismatch for start=0o{o} arg='{s}': z=0o{o} g=0o{o}\n", .{ c.start, c.arg, zb, gb });
            return e;
        };
        std.testing.expectEqual(r.g, r.z) catch |e| {
            std.debug.print("exit mismatch for arg='{s}': z={d} g={d}\n", .{ c.arg, r.z, r.g });
            return e;
        };
    }
}

// ---------------------------------------------------------------------------
// Case 2: 'X' on a directory must add execute (regression: the directory type
// bit used to be masked off before the check, so a+X never fired on dirs).
// ---------------------------------------------------------------------------

test "symbolic X on a directory adds execute like GNU" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator) catch |e| return e;
    defer h.deinit();

    try makeDir(allocator, h.zdir, "d", 0o644);
    try makeDir(allocator, h.gdir, "d", 0o644);
    const r = try h.runBoth(&.{ "a+X", "d" });
    try std.testing.expectEqual(r.g, r.z);
    const zb = try permBits(allocator, h.zdir, "d");
    const gb = try permBits(allocator, h.gdir, "d");
    // GNU turns 0o644 dir into 0o755.
    try std.testing.expectEqual(@as(u16, 0o755), gb);
    try std.testing.expectEqual(gb, zb);
}

// ---------------------------------------------------------------------------
// Case 3: invalid modes. GNU rejects each with exit 1 and leaves the file
// untouched. These used to crash (panic/overflow) or silently succeed.
// ---------------------------------------------------------------------------

test "invalid modes are rejected (exit 1, file unchanged) like GNU" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator) catch |e| return e;
    defer h.deinit();

    const bad = [_][]const u8{
        "", // empty -> GNU invalid (used to set 000)
        "888", // non-octal digits
        "zzz", // garbage symbolic
        "12345", // 5-digit octal value > 0o7777
        "010000", // leading-zero but value > 0o7777
        "200000", // >= 0o200000 (used to panic on @intCast to u16)
        "7777777777777", // overflows u32 (used to panic on overflow)
        "u+xZ", // trailing garbage after a valid clause
        "a", // who with no operator
    };

    for (bad) |arg| {
        try makeFile(allocator, h.zdir, "f", 0o644);
        try makeFile(allocator, h.gdir, "f", 0o644);
        const r = try h.runBoth(&.{ arg, "f" });
        std.testing.expectEqual(r.g, r.z) catch |e| {
            std.debug.print("exit mismatch for invalid arg='{s}': z={d} g={d}\n", .{ arg, r.z, r.g });
            return e;
        };
        // GNU rejects: exit 1.
        try std.testing.expectEqual(@as(u8, 1), r.g);
        // File must be untouched (still 0o644) in BOTH trees.
        try std.testing.expectEqual(@as(u16, 0o644), try permBits(allocator, h.gdir, "f"));
        std.testing.expectEqual(@as(u16, 0o644), try permBits(allocator, h.zdir, "f")) catch |e| {
            std.debug.print("zchmod modified file for invalid arg='{s}'\n", .{arg});
            return e;
        };
    }
}

// ---------------------------------------------------------------------------
// Case 4: recursive traversal must NOT follow a symlink and redirect the mode
// change onto the target outside the tree (the reported high-severity hole).
// Layout:  root/secret (0600)  and  root/tree/link -> ../secret
// After `chmod -R 777 tree`, GNU leaves secret at 0600. zchmod must too.
// ---------------------------------------------------------------------------

test "recursive chmod does not follow symlinks (target left untouched) like GNU" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator) catch |e| return e;
    defer h.deinit();

    inline for (.{ h.zdir, h.gdir }) |base| {
        try makeFile(allocator, base, "secret", 0o600);
        try makeDir(allocator, base, "tree", 0o755);
        const treedir = try std.fmt.allocPrint(allocator, "{s}/tree", .{base});
        defer allocator.free(treedir);
        try makeSymlink(allocator, treedir, "link", "../secret");
        // a real regular file inside the tree, so -R has something to change
        try makeFile(allocator, treedir, "inner", 0o644);
    }

    const r = try h.runBoth(&.{ "-R", "777", "tree" });
    try std.testing.expectEqual(r.g, r.z);

    // The out-of-tree target must be untouched (0600) under both.
    const g_secret = try permBits(allocator, h.gdir, "secret");
    const z_secret = try permBits(allocator, h.zdir, "secret");
    try std.testing.expectEqual(@as(u16, 0o600), g_secret);
    std.testing.expectEqual(g_secret, z_secret) catch |e| {
        std.debug.print("SECURITY: zchmod -R followed a symlink; secret=0o{o} (want 0o600)\n", .{z_secret});
        return e;
    };

    // The real in-tree file must have been changed to 0o777 under both.
    const treedir_z = try std.fmt.allocPrint(allocator, "{s}/tree", .{h.zdir});
    defer allocator.free(treedir_z);
    const treedir_g = try std.fmt.allocPrint(allocator, "{s}/tree", .{h.gdir});
    defer allocator.free(treedir_g);
    try std.testing.expectEqual(@as(u16, 0o777), try permBits(allocator, treedir_g, "inner"));
    try std.testing.expectEqual(@as(u16, 0o777), try permBits(allocator, treedir_z, "inner"));
}

// ---------------------------------------------------------------------------
// Case 5: --reference=RFILE copies the reference file's mode, matching GNU.
// ---------------------------------------------------------------------------

test "--reference copies RFILE mode like GNU" {
    const allocator = std.testing.allocator;
    var h = Harness.init(allocator) catch |e| return e;
    defer h.deinit();

    inline for (.{ h.zdir, h.gdir }) |base| {
        try makeFile(allocator, base, "ref", 0o640);
        try makeFile(allocator, base, "f", 0o755);
    }
    const r = try h.runBoth(&.{ "--reference=ref", "f" });
    try std.testing.expectEqual(r.g, r.z);
    const gb = try permBits(allocator, h.gdir, "f");
    const zb = try permBits(allocator, h.zdir, "f");
    try std.testing.expectEqual(@as(u16, 0o640), gb);
    try std.testing.expectEqual(gb, zb);
}
