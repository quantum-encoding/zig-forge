//! GNU parity tests for zrmdir.
//!
//! These are EXTERNALLY ANCHORED per zig-forge/CLAUDE.md golden rule #1: the
//! expected output is not written by us — it is produced by the *real* GNU
//! `rmdir` binary (grmdir, GNU coreutils 9.10) run on the identical fixture.
//! Each test builds a filesystem fixture, runs the freshly-built `zrmdir` on
//! it, rebuilds the same fixture, runs `grmdir` on it, and asserts that
//! stdout, stderr and the exit code match byte-for-byte after normalizing
//! only the program name (each binary's own argv[0] path and basename -> PROG;
//! see `normalize`).
//!
//! If grmdir is not installed the whole suite skips (error.SkipZigTest) so CI
//! on a machine without coreutils stays green rather than silently vacuous.
//!
//! The zrmdir binary path is injected by build.zig via `build_options`.

const std = @import("std");
const build_options = @import("build_options");

const Io = std.Io;
const Dir = Io.Dir;
const Term = std.process.Child.Term;

/// Per-process counter to keep temp-root names unique across tests.
var counter: u64 = 0;

/// Candidate locations for the GNU rmdir binary, in preference order.
const grmdir_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/rmdir",
    "/opt/homebrew/bin/grmdir",
    "/usr/local/bin/grmdir",
    "/usr/bin/grmdir",
};

fn findGrmdir(io: Io) ?[]const u8 {
    for (grmdir_candidates) |cand| {
        Dir.cwd().access(io, cand, .{}) catch continue;
        return cand;
    }
    return null;
}

/// The kind of filesystem fixture to (re)build under the temp root before a run.
const Fixture = enum {
    /// Only the temp root exists; no operand target.
    none,
    /// root/d  (an empty directory)
    empty_d,
    /// root/d + root/d/child  (a non-empty directory)
    nonempty_d,
    /// root/a/b/c  (a chain of empty directories, for -p)
    nested_abc,
    /// root/x/keep (a file) + root/x/a/b  (climb up -p blocks at non-empty x)
    blocked_top,
};

fn buildFixture(io: Io, root: []const u8, fx: Fixture) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    switch (fx) {
        .none => try Dir.cwd().createDirPath(io, root),
        .empty_d => {
            const p = try std.fmt.bufPrint(&buf, "{s}/d", .{root});
            try Dir.cwd().createDirPath(io, p);
        },
        .nonempty_d => {
            const p = try std.fmt.bufPrint(&buf, "{s}/d", .{root});
            try Dir.cwd().createDirPath(io, p);
            const f = try std.fmt.bufPrint(&buf, "{s}/d/child", .{root});
            var file = try Dir.cwd().createFile(io, f, .{});
            file.close(io);
        },
        .nested_abc => {
            const p = try std.fmt.bufPrint(&buf, "{s}/a/b/c", .{root});
            try Dir.cwd().createDirPath(io, p);
        },
        .blocked_top => {
            const p = try std.fmt.bufPrint(&buf, "{s}/x/a/b", .{root});
            try Dir.cwd().createDirPath(io, p);
            const f = try std.fmt.bufPrint(&buf, "{s}/x/keep", .{root});
            var file = try Dir.cwd().createFile(io, f, .{});
            file.close(io);
        },
    }
}

fn exitCode(t: Term) i64 {
    return switch (t) {
        .exited => |c| c,
        .signal => |s| -@as(i64, @intFromEnum(s)),
        else => -9999,
    };
}

/// Normalize the program name to "PROG" so the two runs' diagnostics can be
/// compared. GNU rmdir echoes argv[0] *verbatim* in verbose lines and the
/// "Try '… --help'" hint, but the basename in `error()` diagnostics; zrmdir
/// prints a fixed "zrmdir". So replace the full invoked path first (covers the
/// verbose/try-help forms), then the basename (covers the error form).
///
/// The temp root is named "rmparity_…" — it contains neither "rmdir" (as a
/// contiguous substring) nor "zrmdir" — so operand paths are never touched.
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

    const r = try std.process.run(alloc, io, .{
        .argv = argv.items,
    });
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);

    return .{
        .stdout = try normalize(alloc, r.stdout, exe),
        .stderr = try normalize(alloc, r.stderr, exe),
        .code = exitCode(r.term),
    };
}

