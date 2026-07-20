//! Externally-anchored parity tests for zcsplit.
//!
//! The external anchor (per zig-forge/CLAUDE.md's golden rule #1) is the REAL
//! GNU coreutils `csplit` binary — here `/opt/homebrew/bin/gcsplit` (GNU
//! coreutils 9.10). Every test runs the SAME inputs through both the freshly
//! built `zcsplit` and GNU `csplit`, in isolated temp directories, and asserts
//! that their observable behaviour matches:
//!
//!   * process exit code
//!   * stdout (the printed byte counts) — for the success cases
//!   * the set of created output files (names + exact bytes)
//!
//! These are NOT roundtrip tests: the expected output is produced by an
//! independent implementation the zcsplit author did not write. If `gcsplit`
//! is not installed the test self-skips (error.SkipZigTest) so CI on a machine
//! without coreutils still passes rather than silently proving nothing.

const std = @import("std");
const build_opts = @import("build_opts");
const Io = std.Io;

const zcsplit_bin = build_opts.zcsplit_bin;
const io = std.testing.io;

/// Candidate paths for the GNU reference binary, in priority order.
const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/csplit",
    "/opt/homebrew/bin/gcsplit",
    "/usr/local/bin/gcsplit",
    "/usr/bin/gcsplit",
};

/// The build passes zcsplit's path relative to the build root; the child
/// process runs with cwd set to a temp dir, so resolve it to absolute first.
fn absZcsplitBin(a: std.mem.Allocator) ![]const u8 {
    if (std.fs.path.isAbsolute(zcsplit_bin)) return zcsplit_bin;
    const cwd = try std.process.currentPathAlloc(io, a);
    return std.fs.path.join(a, &.{ cwd, zcsplit_bin });
}

fn findGnu() ?[]const u8 {
    for (gnu_candidates) |c| {
        Io.Dir.accessAbsolute(io, c, .{}) catch continue;
        return c;
    }
    return null;
}

const OutFile = struct {
    name: []u8,
    bytes: []u8,
};

const RunResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
    files: []OutFile,
};

/// Run `bin` with `args` (the tokens after the program name) inside a fresh
/// subdirectory of `parent`, then read back stdout/exit and every file the
/// tool created (everything except the "input" file we planted).
fn runTool(
    a: std.mem.Allocator,
    parent: Io.Dir,
    subdir: []const u8,
    bin: []const u8,
    content: []const u8,
    args: []const []const u8,
) !RunResult {
    try parent.createDirPath(io, subdir);
    var dir = try parent.openDir(io, subdir, .{ .iterate = true });
    defer dir.close(io);

    try dir.writeFile(io, .{ .sub_path = "input", .data = content });

    var argv = try a.alloc([]const u8, args.len + 1);
    defer a.free(argv);
    argv[0] = bin;
    for (args, 0..) |arg, i| argv[i + 1] = arg;

    const res = try std.process.run(a, io, .{
        .argv = argv,
        .cwd = .{ .dir = dir },
    });

    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };

    // Collect created output files (all entries except our planted "input").
    var files = std.ArrayListUnmanaged(OutFile).empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, "input")) continue;
        const bytes = try dir.readFileAlloc(io, entry.name, a, .unlimited);
        try files.append(a, .{ .name = try a.dupe(u8, entry.name), .bytes = bytes });
    }
    const slice = try files.toOwnedSlice(a);
    std.mem.sort(OutFile, slice, {}, struct {
        fn lt(_: void, x: OutFile, y: OutFile) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);

    return .{ .exit_code = code, .stdout = res.stdout, .stderr = res.stderr, .files = slice };
}

const Case = struct {
    name: []const u8,
    content: []const u8,
    args: []const []const u8,
    /// If non-empty, assert zcsplit's stderr contains this (pins the diagnostic).
    expect_stderr: []const u8 = "",
};

