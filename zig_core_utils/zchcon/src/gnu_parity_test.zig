//! Externally-anchored behaviour tests for zchcon.
//!
//! GNU `chcon` is a SELinux tool: it exists only on Linux and there is no GNU
//! `chcon`/`gchcon` binary on this macOS build host to live-diff against (unlike
//! zchgrp/zchmod, which diff the real GNU binary). So every expectation here is
//! anchored to *documented* GNU/SELinux behaviour, with the expected bytes
//! written LITERALLY in the test and the authoritative source cited in-comment.
//! None of these are roundtrip (encode∘decode==x) tests — each pins concrete
//! output bytes / exit codes that come from the SELinux spec and GNU coreutils
//! docs, not from zchcon's own implementation.
//!
//! The observable substrate is the `security.selinux` extended attribute, which
//! macOS stores and returns verbatim (confirmed on this host), so we can drive
//! the real built `zchcon` binary end-to-end: set a known context, run zchcon,
//! and read the raw xattr bytes back to compare against the documented result.
//!
//! Anchored references:
//!   * SELinux security context grammar `user:role:type[:range]` where ONLY the
//!     first three ':' are field separators and the MLS/MCS range field may
//!     itself contain ':' (e.g. `s0-s0:c0.c1023`) — libselinux `context_new`
//!     (selinux/context.h) and `chcon(1)` "CONTEXT ... user:role:type:range".
//!   * GNU coreutils `chcon -R, --recursive` "operate on files and directories
//!     recursively" — coreutils.info / chcon(1).
//!   * GNU coreutils writes `--help`/`--version` to STDOUT and exits 0 —
//!     coreutils "Common options" (info coreutils 'Common options').
//!   * libselinux stores the context value NUL-terminated in `security.selinux`
//!     (setxattr size includes the trailing NUL) — libselinux setfilecon.
//!   * POSIX Utility Syntax Guideline 10 / getopt: `--` terminates options;
//!     clustered short options (`-Rv`) are equivalent to `-R -v`.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const zchcon_bin = build_options.zchcon_bin;

const SELINUX_XATTR = "security.selinux";

// ---------------------------------------------------------------------------
// raw xattr read/write (host-correct fixed-arity externs; the variadic form
// silently corrupts args on Apple arm64 — the same bug the util itself carried)
// ---------------------------------------------------------------------------

const is_macos = builtin.os.tag == .macos;

fn rawSet(path: [*:0]const u8, value: []const u8) bool {
    if (is_macos) {
        const f = @extern(*const fn ([*:0]const u8, [*:0]const u8, [*]const u8, usize, u32, c_int) callconv(.c) c_int, .{ .name = "setxattr" });
        return f(path, SELINUX_XATTR, value.ptr, value.len, 0, 0) == 0;
    } else {
        const f = @extern(*const fn ([*:0]const u8, [*:0]const u8, [*]const u8, usize, c_int) callconv(.c) c_int, .{ .name = "setxattr" });
        return f(path, SELINUX_XATTR, value.ptr, value.len, 0) == 0;
    }
}

var raw_buf: [1024]u8 = undefined;

/// Return the raw bytes of the security.selinux xattr, INCLUDING any trailing
/// NUL (so tests can assert on NUL-termination). null if unset.
fn rawGet(path: [*:0]const u8) ?[]const u8 {
    const n = blk: {
        if (is_macos) {
            const f = @extern(*const fn ([*:0]const u8, [*:0]const u8, ?[*]u8, usize, u32, c_int) callconv(.c) isize, .{ .name = "getxattr" });
            break :blk f(path, SELINUX_XATTR, &raw_buf, raw_buf.len, 0, 0);
        } else {
            const f = @extern(*const fn ([*:0]const u8, [*:0]const u8, ?[*]u8, usize) callconv(.c) isize, .{ .name = "getxattr" });
            break :blk f(path, SELINUX_XATTR, &raw_buf, raw_buf.len);
        }
    };
    if (n < 0) return null;
    return raw_buf[0..@intCast(n)];
}

