//! GNU parity tests for zlink.
//!
//! External anchor: every case is diffed live against the real GNU
//! coreutils `link` binary (Homebrew gnubin), run in an identical
//! fixture directory: exit code, stdout, stderr (program-name
//! normalized), and resulting filesystem state must all match.
//!
//! A second set of literal tests pins the exact diagnostic bytes
//! observed from GNU coreutils 9.10 `link` (LC_ALL=C, macOS,
//! 2026-07-19) so the suite still verifies GNU-documented behavior
//! byte-for-byte on machines without the GNU binary. These are NOT
//! roundtrip tests — expected outputs were captured from the GNU
//! binary, not derived from zlink.

const std = @import("std");
const build_options = @import("build_options");
const testing = std.testing;
const io = testing.io;
const Io = std.Io;

const zlink_bin = build_options.zlink_bin;

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/link",
    "/usr/local/opt/coreutils/libexec/gnubin/link",
    "/opt/homebrew/bin/glink",
    "/usr/local/bin/glink",
};

fn findGnuLink() ?[]const u8 {
    for (gnu_candidates) |candidate| {
        Io.Dir.accessAbsolute(io, candidate, .{}) catch continue;
        return candidate;
    }
    return null;
}

const RunOutcome = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *RunOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Run `bin` with `args` inside `cwd`, LC_ALL=C, capturing everything.
fn runTool(
    allocator: std.mem.Allocator,
    bin: []const u8,
    args: []const []const u8,
    cwd: Io.Dir,
) !RunOutcome {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, bin);
    try argv.appendSlice(allocator, args);

    // C locale so GNU quoting is ASCII '...' regardless of host locale.
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("LC_ALL", "C");

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .dir = cwd },
        .environ_map = &env,
    });
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
            return error.ChildCrashed;
        },
    };
    return .{ .code = code, .stdout = result.stdout, .stderr = result.stderr };
}

/// GNU prints its own name from argv[0] ("link:" in error() lines, the
/// full binary path in Try/usage lines); zlink hardcodes "zlink".
/// Normalize both to the token "link" so the bytes can be compared.
fn normalize(allocator: std.mem.Allocator, output: []const u8, prog_token: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, output, prog_token, "link");
}

const Fixture = *const fn (dir: Io.Dir) anyerror!void;
const Check = *const fn (dir: Io.Dir) anyerror!void;

/// Core harness: identical fixtures in two temp dirs, run GNU link in
/// one and zlink in the other, require identical exit code + normalized
/// stdout/stderr + identical post-state.
fn diffAgainstGnu(args: []const []const u8, setup: ?Fixture, check: ?Check) !void {
    const gnu = findGnuLink() orelse return error.SkipZigTest;
    const allocator = testing.allocator;

    var tmp_gnu = testing.tmpDir(.{});
    defer tmp_gnu.cleanup();
    var tmp_z = testing.tmpDir(.{});
    defer tmp_z.cleanup();

    if (setup) |s| {
        try s(tmp_gnu.dir);
        try s(tmp_z.dir);
    }

    var res_gnu = try runTool(allocator, gnu, args, tmp_gnu.dir);
    defer res_gnu.deinit(allocator);
    var res_z = try runTool(allocator, zlink_bin, args, tmp_z.dir);
    defer res_z.deinit(allocator);

    const gnu_stderr = try normalize(allocator, res_gnu.stderr, gnu);
    defer allocator.free(gnu_stderr);
    const gnu_stdout = try normalize(allocator, res_gnu.stdout, gnu);
    defer allocator.free(gnu_stdout);
    const z_stderr = try normalize(allocator, res_z.stderr, "zlink");
    defer allocator.free(z_stderr);
    const z_stdout = try normalize(allocator, res_z.stdout, "zlink");
    defer allocator.free(z_stdout);

    try testing.expectEqualStrings(gnu_stderr, z_stderr);
    try testing.expectEqualStrings(gnu_stdout, z_stdout);
    try testing.expectEqual(res_gnu.code, res_z.code);

    if (check) |c| {
        try c(tmp_gnu.dir);
        try c(tmp_z.dir);
    }
}

// ---- fixtures ----

