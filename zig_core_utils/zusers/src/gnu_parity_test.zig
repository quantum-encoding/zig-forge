//! Externally-anchored parity tests for zusers (GNU `users` clone).
//!
//! ANCHOR NOTE (per zig-forge/CLAUDE.md golden rule §1):
//! The PRIMARY external anchor is the real GNU coreutils `users` binary
//! installed on this host (`/opt/homebrew/bin/gusers`, coreutils 9.10) — a
//! program this repo did not write. Two independent anchoring strategies:
//!
//!   1. CRAFTED FIXTURE (deterministic): we synthesize a utmpx database with
//!      known records via the platform libc `pututxline` (the same on-disk
//!      format both binaries read), then run BOTH `gusers FIXTURE` and
//!      `zusers FIXTURE` and require their stdout to be identical AND to equal
//!      a literal expected string. The literal is anchored to documented GNU
//!      behavior: USER_PROCESS records only (BOOT_TIME/LOGIN_PROCESS filtered),
//!      duplicates preserved, sorted in strcmp order, single trailing newline.
//!      (`users` invocation, GNU coreutils manual + users.c `userid_compare`.)
//!
//!   2. LIVE DIFF: `zusers` (no args) must byte-match `gusers` (no args) reading
//!      the live /var/run/utmpx at the same instant — this exercises the real
//!      login state, including the BOOT_TIME record the pre-fix code never saw
//!      (it read a hard-coded Linux glibc struct from /var/run/utmp and printed
//!      NOTHING on macOS).
//!
//! The rest anchor to the documented GNU contract: --help/--version to STDOUT
//! (exit 0), unknown option -> diagnostic + exit 1, extra operand -> exit 1,
//! empty database -> empty output (exit 0). None are roundtrip tests: expected
//! bytes and exit codes come from the external `gusers` binary and the GNU spec.
//!
//! If `gusers` is not installed, the diff tests SkipZigTest rather than
//! silently passing.

const std = @import("std");
const build_options = @import("build_options");
const c = @cImport({
    @cInclude("utmpx.h");
    @cInclude("unistd.h"); // unlink, getpid
    @cInclude("stdlib.h"); // getenv
});

const ZUSERS: []const u8 = build_options.zusers_exe;
const GUSERS: []const u8 = "/opt/homebrew/bin/gusers";
const io = std.testing.io;

// POSIX ut_type values.
const BOOT_TIME: c_short = 2;
const LOGIN_PROCESS: c_short = 6;
const USER_PROCESS: c_short = 7;

fn gusersAvailable() bool {
    _ = std.Io.Dir.cwd().statFile(io, GUSERS, .{}) catch return false;
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
        .exited => |code| .{ .stdout = res.stdout, .stderr = res.stderr, .code = code, .crashed = false },
        else => .{ .stdout = res.stdout, .stderr = res.stderr, .code = 0, .crashed = true },
    };
}

fn addRecord(t: c_short, user: []const u8, line: []const u8, id: []const u8, pid: c_int) void {
    var u = std.mem.zeroes(c.struct_utmpx);
    u.ut_type = t;
    u.ut_pid = pid;
    @memcpy(u.ut_user[0..user.len], user);
    @memcpy(u.ut_line[0..line.len], line);
    @memcpy(u.ut_id[0..id.len], id);
    u.ut_tv.tv_sec = 1234567890;
    _ = c.pututxline(&u);
}

/// Build a utmpx database at `path` (null-terminated) with a fixed set of
/// records via libc — the exact on-disk format both `gusers` and `zusers` read.
/// Records include non-USER_PROCESS entries that must be filtered out.
fn writeFixture(path: [:0]const u8) void {
    // Ensure a clean file: a stale DB would accumulate records across runs.
    _ = c.unlink(path.ptr);
    _ = c.utmpxname(path.ptr);
    c.setutxent();
    addRecord(BOOT_TIME, "", "", "bt", 0); // filtered
    addRecord(USER_PROCESS, "charlie", "ttys003", "c1", 300);
    addRecord(USER_PROCESS, "alice", "ttys001", "a1", 100);
    addRecord(USER_PROCESS, "bob", "ttys002", "b1", 200);
    addRecord(USER_PROCESS, "alice", "ttys004", "a2", 400); // duplicate kept
    addRecord(LOGIN_PROCESS, "login", "ttys009", "lg", 900); // filtered
    c.endutxent();
}

/// Build an empty utmpx database (signature record only, no sessions).
fn writeEmptyFixture(path: [:0]const u8) void {
    _ = c.unlink(path.ptr);
    _ = c.utmpxname(path.ptr);
    c.setutxent();
    c.endutxent();
}

var fixture_seq: u32 = 0;

fn fixturePath(buf: []u8) [:0]const u8 {
    const dir: []const u8 = if (c.getenv("TMPDIR")) |d| std.mem.span(d) else "/tmp/";
    const pid = c.getpid();
    fixture_seq += 1;
    const s = std.fmt.bufPrintZ(buf, "{s}zusers_fix_{d}_{d}.utmpx", .{ dir, pid, fixture_seq }) catch |err|
        std.debug.panic("fixture path did not fit in buffer: {t}", .{err});
    return s;
}

