//! Externally-anchored parity tests for zcomm against GNU coreutils `comm`.
//!
//! Two anchor kinds, both external (NOT roundtrip):
//!
//!   1. LITERAL anchors — the expected bytes are the *actual* output of GNU
//!      coreutils `comm` (gcomm) v9.10, captured with `gcomm ... | xxd` and
//!      transcribed here verbatim. These run unconditionally, so the suite is
//!      an external anchor even on a machine with no GNU binary installed.
//!
//!   2. LIVE-DIFF anchors — when a GNU `comm` binary is present, zcomm's stdout
//!      and exit code are diffed byte-for-byte against it over a spread of
//!      inputs/flags. This is the strongest anchor (the reference binary itself)
//!      but is skipped (error.SkipZigTest) when gcomm is absent.
//!
//! The zcomm binary under test is located via the ZCOMM_BIN env var, which
//! build.zig sets to the installed artifact path. Fixtures are written to a
//! per-test temp dir and passed as relative operands with cwd set to that dir.

const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,
};

fn zcommBin(_: std.mem.Allocator) ![]const u8 {
    // Absolute path of the installed zcomm artifact, injected by build.zig.
    if (build_options.zcomm_bin.len == 0) return error.SkipZigTest;
    return build_options.zcomm_bin;
}

fn gcommPath() ?[]const u8 {
    const candidates = [_][]const u8{
        "/opt/homebrew/opt/coreutils/libexec/gnubin/comm",
        "/opt/homebrew/bin/gcomm",
        "/usr/local/opt/coreutils/libexec/gnubin/comm",
        "/usr/local/bin/gcomm",
    };
    for (candidates) |c| {
        std.Io.Dir.accessAbsolute(testing.io, c, .{}) catch continue;
        return c;
    }
    return null;
}

fn run(alloc: std.mem.Allocator, exe: []const u8, extra: []const []const u8, cwd: std.Io.Dir) !RunResult {
    var argv = try alloc.alloc([]const u8, extra.len + 1);
    argv[0] = exe;
    for (extra, 0..) |a, i| argv[i + 1] = a;

    const res = try std.process.run(alloc, testing.io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
    });
    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = res.stdout, .stderr = res.stderr, .code = code };
}

fn printArgs(args: []const []const u8) void {
    for (args) |a| std.debug.print("{s} ", .{a});
    std.debug.print("\n", .{});
}

/// Standard fixtures used across the parity tests.
fn writeFixtures(dir: std.Io.Dir) !void {
    const io = testing.io;
    try dir.writeFile(io, .{ .sub_path = "s1", .data = "apple\nbanana\ncherry\n" });
    try dir.writeFile(io, .{ .sub_path = "s2", .data = "banana\ncherry\ndate\n" });
    try dir.writeFile(io, .{ .sub_path = "nonl", .data = "a\nb\nc" }); // no trailing newline
    try dir.writeFile(io, .{ .sub_path = "e2", .data = "a\nc\n" });
    try dir.writeFile(io, .{ .sub_path = "d1", .data = "c\nb\na\n" }); // reverse sorted
    try dir.writeFile(io, .{ .sub_path = "d2", .data = "a\nb\nc\n" });
    try dir.writeFile(io, .{ .sub_path = "empty", .data = "" });
}

// ---------------------------------------------------------------------------
// LITERAL anchors — expected bytes are gcomm (GNU coreutils) 9.10 output.
// ---------------------------------------------------------------------------

const LiteralCase = struct {
    args: []const []const u8,
    expected_stdout: []const u8,
    expected_code: u8,
};

