//! Externally-anchored parity tests for zdu.
//!
//! The anchor is the REAL GNU coreutils `du` binary installed on this machine
//! (homebrew coreutils -- `gdu` / the `gnubin/du` symlink). For a spread of
//! representative directory trees and flag combinations we run BOTH `zdu` and
//! GNU `du` on the identical absolute path and require byte-identical output
//! after sorting lines (zdu's parallel walker emits entries in
//! thread-completion order, which is a documented nondeterminism; sorting
//! normalizes ordering while still proving every (size, path) pair matches).
//!
//! This is a true external anchor per zig-forge/CLAUDE.md rule #1: the expected
//! output is produced by an implementation this repo did not write. If GNU du is
//! not installed the tests skip (they never silently pass).
//!
//! Both the sequential (`--threads=1`) and default (parallel) code paths are
//! checked against GNU. The wide tree (>=4 top-level subdirs) exercises the
//! real parallel walker + its completion/termination logic.

const std = @import("std");
const build_options = @import("build_options");

const zdu_bin = build_options.zdu_bin;

// The process-spawning I/O needs a real allocator: std.Io's
// `global_single_threaded` instance is initialized with `Allocator.failing`,
// so `std.process.run` on it fails with OutOfMemory before ever reaching exec.
// Each test constructs a `Threaded` io backed by the testing allocator and
// threads it through every operation (filesystem + process spawn).
const Io = std.Io;

/// Locate the GNU coreutils `du` binary. Homebrew installs it as `gdu` and also
/// exposes it under `gnubin/du`. Returns null if none is present.
fn findGnuDu(io: Io) ?[]const u8 {
    const candidates = [_][]const u8{
        "/opt/homebrew/opt/coreutils/libexec/gnubin/du",
        "/opt/homebrew/bin/gdu",
        "/usr/local/opt/coreutils/libexec/gnubin/du",
        "/usr/local/bin/gdu",
        "/usr/bin/gdu",
    };
    for (candidates) |c| {
        std.Io.Dir.accessAbsolute(io, c, .{}) catch continue;
        return c;
    }
    return null;
}

/// Sort the newline-separated lines of `input`, dropping empty lines. Returns a
/// caller-owned buffer.
fn sortLines(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);

    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0) continue;
        try lines.append(gpa, ln);
    }

    std.mem.sort([]const u8, lines.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    return std.mem.join(gpa, "\n", lines.items);
}

/// Run `argv`, returning its stdout with lines sorted (caller owns the result).
fn runSorted(gpa: std.mem.Allocator, io: Io, argv: []const []const u8) ![]u8 {
    const res = try std.process.run(gpa, io, .{ .argv = argv });
    gpa.free(res.stderr);
    defer gpa.free(res.stdout);
    return sortLines(gpa, res.stdout);
}

/// Build an argv: [bin] ++ flags ++ (extra) ++ [target].
fn buildArgv(
    gpa: std.mem.Allocator,
    bin: []const u8,
    flags: []const []const u8,
    extra: []const []const u8,
    target: []const u8,
) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(gpa);
    try argv.append(gpa, bin);
    for (flags) |f| try argv.append(gpa, f);
    for (extra) |e| try argv.append(gpa, e);
    try argv.append(gpa, target);
    return argv.toOwnedSlice(gpa);
}

/// Compare zdu (both sequential and parallel) against GNU du for one flag set
/// on one absolute target path.
fn compareCase(
    gpa: std.mem.Allocator,
    io: Io,
    gnu: []const u8,
    target: []const u8,
    flags: []const []const u8,
) !void {
    // GNU reference output.
    const gnu_argv = try buildArgv(gpa, gnu, flags, &.{}, target);
    defer gpa.free(gnu_argv);
    const expected = try runSorted(gpa, io, gnu_argv);
    defer gpa.free(expected);

    // zdu sequential (single-threaded walker).
    const seq_argv = try buildArgv(gpa, zdu_bin, flags, &.{"--threads=1"}, target);
    defer gpa.free(seq_argv);
    const seq_out = try runSorted(gpa, io, seq_argv);
    defer gpa.free(seq_out);

    // zdu default (parallel walker).
    const par_argv = try buildArgv(gpa, zdu_bin, flags, &.{}, target);
    defer gpa.free(par_argv);
    const par_out = try runSorted(gpa, io, par_argv);
    defer gpa.free(par_out);

    if (!std.mem.eql(u8, expected, seq_out)) {
        std.debug.print(
            "\nSEQUENTIAL parity mismatch for flags {any}\n--- GNU du ---\n{s}\n--- zdu --threads=1 ---\n{s}\n",
            .{ flags, expected, seq_out },
        );
        return error.SequentialParityMismatch;
    }
    if (!std.mem.eql(u8, expected, par_out)) {
        std.debug.print(
            "\nPARALLEL parity mismatch for flags {any}\n--- GNU du ---\n{s}\n--- zdu (parallel) ---\n{s}\n",
            .{ flags, expected, par_out },
        );
        return error.ParallelParityMismatch;
    }
}

