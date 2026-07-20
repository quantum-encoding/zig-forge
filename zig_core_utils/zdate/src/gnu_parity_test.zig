//! Externally-anchored parity tests for zdate.
//!
//! These are NOT roundtrip tests. Every assertion is anchored to the real GNU
//! `date` binary (GNU coreutils `gdate`) installed on this machine, or — for
//! the two convention checks GNU documents but that are awkward to diff live —
//! to GNU's documented behavior with the expected bytes written literally and
//! the source cited inline.
//!
//! The zdate binary under test is passed in from build.zig via build_options
//! (`zdate_bin`), so the test always exercises the freshly-compiled binary.
//!
//! Anchoring model (per zig-forge/CLAUDE.md golden rule #1): the inputs AND the
//! expected outputs come from a source the library author did not write —
//! `/opt/homebrew/bin/gdate` (GNU coreutils 9.10). TZ and LC_ALL are pinned to
//! the SAME values for both binaries so the comparison is apples-to-apples.

const std = @import("std");
const build_options = @import("build_options");

const ZDATE = build_options.zdate_bin;

// Candidate locations for the GNU coreutils `date` binary on macOS/Homebrew.
const GDATE_CANDIDATES = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/date",
    "/opt/homebrew/bin/gdate",
    "/usr/local/bin/gdate",
};

fn findGdate() ?[]const u8 {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    for (GDATE_CANDIDATES) |p| {
        _ = cwd.statFile(io, p, .{}) catch continue;
        return p;
    }
    return null;
}

const RunOut = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,
};

fn runCmd(
    alloc: std.mem.Allocator,
    bin: []const u8,
    extra: []const []const u8,
    tz: []const u8,
) !RunOut {
    // The process-spawn machinery needs a working allocator (the global
    // single-threaded Io uses `.failing`), so stand up a local Threaded Io.
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, bin);
    for (extra) |a| try argv.append(alloc, a);

    // Minimal, controlled environment: `date` only needs TZ (zoneinfo lookup)
    // and a pinned locale. Both binaries get exactly the same env so the diff
    // is fair. argv[0] is absolute, so PATH is irrelevant.
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("TZ", tz);
    try env.put("LC_ALL", "C");

    const res = try std.process.run(alloc, io, .{
        .argv = argv.items,
        .environ_map = &env,
    });
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = res.stdout, .stderr = res.stderr, .code = code };
}

const ParityCase = struct {
    args: []const []const u8,
    tz: []const u8 = "UTC",
};

// Epoch 1000000000 == 2001-09-09 01:46:40 UTC (a fixed, well-known instant).
// Every case pins the instant via `-d @<epoch>` so output is deterministic and
// independent of the wall clock — only TZ/locale vary, identically for both
// binaries.
const PARITY_CASES = [_]ParityCase{
    // Core strftime specifiers at a fixed epoch.
    .{ .args = &.{ "-d", "@1000000000", "+%Y-%m-%d" } },
    .{ .args = &.{ "-d", "@1000000000", "+%H:%M:%S" } },
    .{ .args = &.{ "-d", "@1000000000", "+%Y-%m-%dT%H:%M:%S" } },
    .{ .args = &.{ "-d", "@1000000000", "+%s" } },
    .{ .args = &.{ "-d", "@1000000000", "+%A" } },
    .{ .args = &.{ "-d", "@1000000000", "+%B" } },
    .{ .args = &.{ "-d", "@1000000000", "+%a %b %e" } },
    .{ .args = &.{ "-d", "@1000000000", "+%j" } },
    .{ .args = &.{ "-d", "@1000000000", "+%F %T" } },
    .{ .args = &.{ "-d", "@1000000000", "+%D" } },
    .{ .args = &.{ "-d", "@1000000000", "+%p %r" } },
    .{ .args = &.{ "-d", "@1000000000", "+%u %w" } },
    .{ .args = &.{ "-d", "@1000000000", "+%C%y" } },
    .{ .args = &.{ "-d", "@1000000000", "+100%% literal" } },
    // Same instant rendered in offset zones.
    .{ .args = &.{ "-d", "@1000000000", "+%H:%M %Z" }, .tz = "Europe/Berlin" },
    .{ .args = &.{ "-d", "@1000000000", "+%H:%M" }, .tz = "America/New_York" },

    // ISO 8601 — the "%:z requires a colon" fix. GNU emits +00:00 / +02:00.
    .{ .args = &.{ "-Iseconds", "-d", "@1000000000" } },
    .{ .args = &.{ "-Iseconds", "-d", "@1000000000" }, .tz = "Europe/Berlin" },
    .{ .args = &.{ "-Iseconds", "-d", "@1000000000" }, .tz = "America/New_York" },
    .{ .args = &.{ "-Iminutes", "-d", "@1000000000" }, .tz = "Europe/Berlin" },
    .{ .args = &.{ "-Ihours", "-d", "@1000000000" }, .tz = "Europe/Berlin" },
    .{ .args = &.{ "-I", "-d", "@1000000000" } },

    // RFC 3339 — same colon-offset requirement.
    .{ .args = &.{ "--rfc-3339=seconds", "-d", "@1000000000" } },
    .{ .args = &.{ "--rfc-3339=seconds", "-d", "@1000000000" }, .tz = "America/New_York" },
    .{ .args = &.{ "--rfc-3339=date", "-d", "@1000000000" } },

    // RFC 2822 — GNU uses a colon-less numeric offset here; must still match.
    .{ .args = &.{ "-R", "-d", "@1000000000" } },
    .{ .args = &.{ "-R", "-d", "@1000000000" }, .tz = "Europe/Berlin" },

    // Absolute date parsing (previously unsupported -> exit 1).
    .{ .args = &.{ "-d", "2020-01-15", "+%Y-%m-%d" } },
    .{ .args = &.{ "-d", "2020-01-15 10:30:00", "+%Y-%m-%dT%H:%M:%S" } },
    .{ .args = &.{ "-d", "2020-01-15T10:30:00", "+%s" } },
    .{ .args = &.{ "-d", "2020-06-30 23:59:59", "+%s" } },
    .{ .args = &.{ "-d", "10:30:00", "+%H:%M:%S" } },

    // UTC flag with an absolute string (timegm path).
    .{ .args = &.{ "-u", "-d", "2020-01-15 10:30:00", "+%s" } },
};

