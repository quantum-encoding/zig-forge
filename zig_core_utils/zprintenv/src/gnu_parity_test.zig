//! Externally-anchored tests for zprintenv (GNU `printenv` clone).
//!
//! ANCHOR NOTE (per zig-forge/CLAUDE.md golden rule §1):
//! The real GNU coreutils `printenv` binary IS installed on this host as
//! /opt/homebrew/bin/gprintenv (GNU coreutils 9.10). That binary — a real,
//! external program this repo did not write — is the PRIMARY anchor.
//!
//! Both the freshly-built `zprintenv` and GNU `gprintenv` are spawned as
//! children of THIS test process, so they inherit the exact same environment
//! (identical `environ` array via execve). Every diff test therefore compares
//! two implementations reading the same input — a true cross-implementation
//! comparison, NOT a roundtrip. Expected stdout bytes and exit codes come from
//! the external GNU binary, never from zprintenv's own output.
//!
//! Program-name PREFIX ('zprintenv:' vs GNU 'gprintenv:') differs by z-util
//! convention, so error tests assert on GNU's EXIT CODE + the stable substring
//! ("invalid option", "unrecognized option") for the GNU side, and on the exact
//! zprintenv diagnostic bytes for our side.
//!
//! If /opt/homebrew/bin/gprintenv is missing, the diff tests SkipZigTest rather
//! than silently passing.

const std = @import("std");
const build_options = @import("build_options");

const ZPRINTENV: []const u8 = build_options.zprintenv_exe;
const GPRINTENV: []const u8 = "/opt/homebrew/bin/gprintenv";
const io = std.testing.io;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

// A NAME longer than 255 bytes: the pre-fix code capped name copies at a 256-byte
// buffer and silently skipped anything larger (audit finding #5).
const LONG_NAME = "ZPTEST_LONG_" ++ ("x" ** 300);

/// Populate a known, deterministic set of environment variables in THIS process
/// so that both spawned children inherit identical state. Idempotent.
fn ensureEnv() void {
    _ = setenv("ZPTEST_A", "alpha", 1);
    _ = setenv("ZPTEST_B", "bravo bravo", 1); // embedded space
    _ = setenv("ZPTEST_EMPTY", "", 1); // empty value
    _ = setenv("ZPTEST_SPECIAL", "x=y;z\td$w", 1); // special chars
    _ = setenv("-weird-name", "dashval", 1); // name begins with '-'
    _ = setenv(LONG_NAME, "hooray", 1); // name > 255 bytes
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

fn gnuAvailable() bool {
    _ = std.Io.Dir.cwd().statFile(io, GPRINTENV, .{}) catch return false;
    return true;
}

/// Run the same argv (minus argv[0]) against both binaries and assert byte-exact
/// stdout + identical exit code. `extra` is appended after the program name.
fn expectMatch(alloc: std.mem.Allocator, extra: []const []const u8) !void {
    ensureEnv();

    var z = std.ArrayList([]const u8).empty;
    defer z.deinit(alloc);
    try z.append(alloc, ZPRINTENV);
    try z.appendSlice(alloc, extra);

    var g = std.ArrayList([]const u8).empty;
    defer g.deinit(alloc);
    try g.append(alloc, GPRINTENV);
    try g.appendSlice(alloc, extra);

    const got = try run(alloc, z.items);
    defer got.free(alloc);
    const want = try run(alloc, g.items);
    defer want.free(alloc);

    try std.testing.expect(!got.crashed);
    try std.testing.expect(!want.crashed);
    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqualStrings(want.stdout, got.stdout);
}

// ---------------------------------------------------------------------------
// PRIMARY EXTERNAL ANCHOR: whole-environment dump must match GNU byte-for-byte.
// Both children inherit the identical environ; iteration order is identical.
test "no args: full environment dump equals GNU byte-for-byte" {
    if (!gnuAvailable()) return error.SkipZigTest;
    try expectMatch(std.testing.allocator, &.{});
}

test "single present variable equals GNU" {
    if (!gnuAvailable()) return error.SkipZigTest;
    try expectMatch(std.testing.allocator, &.{"ZPTEST_A"});
}

test "empty-valued variable equals GNU (prints bare newline)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    try expectMatch(std.testing.allocator, &.{"ZPTEST_EMPTY"});
}

test "value with spaces and special chars equals GNU" {
    if (!gnuAvailable()) return error.SkipZigTest;
    try expectMatch(std.testing.allocator, &.{"ZPTEST_SPECIAL"});
}

test "multiple variables (present + present) equals GNU" {
    if (!gnuAvailable()) return error.SkipZigTest;
    try expectMatch(std.testing.allocator, &.{ "ZPTEST_A", "ZPTEST_B" });
}

// Missing NAME -> exit 1 in GNU; present ones still print. Anchored to GNU code.
test "missing variable exits 1 (matches GNU)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    ensureEnv();
    const want = try run(alloc, &.{ GPRINTENV, "ZPTEST_DOES_NOT_EXIST" });
    defer want.free(alloc);
    try std.testing.expectEqual(@as(u8, 1), want.code); // confirm the anchor's expectation
    try expectMatch(alloc, &.{"ZPTEST_DOES_NOT_EXIST"});
}