fn writeZeros(dir: std.Io.Dir, io: Io, sub_path: []const u8, n: usize, gpa: std.mem.Allocator) !void {
    const data = try gpa.alloc(u8, n);
    defer gpa.free(data);
    @memset(data, 0);
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
}

/// The flag combinations exercised against GNU du. Each inner slice is one
/// invocation's flags (before the target path).
const cases = [_][]const []const u8{
    &.{}, // default: 1K blocks, directories only
    &.{"-a"}, // all files
    &.{"-s"}, // summarize
    &.{"-b"}, // apparent size in bytes
    &.{"-k"}, // 1K blocks
    &.{"-m"}, // 1M blocks
    &.{"-h"}, // human readable (binary)
    &.{"--si"}, // human readable (SI / powers of 1000)
    &.{"-c"}, // grand total
    &.{ "-a", "-h" }, // all + human
    &.{ "-a", "--si" }, // all + SI
};

test "zdu matches GNU du on a small nested tree" {
    const gpa = std.testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const gnu = findGnuDu(io) orelse return error.SkipZigTest;

    const cwd = std.Io.Dir.cwd();
    const base = "zdu_parity_small";
    // Clean any leftover from an interrupted prior run, then build fresh.
    cwd.deleteTree(io, base) catch {};
    defer cwd.deleteTree(io, base) catch {};

    try cwd.createDirPath(io, base ++ "/a/b/c");
    try cwd.createDirPath(io, base ++ "/a/d");
    try cwd.createDirPath(io, base ++ "/e");

    var dir = try cwd.openDir(io, base, .{});
    defer dir.close(io);
    try writeZeros(dir, io, "a/f1", 1000, gpa);
    try writeZeros(dir, io, "a/b/f2", 5000, gpa);
    try writeZeros(dir, io, "a/b/c/f3", 100, gpa);
    try writeZeros(dir, io, "a/d/f4", 20000, gpa);
    try writeZeros(dir, io, "e/f5", 3000, gpa);

    const abs = try dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(abs);

    for (cases) |flags| {
        try compareCase(gpa, io, gnu, abs, flags);
    }
}

test "zdu matches GNU du on a wide tree (parallel walker)" {
    const gpa = std.testing.allocator;
    var threaded = Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const gnu = findGnuDu(io) orelse return error.SkipZigTest;

    const cwd = std.Io.Dir.cwd();
    const base = "zdu_parity_wide";
    cwd.deleteTree(io, base) catch {};
    defer cwd.deleteTree(io, base) catch {};

    try cwd.createDirPath(io, base);
    var dir = try cwd.openDir(io, base, .{});
    defer dir.close(io);

    // 6 top-level subdirs, each with a nested subdir + files. >= 4 top-level
    // dirs forces the real parallel path (PARALLEL_THRESHOLD = 4), so this tree
    // exercises the worker queue + completion/termination logic that must not
    // drop subtrees.
    const names = [_][]const u8{ "d1", "d2", "d3", "d4", "d5", "d6" };
    inline for (names, 0..) |name, i| {
        try dir.createDirPath(io, name ++ "/sub");
        try writeZeros(dir, io, name ++ "/file", 2000 + i * 500, gpa);
        try writeZeros(dir, io, name ++ "/sub/f", 1500, gpa);
    }

    const abs = try dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(abs);

    for (cases) |flags| {
        try compareCase(gpa, io, gnu, abs, flags);
    }
}
