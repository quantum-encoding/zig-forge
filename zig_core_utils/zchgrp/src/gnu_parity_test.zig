//! Externally-anchored GNU-parity tests for zchgrp.
//!
//! Every "matches GNU" case is anchored against the REAL GNU `chgrp` binary
//! (GNU coreutils 9.10, /opt/homebrew/opt/coreutils/libexec/gnubin/chgrp). For
//! each case we build TWO identical fixture trees, run the freshly built
//! `zchgrp` over one and the reference `chgrp` over the other with identical
//! argv, and assert:
//!   * byte-identical stdout (the -v/-c change/retain diagnostics),
//!   * identical process exit code, and
//!   * identical resulting gid on every path we name.
//! The expected bytes/gids therefore come from a program zchgrp's author did
//! not write. This is a true external anchor, not a roundtrip.
//!
//! stderr is deliberately NOT byte-compared: GNU prefixes it with the invoked
//! program path and locale-quotes operands (‘…’ vs '…'), so the bytes are
//! environment-dependent. Error-path cases instead pin zchgrp's own stderr/exit
//! with the documented GNU behavior cited in-source (literal anchors).
//!
//! Group changes are performed only between groups the running user is actually
//! a member of (its primary gid + one supplementary gid), so the suite passes
//! without root. If the user belongs to only one group, the change/verbose
//! cases SKIP rather than silently pass.
//!
//! If the GNU reference binary is not installed, the live-diff cases SKIP.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const zchgrp_bin = build_options.zchgrp_bin;

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/chgrp",
    "/opt/homebrew/bin/gchgrp",
    "/usr/local/opt/coreutils/libexec/gnubin/chgrp",
    "/usr/local/bin/gchgrp",
};

// ---------------------------------------------------------------------------
// gid discovery + lstat (same struct layout as src/main.zig)
// ---------------------------------------------------------------------------

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
        atim: std.c.timespec,
        mtim: std.c.timespec,
        ctim: std.c.timespec,
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
        atim: std.c.timespec,
        mtim: std.c.timespec,
        ctim: std.c.timespec,
        birthtim: std.c.timespec,
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
extern "c" fn getgid() u32;
extern "c" fn getgroups(size: c_int, list: [*]u32) c_int;

fn gidOf(gpa: std.mem.Allocator, path: []const u8) !u32 {
    const z = try gpa.dupeZ(u8, path);
    defer gpa.free(z);
    var s: Stat = undefined;
    if (lstat(z.ptr, &s) != 0) return error.LstatFailed;
    return s.gid;
}

/// Two distinct gids the current user is a member of: {from, to}. null if the
/// user belongs to only one group (nothing to change between without root).
fn usableGids() ?[2]u32 {
    const primary = getgid();
    var buf: [64]u32 = undefined;
    const n = getgroups(@intCast(buf.len), &buf);
    if (n <= 0) return null;
    var i: usize = 0;
    while (i < @as(usize, @intCast(n))) : (i += 1) {
        if (buf[i] != primary) return .{ buf[i], primary };
    }
    return null;
}

// ---------------------------------------------------------------------------
// process runner
// ---------------------------------------------------------------------------

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |c| c,
        else => 255,
    };
}

const Out = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,
    gpa: std.mem.Allocator,
    fn deinit(self: *Out) void {
        self.gpa.free(self.stdout);
        self.gpa.free(self.stderr);
    }
};

fn run(gpa: std.mem.Allocator, argv: []const []const u8) !Out {
    const res = try std.process.run(gpa, std.testing.io, .{ .argv = argv });
    return .{ .stdout = res.stdout, .stderr = res.stderr, .code = exitCode(res.term), .gpa = gpa };
}

fn firstGnu() ?[]const u8 {
    const io = std.testing.io;
    for (gnu_candidates) |p| {
        std.Io.Dir.accessAbsolute(io, p, .{}) catch continue;
        return p;
    }
    return null;
}

var base_counter: u64 = 0;

