//! Externally-anchored parity tests for zfactor.
//!
//! The primary anchor is the real GNU `factor` binary (GNU coreutils 9.10 via
//! Homebrew `gfactor`). Each `expectMatchesGnu` case runs BOTH zfactor and the
//! genuine GNU binary on identical input and asserts byte-identical stdout and
//! identical exit status. Neither the inputs nor the expected outputs were
//! authored by this library — they come from GNU coreutils. This satisfies
//! zig-forge CLAUDE.md golden-rule §1 (no roundtrip-only tests).
//!
//! A few cases are DELIBERATE, DOCUMENTED divergences from GNU and are anchored
//! to literal expected bytes with the divergence explained inline:
//!   * out-of-range (> u128) input: GNU has GMP arbitrary precision and factors
//!     it correctly; zfactor cannot, so it errors (exit 1) rather than silently
//!     wrapping. We assert the error, not a GNU match.
//!   * --version / --help first line: our program name/version differ from GNU;
//!     we assert routing to stdout + our own literal text.

const std = @import("std");
const build_opts = @import("build_opts");
const testing = std.testing;
const File = std.Io.File;

const ZFACTOR = build_opts.zfactor_path;
const GFACTOR = build_opts.gfactor_path;

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,
    fn deinit(self: RunResult, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

fn drain(a: std.mem.Allocator, io: std.Io, f: File) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(a);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = f.readStreaming(io, &.{&buf}) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (n == 0) break;
        try list.appendSlice(a, buf[0..n]);
    }
    return list.toOwnedSlice(a);
}

