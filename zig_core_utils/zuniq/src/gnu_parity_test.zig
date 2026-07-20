//! Externally-anchored parity tests for zuniq.
//!
//! The primary anchor is the real GNU `uniq` binary (coreutils): every case
//! below runs the SAME argv against both `zuniq` and GNU `uniq` and asserts the
//! stdout bytes AND the process exit code match. GNU coreutils is a third-party
//! implementation zuniq's authors did not write, so this is a true external
//! anchor (not a roundtrip).
//!
//! When no GNU binary is present, the suite falls back to literal expected
//! bytes taken from the documented GNU/POSIX behavior (see `literal_cases`),
//! with the source of each expectation cited inline.
//!
//! The zuniq binary under test is passed in by build.zig via the generated
//! `build_options` module (build_options.zuniq_bin).

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;

const io = std.testing.io;

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/uniq",
    "/opt/homebrew/bin/guniq",
    "/usr/bin/uniq", // GNU on Linux
};

fn findGnu() ?[]const u8 {
    for (gnu_candidates) |p| {
        Io.Dir.accessAbsolute(io, p, .{}) catch continue;
        return p;
    }
    return null;
}

const RunOut = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8, // 255 sentinel for signal/abnormal termination
};

/// Run `bin` with `args`, with the child's cwd set to `dir`, capturing stdout,
/// stderr and the exit code. `args` are appended after `bin`.
fn runIn(
    gpa: std.mem.Allocator,
    dir: Io.Dir,
    bin: []const u8,
    args: []const []const u8,
) !RunOut {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, bin);
    for (args) |a| try argv.append(gpa, a);

    const r = try std.process.run(gpa, io, .{
        .argv = argv.items,
        .cwd = .{ .dir = dir },
    });
    const code: u8 = switch (r.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = r.stdout, .stderr = r.stderr, .code = code };
}

const zbin = build_options.zuniq_bin;

const Case = struct {
    name: []const u8,
    args: []const []const u8, // NOT including the fixture filename
    input: []const u8,
};

// Every case writes `input` to a fixture file and runs `args ++ ["in.txt"]`.
const cases = [_]Case{
    .{ .name = "plain", .args = &.{}, .input = "a\na\nb\nb\nb\nc\n" },
    .{ .name = "count", .args = &.{"-c"}, .input = "a\na\nb\nb\nb\nc\n" },
    .{ .name = "repeated", .args = &.{"-d"}, .input = "a\na\nb\nb\nb\nc\n" },
    .{ .name = "unique", .args = &.{"-u"}, .input = "a\na\nb\nb\nb\nc\n" },
    .{ .name = "all-repeated", .args = &.{"-D"}, .input = "a\na\nb\nb\nb\nc\n" },
    .{ .name = "bundle-dc", .args = &.{"-dc"}, .input = "a\na\nb\nb\nb\nc\n" },
    .{ .name = "bundle-cd", .args = &.{"-cd"}, .input = "a\na\nb\nb\nb\nc\n" },
    .{ .name = "repeated+unique-empty", .args = &.{ "-d", "-u" }, .input = "a\na\nb\nc\nc\n" },
    .{ .name = "ignore-case", .args = &.{"-i"}, .input = "A\na\nB\n" },
    .{ .name = "skip-fields-attached", .args = &.{"-f1"}, .input = "x a\ny a\nz b\n" },
    .{ .name = "skip-fields-separate", .args = &.{ "-f", "1" }, .input = "x a\ny a\nz b\n" },
    .{ .name = "skip-chars-attached", .args = &.{"-s2"}, .input = "aaX\nbbX\nbbY\n" },
    .{ .name = "check-chars-attached", .args = &.{"-w1"}, .input = "aaX\nbbX\nbbY\n" },
    .{ .name = "count+skip", .args = &.{ "-c", "-f1" }, .input = "x a\ny a\nz b\n" },
    .{ .name = "group-default", .args = &.{"--group"}, .input = "a\na\nb\nb\nb\nc\n" },
    .{ .name = "group-both", .args = &.{"--group=both"}, .input = "a\na\nb\nc\n" },
    .{ .name = "all-repeated-prepend", .args = &.{"--all-repeated=prepend"}, .input = "a\na\nb\nc\nc\n" },
    .{ .name = "all-repeated-separate", .args = &.{"--all-repeated=separate"}, .input = "a\na\nb\nc\nc\n" },
    .{ .name = "zero-terminated", .args = &.{"-z"}, .input = "a\x00a\x00b\x00" },
    .{ .name = "empty-input", .args = &.{}, .input = "" },
    .{ .name = "no-trailing-newline", .args = &.{}, .input = "a\na\nb" },
    .{ .name = "single-line", .args = &.{}, .input = "only\n" },
    // Error / exit-code parity:
    .{ .name = "invalid-option", .args = &.{"-Q"}, .input = "a\n" },
    .{ .name = "invalid-number", .args = &.{ "-f", "abc" }, .input = "a\n" },
    .{ .name = "mutually-exclusive-cD", .args = &.{ "-c", "-D" }, .input = "a\n" },
    .{ .name = "mutually-exclusive-group", .args = &.{ "--group", "-c" }, .input = "a\n" },
};

