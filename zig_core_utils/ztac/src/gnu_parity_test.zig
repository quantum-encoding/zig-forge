//! Externally-anchored parity tests for ztac.
//!
//! These are NOT roundtrip tests. Each case runs BOTH our `ztac` binary and the
//! real GNU coreutils `tac` binary (installed as `gtac` on macOS, coreutils
//! 9.10) over identical inputs and asserts byte-identical stdout AND identical
//! exit status. GNU tac is the external oracle — the anchor is a different
//! implementation's observed behavior, per zig-forge/CLAUDE.md's golden rule.
//!
//! The ztac binary path comes from the ZTAC_BIN env var, set by build.zig's test
//! step (which also depends on the install step so the binary exists first).
//! If no GNU tac binary is found on the system the tests SkipZigTest rather than
//! asserting against self-produced output.
//!
//! Verified against: tac (GNU coreutils) 9.10.

const std = @import("std");
const libc = std.c;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

const gtac_candidates = [_][*:0]const u8{
    "/opt/homebrew/bin/gtac",
    "/opt/homebrew/opt/coreutils/libexec/gnubin/tac",
    "/usr/local/bin/gtac",
    "/usr/bin/tac",
};

fn findGtac() ?[]const u8 {
    for (gtac_candidates) |c| {
        if (libc.access(c, 0) == 0) return std.mem.span(c);
    }
    return null;
}

fn ztacPath() ?[]const u8 {
    const p = getenv("ZTAC_BIN") orelse return null;
    return std.mem.span(p);
}

