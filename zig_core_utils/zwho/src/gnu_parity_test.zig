//! Externally-anchored parity tests for zwho vs GNU coreutils `who`.
//!
//! The anchor is the REAL GNU binary (coreutils 9.10) discovered on this host,
//! not any output zwho produced. Each test runs both binaries against the same
//! live utmpx database and asserts byte-identical stdout, or asserts the exact
//! exit-code / diagnostic contract GNU `who` documents. There are NO
//! roundtrip-only tests (zig-forge golden rule §1).
//!
//! If no GNU `who` is found the diff tests skip (SkipZigTest) rather than
//! silently pass, so the suite never claims parity it did not verify. The
//! exit-code contract for unknown options and --version/--help is additionally
//! pinned to documented GNU behavior so it holds even without the binary.

const std = @import("std");
const build_options = @import("build_options");

const zwho_path = build_options.zwho_path;

// Candidate locations for the GNU reference binary (Homebrew coreutils).
const gwho_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/who",
    "/opt/homebrew/bin/gwho",
    "/usr/local/opt/coreutils/libexec/gnubin/who",
    "/usr/local/bin/gwho",
};

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8, // 255 sentinel for signal / abnormal termination

    fn deinit(self: RunResult, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

/// Run `argv`, returning captured output, or null if argv[0] does not exist.
fn tryRun(a: std.mem.Allocator, argv: []const []const u8) !?RunResult {
    const res = std.process.run(a, std.testing.io, .{
        .argv = argv,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = res.stdout, .stderr = res.stderr, .code = code };
}

fn runZwho(a: std.mem.Allocator, extra: []const []const u8) !RunResult {
    var buf: [8][]const u8 = undefined;
    buf[0] = zwho_path;
    @memcpy(buf[1 .. 1 + extra.len], extra);
    return (try tryRun(a, buf[0 .. 1 + extra.len])) orelse error.ZwhoBinaryMissing;
}

/// Run the GNU reference with `extra` args; null if no GNU who is installed.
fn runGwho(a: std.mem.Allocator, extra: []const []const u8) !?RunResult {
    for (gwho_candidates) |cand| {
        var buf: [8][]const u8 = undefined;
        buf[0] = cand;
        @memcpy(buf[1 .. 1 + extra.len], extra);
        if (try tryRun(a, buf[0 .. 1 + extra.len])) |r| return r;
    }
    return null;
}

// --- Diff tests: zwho stdout must equal GNU who stdout, byte for byte. ---

fn expectSameStdout(a: std.mem.Allocator, extra: []const []const u8) !void {
    const g = (try runGwho(a, extra)) orelse return error.SkipZigTest;
    defer g.deinit(a);
    const z = try runZwho(a, extra);
    defer z.deinit(a);

    try std.testing.expectEqual(g.code, z.code);
    std.testing.expectEqualStrings(g.stdout, z.stdout) catch |e| {
        std.debug.print(
            "\nzwho vs gwho stdout mismatch for args {any}:\n--- gwho ---\n{s}\n--- zwho ---\n{s}\n",
            .{ extra, g.stdout, z.stdout },
        );
        return e;
    };
}

test "parity: no args (login records) matches GNU who" {
    try expectSameStdout(std.testing.allocator, &.{});
}

test "parity: -H heading matches GNU who" {
    // Anchors the COMMENT column label + column widths against GNU output.
    try expectSameStdout(std.testing.allocator, &.{"-H"});
}

test "parity: --heading long form matches GNU who" {
    try expectSameStdout(std.testing.allocator, &.{"--heading"});
}

test "parity: -q count matches GNU who" {
    try expectSameStdout(std.testing.allocator, &.{"-q"});
}

test "parity: --count long form matches GNU who" {
    try expectSameStdout(std.testing.allocator, &.{"--count"});
}

// --- Heading label is literally COMMENT, never HOST (documented anchor). ---
// GNU coreutils who prints `NAME     LINE         TIME             COMMENT` as
// its heading (verified via `who -H`; coreutils who.c uses "COMMENT"). The
// pre-fix zwho printed HOST, which broke column-name parsing.

test "heading last column is COMMENT not HOST" {
    const a = std.testing.allocator;
    const z = try runZwho(a, &.{"-H"});
    defer z.deinit(a);
    try std.testing.expectEqual(@as(u8, 0), z.code);
    const first_nl = std.mem.indexOfScalar(u8, z.stdout, '\n') orelse z.stdout.len;
    const heading = z.stdout[0..first_nl];
    try std.testing.expectEqualStrings("NAME     LINE         TIME             COMMENT", heading);
    try std.testing.expect(std.mem.indexOf(u8, heading, "HOST") == null);
}

// --- Exit-code contract: unknown options. ---
// GNU who rejects unknown options with a stderr diagnostic and a non-zero
// exit (observed exit 1 on coreutils 9.10). zwho must do the same and must
// NOT emit login records to stdout.

test "unknown option: nonzero exit, diagnostic on stderr, empty stdout" {
    const a = std.testing.allocator;
    const z = try runZwho(a, &.{"--bogus"});
    defer z.deinit(a);
    try std.testing.expect(z.code != 0);
    try std.testing.expectEqual(@as(usize, 0), z.stdout.len);
    try std.testing.expect(z.stderr.len > 0);

    // Cross-check the exit code against the real GNU binary when present.
    if (try runGwho(a, &.{"--bogus"})) |g| {
        defer g.deinit(a);
        try std.testing.expectEqual(g.code, z.code);
        try std.testing.expectEqual(@as(usize, 0), g.stdout.len);
    }
}

test "unknown short option is also rejected" {
    const a = std.testing.allocator;
    const z = try runZwho(a, &.{"-Z"});
    defer z.deinit(a);
    try std.testing.expect(z.code != 0);
    try std.testing.expectEqual(@as(usize, 0), z.stdout.len);
}

// --- --version and --help: exit 0 with output on stdout (GNU contract). ---

test "--version exits 0 with a banner on stdout" {
    const a = std.testing.allocator;
    const z = try runZwho(a, &.{"--version"});
    defer z.deinit(a);
    try std.testing.expectEqual(@as(u8, 0), z.code);
    try std.testing.expect(z.stdout.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, z.stdout, "zwho"));

    if (try runGwho(a, &.{"--version"})) |g| {
        defer g.deinit(a);
        try std.testing.expectEqual(g.code, z.code); // both 0
    }
}

test "--help exits 0 with usage on stdout" {
    const a = std.testing.allocator;
    const z = try runZwho(a, &.{"--help"});
    defer z.deinit(a);
    try std.testing.expectEqual(@as(u8, 0), z.code);
    try std.testing.expect(std.mem.startsWith(u8, z.stdout, "Usage:"));

    if (try runGwho(a, &.{"--help"})) |g| {
        defer g.deinit(a);
        try std.testing.expectEqual(g.code, z.code); // both 0
    }
}
