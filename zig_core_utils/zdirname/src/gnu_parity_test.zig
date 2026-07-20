//! Externally-anchored parity tests for `zdirname`.
//!
//! The external anchor is the real GNU coreutils `dirname` binary (installed via
//! Homebrew as `gdirname` / `.../gnubin/dirname`, GNU coreutils 9.x). For a
//! spread of representative inputs and flags we run BOTH `zdirname` and GNU
//! `dirname` with the same argv and assert that stdout bytes and exit codes
//! match. GNU's output is the source of truth; nothing here is a
//! self-consistency / roundtrip test.
//!
//! For diagnostics on stderr, GNU emits the program name (`gdirname`) that
//! differs from ours (`zdirname`) by design, so those cases compare exit codes
//! against GNU and additionally pin the exact expected stderr bytes literally
//! (with our program name), drawn from observed GNU 9.10 output.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const zdirname_bin: []const u8 = build_options.zdirname_bin;

// A process-wide Threaded io backed by the page allocator so spawn's internal
// bookkeeping is not mis-reported as a test-owned leak.
var g_threaded: ?Io.Threaded = null;

fn io() Io {
    if (g_threaded == null) g_threaded = Io.Threaded.init(std.heap.page_allocator, .{});
    return g_threaded.?.io();
}

/// Locate a GNU `dirname`. Returns null if none is installed.
fn gnuDirname() ?[]const u8 {
    const candidates = [_][]const u8{
        "/opt/homebrew/bin/gdirname",
        "/opt/homebrew/opt/coreutils/libexec/gnubin/dirname",
        "/usr/local/bin/gdirname",
        "/usr/local/opt/coreutils/libexec/gnubin/dirname",
    };
    for (candidates) |c| {
        const f = Dir.openFileAbsolute(io(), c, .{}) catch continue;
        f.close(io());
        return c;
    }
    return null;
}

const RunOut = struct {
    stdout: []u8,
    stderr: []u8,
    code: i32, // process exit code, or -1 if killed by signal

    fn deinit(self: RunOut, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

var g_path_counter: u64 = 0;

fn uniquePath(gpa: std.mem.Allocator, tag: []const u8) ![]u8 {
    var local: u8 = 0;
    const seed = @intFromPtr(&local);
    g_path_counter += 1;
    return std.fmt.allocPrint(gpa, "/tmp/zdirname_test_{x}_{x}_{s}", .{ seed, g_path_counter, tag });
}

/// Run `argv`, redirecting stdout+stderr to regular temp files. Returns captured
/// stdout/stderr bytes and the exit code.
fn runProc(gpa: std.mem.Allocator, argv: []const []const u8) !RunOut {
    const out_path = try uniquePath(gpa, "out");
    defer gpa.free(out_path);
    const err_path = try uniquePath(gpa, "err");
    defer gpa.free(err_path);

    var of = try Dir.createFileAbsolute(io(), out_path, .{ .read = true });
    var ef = try Dir.createFileAbsolute(io(), err_path, .{ .read = true });

    var child = try std.process.spawn(io(), .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .{ .file = of },
        .stderr = .{ .file = ef },
    });
    const term = try child.wait(io());

    const ostat = try of.stat(io());
    const estat = try ef.stat(io());
    const out = try gpa.alloc(u8, @intCast(ostat.size));
    const err = try gpa.alloc(u8, @intCast(estat.size));
    _ = try of.readPositionalAll(io(), out, 0);
    _ = try ef.readPositionalAll(io(), err, 0);

    of.close(io());
    ef.close(io());
    Dir.deleteFileAbsolute(io(), out_path) catch {};
    Dir.deleteFileAbsolute(io(), err_path) catch {};

    const code: i32 = switch (term) {
        .exited => |c| c,
        else => -1,
    };
    return .{ .stdout = out, .stderr = err, .code = code };
}

fn buildArgv(gpa: std.mem.Allocator, bin: []const u8, rest: []const []const u8) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    try list.append(gpa, bin);
    for (rest) |a| try list.append(gpa, a);
    return list.toOwnedSlice(gpa);
}

/// Run both binaries with the same args and assert identical stdout AND exit
/// code. The GNU binary is the external anchor. stderr is not compared here
/// because GNU emits its own program name.
fn expectParity(gpa: std.mem.Allocator, gnu: []const u8, args: []const []const u8) !void {
    const z_argv = try buildArgv(gpa, zdirname_bin, args);
    defer gpa.free(z_argv);
    const g_argv = try buildArgv(gpa, gnu, args);
    defer gpa.free(g_argv);

    const z = try runProc(gpa, z_argv);
    defer z.deinit(gpa);
    const g = try runProc(gpa, g_argv);
    defer g.deinit(gpa);

    if (!std.mem.eql(u8, z.stdout, g.stdout) or z.code != g.code) {
        std.debug.print("\nPARITY MISMATCH args=[ ", .{});
        for (args) |a| std.debug.print("'{s}' ", .{a});
        std.debug.print(
            "]\n  zdirname code={d} stdout={d}B: '{s}'\n  gnu      code={d} stdout={d}B: '{s}'\n",
            .{ z.code, z.stdout.len, z.stdout, g.code, g.stdout.len, g.stdout },
        );
        return error.ParityMismatch;
    }
}

// ---- External-anchor tests (diff vs GNU dirname) -------------------------