fn fixtureFileA(dir: Io.Dir) anyerror!void {
    try dir.writeFile(io, .{ .sub_path = "a", .data = "alpha\n" });
}

fn fixtureFileAAndB(dir: Io.Dir) anyerror!void {
    try dir.writeFile(io, .{ .sub_path = "a", .data = "alpha\n" });
    try dir.writeFile(io, .{ .sub_path = "b", .data = "beta\n" });
}

fn fixtureFileAAndDirD(dir: Io.Dir) anyerror!void {
    try dir.writeFile(io, .{ .sub_path = "a", .data = "alpha\n" });
    try dir.createDirPath(io, "d");
}

fn fixtureSymlinkToA(dir: Io.Dir) anyerror!void {
    try dir.writeFile(io, .{ .sub_path = "a", .data = "alpha\n" });
    try dir.symLink(io, "a", "sym", .{});
}

fn fixtureDashXFile(dir: Io.Dir) anyerror!void {
    try dir.writeFile(io, .{ .sub_path = "-x", .data = "dashx\n" });
}

// ---- state checks ----

fn expectHardLinked(dir: Io.Dir, p1: []const u8, p2: []const u8) !void {
    const s1 = try dir.statFile(io, p1, .{});
    const s2 = try dir.statFile(io, p2, .{});
    try testing.expectEqual(s1.inode, s2.inode);
}

fn checkAHardLinkedB(dir: Io.Dir) anyerror!void {
    try expectHardLinked(dir, "a", "b");
}

fn checkAStillIntact(dir: Io.Dir) anyerror!void {
    const contents = try dir.readFileAlloc(io, "a", testing.allocator, .limited(64));
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("alpha\n", contents);
}

fn checkDashHardLinkedToA(dir: Io.Dir) anyerror!void {
    try expectHardLinked(dir, "a", "-");
}

fn checkHlHardLinkedToA(dir: Io.Dir) anyerror!void {
    try expectHardLinked(dir, "a", "hl");
}

fn checkCHardLinkedToDashX(dir: Io.Dir) anyerror!void {
    try expectHardLinked(dir, "-x", "c");
}

fn checkNoB(dir: Io.Dir) anyerror!void {
    try testing.expectError(error.FileNotFound, dir.access(io, "b", .{}));
}

// ---- GNU-diff tests ----

test "success: two operands create a hard link, silent, exit 0" {
    try diffAgainstGnu(&.{ "a", "b" }, fixtureFileA, checkAHardLinkedB);
}

test "missing operand: no operands" {
    try diffAgainstGnu(&.{}, null, null);
}

test "missing operand after first operand" {
    try diffAgainstGnu(&.{"a"}, fixtureFileA, null);
}

test "extra operand: three operands rejected (no ln-style DIR logic)" {
    try diffAgainstGnu(&.{ "a", "b", "c" }, fixtureFileA, null);
}

test "destination exists: EEXIST diagnostic" {
    try diffAgainstGnu(&.{ "a", "b" }, fixtureFileAAndB, null);
}

test "source missing: ENOENT diagnostic" {
    try diffAgainstGnu(&.{ "nope", "x" }, null, null);
}

test "same file: link a a fails with EEXIST and does NOT delete a" {
    // Regression for the critical `-f` finding: old zlink unlinked the
    // destination first, so this invocation destroyed the user's file.
    try diffAgainstGnu(&.{ "a", "a" }, fixtureFileA, checkAStillIntact);
}

test "lone dash is a filename operand, not an option" {
    try diffAgainstGnu(&.{ "a", "-" }, fixtureFileA, checkDashHardLinkedToA);
}

test "double dash ends option parsing: dash-prefixed operand" {
    try diffAgainstGnu(&.{ "--", "-x", "c" }, fixtureDashXFile, checkCHardLinkedToDashX);
}

test "unrecognized long option" {
    try diffAgainstGnu(&.{"--frobnicate"}, null, null);
}

test "invalid short option" {
    try diffAgainstGnu(&.{"-z"}, null, null);
}

test "former ln flag -s is rejected (link has no options)" {
    try diffAgainstGnu(&.{ "-s", "a", "b" }, fixtureFileA, checkNoB);
}

test "destination is an existing directory: plain EEXIST, no basename append" {
    try diffAgainstGnu(&.{ "a", "d" }, fixtureFileAAndDirD, null);
}

