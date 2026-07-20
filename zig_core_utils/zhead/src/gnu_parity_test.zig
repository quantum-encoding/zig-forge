//! Externally-anchored parity tests for `zhead`.
//!
//! The external anchor is the real GNU coreutils `head` binary (installed via
//! Homebrew as `ghead` / `.../gnubin/head`, GNU coreutils 9.x). For a spread of
//! representative inputs and flags we run BOTH `zhead` and GNU `head` with the
//! same argv and assert that stdout bytes and exit codes match. GNU's output is
//! the source of truth; nothing here is a self-consistency / roundtrip test.
//!
//! Crucially, the child's stdout is redirected to a *regular file* (not a
//! pipe). The multi-file/-v corruption bug (audit finding #2) only manifests
//! when stdout is seekable, so a pipe-based harness would silently miss it.
//!
//! A handful of assertions additionally pin the exact expected bytes / exit
//! codes drawn from documented GNU behavior, so the core invariants still bite
//! even if no GNU binary is present on the machine.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const zhead_bin: []const u8 = build_options.zhead_bin;

// A process-wide Threaded io with a real allocator. `global_single_threaded`
// uses a `.failing` allocator, so it cannot spawn child processes. We back this
// one with the page allocator (not the testing allocator) so spawn's internal
// bookkeeping is not mis-reported as a test-owned leak. It also installs a
// no-op SIGPIPE handler, matching how head tolerates a closed output pipe.
var g_threaded: ?Io.Threaded = null;

fn io() Io {
    if (g_threaded == null) g_threaded = Io.Threaded.init(std.heap.page_allocator, .{});
    return g_threaded.?.io();
}

