//! GNU parity tests for ztail.
//!
//! EXTERNALLY ANCHORED per zig-forge/CLAUDE.md golden rule #1: the expected
//! output is NOT written by us — it is produced by the *real* GNU `tail`
//! binary (gtail / coreutils gnubin `tail`, GNU coreutils 9.x) run on the
//! identical fixture. Each test builds a fixture directory, runs the
//! freshly-built `ztail` on it, runs GNU `tail` on the same fixture, and
//! asserts that stdout, stderr and the exit code match byte-for-byte after
//! normalizing only the program name (each binary's own argv[0] path and
//! basename -> PROG; see `normalize`). These are true differential tests
//! against an implementation ztail's author did not write — not roundtrips.
//!
//! If GNU tail is not installed the whole suite skips (error.SkipZigTest) so
//! CI on a machine without coreutils stays green rather than silently vacuous.
//!
//! The ztail binary path is injected by build.zig via `build_options`.

const std = @import("std");
const build_options = @import("build_options");

const Io = std.Io;
const Dir = Io.Dir;
const Term = std.process.Child.Term;

var counter: u64 = 0;

/// Candidate locations for the GNU tail binary, in preference order. The
/// gnubin path's basename is `tail`; the homebrew keg is `gtail`.
const gtail_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/tail",
    "/opt/homebrew/bin/gtail",
    "/usr/local/opt/coreutils/libexec/gnubin/tail",
    "/usr/local/bin/gtail",
    "/usr/bin/gtail",
};

fn findGtail(io: Io) ?[]const u8 {
    for (gtail_candidates) |cand| {
        Dir.cwd().access(io, cand, .{}) catch continue;
        return cand;
    }
    return null;
}

/// One fixture entry: a regular file (content != null) or a directory (null).
const FileSpec = struct {
    path: []const u8,
    content: ?[]const u8,
};

fn buildFixture(io: Io, root: []const u8, specs: []const FileSpec) !void {
    try Dir.cwd().createDirPath(io, root);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for (specs) |spec| {
        const p = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, spec.path });
        if (spec.content) |content| {
            var file = try Dir.cwd().createFile(io, p, .{});
            defer file.close(io);
            try file.writeStreamingAll(io, content);
        } else {
            try Dir.cwd().createDirPath(io, p);
        }
    }
}

fn exitCode(t: Term) i64 {
    return switch (t) {
        .exited => |c| c,
        .signal => |s| -@as(i64, @intFromEnum(s)),
        else => -9999,
    };
}

/// Normalize the program name to "PROG" so the two runs' diagnostics compare.
/// Replace the full invoked path first, then the basename ("tail" / "gtail" /
/// "ztail"). Fixture roots and operand names deliberately avoid the substrings
/// "tail"/"gtail"/"ztail" so operand paths in messages are never touched.
fn normalize(alloc: std.mem.Allocator, text: []const u8, exe_path: []const u8) ![]u8 {
    const base = std.fs.path.basename(exe_path);
    const t1 = try std.mem.replaceOwned(u8, alloc, text, exe_path, "PROG");
    defer alloc.free(t1);
    return std.mem.replaceOwned(u8, alloc, t1, base, "PROG");
}

const RunOut = struct {
    stdout: []u8,
    stderr: []u8,
    code: i64,
};

fn runOne(
    alloc: std.mem.Allocator,
    io: Io,
    exe: []const u8,
    tail: []const []const u8,
) !RunOut {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, exe);
    for (tail) |a| try argv.append(alloc, a);

    const r = try std.process.run(alloc, io, .{ .argv = argv.items });
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);

    return .{
        .stdout = try normalize(alloc, r.stdout, exe),
        .stderr = try normalize(alloc, r.stderr, exe),
        .code = exitCode(r.term),
    };
}

/// Run `exe` with its stdin redirected from `stdin_file`, via `/bin/sh -c`.
/// `std.process.run` ignores stdin, so a shell redirect is the portable way to
/// feed the "-"/stdin code path. Paths are test-controlled (temp dir, no
/// spaces) so the single-quoted interpolation is safe here.
fn runStdin(
    alloc: std.mem.Allocator,
    io: Io,
    exe: []const u8,
    flags: []const []const u8,
    stdin_file: []const u8,
) !RunOut {
    var cmd: std.ArrayListUnmanaged(u8) = .empty;
    defer cmd.deinit(alloc);
    try cmd.appendSlice(alloc, "exec '");
    try cmd.appendSlice(alloc, exe);
    try cmd.append(alloc, '\'');
    for (flags) |f| {
        try cmd.append(alloc, ' ');
        try cmd.appendSlice(alloc, f);
    }
    try cmd.appendSlice(alloc, " < '");
    try cmd.appendSlice(alloc, stdin_file);
    try cmd.append(alloc, '\'');

    const argv = [_][]const u8{ "/bin/sh", "-c", cmd.items };
    const r = try std.process.run(alloc, io, .{ .argv = &argv });
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);

    return .{
        .stdout = try normalize(alloc, r.stdout, exe),
        .stderr = try normalize(alloc, r.stderr, exe),
        .code = exitCode(r.term),
    };
}

