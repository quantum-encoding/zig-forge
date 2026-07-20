//! Externally-anchored tests for zprintf (GNU coreutils `printf` parity).
//!
//! Per zig-forge/CLAUDE.md's golden rule, these tests are NOT roundtrips.
//! Two anchoring strategies are used:
//!
//!   1. Literal anchors (always run): the pure argument-parsing helpers are
//!      checked against expected values taken from GNU/POSIX documented
//!      behavior, hardcoded here. Sources cited inline. These do not depend
//!      on any external binary being installed.
//!
//!   2. Live diff anchors (run when the real GNU binary is present): zprintf's
//!      actual stdout + exit code are diffed byte-for-byte against the output
//!      of the real GNU coreutils `printf` for a spread of representative
//!      format strings and arguments. This is the strongest anchor — the
//!      expected bytes come from the reference implementation itself, not us.
//!
//! Wired into `zig build test`. The zprintf binary path is injected by
//! build.zig via the `build_options` module.

const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");
const main = @import("main.zig");

// ===========================================================================
// 1. LITERAL ANCHORS — pure functions vs documented GNU/POSIX values
// ===========================================================================

test "parseSigned: leading-quote char code (POSIX: 'A -> 65)" {
    // POSIX printf / GNU: a numeric arg beginning with ' or " has the value of
    // the numeric code of the next byte. `printf '%d' "'A"` -> 65.
    try testing.expectEqual(@as(i64, 65), main.parseSigned("'A"));
    try testing.expectEqual(@as(i64, 90), main.parseSigned("\"Z"));
    try testing.expectEqual(@as(i64, 48), main.parseSigned("'0"));
}

test "parseSigned: overflow clamps to INT64 range (GNU strtoimax)" {
    // GNU: out-of-range -> clamp to INTMAX_MAX/MIN + "Result too large".
    try testing.expectEqual(std.math.maxInt(i64), main.parseSigned("99999999999999999999"));
    try testing.expectEqual(std.math.minInt(i64), main.parseSigned("-99999999999999999999"));
    // Exact boundaries must round-trip, not clamp.
    try testing.expectEqual(std.math.maxInt(i64), main.parseSigned("9223372036854775807"));
    try testing.expectEqual(std.math.minInt(i64), main.parseSigned("-9223372036854775808"));
}

test "parseSigned: base detection (hex 0x, octal 0)" {
    // GNU: `printf '%d' 0x1F` -> 31 ; `printf '%d' 010` -> 8.
    try testing.expectEqual(@as(i64, 31), main.parseSigned("0x1F"));
    try testing.expectEqual(@as(i64, 8), main.parseSigned("010"));
    try testing.expectEqual(@as(i64, 0), main.parseSigned("0"));
    try testing.expectEqual(@as(i64, -42), main.parseSigned("-42"));
    try testing.expectEqual(@as(i64, 255), main.parseSigned("0xff"));
}

test "parseSigned: empty arg is zero, no error" {
    // GNU: a missing argument formats as 0 with exit 0.
    try testing.expectEqual(@as(i64, 0), main.parseSigned(""));
}

test "parseUnsigned: negative wraps two's complement (GNU strtoumax)" {
    // GNU: `printf '%u' -1` -> 18446744073709551615.
    try testing.expectEqual(std.math.maxInt(u64), main.parseUnsigned("-1"));
    try testing.expectEqual(@as(u64, 255), main.parseUnsigned("255"));
    try testing.expectEqual(@as(u64, 65), main.parseUnsigned("'A"));
    // Overflow clamps to UINT64_MAX.
    try testing.expectEqual(std.math.maxInt(u64), main.parseUnsigned("999999999999999999999999"));
}

test "digitVal: base-limited digit values" {
    try testing.expectEqual(@as(?u8, 9), main.digitVal('9', 10));
    try testing.expectEqual(@as(?u8, null), main.digitVal('8', 8)); // 8 invalid in octal
    try testing.expectEqual(@as(?u8, 15), main.digitVal('f', 16));
    try testing.expectEqual(@as(?u8, 15), main.digitVal('F', 16));
    try testing.expectEqual(@as(?u8, null), main.digitVal('g', 16));
}

