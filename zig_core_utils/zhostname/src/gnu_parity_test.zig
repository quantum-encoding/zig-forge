//! Externally-anchored tests for zhostname (GNU/inetutils `hostname` clone).
//!
//! ANCHOR NOTE (per zig-forge/CLAUDE.md golden rule §1):
//! No GNU/inetutils `hostname` binary is installed on this host (neither
//! /opt/homebrew/opt/coreutils/libexec/gnubin/hostname, /opt/homebrew/bin/ghostname,
//! nor an inetutils build exist). The system's `/bin/hostname` (BSD) is a real,
//! external, non-zhostname program this repo did not write. Both `/bin/hostname`
//! with no arguments and GNU/inetutils `hostname` with no arguments print the
//! value returned by gethostname(2) followed by a newline — so the primary
//! anchor is byte-for-byte equality against `/bin/hostname`'s stdout. That
//! comparison catches the OOB / truncation bug in the getter (a mis-terminated
//! buffer would print garbage or a wrong-length token, diverging from
//! /bin/hostname).
//!
//! The remaining tests anchor to documented GNU/inetutils behavior:
//!   - `-s` / `--short`  -> hostname up to the first dot (coreutils/inetutils docs)
//!   - unknown option    -> diagnostic on stderr + exit 1 (GNU rejects, not ignores)
//!   - extra operands    -> diagnostic on stderr + exit 1 (at most one NAME)
//!   - --version         -> version line on stdout, exit 0
//!   - --help            -> usage on stdout, exit 0
//! These are NOT roundtrip tests: expected bytes/exit codes come from an
//! external binary (`/bin/hostname`) and from the documented GNU contract.
//!
//! If `/bin/hostname` is missing, the comparison test SkipZigTest rather than
//! silently passing.

const std = @import("std");
const build_options = @import("build_options");

const ZHOSTNAME: []const u8 = build_options.zhostname_exe;
const HOSTNAME: []const u8 = "/bin/hostname";
const io = std.testing.io;

fn hostnameAvailable() bool {
    _ = std.Io.Dir.cwd().statFile(io, HOSTNAME, .{}) catch return false;
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

// PRIMARY EXTERNAL ANCHOR: zhostname (no args) must reproduce `/bin/hostname`
// byte-for-byte. Both print gethostname(2) + "\n". A mis-terminated getter
// buffer (the pre-fix `undefined` stack buffer) would print a wrong-length
// token or trailing garbage, so this diff would go RED.
test "zhostname output equals /bin/hostname (external anchor)" {
    if (!hostnameAvailable()) return error.SkipZigTest;
    const alloc = std.testing.allocator;

    const got = try run(alloc, &.{ZHOSTNAME});
    defer got.free(alloc);
    try std.testing.expect(!got.crashed);
    try std.testing.expectEqual(@as(u8, 0), got.code);

    const want = try run(alloc, &.{HOSTNAME});
    defer want.free(alloc);
    try std.testing.expect(!want.crashed);
    try std.testing.expectEqual(@as(u8, 0), want.code);

    try std.testing.expect(got.stdout.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, got.stdout, "\n"));
    // BSD /bin/hostname may print the FQDN; zhostname prints the raw
    // gethostname() value. On this host they are identical. Compare exactly —
    // if they ever diverge the test surfaces it rather than hiding it.
    try std.testing.expectEqualStrings(want.stdout, got.stdout);
}

// The printed hostname must be a single clean line with no embedded NULs —
// proves we sliced to the terminator, not printed a whole fixed-size field.
// The pre-fix bug (uninitialized 256-byte buffer, no reserved terminator)
// could walk past the buffer into adjacent stack memory on truncation.
test "hostname is a clean non-empty token with single trailing newline" {
    const alloc = std.testing.allocator;
    const got = try run(alloc, &.{ZHOSTNAME});
    defer got.free(alloc);

    try std.testing.expect(!got.crashed);
    try std.testing.expectEqual(@as(u8, 0), got.code);
    try std.testing.expect(got.stdout.len >= 2); // at least one char + newline
    try std.testing.expectEqual(@as(u8, '\n'), got.stdout[got.stdout.len - 1]);
    try std.testing.expect(std.mem.indexOfScalar(u8, got.stdout, 0) == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, got.stdout, "\n"));
}

