//! GNU parity tests for ztruncate.
//!
//! External anchor: every diff case runs the installed `ztruncate` binary
//! AND the real GNU coreutils `truncate` binary (Homebrew gnubin) on
//! identical fixtures, and requires their observable results to match:
//! the process exit code, and the resulting file's presence + byte size.
//!
//! Diagnostic *text* is deliberately NOT compared: GNU emits its errors
//! with locale-specific typographic quotes and the binary's full argv[0]
//! path, neither of which ztruncate reproduces. Exit code + resulting
//! file size is the contract that actually matters for `truncate` and is
//! a genuine external anchor (the expected bytes come from GNU, not from
//! ztruncate).
//!
//! A second set of literal tests pins specific byte sizes / exit codes
//! captured from GNU coreutils 9.10 (LC_ALL=C, macOS, 2026-07-19) so the
//! suite still verifies GNU-documented behavior when no GNU binary is
//! installed. These are NOT roundtrip tests — the expected values were
//! observed from the GNU binary, not derived from ztruncate.

const std = @import("std");
const build_options = @import("build_options");
const testing = std.testing;
const Io = std.Io;
const io = testing.io;

const ztruncate_bin = build_options.ztruncate_bin;

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/truncate",
    "/usr/local/opt/coreutils/libexec/gnubin/truncate",
    "/opt/homebrew/bin/gtruncate",
    "/usr/local/bin/gtruncate",
};

fn findGnuTruncate() ?[]const u8 {
    for (gnu_candidates) |candidate| {
        Io.Dir.accessAbsolute(io, candidate, .{}) catch continue;
        return candidate;
    }
    return null;
}

const RunOutcome = struct {
    code: u8,
    crashed: bool,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *RunOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

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

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("LC_ALL", "C");

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .dir = cwd },
        .environ_map = &env,
    });
    const code: u8, const crashed: bool = switch (result.term) {
        .exited => |c| .{ c, false },
        else => .{ 0, true }, // e.g. the old integer-overflow SIGABRT
    };
    return .{ .code = code, .crashed = crashed, .stdout = result.stdout, .stderr = result.stderr };
}

/// -1 sentinel for "file does not exist".
fn sizeOf(dir: Io.Dir, name: []const u8) !i64 {
    const st = dir.statFile(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return -1,
        else => return err,
    };
    return @intCast(st.size);
}

/// Write `data` to `name` in `dir`.
fn seed(dir: Io.Dir, name: []const u8, data: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = name, .data = data });
}

const Fixture = *const fn (dir: Io.Dir) anyerror!void;

/// Core harness: run GNU truncate and ztruncate on identical fixtures and
/// require identical exit codes and identical post-state sizes for every
/// name in `check_names`. Neither binary may crash.
fn diffAgainstGnu(
    args: []const []const u8,
    setup: ?Fixture,
    check_names: []const []const u8,
) !void {
    const gnu = findGnuTruncate() orelse return error.SkipZigTest;
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
    var res_z = try runTool(allocator, ztruncate_bin, args, tmp_z.dir);
    defer res_z.deinit(allocator);

    try testing.expect(!res_gnu.crashed);
    try testing.expect(!res_z.crashed); // regression: overflow must not SIGABRT
    try testing.expectEqual(res_gnu.code, res_z.code);

    for (check_names) |name| {
        const g = try sizeOf(tmp_gnu.dir, name);
        const z = try sizeOf(tmp_z.dir, name);
        try testing.expectEqual(g, z);
    }
}

// ---- fixtures ----

fn seed3(dir: Io.Dir) anyerror!void {
    try seed(dir, "f", "abc"); // 3 bytes
}
fn seed10(dir: Io.Dir) anyerror!void {
    try seed(dir, "f", "0123456789"); // 10 bytes
}
fn seed8(dir: Io.Dir) anyerror!void {
    try seed(dir, "f", "01234567"); // 8 bytes
}
fn seed5ref(dir: Io.Dir) anyerror!void {
    try seed(dir, "ref", "12345"); // 5-byte reference
    try seed(dir, "f", "abc");
}
fn seed8ref_only(dir: Io.Dir) anyerror!void {
    try seed(dir, "ref", "01234567"); // 8-byte reference
}

// ---- absolute sizes & creation ----

test "create nonexistent file at absolute size (was: cannot open, exit 1)" {
    // GNU creates the file with O_CREAT 0666; old ztruncate failed to open.
    try diffAgainstGnu(&.{ "-s", "10", "f" }, null, &.{"f"});
}

