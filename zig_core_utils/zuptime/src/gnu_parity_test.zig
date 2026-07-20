//! Externally-anchored parity tests for zuptime.
//!
//! There is no runnable GNU/procps `uptime` binary on this host (uptime ships in
//! procps-ng, NOT coreutils, and the util reads /proc/uptime, /proc/loadavg and
//! /var/run/utmp — none of which exist on macOS), so a live byte-diff of the
//! full default line is impossible here. The anchoring is split accordingly:
//!
//!  * FORMAT anchor (the wording/spacing the audit flagged): the expected bytes
//!    are the OUTPUT of procps-ng's reference implementation, applied by hand to
//!    fixed inputs. The exact procps format strings are quoted from
//!    https://gitlab.com/procps-ng/procps/-/raw/master/library/uptime.c
//!    (function snprint_uptime_only / procps_uptime_snprint) and
//!    https://gitlab.com/procps-ng/procps/-/raw/master/src/uptime.c
//!    (print_uptime_since). These exercise the pure format functions directly.
//!    Per zig-forge golden rule #1, "a different implementation's golden file"
//!    is an acceptable external anchor — here procps-ng is that implementation.
//!
//!  * BEHAVIOR anchor (exit codes + stream routing): the freshly-built zuptime
//!    binary is run and its exit status / stdout / stderr checked against the
//!    documented GNU/POSIX convention (--help/--version → stdout, exit 0;
//!    unknown option → stderr, exit 1; unreadable /proc/uptime → exit 1). These
//!    run live on this host — the /proc/uptime error path is exercised for real.
//!
//! None of these are roundtrip tests: every expected value comes from a source
//! this repo's authors did not write (procps-ng, or the POSIX/coreutils CLI
//! convention), with the source cited inline.

const std = @import("std");
const build_options = @import("build_options");
const zuptime = @import("main.zig");

const ZUPTIME = build_options.zuptime_bin;

// ---------------------------------------------------------------------------
// FORMAT anchor — pure functions vs procps-ng reference output.
// ---------------------------------------------------------------------------

// Classic (non-pretty) uptime component — the text after "up ".
// procps snprint_uptime_only(pretty=0):
//   days:  "%s%d %s"     UNITS = (updays != 1 ? "days" : "day")
//   hours: "%s%2d:%02d"  (space-padded to width 2)
//   mins:  "%s%d %s"     UNITS = "min"
// with "%s" = ", " once an earlier field printed, else "". The thresholds are
// strict `>` on the subtracted remainder, so 3600 -> "60 min", 86400 -> "24:00"
// and 90000 -> "1 day, 60 min" are deliberate procps quirks locked in below.
const ComponentCase = struct { secs: u64, want: []const u8 };
const COMPONENT_CASES = [_]ComponentCase{
    .{ .secs = 0, .want = "0 min" },
    .{ .secs = 59, .want = "0 min" },
    .{ .secs = 60, .want = "0 min" }, // strict `>` : exactly 60s is still 0 min
    .{ .secs = 61, .want = "1 min" },
    .{ .secs = 120, .want = "2 min" },
    .{ .secs = 3600, .want = "60 min" }, // quirk: 3600 is NOT > 3600 -> no hours
    .{ .secs = 3660, .want = " 1:00" }, // "%2d" pads hours to width 2
    .{ .secs = 7260, .want = " 2:00" },
    .{ .secs = 93780, .want = "1 day,  2:03" }, // ", " + " 2:03" -> two spaces
    .{ .secs = 90000, .want = "1 day, 60 min" }, // quirk lock
    .{ .secs = 86400, .want = "24:00" }, // quirk lock
    .{ .secs = 172800, .want = "2 days, 0 min" }, // plural "days"
};

test "uptime component matches procps snprint_uptime_only(pretty=0)" {
    var buf: [64]u8 = undefined;
    for (COMPONENT_CASES) |c| {
        const got = zuptime.formatUptimeComponent(c.secs, &buf);
        std.testing.expectEqualStrings(c.want, got) catch |e| {
            std.debug.print("secs={d}: got \"{s}\" want \"{s}\"\n", .{ c.secs, got, c.want });
            return e;
        };
    }
}

// Pretty (`-p`) — procps snprint_uptime_only(pretty=1) prefixed with "up ".
// decades/years/weeks/days/hours/minutes joined by ", "; days uses `!= 1` for
// plural, the rest use `> 1`; minutes are emitted even at 0 when the leftover
// seconds are <= 60 (hence "0 minute" singular for a sub-minute / exact bucket).
const PrettyCase = struct { secs: u64, want: []const u8 };
const PRETTY_CASES = [_]PrettyCase{
    .{ .secs = 0, .want = "up 0 minute" },
    .{ .secs = 61, .want = "up 1 minute" },
    .{ .secs = 120, .want = "up 2 minutes" },
    .{ .secs = 93780, .want = "up 1 day, 2 hours, 3 minutes" },
    .{ .secs = 90000, .want = "up 1 day, 60 minutes" }, // quirk lock
    .{ .secs = 172800, .want = "up 2 days, 0 minute" }, // plural days, singular-zero minute
    .{ .secs = 700000, .want = "up 1 week, 1 day, 2 hours, 26 minutes" },
};

