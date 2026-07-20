//! Externally-anchored tests for zwhoami (GNU `whoami` clone).
//!
//! ANCHOR NOTE (per zig-forge/CLAUDE.md golden rule §1):
//! The real GNU coreutils `whoami` binary IS installed on this host as
//! /opt/homebrew/opt/coreutils/libexec/gnubin/whoami (GNU coreutils 9.10).
//! That binary — a real, external program this repo did not write — is the
//! primary anchor:
//!
//!   PRIMARY DIFF: `zwhoami` (no args) stdout must equal GNU `whoami` (no args)
//!   stdout byte-for-byte. Both print getpwuid(geteuid())->pw_name + newline;
//!   this is a true cross-implementation comparison, not a roundtrip.
//!
//! The remaining tests anchor each argument-handling behavior to the SAME GNU
//! binary's observed exit status (help/version -> 0, extra operand / unknown
//! option -> 1) and to the documented GNU getopt_long contract:
//!   - --help / --version honored in ANY position (permutation) and via
//!     abbreviation (--v, --he), printed to stdout, exit 0
//!   - the FIRST acting option token wins (`-x --help` -> invalid option, not help)
//!   - a non-option operand -> "extra operand" diagnostic, exit 1
//!   - an unknown short option -> "invalid option" diagnostic, exit 1
//!   - an unknown long option  -> "unrecognized option" diagnostic, exit 1
//!   - "--" terminates options; alone it prints the user name (exit 0);
//!     followed by an operand -> extra operand (exit 1)
//!   - `-h` is NOT a help alias in GNU whoami: it is an invalid option (exit 1)
//!
//! Program-name PREFIX ('zwhoami:' vs GNU 'whoami:') and quote glyphs (ASCII
//! ' vs GNU unicode ‘’) differ by z-util convention, so error tests assert on
//! GNU's EXIT CODE + the stable substring ("extra operand", "invalid option",
//! "unrecognized option"), never on the exact prefix/quote bytes. GNU's --help
//! body also embeds an absolute argv[0] path and OSC-8 hyperlinks, so help/
//! version CONTENT is anchored on GNU's exit code + a stable substring, not the
//! full body.
//!
//! These are NOT roundtrip tests: expected stdout bytes and exit codes come
//! from an external GNU binary and the documented GNU contract.
//!
//! If the GNU whoami binary is missing, the diff tests SkipZigTest rather than
//! silently passing.

const std = @import("std");
const build_options = @import("build_options");

const ZWHOAMI: []const u8 = build_options.zwhoami_exe;
const GWHOAMI: []const u8 = "/opt/homebrew/opt/coreutils/libexec/gnubin/whoami";
const io = std.testing.io;

fn gnuAvailable() bool {
    _ = std.Io.Dir.cwd().statFile(io, GWHOAMI, .{}) catch return false;
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

// PRIMARY EXTERNAL ANCHOR: zwhoami (no args) must reproduce GNU whoami
// (no args) stdout byte-for-byte. Both print getpwuid(geteuid())->pw_name + \n.
test "zwhoami output equals GNU whoami (external anchor)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ZWHOAMI});
    defer got.free(alloc);
    const want = try run(alloc, &.{GWHOAMI});
    defer want.free(alloc);

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

// --help: exit code matches GNU (0) and usage goes to STDOUT (not stderr).
// Pre-fix, zwhoami wrote usage to stderr; this test would go RED on that.
test "--help matches GNU exit 0 with usage on stdout" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZWHOAMI, "--help" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GWHOAMI, "--help" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 0), got.code);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "Usage") != null);
    try std.testing.expectEqualStrings("", got.stderr);
}

