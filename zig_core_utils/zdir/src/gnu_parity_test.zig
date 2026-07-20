//! Externally-anchored GNU-parity tests for zdir.
//!
//! The anchor is the REAL GNU `dir` binary from Homebrew coreutils
//! (/opt/homebrew/opt/coreutils/libexec/gnubin/dir -> gdir, coreutils 9.10).
//! Each test runs the *same* argv against both zdir and GNU `dir`, under an
//! identical `LC_ALL=C` environment (so collation is plain byte order, which
//! zdir sorts by), inside the same fixture directory, and asserts byte-exact
//! stdout / matching exit status. Neither the inputs nor the expected outputs
//! are authored here — the expected output IS whatever GNU emits. Nothing is a
//! roundtrip; every assertion is against an independent implementation.
//!
//! GNU `dir` == `ls -C -b`: it C-escapes special bytes in names by default
//! (space -> "\ ", TAB -> "\t", 0x01 -> "\001", backslash -> "\\"), even when
//! stdout is not a terminal. The fixtures below deliberately include such
//! names so the escape logic is checked against GNU, not against ourselves.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;
const Dir = Io.Dir;

const gdir_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/dir",
    "/opt/homebrew/bin/gdir",
    "/usr/bin/dir",
    "/bin/dir",
};

fn findGdir(io: Io) ?[]const u8 {
    for (gdir_candidates) |c| {
        _ = Dir.statFile(Dir.cwd(), io, c, .{}) catch continue;
        return c;
    }
    return null;
}

var fixture_counter: u32 = 0;

const RunOut = struct {
    exit: u8,
    stdout: []u8,
    stderr: []u8,
    fn deinit(self: RunOut, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

fn runTool(
    gpa: std.mem.Allocator,
    io: Io,
    exe: []const u8,
    tail: []const []const u8,
    cwd_path: []const u8,
) !RunOut {
    var argv = std.ArrayListUnmanaged([]const u8).empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, exe);
    try argv.appendSlice(gpa, tail);

    // Force the C locale so GNU sorts by raw byte order (matching zdir).
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("LC_ALL", "C");
    try env.put("LANG", "C");

    const res = try std.process.run(gpa, io, .{
        .argv = argv.items,
        .cwd = .{ .path = cwd_path },
        .environ_map = &env,
    });
    const exit: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .exit = exit, .stdout = res.stdout, .stderr = res.stderr };
}

/// Build a throwaway fixture directory and return its absolute path (caller frees).
fn makeFixture(gpa: std.mem.Allocator, io: Io) ![]u8 {
    fixture_counter += 1;
    const path = try std.fmt.allocPrint(gpa, "/tmp/zdir_parity_fixture_{d}", .{fixture_counter});
    errdefer gpa.free(path);

    Dir.deleteTree(Dir.cwd(), io, path) catch {};
    try Dir.createDirPath(Dir.cwd(), io, path);
    var dir = try Dir.openDir(Dir.cwd(), io, path, .{});
    defer dir.close(io);

    // Regular files, including special-character names to exercise escaping.
    const files = [_][]const u8{
        "afile",
        "bfile",
        "name with space",
        "tab\tname",
        ".hidden",
        "Zcap", // uppercase, sorts before lowercase under C locale
    };
    for (files) |f| {
        const file = try dir.createFile(io, f, .{});
        file.close(io);
    }
    try dir.createDirPath(io, "subdir");
    try dir.createDirPath(io, "adir");
    return path;
}

fn removeFixture(gpa: std.mem.Allocator, io: Io, path: []const u8) void {
    Dir.deleteTree(Dir.cwd(), io, path) catch {};
    gpa.free(path);
}

/// Assert byte-exact stdout parity and matching exit code between zdir and GNU dir.
fn expectStdoutParity(
    gpa: std.mem.Allocator,
    io: Io,
    gdir: []const u8,
    tail: []const []const u8,
    cwd_path: []const u8,
) !void {
    const z = try runTool(gpa, io, build_options.zdir_exe, tail, cwd_path);
    defer z.deinit(gpa);
    const g = try runTool(gpa, io, gdir, tail, cwd_path);
    defer g.deinit(gpa);

    if (!std.mem.eql(u8, z.stdout, g.stdout) or z.exit != g.exit) {
        std.debug.print("PARITY MISMATCH for args:", .{});
        for (tail) |t| std.debug.print(" '{s}'", .{t});
        std.debug.print(
            \\
            \\  zdir exit={d} stdout={s}
            \\  gdir exit={d} stdout={s}
            \\
        , .{ z.exit, z.stdout, g.exit, g.stdout });
        return error.ParityMismatch;
    }
}

