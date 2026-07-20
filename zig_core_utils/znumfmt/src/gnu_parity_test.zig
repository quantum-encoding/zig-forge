//! Externally-anchored parity tests for znumfmt against GNU coreutils `numfmt`.
//!
//! Two layers of anchoring, per zig-forge/CLAUDE.md's golden rule (no
//! roundtrip-only tests):
//!
//!   1. LITERAL vectors — the expected bytes were captured from the real GNU
//!      `numfmt` (coreutils, run under `LC_ALL=C`) and are pinned here with the
//!      exact flags. These bite even when no GNU binary is installed and are the
//!      regression guard for the SI-casing and rounding fixes.
//!
//!   2. CROSS-CHECK sweep — when a GNU `numfmt` binary is present, znumfmt's
//!      stdout+exit are diffed against GNU's live output for a wider spread.
//!      This is the true external anchor (a second implementation's output).
//!
//! The znumfmt binary under test is located via the ZNUMFMT_BIN env var (set by
//! build.zig), falling back to the default install path. All comparisons run
//! with LC_ALL=C so grouping/formatting is deterministic.

const std = @import("std");
const build_options = @import("build_options");
const testing = std.testing;
const io = std.testing.io;

const Result = struct {
    stdout: []u8,
    stderr: []u8,
    exit: u8, // 255 == signal/abnormal
};

fn znumfmtBin() []const u8 {
    return build_options.znumfmt_bin;
}

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/numfmt",
    "/opt/homebrew/bin/gnumfmt",
    "/usr/bin/numfmt",
    "/usr/local/bin/gnumfmt",
};

/// Locate a GNU numfmt by attempting to run each candidate absolute path.
/// Returns null when none exists (the cross-check tests then skip).
fn gnuBin(alloc: std.mem.Allocator) ?[]const u8 {
    for (gnu_candidates) |p| {
        const r = run(alloc, p, &.{"--version"}, null) catch continue;
        alloc.free(r.stdout);
        alloc.free(r.stderr);
        if (r.exit == 0) return p;
    }
    return null;
}

/// Run `bin` with `args` and optional stdin, return captured output + exit.
/// `bin` must be an absolute path or resolvable via PATH.
fn run(alloc: std.mem.Allocator, bin: []const u8, args: []const []const u8, stdin: ?[]const u8) !Result {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, bin);
    for (args) |a| try argv.append(alloc, a);

    // Deterministic formatting regardless of the tester's locale.
    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();
    try env.put("LC_ALL", "C");

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = &env,
        .stdin = if (stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    errdefer child.kill(io);

    if (stdin) |data| {
        try child.stdin.?.writeStreamingAll(io, data);
        child.stdin.?.close(io);
        child.stdin = null;
    }

    // Inputs and outputs are tiny (well under the pipe buffer), so draining
    // stdout fully and then stderr cannot deadlock.
    var obuf: [8192]u8 = undefined;
    var ebuf: [8192]u8 = undefined;
    var out_reader = child.stdout.?.reader(io, &obuf);
    var err_reader = child.stderr.?.reader(io, &ebuf);
    const out = try out_reader.interface.allocRemaining(alloc, .unlimited);
    errdefer alloc.free(out);
    const err = try err_reader.interface.allocRemaining(alloc, .unlimited);

    const term = try child.wait(io);
    const exit: u8 = switch (term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = out, .stderr = err, .exit = exit };
}

// ---------------------------------------------------------------------------
// Layer 1: literal vectors captured from GNU numfmt (LC_ALL=C).
// ---------------------------------------------------------------------------

const LiteralCase = struct {
    args: []const []const u8,
    stdin: ?[]const u8 = null,
    want_stdout: []const u8,
    want_exit: u8 = 0,
};

