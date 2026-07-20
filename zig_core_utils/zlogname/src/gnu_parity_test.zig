//! Externally-anchored tests for zlogname (GNU `logname` clone).
//!
//! ANCHOR NOTE (per zig-forge/CLAUDE.md golden rule §1):
//! The real GNU coreutils `logname` binary IS installed on this host as
//! /opt/homebrew/bin/glogname (GNU coreutils 9.10). That binary — a real,
//! external program this repo did not write — is the primary anchor:
//!
//!   PRIMARY DIFF: `zlogname` (no args) stdout must equal `glogname` (no args)
//!   stdout byte-for-byte. Both read the login name from getlogin(); this is a
//!   true cross-implementation comparison, not a roundtrip.
//!
//! The remaining tests anchor each argument-handling behavior to the SAME GNU
//! binary's observed exit status (help/version -> 0, extra operand / unknown
//! option -> 1) and to the documented GNU getopt_long contract:
//!   - --help / --version honored in ANY position (permutation) and via
//!     abbreviation (--v, --he), printed to stdout, exit 0
//!   - the FIRST acting option token wins (`-x --help` -> invalid option, not help)
//!   - a non-option operand -> "extra operand" diagnostic, exit 1
//!   - an unknown option    -> diagnostic, exit 1
//!   - "--" terminates options; alone it prints the login name (exit 0)
//!
//! Program-name PREFIX ('zlogname:' vs GNU 'logname:') and quote glyphs (ASCII
//! ' vs GNU unicode ‘’) differ by z-util convention, so error tests assert on
//! GNU's EXIT CODE + the stable substring ("extra operand", "invalid option",
//! "unrecognized option"), never on the exact prefix/quote bytes.
//!
//! These are NOT roundtrip tests: expected stdout bytes and exit codes come
//! from an external GNU binary and the documented GNU contract.
//!
//! If /opt/homebrew/bin/glogname is missing, the diff test SkipZigTests
//! rather than silently passing.

const std = @import("std");
const build_options = @import("build_options");

const ZLOGNAME: []const u8 = build_options.zlogname_exe;
const GLOGNAME: []const u8 = "/opt/homebrew/bin/glogname";
const io = std.testing.io;

fn gnuAvailable() bool {
    _ = std.Io.Dir.cwd().statFile(io, GLOGNAME, .{}) catch return false;
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

// PRIMARY EXTERNAL ANCHOR: zlogname (no args) must reproduce GNU glogname
// (no args) stdout byte-for-byte. Both print getlogin()'s result + newline.
test "zlogname output equals GNU glogname (external anchor)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ZLOGNAME});
    defer got.free(alloc);
    const want = try run(alloc, &.{GLOGNAME});
    defer want.free(alloc);

    // Both must succeed or both must fail identically (e.g. in a CI harness
    // with no controlling tty, getlogin() may fail in both).
    try std.testing.expect(!got.crashed);
    try std.testing.expect(!want.crashed);
    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqualStrings(want.stdout, got.stdout);
    if (want.code == 0) {
        try std.testing.expect(got.stdout.len > 0);
        try std.testing.expect(std.mem.endsWith(u8, got.stdout, "\n"));
        // Single clean line, no embedded NULs (proves we sliced to the NUL
        // terminator, not printed a fixed-size field into adjacent memory).
        try std.testing.expect(std.mem.indexOfScalar(u8, got.stdout, 0) == null);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.stdout, "\n"));
    }
}

// --help: exit code matches GNU (0) and usage goes to stdout.
test "--help matches GNU exit 0 with usage on stdout" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZLOGNAME, "--help" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GLOGNAME, "--help" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 0), got.code);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "Usage") != null);
    try std.testing.expectEqualStrings("", got.stderr);
}

// --version: GNU exits 0 and prints an identifying line on stdout. Pre-fix,
// zlogname ignored the flag and printed the LOGIN NAME with exit 0 (the
// semantically-wrong output the audit flagged) — this test would go RED on that.
test "--version matches GNU exit 0 and does not print the login name" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZLOGNAME, "--version" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GLOGNAME, "--version" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 0), got.code);
    // Must announce the tool, not emit a bare username line.
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "zlogname") != null);

    // Anchor against the actual login name: --version output must NOT equal it.
    const plain = try run(alloc, &.{ZLOGNAME});
    defer plain.free(alloc);
    if (plain.code == 0) {
        try std.testing.expect(!std.mem.eql(u8, plain.stdout, got.stdout));
    }
}

// --version via getopt abbreviation must behave like the full flag (exit 0,
// tool line) — GNU getopt_long accepts unambiguous prefixes.
test "--v abbreviation behaves as --version (exit 0)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZLOGNAME, "--v" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GLOGNAME, "--v" });
    defer want.free(alloc);

    // Version CONTENT differs by tool (GNU announces coreutils; we announce
    // zlogname), so anchor on GNU's exit code + our tool identifying the tool.
    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 0), got.code);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "zlogname") != null);
}

// Extra operand: GNU exits 1 with an "extra operand" diagnostic on stderr and
// nothing on stdout. Pre-fix, zlogname printed the login name and exited 0.
test "extra operand matches GNU exit 1" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZLOGNAME, "foo" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GLOGNAME, "foo" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 1), got.code);
    try std.testing.expectEqualStrings("", got.stdout);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "extra operand") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "foo") != null);
}

// Unknown short option: GNU exits 1 with "invalid option". Pre-fix, silently
// ignored (printed login name, exit 0).
test "unknown short option matches GNU exit 1" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZLOGNAME, "-x" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GLOGNAME, "-x" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 1), got.code);
    try std.testing.expectEqualStrings("", got.stdout);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "invalid option") != null);
}

// Unknown long option: GNU exits 1 with "unrecognized option".
test "unknown long option matches GNU exit 1" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZLOGNAME, "--bogus" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GLOGNAME, "--bogus" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 1), got.code);
    try std.testing.expectEqualStrings("", got.stdout);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "unrecognized option") != null);
}

// --help honored in a non-leading position (getopt permutation). GNU prints
// usage, exit 0. Pre-fix, --help was only recognized as the FIRST arg.
test "--help after an operand still prints usage (permutation, exit 0)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZLOGNAME, "foo", "--help" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GLOGNAME, "foo", "--help" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 0), got.code);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "Usage") != null);
}

// getopt processing order: the FIRST option token decides. `-x --help` must be
// rejected as an invalid option (exit 1), NOT print help — matching GNU, where
// getopt returns the bad option before it reaches --help.
test "invalid option before --help wins (exit 1, matches GNU)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZLOGNAME, "-x", "--help" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GLOGNAME, "-x", "--help" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 1), got.code);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "invalid option") != null);
}

// "--" terminates option processing; with no following operand it prints the
// login name and exits 0 — identical to no args (documented GNU getopt).
test "-- alone prints login name, exit 0 (matches GNU)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZLOGNAME, "--" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GLOGNAME, "--" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqualStrings(want.stdout, got.stdout);
}

// After "--", a following argument is an operand, not an option -> exit 1.
test "-- then operand is an extra operand (exit 1, matches GNU)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZLOGNAME, "--", "foo" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GLOGNAME, "--", "foo" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 1), got.code);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "extra operand") != null);
}