test "parity against GNU uniq (stdout + exit code)" {
    const gnu = findGnu() orelse {
        std.debug.print("SKIP: no GNU uniq found; literal-byte tests still cover core behavior\n", .{});
        return error.SkipZigTest;
    };
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var failures: usize = 0;
    for (cases) |c| {
        try tmp.dir.writeFile(io, .{ .sub_path = "in.txt", .data = c.input });

        var args: std.ArrayListUnmanaged([]const u8) = .empty;
        defer args.deinit(gpa);
        for (c.args) |a| try args.append(gpa, a);
        try args.append(gpa, "in.txt");

        const zr = try runIn(gpa, tmp.dir, zbin, args.items);
        defer gpa.free(zr.stdout);
        defer gpa.free(zr.stderr);
        const gr = try runIn(gpa, tmp.dir, gnu, args.items);
        defer gpa.free(gr.stdout);
        defer gpa.free(gr.stderr);

        if (!std.mem.eql(u8, zr.stdout, gr.stdout) or zr.code != gr.code) {
            failures += 1;
            std.debug.print(
                "MISMATCH [{s}]: exit z={d} g={d}\n  zuniq stdout: {s}\n  gnu   stdout: {s}\n",
                .{ c.name, zr.code, gr.code, zr.stdout, gr.stdout },
            );
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "large input is not truncated at 4 MiB (streaming)" {
    // The old implementation read into a fixed 4 MiB stack buffer and silently
    // dropped everything past the boundary, returning success. This drives
    // >4 MiB of DISTINCT lines through and requires the final marker line to
    // survive and the total byte count to be preserved.
    const gpa = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    var line_buf: [32]u8 = undefined;
    var i: usize = 0;
    while (buf.items.len < 5 * 1024 * 1024) : (i += 1) {
        const line = try std.fmt.bufPrint(&line_buf, "line-{d}\n", .{i});
        try buf.appendSlice(gpa, line);
    }
    try buf.appendSlice(gpa, "SENTINEL_LAST_LINE\n");

    try tmp.dir.writeFile(io, .{ .sub_path = "big.txt", .data = buf.items });

    const zr = try runIn(gpa, tmp.dir, zbin, &.{"big.txt"});
    defer gpa.free(zr.stdout);
    defer gpa.free(zr.stderr);

    try std.testing.expectEqual(@as(u8, 0), zr.code);
    // All lines are unique, so output == input; nothing may be dropped.
    try std.testing.expect(std.mem.indexOf(u8, zr.stdout, "SENTINEL_LAST_LINE\n") != null);
    try std.testing.expectEqual(buf.items.len, zr.stdout.len);
}

test "missing input file exits nonzero with empty stdout" {
    // GNU: `uniq /nonexistent` -> exit 1. The pre-fix zuniq exited 0.
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const zr = try runIn(gpa, tmp.dir, zbin, &.{"does_not_exist_12345.txt"});
    defer gpa.free(zr.stdout);
    defer gpa.free(zr.stderr);
    try std.testing.expectEqual(@as(u8, 1), zr.code);
    try std.testing.expectEqual(@as(usize, 0), zr.stdout.len);
}

test "--help and --version write to stdout, exit 0" {
    // GNU routes both to stdout; the pre-fix zuniq wrote to stderr (empty stdout).
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "--help", "--version" }) |flag| {
        const zr = try runIn(gpa, tmp.dir, zbin, &.{flag});
        defer gpa.free(zr.stdout);
        defer gpa.free(zr.stderr);
        try std.testing.expectEqual(@as(u8, 0), zr.code);
        try std.testing.expect(zr.stdout.len > 0);
    }
}

// --- Literal-byte anchors (survive even when no GNU binary is installed) ---
// Expected outputs transcribed from GNU coreutils `uniq` documented behavior
// and POSIX (IEEE Std 1003.1 `uniq`). These are NOT roundtrips: the expected
// bytes are written out explicitly, independent of zuniq's own code.

const LiteralCase = struct {
    args: []const []const u8,
    input: []const u8,
    expect_stdout: []const u8,
    expect_code: u8,
};

const literal_cases = [_]LiteralCase{
    // POSIX: adjacent duplicate lines collapse to one.
    .{ .args = &.{}, .input = "a\na\nb\nc\nc\n", .expect_stdout = "a\nb\nc\n", .expect_code = 0 },
    // GNU -c: right-justified count in a 7-wide field, a space, then the line.
    .{ .args = &.{"-c"}, .input = "a\na\nb\n", .expect_stdout = "      2 a\n      1 b\n", .expect_code = 0 },
    // GNU -d: only lines that repeat.
    .{ .args = &.{"-d"}, .input = "a\na\nb\n", .expect_stdout = "a\n", .expect_code = 0 },
    // GNU -u: only lines that never repeat.
    .{ .args = &.{"-u"}, .input = "a\na\nb\n", .expect_stdout = "b\n", .expect_code = 0 },
    // GNU: -d and -u together select lines that are both repeated and unique => none.
    .{ .args = &.{ "-d", "-u" }, .input = "a\na\nb\n", .expect_stdout = "", .expect_code = 0 },
    // GNU: invalid option exits 1 with empty stdout.
    .{ .args = &.{"-Q"}, .input = "a\n", .expect_stdout = "", .expect_code = 1 },
};

test "literal-byte anchors (GNU/POSIX documented behavior)" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (literal_cases) |c| {
        try tmp.dir.writeFile(io, .{ .sub_path = "in.txt", .data = c.input });
        var args: std.ArrayListUnmanaged([]const u8) = .empty;
        defer args.deinit(gpa);
        for (c.args) |a| try args.append(gpa, a);
        try args.append(gpa, "in.txt");

        const zr = try runIn(gpa, tmp.dir, zbin, args.items);
        defer gpa.free(zr.stdout);
        defer gpa.free(zr.stderr);
        try std.testing.expectEqualSlices(u8, c.expect_stdout, zr.stdout);
        try std.testing.expectEqual(c.expect_code, zr.code);
    }
}