const literal_cases = [_]LiteralCase{
    // --- SI scaling: kilo is lowercase 'k', M/G/T uppercase (GNU parity). ---
    .{ .args = &.{ "--to=si", "1000" }, .want_stdout = "1.0k\n" },
    .{ .args = &.{ "--to=si", "1500" }, .want_stdout = "1.5k\n" },
    .{ .args = &.{ "--to=si", "1000000" }, .want_stdout = "1.0M\n" },
    .{ .args = &.{ "--to=si", "1073741824" }, .want_stdout = "1.1G\n" },
    .{ .args = &.{ "--to=si", "999" }, .want_stdout = "999\n" },
    .{ .args = &.{ "--to=si", "0" }, .want_stdout = "0\n" },
    // Default rounding is from-zero: 1234567 -> 1.3M (not 1.2M), 12.5 -> 13.
    .{ .args = &.{ "--to=si", "1234567" }, .want_stdout = "1.3M\n" },
    .{ .args = &.{ "--to=si", "12.5" }, .want_stdout = "13\n" },
    // Rounding pushes 9.95k -> 10k (integer display, not 10.0k).
    .{ .args = &.{ "--to=si", "9950" }, .want_stdout = "10k\n" },
    .{ .args = &.{ "--to=si", "9999" }, .want_stdout = "10k\n" },
    // Rescale after rounding: 999999 -> 1.0M.
    .{ .args = &.{ "--to=si", "999999" }, .want_stdout = "1.0M\n" },
    .{ .args = &.{ "--to=si", "10500" }, .want_stdout = "11k\n" },

    // --- Explicit rounding modes on 1234567 (=1.234567M). ---
    .{ .args = &.{ "--to=si", "--round=up", "1234567" }, .want_stdout = "1.3M\n" },
    .{ .args = &.{ "--to=si", "--round=down", "1234567" }, .want_stdout = "1.2M\n" },
    .{ .args = &.{ "--to=si", "--round=from-zero", "1234567" }, .want_stdout = "1.3M\n" },
    .{ .args = &.{ "--to=si", "--round=towards-zero", "1234567" }, .want_stdout = "1.2M\n" },
    .{ .args = &.{ "--to=si", "--round=nearest", "1234567" }, .want_stdout = "1.2M\n" },
    // nearest ties away from zero: 1550 -> 1.6k, 1450 -> 1.5k.
    .{ .args = &.{ "--to=si", "--round=nearest", "1550" }, .want_stdout = "1.6k\n" },
    .{ .args = &.{ "--to=si", "--round=nearest", "1450" }, .want_stdout = "1.5k\n" },

    // --- IEC (base 1024): uppercase 'K'. ---
    .{ .args = &.{ "--to=iec", "1024" }, .want_stdout = "1.0K\n" },
    .{ .args = &.{ "--to=iec", "1536" }, .want_stdout = "1.5K\n" },
    .{ .args = &.{ "--to=iec", "1048576" }, .want_stdout = "1.0M\n" },
    .{ .args = &.{ "--to=iec", "1000" }, .want_stdout = "1000\n" },
    // --- IEC-i: two-letter Ki/Mi suffixes. ---
    .{ .args = &.{ "--to=iec-i", "1024" }, .want_stdout = "1.0Ki\n" },
    .{ .args = &.{ "--to=iec-i", "1048576" }, .want_stdout = "1.0Mi\n" },

    // --- Parsing input suffixes. ---
    .{ .args = &.{ "--from=si", "1K" }, .want_stdout = "1000\n" },
    .{ .args = &.{ "--from=si", "1.5K" }, .want_stdout = "1500\n" },
    .{ .args = &.{ "--from=si", "2G" }, .want_stdout = "2000000000\n" },
    .{ .args = &.{ "--from=si", "1k" }, .want_stdout = "1000\n" },
    .{ .args = &.{ "--from=iec", "1K" }, .want_stdout = "1024\n" },
    .{ .args = &.{ "--from=auto", "1Ki" }, .want_stdout = "1024\n" },
    .{ .args = &.{ "--from=auto", "1Mi" }, .want_stdout = "1048576\n" },

    // --- Negative values (must be after `--`). ---
    .{ .args = &.{ "--to=si", "--", "-1234567" }, .want_stdout = "-1.3M\n" },
    .{ .args = &.{ "--to=si", "--", "-1000" }, .want_stdout = "-1.0k\n" },

    // --- from-unit / to-unit scaling. ---
    .{ .args = &.{ "--from-unit=1024", "512" }, .want_stdout = "524288\n" },
    .{ .args = &.{ "--to-unit=1024", "2048" }, .want_stdout = "2\n" },

    // --- suffix append. ---
    .{ .args = &.{ "--suffix=B", "--to=si", "1000" }, .want_stdout = "1.0kB\n" },

    // --- Attached short option -d, plus space-form --field. ---
    .{ .args = &.{ "-d,", "--field", "2", "--to=si" }, .stdin = "a,1000", .want_stdout = "a,1.0k\n" },
    .{ .args = &.{ "--field", "2", "--to=si" }, .stdin = "a 1000\n", .want_stdout = "a 1.0k\n" },

    // --- Invalid input is echoed through (no silent data loss). ---
    // warn: diagnose on stderr, echo token, exit 0.
    .{ .args = &.{ "--invalid=warn", "abc" }, .want_stdout = "abc\n", .want_exit = 0 },
    // ignore: echo token, exit 0.
    .{ .args = &.{ "--invalid=ignore", "abc" }, .want_stdout = "abc\n", .want_exit = 0 },
    // fail: echo token(s), exit 2.
    .{ .args = &.{ "--invalid=fail", "abc", "100" }, .want_stdout = "abc\n100\n", .want_exit = 2 },

    // --- Error cases: exit codes match GNU (stdout empty). ---
    // Z/Y suffixes must not overflow/panic; too-large -> exit 2.
    .{ .args = &.{ "--from=iec", "1Y" }, .want_stdout = "", .want_exit = 2 },
    .{ .args = &.{ "--from=si", "1Z" }, .want_stdout = "", .want_exit = 2 },
    // Unchecked @intFromFloat used to panic; now a clean too-large error.
    .{ .args = &.{ "--to=none", "99999999999999999999" }, .want_stdout = "", .want_exit = 2 },
    .{ .args = &.{ "--to=none", "9999999999999999" }, .want_stdout = "", .want_exit = 2 },
    // Zero unit size rejected at parse time (was div-by-zero -> panic).
    .{ .args = &.{ "--to-unit=0", "1000" }, .want_stdout = "", .want_exit = 1 },
    .{ .args = &.{ "--from-unit=0", "1000" }, .want_stdout = "", .want_exit = 1 },
    // --grouping cannot be combined with --to.
    .{ .args = &.{ "--grouping", "--to=si", "1234567" }, .want_stdout = "", .want_exit = 1 },
    // Value within range still prints (below the 10^16 too-large threshold).
    .{ .args = &.{ "--to=none", "999999999999999" }, .want_stdout = "999999999999999\n", .want_exit = 0 },
};