// --version: GNU exits 0 and prints an identifying line on STDOUT. Pre-fix,
// zwhoami wrote to stderr, so stdout was empty (breaks `zwhoami --version | grep`).
test "--version matches GNU exit 0 with tool line on stdout" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZWHOAMI, "--version" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GWHOAMI, "--version" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 0), got.code);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "zwhoami") != null);
    try std.testing.expectEqualStrings("", got.stderr);

    // Anchor against the actual user name: --version output must NOT equal it.
    const plain = try run(alloc, &.{ZWHOAMI});
    defer plain.free(alloc);
    if (plain.code == 0) {
        try std.testing.expect(!std.mem.eql(u8, plain.stdout, got.stdout));
    }
}

// --version via getopt abbreviation must behave like the full flag (exit 0).
test "--v abbreviation behaves as --version (exit 0)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZWHOAMI, "--v" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GWHOAMI, "--v" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 0), got.code);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "zwhoami") != null);
}

// --help via getopt abbreviation (--he) -> exit 0, usage on stdout.
test "--he abbreviation behaves as --help (exit 0)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZWHOAMI, "--he" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GWHOAMI, "--he" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 0), got.code);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "Usage") != null);
}

// Extra operand: GNU exits 1 with an "extra operand" diagnostic on stderr and
// nothing on stdout. Pre-fix, zwhoami printed the user name and exited 0.
test "extra operand matches GNU exit 1" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZWHOAMI, "foo" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GWHOAMI, "foo" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 1), got.code);
    try std.testing.expectEqualStrings("", got.stdout);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "extra operand") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "foo") != null);
}

// Unknown short option: GNU exits 1 with "invalid option -- 'x'".
test "unknown short option matches GNU exit 1" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZWHOAMI, "-x" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GWHOAMI, "-x" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 1), got.code);
    try std.testing.expectEqualStrings("", got.stdout);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "invalid option") != null);
    // The option name must appear verbatim ('x'), NOT with a stray dash.
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "'x'") != null);
}

// `-h` is NOT a help alias in GNU whoami: it is an invalid option (exit 1).
// Pre-fix, zwhoami accepted -h as help (exit 0 + usage) — this test bites that.
test "-h is an invalid option not a help alias (matches GNU exit 1)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZWHOAMI, "-h" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GWHOAMI, "-h" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 1), got.code);
    try std.testing.expectEqualStrings("", got.stdout);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "invalid option") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "'h'") != null);
}

// Unknown long option: GNU exits 1 with "unrecognized option '--bogus'".
// Pre-fix, zwhoami emitted the mangled "invalid option -- '-bogus'".
test "unknown long option matches GNU exit 1 with verbatim name" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZWHOAMI, "--bogus" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GWHOAMI, "--bogus" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 1), got.code);
    try std.testing.expectEqualStrings("", got.stdout);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "unrecognized option") != null);
    // Full option printed verbatim, not with a dash stripped.
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "--bogus") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "'-bogus'") == null);
}

// --help honored in a non-leading position (getopt permutation). GNU prints
// usage, exit 0.
test "--help after an operand still prints usage (permutation, exit 0)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZWHOAMI, "foo", "--help" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GWHOAMI, "foo", "--help" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 0), got.code);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "Usage") != null);
}

// getopt processing order: the FIRST option token decides. `-x --help` must be
// rejected as an invalid option (exit 1), NOT print help — matching GNU.
test "invalid option before --help wins (exit 1, matches GNU)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZWHOAMI, "-x", "--help" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GWHOAMI, "-x", "--help" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 1), got.code);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "invalid option") != null);
}

// "--" terminates option processing; with no following operand it prints the
// user name and exits 0 — identical to no args (documented GNU getopt).
test "-- alone prints user name, exit 0 (matches GNU)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZWHOAMI, "--" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GWHOAMI, "--" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqualStrings(want.stdout, got.stdout);
}

// After "--", a following argument is an operand, not an option -> exit 1.
test "-- then operand is an extra operand (exit 1, matches GNU)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZWHOAMI, "--", "foo" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GWHOAMI, "--", "foo" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 1), got.code);
    try std.testing.expectEqualStrings("", got.stdout);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "extra operand") != null);
}