/// Strip a single trailing NUL, if present.
fn stripNul(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == 0) return s[0 .. s.len - 1];
    return s;
}

// ---------------------------------------------------------------------------
// process runner + scratch fixtures
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

fn runIn(gpa: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !Out {
    const res = try std.process.run(gpa, std.testing.io, .{ .argv = argv, .cwd = .{ .path = cwd } });
    return .{ .stdout = res.stdout, .stderr = res.stderr, .code = exitCode(res.term), .gpa = gpa };
}

extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]u8;

/// zchcon_bin from build_options is relative to the build root; when we chdir a
/// child via `cwd`, resolve it to an absolute path first. Caller frees.
fn absBin(gpa: std.mem.Allocator) ![]u8 {
    if (zchcon_bin.len > 0 and zchcon_bin[0] == '/') return gpa.dupe(u8, zchcon_bin);
    var buf: [4096]u8 = undefined;
    const cwd = getcwd(&buf, buf.len) orelse return error.GetCwdFailed;
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ std.mem.span(cwd), zchcon_bin });
}

var base_counter: u64 = 0;

/// Unique absolute scratch dir under $TMPDIR. Caller tears it down.
fn makeBase(gpa: std.mem.Allocator) ![]u8 {
    const tmp = if (std.c.getenv("TMPDIR")) |p| std.mem.span(p) else "/tmp/";
    const sep: []const u8 = if (tmp.len > 0 and tmp[tmp.len - 1] == '/') "" else "/";
    base_counter += 1;
    const salt: u64 = (@as(u64, @intCast(std.c.getpid())) << 24) ^ base_counter;
    const base = try std.fmt.allocPrint(gpa, "{s}{s}zchcon_par_{x}", .{ tmp, sep, salt });
    var mk = try run(gpa, &.{ "/bin/mkdir", "-p", base });
    mk.deinit();
    return base;
}

fn removeTree(gpa: std.mem.Allocator, path: []const u8) void {
    var r = run(gpa, &.{ "/bin/rm", "-rf", path }) catch return;
    r.deinit();
}

/// touch a file at base/leaf and set its initial selinux context. Returns the
/// owned absolute path.
fn mkFile(gpa: std.mem.Allocator, base: []const u8, leaf: []const u8, ctx: []const u8) ![]u8 {
    const p = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, leaf });
    var t = try run(gpa, &.{ "/usr/bin/touch", p });
    t.deinit();
    const pz = try gpa.dupeZ(u8, p);
    defer gpa.free(pz);
    if (!rawSet(pz, ctx)) return error.SetXattrFailed;
    return p;
}

fn ctxOf(gpa: std.mem.Allocator, path: []const u8) !?[]const u8 {
    const pz = try gpa.dupeZ(u8, path);
    defer gpa.free(pz);
    return rawGet(pz);
}