test "pretty format matches procps snprint_uptime_only(pretty=1)" {
    var buf: [128]u8 = undefined;
    for (PRETTY_CASES) |c| {
        const got = zuptime.formatPretty(c.secs, &buf);
        std.testing.expectEqualStrings(c.want, got) catch |e| {
            std.debug.print("secs={d}: got \"{s}\" want \"{s}\"\n", .{ c.secs, got, c.want });
            return e;
        };
    }
}

// Users segment — procps `", %2d %s,  "` (two trailing spaces), UNITS =
// (users != 1 ? "users" : "user"); `", ? users,  "` when utmp is unreadable.
test "users segment matches procps procps_uptime_snprint" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings(",  0 users,  ", zuptime.formatUsers(0, &buf));
    try std.testing.expectEqualStrings(",  1 user,  ", zuptime.formatUsers(1, &buf));
    try std.testing.expectEqualStrings(",  2 users,  ", zuptime.formatUsers(2, &buf));
    try std.testing.expectEqualStrings(", 12 users,  ", zuptime.formatUsers(12, &buf)); // %2d, no over-pad
    try std.testing.expectEqualStrings(", ? users,  ", zuptime.formatUsers(null, &buf));
}

// Load segment — procps `"load average: %.2f, %.2f, %.2f"` (+ our newline).
// %.2f rounding and 2-decimal padding are the anchor.
test "load segment matches procps load average format" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "load average: 0.00, 0.00, 0.00\n",
        zuptime.formatLoad(0, 0, 0, &buf),
    );
    try std.testing.expectEqualStrings(
        "load average: 0.50, 1.00, 2.05\n",
        zuptime.formatLoad(0.5, 1.0, 2.05, &buf),
    );
    // %.2f rounds to 2 decimals (0.567 -> 0.57).
    try std.testing.expectEqualStrings(
        "load average: 0.57, 12.34, 0.10\n",
        zuptime.formatLoad(0.567, 12.34, 0.1, &buf),
    );
}

// ---------------------------------------------------------------------------
// BEHAVIOR anchor — run the real binary, check exit codes + stream routing.
// ---------------------------------------------------------------------------

const RunOut = struct { stdout: []u8, stderr: []u8, code: u8 };

fn runCmd(alloc: std.mem.Allocator, extra: []const []const u8) !RunOut {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, ZUPTIME);
    for (extra) |a| try argv.append(alloc, a);

    const res = try std.process.run(alloc, io, .{ .argv = argv.items });
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = res.stdout, .stderr = res.stderr, .code = code };
}

fn procUptimeExists() bool {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    _ = std.Io.Dir.cwd().statFile(io, "/proc/uptime", .{}) catch return false;
    return true;
}

// GNU/POSIX convention (coreutils version_etc/usage, procps getopt 'h'/'V'):
// --help and --version print to STDOUT and exit 0, so `uptime --help | grep`
// works. The pre-fix code wrote both to stderr and exited 0.
test "--help goes to stdout with exit 0" {
    const alloc = std.testing.allocator;
    const r = try runCmd(alloc, &.{"--help"});
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);

    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(r.stdout.len > 0);
    try std.testing.expectEqualStrings("", r.stderr);
    try std.testing.expect(std.mem.startsWith(u8, r.stdout, "Usage:"));
}

test "--version goes to stdout with exit 0" {
    const alloc = std.testing.allocator;
    const r = try runCmd(alloc, &.{"--version"});
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);

    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(r.stdout.len > 0);
    try std.testing.expectEqualStrings("", r.stderr);
}

// procps/getopt: an unrecognized option is an error — message to stderr, exit 1,
// nothing on stdout. The pre-fix arg loop silently ignored unknown options and
// exited 0.
test "unknown option errors to stderr with exit 1" {
    const alloc = std.testing.allocator;
    const r = try runCmd(alloc, &.{"--bogus"});
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);

    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expectEqualStrings("", r.stdout);
    try std.testing.expect(r.stderr.len > 0);
}

// procps exits non-zero when it cannot read the uptime source (open failure ->
// errno propagated). The pre-fix code printed an error but still returned 0.
// This is exercised live: on this macOS host /proc/uptime is absent, so the
// default invocation MUST take the error path (exit 1, empty stdout). On a Linux
// host where /proc/uptime exists, the success path (exit 0) is asserted instead.
test "default invocation exit code tracks /proc/uptime readability" {
    const alloc = std.testing.allocator;
    const r = try runCmd(alloc, &.{});
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);

    if (procUptimeExists()) {
        try std.testing.expectEqual(@as(u8, 0), r.code);
        try std.testing.expect(r.stdout.len > 0);
    } else {
        try std.testing.expectEqual(@as(u8, 1), r.code);
        try std.testing.expectEqualStrings("", r.stdout);
        try std.testing.expect(r.stderr.len > 0);
    }
}