test "absolute size zero truncates existing file" {
    try diffAgainstGnu(&.{ "-s", "0", "f" }, seed10, &.{"f"});
}

test "attached -s form and --size= form agree with GNU" {
    try diffAgainstGnu(&.{ "-s7", "f" }, null, &.{"f"});
    try diffAgainstGnu(&.{ "--size=7", "f" }, null, &.{"f"});
}

// ---- suffix scaling (KB=1000 vs K=1024 etc.) ----

test "suffix K = 1024" {
    try diffAgainstGnu(&.{ "-s", "1K", "f" }, null, &.{"f"});
}
test "suffix KB = 1000 (parity fix: old ztruncate gave 1024)" {
    try diffAgainstGnu(&.{ "-s", "1KB", "f" }, null, &.{"f"});
}
test "suffix KiB = 1024" {
    try diffAgainstGnu(&.{ "-s", "1KiB", "f" }, null, &.{"f"});
}
test "suffix M and MB" {
    try diffAgainstGnu(&.{ "-s", "1M", "f" }, null, &.{"f"});
    try diffAgainstGnu(&.{ "-s", "1MB", "f" }, null, &.{"f"});
}
test "suffix P (1024^5)" {
    try diffAgainstGnu(&.{ "-s", "1P", "f" }, null, &.{"f"});
}

// ---- invalid numbers (parity: exit 1, no panic) ----

test "trailing garbage rejected (5Kxyz), no file created" {
    try diffAgainstGnu(&.{ "-s", "5Kxyz", "f" }, null, &.{"f"});
}
test "fraction rejected (1.5K)" {
    try diffAgainstGnu(&.{ "-s", "1.5K", "f" }, null, &.{"f"});
}
test "non-number rejected (abc)" {
    try diffAgainstGnu(&.{ "-s", "abc", "f" }, null, &.{"f"});
}
test "multiply overflow rejected, not a SIGABRT panic (9999999999T)" {
    // Old ztruncate: `num *= multiplier` panicked -> exit 134. GNU: exit 1.
    try diffAgainstGnu(&.{ "-s", "9999999999T", "f" }, null, &.{"f"});
}
test "suffix 8E overflows i64 -> invalid" {
    try diffAgainstGnu(&.{ "-s", "8E", "f" }, null, &.{"f"});
}

// ---- relative operators ----

test "extend +5 on a 3-byte file -> 8" {
    try diffAgainstGnu(&.{ "-s", "+5", "f" }, seed3, &.{"f"});
}
test "reduce -2 on a 10-byte file -> 8" {
    try diffAgainstGnu(&.{ "-s", "-2", "f" }, seed10, &.{"f"});
}
test "reduce below zero floors at 0" {
    try diffAgainstGnu(&.{ "-s", "-100", "f" }, seed3, &.{"f"});
}
test "extend on a freshly-created file bases at 0" {
    // GNU O_CREATs the file (size 0) then extends: +5 -> 5.
    try diffAgainstGnu(&.{ "-s", "+5", "f" }, null, &.{"f"});
}
test "add overflow reported, not a SIGABRT panic (+i64max on 3 bytes)" {
    // Old ztruncate: `current + size` panicked -> exit 134. GNU: exit 1.
    try diffAgainstGnu(&.{ "-s", "+9223372036854775807", "f" }, seed3, &.{"f"});
}
test "at-most <4 on 8 bytes -> 4" {
    try diffAgainstGnu(&.{ "-s", "<4", "f" }, seed8, &.{"f"});
}
test "at-most <4 on 3 bytes -> 3 (no change)" {
    try diffAgainstGnu(&.{ "-s", "<4", "f" }, seed3, &.{"f"});
}
test "at-least >4 on 8 bytes -> 8 (no change)" {
    try diffAgainstGnu(&.{ "-s", ">4", "f" }, seed8, &.{"f"});
}
test "at-least >4 on 3 bytes -> 4" {
    try diffAgainstGnu(&.{ "-s", ">4", "f" }, seed3, &.{"f"});
}
test "round down /3 on 10 bytes -> 9" {
    try diffAgainstGnu(&.{ "-s", "/3", "f" }, seed10, &.{"f"});
}
test "round up %4 on 10 bytes -> 12" {
    try diffAgainstGnu(&.{ "-s", "%4", "f" }, seed10, &.{"f"});
}
test "round up %4 on 8 bytes -> 8 (already a multiple)" {
    try diffAgainstGnu(&.{ "-s", "%4", "f" }, seed8, &.{"f"});
}
test "division by zero /0 rejected (exit 1)" {
    try diffAgainstGnu(&.{ "-s", "/0", "f" }, seed10, &.{"f"});
}
test "division by zero %0 rejected (exit 1)" {
    try diffAgainstGnu(&.{ "-s", "%0", "f" }, seed10, &.{"f"});
}

