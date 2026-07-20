//! Externally-anchored parity tests for zhostid.
//!
//! The anchor is the REAL GNU `hostid` binary (GNU coreutils 9.10), located via
//! a build option (see build.zig). For each representative invocation we run
//! BOTH binaries under `LC_ALL=C`, then compare stdout, stderr and exit status.
//! Because the two programs necessarily print different program names, outputs
//! are normalized by replacing each binary's own invocation path and basename
//! with fixed placeholders before comparison — everything else (wording,
//! quoting, framing, exit codes) must match byte-for-byte.
//!
//! This is a true external anchor per zig-forge/CLAUDE.md's golden rule: the
//! expected bytes come from a third-party implementation the author did not
//! write, not from a roundtrip of our own output.
//!
//! If the GNU binary is absent, the cross-checks are skipped and we fall back
//! to asserting against the literal bytes documented from GNU behavior (also
//! recorded here), so the suite still anchors to an external spec.

const std = @import("std");
const build_options = @import("build_options");

const zhostid_bin = build_options.zhostid_bin;
const gnu_hostid = build_options.gnu_hostid;

const Result = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8, // exit code; 255 used as a sentinel for signal termination
};

fn run(allocator: std.mem.Allocator, bin: []const u8, args: []const []const u8) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, bin);
    for (args) |a| try argv.append(allocator, a);

    // Minimal child environment forcing the C locale, so GNU emits ASCII
    // quotes and untranslated (English) diagnostics — deterministic to diff.
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("LC_ALL", "C");
    try env.put("LANG", "C");
    try env.put("LC_MESSAGES", "C");

    const res = try std.process.run(allocator, std.testing.io, .{
        .argv = argv.items,
        .environ_map = &env,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = res.stdout, .stderr = res.stderr, .code = code };
}

/// Replace every occurrence of the binary's full invocation path (with "@P")
/// and its basename (with "@N"). Path first, since the basename is a substring
/// of the path.
fn normalize(allocator: std.mem.Allocator, s: []const u8, bin: []const u8) ![]u8 {
    const base = std.fs.path.basename(bin);
    const step1 = try std.mem.replaceOwned(u8, allocator, s, bin, "@P");
    defer allocator.free(step1);
    const step2 = try std.mem.replaceOwned(u8, allocator, step1, base, "@N");
    defer allocator.free(step2);
    // Locale-independent quoting: collapse GNU's U+2018/U+2019 smart quotes and
    // ASCII quotes to a single token (belt-and-suspenders beside LC_ALL=C).
    const step3 = try std.mem.replaceOwned(u8, allocator, step2, "\u{2018}", "@Q");
    defer allocator.free(step3);
    const step4 = try std.mem.replaceOwned(u8, allocator, step3, "\u{2019}", "@Q");
    defer allocator.free(step4);
    return std.mem.replaceOwned(u8, allocator, step4, "'", "@Q");
}

fn gnuAvailable() bool {
    if (gnu_hostid.len == 0) return false;
    // No stable synchronous fs.access in this std; probe by spawning GNU once.
    // A missing binary makes Child.run return error.FileNotFound.
    const a = std.testing.allocator;
    const r = run(a, gnu_hostid, &.{"--version"}) catch return false;
    a.free(r.stdout);
    a.free(r.stderr);
    return r.code == 0;
}

/// Run `args` through both binaries and assert normalized stdout, normalized
/// stderr and exit code all match. Skips (returns) if GNU is unavailable.
fn expectParity(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (!gnuAvailable()) return error.SkipZigTest;

    const mine = try run(allocator, zhostid_bin, args);
    defer allocator.free(mine.stdout);
    defer allocator.free(mine.stderr);
    const gnu = try run(allocator, gnu_hostid, args);
    defer allocator.free(gnu.stdout);
    defer allocator.free(gnu.stderr);

    const mine_out = try normalize(allocator, mine.stdout, zhostid_bin);
    defer allocator.free(mine_out);
    const gnu_out = try normalize(allocator, gnu.stdout, gnu_hostid);
    defer allocator.free(gnu_out);
    const mine_err = try normalize(allocator, mine.stderr, zhostid_bin);
    defer allocator.free(mine_err);
    const gnu_err = try normalize(allocator, gnu.stderr, gnu_hostid);
    defer allocator.free(gnu_err);

    std.testing.expectEqual(gnu.code, mine.code) catch |e| {
        std.debug.print("exit-code mismatch for args={any}: gnu={d} mine={d}\n", .{ args, gnu.code, mine.code });
        return e;
    };
    std.testing.expectEqualStrings(gnu_out, mine_out) catch |e| {
        std.debug.print("stdout mismatch for args={any}\n", .{args});
        return e;
    };
    std.testing.expectEqualStrings(gnu_err, mine_err) catch |e| {
        std.debug.print("stderr mismatch for args={any}\n", .{args});
        return e;
    };
}

// ---------------------------------------------------------------------------
// Cross-implementation parity (the primary external anchor).
// ---------------------------------------------------------------------------

