//! Externally-anchored tests for zarch (GNU `arch` clone).
//!
//! ANCHOR NOTE (per zig-forge/CLAUDE.md golden rule §1):
//! No GNU `arch` binary is installed on this host (neither
//! /opt/homebrew/opt/coreutils/libexec/gnubin/arch nor /opt/homebrew/bin/garch
//! exist). GNU `arch` is documented as equivalent to `uname -m`
//! (coreutils manual, "arch: Print machine hardware name"). So the primary
//! anchor here is the system `/usr/bin/uname -m` binary — a real, external,
//! non-zarch program this repo did not write — whose `-m` output GNU `arch`
//! is defined to reproduce byte-for-byte. That comparison catches the critical
//! struct-layout / wrong-offset bug (pre-fix macOS printed a hostname fragment
//! or crashed). The remaining tests anchor to documented GNU behavior:
//!   - non-option operand  -> "extra operand" diagnostic, exit 1
//!   - "--"                -> end-of-options terminator, prints arch, exit 0
//!   - unknown option      -> diagnostic + exit 1
//! These are NOT roundtrip tests: expected bytes/exit codes come from an
//! external binary (`uname -m`) and from the documented GNU contract.
//!
//! If `/usr/bin/uname` is missing, the comparison test SkipZigTests rather
//! than silently passing.

const std = @import("std");
const build_options = @import("build_options");

const ZARCH: []const u8 = build_options.zarch_exe;
const UNAME: []const u8 = "/usr/bin/uname";
const io = std.testing.io;

fn unameAvailable() bool {
    _ = std.Io.Dir.cwd().statFile(io, UNAME, .{}) catch return false;
    return true;
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,
    crashed: bool,

    fn free(self: RunResult, alloc: std.mem.Allocator) void {
        alloc.free(self.stdout);
        alloc.free(self.stderr);
    }
};

fn run(alloc: std.mem.Allocator, argv: []const []const u8) !RunResult {
    const res = try std.process.run(alloc, io, .{ .argv = argv });
    return switch (res.term) {
        .exited => |c| .{ .stdout = res.stdout, .stderr = res.stderr, .code = c, .crashed = false },
        else => .{ .stdout = res.stdout, .stderr = res.stderr, .code = 0, .crashed = true },
    };
}

// PRIMARY EXTERNAL ANCHOR: zarch (no args) must reproduce `/usr/bin/uname -m`
// byte-for-byte. GNU `arch` is documented as equivalent to `uname -m`. On the
// pre-fix code, macOS printed a fragment of the hostname (or crashed via the
// undersized stack buffer), so this diff would go RED.
test "zarch output equals `uname -m` (external anchor)" {
    if (!unameAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ZARCH});
    defer got.free(alloc);
    try std.testing.expect(!got.crashed);
    try std.testing.expectEqual(@as(u8, 0), got.code);

    const want = try run(alloc, &.{ UNAME, "-m" });
    defer want.free(alloc);
    try std.testing.expect(!want.crashed);
    try std.testing.expectEqual(@as(u8, 0), want.code);

    try std.testing.expect(got.stdout.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, got.stdout, "\n"));
    try std.testing.expectEqualStrings(want.stdout, got.stdout);
}

// The printed arch must be a single clean line with no embedded NULs — proves
// we sliced to the terminator, not printed a whole fixed-size field (the
// pre-fix bug walked past field boundaries into adjacent stack memory).
test "arch is a clean non-empty token with single trailing newline" {
    const alloc = std.testing.allocator;
    const got = try run(alloc, &.{ZARCH});
    defer got.free(alloc);

    try std.testing.expect(!got.crashed);
    try std.testing.expectEqual(@as(u8, 0), got.code);
    try std.testing.expect(got.stdout.len >= 2); // at least one char + newline
    try std.testing.expectEqual(@as(u8, '\n'), got.stdout[got.stdout.len - 1]);
    try std.testing.expect(std.mem.indexOfScalar(u8, got.stdout, 0) == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.stdout, "\n"));
}

// Documented GNU behavior: a non-option operand yields an "extra operand"
// diagnostic on stderr and exit status 1, with nothing on stdout.
test "non-option operand -> extra operand, exit 1" {
    const alloc = std.testing.allocator;
    const got = try run(alloc, &.{ ZARCH, "foo" });
    defer got.free(alloc);

    try std.testing.expect(!got.crashed);
    try std.testing.expectEqual(@as(u8, 1), got.code);
    try std.testing.expectEqualStrings("", got.stdout);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "extra operand") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "foo") != null);
}

// Documented GNU getopt behavior: "--" terminates option processing. With no
// operand following it, `arch` prints the machine arch and exits 0 — same as
// no args.
test "-- end-of-options prints arch, exit 0" {
    const alloc = std.testing.allocator;
    const plain = try run(alloc, &.{ZARCH});
    defer plain.free(alloc);
    const dashed = try run(alloc, &.{ ZARCH, "--" });
    defer dashed.free(alloc);

    try std.testing.expect(!dashed.crashed);
    try std.testing.expectEqual(@as(u8, 0), dashed.code);
    try std.testing.expectEqualStrings(plain.stdout, dashed.stdout);
}

// After "--", any following argument is an operand, not an option.
test "-- then operand -> extra operand, exit 1" {
    const alloc = std.testing.allocator;
    const got = try run(alloc, &.{ ZARCH, "--", "-x" });
    defer got.free(alloc);

    try std.testing.expectEqual(@as(u8, 1), got.code);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "extra operand") != null);
}

// Documented GNU behavior: an unknown option is rejected (exit 1), not
// treated as an operand.
test "unknown option -> exit 1" {
    const alloc = std.testing.allocator;
    const got = try run(alloc, &.{ ZARCH, "-x" });
    defer got.free(alloc);

    try std.testing.expectEqual(@as(u8, 1), got.code);
    try std.testing.expectEqualStrings("", got.stdout);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "unrecognized option") != null);
}

// --version prints an identifying line on stdout and exits 0.
test "--version exits 0 with a version line" {
    const alloc = std.testing.allocator;
    const got = try run(alloc, &.{ ZARCH, "--version" });
    defer got.free(alloc);

    try std.testing.expectEqual(@as(u8, 0), got.code);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "zarch") != null);
}

// --help prints usage on stdout and exits 0.
test "--help exits 0 with usage" {
    const alloc = std.testing.allocator;
    const got = try run(alloc, &.{ ZARCH, "--help" });
    defer got.free(alloc);

    try std.testing.expectEqual(@as(u8, 0), got.code);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "Usage") != null);
}