test "parity: core path stripping matches GNU" {
    const gpa = std.testing.allocator;
    const gnu = gnuDirname() orelse return error.SkipZigTest;

    // Cases span: absolute/relative, trailing slashes, repeated slashes, root
    // variants, no-slash (-> "."), empty, lone dash, and dotfiles.
    const cases = [_][]const u8{
        "/usr/lib",  "usr/lib", "/usr/",   "usr",     "/",
        ".",         "a/b",     "a",       "a/b/",    "",
        "a//b",      "//",      "///",     "-",       "stdio.h",
        "/usr/bin/", "dir1/str", "./x",    "../y",    "a/b/c/d",
        "foo///bar///", "/.hidden", ".hidden",
    };
    for (cases) |c| {
        try expectParity(gpa, gnu, &.{c});
    }
}

test "parity: -z / --zero terminator and NUL framing" {
    const gpa = std.testing.allocator;
    const gnu = gnuDirname() orelse return error.SkipZigTest;

    try expectParity(gpa, gnu, &.{ "-z", "a/b" });
    try expectParity(gpa, gnu, &.{ "--zero", "a/b" });
    try expectParity(gpa, gnu, &.{ "-z", "a/b", "c/d", "/usr/lib" });
    // Options may follow operands (GNU permutes argv): -z still applies globally.
    try expectParity(gpa, gnu, &.{ "a/b", "-z", "c/d" });
    // Grouped short cluster.
    try expectParity(gpa, gnu, &.{ "-zz", "a/b" });
}

test "parity: multiple operands, order preserved" {
    const gpa = std.testing.allocator;
    const gnu = gnuDirname() orelse return error.SkipZigTest;

    try expectParity(gpa, gnu, &.{ "a/b", "c/d", "e/f" });
    try expectParity(gpa, gnu, &.{ "/usr/bin", "no_slash", "/" });
}

test "parity: -- end-of-options sentinel" {
    const gpa = std.testing.allocator;
    const gnu = gnuDirname() orelse return error.SkipZigTest;

    // After --, a dash-led operand is a path, not an option.
    try expectParity(gpa, gnu, &.{ "--", "-z/foo" });
    try expectParity(gpa, gnu, &.{ "--", "-z", "a/b" }); // "-z" now a bare operand -> "."
    try expectParity(gpa, gnu, &.{ "--", "--foo/bar" });
}

test "parity: error exit codes match GNU (stderr text differs by prog name)" {
    const gpa = std.testing.allocator;
    const gnu = gnuDirname() orelse return error.SkipZigTest;

    // Unrecognized long option, invalid short option, disallowed argument,
    // and missing operand all exit 1 with empty stdout in GNU.
    try expectParity(gpa, gnu, &.{"--foo"});
    try expectParity(gpa, gnu, &.{"-x"});
    try expectParity(gpa, gnu, &.{"--zero=x"});
    try expectParity(gpa, gnu, &.{}); // missing operand
}

// ---- Documented-byte anchors (independent of a GNU binary being present) --
//
// These pin the exact bytes GNU coreutils 9.10 was observed to emit, with our
// program name substituted where GNU prints its own. They still bite if the
// machine has no GNU binary installed.

fn runZ(gpa: std.mem.Allocator, args: []const []const u8) !RunOut {
    const argv = try buildArgv(gpa, zdirname_bin, args);
    defer gpa.free(argv);
    return runProc(gpa, argv);
}

test "anchor: unrecognized long option -> exact stderr + exit 1, no stdout" {
    const gpa = std.testing.allocator;
    const r = try runZ(gpa, &.{"--foo"});
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(i32, 1), r.code);
    try std.testing.expectEqualStrings("", r.stdout);
    try std.testing.expectEqualStrings(
        "zdirname: unrecognized option '--foo'\n" ++
            "Try 'zdirname --help' for more information.\n",
        r.stderr,
    );
}

test "anchor: invalid short option -> exact stderr + exit 1" {
    const gpa = std.testing.allocator;
    const r = try runZ(gpa, &.{"-x"});
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(i32, 1), r.code);
    try std.testing.expectEqualStrings("", r.stdout);
    try std.testing.expectEqualStrings(
        "zdirname: invalid option -- 'x'\n" ++
            "Try 'zdirname --help' for more information.\n",
        r.stderr,
    );
}

test "anchor: missing operand -> exact stderr + exit 1" {
    const gpa = std.testing.allocator;
    const r = try runZ(gpa, &.{});
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(i32, 1), r.code);
    try std.testing.expectEqualStrings("", r.stdout);
    try std.testing.expectEqualStrings(
        "zdirname: missing operand\n" ++
            "Try 'zdirname --help' for more information.\n",
        r.stderr,
    );
}

test "anchor: --zero=x rejects argument -> exact stderr + exit 1" {
    const gpa = std.testing.allocator;
    const r = try runZ(gpa, &.{"--zero=x"});
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(i32, 1), r.code);
    try std.testing.expectEqualStrings("", r.stdout);
    try std.testing.expectEqualStrings(
        "zdirname: option '--zero' doesn't allow an argument\n" ++
            "Try 'zdirname --help' for more information.\n",
        r.stderr,
    );
}

test "anchor: --version prints a version line and exits 0" {
    const gpa = std.testing.allocator;
    const r = try runZ(gpa, &.{"--version"});
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(i32, 0), r.code);
    try std.testing.expect(std.mem.startsWith(u8, r.stdout, "zdirname"));
    try std.testing.expect(std.mem.endsWith(u8, r.stdout, "\n"));
}

test "anchor: -z emits NUL terminators, not newlines (documented GNU framing)" {
    const gpa = std.testing.allocator;
    const r = try runZ(gpa, &.{ "-z", "a/b", "c/d" });
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(i32, 0), r.code);
    // GNU: each result ("a", "c") followed by a NUL byte, no trailing newline.
    try std.testing.expectEqualSlices(u8, "a\x00c\x00", r.stdout);
}
