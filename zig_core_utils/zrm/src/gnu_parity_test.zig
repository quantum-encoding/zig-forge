//! Externally-anchored parity tests for `zrm`.
//!
//! The external anchor is the REAL GNU coreutils `rm` binary (Homebrew's `grm`,
//! coreutils 9.10). Each test runs the SAME operation with both `zrm` and `grm`
//! on identical scratch trees and diffs the observable result (stdout / stderr /
//! exit status). These are NOT roundtrip tests: the expected bytes come from a
//! third-party implementation the zrm author did not write (zig-forge golden rule).
//!
//! Where the two tools legitimately differ only in the program-name prefix
//! ("zrm:" vs "grm:"/argv0), the prefix is stripped before comparison; the
//! message body must still match GNU byte-for-byte.
//!
//! The verbose test deliberately redirects stdout to a REGULAR FILE, because the
//! historical corruption bug (positional File.Writer writes rewriting from offset
//! 0) only manifested on a seekable sink — a pipe would have hidden it.
//!
//! If `grm` is not installed, GNU-diff tests SkipZigTest; the safety/behavioral
//! tests still run against documented behavior.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;

const zrm_exe = build_options.zrm_exe;
const grm_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/rm",
    "/opt/homebrew/bin/grm",
    "/usr/local/bin/grm",
};

// The global single-threaded io uses a `.failing` allocator, which cannot back
// process spawning. Build a real one (page-allocator-backed so spawn-internal
// allocations don't trip the testing leak detector) that inherits the parent
// environment block, so `/bin/sh` in the child can still resolve coreutils.
var g_threaded: Io.Threaded = undefined;
var g_init = false;
fn getIo() Io {
    if (!g_init) {
        const env_slice: [:null]const ?[*:0]const u8 = std.mem.span(std.c.environ);
        g_threaded = Io.Threaded.init(std.heap.page_allocator, .{ .environ = .{ .block = .{ .slice = env_slice } } });
        g_init = true;
    }
    return g_threaded.io();
}

fn grmPath() ?[]const u8 {
    const io = getIo();
    for (grm_candidates) |c| {
        Io.Dir.cwd().access(io, c, .{}) catch continue;
        return c;
    }
    return null;
}

const Run = struct {
    out: []u8,
    err: []u8,
    code: i64,
    fn deinit(self: *Run, a: std.mem.Allocator) void {
        a.free(self.out);
        a.free(self.err);
    }
};

/// Run `cmd` under /bin/sh in `cwd`, redirecting stdout/stderr to regular files
/// and the exit status to a third file, then read them back. Using a real shell
/// redirect guarantees stdout is a seekable regular file (reproduces the verbose
/// corruption bug) and matches exactly how a user would capture `rm -v > log`.
fn runShell(a: std.mem.Allocator, cwd: []const u8, cmd: []const u8) !Run {
    const full = try std.fmt.allocPrint(
        a,
        "{s} > .zrm_out 2> .zrm_err; printf %d $? > .zrm_code",
        .{cmd},
    );
    defer a.free(full);
    try shSetup(a, cwd, full);

    return .{
        .out = try readRel(a, cwd, ".zrm_out"),
        .err = try readRel(a, cwd, ".zrm_err"),
        .code = try readCode(a, cwd),
    };
}

/// Run a shell command in `cwd` for its side effects (test setup / teardown).
/// A fixed PATH is exported so coreutils resolve regardless of the (possibly
/// empty) environment the test binary hands the child.
fn shSetup(a: std.mem.Allocator, cwd: []const u8, cmd: []const u8) !void {
    const io = getIo();
    const wrapped = try std.fmt.allocPrint(a, "export PATH=/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin; {s}", .{cmd});
    defer a.free(wrapped);
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", wrapped },
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = try child.wait(io);
}

fn readRel(a: std.mem.Allocator, cwd: []const u8, name: []const u8) ![]u8 {
    const p = try std.fs.path.join(a, &.{ cwd, name });
    defer a.free(p);
    return Io.Dir.cwd().readFileAlloc(getIo(), p, a, .limited(1 << 20));
}

fn readCode(a: std.mem.Allocator, cwd: []const u8) !i64 {
    const raw = try readRel(a, cwd, ".zrm_code");
    defer a.free(raw);
    return std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\r\n"), 10);
}

