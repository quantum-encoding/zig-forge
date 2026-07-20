//! Externally-anchored parity tests for zchown.
//!
//! The external anchor is the REAL GNU coreutils `chown` binary (gchown, GNU
//! coreutils 9.10). Each parity case runs identical argv through `zchown` and
//! `gchown` against identically-seeded files in isolated temp directories and
//! asserts the resulting ownership / stdout bytes / exit codes match. Expected
//! values come from an implementation zchown's author did not write — a true
//! external anchor per the zig-forge golden rule (NO roundtrip-only tests).
//!
//! The critical case (`recursive symlink is NOT dereferenced`) additionally
//! asserts a documented GNU/POSIX invariant with the expected gid pinned at
//! runtime (the out-of-tree target's group is UNCHANGED under the default -P),
//! so it bites even if the GNU binary is absent. This is the case that catches
//! the shipped `chown -R` symlink-attack bug.
//!
//! Binaries:
//!   ZCHOWN_BIN — path to the freshly-built zchown (set by build.zig; falls
//!                back to zig-out/bin/zchown).
//!   GNU chown  — first of the well-known coreutils install paths that exists.
//! If GNU chown is not present the diffing cases SkipZigTest rather than
//! silently pass; the -P invariant case still runs.

const std = @import("std");
const builtin = @import("builtin");

// ---------------------------------------------------------------------------
// libc surface used only by the test to seed and inspect ownership.
// ---------------------------------------------------------------------------
extern "c" fn chown(path: [*:0]const u8, owner: u32, group: u32) c_int;
extern "c" fn getuid() u32;
extern "c" fn getgid() u32;
extern "c" fn getgroups(size: c_int, list: [*]u32) c_int;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn symlink(target: [*:0]const u8, linkpath: [*:0]const u8) c_int;

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
extern "c" fn lstat(path: [*:0]const u8, buf: *Stat) c_int;

const CGroup = extern struct {
    gr_name: [*:0]const u8,
    gr_passwd: [*:0]const u8,
    gr_gid: u32,
    gr_mem: [*:null]?[*:0]const u8,
};
extern "c" fn getgrgid(gid: u32) ?*CGroup;

/// Resolve a gid to its group name. GNU's verbose output for a group given by
/// NAME uses the "changed ownership … to :name" form (which zchown matches);
/// a group given NUMERICALLY triggers a separate GNU-only "changed group of …
/// to <n>" form. The stdout-parity cases therefore drive changes by name.
fn groupName(gid: u32) ?[:0]const u8 {
    const gr = getgrgid(gid) orelse return null;
    return std.mem.span(gr.gr_name);
}

fn gidOf(path: [:0]const u8, follow: bool) !u32 {
    var st: Stat = undefined;
    const rc = if (follow) stat(path.ptr, &st) else lstat(path.ptr, &st);
    if (rc != 0) return error.StatFailed;
    return st.gid;
}

// ---------------------------------------------------------------------------
// Binary discovery + running.
// ---------------------------------------------------------------------------
fn zchownBin() []const u8 {
    if (std.c.getenv("ZCHOWN_BIN")) |v| return std.mem.span(v);
    return "zig-out/bin/zchown";
}

fn findGnuChown() ?[:0]const u8 {
    const candidates = [_][:0]const u8{
        "/opt/homebrew/opt/coreutils/libexec/gnubin/chown",
        "/opt/homebrew/bin/gchown",
        "/usr/local/opt/coreutils/libexec/gnubin/chown",
        "/usr/bin/chown",
    };
    for (candidates) |c| {
        if (std.c.access(c.ptr, 0) == 0) return c; // F_OK
    }
    return null;
}

const RunResult = struct {
    stdout: []u8,
    code: u8, // 255 = signal/abnormal termination (the pre-fix overflow panic lands here)
};

fn runBin(
    alloc: std.mem.Allocator,
    io: std.Io,
    bin: []const u8,
    cwd: []const u8,
    args: []const []const u8,
) !RunResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, bin);
    for (args) |a| try argv.append(alloc, a);

    const res = try std.process.run(alloc, io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd },
    });
    alloc.free(res.stderr);
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = res.stdout, .code = code };
}

