//! Externally-anchored parity tests for zmore (a `more(1)` clone).
//!
//! These tests exercise the built `zmore` binary as a black box (spawned as a
//! child process with stdout redirected to a pipe, i.e. NOT a TTY) and compare
//! its bytes against behaviour documented for GNU/util-linux `more(1)` and
//! POSIX. Every expected value below is written literally and sourced from an
//! authority the author of this library did not write:
//!
//!   * util-linux `more.c` banner (`::::::::::::::` rule): multi-file
//!     separators are a plain 14-colon rule, the filename, then a second
//!     14-colon rule, printed with no terminal styling. When stdout is not a
//!     terminal, `more` copies the file through unchanged (cat-like) and emits
//!     no ANSI control sequences.
//!       - https://github.com/util-linux/util-linux/blob/master/text-utils/more.c
//!   * POSIX `more` / `man more`: "+number  Start displaying the file at line
//!     number." Line numbering is 1-based, so `+1` shows the file from its
//!     first line and `+2` from its second.
//!       - https://pubs.opengroup.org/onlinepubs/9699919799/utilities/more.html
//!   * POSIX exit status: ">0  An error occurred." An unopenable file operand
//!     is an error, so the utility must exit non-zero.
//!
//! There are deliberately NO decode(encode(x))==x roundtrip tests here; each
//! assertion pins an externally-documented output shape (zig-forge golden rule).
//!
//! Fixture files are created with libc directly (open/write/close) so the
//! tests do not depend on the churning std filesystem/Io API surface.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const ZMORE = build_options.zmore_path;

// open(2) is variadic in C (`int open(const char *, int, ...)`); the mode
// argument is read via va_arg. Declaring a fixed 3rd parameter passes it in a
// register on AArch64 while the callee reads it from the stack, corrupting the
// created file's permissions. Declare it variadic so the mode lands correctly.
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn getpid() c_int;

// open(2) flag values are OS-specific.
const OpenFlags = struct {
    const wronly: c_int = if (builtin.os.tag == .linux) 0o1 else 0x0001;
    const creat: c_int = if (builtin.os.tag == .linux) 0o100 else 0x0200;
    const trunc: c_int = if (builtin.os.tag == .linux) 0o1000 else 0x0400;
    const all: c_int = wronly | creat | trunc;
};

var fixture_counter: u32 = 0;

/// Create a temp fixture file and return its absolute, null-terminated path.
/// Caller frees the returned slice; the underlying file is unlinked by the
/// caller via `unlink` on the same bytes.
fn makeFixture(a: std.mem.Allocator, contents: []const u8) ![:0]u8 {
    fixture_counter += 1;
    const path = try std.fmt.allocPrintSentinel(a, "/tmp/zmore_test_{d}_{d}.txt", .{
        getpid(), fixture_counter,
    }, 0);
    errdefer a.free(path);

    const fd = open(path.ptr, OpenFlags.all, @as(c_uint, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = close(fd);

    var written: usize = 0;
    while (written < contents.len) {
        const n = write(fd, contents.ptr + written, contents.len - written);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
    return path;
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,

    fn deinit(self: RunResult, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

/// Spawn zmore with `args` (stdout is a pipe -> non-TTY path) and capture it.
fn runZmore(a: std.mem.Allocator, args: []const []const u8) !RunResult {
    var argv_buf: [8][]const u8 = undefined;
    std.debug.assert(args.len + 1 <= argv_buf.len);
    argv_buf[0] = ZMORE;
    for (args, 0..) |arg, idx| argv_buf[idx + 1] = arg;
    const argv = argv_buf[0 .. args.len + 1];

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const res = try std.process.run(a, io, .{
        .argv = argv,
    });

    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = res.stdout, .stderr = res.stderr, .code = code };
}

test "single file to a pipe is copied through verbatim (cat-like), exit 0" {
    const a = std.testing.allocator;
    const body = "alpha\nbeta\ngamma\n";
    const path = try makeFixture(a, body);
    defer a.free(path);
    defer _ = unlink(path.ptr);

    const r = try runZmore(a, &.{path});
    defer r.deinit(a);

    // GNU more, non-TTY: pass the file through unchanged.
    try std.testing.expectEqualStrings(body, r.stdout);
    try std.testing.expectEqual(@as(u8, 0), r.code);
}

test "multi-file banner is a plain 14-colon rule with no ANSI escapes" {
    const a = std.testing.allocator;
    const pa = try makeFixture(a, "a1\na2\n");
    defer a.free(pa);
    defer _ = unlink(pa.ptr);
    const pb = try makeFixture(a, "b1\nb2\n");
    defer a.free(pb);
    defer _ = unlink(pb.ptr);

    const r = try runZmore(a, &.{ pa, pb });
    defer r.deinit(a);

    try std.testing.expectEqual(@as(u8, 0), r.code);

    // No terminal styling may reach a pipe.
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "\x1b") == null);

    // The util-linux banner rule is exactly 14 colons (not 13, not 15).
    const rule = "::::::::::::::";
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, rule ++ ":") == null); // never 15+
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, rule) != null);

    // Both file bodies are present.
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "a1\na2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "b1\nb2\n") != null);

    // Count colon-rule lines: two files -> two banners -> 4 rule lines.
    var rules: usize = 0;
    var it = std.mem.splitScalar(u8, r.stdout, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, line, rule)) rules += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), rules);
}

test "+N start line is 1-based per POSIX (+1 = whole file, +2 = from line 2)" {
    const a = std.testing.allocator;
    const body = "L1\nL2\nL3\n";
    const path = try makeFixture(a, body);
    defer a.free(path);
    defer _ = unlink(path.ptr);

    // +1 shows the file from its first line -> unchanged.
    {
        const r = try runZmore(a, &.{ "+1", path });
        defer r.deinit(a);
        try std.testing.expectEqualStrings("L1\nL2\nL3\n", r.stdout);
        try std.testing.expectEqual(@as(u8, 0), r.code);
    }

    // +2 starts at the SECOND line. (Pre-fix this printed "L3\n" only.)
    {
        const r = try runZmore(a, &.{ "+2", path });
        defer r.deinit(a);
        try std.testing.expectEqualStrings("L2\nL3\n", r.stdout);
    }

    // +3 starts at the third line.
    {
        const r = try runZmore(a, &.{ "+3", path });
        defer r.deinit(a);
        try std.testing.expectEqualStrings("L3\n", r.stdout);
    }
}

test "unopenable file operand yields a non-zero exit status (POSIX >0)" {
    const a = std.testing.allocator;
    const r = try runZmore(a, &.{"/no/such/zmore/file/definitely-absent"});
    defer r.deinit(a);
    try std.testing.expect(r.code != 0);
}

test "--lines=N equals-form is accepted (advertised in --help), exit 0" {
    const a = std.testing.allocator;
    const body = "x1\nx2\nx3\nx4\n";
    const path = try makeFixture(a, body);
    defer a.free(path);
    defer _ = unlink(path.ptr);

    const r = try runZmore(a, &.{ "--lines=2", path });
    defer r.deinit(a);

    // Must not be rejected as an invalid option (pre-fix: "invalid option -- '-'").
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "invalid option") == null);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    // Non-TTY output is still the full file (paging only applies to a terminal).
    try std.testing.expectEqualStrings(body, r.stdout);
}