/// Replace every literal "{s}" token in `shape` with `base` (runtime, since the
/// shape strings are values not comptime format strings).
fn expandShape(gpa: std.mem.Allocator, shape: []const u8, base: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < shape.len) {
        if (std.mem.startsWith(u8, shape[i..], "{s}")) {
            try out.appendSlice(gpa, base);
            i += 3;
        } else {
            try out.append(gpa, shape[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Build a unique absolute scratch directory under $TMPDIR. Caller frees the
/// returned path and is responsible for the tree living under it.
fn makeBase(gpa: std.mem.Allocator) ![]u8 {
    const tmp = if (std.c.getenv("TMPDIR")) |p| std.mem.span(p) else "/tmp/";
    const sep: []const u8 = if (tmp.len > 0 and tmp[tmp.len - 1] == '/') "" else "/";
    base_counter += 1;
    const salt: u64 = (@as(u64, @intCast(std.c.getpid())) << 24) ^ base_counter;
    const base = try std.fmt.allocPrint(gpa, "{s}{s}zchgrp_par_{x}", .{ tmp, sep, salt });
    var mk = try run(gpa, &.{ "/bin/mkdir", "-p", base });
    mk.deinit();
    return base;
}

fn removeTree(gpa: std.mem.Allocator, path: []const u8) void {
    // chmod first so an unreadable fixture dir can still be torn down.
    var c1 = run(gpa, &.{ "/bin/chmod", "-R", "u+rwx", path }) catch return;
    c1.deinit();
    var r = run(gpa, &.{ "/bin/rm", "-rf", path }) catch return;
    r.deinit();
}

fn sh(gpa: std.mem.Allocator, script: []const u8) !void {
    // Test-harness only: the script is fully static/test-controlled. This does
    // not run any external/untrusted input (SHELL-CHILD applies to shipped code).
    var o = try run(gpa, &.{ "/bin/sh", "-c", script });
    defer o.deinit();
    if (o.code != 0) {
        std.debug.print("setup script failed ({d}): {s}\nstderr: {s}\n", .{ o.code, script, o.stderr });
        return error.SetupFailed;
    }
}

// ---------------------------------------------------------------------------
// Literal anchors (no fs group change needed) — documented GNU behavior pinned
// ---------------------------------------------------------------------------

/// Run zchgrp with argv and assert exact stdout + exit code.
fn expectZ(gpa: std.mem.Allocator, argv: []const []const u8, want_stdout: []const u8, want_code: u8) !void {
    var full: std.ArrayListUnmanaged([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.append(gpa, zchgrp_bin);
    try full.appendSlice(gpa, argv);
    var o = try run(gpa, full.items);
    defer o.deinit();
    std.testing.expectEqualSlices(u8, want_stdout, o.stdout) catch |e| {
        std.debug.print("stdout mismatch argv={any}\n  want: [{s}]\n  got:  [{s}]\n", .{ argv, want_stdout, o.stdout });
        return e;
    };
    try std.testing.expectEqual(want_code, o.code);
}

test "overflow numeric gid is 'invalid group' exit 1 (was integer-overflow panic, exit 134)" {
    // GNU: `chgrp 99999999999 f` -> exit 1, "invalid group". The pre-fix zchgrp
    // accumulated gid*10 on a u32 and aborted (SIGABRT, exit 134) in a safe build.
    const gpa = std.testing.allocator;
    const base = try makeBase(gpa);
    defer gpa.free(base);
    defer removeTree(gpa, base);
    {
        const scr = try std.fmt.allocPrint(gpa, "touch {s}/f", .{base});
        defer gpa.free(scr);
        try sh(gpa, scr);
    }
    const f = try std.fmt.allocPrint(gpa, "{s}/f", .{base});
    defer gpa.free(f);
    try expectZ(gpa, &.{ "99999999999", f }, "", 1);
    try expectZ(gpa, &.{ "4294967296", f }, "", 1);
}

test "unknown numeric-name group is 'invalid group' exit 1" {
    const gpa = std.testing.allocator;
    const base = try makeBase(gpa);
    defer gpa.free(base);
    defer removeTree(gpa, base);
    {
        const scr = try std.fmt.allocPrint(gpa, "touch {s}/f", .{base});
        defer gpa.free(scr);
        try sh(gpa, scr);
    }
    const f = try std.fmt.allocPrint(gpa, "{s}/f", .{base});
    defer gpa.free(f);
    try expectZ(gpa, &.{ "nosuchgrp_zxq_42", f }, "", 1);
}

test "empty group operand is a no-op success, exit 0 (GNU coreutils chgrp)" {
    // `chgrp '' f` under GNU exits 0 and leaves the group unchanged.
    const gpa = std.testing.allocator;
    const base = try makeBase(gpa);
    defer gpa.free(base);
    defer removeTree(gpa, base);
    {
        const scr = try std.fmt.allocPrint(gpa, "touch {s}/f", .{base});
        defer gpa.free(scr);
        try sh(gpa, scr);
    }
    const f = try std.fmt.allocPrint(gpa, "{s}/f", .{base});
    defer gpa.free(f);
    const before = try gidOf(gpa, f);
    try expectZ(gpa, &.{ "", f }, "", 0);
    try std.testing.expectEqual(before, try gidOf(gpa, f));
}

test "missing operand exits 1" {
    try expectZ(std.testing.allocator, &.{}, "", 1);
}

test "unknown long option exits 1" {
    try expectZ(std.testing.allocator, &.{ "--bogus-xyz", "staff", "f" }, "", 1);
}

// ---------------------------------------------------------------------------
// Live GNU parity — exit-code + stdout diff on non-fs-mutating error paths
// ---------------------------------------------------------------------------

/// Run both binaries with identical trailing argv and compare exit code (and
/// stdout, which for these cases is empty). SKIPs if GNU is missing.
fn expectExitMatchesGnu(gpa: std.mem.Allocator, argv: []const []const u8) !void {
    const gnu = firstGnu() orelse return error.SkipZigTest;

    var za: std.ArrayListUnmanaged([]const u8) = .empty;
    defer za.deinit(gpa);
    try za.append(gpa, zchgrp_bin);
    try za.appendSlice(gpa, argv);

    var ga: std.ArrayListUnmanaged([]const u8) = .empty;
    defer ga.deinit(gpa);
    try ga.append(gpa, gnu);
    try ga.appendSlice(gpa, argv);

    var zr = try run(gpa, za.items);
    defer zr.deinit();
    var gr = try run(gpa, ga.items);
    defer gr.deinit();

    std.testing.expectEqual(gr.code, zr.code) catch |e| {
        std.debug.print("exit mismatch argv={any} gnu={d} zchgrp={d}\n", .{ argv, gr.code, zr.code });
        return e;
    };
    try std.testing.expectEqualSlices(u8, gr.stdout, zr.stdout);
}

test "GNU parity: invalid group exit code" {
    const gpa = std.testing.allocator;
    const base = try makeBase(gpa);
    defer gpa.free(base);
    defer removeTree(gpa, base);
    {
        const scr = try std.fmt.allocPrint(gpa, "touch {s}/f", .{base});
        defer gpa.free(scr);
        try sh(gpa, scr);
    }
    const f = try std.fmt.allocPrint(gpa, "{s}/f", .{base});
    defer gpa.free(f);
    try expectExitMatchesGnu(gpa, &.{ "nosuchgrp_zxq_42", f });
    try expectExitMatchesGnu(gpa, &.{ "99999999999", f });
}

test "GNU parity: missing operand exit code" {
    try expectExitMatchesGnu(std.testing.allocator, &.{});
}

// ---------------------------------------------------------------------------
// Live GNU parity — group changes on fixture trees (needs 2 usable groups)
// ---------------------------------------------------------------------------

const Fixture = struct {
    root: []u8, // absolute path to the operand passed to the util
    base: []u8, // absolute scratch dir to tear down
    gpa: std.mem.Allocator,
    fn deinit(self: *Fixture) void {
        removeTree(self.gpa, self.base);
        self.gpa.free(self.root);
        self.gpa.free(self.base);
    }
};

/// Build one fixture tree. `shape` is a printf template with a single {s} where
/// the tree root goes; it is run under /bin/sh to create files/links and MUST
/// leave everything at gid `from`. Returns the root path to operate on.
fn buildTree(gpa: std.mem.Allocator, shape: []const u8, root_leaf: []const u8, from: u32) !Fixture {
    const base = try makeBase(gpa);
    errdefer {
        removeTree(gpa, base);
        gpa.free(base);
    }
    const root = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, root_leaf });
    errdefer gpa.free(root);

    const script = try expandShape(gpa, shape, base);
    defer gpa.free(script);
    try sh(gpa, script);

    // Initialize the whole tree to `from` using the GNU binary (recursively,
    // no symlink traversal) so both trees start identical.
    const gnu = firstGnu() orelse "/usr/sbin/chgrp";
    const init_cmd = try std.fmt.allocPrint(gpa, "'{s}' -R -h {d} {s}", .{ gnu, from, base });
    defer gpa.free(init_cmd);
    try sh(gpa, init_cmd);

    return .{ .root = root, .base = base, .gpa = gpa };
}

/// Core group-change parity: build the same `shape` twice, run zchgrp on one and
/// GNU chgrp on the other with `flags ++ root`, and assert identical stdout,
/// exit code, and gid on each path in `check_leaves` (relative to base).
fn expectChangeMatchesGnu(
    shape: []const u8,
    root_leaf: []const u8,
    flags: []const []const u8,
    check_leaves: []const []const u8,
    init_from_to: enum { from, to }, // initialize tree to `from` or already `to`
) !void {
    const gpa = std.testing.allocator;
    const gnu = firstGnu() orelse return error.SkipZigTest;
    const gids = usableGids() orelse return error.SkipZigTest;
    const from = gids[0];
    const to = gids[1];
    const init_gid = if (init_from_to == .from) from else to;

    var zf = try buildTree(gpa, shape, root_leaf, init_gid);
    defer zf.deinit();
    var gf = try buildTree(gpa, shape, root_leaf, init_gid);
    defer gf.deinit();

    const to_str = try std.fmt.allocPrint(gpa, "{d}", .{to});
    defer gpa.free(to_str);

    var za: std.ArrayListUnmanaged([]const u8) = .empty;
    defer za.deinit(gpa);
    try za.append(gpa, zchgrp_bin);
    try za.appendSlice(gpa, flags);
    try za.append(gpa, to_str);
    try za.append(gpa, zf.root);

    var ga: std.ArrayListUnmanaged([]const u8) = .empty;
    defer ga.deinit(gpa);
    try ga.append(gpa, gnu);
    try ga.appendSlice(gpa, flags);
    try ga.append(gpa, to_str);
    try ga.append(gpa, gf.root);

    var zr = try run(gpa, za.items);
    defer zr.deinit();
    var gr = try run(gpa, ga.items);
    defer gr.deinit();

    // stdout: -v/-c diagnostics. GNU and zchgrp reference each tree by its own
    // absolute path, so normalize the base prefix out before comparing.
    const zout = try normalizeBase(gpa, zr.stdout, zf.base);
    defer gpa.free(zout);
    const gout = try normalizeBase(gpa, gr.stdout, gf.base);
    defer gpa.free(gout);

    std.testing.expectEqualSlices(u8, gout, zout) catch |e| {
        std.debug.print("stdout mismatch flags={any}\n  gnu:    [{s}]\n  zchgrp: [{s}]\n", .{ flags, gout, zout });
        return e;
    };
    std.testing.expectEqual(gr.code, zr.code) catch |e| {
        std.debug.print("exit mismatch flags={any} gnu={d} zchgrp={d}\n  gnu stderr: {s}\n  z stderr: {s}\n", .{ flags, gr.code, zr.code, gr.stderr, zr.stderr });
        return e;
    };

    for (check_leaves) |leaf| {
        const zp = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ zf.base, leaf });
        defer gpa.free(zp);
        const gp = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ gf.base, leaf });
        defer gpa.free(gp);
        const zg = try gidOf(gpa, zp);
        const gg = try gidOf(gpa, gp);
        std.testing.expectEqual(gg, zg) catch |e| {
            std.debug.print("gid mismatch at {s}: gnu={d} zchgrp={d} (from={d} to={d})\n", .{ leaf, gg, zg, from, to });
            return e;
        };
    }
}