fn tmpRoot(buf: []u8) ![]const u8 {
    const tmp_base: []const u8 = if (std.c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
    counter += 1;
    const pid: u64 = @intCast(std.c.getpid());
    const seed: u64 = (pid << 20) ^ (counter *% 0x9E3779B97F4A7C15);
    const base = std.mem.trimEnd(u8, tmp_base, "/");
    // Root name avoids the substrings "tail"/"gtail"/"ztail".
    return std.fmt.bufPrint(buf, "{s}/tlpar_{x}", .{ base, seed });
}

fn threadedIo(alloc: std.mem.Allocator) Io.Threaded {
    return Io.Threaded.init(alloc, .{});
}

fn compare(g: RunOut, z: RunOut) !void {
    std.testing.expectEqualStrings(g.stdout, z.stdout) catch |e| {
        std.debug.print("STDOUT mismatch (expected=GNU tail, actual=ztail)\n", .{});
        return e;
    };
    std.testing.expectEqualStrings(g.stderr, z.stderr) catch |e| {
        std.debug.print("STDERR mismatch (expected=GNU tail, actual=ztail)\n", .{});
        return e;
    };
    std.testing.expectEqual(g.code, z.code) catch |e| {
        std.debug.print("EXIT mismatch: gtail={d} ztail={d}\n", .{ g.code, z.code });
        return e;
    };
}

/// Core file-mode comparison: create the fixture, run ztail and GNU tail with
/// `flags` followed by `operands` (joined onto the temp root), assert parity.
fn runParity(
    specs: []const FileSpec,
    flags: []const []const u8,
    operands: []const []const u8,
) !void {
    const alloc = std.testing.allocator;
    var threaded = threadedIo(alloc);
    defer threaded.deinit();
    const io = threaded.io();

    const gtail = findGtail(io) orelse return error.SkipZigTest;
    const ztail = build_options.ztail_exe;

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&root_buf);
    defer Dir.cwd().deleteTree(io, root) catch {};

    try buildFixture(io, root, specs);

    // Build shared argv tail: flags, then root-joined operands.
    var tail: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (tail.items[flags.len..]) |o| alloc.free(o);
        tail.deinit(alloc);
    }
    for (flags) |f| try tail.append(alloc, f);
    for (operands) |op| {
        const s = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, op });
        try tail.append(alloc, s);
    }

    const z = try runOne(alloc, io, ztail, tail.items);
    defer alloc.free(z.stdout);
    defer alloc.free(z.stderr);
    const g = try runOne(alloc, io, gtail, tail.items);
    defer alloc.free(g.stdout);
    defer alloc.free(g.stderr);

    try compare(g, z);
}

/// stdin-mode comparison: feed `content` to both binaries' stdin.
fn runStdinParity(
    flags: []const []const u8,
    content: []const u8,
) !void {
    const alloc = std.testing.allocator;
    var threaded = threadedIo(alloc);
    defer threaded.deinit();
    const io = threaded.io();

    const gtail = findGtail(io) orelse return error.SkipZigTest;
    const ztail = build_options.ztail_exe;

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&root_buf);
    defer Dir.cwd().deleteTree(io, root) catch {};

    try buildFixture(io, root, &.{.{ .path = "in", .content = content }});

    var in_buf: [std.fs.max_path_bytes]u8 = undefined;
    const in_path = try std.fmt.bufPrint(&in_buf, "{s}/in", .{root});

    const z = try runStdin(alloc, io, ztail, flags, in_path);
    defer alloc.free(z.stdout);
    defer alloc.free(z.stderr);
    const g = try runStdin(alloc, io, gtail, flags, in_path);
    defer alloc.free(g.stdout);
    defer alloc.free(g.stderr);

    try compare(g, z);
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const lines20 =
    "line01\nline02\nline03\nline04\nline05\nline06\nline07\nline08\nline09\nline10\n" ++
    "line11\nline12\nline13\nline14\nline15\nline16\nline17\nline18\nline19\nline20\n";
const lines3 = "aaa\nbbb\nccc\n";
const no_newline = "xxx\nyyy\nzzz";
const bytes_fix = "0123456789ABCDEF";

fn f20() []const FileSpec {
    return &.{.{ .path = "f20", .content = lines20 }};
}

// ---------------------------------------------------------------------------
// Line selection
// ---------------------------------------------------------------------------

test "default: last 10 lines" {
    try runParity(f20(), &.{}, &.{"f20"});
}

test "-n 3: last 3 lines" {
    try runParity(f20(), &.{ "-n", "3" }, &.{"f20"});
}

test "-n0: zero lines (empty output)" {
    try runParity(f20(), &.{"-n0"}, &.{"f20"});
}

test "-n +5: from line 5 to end" {
    try runParity(f20(), &.{ "-n", "+5" }, &.{"f20"});
}

test "--lines=2" {
    try runParity(f20(), &.{"--lines=2"}, &.{"f20"});
}