test "zdate output matches GNU date byte-for-byte" {
    const alloc = std.testing.allocator;
    const gdate = findGdate() orelse {
        std.debug.print("SKIP: no GNU date (gdate) found in {any}\n", .{GDATE_CANDIDATES});
        return error.SkipZigTest;
    };

    var failures: usize = 0;
    for (PARITY_CASES) |c| {
        const z = try runCmd(alloc, ZDATE, c.args, c.tz);
        defer alloc.free(z.stdout);
        defer alloc.free(z.stderr);
        const g = try runCmd(alloc, gdate, c.args, c.tz);
        defer alloc.free(g.stdout);
        defer alloc.free(g.stderr);

        if (!std.mem.eql(u8, z.stdout, g.stdout) or z.code != g.code) {
            failures += 1;
            std.debug.print(
                "MISMATCH TZ={s} args={any}\n  zdate  (code {d}): {s}\n  gdate  (code {d}): {s}\n",
                .{ c.tz, c.args, z.code, z.stdout, g.code, g.stdout },
            );
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

// The two overflow findings: a numeric -d input that overflows i64 / c_int must
// be reported as "invalid date" (exit 1) like GNU — NOT a Debug/ReleaseSafe
// SIGABRT (exit 134) nor a silent ReleaseFast wrap. Anchor: GNU's exit status.
const OVERFLOW_CASES = [_][]const []const u8{
    &.{ "-d", "@99999999999999999999999999", "+%Y" },
    &.{ "-d", "@-99999999999999999999999999", "+%Y" },
    &.{ "-d", "99999999999 days", "+%Y" },
    &.{ "-d", "999999999999999 hours", "+%Y" },
};

test "oversized numeric -d is an invalid-date error, not a panic" {
    const alloc = std.testing.allocator;
    const gdate = findGdate() orelse return error.SkipZigTest;

    for (OVERFLOW_CASES) |args| {
        const z = try runCmd(alloc, ZDATE, args, "UTC");
        defer alloc.free(z.stdout);
        defer alloc.free(z.stderr);
        const g = try runCmd(alloc, gdate, args, "UTC");
        defer alloc.free(g.stdout);
        defer alloc.free(g.stderr);

        // GNU reports exit 1; zdate must too (and must NOT abort with 134).
        try std.testing.expectEqual(@as(u8, 1), g.code);
        std.testing.expectEqual(@as(u8, 1), z.code) catch |e| {
            std.debug.print("overflow args={any}: zdate exit {d} (want 1), stderr: {s}\n", .{ args, z.code, z.stderr });
            return e;
        };
        // On the error path nothing is written to stdout, matching GNU.
        try std.testing.expectEqualStrings("", z.stdout);
    }
}

test "extra operand is an error, not a silent no-op" {
    const alloc = std.testing.allocator;
    const gdate = findGdate() orelse return error.SkipZigTest;

    const args = [_][]const u8{ "foo", "bar" };
    const z = try runCmd(alloc, ZDATE, &args, "UTC");
    defer alloc.free(z.stdout);
    defer alloc.free(z.stderr);
    const g = try runCmd(alloc, gdate, &args, "UTC");
    defer alloc.free(g.stdout);
    defer alloc.free(g.stderr);

    // GNU: `date: extra operand 'bar'` exit 1. zdate must also reject (exit 1),
    // rather than printing the current date with exit 0.
    try std.testing.expectEqual(@as(u8, 1), g.code);
    try std.testing.expectEqual(@as(u8, 1), z.code);
    try std.testing.expectEqualStrings("", z.stdout);
}

// GNU convention (POSIX / coreutils): --help and --version write to STDOUT and
// exit 0 on the success path, so `date --version | head` and `date --help |
// grep` work. See coreutils `src/date.c` -> usage()/version_etc(), both routed
// to stdout for the explicit --help/--version requests. This is a documented
// convention rather than a byte-diff (zdate's help text is its own), so it is
// anchored to that behavior with the expectations written literally here.
test "--help goes to stdout with exit 0" {
    const alloc = std.testing.allocator;
    const z = try runCmd(alloc, ZDATE, &.{"--help"}, "UTC");
    defer alloc.free(z.stdout);
    defer alloc.free(z.stderr);

    try std.testing.expectEqual(@as(u8, 0), z.code);
    try std.testing.expect(z.stdout.len > 0); // help text on stdout
    try std.testing.expectEqualStrings("", z.stderr); // nothing on stderr
    try std.testing.expect(std.mem.startsWith(u8, z.stdout, "Usage:"));
}

test "--version goes to stdout with exit 0" {
    const alloc = std.testing.allocator;
    const z = try runCmd(alloc, ZDATE, &.{"--version"}, "UTC");
    defer alloc.free(z.stdout);
    defer alloc.free(z.stderr);

    try std.testing.expectEqual(@as(u8, 0), z.code);
    try std.testing.expect(z.stdout.len > 0);
    try std.testing.expectEqualStrings("", z.stderr);
}
