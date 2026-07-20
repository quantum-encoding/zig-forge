//! Externally-anchored parity tests for zsleep.
//!
//! These shell out to BOTH the built `zsleep` binary and the real GNU
//! `sleep` (coreutils) and compare normalized stderr and exit codes.
//! GNU coreutils `sleep` is the external anchor — nothing here is a
//! roundtrip against zsleep's own output.
//!
//! Binaries are located via env vars set by build.zig:
//!   ZSLEEP_BIN  - path to the freshly built zsleep (required)
//!   GSLEEP_BIN  - path to GNU sleep (default /opt/homebrew/bin/gsleep)
//!
//! If GNU sleep is unavailable the test SKIPS (never silently passes).
//! Error messages are run under LC_ALL=C so GNU uses ASCII quotes.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

fn envOr(name: [*:0]const u8, default: []const u8) []const u8 {
    if (std.c.getenv(name)) |v| return std.mem.span(v);
    return default;
}

fn zsleepBin() []const u8 {
    return envOr("ZSLEEP_BIN", "zig-out/bin/zsleep");
}

fn fileExists(p: []const u8) bool {
    var buf: [4096]u8 = undefined;
    if (p.len >= buf.len) return false;
    @memcpy(buf[0..p.len], p);
    buf[p.len] = 0;
    return std.c.access(buf[0..p.len :0], std.posix.F_OK) == 0;
}

fn gsleepBin() ?[]const u8 {
    const candidates = [_][]const u8{
        envOr("GSLEEP_BIN", "/opt/homebrew/bin/gsleep"),
        "/opt/homebrew/opt/coreutils/libexec/gnubin/sleep",
        "/usr/bin/gsleep",
    };
    for (candidates) |p| {
        if (fileExists(p)) return p;
    }
    return null;
}

/// Space-join args into a caller-supplied buffer for diagnostic messages.
fn joinInto(buf: []u8, args: []const []const u8) []const u8 {
    var n: usize = 0;
    for (args, 0..) |a, i| {
        if (i > 0 and n < buf.len) {
            buf[n] = ' ';
            n += 1;
        }
        const m = @min(a.len, buf.len - n);
        @memcpy(buf[n .. n + m], a[0..m]);
        n += m;
    }
    return buf[0..n];
}

/// Build a child environment forcing the C locale (ASCII quoting from GNU
/// coreutils) while preserving PATH.
fn cLocaleEnv(gpa: std.mem.Allocator) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(gpa);
    errdefer env.deinit();
    try env.put("LC_ALL", "C");
    if (std.c.getenv("PATH")) |path| try env.put("PATH", std.mem.span(path));
    return env;
}

fn termToCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |c| c,
        .signal => |s| @intCast(128 + @as(u32, @intCast(@intFromEnum(s)))),
        else => 255,
    };
}

const CaseResult = struct {
    stderr: []u8,
    exit_code: u8,
    gpa: std.mem.Allocator,
    fn deinit(self: *CaseResult) void {
        self.gpa.free(self.stderr);
    }
};

/// Run a (fast-exiting) invocation to completion, capturing stderr + exit code.
fn runFast(gpa: std.mem.Allocator, io: Io, bin: []const u8, extra: []const []const u8) !CaseResult {
    var argv = std.ArrayListUnmanaged([]const u8).empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, bin);
    try argv.appendSlice(gpa, extra);

    var env = try cLocaleEnv(gpa);
    defer env.deinit();

    const res = try std.process.run(gpa, io, .{
        .argv = argv.items,
        .environ_map = &env,
    });
    gpa.free(res.stdout);
    return .{ .stderr = res.stderr, .exit_code = termToCode(res.term), .gpa = gpa };
}

/// Replace the binary's full path and its basename with "PROG" so that
/// zsleep's and gsleep's diagnostics become byte-comparable.
fn normalize(gpa: std.mem.Allocator, text: []const u8, bin: []const u8) ![]u8 {
    const basename = std.fs.path.basename(bin);
    const step1 = try std.mem.replaceOwned(u8, gpa, text, bin, "PROG");
    defer gpa.free(step1);
    return std.mem.replaceOwned(u8, gpa, step1, basename, "PROG");
}

/// Assert zsleep matches GNU sleep on exit code AND normalized stderr.
fn expectParity(gpa: std.mem.Allocator, io: Io, gnu: []const u8, args: []const []const u8) !void {
    var z = try runFast(gpa, io, zsleepBin(), args);
    defer z.deinit();
    var g = try runFast(gpa, io, gnu, args);
    defer g.deinit();

    const zn = try normalize(gpa, z.stderr, zsleepBin());
    defer gpa.free(zn);
    const gn = try normalize(gpa, g.stderr, gnu);
    defer gpa.free(gn);

    var abuf: [256]u8 = undefined;
    const alabel = joinInto(&abuf, args);
    testing.expectEqual(g.exit_code, z.exit_code) catch |e| {
        std.debug.print("args=[{s}]\n  gnu exit={d} zsleep exit={d}\n", .{ alabel, g.exit_code, z.exit_code });
        return e;
    };
    testing.expectEqualStrings(gn, zn) catch |e| {
        std.debug.print("args=[{s}]\n  gnu stderr=<{s}>\n  zsleep stderr=<{s}>\n", .{ alabel, gn, zn });
        return e;
    };
}