/// Core comparison. Builds the fixture, runs zrmdir, rebuilds the identical
/// fixture, runs grmdir, and asserts all three observable channels match.
///
/// `operands` are joined onto the temp root when `join_root` is true (absolute
/// operands); otherwise they are passed to both binaries verbatim (used for
/// the "." EINVAL case and the `-- -p` literal-operand case, neither of which
/// removes anything, so the inherited cwd is irrelevant).
fn runParity(
    fx: Fixture,
    flags: []const []const u8,
    operands: []const []const u8,
    join_root: bool,
) !void {
    const alloc = std.testing.allocator;
    // The global single-threaded IO ships with a *failing* allocator, but
    // process spawning allocates the argv/environ buffers through the IO's
    // allocator — so build a Threaded IO backed by the testing allocator.
    var threaded = Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const grmdir = findGrmdir(io) orelse return error.SkipZigTest;
    const zrmdir = build_options.zrmdir_exe;

    // Unique temp root. The name deliberately contains neither "grmdir" nor
    // "zrmdir" so the program-name normalization never touches the path.
    const tmp_base: []const u8 = if (std.c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
    // Unique-per-run suffix: this process's pid mixed with a per-call counter
    // so tests in the same process never collide, and separate runs (distinct
    // pids) never collide either.
    counter += 1;
    const pid: u64 = @intCast(std.c.getpid());
    const seed: u64 = (pid << 20) ^ (counter *% 0x9E3779B97F4A7C15);
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = std.mem.trimEnd(u8, tmp_base, "/");
    const root = try std.fmt.bufPrint(&root_buf, "{s}/rmparity_{x}", .{ base, seed });

    defer Dir.cwd().deleteTree(io, root) catch {};

    // Build the argv tail (flags then operands) shared by both runs.
    var tail: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (tail.items[flags.len..]) |o| alloc.free(o);
        tail.deinit(alloc);
    }
    for (flags) |f| try tail.append(alloc, f);
    for (operands) |op| {
        const s = if (join_root)
            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, op })
        else
            try alloc.dupe(u8, op);
        try tail.append(alloc, s);
    }

    try buildFixture(io, root, fx);
    const z = try runOne(alloc, io, zrmdir, tail.items);
    defer alloc.free(z.stdout);
    defer alloc.free(z.stderr);

    // Clean any partial removal, then rebuild the identical fixture for grmdir.
    Dir.cwd().deleteTree(io, root) catch {};
    try buildFixture(io, root, fx);
    const g = try runOne(alloc, io, grmdir, tail.items);
    defer alloc.free(g.stdout);
    defer alloc.free(g.stderr);

    std.testing.expectEqualStrings(g.stdout, z.stdout) catch |e| {
        std.debug.print("STDOUT mismatch (expected=grmdir, actual=zrmdir)\n", .{});
        return e;
    };
    std.testing.expectEqualStrings(g.stderr, z.stderr) catch |e| {
        std.debug.print("STDERR mismatch (expected=grmdir, actual=zrmdir)\n", .{});
        return e;
    };
    std.testing.expectEqual(g.code, z.code) catch |e| {
        std.debug.print("EXIT mismatch: grmdir={d} zrmdir={d}\n", .{ g.code, z.code });
        return e;
    };
}

// ---------------------------------------------------------------------------
// Tests. Each asserts zrmdir == grmdir on identical inputs.
// ---------------------------------------------------------------------------

test "empty directory removed silently, exit 0" {
    try runParity(.empty_d, &.{}, &.{"d"}, true);
}

test "verbose empty directory removal" {
    try runParity(.empty_d, &.{"-v"}, &.{"d"}, true);
}

test "non-empty directory: 'Directory not empty', exit 1" {
    try runParity(.nonempty_d, &.{}, &.{"d"}, true);
}

test "nonexistent directory: 'No such file or directory', exit 1" {
    try runParity(.none, &.{}, &.{"nope"}, true);
}

test "not-a-directory component: 'Not a directory', exit 1" {
    // root/x/keep is a file; keep/sub can never be a directory -> ENOTDIR.
    try runParity(.blocked_top, &.{}, &.{"x/keep/sub"}, true);
}

test "-p climbs and removes the whole empty chain" {
    try runParity(.nested_abc, &.{"-p"}, &.{"a/b/c"}, true);
}

test "-pv verbose climb prints a line per ancestor" {
    try runParity(.nested_abc, &.{"-pv"}, &.{"a/b/c"}, true);
}

test "-p climb failure at non-empty ancestor: 'failed to remove directory'" {
    // This is the exact case the audit flagged: GNU's remove_parents DOES emit
    // the word 'directory' here. Anchoring against grmdir proves parity.
    try runParity(.blocked_top, &.{"-p"}, &.{"x/a/b"}, true);
}

test "-pv climb failure verbose output + diagnostic" {
    try runParity(.blocked_top, &.{"-pv"}, &.{"x/a/b"}, true);
}

test "--ignore-fail-on-non-empty swallows non-empty error, exit 0" {
    try runParity(.nonempty_d, &.{"--ignore-fail-on-non-empty"}, &.{"d"}, true);
}

test "-p with --ignore-fail-on-non-empty stops quietly at non-empty ancestor" {
    try runParity(.blocked_top, &.{ "-p", "--ignore-fail-on-non-empty" }, &.{"x/a/b"}, true);
}

test "missing operand: diagnostic + Try-help, exit 1" {
    try runParity(.none, &.{}, &.{}, true);
}

test "'.' operand: EINVAL 'Invalid argument', exit 1" {
    // rmdir '.' fails EINVAL on both binaries and never removes anything, so
    // the inherited cwd is safe. (zrmdir must NOT crash here — Zig's deleteDir
    // aborts on EINVAL, which is why isDotFinalComponent guards it.)
    try runParity(.none, &.{}, &.{"."}, false);
}

test "unrecognized long option: diagnostic + Try-help, exit 1" {
    try runParity(.none, &.{"--bogus"}, &.{"d"}, true);
}

test "invalid short option: diagnostic + Try-help, exit 1" {
    try runParity(.none, &.{"-z"}, &.{"d"}, true);
}

test "'--' terminates options; following '-p' is an operand name" {
    // After '--', '-p' is a literal (nonexistent) operand, not a flag.
    try runParity(.none, &.{"--"}, &.{"-p"}, false);
}

test "multiple operands: one fails, one succeeds; exit 1 overall" {
    // root/d empty (removed), root/nope missing (error) -> exit 1, order preserved.
    try runParity(.empty_d, &.{}, &.{ "d", "nope" }, true);
}