/// Run `path` with `args` and optional stdin bytes, capturing stdout/stderr/exit.
fn run(a: std.mem.Allocator, path: []const u8, args: []const []const u8, stdin: ?[]const u8) !RunResult {
    const io = testing.io;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.append(a, path);
    for (args) |arg| try argv.append(a, arg);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = if (stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    if (stdin) |data| {
        try child.stdin.?.writeStreamingAll(io, data);
        child.stdin.?.close(io);
        child.stdin = null;
    }

    // Outputs are tiny (well under the pipe buffer), so a sequential drain
    // cannot deadlock.
    const out = try drain(a, io, child.stdout.?);
    errdefer a.free(out);
    const err = try drain(a, io, child.stderr.?);
    errdefer a.free(err);

    const term = try child.wait(io);
    const code: u8 = switch (term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = out, .stderr = err, .code = code };
}

fn gfactorAvailable() bool {
    std.Io.Dir.accessAbsolute(testing.io, GFACTOR, .{}) catch return false;
    return true;
}

/// Core external anchor: identical stdout + exit code vs the real GNU binary.
fn expectMatchesGnu(args: []const []const u8, stdin: ?[]const u8) !void {
    const a = testing.allocator;
    if (!gfactorAvailable()) return error.SkipZigTest;

    const mine = try run(a, ZFACTOR, args, stdin);
    defer mine.deinit(a);
    const gnu = try run(a, GFACTOR, args, stdin);
    defer gnu.deinit(a);

    testing.expectEqualStrings(gnu.stdout, mine.stdout) catch |e| {
        std.debug.print("args={any} stdin={?s}\n gnu.out=<{s}>\n my .out=<{s}>\n", .{ args, stdin, gnu.stdout, mine.stdout });
        return e;
    };
    testing.expectEqual(gnu.code, mine.code) catch |e| {
        std.debug.print("args={any} stdin={?s} gnu.code={d} my.code={d}\n", .{ args, stdin, gnu.code, mine.code });
        return e;
    };
}

// --- Core factoring (byte-exact vs GNU) ---------------------------------

test "gnu parity: small numbers" {
    try expectMatchesGnu(&.{"12"}, null);
    try expectMatchesGnu(&.{"100"}, null);
    try expectMatchesGnu(&.{"97"}, null);
    try expectMatchesGnu(&.{"2"}, null);
    try expectMatchesGnu(&.{"4"}, null);
    try expectMatchesGnu(&.{"9"}, null);
    try expectMatchesGnu(&.{"1000000"}, null);
}

test "gnu parity: 0 and 1 edge cases" {
    try expectMatchesGnu(&.{"0"}, null);
    try expectMatchesGnu(&.{"1"}, null);
}

test "gnu parity: multiple args in one invocation" {
    try expectMatchesGnu(&.{ "12", "100", "97", "999983" }, null);
}

test "gnu parity: leading plus accepted" {
    try expectMatchesGnu(&.{"+12"}, null);
}

// --- Large primes / semiprimes (the DoS anchor) -------------------------
// Trial division would hang for minutes-to-forever on these; GNU (and now
// zfactor via Miller-Rabin + Pollard rho) return in milliseconds.

test "gnu parity: 21-digit prime (DoS anchor)" {
    try expectMatchesGnu(&.{"100000000000000000039"}, null);
}

test "gnu parity: large semiprime with a ~2^92 prime factor (rho anchor)" {
    try expectMatchesGnu(&.{"10000000000000000000000000000000000121"}, null);
}

test "gnu parity: u128 boundary 2^128-1" {
    try expectMatchesGnu(&.{"340282366920938463463374607431768211455"}, null);
    try expectMatchesGnu(&.{ "-h", "340282366920938463463374607431768211455" }, null);
}

// --- -h / --exponents ---------------------------------------------------

test "gnu parity: exponent formatting" {
    try expectMatchesGnu(&.{ "-h", "12" }, null);
    try expectMatchesGnu(&.{ "-h", "360" }, null);
    try expectMatchesGnu(&.{ "--exponents", "360" }, null);
    try expectMatchesGnu(&.{ "-h", "1024" }, null); // 2^10
}

// --- Invalid input (exit 1, empty stdout) -------------------------------

test "gnu parity: invalid input exits 1" {
    try expectMatchesGnu(&.{"abc"}, null);
    try expectMatchesGnu(&.{""}, null);
    try expectMatchesGnu(&.{"1 2"}, null); // embedded whitespace rejected
    try expectMatchesGnu(&.{" 12 "}, null); // surrounding whitespace rejected
}

// --- stdin (whitespace-tokenised like GNU) ------------------------------

test "gnu parity: stdin one number per line" {
    try expectMatchesGnu(&.{}, "12\n100\n97\n");
}

test "gnu parity: stdin multiple numbers per line" {
    try expectMatchesGnu(&.{}, "12 100 97\n");
}

test "gnu parity: stdin mixed valid/invalid (stdout + exit)" {
    // NOTE: only stdout + exit code are compared (not merged stderr order),
    // because GNU's libc fully-buffers stdout when it is a pipe while stderr
    // is unbuffered, so an interleaved 2>&1 order is a buffering artifact, not
    // a contract. stdout content and exit status are the real contract.
    try expectMatchesGnu(&.{}, "abc 13\n");
}

// --- DOCUMENTED divergences from GNU ------------------------------------

test "over-u128 input errors instead of silently wrapping (critical fix)" {
    // GNU factors this correctly via GMP arbitrary precision. zfactor is u128
    // and CANNOT, so it must error (exit 1) rather than clamp to 2^128-1 and
    // print a confidently-wrong factorization with exit 0 (the original bug).
    const a = testing.allocator;
    const r = try run(a, ZFACTOR, &.{"999999999999999999999999999999999999999999"}, null);
    defer r.deinit(a);
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings("", r.stdout); // no wrong answer emitted
    try testing.expect(r.stderr.len > 0); // an error was reported
}

test "--version goes to stdout, exit 0 (literal anchor)" {
    // GNU routes --version to stdout; original zfactor wrote it to stderr.
    // Program name/version differ from GNU, so we anchor to our own bytes.
    const a = testing.allocator;
    const r = try run(a, ZFACTOR, &.{"--version"}, null);
    defer r.deinit(a);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expectEqualStrings("zfactor 1.0.0\n", r.stdout);
    try testing.expectEqualStrings("", r.stderr);
}

test "--help goes to stdout, exit 0" {
    const a = testing.allocator;
    const r = try run(a, ZFACTOR, &.{"--help"}, null);
    defer r.deinit(a);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(std.mem.startsWith(u8, r.stdout, "Usage: zfactor"));
    try testing.expectEqualStrings("", r.stderr);
}

test "unknown leading-dash option is an error, exit 1" {
    const a = testing.allocator;
    const r = try run(a, ZFACTOR, &.{"-5"}, null);
    defer r.deinit(a);
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings("", r.stdout);
    try testing.expect(r.stderr.len > 0);
}