/// Return true iff `bin extra…` is STILL RUNNING after `ms` (i.e. it is
/// sleeping, not crashing/erroring). Implemented via run() with a timeout:
/// a sleeping child keeps its stdout pipe open, so the reader blocks until the
/// timeout fires (error.Timeout); a child that crashes/exits early closes the
/// pipe and run() returns normally.
fn survivesFor(gpa: std.mem.Allocator, io: Io, bin: []const u8, extra: []const []const u8, ms: i64) !bool {
    var argv = std.ArrayListUnmanaged([]const u8).empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, bin);
    try argv.appendSlice(gpa, extra);

    var env = try cLocaleEnv(gpa);
    defer env.deinit();

    const timeout: Io.Timeout = .{ .duration = .{
        .raw = .fromMilliseconds(ms),
        .clock = .awake,
    } };

    if (std.process.run(gpa, io, .{
        .argv = argv.items,
        .environ_map = &env,
        .timeout = timeout,
    })) |res| {
        // Completed within the window => it exited early (did not sleep).
        gpa.free(res.stdout);
        gpa.free(res.stderr);
        return false;
    } else |err| switch (err) {
        error.Timeout => return true, // blocked in sleep => survived
        else => return err,
    }
}

test "parity: error diagnostics and exit codes match GNU sleep" {
    const gpa = testing.allocator;
    const io = testing.io;
    const gnu = gsleepBin() orelse return error.SkipZigTest;

    // Each of these terminates immediately (invalid input), so nothing sleeps.
    try expectParity(gpa, io, gnu, &.{"abc"}); // invalid time interval
    try expectParity(gpa, io, gnu, &.{""}); // empty operand
    try expectParity(gpa, io, gnu, &.{"5x"}); // bad suffix
    try expectParity(gpa, io, gnu, &.{"5s5"}); // suffix mid-string
    try expectParity(gpa, io, gnu, &.{"nan"}); // NaN rejected
    try expectParity(gpa, io, gnu, &.{ "5", "abc" }); // 2nd operand invalid, no sleep
    try expectParity(gpa, io, gnu, &.{ "--", "-5" }); // negative interval
    try expectParity(gpa, io, gnu, &.{"--foo"}); // unrecognized long option
    try expectParity(gpa, io, gnu, &.{"-5"}); // invalid short option
    try expectParity(gpa, io, gnu, &.{}); // missing operand
}

test "parity: exit code for help/version and option ordering" {
    const gpa = testing.allocator;
    const io = testing.io;
    const gnu = gsleepBin() orelse return error.SkipZigTest;

    // Help/version text differs by program, but the EXIT CODE and option
    // precedence (getopt permutation) must match GNU exactly.
    for ([_][]const []const u8{
        &.{"--help"},
        &.{"--version"},
        &.{ "abc", "--help" }, // --help wins over invalid operand (exit 0)
        &.{ "--foo", "--help" }, // --foo errors first (exit 1)
        &.{ "--help", "--foo" }, // --help wins (exit 0)
        &.{ "5", "--version" }, // version wins over the (valid) sleep
    }) |args| {
        var z = try runFast(gpa, io, zsleepBin(), args);
        defer z.deinit();
        var g = try runFast(gpa, io, gnu, args);
        defer g.deinit();
        var abuf: [256]u8 = undefined;
        testing.expectEqual(g.exit_code, z.exit_code) catch |e| {
            std.debug.print("args=[{s}] gnu={d} zsleep={d}\n", .{ joinInto(&abuf, args), g.exit_code, z.exit_code });
            return e;
        };
    }
}

test "parity: zero-length sleep returns immediately with exit 0" {
    const gpa = testing.allocator;
    const io = testing.io;
    const gnu = gsleepBin() orelse return error.SkipZigTest;
    try expectParity(gpa, io, gnu, &.{"0"});
}

test "anchor: fractional-with-suffix does not crash (0.5d), matches GNU sleeping" {
    // REGRESSION + MUTATION TARGET. Pre-fix, `zsleep 0.5d` aborted with SIGABRT
    // (u64 overflow) within milliseconds -> would NOT survive the window.
    // GNU `sleep 0.5d` sleeps 12h. Both must still be running after 300ms.
    const gpa = testing.allocator;
    const io = testing.io;
    const gnu = gsleepBin() orelse return error.SkipZigTest;

    try testing.expect(try survivesFor(gpa, io, gnu, &.{"0.5d"}, 300)); // anchor: GNU survives
    try testing.expect(try survivesFor(gpa, io, zsleepBin(), &.{"0.5d"}, 300)); // zsleep must too
    // And the overflow-prone huge integer input must not crash either.
    try testing.expect(try survivesFor(gpa, io, zsleepBin(), &.{"999999999999d"}, 300));
}

test "anchor: inf sleeps forever like GNU (does not exit early)" {
    const gpa = testing.allocator;
    const io = testing.io;
    const gnu = gsleepBin() orelse return error.SkipZigTest;
    try testing.expect(try survivesFor(gpa, io, gnu, &.{"inf"}, 300)); // anchor
    try testing.expect(try survivesFor(gpa, io, zsleepBin(), &.{"inf"}, 300));
    try testing.expect(try survivesFor(gpa, io, zsleepBin(), &.{"infinity"}, 300));
}