/// Write `data` to `path` using libc (avoids the Io file API entirely).
fn writeTmp(path: [*:0]const u8, data: []const u8) !void {
    const fd = libc.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(libc.mode_t, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = libc.close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const n = libc.write(fd, data.ptr + off, data.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

const Outcome = struct {
    stdout: []u8,
    code: u8,
};

fn runExe(
    gpa: std.mem.Allocator,
    io: std.Io,
    exe: []const u8,
    flags: []const []const u8,
    file_arg: ?[]const u8,
) !Outcome {
    var argv = std.ArrayListUnmanaged([]const u8).empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, exe);
    for (flags) |f| try argv.append(gpa, f);
    if (file_arg) |fa| try argv.append(gpa, fa);

    const res = try std.process.run(gpa, io, .{ .argv = argv.items });
    gpa.free(res.stderr);
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = res.stdout, .code = code };
}

fn printHex(label: []const u8, bytes: []const u8) void {
    std.debug.print("{s} ({d}B):", .{ label, bytes.len });
    for (bytes) |b| std.debug.print(" {x:0>2}", .{b});
    std.debug.print("\n", .{});
}

const Case = struct {
    name: []const u8,
    flags: []const []const u8,
    input: []const u8,
};

// Representative inputs × flag combinations. Every one is checked against GNU.
const cases = [_]Case{
    // default separator (newline), "after" mode
    .{ .name = "trailing-nl", .flags = &.{}, .input = "a\nb\nc\n" },
    .{ .name = "no-trailing-nl", .flags = &.{}, .input = "a\nb\nc" },
    .{ .name = "single-no-nl", .flags = &.{}, .input = "abc" },
    .{ .name = "empty", .flags = &.{}, .input = "" },
    .{ .name = "only-nl", .flags = &.{}, .input = "\n" },
    .{ .name = "blank-lines", .flags = &.{}, .input = "a\n\nb\n" },
    .{ .name = "many-lines", .flags = &.{}, .input = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n" },
    .{ .name = "crlf", .flags = &.{}, .input = "a\r\nb\r\nc\r\n" },
    .{ .name = "leading-blanks", .flags = &.{}, .input = "\n\n\nx\n" },
    // -b / --before
    .{ .name = "before-trailing-nl", .flags = &.{"-b"}, .input = "a\nb\nc\n" },
    .{ .name = "before-no-trailing-nl", .flags = &.{"-b"}, .input = "a\nb\nc" },
    .{ .name = "before-long", .flags = &.{"--before"}, .input = "one\ntwo\nthree\n" },
    // -s SEP (custom literal separator)
    .{ .name = "sep-comma-trailing", .flags = &.{ "-s", "," }, .input = "a,b,c," },
    .{ .name = "sep-comma-no-trailing", .flags = &.{ "-s", "," }, .input = "a,b,c" },
    .{ .name = "sep-attached", .flags = &.{"-s,"}, .input = "a,b,c" },
    .{ .name = "sep-eq-form", .flags = &.{"--separator=:"}, .input = "a:b:c:" },
    .{ .name = "sep-multichar", .flags = &.{ "-s", "::" }, .input = "a::b::c::" },
    .{ .name = "sep-multichar-no-trail", .flags = &.{ "-s", "::" }, .input = "a::b::c" },
    // -b combined with -s
    .{ .name = "before-sep", .flags = &.{ "-b", "-s", "," }, .input = "a,b,c" },
    .{ .name = "before-sep-cluster", .flags = &.{"-bs,"}, .input = "a,b,c" },
    // -r regex separator.
    // NOTE: only FIXED-LENGTH patterns are anchored here. GNU tac searches for
    // the regex separator BACKWARD from end-of-buffer, which yields quirky
    // per-position matches for variable-length quantifiers (`a+` splits every
    // `a`, not the greedy run). ztac uses a straightforward forward-greedy
    // match, so it matches GNU exactly for fixed-length separators (literal
    // strings, single character classes, `.` wildcards) but intentionally
    // diverges on quantifier patterns. See remaining[] in the audit result.
    .{ .name = "regex-digit-class", .flags = &.{ "-r", "-s", "[0-9]" }, .input = "a1b22c3" },
    .{ .name = "regex-fixed-str", .flags = &.{ "-r", "-s", "ab" }, .input = "xabyabz" },
    .{ .name = "regex-wildcard", .flags = &.{ "-r", "-s", "a.c" }, .input = "zabcxadcy" },
    .{ .name = "regex-two-digit", .flags = &.{ "-r", "-s", "[0-9][0-9]" }, .input = "a1b22c" },
    .{ .name = "regex-before", .flags = &.{ "-r", "-b", "-s", "[0-9]" }, .input = "a1b2c3" },
    // separator not present at all
    .{ .name = "sep-absent", .flags = &.{ "-s", "," }, .input = "no separators here\n" },
};

fn compareCase(gpa: std.mem.Allocator, io: std.Io, ztac: []const u8, gtac: []const u8, case: Case, tmp: [*:0]const u8, tmp_slice: []const u8) !void {
    try writeTmp(tmp, case.input);

    const mine = try runExe(gpa, io, ztac, case.flags, tmp_slice);
    defer gpa.free(mine.stdout);
    const theirs = try runExe(gpa, io, gtac, case.flags, tmp_slice);
    defer gpa.free(theirs.stdout);

    if (!std.mem.eql(u8, mine.stdout, theirs.stdout) or mine.code != theirs.code) {
        std.debug.print("\nPARITY MISMATCH case '{s}' code(ztac={d} gtac={d})\n", .{ case.name, mine.code, theirs.code });
        printHex("  ztac out", mine.stdout);
        printHex("  gtac out", theirs.stdout);
        return error.ParityMismatch;
    }
}

test "ztac matches GNU tac across inputs and flags" {
    const gpa = std.testing.allocator;
    const ztac = ztacPath() orelse return error.SkipZigTest;
    const gtac = findGtac() orelse return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const tmp: [*:0]const u8 = "/tmp/ztac_parity_input.txt";
    const tmp_slice: []const u8 = std.mem.span(tmp);
    defer _ = libc.unlink(tmp);

    for (cases) |case| {
        try compareCase(gpa, io, ztac, gtac, case, tmp, tmp_slice);
    }
}

test "ztac matches GNU tac exit status on error inputs" {
    const gpa = std.testing.allocator;
    const ztac = ztacPath() orelse return error.SkipZigTest;
    const gtac = findGtac() orelse return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Nonexistent file: GNU tac -> empty stdout, exit 1.
    {
        const mine = try runExe(gpa, io, ztac, &.{}, "/nonexistent-ztac-xyz-12345");
        defer gpa.free(mine.stdout);
        const theirs = try runExe(gpa, io, gtac, &.{}, "/nonexistent-ztac-xyz-12345");
        defer gpa.free(theirs.stdout);
        try std.testing.expectEqual(theirs.code, mine.code);
        try std.testing.expect(mine.code == 1);
        try std.testing.expectEqualSlices(u8, theirs.stdout, mine.stdout);
    }

    // Directory argument: GNU tac -> read error, empty stdout, exit 1.
    {
        const mine = try runExe(gpa, io, ztac, &.{}, "/tmp");
        defer gpa.free(mine.stdout);
        const theirs = try runExe(gpa, io, gtac, &.{}, "/tmp");
        defer gpa.free(theirs.stdout);
        try std.testing.expectEqual(theirs.code, mine.code);
        try std.testing.expect(mine.code == 1);
        try std.testing.expectEqualSlices(u8, theirs.stdout, mine.stdout);
    }
}
