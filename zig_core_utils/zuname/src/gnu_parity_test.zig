//! Externally-anchored parity tests for `zuname`.
//!
//! The anchor is the real GNU coreutils `uname` binary installed on this host
//! (path injected by build.zig as `build_options.gnu_uname`, default
//! /opt/homebrew/opt/coreutils/libexec/gnubin/uname). For every flag spread we
//! run BOTH `zuname` and GNU `uname` and require byte-identical stdout and
//! identical exit status. Neither the inputs nor the expected outputs are
//! authored by this repo — they come from GNU coreutils 9.10.
//!
//! Where the exact bytes can't be a live diff (error diagnostics embed the
//! program name, which differs), we anchor to *documented* GNU/POSIX behavior:
//! POSIX `uname` and GNU coreutils exit 1 with a diagnostic on invalid options
//! and on extra operands, and route --help/--version to stdout (exit 0).
//!
//! If the GNU binary is absent, the live-diff tests SkipZigTest rather than
//! silently passing; the documented-behavior tests still run against zuname.

const std = @import("std");
const build_options = @import("build_options");
const testing = std.testing;

const ZUNAME = build_options.zuname_bin;
const GNU = build_options.gnu_uname;

const Captured = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *Captured) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }
};

fn termCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |c| c,
        // A signal (e.g. the pre-fix SIGSEGV=134 stack smash) is not exit 0;
        // surface it as a distinct non-zero so parity comparisons catch it.
        else => 255,
    };
}

fn run(bin: []const u8, extra: []const []const u8) !Captured {
    var buf: [16][]const u8 = undefined;
    buf[0] = bin;
    for (extra, 0..) |a, i| buf[i + 1] = a;
    const argv = buf[0 .. extra.len + 1];

    const res = try std.process.run(testing.allocator, testing.io, .{ .argv = argv });
    return .{ .code = termCode(res.term), .stdout = res.stdout, .stderr = res.stderr };
}

fn gnuAvailable() bool {
    var buf: [1024]u8 = undefined;
    if (GNU.len >= buf.len) return false;
    @memcpy(buf[0..GNU.len], GNU);
    buf[GNU.len] = 0;
    // F_OK == 0: test for existence.
    return std.c.access(@ptrCast(&buf), 0) == 0;
}

/// Live diff: zuname's stdout+exit must match the GNU binary for `extra`.
fn expectParity(extra: []const []const u8) !void {
    if (!gnuAvailable()) return error.SkipZigTest;

    var z = try run(ZUNAME, extra);
    defer z.deinit();
    var g = try run(GNU, extra);
    defer g.deinit();

    testing.expectEqualStrings(g.stdout, z.stdout) catch |e| {
        std.debug.print("parity stdout mismatch (first arg: {s})\n  gnu: {s}\n  zig: {s}\n", .{ if (extra.len > 0) extra[0] else "(none)", g.stdout, z.stdout });
        return e;
    };
    testing.expectEqual(g.code, z.code) catch |e| {
        std.debug.print("parity exit mismatch: gnu={d} zig={d}\n", .{ g.code, z.code });
        return e;
    };
}

test "parity: no args (defaults to -s)" {
    try expectParity(&.{});
}

test "parity: single short flags" {
    for ([_][]const u8{ "-s", "-n", "-r", "-v", "-m", "-p", "-i", "-o", "-a" }) |f| {
        try expectParity(&.{f});
    }
}

test "parity: single long flags" {
    for ([_][]const u8{
        "--kernel-name",   "--nodename",
        "--kernel-release", "--kernel-version",
        "--machine",       "--processor",
        "--hardware-platform", "--operating-system",
        "--all",
    }) |f| {
        try expectParity(&.{f});
    }
}

test "parity: bundled short options" {
    try expectParity(&.{"-sr"});
    try expectParity(&.{"-snrvm"});
    try expectParity(&.{"-mo"});
    try expectParity(&.{"-snrvmpio"});
    try expectParity(&.{"-a"});
}

test "parity: multiple separate flags preserve GNU field order" {
    try expectParity(&.{ "-o", "-s" });
    try expectParity(&.{ "-m", "-o" });
    try expectParity(&.{ "-r", "-s" }); // reversed request, GNU emits s then r
}

// --- Documented-behavior anchors (program name differs, so we don't byte-diff
// stderr; we anchor to GNU/POSIX: exit 1 + a diagnostic on stderr). ---

test "invalid option: exit 1 with diagnostic (GNU/POSIX)" {
    var z = try run(ZUNAME, &.{"-z"});
    defer z.deinit();
    try testing.expectEqual(@as(u8, 1), z.code);
    try testing.expect(z.stderr.len > 0);
    try testing.expect(std.mem.indexOf(u8, z.stderr, "invalid option") != null);
    try testing.expectEqualStrings("", z.stdout);
}

test "unrecognized long option: exit 1 with diagnostic" {
    var z = try run(ZUNAME, &.{"--bogus"});
    defer z.deinit();
    try testing.expectEqual(@as(u8, 1), z.code);
    try testing.expect(std.mem.indexOf(u8, z.stderr, "unrecognized option") != null);
}

test "extra operand: exit 1 with diagnostic (GNU/POSIX)" {
    var z = try run(ZUNAME, &.{"foo"});
    defer z.deinit();
    try testing.expectEqual(@as(u8, 1), z.code);
    try testing.expect(z.stderr.len > 0);
    try testing.expect(std.mem.indexOf(u8, z.stderr, "extra operand") != null);
}

test "invalid char inside a bundle still errors" {
    var z = try run(ZUNAME, &.{"-sz"});
    defer z.deinit();
    try testing.expectEqual(@as(u8, 1), z.code);
    try testing.expect(std.mem.indexOf(u8, z.stderr, "invalid option") != null);
}

test "--help goes to stdout with exit 0 (GNU)" {
    var z = try run(ZUNAME, &.{"--help"});
    defer z.deinit();
    try testing.expectEqual(@as(u8, 0), z.code);
    try testing.expect(z.stdout.len > 0);
    try testing.expectEqualStrings("", z.stderr);
    try testing.expect(std.mem.indexOf(u8, z.stdout, "Usage:") != null);
}

test "--version goes to stdout with exit 0 (GNU)" {
    var z = try run(ZUNAME, &.{"--version"});
    defer z.deinit();
    try testing.expectEqual(@as(u8, 0), z.code);
    try testing.expect(z.stdout.len > 0);
    try testing.expectEqualStrings("", z.stderr);
}

// Anchor a concrete documented field: kernel-name on this Darwin host must be
// "Darwin\n" (matches the GNU binary; also the FreeBSD/Darwin utsname sysname).
test "kernel-name is Darwin on this host" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    var z = try run(ZUNAME, &.{"-s"});
    defer z.deinit();
    try testing.expectEqualStrings("Darwin\n", z.stdout);
}