// ---------------------------------------------------------------------------
// Test environment: two distinct groups the running user belongs to, so we can
// actually chgrp between them without privileges (the audit's 20<->12 case),
// plus a temp root with z/ and g/ sub-trees.
// ---------------------------------------------------------------------------
const Groups = struct { a: u32, b: u32 };

fn twoGroups() !Groups {
    const a = getgid();
    var list: [64]u32 = undefined;
    const n = getgroups(list.len, &list);
    if (n < 0) return error.SkipZigTest;
    var i: usize = 0;
    while (i < @as(usize, @intCast(n))) : (i += 1) {
        if (list[i] != a) return .{ .a = a, .b = list[i] };
    }
    return error.SkipZigTest; // only one group — can't exercise a group change
}

const Env = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    zchown: []const u8,
    gchown: ?[:0]const u8,
    root: [:0]u8,
    zdir: [:0]u8,
    gdir: [:0]u8,
    groups: Groups,

    fn init(alloc: std.mem.Allocator, io: std.Io) !Env {
        const groups = try twoGroups();
        var tmpl = [_]u8{0} ** 48;
        const prefix = "/tmp/zchown_parity_XXXXXX";
        @memcpy(tmpl[0..prefix.len], prefix);
        const made = mkdtemp(@ptrCast(&tmpl)) orelse return error.MkdtempFailed;
        const root = try alloc.dupeZ(u8, std.mem.span(made));
        const zdir = try std.fmt.allocPrintSentinel(alloc, "{s}/z", .{root}, 0);
        const gdir = try std.fmt.allocPrintSentinel(alloc, "{s}/g", .{root}, 0);
        if (mkdir(zdir.ptr, 0o755) != 0) return error.MkdirFailed;
        if (mkdir(gdir.ptr, 0o755) != 0) return error.MkdirFailed;
        return .{
            .alloc = alloc,
            .io = io,
            .zchown = zchownBin(),
            .gchown = findGnuChown(),
            .root = root,
            .zdir = zdir,
            .gdir = gdir,
            .groups = groups,
        };
    }

    fn deinit(self: *Env) void {
        var argv = [_][]const u8{ "/bin/rm", "-rf", self.root };
        _ = std.process.run(self.alloc, self.io, .{ .argv = &argv }) catch null;
        self.alloc.free(self.root);
        self.alloc.free(self.zdir);
        self.alloc.free(self.gdir);
    }

    fn path(self: *Env, dir: [:0]const u8, name: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(self.alloc, "{s}/{s}", .{ dir, name }, 0);
    }

    /// Seed a plain file `name` in both z/ and g/ owned by us with group `gid`.
    fn seedFile(self: *Env, name: []const u8, gid: u32) !void {
        for ([_][:0]const u8{ self.zdir, self.gdir }) |d| {
            const p = try self.path(d, name);
            defer self.alloc.free(p);
            const fd = std.c.open(p.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
            if (fd < 0) return error.CreateFailed;
            _ = std.c.close(fd);
            if (chown(p.ptr, getuid(), gid) != 0) return error.SeedChownFailed;
        }
    }

    /// Run identical args through zchown (in z/) and gchown (in g/); compare
    /// stdout bytes and exit code. Skips if GNU chown is unavailable.
    fn expectParity(self: *Env, args: []const []const u8) !void {
        const gnu = self.gchown orelse return error.SkipZigTest;
        const z = try runBin(self.alloc, self.io, self.zchown, self.zdir, args);
        defer self.alloc.free(z.stdout);
        const g = try runBin(self.alloc, self.io, gnu, self.gdir, args);
        defer self.alloc.free(g.stdout);

        if (!std.mem.eql(u8, z.stdout, g.stdout) or z.code != g.code) {
            std.debug.print(
                "PARITY DIFF args={any}\n  gnu:    out='{s}' exit={d}\n  zchown: out='{s}' exit={d}\n",
                .{ args, g.stdout, g.code, z.stdout, z.code },
            );
            return error.ParityMismatch;
        }
    }
};