// ---- -c / --no-create ----

test "-c on a missing file: nothing created, exit 0" {
    try diffAgainstGnu(&.{ "-c", "-s", "10", "f" }, null, &.{"f"});
}
test "-c on an existing file still truncates" {
    try diffAgainstGnu(&.{ "-c", "-s", "3", "f" }, seed10, &.{"f"});
}
test "--no-create long form on a missing file" {
    try diffAgainstGnu(&.{ "--no-create", "-s", "5", "f" }, null, &.{"f"});
}

// ---- -r / --reference ----

test "-r sets file to reference size exactly" {
    try diffAgainstGnu(&.{ "-r", "ref", "f" }, seed5ref, &.{"f"});
}
test "-r with relative -s applies operator to reference size" {
    // ref is 5 bytes; -s +2 -> 7.
    try diffAgainstGnu(&.{ "-r", "ref", "-s", "+2", "f" }, seed5ref, &.{"f"});
}
test "-r with absolute -s is an error (must be relative)" {
    try diffAgainstGnu(&.{ "-r", "ref", "-s", "0", "f" }, seed5ref, &.{"f"});
}

// ---- multiple operands ----

test "many operands are all truncated (was: silent drop past 256)" {
    const allocator = testing.allocator;
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        try names.append(allocator, try std.fmt.allocPrint(allocator, "f{d:0>3}", .{i}));
    }
    // args = ["-s", "4", f000 .. f299]
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(allocator);
    try args.append(allocator, "-s");
    try args.append(allocator, "4");
    try args.appendSlice(allocator, names.items);
    try diffAgainstGnu(args.items, null, names.items);
}

// ---- missing-operand / no-size errors ----

test "no size and no reference: exit 1" {
    try diffAgainstGnu(&.{"f"}, seed3, &.{"f"});
}
test "size but no file operand: exit 1" {
    try diffAgainstGnu(&.{ "-s", "10" }, null, &.{});
}

// ---------------------------------------------------------------------------
// Literal anchors (GNU coreutils 9.10, LC_ALL=C, macOS, 2026-07-19).
// Kept literal so the suite pins GNU behavior even without the GNU binary.
// ---------------------------------------------------------------------------

fn runZ(allocator: std.mem.Allocator, args: []const []const u8, cwd: Io.Dir) !RunOutcome {
    return runTool(allocator, ztruncate_bin, args, cwd);
}

test "literal: -s 1KB yields exactly 1000 bytes" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{ "-s", "1KB", "f" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res.code);
    try testing.expectEqual(@as(i64, 1000), try sizeOf(tmp.dir, "f"));
}

test "literal: -s 1K yields exactly 1024 bytes" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{ "-s", "1K", "f" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res.code);
    try testing.expectEqual(@as(i64, 1024), try sizeOf(tmp.dir, "f"));
}

test "literal: overflow spec exits 1 without SIGABRT" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{ "-s", "9999999999T", "f" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expect(!res.crashed);
    try testing.expectEqual(@as(u8, 1), res.code);
    try testing.expectEqual(@as(i64, -1), try sizeOf(tmp.dir, "f")); // not created
}

test "literal: round up %4 on 10 bytes -> 12" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try seed(tmp.dir, "f", "0123456789");
    var res = try runZ(allocator, &.{ "-s", "%4", "f" }, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res.code);
    try testing.expectEqual(@as(i64, 12), try sizeOf(tmp.dir, "f"));
}

test "literal: --version to stdout, exit 0" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{"--version"}, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res.code);
    try testing.expectEqualStrings("", res.stderr);
    try testing.expect(std.mem.startsWith(u8, res.stdout, "ztruncate "));
}

test "literal: --help to stdout, exit 0" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var res = try runZ(allocator, &.{"--help"}, tmp.dir);
    defer res.deinit(allocator);
    try testing.expectEqual(@as(u8, 0), res.code);
    try testing.expect(std.mem.indexOf(u8, res.stdout, "Usage: ztruncate") != null);
}
