//! Externally-anchored parity tests for `zpaste` against GNU coreutils `paste`.
//!
//! These are NOT roundtrip / self-consistency tests. Every expected value is
//! either:
//!   (a) the exact bytes emitted by the real GNU `paste` binary (captured with
//!       `paste … | od -c` on 2026-07-19, Homebrew coreutils 9.10), embedded
//!       here literally as the anchor, AND
//!   (b) re-diffed live against the GNU binary at test time whenever one is
//!       found on the system (`…/gnubin/paste` or `gpaste`) — a true external
//!       anchor, not a hash pinned over our own output.
//!
//! If no GNU binary is present the literal-bytes assertions still run (they are
//! the anchor); the live cross-check is skipped.
//!
//! The child's stdout/stderr are redirected to regular temp files and stdin is
//! optionally fed from a temp file, so the shared-fd-0 interleave path (audit
//! finding #1) is exercised exactly as GNU sees it. The `zpaste` binary under
//! test is located via the `zpaste_bin` build option (absolute install path).

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const zpaste_bin: []const u8 = build_options.zpaste_bin;

// A process-wide Threaded io backed by the page allocator so spawn bookkeeping
// isn't mis-reported as a test-owned leak. (Same pattern as the zhead suite.)
var g_threaded: ?Io.Threaded = null;

fn io() Io {
    if (g_threaded == null) g_threaded = Io.Threaded.init(std.heap.page_allocator, .{});
    return g_threaded.?.io();
}

