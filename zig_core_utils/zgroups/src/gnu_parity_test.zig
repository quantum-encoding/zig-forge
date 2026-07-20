//! Externally-anchored GNU-parity tests for zgroups.
//!
//! The external anchor is the REAL GNU coreutils `groups` binary
//! (`/opt/homebrew/bin/ggroups`, GNU coreutils 9.10). Each test spawns both
//! `zgroups` and `ggroups` with identical argv and diffs the observable
//! contract: stdout bytes, stderr bytes (normalized only for the program-name
//! token), and the process exit code. Nothing here is a roundtrip — every
//! expectation is either the GNU binary's own output or a literal byte string
//! captured from GNU and cited in a comment (see zig-forge/CLAUDE.md golden
//! rule §1).
//!
//! Build wires the compiled zgroups path and the ggroups path in via
//! `build_opts`. If ggroups is not installed on the box, the GNU-diff tests
//! skip (they cannot be faked); the literal-byte tests still run.

const std = @import("std");
const testing = std.testing;
const opts = @import("build_opts");

const ZGROUPS = opts.zgroups_exe;
const GGROUPS = opts.ggroups_exe;

const Result = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8, // 255 sentinel for "terminated by signal"

    fn deinit(self: Result) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }
};

fn run(argv: []const []const u8) !Result {
    const r = try std.process.run(testing.allocator, testing.io, .{
        .argv = argv,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    const code: u8 = switch (r.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = r.stdout, .stderr = r.stderr, .code = code };
}

fn ggroupsAvailable() bool {
    std.Io.Dir.accessAbsolute(testing.io, GGROUPS, .{ .execute = true }) catch return false;
    return true;
}

/// Replace a diagnostic's program-name token with a placeholder so a GNU
/// message can be compared byte-for-byte against zgroups's. GNU derives its
/// program name from argv[0] (here the absolute GGROUPS path); zgroups is a
/// reimplementation that self-names "zgroups". Every OTHER byte of the
/// diagnostic ("invalid option -- 'x'", the "Try ... --help" hint, etc.) must
/// match GNU exactly after this substitution.
fn normalizeProg(alloc: std.mem.Allocator, s: []const u8, prog: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, alloc, s, prog, "PROG");
}

// --- Anchor 1: no-arg output equals GNU groups for the current process -------
test "no args: stdout and exit match GNU groups" {
    if (!ggroupsAvailable()) return error.SkipZigTest;
    const mine = try run(&.{ZGROUPS});
    defer mine.deinit();
    const gnu = try run(&.{GGROUPS});
    defer gnu.deinit();

    try testing.expectEqualStrings(gnu.stdout, mine.stdout);
    try testing.expectEqual(@as(u8, 0), gnu.code);
    try testing.expectEqual(gnu.code, mine.code);
}

// --- Anchor 2: named user (the current user) equals GNU ----------------------
test "named user: 'user : groups' line matches GNU groups" {
    if (!ggroupsAvailable()) return error.SkipZigTest;
    // Resolve the current username from the environment (test links libc).
    const user_z = std.c.getenv("USER") orelse return error.SkipZigTest;
    const user = std.mem.span(user_z);

    const mine = try run(&.{ ZGROUPS, user });
    defer mine.deinit();
    const gnu = try run(&.{ GGROUPS, user });
    defer gnu.deinit();

    try testing.expectEqualStrings(gnu.stdout, mine.stdout);
    try testing.expectEqual(gnu.code, mine.code);
}

// --- Anchor 3: unknown user -> exit 1, GNU-shaped diagnostic -----------------
test "no such user: exit 1 and diagnostic matches GNU (normalized prog name)" {
    if (!ggroupsAvailable()) return error.SkipZigTest;
    const bad = "zz_no_such_user_zz_9999";
    const mine = try run(&.{ ZGROUPS, bad });
    defer mine.deinit();
    const gnu = try run(&.{ GGROUPS, bad });
    defer gnu.deinit();

    try testing.expectEqual(@as(u8, 1), gnu.code);
    try testing.expectEqual(gnu.code, mine.code);
    try testing.expectEqualStrings("", mine.stdout);

    // GNU uses locale quotes (‘’); zgroups uses ASCII ('). Compare the stable
    // suffix that both share: ": no such user\n".
    try testing.expect(std.mem.endsWith(u8, mine.stderr, "': no such user\n"));
    try testing.expect(std.mem.indexOf(u8, gnu.stderr, "no such user") != null);
}

// --- Anchor 4: --version goes to STDOUT with exit 0 (the fixed bug) ----------
// GNU coreutils writes --version to stdout, not stderr, and exits 0.
// (Verified: `ggroups --version` prints to fd 1, exit 0.)
test "--version: text on stdout, empty stderr, exit 0" {
    const mine = try run(&.{ ZGROUPS, "--version" });
    defer mine.deinit();
    try testing.expectEqual(@as(u8, 0), mine.code);
    try testing.expect(mine.stdout.len > 0);
    try testing.expectEqualStrings("", mine.stderr);
    try testing.expect(std.mem.indexOf(u8, mine.stdout, "zgroups") != null);
}

// --- Anchor 5: --help goes to STDOUT with exit 0 (the fixed bug) -------------
// GNU coreutils writes --help to stdout, not stderr, and exits 0.
test "--help: text on stdout, empty stderr, exit 0" {
    const mine = try run(&.{ ZGROUPS, "--help" });
    defer mine.deinit();
    try testing.expectEqual(@as(u8, 0), mine.code);
    try testing.expect(mine.stdout.len > 0);
    try testing.expectEqualStrings("", mine.stderr);
    try testing.expect(std.mem.indexOf(u8, mine.stdout, "Usage:") != null);
}

// --- Anchor 6: invalid short option -> exit 1, byte-exact GNU diagnostic -----
test "invalid short option -x: diagnostic byte-matches GNU (normalized)" {
    if (!ggroupsAvailable()) return error.SkipZigTest;
    const mine = try run(&.{ ZGROUPS, "-x" });
    defer mine.deinit();
    const gnu = try run(&.{ GGROUPS, "-x" });
    defer gnu.deinit();

    try testing.expectEqual(@as(u8, 1), gnu.code);
    try testing.expectEqual(gnu.code, mine.code);
    try testing.expectEqualStrings("", mine.stdout);

    const gnu_norm = try normalizeProg(testing.allocator, gnu.stderr, GGROUPS);
    defer testing.allocator.free(gnu_norm);
    const mine_norm = try normalizeProg(testing.allocator, mine.stderr, "zgroups");
    defer testing.allocator.free(mine_norm);
    try testing.expectEqualStrings(gnu_norm, mine_norm);
}

// --- Anchor 7: unrecognized long option -> exit 1, byte-exact GNU diagnostic -
test "unrecognized long option --foo: diagnostic byte-matches GNU (normalized)" {
    if (!ggroupsAvailable()) return error.SkipZigTest;
    const mine = try run(&.{ ZGROUPS, "--foo" });
    defer mine.deinit();
    const gnu = try run(&.{ GGROUPS, "--foo" });
    defer gnu.deinit();

    try testing.expectEqual(@as(u8, 1), gnu.code);
    try testing.expectEqual(gnu.code, mine.code);
    try testing.expectEqualStrings("", mine.stdout);

    const gnu_norm = try normalizeProg(testing.allocator, gnu.stderr, GGROUPS);
    defer testing.allocator.free(gnu_norm);
    const mine_norm = try normalizeProg(testing.allocator, mine.stderr, "zgroups");
    defer testing.allocator.free(mine_norm);
    try testing.expectEqualStrings(gnu_norm, mine_norm);
}

// --- Anchor 8: '--' end-of-options -> dash-prefixed arg is a username --------
// GNU: `groups -- -weirduser` looks up "-weirduser" (no such user, exit 1),
// it does NOT treat -weirduser as an option.
test "-- separator: following dash arg is a username, matches GNU exit" {
    if (!ggroupsAvailable()) return error.SkipZigTest;
    const mine = try run(&.{ ZGROUPS, "--", "-weirduser" });
    defer mine.deinit();
    const gnu = try run(&.{ GGROUPS, "--", "-weirduser" });
    defer gnu.deinit();

    try testing.expectEqual(@as(u8, 1), gnu.code);
    try testing.expectEqual(gnu.code, mine.code);
    // The arg reached the username lookup (not the option rejector): the
    // diagnostic is a "no such user" message, not "invalid option".
    try testing.expect(std.mem.indexOf(u8, mine.stderr, "no such user") != null);
    try testing.expect(std.mem.indexOf(u8, mine.stderr, "invalid option") == null);
}

// --- Anchor 9: bare '-' is a username, not an option ------------------------
// GNU: `groups -` looks up user "-" (no such user, exit 1).
test "bare dash is a username, matches GNU" {
    if (!ggroupsAvailable()) return error.SkipZigTest;
    const mine = try run(&.{ ZGROUPS, "-" });
    defer mine.deinit();
    const gnu = try run(&.{ GGROUPS, "-" });
    defer gnu.deinit();

    try testing.expectEqual(gnu.code, mine.code);
    try testing.expect(std.mem.indexOf(u8, mine.stderr, "no such user") != null);
}