test "buildCFmt: reconstructs C conversion specs (sign/zero/width/precision)" {
    var buf: [64]u8 = undefined;

    // %05d  -> zero flag + width 5
    {
        const spec = main.FormatSpec{ .zero_pad = true, .width = 5, .specifier = 'd' };
        try testing.expectEqualStrings("%05lld", main.buildCFmt(&buf, &spec, "ll", 'd'));
    }
    // %+05d -> plus + zero + width
    {
        const spec = main.FormatSpec{ .show_sign = true, .zero_pad = true, .width = 5, .specifier = 'd' };
        try testing.expectEqualStrings("%+05lld", main.buildCFmt(&buf, &spec, "ll", 'd'));
    }
    // %-10.5s style, but for a float: %-10.5f
    {
        const spec = main.FormatSpec{ .left_align = true, .width = 10, .precision = 5, .specifier = 'f' };
        try testing.expectEqualStrings("%-10.5f", main.buildCFmt(&buf, &spec, "", 'f'));
    }
    // %#x
    {
        const spec = main.FormatSpec{ .alternate = true, .specifier = 'x' };
        try testing.expectEqualStrings("%#llx", main.buildCFmt(&buf, &spec, "ll", 'x'));
    }
    // %.0d (precision zero must emit ".0", not be dropped)
    {
        const spec = main.FormatSpec{ .precision = 0, .specifier = 'd' };
        try testing.expectEqualStrings("%.0lld", main.buildCFmt(&buf, &spec, "ll", 'd'));
    }
}

test "writeUintDec: decimal rendering" {
    var buf: [24]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), main.writeUintDec(&buf, 0));
    try testing.expectEqualStrings("0", buf[0..1]);
    const n = main.writeUintDec(&buf, 12345);
    try testing.expectEqualStrings("12345", buf[0..n]);
}

// ===========================================================================
// 2. LIVE DIFF ANCHORS — zprintf stdout/exit vs the real GNU binary
// ===========================================================================

extern "c" fn popen(cmd: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn pclose(stream: *anyopaque) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/printf",
    "/opt/homebrew/bin/gprintf",
    "/usr/local/opt/coreutils/libexec/gnubin/printf",
    "/usr/bin/printf", // GNU on Linux
};

fn findGnu() ?[]const u8 {
    for (gnu_candidates) |c| {
        var zbuf: [512]u8 = undefined;
        const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{c}) catch continue;
        if (access(z.ptr, 0) == 0) return c;
    }
    return null;
}

const RunResult = struct {
    stdout: []u8,
    exit_code: u8,
};

/// Run `cmd` via /bin/sh, capturing stdout and the process exit code.
fn shell(alloc: std.mem.Allocator, cmd: [:0]const u8) !RunResult {
    const f = popen(cmd.ptr, "r") orelse return error.PopenFailed;
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const got = fread(&chunk, 1, chunk.len, f);
        if (got > 0) try list.appendSlice(alloc, chunk[0..got]);
        if (got < chunk.len) break;
    }
    const status = pclose(f);
    // POSIX wait status: normal-exit code lives in bits 8..15.
    const code: u8 = @intCast((@as(u32, @bitCast(status)) >> 8) & 0xff);
    return .{ .stdout = try list.toOwnedSlice(alloc), .exit_code = code };
}

/// Shell-single-quote a byte string so it survives /bin/sh word splitting.
fn sq(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    try list.append(alloc, '\'');
    for (s) |c| {
        if (c == '\'') {
            try list.appendSlice(alloc, "'\\''");
        } else {
            try list.append(alloc, c);
        }
    }
    try list.append(alloc, '\'');
    return list.toOwnedSlice(alloc);
}

/// Build `<bin> '<fmt>' '<arg>'...` as a NUL-terminated shell command.
fn buildCmd(alloc: std.mem.Allocator, bin: []const u8, fmt: []const u8, args: []const []const u8) ![:0]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    try list.appendSlice(alloc, bin);
    try list.append(alloc, ' ');
    const qf = try sq(alloc, fmt);
    defer alloc.free(qf);
    try list.appendSlice(alloc, qf);
    for (args) |a| {
        try list.append(alloc, ' ');
        const qa = try sq(alloc, a);
        defer alloc.free(qa);
        try list.appendSlice(alloc, qa);
    }
    return list.toOwnedSliceSentinel(alloc, 0);
}

const Case = struct {
    fmt: []const u8,
    args: []const []const u8 = &.{},
};