test "byte-exact stdout parity vs GNU dir across representative inputs" {
    const gpa = std.testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gdir = findGdir(io) orelse return error.SkipZigTest;
    const fx = try makeFixture(gpa, io);
    defer removeFixture(gpa, io, fx);

    // One-per-line mode: fully deterministic, escape-sensitive, sort-sensitive.
    try expectStdoutParity(gpa, io, gdir, &.{"-1"}, fx); // default operand "."
    try expectStdoutParity(gpa, io, gdir, &.{ "-1", "." }, fx);
    try expectStdoutParity(gpa, io, gdir, &.{ "-1", "-a", "." }, fx); // includes . and ..
    try expectStdoutParity(gpa, io, gdir, &.{ "-1", "-A", "." }, fx); // hidden but no . / ..
    try expectStdoutParity(gpa, io, gdir, &.{ "-1", "--all", "." }, fx);
    try expectStdoutParity(gpa, io, gdir, &.{ "-1", "--almost-all", "." }, fx);
}

test "combined short-flag cluster -1a matches GNU" {
    const gpa = std.testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gdir = findGdir(io) orelse return error.SkipZigTest;
    const fx = try makeFixture(gpa, io);
    defer removeFixture(gpa, io, fx);
    try expectStdoutParity(gpa, io, gdir, &.{ "-1a", "." }, fx);
    try expectStdoutParity(gpa, io, gdir, &.{ "-a1", "." }, fx);
}

test "non-directory (file) operand is listed by name, not rejected" {
    const gpa = std.testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gdir = findGdir(io) orelse return error.SkipZigTest;
    const fx = try makeFixture(gpa, io);
    defer removeFixture(gpa, io, fx);

    // GNU prints the (escaped) operand name and exits 0.
    try expectStdoutParity(gpa, io, gdir, &.{ "-1", "name with space" }, fx);
    try expectStdoutParity(gpa, io, gdir, &.{ "-1", "afile" }, fx);
    // Mixed file + dir operands: file first, then "dir:" header block.
    try expectStdoutParity(gpa, io, gdir, &.{ "-1", "afile", "subdir" }, fx);
    // Two directory operands, headers, sorted.
    try expectStdoutParity(gpa, io, gdir, &.{ "-1", "subdir", "adir" }, fx);
}

test "cannot-access operand: exit 2 and strerror-style diagnostic (anchored to GNU)" {
    const gpa = std.testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gdir = findGdir(io) orelse return error.SkipZigTest;
    const fx = try makeFixture(gpa, io);
    defer removeFixture(gpa, io, fx);

    const z = try runTool(gpa, io, build_options.zdir_exe, &.{"no_such_entry_xyz"}, fx);
    defer z.deinit(gpa);
    const g = try runTool(gpa, io, gdir, &.{"no_such_entry_xyz"}, fx);
    defer g.deinit(gpa);

    // GNU exit code for a cannot-access command-line operand is 2.
    try std.testing.expectEqual(@as(u8, 2), g.exit);
    try std.testing.expectEqual(g.exit, z.exit);
    // Both use strerror text "No such file or directory" (program-name prefix
    // differs, so we anchor on the reason string GNU emits).
    try std.testing.expect(std.mem.indexOf(u8, g.stderr, "No such file or directory") != null);
    try std.testing.expect(std.mem.indexOf(u8, z.stderr, "No such file or directory") != null);
    // Nothing on stdout for a single bad operand.
    try std.testing.expectEqualStrings("", z.stdout);
}

test "unknown option: exit 2 with a diagnostic (anchored to GNU)" {
    const gpa = std.testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gdir = findGdir(io) orelse return error.SkipZigTest;
    const fx = try makeFixture(gpa, io);
    defer removeFixture(gpa, io, fx);

    // Long option GNU also rejects.
    {
        const z = try runTool(gpa, io, build_options.zdir_exe, &.{"--frobnicate"}, fx);
        defer z.deinit(gpa);
        const g = try runTool(gpa, io, gdir, &.{"--frobnicate"}, fx);
        defer g.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 2), g.exit);
        try std.testing.expectEqual(g.exit, z.exit);
        try std.testing.expect(z.stderr.len > 0);
        try std.testing.expectEqualStrings("", z.stdout);
    }
    // Short option GNU also rejects ('%' is not a GNU dir option).
    {
        const z = try runTool(gpa, io, build_options.zdir_exe, &.{"-%"}, fx);
        defer z.deinit(gpa);
        const g = try runTool(gpa, io, gdir, &.{"-%"}, fx);
        defer g.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 2), g.exit);
        try std.testing.expectEqual(g.exit, z.exit);
        try std.testing.expect(z.stderr.len > 0);
    }
}

test "-- ends option processing (anchored to GNU)" {
    const gpa = std.testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gdir = findGdir(io) orelse return error.SkipZigTest;
    const fx = try makeFixture(gpa, io);
    defer removeFixture(gpa, io, fx);
    // After "--", "afile" is an operand even though nothing here looks like a flag.
    try expectStdoutParity(gpa, io, gdir, &.{ "-1", "--", "afile" }, fx);
}