/// True if `abs_path` exists.
fn exists(abs_path: []const u8) bool {
    Io.Dir.cwd().access(getIo(), abs_path, .{}) catch return false;
    return true;
}

/// Strip a leading "PROG: " program-name prefix from each line so that only the
/// message body is compared. GNU's coreutils errors use the basename ("grm:"),
/// its getopt errors use argv0 (an absolute path); zrm always uses "zrm:". The
/// first ": " on a line delimits the prefix; the body may contain further ": ".
fn stripPrefixes(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(a, '\n');
        first = false;
        const body = if (std.mem.indexOf(u8, line, ": ")) |idx|
            line[idx + 2 ..]
        else
            line;
        try out.appendSlice(a, body);
    }
    return out.toOwnedSlice(a);
}

var scratch_counter: usize = 0;

fn mkScratch(a: std.mem.Allocator, tag: []const u8) ![]u8 {
    const base = "/private/tmp/zrm_parity";
    scratch_counter += 1;
    const dir = try std.fmt.allocPrint(a, "{s}/{s}.{d}", .{ base, tag, scratch_counter });
    // clean + create
    const cmd = try std.fmt.allocPrint(a, "rm -rf '{s}' && mkdir -p '{s}'", .{ dir, dir });
    defer a.free(cmd);
    try shSetup(a, "/", cmd);
    return dir;
}