test "directory source: EPERM diagnostic" {
    try diffAgainstGnu(&.{ "d", "dlink" }, fixtureFileAAndDirD, null);
}

test "symlink source: hard link follows the symlink (matches GNU link on macOS)" {
    try diffAgainstGnu(&.{ "sym", "hl" }, fixtureSymlinkToA, checkHlHardLinkedToA);
}

test "abbreviated long option --vers acts as --version (exit codes match)" {
    // stdout content deliberately differs (zlink does not claim to be GNU),
    // so compare exit codes only.
    const gnu = findGnuLink() orelse return error.SkipZigTest;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res_gnu = try runTool(allocator, gnu, &.{"--vers"}, tmp.dir);
    defer res_gnu.deinit(allocator);
    var res_z = try runTool(allocator, zlink_bin, &.{"--vers"}, tmp.dir);
    defer res_z.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res_gnu.code);
    try testing.expectEqual(@as(u8, 0), res_z.code);
    try testing.expect(res_z.stdout.len > 0);
}

test "--help after operands wins (getopt permutation): exit 0, no link created" {
    const gnu = findGnuLink() orelse return error.SkipZigTest;
    const allocator = testing.allocator;
    var tmp_gnu = testing.tmpDir(.{});
    defer tmp_gnu.cleanup();
    var tmp_z = testing.tmpDir(.{});
    defer tmp_z.cleanup();
    try fixtureFileA(tmp_gnu.dir);
    try fixtureFileA(tmp_z.dir);
    var res_gnu = try runTool(allocator, gnu, &.{ "a", "b", "--help" }, tmp_gnu.dir);
    defer res_gnu.deinit(allocator);
    var res_z = try runTool(allocator, zlink_bin, &.{ "a", "b", "--help" }, tmp_z.dir);
    defer res_z.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res_gnu.code);
    try testing.expectEqual(@as(u8, 0), res_z.code);
    try checkNoB(tmp_gnu.dir);
    try checkNoB(tmp_z.dir);
}

// ---- literal anchors (GNU coreutils 9.10 `link`, LC_ALL=C, macOS) ----
// Captured from the real binary; kept literal so this suite still pins
// GNU behavior byte-for-byte when no GNU binary is installed.

fn runZlink(allocator: std.mem.Allocator, args: []const []const u8, cwd: Io.Dir) !RunOutcome {
    return runTool(allocator, zlink_bin, args, cwd);
}

test "literal: missing operand diagnostic bytes" {
    // GNU: "link: missing operand\nTry 'link --help' for more information.\n", exit 1
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZlink(allocator, &.{}, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqualStrings(
        "zlink: missing operand\nTry 'zlink --help' for more information.\n",
        res.stderr,
    );
    try testing.expectEqualStrings("", res.stdout);
}

test "literal: missing operand after 'onearg' diagnostic bytes" {
    // GNU: "link: missing operand after 'onearg'\nTry 'link --help' for more information.\n"
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZlink(allocator, &.{"onearg"}, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqualStrings(
        "zlink: missing operand after 'onearg'\nTry 'zlink --help' for more information.\n",
        res.stderr,
    );
}

test "literal: extra operand 'c' diagnostic bytes" {
    // GNU: "link: extra operand 'c'\nTry 'link --help' for more information.\n"
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZlink(allocator, &.{ "a", "b", "c" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqualStrings(
        "zlink: extra operand 'c'\nTry 'zlink --help' for more information.\n",
        res.stderr,
    );
}

test "literal: EEXIST diagnostic bytes and shape" {
    // GNU: "link: cannot create link 'b' to 'a': File exists\n", exit 1
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixtureFileAAndB(tmp.dir);
    var res = try runZlink(allocator, &.{ "a", "b" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqualStrings(
        "zlink: cannot create link 'b' to 'a': File exists\n",
        res.stderr,
    );
}

test "literal: same-file invocation must not destroy the file (data-loss regression)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try fixtureFileA(tmp.dir);
    var res = try runZlink(allocator, &.{ "a", "a" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqualStrings(
        "zlink: cannot create link 'a' to 'a': File exists\n",
        res.stderr,
    );
    try checkAStillIntact(tmp.dir);
}