test "present then missing: prints present, exit 1 (matches GNU)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    try expectMatch(std.testing.allocator, &.{ "ZPTEST_A", "ZPTEST_DOES_NOT_EXIST", "ZPTEST_B" });
}

// -0 / --null: NUL line terminator.
test "-0 with present variable equals GNU (NUL terminator)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    try expectMatch(std.testing.allocator, &.{ "-0", "ZPTEST_A" });
}

test "--null full dump equals GNU (NUL terminator)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    try expectMatch(std.testing.allocator, &.{"--null"});
}

// FINDING #5: NAME > 255 bytes. Pre-fix zprintenv silently skipped it (256-byte
// bufPrintZ overflow -> `catch continue`); GNU prints the value, exit 0.
test "variable name longer than 255 bytes equals GNU" {
    if (!gnuAvailable()) return error.SkipZigTest;
    try expectMatch(std.testing.allocator, &.{LONG_NAME});
}

// FINDING #4: more than 64 NAME operands. Pre-fix zprintenv capped Config.names
// at 64 and dropped the rest, so a present var at position 65+ printed nothing.
// GNU has no limit.
test "more than 64 name operands: present var past index 63 still prints (matches GNU)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(alloc);
    var i: usize = 0;
    while (i < 64) : (i += 1) try names.append(alloc, "ZPTEST_DOES_NOT_EXIST");
    try names.append(alloc, "ZPTEST_A"); // present, at position 65
    try expectMatch(alloc, names.items);
}

// FINDING #2 (--): "--" ends option parsing; a following NAME starting with '-'
// must be LOOKED UP, not parsed as an option. "-weird-name" is present here.
test "-- then name starting with dash is looked up (matches GNU)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    try expectMatch(std.testing.allocator, &.{ "--", "-weird-name" });
}

// FINDING #2 (--): pre-fix `-- --null` misparsed --null as the -0 flag and
// NUL-dumped everything. GNU treats --null as a (missing) NAME -> exit 1.
test "-- --null treats --null as a NAME, exit 1 (matches GNU)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    try expectMatch(std.testing.allocator, &.{ "--", "--null" });
}

// GNU stop-at-first-operand: once a NAME is seen, later '-0' is a NAME, not a
// flag. Pre-fix zprintenv scanned ALL args for flags (wrong for GNU parity).
test "operand stops option scan: trailing -0 is a missing NAME (matches GNU)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    try expectMatch(std.testing.allocator, &.{ "ZPTEST_A", "-0", "ZPTEST_B" });
}

// FINDING #1 (SECURITY): an unrecognized short option must be a FATAL error
// (GNU: "invalid option", exit 2) — NOT silently ignored and NOT a fall-through
// that dumps the entire environment (which would leak every secret on a typo).
test "unknown short option -x: exit 2, empty stdout, diagnostic (matches GNU code)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    ensureEnv();

    const got = try run(alloc, &.{ ZPRINTENV, "-x" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GPRINTENV, "-x" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 2), got.code);
    // The whole point: a mistyped flag must NOT dump the environment.
    try std.testing.expectEqualStrings("", got.stdout);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "invalid option -- 'x'") != null);
    // And it must not have leaked our known secret-shaped var.
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "alpha") == null);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "alpha") == null);
}

// FINDING #1: unknown long option -> "unrecognized option", exit 2.
test "unknown long option --foo: exit 2, empty stdout (matches GNU code)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    ensureEnv();

    const got = try run(alloc, &.{ ZPRINTENV, "--foo" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GPRINTENV, "--foo" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 2), got.code);
    try std.testing.expectEqualStrings("", got.stdout);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "unrecognized option '--foo'") != null);
}

// Short-option cluster: `-0F` -> '0' ok, 'F' invalid -> exit 2 (matches GNU).
test "short cluster -0FOO: invalid option F, exit 2 (matches GNU code)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    ensureEnv();

    const got = try run(alloc, &.{ ZPRINTENV, "-0FOO" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GPRINTENV, "-0FOO" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 2), got.code);
    try std.testing.expectEqualStrings("", got.stdout);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "invalid option -- 'F'") != null);
}

// FINDING #3: --help / --version go to STDOUT with exit 0 (pre-fix: stderr).
test "--help: exit 0, usage on stdout, empty stderr (matches GNU code)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZPRINTENV, "--help" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GPRINTENV, "--help" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 0), got.code);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "Usage") != null);
    try std.testing.expectEqualStrings("", got.stderr);
}

test "--version: exit 0, identifies tool on stdout, empty stderr (matches GNU code)" {
    if (!gnuAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ ZPRINTENV, "--version" });
    defer got.free(alloc);
    const want = try run(alloc, &.{ GPRINTENV, "--version" });
    defer want.free(alloc);

    try std.testing.expectEqual(want.code, got.code);
    try std.testing.expectEqual(@as(u8, 0), got.code);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "zprintenv") != null);
    try std.testing.expectEqualStrings("", got.stderr);
}