// Documented GNU/inetutils behavior: `-s`/`--short` truncates at the first
// dot. Anchor: the short form must equal everything before the first '.' of
// the plain output (and be dot-free), for both spellings.
test "-s / --short truncate at first dot" {
    const alloc = std.testing.allocator;

    const full = try run(alloc, &.{ZHOSTNAME});
    defer full.free(alloc);
    try std.testing.expectEqual(@as(u8, 0), full.code);
    const full_name = std.mem.trimEnd(u8, full.stdout, "\n");

    const expected_short = if (std.mem.indexOfScalar(u8, full_name, '.')) |dot|
        full_name[0..dot]
    else
        full_name;

    for ([_][]const u8{ "-s", "--short" }) |flag| {
        const got = try run(alloc, &.{ ZHOSTNAME, flag });
        defer got.free(alloc);
        try std.testing.expectEqual(@as(u8, 0), got.code);
        const short_name = std.mem.trimEnd(u8, got.stdout, "\n");
        try std.testing.expectEqualStrings(expected_short, short_name);
        try std.testing.expect(std.mem.indexOfScalar(u8, short_name, '.') == null);
    }
}

// Documented GNU behavior: an unknown option is rejected (diagnostic on
// stderr, exit 1), not silently ignored (which would print the hostname and
// exit 0 — the pre-fix bug).
test "unknown option -> diagnostic, exit 1" {
    const alloc = std.testing.allocator;
    const got = try run(alloc, &.{ ZHOSTNAME, "-z" });
    defer got.free(alloc);

    try std.testing.expect(!got.crashed);
    try std.testing.expectEqual(@as(u8, 1), got.code);
    try std.testing.expectEqualStrings("", got.stdout);
    try std.testing.expect(got.stderr.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "-z") != null);
}

// A long-form unknown option (e.g. a flag zhostname does not implement) must
// also be rejected, not treated as a positional.
test "unknown long option -> diagnostic, exit 1" {
    const alloc = std.testing.allocator;
    const got = try run(alloc, &.{ ZHOSTNAME, "--fqdn" });
    defer got.free(alloc);

    try std.testing.expectEqual(@as(u8, 1), got.code);
    try std.testing.expectEqualStrings("", got.stdout);
    try std.testing.expect(got.stderr.len > 0);
}

// Documented GNU behavior: at most one NAME operand. Extra operands are an
// error (exit 1), NOT silently coalesced to the last (the pre-fix behavior).
// We do not pass a single operand because setting the hostname needs root and
// would mutate the machine; two operands are rejected during arg parsing
// before any sethostname() call.
test "extra operands -> diagnostic, exit 1" {
    const alloc = std.testing.allocator;
    const got = try run(alloc, &.{ ZHOSTNAME, "aaa", "bbb" });
    defer got.free(alloc);

    try std.testing.expect(!got.crashed);
    try std.testing.expectEqual(@as(u8, 1), got.code);
    try std.testing.expectEqualStrings("", got.stdout);
    // Must be rejected during ARG PARSING ("too many arguments"), before any
    // sethostname() attempt. If the extra operand were silently coalesced to
    // the last (the pre-fix bug), zhostname would instead try sethostname()
    // and fail with a permission diagnostic — a distinguishable stderr.
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "too many arguments") != null);
}

// --version prints an identifying line on stdout and exits 0 (documented GNU
// behavior). Pre-fix, --version fell through the unknown-flag path and printed
// the hostname.
test "--version exits 0 with a version line" {
    const alloc = std.testing.allocator;
    const got = try run(alloc, &.{ ZHOSTNAME, "--version" });
    defer got.free(alloc);

    try std.testing.expectEqual(@as(u8, 0), got.code);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "zhostname") != null);
}

// --help prints usage on stdout and exits 0.
test "--help exits 0 with usage" {
    const alloc = std.testing.allocator;
    const got = try run(alloc, &.{ ZHOSTNAME, "--help" });
    defer got.free(alloc);

    try std.testing.expectEqual(@as(u8, 0), got.code);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "Usage") != null);
}