test "-n larger than file: whole file" {
    try runParity(&.{.{ .path = "f3", .content = lines3 }}, &.{ "-n", "100" }, &.{"f3"});
}

test "no trailing newline, -n 2" {
    try runParity(&.{.{ .path = "fno", .content = no_newline }}, &.{ "-n", "2" }, &.{"fno"});
}

test "empty file, -n 5" {
    try runParity(&.{.{ .path = "fe", .content = "" }}, &.{ "-n", "5" }, &.{"fe"});
}

// ---------------------------------------------------------------------------
// Byte selection
// ---------------------------------------------------------------------------

test "-c 5: last 5 bytes" {
    try runParity(&.{.{ .path = "fb", .content = bytes_fix }}, &.{ "-c", "5" }, &.{"fb"});
}

test "-c +3: from byte 3" {
    try runParity(&.{.{ .path = "fb", .content = bytes_fix }}, &.{ "-c", "+3" }, &.{"fb"});
}

test "-c larger than file: whole file" {
    try runParity(&.{.{ .path = "fb", .content = bytes_fix }}, &.{ "-c", "9999" }, &.{"fb"});
}

// ---------------------------------------------------------------------------
// Numeric-argument validation (the audit's core high/medium findings)
// ---------------------------------------------------------------------------

test "-n abc: invalid number of lines, exit 1" {
    try runParity(f20(), &.{ "-n", "abc" }, &.{"f20"});
}

test "-n empty: invalid number of lines, exit 1" {
    try runParity(f20(), &.{ "-n", "" }, &.{"f20"});
}

test "--lines=abc: invalid number of lines, exit 1" {
    try runParity(f20(), &.{"--lines=abc"}, &.{"f20"});
}

test "-c abc: invalid number of bytes, exit 1" {
    try runParity(f20(), &.{ "-c", "abc" }, &.{"f20"});
}

test "-n huge (overflow): GNU clamps and prints all, exit 0" {
    // 26 nines overflows u64. GNU does NOT error here — it clamps to the max
    // and prints the whole file. This anchors the overflow-clamp fix.
    try runParity(f20(), &.{ "-n", "99999999999999999999999999" }, &.{"f20"});
}

test "-c huge (overflow): GNU clamps and prints all, exit 0" {
    try runParity(&.{.{ .path = "fb", .content = bytes_fix }}, &.{ "-c", "99999999999999999999999999" }, &.{"fb"});
}

test "--pid abc: invalid PID, exit 1" {
    try runParity(f20(), &.{ "--pid=abc", "-n1" }, &.{"f20"});
}

test "--pid overflow: Value too large, exit 1" {
    try runParity(f20(), &.{ "--pid=99999999999999999", "-n1" }, &.{"f20"});
}

test "--pid negative: invalid PID, exit 1" {
    try runParity(f20(), &.{ "--pid=-5", "-n1" }, &.{"f20"});
}

test "-s negative: invalid number of seconds, exit 1" {
    try runParity(f20(), &.{ "-s", "-1", "-n1" }, &.{"f20"});
}

test "-s empty: invalid number of seconds, exit 1" {
    try runParity(f20(), &.{ "-s", "", "-n1" }, &.{"f20"});
}

// ---------------------------------------------------------------------------
// File-open / directory / header handling
// ---------------------------------------------------------------------------

test "missing file: real errno message, exit 1" {
    try runParity(&.{}, &.{}, &.{"nope"});
}

test "directory operand: Is a directory, exit 1" {
    try runParity(&.{.{ .path = "d", .content = null }}, &.{}, &.{"d"});
}

test "multi-file: header only for openable files" {
    // nope missing (no header), d20 present (header). GNU suppresses the header
    // for the file it cannot open; ztail must too.
    try runParity(f20(), &.{}, &.{ "nope", "f20" });
}

test "multi-file: two files, headers + blank separator" {
    try runParity(
        &.{ .{ .path = "f20", .content = lines20 }, .{ .path = "f3", .content = lines3 } },
        &.{"-n2"},
        &.{ "f20", "f3" },
    );
}

test "multi-file mixed: missing + directory + file" {
    try runParity(
        &.{ .{ .path = "d", .content = null }, .{ .path = "f3", .content = lines3 } },
        &.{},
        &.{ "nope", "d", "f3" },
    );
}

test "-q suppresses headers for multiple files" {
    try runParity(
        &.{ .{ .path = "f20", .content = lines20 }, .{ .path = "f3", .content = lines3 } },
        &.{ "-q", "-n2" },
        &.{ "f20", "f3" },
    );
}

test "-v forces header for single file" {
    try runParity(f20(), &.{ "-v", "-n2" }, &.{"f20"});
}

// ---------------------------------------------------------------------------
// stdin ("-") path
// ---------------------------------------------------------------------------

test "stdin: last 2 lines" {
    try runStdinParity(&.{ "-n", "2" }, lines20);
}

test "stdin: last 4 bytes" {
    try runStdinParity(&.{ "-c", "4" }, bytes_fix);
}

test "stdin: -v prints 'standard input' header" {
    try runStdinParity(&.{ "-v", "-n2" }, lines3);
}