const literal_cases = [_]LiteralCase{
    // gcomm s1 s2  -> apple in col1, banana/cherry common (col3, two tabs), date col2 (one tab)
    .{ .args = &.{ "s1", "s2" }, .expected_stdout = "apple\n\t\tbanana\n\t\tcherry\n\tdate\n", .expected_code = 0 },
    // gcomm -12 s1 s2 -> only common lines, no delimiters
    .{ .args = &.{ "-12", "s1", "s2" }, .expected_stdout = "banana\ncherry\n", .expected_code = 0 },
    // gcomm -3 s1 s2 -> unique lines only (col1 no delim, col2 one tab)
    .{ .args = &.{ "-3", "s1", "s2" }, .expected_stdout = "apple\n\tdate\n", .expected_code = 0 },
    // gcomm --output-delimiter=:: s1 s2
    .{ .args = &.{ "--output-delimiter=::", "s1", "s2" }, .expected_stdout = "apple\n::::banana\n::::cherry\n::date\n", .expected_code = 0 },
    // gcomm --total s1 s2 -> normal output + "1\t1\t2\ttotal\n"
    .{ .args = &.{ "--total", "s1", "s2" }, .expected_stdout = "apple\n\t\tbanana\n\t\tcherry\n\tdate\n1\t1\t2\ttotal\n", .expected_code = 0 },
    // gcomm -12 --total s1 s2 -> counts unaffected by column suppression
    .{ .args = &.{ "-12", "--total", "s1", "s2" }, .expected_stdout = "banana\ncherry\n1\t1\t2\ttotal\n", .expected_code = 0 },
    // gcomm -z s1 s2 -> whole file is one NUL-terminated "line"; they differ
    .{ .args = &.{ "-z", "s1", "s2" }, .expected_stdout = "apple\nbanana\ncherry\n\x00\tbanana\ncherry\ndate\n\x00", .expected_code = 0 },
    // gcomm empty s2 -> everything is col2 (one leading tab per line)
    .{ .args = &.{ "empty", "s2" }, .expected_stdout = "\tbanana\n\tcherry\n\tdate\n", .expected_code = 0 },
    // gcomm nonl e2 (nonl=a,b,c[no nl]; e2=a,c): a common, b col1, c common
    .{ .args = &.{ "nonl", "e2" }, .expected_stdout = "\t\ta\nb\n\t\tc\n", .expected_code = 0 },
    // --check-order on reverse-sorted d1: emits partial output then exits 1
    .{ .args = &.{ "--check-order", "d1", "d2" }, .expected_stdout = "\ta\n\tb\n\t\tc\n", .expected_code = 1 },
    // default (no flag) disorder is also fatal once an unpairable line is seen
    .{ .args = &.{ "d1", "d2" }, .expected_stdout = "\ta\n\tb\n\t\tc\nb\na\n", .expected_code = 1 },
    // --nocheck-order suppresses the check entirely: exit 0
    .{ .args = &.{ "--nocheck-order", "d1", "d2" }, .expected_stdout = "\ta\n\tb\n\t\tc\nb\na\n", .expected_code = 0 },
};

test "literal GNU comm 9.10 anchors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bin = try zcommBin(alloc);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixtures(tmp.dir);
    const cwd = tmp.dir;

    for (literal_cases) |c| {
        const r = try run(alloc, bin, c.args, cwd);
        testing.expectEqualStrings(c.expected_stdout, r.stdout) catch |e| {
            std.debug.print("literal case failed: args=", .{});
            printArgs(c.args);
            return e;
        };
        testing.expectEqual(c.expected_code, r.code) catch |e| {
            std.debug.print("literal case exit mismatch: got={d} want={d} args=", .{ r.code, c.expected_code });
            printArgs(c.args);
            return e;
        };
    }
}

test "literal: --version and --help go to stdout with exit 0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const bin = try zcommBin(alloc);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = tmp.dir;

    // GNU writes --version / --help to stdout (fd 1), exit 0. The regression
    // this guards: `zcomm --version | grep zcomm` must produce output.
    const ver = try run(alloc, bin, &.{"--version"}, cwd);
    try testing.expectEqual(@as(u8, 0), ver.code);
    try testing.expect(ver.stdout.len > 0);
    try testing.expectEqual(@as(usize, 0), ver.stderr.len);
    try testing.expect(std.mem.indexOf(u8, ver.stdout, "zcomm") != null);

    const help = try run(alloc, bin, &.{"--help"}, cwd);
    try testing.expectEqual(@as(u8, 0), help.code);
    try testing.expect(help.stdout.len > 0);
    try testing.expectEqual(@as(usize, 0), help.stderr.len);
    try testing.expect(std.mem.indexOf(u8, help.stdout, "Usage") != null);
}