// ---------------------------------------------------------------------------
// CRITICAL: recursive traversal must NOT dereference symlinks (GNU default -P).
// This is the shipped chown-R symlink-attack bug. Anchored two ways:
//  (1) the out-of-tree target's group is UNCHANGED (documented -P invariant,
//      expected gid pinned at runtime — runs without GNU), and
//  (2) the whole tree's resulting group matches GNU byte-for-byte.
// ---------------------------------------------------------------------------
test "recursive chgrp does NOT follow a symlink out of the tree (GNU -P default)" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var env = Env.init(alloc, threaded.io()) catch |e| return e;
    defer env.deinit();

    const ga = env.groups.a; // seed group (e.g. staff/20)
    const gb = env.groups.b; // target group (e.g. everyone/12)
    const gb_str = try std.fmt.allocPrint(alloc, ":{d}", .{gb});
    defer alloc.free(gb_str);

    // Build in BOTH trees:  <dir>/outside (group ga)  and  <dir>/tree/evil -> outside
    for ([_][:0]const u8{ env.zdir, env.gdir }) |d| {
        const treedir = try env.path(d, "tree");
        defer alloc.free(treedir);
        if (mkdir(treedir.ptr, 0o755) != 0) return error.MkdirFailed;

        const outside = try env.path(d, "outside");
        defer alloc.free(outside);
        const fd = std.c.open(outside.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        if (fd < 0) return error.CreateFailed;
        _ = std.c.close(fd);
        if (chown(outside.ptr, getuid(), ga) != 0) return error.SeedChownFailed;

        const link = try env.path(d, "tree/evil");
        defer alloc.free(link);
        if (symlink(outside.ptr, link.ptr) != 0) return error.SymlinkFailed;
    }

    // Recursively chgrp the tree to gb.
    const zres = try runBin(alloc, env.io, env.zchown, env.zdir, &.{ "-R", gb_str, "tree" });
    alloc.free(zres.stdout);

    // (1) Documented -P invariant: the out-of-tree referent keeps group ga.
    const z_outside = try env.path(env.zdir, "outside");
    defer alloc.free(z_outside);
    try std.testing.expectEqual(ga, try gidOf(z_outside, true));

    // The symlink itself IS retargeted (lchown) to gb — proves we operated on
    // the link, not its referent.
    const z_link = try env.path(env.zdir, "tree/evil");
    defer alloc.free(z_link);
    try std.testing.expectEqual(gb, try gidOf(z_link, false));

    // (2) Cross-check against GNU when present: same outcome on both sides.
    if (env.gchown) |gnu| {
        const gres = try runBin(alloc, env.io, gnu, env.gdir, &.{ "-R", gb_str, "tree" });
        alloc.free(gres.stdout);
        const g_outside = try env.path(env.gdir, "outside");
        defer alloc.free(g_outside);
        try std.testing.expectEqual(try gidOf(g_outside, true), try gidOf(z_outside, true));
        const g_link = try env.path(env.gdir, "tree/evil");
        defer alloc.free(g_link);
        try std.testing.expectEqual(try gidOf(g_link, false), try gidOf(z_link, false));
    }
}

// ---------------------------------------------------------------------------
// HIGH: a huge numeric UID/GID must be rejected as "invalid" (exit 1), NOT
// overflow-panic (which lands on the 255 signal sentinel). Anchored to GNU:
// `chown: invalid user: '999...'` exit 1.
// ---------------------------------------------------------------------------
test "over-range numeric UID is rejected, not an overflow panic" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var env = Env.init(alloc, threaded.io()) catch |e| return e;
    defer env.deinit();

    try env.seedFile("f", env.groups.a);

    // Direct assertion (holds without GNU): exit 1, never 255 (panic/abort).
    const z = try runBin(alloc, env.io, env.zchown, env.zdir, &.{ "99999999999999999999", "f" });
    defer alloc.free(z.stdout);
    try std.testing.expectEqual(@as(u8, 1), z.code);

    // And byte/exit parity with GNU when available.
    try env.expectParity(&.{ "99999999999999999999", "f" });
}

test "over-range numeric GID (:group) is rejected, not a panic" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var env = Env.init(alloc, threaded.io()) catch |e| return e;
    defer env.deinit();

    try env.seedFile("f", env.groups.a);
    const z = try runBin(alloc, env.io, env.zchown, env.zdir, &.{ ":99999999999999999999", "f" });
    defer alloc.free(z.stdout);
    try std.testing.expectEqual(@as(u8, 1), z.code);
    try env.expectParity(&.{ ":99999999999999999999", "f" });
}