/// Locate a GNU `head`. Returns null if none is installed.
fn gnuHead() ?[]const u8 {
    const candidates = [_][]const u8{
        "/opt/homebrew/bin/ghead",
        "/opt/homebrew/opt/coreutils/libexec/gnubin/head",
        "/usr/local/bin/ghead",
        "/usr/local/opt/coreutils/libexec/gnubin/head",
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
    // Per-process salt from a stack address (ASLR varies it across processes);
    // an incrementing counter makes each call unique within a process. Tests
    // run single-threaded, so the un-synchronized counter is fine.
    var local: u8 = 0;
    const seed = @intFromPtr(&local);
    g_path_counter += 1;
    return std.fmt.allocPrint(gpa, "/tmp/zhead_test_{x}_{x}_{s}", .{ seed, g_path_counter, tag });
}

fn writeFixture(gpa: std.mem.Allocator, tag: []const u8, bytes: []const u8) ![]u8 {
    const path = try uniquePath(gpa, tag);
    var f = try Dir.createFileAbsolute(io(), path, .{});
    defer f.close(io());
    var buf: [64]u8 = undefined;
    var w = f.writer(io(), &buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
    return path;
}

/// Run `argv`, redirecting stdout+stderr to regular temp files (so the
/// seekable-stdout code path is exercised), optionally feeding `stdin_path` as
/// the child's stdin. Returns captured stdout/stderr bytes and the exit code.
fn runProc(gpa: std.mem.Allocator, argv: []const []const u8, stdin_path: ?[]const u8) !RunOut {
    const out_path = try uniquePath(gpa, "out");
    defer gpa.free(out_path);
    const err_path = try uniquePath(gpa, "err");
    defer gpa.free(err_path);

    var of = try Dir.createFileAbsolute(io(), out_path, .{ .read = true });
    var ef = try Dir.createFileAbsolute(io(), err_path, .{ .read = true });

    const stdin_file: ?File = if (stdin_path) |p|
        try Dir.openFileAbsolute(io(), p, .{})
    else
        null;

    var child = try std.process.spawn(io(), .{
        .argv = argv,
        .stdin = if (stdin_file) |f| .{ .file = f } else .ignore,
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
    if (stdin_file) |f| f.close(io());
    Dir.deleteFileAbsolute(io(), out_path) catch {};
    Dir.deleteFileAbsolute(io(), err_path) catch {};

    const code: i32 = switch (term) {
        .exited => |c| c,
        else => -1,
    };
    return .{ .stdout = out, .stderr = err, .code = code };
}

/// Concatenate `[bin] ++ flags ++ files` into an argv slice.
fn buildArgv(gpa: std.mem.Allocator, bin: []const u8, flags: []const []const u8, files: []const []const u8) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    try list.append(gpa, bin);
    for (flags) |f| try list.append(gpa, f);
    for (files) |f| try list.append(gpa, f);
    return list.toOwnedSlice(gpa);
}

/// Run both binaries with the same flags/files and assert identical stdout and
/// exit code. The GNU binary is the external anchor.
fn expectParity(gpa: std.mem.Allocator, gnu: []const u8, flags: []const []const u8, files: []const []const u8, stdin_path: ?[]const u8) !void {
    const z_argv = try buildArgv(gpa, zhead_bin, flags, files);
    defer gpa.free(z_argv);
    const g_argv = try buildArgv(gpa, gnu, flags, files);
    defer gpa.free(g_argv);

    const z = try runProc(gpa, z_argv, stdin_path);
    defer z.deinit(gpa);
    const g = try runProc(gpa, g_argv, stdin_path);
    defer g.deinit(gpa);

    if (!std.mem.eql(u8, z.stdout, g.stdout) or z.code != g.code) {
        std.debug.print("\nPARITY MISMATCH flags=[ ", .{});
        for (flags) |f| std.debug.print("{s} ", .{f});
        std.debug.print("] files=[ ", .{});
        for (files) |f| std.debug.print("{s} ", .{f});
        std.debug.print(
            "]\n  zhead code={d} stdout={d}B: {s}\n  gnu   code={d} stdout={d}B: {s}\n",
            .{ z.code, z.stdout.len, z.stdout, g.code, g.stdout.len, g.stdout },
        );
        return error.ParityMismatch;
    }
}

// ---- Fixtures shared across the diff tests -------------------------------

const Fixtures = struct {
    dir_alloc: std.mem.Allocator,
    twelve: []u8, // 12 numbered lines, each newline-terminated
    nonl: []u8, // content with NO trailing newline
    empty: []u8, // zero bytes
    binary: []u8, // 256 bytes 0x00..0xFF
    big: []u8, // 5000 zero bytes (for suffix clamp checks)

    fn make(gpa: std.mem.Allocator) !Fixtures {
        const twelve = try writeFixture(gpa, "twelve", "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n");
        const nonl = try writeFixture(gpa, "nonl", "no newline at end");
        const empty = try writeFixture(gpa, "empty", "");
        var bin: [256]u8 = undefined;
        for (&bin, 0..) |*b, i| b.* = @intCast(i);
        const binary = try writeFixture(gpa, "binary", &bin);
        const big = try writeFixture(gpa, "big", &[_]u8{0} ** 5000);
        return .{ .dir_alloc = gpa, .twelve = twelve, .nonl = nonl, .empty = empty, .binary = binary, .big = big };
    }

    fn deinit(self: *Fixtures) void {
        for ([_][]u8{ self.twelve, self.nonl, self.empty, self.binary, self.big }) |p| {
            Dir.deleteFileAbsolute(io(), p) catch {};
            self.dir_alloc.free(p);
        }
    }
};

// ---- External-anchor tests (diff vs GNU head) ----------------------------

test "parity: default 10 lines, -n variants, negative, byte counts" {
    const gpa = std.testing.allocator;
    const gnu = gnuHead() orelse return error.SkipZigTest;
    var fx = try Fixtures.make(gpa);
    defer fx.deinit();

    const one = [_][]const u8{fx.twelve};
    try expectParity(gpa, gnu, &.{}, &one, null); // default 10 lines
    try expectParity(gpa, gnu, &.{ "-n", "3" }, &one, null);
    try expectParity(gpa, gnu, &.{ "-n", "0" }, &one, null);
    try expectParity(gpa, gnu, &.{ "-n", "100" }, &one, null); // more than file has
    try expectParity(gpa, gnu, &.{"-3"}, &one, null); // -NUM form
    try expectParity(gpa, gnu, &.{ "-n", "-4" }, &one, null); // all but last 4
    try expectParity(gpa, gnu, &.{ "--lines=5" }, &one, null);
    try expectParity(gpa, gnu, &.{ "-c", "7" }, &one, null);
    try expectParity(gpa, gnu, &.{ "-c", "-5" }, &one, null); // all but last 5 bytes
    try expectParity(gpa, gnu, &.{ "--bytes=3" }, &one, null);
}

test "parity: no trailing newline, empty file, binary content" {
    const gpa = std.testing.allocator;
    const gnu = gnuHead() orelse return error.SkipZigTest;
    var fx = try Fixtures.make(gpa);
    defer fx.deinit();

    try expectParity(gpa, gnu, &.{ "-n", "1" }, &.{fx.nonl}, null);
    try expectParity(gpa, gnu, &.{}, &.{fx.nonl}, null);
    try expectParity(gpa, gnu, &.{}, &.{fx.empty}, null);
    try expectParity(gpa, gnu, &.{ "-n", "5" }, &.{fx.empty}, null);
    try expectParity(gpa, gnu, &.{ "-c", "100" }, &.{fx.binary}, null);
    try expectParity(gpa, gnu, &.{ "-c", "16" }, &.{fx.binary}, null);
}

test "parity: multi-file headers to a REGULAR-FILE stdout (audit finding #2)" {
    const gpa = std.testing.allocator;
    const gnu = gnuHead() orelse return error.SkipZigTest;
    var fx = try Fixtures.make(gpa);
    defer fx.deinit();

    const two = [_][]const u8{ fx.twelve, fx.nonl };
    // Default multi-file header behavior — this is the exact case that emitted
    // "\n=> file <==" (dropped first byte) before the single-writer fix.
    try expectParity(gpa, gnu, &.{}, &two, null);
    try expectParity(gpa, gnu, &.{ "-n", "2" }, &two, null);
    try expectParity(gpa, gnu, &.{"-q"}, &two, null); // never headers
    try expectParity(gpa, gnu, &.{"-v"}, &.{fx.twelve}, null); // force header, single file
    try expectParity(gpa, gnu, &.{"-qv"}, &two, null); // last-wins -> verbose
    try expectParity(gpa, gnu, &.{"-vq"}, &two, null); // last-wins -> quiet
    // Three files including an empty one.
    try expectParity(gpa, gnu, &.{ "-n", "3" }, &.{ fx.twelve, fx.empty, fx.nonl }, null);
}

test "parity: numeric overflow is graceful (audit finding #1), not SIGABRT" {
    const gpa = std.testing.allocator;
    const gnu = gnuHead() orelse return error.SkipZigTest;
    var fx = try Fixtures.make(gpa);
    defer fx.deinit();

    const one = [_][]const u8{fx.twelve};
    try expectParity(gpa, gnu, &.{ "-n", "99999999999999999999999999" }, &one, null);
    try expectParity(gpa, gnu, &.{ "-c", "99999999999999999G" }, &one, null);
    try expectParity(gpa, gnu, &.{ "-c", "18446744073709551615" }, &one, null); // u64 max
}

test "parity: invalid numeric args error with exit 1 (audit finding #3)" {
    const gpa = std.testing.allocator;
    const gnu = gnuHead() orelse return error.SkipZigTest;
    var fx = try Fixtures.make(gpa);
    defer fx.deinit();

    const one = [_][]const u8{fx.twelve};
    try expectParity(gpa, gnu, &.{ "-n", "abc" }, &one, null);
    try expectParity(gpa, gnu, &.{ "-c", "xyz" }, &one, null);
    try expectParity(gpa, gnu, &.{ "--lines=notanumber" }, &one, null);
    try expectParity(gpa, gnu, &.{ "-c", "12 q" }, &one, null);
}

test "parity: directory argument errors (audit finding #4)" {
    const gpa = std.testing.allocator;
    const gnu = gnuHead() orelse return error.SkipZigTest;

    const dir_arg = [_][]const u8{"/tmp"};
    // Both must exit 1 with empty stdout (stderr text differs by program name).
    try expectParity(gpa, gnu, &.{ "-n", "1" }, &dir_arg, null);
}

test "parity: nonexistent file errors" {
    const gpa = std.testing.allocator;
    const gnu = gnuHead() orelse return error.SkipZigTest;
    try expectParity(gpa, gnu, &.{}, &.{"/no/such/file/zhead_xyz"}, null);
}

test "parity: GNU suffixes b/kB/K/MB/M/GB/G against a 5000-byte file" {
    const gpa = std.testing.allocator;
    const gnu = gnuHead() orelse return error.SkipZigTest;
    var fx = try Fixtures.make(gpa);
    defer fx.deinit();

    const big = [_][]const u8{fx.big};
    for ([_][]const u8{ "1b", "1kB", "1K", "1k", "1KiB", "1MB", "1M", "1MiB", "1GB", "1G", "2b", "3kB" }) |suf| {
        try expectParity(gpa, gnu, &.{ "-c", suf }, &big, null);
    }
}

test "parity: reading from stdin (the '-' path)" {
    const gpa = std.testing.allocator;
    const gnu = gnuHead() orelse return error.SkipZigTest;
    var fx = try Fixtures.make(gpa);
    defer fx.deinit();

    // No file argument -> both read stdin, which we feed from a fixture file.
    try expectParity(gpa, gnu, &.{ "-n", "4" }, &.{}, fx.twelve);
    try expectParity(gpa, gnu, &.{ "-c", "5" }, &.{}, fx.twelve);
    try expectParity(gpa, gnu, &.{ "-n", "-3" }, &.{}, fx.twelve);
    try expectParity(gpa, gnu, &.{}, &.{"-"}, fx.twelve); // explicit '-' as the file
    try expectParity(gpa, gnu, &.{"-v"}, &.{"-"}, fx.twelve); // header must say "standard input"
    // NOTE: two '-' args reading a *seekable* stdin (GNU lseeks the unconsumed
    // tail back so a second reader continues) is a documented GNU edge case
    // zhead does not replicate; intentionally not asserted here.
}

// ---- Literal-anchored invariants (do not require a GNU binary) -----------
//
// Expected bytes/exit codes come from documented GNU coreutils `head`
// behavior. These bite even when GNU head is not installed.

test "anchor: -n 2 emits exactly the first two lines" {
    const gpa = std.testing.allocator;
    const path = try writeFixture(gpa, "lit", "one\ntwo\nthree\nfour\n");
    defer {
        Dir.deleteFileAbsolute(io(), path) catch {};
        gpa.free(path);
    }
    const argv = [_][]const u8{ zhead_bin, "-n", "2", path };
    const r = try runProc(gpa, &argv, null);
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("one\ntwo\n", r.stdout);
    try std.testing.expectEqual(@as(i32, 0), r.code);
}

test "anchor: -c 3 emits exactly the first three bytes" {
    const gpa = std.testing.allocator;
    const path = try writeFixture(gpa, "lit", "abcdef\n");
    defer {
        Dir.deleteFileAbsolute(io(), path) catch {};
        gpa.free(path);
    }
    const argv = [_][]const u8{ zhead_bin, "-c", "3", path };
    const r = try runProc(gpa, &argv, null);
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("abc", r.stdout);
    try std.testing.expectEqual(@as(i32, 0), r.code);
}

test "anchor: huge numeric argument does NOT abort (exit 0, whole file)" {
    const gpa = std.testing.allocator;
    const path = try writeFixture(gpa, "lit", "x\ny\nz\n");
    defer {
        Dir.deleteFileAbsolute(io(), path) catch {};
        gpa.free(path);
    }
    // Pre-fix this panicked with integer overflow (SIGABRT, exit 134).
    const argv = [_][]const u8{ zhead_bin, "-n", "99999999999999999999999999", path };
    const r = try runProc(gpa, &argv, null);
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(i32, 0), r.code);
    try std.testing.expectEqualStrings("x\ny\nz\n", r.stdout);
}

test "anchor: invalid -n errors with exit 1 and 'invalid number of lines'" {
    const gpa = std.testing.allocator;
    const path = try writeFixture(gpa, "lit", "x\ny\n");
    defer {
        Dir.deleteFileAbsolute(io(), path) catch {};
        gpa.free(path);
    }
    const argv = [_][]const u8{ zhead_bin, "-n", "abc", path };
    const r = try runProc(gpa, &argv, null);
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(i32, 1), r.code);
    try std.testing.expectEqual(@as(usize, 0), r.stdout.len);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "invalid number of lines") != null);
}

test "anchor: multi-file header starts with '==> ' on regular-file stdout" {
    const gpa = std.testing.allocator;
    const a = try writeFixture(gpa, "a", "alpha\n");
    const b = try writeFixture(gpa, "b", "beta\n");
    defer {
        Dir.deleteFileAbsolute(io(), a) catch {};
        Dir.deleteFileAbsolute(io(), b) catch {};
        gpa.free(a);
        gpa.free(b);
    }
    const argv = [_][]const u8{ zhead_bin, a, b };
    const r = try runProc(gpa, &argv, null);
    defer r.deinit(gpa);
    // Pre-fix this began with "\n=> " (dropped first byte + stray newline).
    try std.testing.expect(r.stdout.len >= 4);
    try std.testing.expectEqualStrings("==> ", r.stdout[0..4]);
    try std.testing.expectEqual(@as(i32, 0), r.code);
}