fn checkCase(a: std.mem.Allocator, gnu_bin: []const u8, zbin: []const u8, case: Case) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const g = try runTool(a, tmp.dir, "g", gnu_bin, case.content, case.args);
    const z = try runTool(a, tmp.dir, "z", zbin, case.content, case.args);

    // 1. Exit codes must match GNU exactly.
    if (g.exit_code != z.exit_code) {
        std.debug.print(
            "\n[{s}] exit mismatch: gnu={d} zcsplit={d}\n  zcsplit stderr: {s}\n",
            .{ case.name, g.exit_code, z.exit_code, z.stderr },
        );
        return error.ExitCodeMismatch;
    }

    // 2. stdout (printed byte counts) must match on success.
    //    On error GNU may have printed a partial count before aborting, which
    //    zcsplit skips by detecting the failure first — so only compare stdout
    //    when the run succeeded.
    if (g.exit_code == 0 and !std.mem.eql(u8, g.stdout, z.stdout)) {
        std.debug.print(
            "\n[{s}] stdout mismatch:\n  gnu:     {s}\n  zcsplit: {s}\n",
            .{ case.name, g.stdout, z.stdout },
        );
        return error.StdoutMismatch;
    }

    // 3. Created output files must match (names + exact bytes). On error, GNU
    //    deletes its partial output (no -k) and so does zcsplit -> both empty.
    if (g.files.len != z.files.len) {
        std.debug.print(
            "\n[{s}] file-count mismatch: gnu={d} zcsplit={d}\n",
            .{ case.name, g.files.len, z.files.len },
        );
        return error.FileCountMismatch;
    }
    for (g.files, z.files) |gf, zf| {
        if (!std.mem.eql(u8, gf.name, zf.name)) {
            std.debug.print("\n[{s}] filename mismatch: gnu={s} zcsplit={s}\n", .{ case.name, gf.name, zf.name });
            return error.FileNameMismatch;
        }
        if (!std.mem.eql(u8, gf.bytes, zf.bytes)) {
            std.debug.print(
                "\n[{s}] content mismatch in {s}:\n  gnu:     '{s}'\n  zcsplit: '{s}'\n",
                .{ case.name, gf.name, gf.bytes, zf.bytes },
            );
            return error.FileContentMismatch;
        }
    }

    // 4. Optionally pin the diagnostic text.
    if (case.expect_stderr.len > 0 and
        std.mem.indexOf(u8, z.stderr, case.expect_stderr) == null)
    {
        std.debug.print(
            "\n[{s}] stderr missing '{s}':\n  zcsplit stderr: {s}\n",
            .{ case.name, case.expect_stderr, z.stderr },
        );
        return error.StderrMismatch;
    }
}

const FIVE = "line1\nline2\nline3\nline4\nline5\n";
const ABC = "a\nb\nc\n";

const cases = [_]Case{
    // ---- success cases: exit 0, output byte-identical to GNU ----
    .{ .name = "line_number_3", .content = FIVE, .args = &.{ "input", "3" } },
    .{ .name = "line_number_5_boundary", .content = FIVE, .args = &.{ "input", "5" } },
    .{ .name = "two_line_numbers", .content = FIVE, .args = &.{ "input", "3", "5" } },
    .{ .name = "regex_match", .content = FIVE, .args = &.{ "input", "/line3/" } },
    .{ .name = "regex_offset_plus1", .content = ABC, .args = &.{ "input", "/b/+1" } },
    .{ .name = "skip_then_regex", .content = FIVE, .args = &.{ "input", "%line2%", "/line4/" } },
    .{ .name = "repeat_star", .content = FIVE, .args = &.{ "input", "/line/", "{*}" } },
    .{ .name = "prefix_flag", .content = FIVE, .args = &.{ "-f", "pre_", "input", "3" } },
    .{ .name = "digits_flag_4", .content = FIVE, .args = &.{ "-n", "4", "input", "3" } },
    .{ .name = "silent_flag", .content = FIVE, .args = &.{ "-s", "input", "3" } },
    .{ .name = "elide_empty_dup", .content = FIVE, .args = &.{ "-z", "input", "3", "3" } },

    // ---- error cases: GNU exits 1, deletes output; zcsplit must match ----
    .{ .name = "nonmatch_regex", .content = FIVE, .args = &.{ "input", "/zzz/" }, .expect_stderr = "match not found" },
    .{ .name = "line_out_of_range_100", .content = FIVE, .args = &.{ "input", "100" }, .expect_stderr = "out of range" },
    .{ .name = "line_out_of_range_6", .content = FIVE, .args = &.{ "input", "6" }, .expect_stderr = "out of range" },
    .{ .name = "invalid_pattern", .content = FIVE, .args = &.{ "input", "foo" }, .expect_stderr = "invalid pattern" },
    .{ .name = "line_zero", .content = FIVE, .args = &.{ "input", "0" }, .expect_stderr = "greater than zero" },
};

test "zcsplit matches GNU csplit across a spread of inputs and flags" {
    const gnu_bin = findGnu() orelse {
        std.debug.print("GNU csplit (gcsplit) not found; skipping parity tests\n", .{});
        return error.SkipZigTest;
    };
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zbin = try absZcsplitBin(arena);

    var failures: usize = 0;
    for (cases) |case| {
        checkCase(arena, gnu_bin, zbin, case) catch |err| {
            std.debug.print("CASE FAILED: {s} -> {s}\n", .{ case.name, @errorName(err) });
            failures += 1;
        };
    }
    if (failures != 0) return error.ParityMismatch;
}
