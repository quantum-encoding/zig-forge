//! GNU-parity tests for ztty.
//!
//! EXTERNAL ANCHOR: these tests do NOT assert ztty against itself. They spawn
//! the real GNU coreutils `tty` binary (Homebrew, 9.10) alongside the freshly
//! built ztty and compare the observable contract:
//!
//!   * process exit code, for a matrix of argument sets;
//!   * output routing (--help / --version go to STDOUT, not STDERR);
//!   * the exact "not a tty\n" line GNU prints on a non-terminal stdin.
//!
//! stdin for every child is /dev/null (stdin_behavior = .Ignore), so isatty(0)
//! is false and the terminal-name branch is never taken — this makes the tests
//! deterministic under `zig build test` regardless of whether the test runner
//! itself has a controlling tty. The GNU binary is the source of the expected
//! values; ztty is required to match it. See GNU coreutils tty.c and the POSIX
//! `tty` spec for the documented behaviour.

const std = @import("std");
const build_options = @import("build_options");

const ztty_bin = build_options.ztty_bin;
const gnu_tty = build_options.gnu_tty;

const ProcResult = struct {
    exit_code: u8,
    term_ok: bool, // true if the process exited normally (not signalled)
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *ProcResult, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

/// Run `bin` with `args`, capturing stdout/stderr. `std.process.run` always
/// spawns the child with stdin = .ignore (i.e. /dev/null), so isatty(0) is
/// guaranteed false in the child — which is exactly the non-terminal case we
/// want to pin against GNU, deterministically, under `zig build test`.
fn run(a: std.mem.Allocator, bin: []const u8, args: []const []const u8) !ProcResult {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.append(a, bin);
    for (args) |arg| try argv.append(a, arg);

    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const result = try std.process.run(a, io, .{ .argv = argv.items });

    var res = ProcResult{
        .exit_code = 0,
        .term_ok = false,
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
    switch (result.term) {
        .exited => |code| {
            res.exit_code = code;
            res.term_ok = true;
        },
        else => res.term_ok = false,
    }
    return res;
}

/// True when the GNU reference binary is present and runnable; tests skip
/// otherwise so the suite still runs (with reduced anchoring) on machines
/// without coreutils. Probes by actually spawning `tty --version`.
fn gnuAvailable(a: std.mem.Allocator) bool {
    var r = run(a, gnu_tty, &.{"--version"}) catch return false;
    r.deinit(a);
    return true;
}

// A representative matrix of invocations. Each row is compared exit-code-for-
// exit-code against GNU. The `note` is documentation of the behaviour under
// test (a specific gnu_gap from the audit).
const Case = struct {
    args: []const []const u8,
    note: []const u8,
};

const cases = [_]Case{
    .{ .args = &.{}, .note = "no args, stdin not a tty -> exit 1" },
    .{ .args = &.{"-s"}, .note = "-s silent -> exit 1, no output" },
    .{ .args = &.{"--silent"}, .note = "--silent -> exit 1" },
    .{ .args = &.{"--quiet"}, .note = "--quiet alias for -s -> exit 1" },
    .{ .args = &.{"--"}, .note = "-- end of options -> exit 1" },
    .{ .args = &.{"-ss"}, .note = "bundled -ss -> exit 1" },
    .{ .args = &.{"foo"}, .note = "extra operand -> exit 2" },
    .{ .args = &.{"--bogus"}, .note = "unrecognized long option -> exit 2" },
    .{ .args = &.{"-x"}, .note = "invalid short option -> exit 2" },
    .{ .args = &.{"-sx"}, .note = "bundled -sx, bad char x -> exit 2" },
    .{ .args = &.{"--help"}, .note = "--help -> exit 0" },
    .{ .args = &.{"--version"}, .note = "--version -> exit 0" },
    .{ .args = &.{ "--", "foo" }, .note = "operand after -- -> exit 2" },
};

test "exit codes match GNU tty across the argument matrix" {
    const a = std.testing.allocator;
    if (!gnuAvailable(a)) {
        std.debug.print("SKIP: GNU tty not found at {s}\n", .{gnu_tty});
        return error.SkipZigTest;
    }

    var failures: usize = 0;
    for (cases) |c| {
        var gnu = try run(a, gnu_tty, c.args);
        defer gnu.deinit(a);
        var mine = try run(a, ztty_bin, c.args);
        defer mine.deinit(a);

        std.testing.expect(gnu.term_ok and mine.term_ok) catch {
            std.debug.print("crash: {s}\n", .{c.note});
            failures += 1;
            continue;
        };
        std.testing.expectEqual(gnu.exit_code, mine.exit_code) catch {
            std.debug.print(
                "exit mismatch [{s}]: gnu={d} ztty={d}\n",
                .{ c.note, gnu.exit_code, mine.exit_code },
            );
            failures += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "--help writes to stdout not stderr (matches GNU routing)" {
    const a = std.testing.allocator;
    if (!gnuAvailable(a)) return error.SkipZigTest;

    var gnu = try run(a, gnu_tty, &.{"--help"});
    defer gnu.deinit(a);
    var mine = try run(a, ztty_bin, &.{"--help"});
    defer mine.deinit(a);

    // GNU reference: help on stdout, nothing on stderr, exit 0.
    try std.testing.expect(gnu.stdout.len > 0);
    try std.testing.expectEqual(@as(usize, 0), gnu.stderr.len);
    try std.testing.expectEqual(@as(u8, 0), gnu.exit_code);

    // ztty must route the same way.
    try std.testing.expect(mine.stdout.len > 0);
    try std.testing.expectEqual(@as(usize, 0), mine.stderr.len);
    try std.testing.expectEqual(@as(u8, 0), mine.exit_code);
}

test "--version writes to stdout not stderr (matches GNU routing)" {
    const a = std.testing.allocator;
    if (!gnuAvailable(a)) return error.SkipZigTest;

    var gnu = try run(a, gnu_tty, &.{"--version"});
    defer gnu.deinit(a);
    var mine = try run(a, ztty_bin, &.{"--version"});
    defer mine.deinit(a);

    try std.testing.expect(gnu.stdout.len > 0);
    try std.testing.expectEqual(@as(usize, 0), gnu.stderr.len);
    try std.testing.expectEqual(@as(u8, 0), gnu.exit_code);

    try std.testing.expect(mine.stdout.len > 0);
    try std.testing.expectEqual(@as(usize, 0), mine.stderr.len);
    try std.testing.expectEqual(@as(u8, 0), mine.exit_code);
}

test "non-tty stdin prints exactly GNU's 'not a tty' line" {
    const a = std.testing.allocator;
    if (!gnuAvailable(a)) return error.SkipZigTest;

    var gnu = try run(a, gnu_tty, &.{});
    defer gnu.deinit(a);
    var mine = try run(a, ztty_bin, &.{});
    defer mine.deinit(a);

    // The GNU binary is the source of truth for the exact bytes.
    try std.testing.expectEqualStrings("not a tty\n", gnu.stdout);
    try std.testing.expectEqualStrings(gnu.stdout, mine.stdout);
    try std.testing.expectEqual(gnu.exit_code, mine.exit_code);
}

test "-s (silent) suppresses output on non-tty, matches GNU" {
    const a = std.testing.allocator;
    if (!gnuAvailable(a)) return error.SkipZigTest;

    var gnu = try run(a, gnu_tty, &.{"-s"});
    defer gnu.deinit(a);
    var mine = try run(a, ztty_bin, &.{"-s"});
    defer mine.deinit(a);

    // GNU: no stdout, exit 1.
    try std.testing.expectEqual(@as(usize, 0), gnu.stdout.len);
    try std.testing.expectEqual(@as(u8, 1), gnu.exit_code);

    try std.testing.expectEqualStrings(gnu.stdout, mine.stdout);
    try std.testing.expectEqual(gnu.exit_code, mine.exit_code);
}

test "error cases emit a diagnostic to stderr with exit 2 (like GNU)" {
    const a = std.testing.allocator;
    if (!gnuAvailable(a)) return error.SkipZigTest;

    const err_args = [_][]const u8{ "foo", "--bogus", "-x" };
    for (err_args) |arg| {
        var gnu = try run(a, gnu_tty, &.{arg});
        defer gnu.deinit(a);
        var mine = try run(a, ztty_bin, &.{arg});
        defer mine.deinit(a);

        // Both: exit 2, empty stdout, non-empty stderr diagnostic.
        try std.testing.expectEqual(@as(u8, 2), gnu.exit_code);
        try std.testing.expectEqual(@as(u8, 2), mine.exit_code);
        try std.testing.expectEqual(@as(usize, 0), mine.stdout.len);
        try std.testing.expect(mine.stderr.len > 0);
    }
}