test "literal GNU-captured vectors" {
    const alloc = testing.allocator;
    const bin = znumfmtBin();
    var failures: usize = 0;

    for (literal_cases) |c| {
        const r = try run(alloc, bin, c.args, c.stdin);
        defer alloc.free(r.stdout);
        defer alloc.free(r.stderr);

        const ok = std.mem.eql(u8, r.stdout, c.want_stdout) and r.exit == c.want_exit;
        if (!ok) {
            failures += 1;
            std.debug.print(
                "MISMATCH args={any} stdin={?s}\n  want stdout='{s}' exit={d}\n   got stdout='{s}' exit={d} stderr='{s}'\n",
                .{ c.args, c.stdin, c.want_stdout, c.want_exit, r.stdout, r.exit, r.stderr },
            );
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

// ---------------------------------------------------------------------------
// Layer 2: live cross-check against the installed GNU numfmt.
// ---------------------------------------------------------------------------

const cross_cases = [_][]const []const u8{
    &.{ "--to=si", "1000" },
    &.{ "--to=si", "1536" },
    &.{ "--to=si", "9999" },
    &.{ "--to=si", "10000" },
    &.{ "--to=si", "1234567" },
    &.{ "--to=si", "999999" },
    &.{ "--to=si", "100000" },
    &.{ "--to=si", "1073741824" },
    &.{ "--to=iec", "1024" },
    &.{ "--to=iec", "1073741824" },
    &.{ "--to=iec-i", "1048576" },
    &.{ "--to=si", "--round=up", "1001" },
    &.{ "--to=si", "--round=down", "1999" },
    &.{ "--to=si", "--round=nearest", "2500" },
    &.{ "--from=si", "1.5K" },
    &.{ "--from=auto", "1Mi" },
    &.{ "--from=iec", "--to=si", "1K" },
    &.{ "--to=si", "--", "-1234567" },
    &.{ "--from-unit=1024", "512" },
    &.{ "--suffix=B", "--to=si", "1000" },
};

test "cross-check stdout against live GNU numfmt" {
    const alloc = testing.allocator;
    const gnu = gnuBin(alloc) orelse {
        std.debug.print("SKIP: no GNU numfmt binary found\n", .{});
        return error.SkipZigTest;
    };
    const bin = znumfmtBin();
    var failures: usize = 0;

    for (cross_cases) |args| {
        const rz = try run(alloc, bin, args, null);
        defer alloc.free(rz.stdout);
        defer alloc.free(rz.stderr);
        const rg = try run(alloc, gnu, args, null);
        defer alloc.free(rg.stdout);
        defer alloc.free(rg.stderr);

        const ok = std.mem.eql(u8, rz.stdout, rg.stdout) and rz.exit == rg.exit;
        if (!ok) {
            failures += 1;
            std.debug.print(
                "CROSS-MISMATCH args={any}\n  znumfmt: '{s}' (exit {d})\n  gnu:     '{s}' (exit {d})\n",
                .{ args, rz.stdout, rz.exit, rg.stdout, rg.exit },
            );
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "error exit codes match live GNU numfmt" {
    const alloc = testing.allocator;
    const gnu = gnuBin(alloc) orelse return error.SkipZigTest;
    const bin = znumfmtBin();

    // Cases where only exit status (not the exact stderr wording) must match,
    // since GNU prefixes its own program name and float repr.
    const err_cases = [_][]const []const u8{
        &.{ "--from=iec", "1Y" },
        &.{ "--to=none", "99999999999999999999" },
        &.{ "--to-unit=0", "1000" },
        &.{ "--grouping", "--to=si", "1234567" },
        &.{ "--foobar", "1" },
    };
    var failures: usize = 0;
    for (err_cases) |args| {
        const rz = try run(alloc, bin, args, null);
        defer alloc.free(rz.stdout);
        defer alloc.free(rz.stderr);
        const rg = try run(alloc, gnu, args, null);
        defer alloc.free(rg.stdout);
        defer alloc.free(rg.stderr);
        if (rz.exit != rg.exit) {
            failures += 1;
            std.debug.print("EXIT-MISMATCH args={any}: znumfmt={d} gnu={d}\n", .{ args, rz.exit, rg.exit });
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