fn sortedLines(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (l.len == 0) continue;
        try lines.append(a, l);
    }
    std.mem.sort([]const u8, lines.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    for (lines.items) |l| {
        try out.appendSlice(a, l);
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// The HIGH-severity anchor: `rm -v a b c > file` must emit one line per file, in
// order, byte-for-byte identical to GNU. Before the fix, zrm emitted only the
// last (partially overwritten) line. stdout is a real file here on purpose.
// ---------------------------------------------------------------------------
test "verbose multi-file: byte-exact vs GNU rm" {
    const a = std.testing.allocator;
    const grm = grmPath() orelse return error.SkipZigTest;

    const zdir = try mkScratch(a, "vz");
    defer a.free(zdir);
    const gdir = try mkScratch(a, "vg");
    defer a.free(gdir);
    try shSetup(a, zdir, "touch aaa bbb ccc");
    try shSetup(a, gdir, "touch aaa bbb ccc");

    const zcmd = try std.fmt.allocPrint(a, "{s} -v aaa bbb ccc", .{zrm_exe});
    defer a.free(zcmd);
    const gcmd = try std.fmt.allocPrint(a, "{s} -v aaa bbb ccc", .{grm});
    defer a.free(gcmd);

    var z = try runShell(a, zdir, zcmd);
    defer z.deinit(a);
    var g = try runShell(a, gdir, gcmd);
    defer g.deinit(a);

    // Externally anchored: GNU prints exactly these bytes.
    try std.testing.expectEqualStrings("removed 'aaa'\nremoved 'bbb'\nremoved 'ccc'\n", g.out);
    try std.testing.expectEqualStrings(g.out, z.out);
    try std.testing.expectEqual(@as(i64, 0), z.code);
    try std.testing.expectEqual(g.code, z.code);
}

// Recursive verbose: contents-before-container ordering. readdir order can differ
// between two independently-created trees, so compare the SORTED line multiset
// (still an external anchor on exactly which lines GNU emits).
test "verbose recursive: sorted line-set vs GNU rm" {
    const a = std.testing.allocator;
    const grm = grmPath() orelse return error.SkipZigTest;

    const zdir = try mkScratch(a, "rvz");
    defer a.free(zdir);
    const gdir = try mkScratch(a, "rvg");
    defer a.free(gdir);
    try shSetup(a, zdir, "mkdir -p za/zb && touch za/f1 za/zb/f2");
    try shSetup(a, gdir, "mkdir -p za/zb && touch za/f1 za/zb/f2");

    const zcmd = try std.fmt.allocPrint(a, "{s} -rv za", .{zrm_exe});
    defer a.free(zcmd);
    const gcmd = try std.fmt.allocPrint(a, "{s} -rv za", .{grm});
    defer a.free(gcmd);

    var z = try runShell(a, zdir, zcmd);
    defer z.deinit(a);
    var g = try runShell(a, gdir, gcmd);
    defer g.deinit(a);

    const zs = try sortedLines(a, z.out);
    defer a.free(zs);
    const gs = try sortedLines(a, g.out);
    defer a.free(gs);

    // GNU emits exactly these four lines (order aside).
    const expected =
        "removed 'za/f1'\n" ++
        "removed 'za/zb/f2'\n" ++
        "removed directory 'za'\n" ++
        "removed directory 'za/zb'\n";
    try std.testing.expectEqualStrings(expected, gs);
    try std.testing.expectEqualStrings(gs, zs);
}

// ---------------------------------------------------------------------------
// Error-message parity (stderr body + exit code) vs GNU, prefix-normalized.
// ---------------------------------------------------------------------------
fn expectStderrMatchesGnu(a: std.mem.Allocator, tag: []const u8, setup_cmd: []const u8, argstr: []const u8) !void {
    const grm = grmPath() orelse return error.SkipZigTest;

    const zdir = try mkScratch(a, tag);
    defer a.free(zdir);
    const gdir = try mkScratch(a, tag);
    defer a.free(gdir);
    if (setup_cmd.len != 0) {
        try shSetup(a, zdir, setup_cmd);
        try shSetup(a, gdir, setup_cmd);
    }

    const zcmd = try std.fmt.allocPrint(a, "{s} {s}", .{ zrm_exe, argstr });
    defer a.free(zcmd);
    const gcmd = try std.fmt.allocPrint(a, "{s} {s}", .{ grm, argstr });
    defer a.free(gcmd);

    var z = try runShell(a, zdir, zcmd);
    defer z.deinit(a);
    var g = try runShell(a, gdir, gcmd);
    defer g.deinit(a);

    const zb = try stripPrefixes(a, z.err);
    defer a.free(zb);
    const gb = try stripPrefixes(a, g.err);
    defer a.free(gb);

    try std.testing.expectEqualStrings(gb, zb);
    try std.testing.expectEqual(g.code, z.code);
}

test "error: -d on non-empty directory matches GNU" {
    try expectStderrMatchesGnu(std.testing.allocator, "de", "mkdir ne && touch ne/x", "-d ne");
}
test "error: trailing slash on non-directory matches GNU (ENOTDIR)" {
    try expectStderrMatchesGnu(std.testing.allocator, "ts", "touch reg", "reg/");
}
test "error: directory without -r matches GNU (Is a directory)" {
    try expectStderrMatchesGnu(std.testing.allocator, "isd", "mkdir isd", "isd");
}
test "error: nonexistent file matches GNU (No such file or directory)" {
    try expectStderrMatchesGnu(std.testing.allocator, "nx", "", "nope");
}

// Option errors: GNU prints the message line + a "Try '<prog> --help' ..." hint.
// Line 1 body must match GNU; line 2 differs only by program name, so we assert
// zrm's exact hint literally.
fn expectOptionError(a: std.mem.Allocator, tag: []const u8, argstr: []const u8, want_line1_body: []const u8) !void {
    const grm = grmPath() orelse return error.SkipZigTest;

    const zdir = try mkScratch(a, tag);
    defer a.free(zdir);
    const gdir = try mkScratch(a, tag);
    defer a.free(gdir);

    const zcmd = try std.fmt.allocPrint(a, "{s} {s}", .{ zrm_exe, argstr });
    defer a.free(zcmd);
    const gcmd = try std.fmt.allocPrint(a, "{s} {s}", .{ grm, argstr });
    defer a.free(gcmd);

    var z = try runShell(a, zdir, zcmd);
    defer z.deinit(a);
    var g = try runShell(a, gdir, gcmd);
    defer g.deinit(a);

    // GNU emits a two-line diagnostic; verify our understanding of its shape.
    var git = std.mem.splitScalar(u8, g.err, '\n');
    const gline1 = git.next() orelse "";
    const gbody1 = if (std.mem.indexOf(u8, gline1, ": ")) |i| gline1[i + 2 ..] else gline1;
    try std.testing.expectEqualStrings(want_line1_body, gbody1);

    var zit = std.mem.splitScalar(u8, z.err, '\n');
    const zline1 = zit.next() orelse "";
    const zbody1 = if (std.mem.indexOf(u8, zline1, ": ")) |i| zline1[i + 2 ..] else zline1;
    try std.testing.expectEqualStrings(want_line1_body, zbody1);

    // zrm must emit the help hint as its second line (GNU parity, own program name).
    const zline2 = zit.next() orelse "";
    try std.testing.expectEqualStrings("Try 'zrm --help' for more information.", zline2);

    try std.testing.expectEqual(g.code, z.code);
}

test "error: unrecognized long option matches GNU shape + emits help hint" {
    try expectOptionError(std.testing.allocator, "opt1", "--bogus", "unrecognized option '--bogus'");
}
test "error: invalid short option matches GNU shape + emits help hint" {
    try expectOptionError(std.testing.allocator, "opt2", "-Z", "invalid option -- 'Z'");
}

// ---------------------------------------------------------------------------
// -I prompt-once semantics (documented GNU behavior). Declining removes nothing.
// ---------------------------------------------------------------------------
test "-I recursive declined: prompt matches GNU and nothing is removed" {
    const a = std.testing.allocator;
    const grm = grmPath() orelse return error.SkipZigTest;

    const zdir = try mkScratch(a, "iz");
    defer a.free(zdir);
    const gdir = try mkScratch(a, "ig");
    defer a.free(gdir);
    try shSetup(a, zdir, "mkdir -p d1 && touch d1/x");
    try shSetup(a, gdir, "mkdir -p d1 && touch d1/x");

    const zcmd = try std.fmt.allocPrint(a, "printf n | {s} -I -r d1", .{zrm_exe});
    defer a.free(zcmd);
    const gcmd = try std.fmt.allocPrint(a, "printf n | {s} -I -r d1", .{grm});
    defer a.free(gcmd);

    var z = try runShell(a, zdir, zcmd);
    defer z.deinit(a);
    var g = try runShell(a, gdir, gcmd);
    defer g.deinit(a);

    const zb = try stripPrefixes(a, z.err);
    defer a.free(zb);
    const gb = try stripPrefixes(a, g.err);
    defer a.free(gb);
    // GNU: "remove 1 argument recursively? "
    try std.testing.expectEqualStrings("remove 1 argument recursively? ", gb);
    try std.testing.expectEqualStrings(gb, zb);
    try std.testing.expectEqual(g.code, z.code);

    // Declined => tree survives in BOTH.
    const zx = try std.fs.path.join(a, &.{ zdir, "d1", "x" });
    defer a.free(zx);
    const gx = try std.fs.path.join(a, &.{ gdir, "d1", "x" });
    defer a.free(gx);
    try std.testing.expect(exists(zx));
    try std.testing.expect(exists(gx));
}

// ---------------------------------------------------------------------------
// Security: TOCTOU / symlink-descent safety. A symlink that appears INSIDE the
// tree being removed must be unlinked, never traversed — files it points at,
// outside the tree, must survive. (Anchors the fd-relative openat/unlinkat walk.)
// ---------------------------------------------------------------------------
test "security: recursive remove does not follow a symlink inside the tree" {
    const a = std.testing.allocator;

    const root = try mkScratch(a, "sec");
    defer a.free(root);

    // inside/link -> <root>/outside (absolute). outside/keep must survive.
    const setup = try std.fmt.allocPrint(
        a,
        "mkdir -p outside inside && touch outside/keep && ln -s '{s}/outside' inside/link",
        .{root},
    );
    defer a.free(setup);
    try shSetup(a, root, setup);

    const cmd = try std.fmt.allocPrint(a, "{s} -r inside", .{zrm_exe});
    defer a.free(cmd);
    var r = try runShell(a, root, cmd);
    defer r.deinit(a);

    try std.testing.expectEqual(@as(i64, 0), r.code);

    const inside = try std.fs.path.join(a, &.{ root, "inside" });
    defer a.free(inside);
    const keep = try std.fs.path.join(a, &.{ root, "outside", "keep" });
    defer a.free(keep);

    // The symlink and its parent are gone...
    try std.testing.expect(!exists(inside));
    // ...but the file the symlink pointed at, outside the tree, MUST survive.
    try std.testing.expect(exists(keep));
}