const cases = [_]Case{
    // --- basics ---
    .{ .fmt = "%d\\n", .args = &.{"42"} },
    .{ .fmt = "%s %s\\n", .args = &.{ "a", "b", "c", "d" } }, // format reuse
    .{ .fmt = "hello\\tworld\\n" },
    .{ .fmt = "%c%c%c\\n", .args = &.{ "a", "b", "c" } },

    // --- sign + zero padding (finding: %05d -42 -> -0042, not 00-42) ---
    .{ .fmt = "%05d\\n", .args = &.{"-42"} },
    .{ .fmt = "%+05d\\n", .args = &.{"42"} },
    .{ .fmt = "%+05d\\n", .args = &.{"-42"} },
    .{ .fmt = "% d\\n", .args = &.{"42"} },
    .{ .fmt = "%.5d\\n", .args = &.{"42"} },
    .{ .fmt = "%-8d|\\n", .args = &.{"42"} },

    // --- overflow clamp (finding: crash -> clamp + exit 1) ---
    .{ .fmt = "%d\\n", .args = &.{"99999999999999999999"} },
    .{ .fmt = "%d\\n", .args = &.{"-9223372036854775808"} },
    .{ .fmt = "%d\\n", .args = &.{"9223372036854775807"} },

    // --- leading-quote char codes (finding) ---
    .{ .fmt = "%d\\n", .args = &.{"'A"} },
    .{ .fmt = "%d\\n", .args = &.{"\"Z"} },

    // --- unsigned / hex / octal ---
    .{ .fmt = "%u\\n", .args = &.{"-1"} },
    .{ .fmt = "%x\\n", .args = &.{"255"} },
    .{ .fmt = "%#x\\n", .args = &.{"255"} },
    .{ .fmt = "%#08X\\n", .args = &.{"255"} },
    .{ .fmt = "%o\\n", .args = &.{"64"} },
    .{ .fmt = "%d\\n", .args = &.{"0x1F"} },
    .{ .fmt = "%d\\n", .args = &.{"010"} },

    // --- floats: %e/%E exponent, %g stripping, big precision (findings) ---
    .{ .fmt = "%e\\n", .args = &.{"12345.678"} },
    .{ .fmt = "%E\\n", .args = &.{"12345.678"} },
    .{ .fmt = "%+.2e\\n", .args = &.{"1234.5"} },
    .{ .fmt = "%g\\n", .args = &.{"0.0001"} },
    .{ .fmt = "%g\\n", .args = &.{"100000"} },
    .{ .fmt = "%G\\n", .args = &.{"0.0000001234"} },
    .{ .fmt = "%.100f\\n", .args = &.{"1.5"} },
    .{ .fmt = "%10.3f\\n", .args = &.{"3.14159"} },
    .{ .fmt = "%-+8.2f|\\n", .args = &.{"3.1"} },
    .{ .fmt = "%f\\n", .args = &.{"-0"} },

    // --- dynamic width/precision '*' (finding) ---
    .{ .fmt = "%*d\\n", .args = &.{ "5", "42" } },
    .{ .fmt = "%.*f\\n", .args = &.{ "2", "3.14159" } },
    .{ .fmt = "%-*d|\\n", .args = &.{ "6", "7" } },

    // --- %c field width (finding) ---
    .{ .fmt = "%5c|\\n", .args = &.{"A"} },

    // --- strings with precision ---
    .{ .fmt = "%-10.5s|\\n", .args = &.{"abcdefgh"} },
    .{ .fmt = "%.3s\\n", .args = &.{"abcdef"} },

    // --- %b backslash escapes ---
    .{ .fmt = "%b\\n", .args = &.{"a\\tb"} },
    .{ .fmt = "%b\\n", .args = &.{"x\\cIGNORED"} }, // \c stops output

    // --- error paths: invalid spec / trailing % (finding: exit 1) ---
    .{ .fmt = "%z\\n" },
    .{ .fmt = "abc%" },
    .{ .fmt = "%d\\n", .args = &.{"abc"} }, // non-numeric -> exit 1, prints 0
};

test "live diff: zprintf byte-for-byte vs GNU coreutils printf" {
    const alloc = testing.allocator;
    const gnu = findGnu() orelse {
        std.debug.print(
            "\n[skip] no GNU coreutils printf found; live-diff anchor skipped " ++
                "(literal anchors still ran). Install coreutils to enable.\n",
            .{},
        );
        return error.SkipZigTest;
    };
    const zbin = build_options.zprintf_bin;

    var failures: usize = 0;
    for (cases) |c| {
        const gcmd = try buildCmd(alloc, gnu, c.fmt, c.args);
        defer alloc.free(gcmd);
        const zcmd = try buildCmd(alloc, zbin, c.fmt, c.args);
        defer alloc.free(zcmd);

        const g = try shell(alloc, gcmd);
        defer alloc.free(g.stdout);
        const z = try shell(alloc, zcmd);
        defer alloc.free(z.stdout);

        const out_ok = std.mem.eql(u8, g.stdout, z.stdout);
        const exit_ok = g.exit_code == z.exit_code;
        if (!out_ok or !exit_ok) {
            failures += 1;
            std.debug.print(
                "\nMISMATCH fmt='{s}' args={any}\n  GNU  (exit {d}): '{s}'\n  ZIG  (exit {d}): '{s}'\n",
                .{ c.fmt, c.args, g.exit_code, g.stdout, z.exit_code, z.stdout },
            );
        }
    }

    if (failures != 0) {
        std.debug.print("\n{d}/{d} live-diff cases diverged from GNU\n", .{ failures, cases.len });
        return error.GnuParityMismatch;
    }
}