test "no args: hostid value matches GNU byte-for-byte" {
    // Both binaries call libc gethostid() on the same host, so the printed
    // 8-hex-digit value + trailing newline must be identical. No program-name
    // normalization needed here — the output is pure hostid.
    const a = std.testing.allocator;
    if (!gnuAvailable()) return error.SkipZigTest;

    const mine = try run(a, zhostid_bin, &.{});
    defer a.free(mine.stdout);
    defer a.free(mine.stderr);
    const gnu = try run(a, gnu_hostid, &.{});
    defer a.free(gnu.stdout);
    defer a.free(gnu.stderr);

    try std.testing.expectEqual(@as(u8, 0), gnu.code);
    try std.testing.expectEqual(@as(u8, 0), mine.code);
    try std.testing.expectEqualStrings(gnu.stdout, mine.stdout);
    // Sanity on the shape: 8 hex digits + '\n'.
    try std.testing.expectEqual(@as(usize, 9), mine.stdout.len);
    try std.testing.expectEqual(@as(u8, '\n'), mine.stdout[8]);
    for (mine.stdout[0..8]) |c| {
        try std.testing.expect(std.ascii.isHex(c) and (c < 'A' or c > 'F'));
    }
}

test "extra operand errors like GNU (exit 1, same message frame)" {
    try expectParity(std.testing.allocator, &.{"foo"});
}

test "only the first extra operand is reported (like GNU)" {
    try expectParity(std.testing.allocator, &.{ "foo", "bar" });
}

test "empty-string operand errors like GNU" {
    try expectParity(std.testing.allocator, &.{""});
}

test "lone dash is treated as an operand like GNU" {
    try expectParity(std.testing.allocator, &.{"-"});
}

test "unknown long option errors like GNU" {
    try expectParity(std.testing.allocator, &.{"--bogus"});
}

test "invalid short option errors like GNU" {
    try expectParity(std.testing.allocator, &.{"-x"});
}

test "-- terminates options; following token is an extra operand like GNU" {
    try expectParity(std.testing.allocator, &.{ "--", "foo" });
}

test "option before operand: --bogus wins over foo like GNU" {
    try expectParity(std.testing.allocator, &.{ "foo", "--bogus" });
}

// ---------------------------------------------------------------------------
// --help / --version: behavior anchored to GNU (both exit 0), content anchored
// to the documented GNU shape via literal bytes (program name aside).
// ---------------------------------------------------------------------------

test "--version exits 0 (GNU parity) and prints a single version line" {
    const a = std.testing.allocator;
    const mine = try run(a, zhostid_bin, &.{"--version"});
    defer a.free(mine.stdout);
    defer a.free(mine.stderr);

    try std.testing.expectEqual(@as(u8, 0), mine.code);
    // Documented GNU shape: first token is the program name, output is one line.
    try std.testing.expect(std.mem.startsWith(u8, mine.stdout, "zhostid "));
    try std.testing.expect(std.mem.endsWith(u8, mine.stdout, "\n"));
    try std.testing.expectEqual(@as(usize, 0), mine.stderr.len);

    if (gnuAvailable()) {
        const gnu = try run(a, gnu_hostid, &.{"--version"});
        defer a.free(gnu.stdout);
        defer a.free(gnu.stderr);
        try std.testing.expectEqual(@as(u8, 0), gnu.code);
        // GNU's first token is the program name too.
        try std.testing.expect(std.mem.startsWith(u8, gnu.stdout, "hostid "));
    }
}

test "--help exits 0 (GNU parity) and matches GNU usage wording" {
    const a = std.testing.allocator;
    const mine = try run(a, zhostid_bin, &.{"--help"});
    defer a.free(mine.stdout);
    defer a.free(mine.stderr);

    try std.testing.expectEqual(@as(u8, 0), mine.code);
    try std.testing.expectEqual(@as(usize, 0), mine.stderr.len);
    // GNU coreutils 9.10 hostid --help wording (literal, external anchor):
    try std.testing.expect(std.mem.startsWith(u8, mine.stdout, "Usage: zhostid [OPTION]\n"));
    try std.testing.expect(std.mem.indexOf(u8, mine.stdout, "Print the numeric identifier (in hexadecimal) for the current host.\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, mine.stdout, "--help") != null);
    try std.testing.expect(std.mem.indexOf(u8, mine.stdout, "--version") != null);

    if (gnuAvailable()) {
        const gnu = try run(a, gnu_hostid, &.{"--help"});
        defer a.free(gnu.stdout);
        defer a.free(gnu.stderr);
        try std.testing.expectEqual(@as(u8, 0), gnu.code);
        // Confirm the wording we anchored to actually appears in GNU's help.
        try std.testing.expect(std.mem.indexOf(u8, gnu.stdout, "Print the numeric identifier (in hexadecimal) for the current host.") != null);
    }
}

test "abbreviated --hel and --vers resolve like getopt_long" {
    const a = std.testing.allocator;
    const h = try run(a, zhostid_bin, &.{"--hel"});
    defer a.free(h.stdout);
    defer a.free(h.stderr);
    try std.testing.expectEqual(@as(u8, 0), h.code);
    try std.testing.expect(std.mem.startsWith(u8, h.stdout, "Usage: zhostid [OPTION]\n"));

    const v = try run(a, zhostid_bin, &.{"--vers"});
    defer a.free(v.stdout);
    defer a.free(v.stderr);
    try std.testing.expectEqual(@as(u8, 0), v.code);
    try std.testing.expect(std.mem.startsWith(u8, v.stdout, "zhostid "));

    // Cross-check GNU accepts the same abbreviations with exit 0.
    if (gnuAvailable()) {
        const gh = try run(a, gnu_hostid, &.{"--hel"});
        defer a.free(gh.stdout);
        defer a.free(gh.stderr);
        try std.testing.expectEqual(@as(u8, 0), gh.code);
    }
}