/// Replace every occurrence of `base` in `s` with the literal token "BASE" so
/// two trees under different scratch dirs compare equal.
fn normalizeBase(gpa: std.mem.Allocator, s: []const u8, base: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        if (std.mem.startsWith(u8, s[i..], base)) {
            try out.appendSlice(gpa, "BASE");
            i += base.len;
        } else {
            try out.append(gpa, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

test "GNU parity: -v change diagnostic + resulting gid on a plain file" {
    // Anchors the corrected wording "changed group of 'X' from A to B"
    // (pre-fix zchgrp emitted "group of 'X' changed from A to B").
    try expectChangeMatchesGnu(
        "touch {s}/f",
        "f",
        &.{"-v"},
        &.{"f"},
        .from,
    );
}

test "GNU parity: -v retained diagnostic when no change" {
    try expectChangeMatchesGnu(
        "touch {s}/f",
        "f",
        &.{"-v"},
        &.{"f"},
        .to, // already the target group -> "retained as"
    );
}

test "GNU parity: -c reports only on change" {
    try expectChangeMatchesGnu("touch {s}/f", "f", &.{"-c"}, &.{"f"}, .from);
    try expectChangeMatchesGnu("touch {s}/f", "f", &.{"-c"}, &.{"f"}, .to);
}

test "GNU parity: -R recurses into real subdirectories" {
    try expectChangeMatchesGnu(
        "mkdir -p {s}/r/sub && touch {s}/r/a {s}/r/sub/b",
        "r",
        &.{"-R"},
        &.{ "r", "r/a", "r/sub", "r/sub/b" },
        .from,
    );
}

test "GNU parity SECURITY: -R does not traverse symlinked dirs; lchowns the link, leaves outside-tree files untouched" {
    // The high-severity finding: build rroot with a symlink to a sibling
    // `other/` dir. GNU default (-P) lchowns the link and does NOT descend, so
    // other/victim keeps its group. Pre-fix zchgrp followed the link and changed
    // other/victim. We assert zchgrp's gids match GNU's on every path, including
    // the outside-tree victim.
    try expectChangeMatchesGnu(
        "mkdir -p {s}/rroot {s}/other && touch {s}/other/victim {s}/rroot/realfile && ln -s ../other {s}/rroot/symdir && ln -s realfile {s}/rroot/symfile",
        "rroot",
        &.{ "-R", "-v" },
        &.{ "rroot", "rroot/realfile", "rroot/symdir", "rroot/symfile", "other", "other/victim" },
        .from,
    );
}

test "GNU parity: non-recursive symlink is dereferenced by default; -h affects the link" {
    // Default: change the referent (target) of a symlink.
    try expectChangeMatchesGnu(
        "touch {s}/tgt && ln -s tgt {s}/lnk",
        "lnk",
        &.{"-v"},
        &.{ "tgt", "lnk" },
        .from,
    );
    // -h: change the link itself, leaving the target alone.
    try expectChangeMatchesGnu(
        "touch {s}/tgt && ln -s tgt {s}/lnk",
        "lnk",
        &.{ "-h", "-v" },
        &.{ "tgt", "lnk" },
        .from,
    );
}

test "GNU parity: option permutation after the group operand (<group> -v FILE)" {
    // `chgrp <group> -v FILE` must treat -v as a flag, not a filename. Pre-fix
    // zchgrp stopped option parsing at the group operand and treated -v as a
    // file ("cannot access -v"). We run BOTH binaries as `<group> -v <root>` and
    // require identical stdout + exit + resulting gid.
    const gpa = std.testing.allocator;
    const gnu = firstGnu() orelse return error.SkipZigTest;
    const gids = usableGids() orelse return error.SkipZigTest;
    const from = gids[0];
    const to = gids[1];

    var zf = try buildTree(gpa, "touch {s}/f", "f", from);
    defer zf.deinit();
    var gf = try buildTree(gpa, "touch {s}/f", "f", from);
    defer gf.deinit();

    const to_str = try std.fmt.allocPrint(gpa, "{d}", .{to});
    defer gpa.free(to_str);

    var zr = try run(gpa, &.{ zchgrp_bin, to_str, "-v", zf.root });
    defer zr.deinit();
    var gr = try run(gpa, &.{ gnu, to_str, "-v", gf.root });
    defer gr.deinit();

    const zout = try normalizeBase(gpa, zr.stdout, zf.base);
    defer gpa.free(zout);
    const gout = try normalizeBase(gpa, gr.stdout, gf.base);
    defer gpa.free(gout);

    try std.testing.expectEqualSlices(u8, gout, zout);
    try std.testing.expectEqual(gr.code, zr.code);
    try std.testing.expectEqual(try gidOf(gpa, gf.root), try gidOf(gpa, zf.root));
    // The change must actually have happened (permutation didn't swallow the op).
    try std.testing.expectEqual(to, try gidOf(gpa, zf.root));
}

test "GNU parity: -- terminator ends option parsing" {
    // `chgrp -- <group> FILE` must succeed treating <group> as the group.
    try expectChangeMatchesGnu("touch {s}/f", "f", &.{"--"}, &.{"f"}, .from);
}