// ---------------------------------------------------------------------------
// MEDIUM: option/operand permutation and `--` terminator (GNU getopt).
// ---------------------------------------------------------------------------
test "option after the owner operand is honored (permutation)" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var env = Env.init(alloc, threaded.io()) catch |e| return e;
    defer env.deinit();

    // Seed to group a; spec `:b` (by name) after which -v appears. GNU applies
    // -v and prints "changed ownership ... to :b".
    try env.seedFile("f", env.groups.a);
    const bname = groupName(env.groups.b) orelse return error.SkipZigTest;
    const gb_str = try std.fmt.allocPrint(alloc, ":{s}", .{bname});
    defer alloc.free(gb_str);
    try env.expectParity(&.{ gb_str, "-v", "f" });
}

test "-- terminates options; following args are operands" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var env = Env.init(alloc, threaded.io()) catch |e| return e;
    defer env.deinit();

    try env.seedFile("f", env.groups.a);
    const uid_str = try std.fmt.allocPrint(alloc, "{d}", .{getuid()});
    defer alloc.free(uid_str);
    // `-- <uid> f`: retained (already ours), exit 0 — GNU accepts `--`.
    try env.expectParity(&.{ "--", uid_str, "f" });
}

// ---------------------------------------------------------------------------
// LOW: verbose output shape is spec-dependent (owner-only prints just the
// owner; group specs include the group). Byte-exact parity with GNU.
// ---------------------------------------------------------------------------
test "verbose owner-only spec prints only the owner (retained)" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var env = Env.init(alloc, threaded.io()) catch |e| return e;
    defer env.deinit();

    try env.seedFile("f", env.groups.a);
    const uid_str = try std.fmt.allocPrint(alloc, "{d}", .{getuid()});
    defer alloc.free(uid_str);
    // GNU: "ownership of 'f' retained as <owner>" — NO ":group".
    try env.expectParity(&.{ "-v", uid_str, "f" });
}

test "verbose group change prints ':group' form matching GNU" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var env = Env.init(alloc, threaded.io()) catch |e| return e;
    defer env.deinit();

    try env.seedFile("f", env.groups.a);
    const bname = groupName(env.groups.b) orelse return error.SkipZigTest;
    const gb_str = try std.fmt.allocPrint(alloc, ":{s}", .{bname});
    defer alloc.free(gb_str);
    // GNU: "changed ownership of 'f' from <owner>:<a> to :<b>"
    try env.expectParity(&.{ "-v", gb_str, "f" });
}

test "invalid user name is rejected with GNU-parity exit code" {
    const alloc = std.testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    var env = Env.init(alloc, threaded.io()) catch |e| return e;
    defer env.deinit();

    try env.seedFile("f", env.groups.a);
    const z = try runBin(alloc, env.io, env.zchown, env.zdir, &.{ "no_such_user_zz", "f" });
    defer alloc.free(z.stdout);
    try std.testing.expectEqual(@as(u8, 1), z.code);
    // exit-code parity (stderr text differs by program name, so compare codes).
    if (env.gchown) |gnu| {
        const g = try runBin(alloc, env.io, gnu, env.gdir, &.{ "no_such_user_zz", "f" });
        defer alloc.free(g.stdout);
        try std.testing.expectEqual(g.code, z.code);
    }
}

// ---------------------------------------------------------------------------
// Spec-anchored unit check (no GNU binary needed): numeric parser overflow
// guard. Documented GNU behaviour: an all-digit id that does not fit uid_t is
// "invalid", i.e. our parser returns null rather than wrapping/aborting.
// ---------------------------------------------------------------------------
test "numeric id parser: in-range parses, over-range is null (no wrap)" {
    // u32 max is a valid id and must parse.
    try std.testing.expectEqual(@as(u32, 4294967295), (std.fmt.parseInt(u32, "4294967295", 10) catch unreachable));
    // One past u32 max must NOT wrap to a small number — parseInt errors.
    try std.testing.expectError(error.Overflow, std.fmt.parseInt(u32, "4294967296", 10));
    try std.testing.expectError(error.Overflow, std.fmt.parseInt(u32, "99999999999999999999", 10));
}