/// Locate a real GNU `paste`. Returns null if none is installed.
fn gnuPaste() ?[]const u8 {
    const candidates = [_][]const u8{
        "/opt/homebrew/opt/coreutils/libexec/gnubin/paste",
        "/opt/homebrew/bin/gpaste",
        "/usr/local/opt/coreutils/libexec/gnubin/paste",
        "/usr/local/bin/gpaste",
        "/usr/bin/gpaste",
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
    return std.fmt.allocPrint(gpa, "/tmp/zpaste_test_{x}_{x}_{s}", .{ seed, g_path_counter, tag });
}

/// Write `bytes` to a fresh temp file and return its (owned) path.
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

/// Run `bin ++ tail`, redirecting stdout/stderr to temp files and optionally
/// feeding `stdin_path` as the child's stdin. Returns captured bytes + exit.
fn run(gpa: std.mem.Allocator, bin: []const u8, tail: []const []const u8, stdin_path: ?[]const u8) !RunOut {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, bin);
    try argv.appendSlice(gpa, tail);

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
        .argv = argv.items,
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

/// Assert zpaste(tail, stdin) emits exactly `want_stdout` with exit `want_code`
/// (literal anchor), AND — when GNU paste is present — that GNU produces the
/// identical stdout + exit for the same invocation (live external anchor).
fn expectParity(
    tail: []const []const u8,
    stdin_path: ?[]const u8,
    want_stdout: []const u8,
    want_code: i32,
) !void {
    const gpa = std.testing.allocator;

    const z = try run(gpa, zpaste_bin, tail, stdin_path);
    defer z.deinit(gpa);

    std.testing.expectEqualSlices(u8, want_stdout, z.stdout) catch |e| {
        std.debug.print("zpaste stdout mismatch tail={any}\n  want: {any}\n  got:  {any}\n", .{ tail, want_stdout, z.stdout });
        return e;
    };
    std.testing.expectEqual(want_code, z.code) catch |e| {
        std.debug.print("zpaste exit mismatch tail={any}: want {d} got {d} (stderr: {s})\n", .{ tail, want_code, z.code, z.stderr });
        return e;
    };

    if (gnuPaste()) |gnu| {
        const g = try run(gpa, gnu, tail, stdin_path);
        defer g.deinit(gpa);
        std.testing.expectEqualSlices(u8, g.stdout, z.stdout) catch |e| {
            std.debug.print("zpaste vs GNU stdout divergence tail={any}\n  gnu: {any}\n  zp:  {any}\n", .{ tail, g.stdout, z.stdout });
            return e;
        };
        try std.testing.expectEqual(g.code, z.code);
    }
}

// ===========================================================================
// Core parallel merge. (gpaste f1 f2  ->  'a\t1\nb\t2\nc\t3\n')
// ===========================================================================

test "parallel: two files merged column-wise with TAB" {
    const gpa = std.testing.allocator;
    const f1 = try writeFixture(gpa, "f1", "a\nb\nc\n");
    defer gpa.free(f1);
    const f2 = try writeFixture(gpa, "f2", "1\n2\n3\n");
    defer gpa.free(f2);
    defer Dir.deleteFileAbsolute(io(), f1) catch {};
    defer Dir.deleteFileAbsolute(io(), f2) catch {};

    try expectParity(&.{ f1, f2 }, null, "a\t1\nb\t2\nc\t3\n", 0);
}

test "parallel: uneven column lengths pad with empty fields" {
    const gpa = std.testing.allocator;
    const f1 = try writeFixture(gpa, "f1", "a\nb\nc\n");
    defer gpa.free(f1);
    const f2 = try writeFixture(gpa, "f2", "1\n");
    defer gpa.free(f2);
    defer Dir.deleteFileAbsolute(io(), f1) catch {};
    defer Dir.deleteFileAbsolute(io(), f2) catch {};

    // (gpaste f1 f2 -> 'a\t1\nb\t\nc\t\n')
    try expectParity(&.{ f1, f2 }, null, "a\t1\nb\t\nc\t\n", 0);
}

test "parallel: final line without trailing newline" {
    const gpa = std.testing.allocator;
    const f1 = try writeFixture(gpa, "f1", "a\nb"); // no trailing newline
    defer gpa.free(f1);
    const f2 = try writeFixture(gpa, "f2", "x\ny\n");
    defer gpa.free(f2);
    defer Dir.deleteFileAbsolute(io(), f1) catch {};
    defer Dir.deleteFileAbsolute(io(), f2) catch {};

    // (gpaste f1 f2 -> 'a\tx\nb\ty\n')
    try expectParity(&.{ f1, f2 }, null, "a\tx\nb\ty\n", 0);
}

// ===========================================================================
// AUDIT FINDING #1 (HIGH): multiple stdin operands must interleave round-robin
// through a single shared stdin reader.
//   (printf 'w\nx\ny\nz\n' | gpaste - -   ->  'w\tx\ny\tz\n')
// Before the fix this produced a single column with empty second fields.
// ===========================================================================

test "multi-stdin: two '-' operands interleave into two columns" {
    const gpa = std.testing.allocator;
    const in = try writeFixture(gpa, "in", "w\nx\ny\nz\n");
    defer gpa.free(in);
    defer Dir.deleteFileAbsolute(io(), in) catch {};

    try expectParity(&.{ "-", "-" }, in, "w\tx\ny\tz\n", 0);
}

test "multi-stdin: three '-' operands, ragged tail padded" {
    const gpa = std.testing.allocator;
    const in = try writeFixture(gpa, "in", "1\n2\n3\n4\n5\n6\n7\n");
    defer gpa.free(in);
    defer Dir.deleteFileAbsolute(io(), in) catch {};

    // (printf '1..7\n' | gpaste - - -  ->  '1\t2\t3\n4\t5\t6\n7\t\t\n')
    try expectParity(&.{ "-", "-", "-" }, in, "1\t2\t3\n4\t5\t6\n7\t\t\n", 0);
}

test "single stdin operand reads the whole stream" {
    const gpa = std.testing.allocator;
    const in = try writeFixture(gpa, "in", "a\nb\nc\n");
    defer gpa.free(in);
    defer Dir.deleteFileAbsolute(io(), in) catch {};

    try expectParity(&.{"-"}, in, "a\nb\nc\n", 0);
}

// ===========================================================================
// AUDIT FINDING #2 (MEDIUM): -d '\0' is GNU's empty-string delimiter, NOT a NUL
// byte.  (gpaste -d'\0' f1 f2  ->  'a1\nb2\nc3\n')
// ===========================================================================

test "delimiter: backslash-zero is the empty string, not a NUL byte" {
    const gpa = std.testing.allocator;
    const f1 = try writeFixture(gpa, "f1", "a\nb\nc\n");
    defer gpa.free(f1);
    const f2 = try writeFixture(gpa, "f2", "1\n2\n3\n");
    defer gpa.free(f2);
    defer Dir.deleteFileAbsolute(io(), f1) catch {};
    defer Dir.deleteFileAbsolute(io(), f2) catch {};

    try expectParity(&.{ "-d\\0", f1, f2 }, null, "a1\nb2\nc3\n", 0);
}

// ===========================================================================
// AUDIT FINDING #3 (MEDIUM): -d '' (empty list) means NO separator, not TAB.
//   (gpaste -d '' f1 f2  ->  'a1\nb2\nc3\n')
// ===========================================================================

test "delimiter: empty list concatenates columns with no separator" {
    const gpa = std.testing.allocator;
    const f1 = try writeFixture(gpa, "f1", "a\nb\nc\n");
    defer gpa.free(f1);
    const f2 = try writeFixture(gpa, "f2", "1\n2\n3\n");
    defer gpa.free(f2);
    defer Dir.deleteFileAbsolute(io(), f1) catch {};
    defer Dir.deleteFileAbsolute(io(), f2) catch {};

    try expectParity(&.{ "-d", "", f1, f2 }, null, "a1\nb2\nc3\n", 0);
}

test "delimiter: single custom char" {
    const gpa = std.testing.allocator;
    const f1 = try writeFixture(gpa, "f1", "a\nb\nc\n");
    defer gpa.free(f1);
    const f2 = try writeFixture(gpa, "f2", "1\n2\n3\n");
    defer gpa.free(f2);
    defer Dir.deleteFileAbsolute(io(), f1) catch {};
    defer Dir.deleteFileAbsolute(io(), f2) catch {};

    try expectParity(&.{ "-d,", f1, f2 }, null, "a,1\nb,2\nc,3\n", 0);
}

// ===========================================================================
// Serial mode + delimiter cycling.
//   (gpaste -s -d',;' f1  ->  'a,b;c\n')   (f1 = a,b,c)
//   (gpaste -s f1 f2      ->  'a\tb\tc\n1\t2\t3\n')
// ===========================================================================

test "serial: delimiter list cycles across a single file" {
    const gpa = std.testing.allocator;
    const f1 = try writeFixture(gpa, "f1", "a\nb\nc\n");
    defer gpa.free(f1);
    defer Dir.deleteFileAbsolute(io(), f1) catch {};

    try expectParity(&.{ "-s", "-d,;", f1 }, null, "a,b;c\n", 0);
}

test "serial: two files concatenated line-wise each" {
    const gpa = std.testing.allocator;
    const f1 = try writeFixture(gpa, "f1", "a\nb\nc\n");
    defer gpa.free(f1);
    const f2 = try writeFixture(gpa, "f2", "1\n2\n3\n");
    defer gpa.free(f2);
    defer Dir.deleteFileAbsolute(io(), f1) catch {};
    defer Dir.deleteFileAbsolute(io(), f2) catch {};

    try expectParity(&.{ "-s", f1, f2 }, null, "a\tb\tc\n1\t2\t3\n", 0);
}

// ===========================================================================
// -z zero-terminated: NUL is the line delimiter, so a newline-only file is one
// logical line.  (gpaste -z f1 f2  ->  'a\nb\nc\n\t1\n2\n3\n\0')
// ===========================================================================

test "zero-terminated uses NUL as line delimiter" {
    const gpa = std.testing.allocator;
    const f1 = try writeFixture(gpa, "f1", "a\nb\nc\n");
    defer gpa.free(f1);
    const f2 = try writeFixture(gpa, "f2", "1\n2\n3\n");
    defer gpa.free(f2);
    defer Dir.deleteFileAbsolute(io(), f1) catch {};
    defer Dir.deleteFileAbsolute(io(), f2) catch {};

    try expectParity(&.{ "-z", f1, f2 }, null, "a\nb\nc\n\t1\n2\n3\n\x00", 0);
}

// ===========================================================================
// AUDIT FINDING #4 (MEDIUM): invalid options must error with exit 1.
// ===========================================================================

test "invalid short option exits 1 with empty stdout" {
    const gpa = std.testing.allocator;
    const f1 = try writeFixture(gpa, "f1", "a\nb\n");
    defer gpa.free(f1);
    defer Dir.deleteFileAbsolute(io(), f1) catch {};

    try expectParity(&.{ "-x", f1 }, null, "", 1);
}

test "unrecognized long option exits 1 with empty stdout" {
    const gpa = std.testing.allocator;
    const f1 = try writeFixture(gpa, "f1", "a\nb\n");
    defer gpa.free(f1);
    defer Dir.deleteFileAbsolute(io(), f1) catch {};

    try expectParity(&.{ "--foobar", f1 }, null, "", 1);
}

// ===========================================================================
// AUDIT FINDING #5 (MEDIUM): serial mode must exit 1 on an unreadable operand,
// while still emitting the readable file's output.
//   (gpaste -s /nonexistent f1  ->  stdout 'a\tb\tc\n', exit 1)
// ===========================================================================

test "serial: unreadable operand yields exit 1 but still emits good file" {
    const gpa = std.testing.allocator;
    const f1 = try writeFixture(gpa, "f1", "a\nb\nc\n");
    defer gpa.free(f1);
    defer Dir.deleteFileAbsolute(io(), f1) catch {};

    try expectParity(&.{ "-s", "/zpaste_nonexistent_path_9z", f1 }, null, "a\tb\tc\n", 1);
}

// ===========================================================================
// AUDIT FINDING #7 (LOW): a delimiter list ending in an unescaped backslash is
// an error (exit 1), not a literal trailing backslash.
// ===========================================================================

test "delimiter: trailing unescaped backslash is rejected (exit 1)" {
    const gpa = std.testing.allocator;
    const f1 = try writeFixture(gpa, "f1", "a\nb\n");
    defer gpa.free(f1);
    const f2 = try writeFixture(gpa, "f2", "1\n2\n");
    defer gpa.free(f2);
    defer Dir.deleteFileAbsolute(io(), f1) catch {};
    defer Dir.deleteFileAbsolute(io(), f2) catch {};

    try expectParity(&.{ "-dx\\", f1, f2 }, null, "", 1);
}

// ===========================================================================
// AUDIT FINDING #8 (LOW): `--` ends option parsing. `paste -- -s` must treat
// `-s` as a filename (which does not exist -> exit 1), NOT as the serial flag.
// If `--` were ignored, `-s` would be parsed as the flag and, with stdin from
// /dev/null, the process would exit 0. So exit-code parity with GNU is the
// discriminating anchor here.  (gpaste -- -s </dev/null  ->  exit 1)
// ===========================================================================

test "end-of-options marker: -s after -- is a filename, not a flag" {
    try expectParity(&.{ "--", "-s" }, null, "", 1);
}

// ===========================================================================
// AUDIT FINDING #6 (LOW): --version / --help go to STDOUT (rc 0), not stderr.
// GNU writes both to stdout and exits 0; the exact text differs from GNU so we
// anchor to the documented routing/exit contract rather than GNU's bytes.
// ===========================================================================

test "--version writes to stdout and exits 0" {
    const gpa = std.testing.allocator;
    const z = try run(gpa, zpaste_bin, &.{"--version"}, null);
    defer z.deinit(gpa);
    try std.testing.expectEqual(@as(i32, 0), z.code);
    try std.testing.expect(z.stdout.len > 0);
    try std.testing.expectEqualSlices(u8, "", z.stderr);
}

test "--help writes to stdout and exits 0" {
    const gpa = std.testing.allocator;
    const z = try run(gpa, zpaste_bin, &.{"--help"}, null);
    defer z.deinit(gpa);
    try std.testing.expectEqual(@as(i32, 0), z.code);
    try std.testing.expect(z.stdout.len > 0);
    try std.testing.expectEqualSlices(u8, "", z.stderr);
}