/// Run the built zchcon with argv, return Out.
fn zchcon(gpa: std.mem.Allocator, argv: []const []const u8) !Out {
    var full: std.ArrayListUnmanaged([]const u8) = .empty;
    defer full.deinit(gpa);
    try full.append(gpa, zchcon_bin);
    try full.appendSlice(gpa, argv);
    return run(gpa, full.items);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "MLS/MCS range field with ':' is preserved verbatim when -t changes type" {
    // ANCHOR: SELinux security context = user:role:type[:range]. Only the FIRST
    // THREE ':' are field separators; the range (MLS/MCS) field may itself
    // contain ':' — e.g. `s0-s0:c0.c1023` (an MLS low-high with a category set).
    // Ref: libselinux context_new (selinux/context.h) parses exactly three
    // colons; chcon(1) documents CONTEXT as "user:role:type:range". Changing
    // only the type MUST leave the full range intact.
    const gpa = std.testing.allocator;
    const base = try makeBase(gpa);
    defer gpa.free(base);
    defer removeTree(gpa, base);

    const f = try mkFile(gpa, base, "f", "staff_u:object_r:user_home_t:s0-s0:c0.c1023");
    defer gpa.free(f);

    var o = try zchcon(gpa, &.{ "-t", "httpd_sys_content_t", f });
    defer o.deinit();
    try std.testing.expectEqual(@as(u8, 0), o.code);

    const got = stripNul((try ctxOf(gpa, f)).?);
    // Documented expected bytes — range field carried through untouched.
    try std.testing.expectEqualStrings("staff_u:object_r:httpd_sys_content_t:s0-s0:c0.c1023", got);
}

test "individual -u/-r/-l edits keep the colon-bearing range field" {
    const gpa = std.testing.allocator;
    const base = try makeBase(gpa);
    defer gpa.free(base);
    defer removeTree(gpa, base);

    const f = try mkFile(gpa, base, "f", "staff_u:staff_r:staff_t:s0-s0:c0.c1023");
    defer gpa.free(f);

    // Change user only.
    {
        var o = try zchcon(gpa, &.{ "-u", "system_u", f });
        defer o.deinit();
        try std.testing.expectEqual(@as(u8, 0), o.code);
        try std.testing.expectEqualStrings(
            "system_u:staff_r:staff_t:s0-s0:c0.c1023",
            stripNul((try ctxOf(gpa, f)).?),
        );
    }
    // Then change the range explicitly (a colon-bearing value passed in).
    {
        var o = try zchcon(gpa, &.{ "-l", "s0-s0:c1.c2", f });
        defer o.deinit();
        try std.testing.expectEqual(@as(u8, 0), o.code);
        try std.testing.expectEqualStrings(
            "system_u:staff_r:staff_t:s0-s0:c1.c2",
            stripNul((try ctxOf(gpa, f)).?),
        );
    }
}

test "full CONTEXT operand is written verbatim WITH a trailing NUL (libselinux convention)" {
    // ANCHOR: libselinux writes the context string NUL-terminated into the
    // security.selinux xattr (the stored length includes the trailing '\0').
    // GNU chcon uses libselinux setfilecon under the hood. We assert both the
    // exact string and the presence of the terminator byte.
    const gpa = std.testing.allocator;
    const base = try makeBase(gpa);
    defer gpa.free(base);
    defer removeTree(gpa, base);

    const f = try mkFile(gpa, base, "f", "old_u:old_r:old_t:s0");
    defer gpa.free(f);

    const want = "system_u:object_r:httpd_sys_content_t:s0";
    var o = try zchcon(gpa, &.{ want, f });
    defer o.deinit();
    try std.testing.expectEqual(@as(u8, 0), o.code);

    const raw = (try ctxOf(gpa, f)).?;
    try std.testing.expectEqual(want.len + 1, raw.len); // includes the NUL
    try std.testing.expectEqual(@as(u8, 0), raw[raw.len - 1]); // trailing NUL
    try std.testing.expectEqualStrings(want, raw[0 .. raw.len - 1]);
}

test "-R recurses into every file and subdirectory (GNU chcon -R)" {
    // ANCHOR: chcon(1) `-R, --recursive`: "operate on files and directories
    // recursively." The whole subtree must receive the new context, not just
    // the named directory.
    const gpa = std.testing.allocator;
    const base = try makeBase(gpa);
    defer gpa.free(base);
    defer removeTree(gpa, base);

    // base/d, base/d/a, base/d/sub, base/d/sub/b — all start at old_t.
    {
        const d = try std.fmt.allocPrint(gpa, "{s}/d/sub", .{base});
        defer gpa.free(d);
        var m = try run(gpa, &.{ "/bin/mkdir", "-p", d });
        m.deinit();
    }
    const dctx = "system_u:object_r:old_t:s0";
    const dd = try mkDir(gpa, base, "d", dctx);
    defer gpa.free(dd);
    const da = try mkFile(gpa, base, "d/a", dctx);
    defer gpa.free(da);
    const dsub = try mkDir(gpa, base, "d/sub", dctx);
    defer gpa.free(dsub);
    const db = try mkFile(gpa, base, "d/sub/b", dctx);
    defer gpa.free(db);

    var o = try zchcon(gpa, &.{ "-R", "-t", "httpd_sys_content_t", dd });
    defer o.deinit();
    try std.testing.expectEqual(@as(u8, 0), o.code);

    const want = "system_u:object_r:httpd_sys_content_t:s0";
    for ([_][]const u8{ dd, da, dsub, db }) |p| {
        const got = stripNul((try ctxOf(gpa, p)).?);
        std.testing.expectEqualStrings(want, got) catch |e| {
            std.debug.print("path {s} not relabeled: got [{s}]\n", .{ p, got });
            return e;
        };
    }
}

test "without -R a directory operand is NOT descended into" {
    // ANCHOR: chcon default (no -R) changes only the named operands. The
    // directory itself is relabeled but its children are left untouched.
    const gpa = std.testing.allocator;
    const base = try makeBase(gpa);
    defer gpa.free(base);
    defer removeTree(gpa, base);

    {
        const d = try std.fmt.allocPrint(gpa, "{s}/d", .{base});
        defer gpa.free(d);
        var m = try run(gpa, &.{ "/bin/mkdir", "-p", d });
        m.deinit();
    }
    const dctx = "system_u:object_r:old_t:s0";
    const dd = try mkDir(gpa, base, "d", dctx);
    defer gpa.free(dd);
    const da = try mkFile(gpa, base, "d/a", dctx);
    defer gpa.free(da);

    var o = try zchcon(gpa, &.{ "-t", "httpd_sys_content_t", dd });
    defer o.deinit();
    try std.testing.expectEqual(@as(u8, 0), o.code);

    // dir relabeled...
    try std.testing.expectEqualStrings(
        "system_u:object_r:httpd_sys_content_t:s0",
        stripNul((try ctxOf(gpa, dd)).?),
    );
    // ...child untouched.
    try std.testing.expectEqualStrings(dctx, stripNul((try ctxOf(gpa, da)).?));
}

test "clustered short options -Rv are decoded as -R -v (getopt bundling)" {
    // ANCHOR: POSIX Utility Syntax Guideline; GNU getopt accepts bundled short
    // flags, so `-Rv` == `-R -v`. Recursion must happen AND a per-file verbose
    // diagnostic must be emitted.
    const gpa = std.testing.allocator;
    const base = try makeBase(gpa);
    defer gpa.free(base);
    defer removeTree(gpa, base);

    {
        const d = try std.fmt.allocPrint(gpa, "{s}/d", .{base});
        defer gpa.free(d);
        var m = try run(gpa, &.{ "/bin/mkdir", "-p", d });
        m.deinit();
    }
    const dctx = "system_u:object_r:old_t:s0";
    const dd = try mkDir(gpa, base, "d", dctx);
    defer gpa.free(dd);
    const da = try mkFile(gpa, base, "d/a", dctx);
    defer gpa.free(da);

    var o = try zchcon(gpa, &.{ "-Rv", "-t", "httpd_sys_content_t", dd });
    defer o.deinit();
    try std.testing.expectEqual(@as(u8, 0), o.code);

    // recursion happened (child relabeled)
    try std.testing.expectEqualStrings(
        "system_u:object_r:httpd_sys_content_t:s0",
        stripNul((try ctxOf(gpa, da)).?),
    );
    // verbose diagnostic mentions the child path (the -v half of the cluster)
    try std.testing.expect(std.mem.indexOf(u8, o.stderr, "d/a") != null);
}

test "-- terminates option parsing so a file named '-t' becomes an operand" {
    // ANCHOR: POSIX Guideline 10 / getopt: `--` ends option processing; the
    // following argument is an operand even if it begins with '-'. Without it,
    // a file literally named `-t` can never be addressed.
    const gpa = std.testing.allocator;
    const base = try makeBase(gpa);
    defer gpa.free(base);
    defer removeTree(gpa, base);

    // create base/-t and label it
    const dashfile = try mkFile(gpa, base, "-t", "old_u:old_r:old_t:s0");
    defer gpa.free(dashfile);

    // run from inside base so `-t` is the relative operand
    const bin = try absBin(gpa);
    defer gpa.free(bin);
    var o = try runIn(gpa, base, &.{ bin, "system_u:object_r:new_t:s0", "--", "-t" });
    defer o.deinit();
    try std.testing.expectEqual(@as(u8, 0), o.code);

    const full = try std.fmt.allocPrint(gpa, "{s}/-t", .{base});
    defer gpa.free(full);
    try std.testing.expectEqualStrings(
        "system_u:object_r:new_t:s0",
        stripNul((try ctxOf(gpa, full)).?),
    );
}

test "--version and --help go to STDOUT and exit 0 (GNU coreutils convention)" {
    // ANCHOR: GNU coreutils "Common options" — --help and --version are written
    // to standard output and the program exits successfully (0). A consumer
    // doing `chcon --version | grep ...` must see bytes on stdout.
    const gpa = std.testing.allocator;
    {
        var o = try zchcon(gpa, &.{"--version"});
        defer o.deinit();
        try std.testing.expectEqual(@as(u8, 0), o.code);
        try std.testing.expect(std.mem.indexOf(u8, o.stdout, "1.0.0") != null);
        try std.testing.expectEqual(@as(usize, 0), o.stderr.len);
    }
    {
        var o = try zchcon(gpa, &.{"--help"});
        defer o.deinit();
        try std.testing.expectEqual(@as(u8, 0), o.code);
        try std.testing.expect(std.mem.indexOf(u8, o.stdout, "Usage:") != null);
        try std.testing.expectEqual(@as(usize, 0), o.stderr.len);
    }
}

test "missing operand is exit 1 (GNU chcon)" {
    // ANCHOR: chcon with no FILE prints "missing operand" to stderr and exits 1.
    const gpa = std.testing.allocator;
    var o = try zchcon(gpa, &.{"system_u:object_r:t_t:s0"});
    defer o.deinit();
    try std.testing.expectEqual(@as(u8, 1), o.code);
    try std.testing.expectEqual(@as(usize, 0), o.stdout.len);
}

test "more than 64 operands are all relabeled (no silent fixed-cap drop)" {
    // The pre-fix util used files[64] and silently discarded operands 64.. with
    // exit 0. GNU chcon handles unbounded operand lists. We relabel 100 files in
    // one invocation and assert every one changed.
    const gpa = std.testing.allocator;
    const base = try makeBase(gpa);
    defer gpa.free(base);
    defer removeTree(gpa, base);

    var paths: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const leaf = try std.fmt.allocPrint(gpa, "f{d}", .{i});
        defer gpa.free(leaf);
        const p = try mkFile(gpa, base, leaf, "old_u:old_r:old_t:s0");
        try paths.append(gpa, p);
    }

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "system_u:object_r:new_t:s0");
    for (paths.items) |p| try argv.append(gpa, p);

    var o = try zchcon(gpa, argv.items);
    defer o.deinit();
    try std.testing.expectEqual(@as(u8, 0), o.code);

    for (paths.items) |p| {
        try std.testing.expectEqualStrings(
            "system_u:object_r:new_t:s0",
            stripNul((try ctxOf(gpa, p)).?),
        );
    }
}

// mkDir: like mkFile but for an already-created directory (dir made by caller
// via mkdir -p); just sets the initial context. Returns owned abs path.
fn mkDir(gpa: std.mem.Allocator, base: []const u8, leaf: []const u8, ctx: []const u8) ![]u8 {
    const p = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, leaf });
    const pz = try gpa.dupeZ(u8, p);
    defer gpa.free(pz);
    if (!rawSet(pz, ctx)) return error.SetXattrFailed;
    return p;
}