test "literal: unknown options and bad operand counts exit 1 (GNU parity)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const bin = try zcommBin(alloc);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixtures(tmp.dir);
    const cwd = tmp.dir;

    // GNU rejects unknown options and bad operand counts with exit 1 and no
    // stdout (the old zcomm silently ignored them and exited 0).
    const bad_long = try run(alloc, bin, &.{ "--bogus", "s1", "s2" }, cwd);
    try testing.expectEqual(@as(u8, 1), bad_long.code);
    try testing.expectEqual(@as(usize, 0), bad_long.stdout.len);

    const bad_short = try run(alloc, bin, &.{ "-x", "s1", "s2" }, cwd);
    try testing.expectEqual(@as(u8, 1), bad_short.code);
    try testing.expectEqual(@as(usize, 0), bad_short.stdout.len);

    const missing = try run(alloc, bin, &.{"s1"}, cwd);
    try testing.expectEqual(@as(u8, 1), missing.code);

    const extra = try run(alloc, bin, &.{ "s1", "s2", "s1" }, cwd);
    try testing.expectEqual(@as(u8, 1), extra.code);
}

test "literal: -- ends option parsing so a file named -1 is an operand" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const bin = try zcommBin(alloc);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "-1", .data = "apple\nbanana\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "s2", .data = "banana\ncherry\n" });
    const cwd = tmp.dir;

    const r = try run(alloc, bin, &.{ "--", "-1", "s2" }, cwd);
    try testing.expectEqual(@as(u8, 0), r.code);
    // apple only in file1, banana common, cherry only in file2
    try testing.expectEqualStrings("apple\n\t\tbanana\n\tcherry\n", r.stdout);
}

// ---------------------------------------------------------------------------
// LIVE-DIFF anchors — diff zcomm against the real GNU binary when available.
// ---------------------------------------------------------------------------

test "live diff against GNU comm binary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const bin = try zcommBin(alloc);
    const gnu = gcommPath() orelse return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixtures(tmp.dir);
    const cwd = tmp.dir;

    const arg_sets = [_][]const []const u8{
        &.{ "s1", "s2" },
        &.{ "-1", "s1", "s2" },
        &.{ "-2", "s1", "s2" },
        &.{ "-3", "s1", "s2" },
        &.{ "-12", "s1", "s2" },
        &.{ "-13", "s1", "s2" },
        &.{ "-23", "s1", "s2" },
        &.{ "-123", "s1", "s2" },
        &.{ "s1", "s1" },
        &.{ "nonl", "e2" },
        &.{ "empty", "s2" },
        &.{ "s1", "empty" },
        &.{ "empty", "empty" },
        &.{ "--output-delimiter=::", "s1", "s2" },
        &.{ "--output-delimiter=", "s1", "s2" },
        &.{ "-z", "s1", "s2" },
        &.{ "--total", "s1", "s2" },
        &.{ "-12", "--total", "s1", "s2" },
        &.{ "-3", "--total", "s1", "s2" },
        &.{ "--total", "-z", "s1", "s2" },
        &.{ "--check-order", "s1", "s2" },
        &.{ "--check-order", "d1", "d2" },
        &.{ "d1", "d2" },
        &.{ "--nocheck-order", "d1", "d2" },
    };

    for (arg_sets) |args| {
        const zc = try run(alloc, bin, args, cwd);
        const gc = try run(alloc, gnu, args, cwd);
        testing.expectEqualSlices(u8, gc.stdout, zc.stdout) catch |e| {
            std.debug.print("stdout diff on args=", .{});
            printArgs(args);
            return e;
        };
        testing.expectEqual(gc.code, zc.code) catch |e| {
            std.debug.print("exit diff zcomm={d} gnu={d} args=", .{ zc.code, gc.code });
            printArgs(args);
            return e;
        };
    }
}