// PRIMARY ANCHOR #1 — crafted fixture, deterministic.
// Sorted, duplicate-preserving, USER_PROCESS-only output, cross-checked against
// GNU `gusers` AND pinned to the literal the GNU contract requires.
test "crafted fixture: matches gusers and documented GNU output" {
    if (!gusersAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var pbuf: [256]u8 = undefined;
    const path = fixturePath(&pbuf);
    writeFixture(path);
    defer _ = c.unlink(path.ptr);

    const want_literal = "alice alice bob charlie\n";

    const gnu = try run(alloc, &.{ GUSERS, path });
    defer gnu.free(alloc);
    try std.testing.expect(!gnu.crashed);
    try std.testing.expectEqual(@as(u8, 0), gnu.code);
    // Confirm the external reference itself agrees with the documented literal.
    try std.testing.expectEqualStrings(want_literal, gnu.stdout);

    const mine = try run(alloc, &.{ ZUSERS, path });
    defer mine.free(alloc);
    try std.testing.expect(!mine.crashed);
    try std.testing.expectEqual(@as(u8, 0), mine.code);
    try std.testing.expectEqualStrings(want_literal, mine.stdout);
}

// PRIMARY ANCHOR #2 — live database diff against the real GNU binary.
// Both read /var/run/utmpx via libc; pre-fix zusers printed nothing here.
test "live utmpx: zusers stdout equals gusers stdout" {
    if (!gusersAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const gnu = try run(alloc, &.{GUSERS});
    defer gnu.free(alloc);
    const mine = try run(alloc, &.{ZUSERS});
    defer mine.free(alloc);

    try std.testing.expect(!gnu.crashed and !mine.crashed);
    try std.testing.expectEqual(@as(u8, 0), gnu.code);
    try std.testing.expectEqual(@as(u8, 0), mine.code);
    try std.testing.expectEqualStrings(gnu.stdout, mine.stdout);
}

// Empty database -> empty output (no trailing newline), exit 0. Cross-checked
// against gusers.
test "empty database: no output, exit 0 (matches gusers)" {
    if (!gusersAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    var pbuf: [256]u8 = undefined;
    const path = fixturePath(&pbuf);
    writeEmptyFixture(path);
    defer _ = c.unlink(path.ptr);

    const gnu = try run(alloc, &.{ GUSERS, path });
    defer gnu.free(alloc);
    const mine = try run(alloc, &.{ ZUSERS, path });
    defer mine.free(alloc);

    try std.testing.expectEqual(@as(u8, 0), gnu.code);
    try std.testing.expectEqual(@as(u8, 0), mine.code);
    try std.testing.expectEqualStrings("", gnu.stdout);
    try std.testing.expectEqualStrings("", mine.stdout);
}

// --help must go to STDOUT (exit 0). The pre-fix bug wrote it to STDERR, so
// `zusers --help > file` produced a 0-byte file.
test "--help writes usage to stdout, exit 0" {
    const alloc = std.testing.allocator;
    const got = try run(alloc, &.{ ZUSERS, "--help" });
    defer got.free(alloc);

    try std.testing.expectEqual(@as(u8, 0), got.code);
    try std.testing.expect(got.stdout.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "Usage") != null);
    try std.testing.expectEqualStrings("", got.stderr);
}

// --version must go to STDOUT (exit 0), not STDERR.
test "--version writes to stdout, exit 0" {
    const alloc = std.testing.allocator;
    const got = try run(alloc, &.{ ZUSERS, "--version" });
    defer got.free(alloc);

    try std.testing.expectEqual(@as(u8, 0), got.code);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "zusers") != null);
    try std.testing.expectEqualStrings("", got.stderr);
}

// Unknown option -> diagnostic on stderr, exit 1, nothing on stdout. The
// pre-fix code silently accepted it and exited 0.
test "unknown option -> unrecognized, exit 1" {
    if (!gusersAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const mine = try run(alloc, &.{ ZUSERS, "--bogus" });
    defer mine.free(alloc);
    try std.testing.expectEqual(@as(u8, 1), mine.code);
    try std.testing.expectEqualStrings("", mine.stdout);
    try std.testing.expect(std.mem.indexOf(u8, mine.stderr, "unrecognized option") != null);

    // Cross-check exit-code parity with the real GNU binary.
    const gnu = try run(alloc, &.{ GUSERS, "--bogus" });
    defer gnu.free(alloc);
    try std.testing.expectEqual(gnu.code, mine.code);
}

// A second positional operand -> "extra operand", exit 1 (GNU accepts one FILE).
test "extra operand -> exit 1" {
    const alloc = std.testing.allocator;
    const got = try run(alloc, &.{ ZUSERS, "a", "b" });
    defer got.free(alloc);

    try std.testing.expectEqual(@as(u8, 1), got.code);
    try std.testing.expectEqualStrings("", got.stdout);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "extra operand") != null);
}

// Unit test for the NUL-terminating field slicer that turns a raw fixed-size
// utmpx ut_user field into a clean username token.
test "nullTerminated trims at embedded NUL and passes through un-terminated" {
    const main = @import("main.zig");
    // Embedded NUL: username is the prefix before the first NUL.
    try std.testing.expectEqualStrings("alice", main.nullTerminated("alice\x00\x00\x00extra"));
    // Leading NUL -> empty (an unused slot).
    try std.testing.expectEqualStrings("", main.nullTerminated("\x00rest"));
    // No NUL at all -> whole buffer passes through unchanged.
    try std.testing.expectEqualStrings("bob", main.nullTerminated("bob"));
}
