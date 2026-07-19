//! GNU-parity tests for zln.
//!
//! External anchor: every case runs BOTH the freshly built `zln` AND the real
//! GNU coreutils `ln` binary (Homebrew coreutils, e.g.
//! /opt/homebrew/opt/coreutils/libexec/gnubin/ln, `ln (GNU coreutils) 9.10`)
//! in two identically prepared sandboxes and compares:
//!   - exit code
//!   - stdout and stderr (program name normalized to "ln")
//!   - the resulting filesystem state of a set of probe paths
//!     (existence, file kind, symlink text, file contents)
//!
//! No roundtrip-only tests: the expected behavior always comes from the GNU
//! binary, an implementation zln's author did not write. If GNU coreutils is
//! not installed, the suite skips (it cannot self-anchor).

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;

const gnu_candidates = [_][:0]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/ln",
    "/usr/local/opt/coreutils/libexec/gnubin/ln",
    "/opt/homebrew/bin/gln",
    "/usr/local/bin/gln",
};

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn realpath(path: [*:0]const u8, resolved: ?[*]u8) ?[*:0]u8;

fn findGnuLn() ?[]const u8 {
    for (gnu_candidates) |cand| {
        if (access(cand.ptr, 1) == 0) return cand; // X_OK
    }
    return null;
}

/// The build system may hand us a cwd-relative path to the zln binary;
/// children run with a different cwd, so make it absolute once.
fn absoluteZlnPath(buf: *[4096]u8) ![]const u8 {
    var zbuf: [4096]u8 = undefined;
    const rel = build_options.zln_exe;
    if (rel.len + 1 > zbuf.len) return error.NameTooLong;
    @memcpy(zbuf[0..rel.len], rel);
    zbuf[rel.len] = 0;
    const res = realpath(zbuf[0..rel.len :0].ptr, buf) orelse return error.RealpathFailed;
    return std.mem.span(res);
}

const SetupOp = union(enum) {
    /// create a regular file with contents
    file: struct { path: []const u8, data: []const u8 },
    /// create a directory (and parents)
    dir: []const u8,
    /// create a symlink `path` whose text is `target`
    symlink: struct { target: []const u8, path: []const u8 },
    /// create a hard link `new` to existing `old`
    hardlink: struct { old: []const u8, new: []const u8 },
};

const Case = struct {
    /// arguments after the program name; identical for both binaries
    argv: []const []const u8,
    setup: []const SetupOp = &.{},
    /// bytes fed to the child's stdin (null: stdin is /dev/null)
    stdin: ?[]const u8 = null,
    /// paths (relative to each sandbox) whose resulting state must match
    probes: []const []const u8 = &.{},
};

const RunResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *RunResult, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

fn runCapture(
    gpa: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
    cwd_dir: Io.Dir,
    stdin_file: ?Io.File,
) !RunResult {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd_dir },
        .stdin = if (stdin_file) |f| .{ .file = f } else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi_reader.checkAnyError();

    const term = try child.wait(io);

    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer gpa.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);
    errdefer gpa.free(stderr_slice);

    return .{
        .exit_code = switch (term) {
            .exited => |code| code,
            else => 255,
        },
        .stdout = stdout_slice,
        .stderr = stderr_slice,
    };
}

fn applySetup(io: Io, dir: Io.Dir, ops: []const SetupOp) !void {
    for (ops) |op| switch (op) {
        .file => |f| try dir.writeFile(io, .{ .sub_path = f.path, .data = f.data }),
        .dir => |d| try dir.createDirPath(io, d),
        .symlink => |s| try dir.symLink(io, s.target, s.path, .{}),
        .hardlink => |h| try dir.hardLink(h.old, dir, h.new, io, .{}),
    };
}

/// Render the state of `path` inside `dir` as a comparable string.
fn describeProbe(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, path: []const u8) ![]u8 {
    const st = dir.statFile(io, path, .{ .follow_symlinks = false }) catch {
        return gpa.dupe(u8, "absent");
    };
    switch (st.kind) {
        .sym_link => {
            var buf: [4096]u8 = undefined;
            const n = try dir.readLink(io, path, &buf);
            return std.fmt.allocPrint(gpa, "symlink -> {s}", .{buf[0..n]});
        },
        .directory => return gpa.dupe(u8, "dir"),
        .file => {
            const data = try dir.readFileAlloc(io, path, gpa, .limited(1 << 20));
            defer gpa.free(data);
            return std.fmt.allocPrint(gpa, "file: {s}", .{data});
        },
        else => return std.fmt.allocPrint(gpa, "kind: {s}", .{@tagName(st.kind)}),
    }
}

/// Normalize program identity in output: the GNU binary prints "ln:" or its
/// full invocation path; zln prints "zln". Map both to "ln".
fn normalize(gpa: std.mem.Allocator, s: []const u8, bin_path: []const u8) ![]u8 {
    const pass1 = try std.mem.replaceOwned(u8, gpa, s, bin_path, "ln");
    defer gpa.free(pass1);
    return std.mem.replaceOwned(u8, gpa, pass1, "zln", "ln");
}

fn runCase(case: Case) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const gnu_ln = findGnuLn() orelse return error.SkipZigTest;

    var zln_buf: [4096]u8 = undefined;
    const zln_exe = try absoluteZlnPath(&zln_buf);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var gnu_dir = try tmp.dir.createDirPathOpen(io, "gnu", .{});
    defer gnu_dir.close(io);
    var zig_dir = try tmp.dir.createDirPathOpen(io, "zig", .{});
    defer zig_dir.close(io);

    try applySetup(io, gnu_dir, case.setup);
    try applySetup(io, zig_dir, case.setup);

    if (case.stdin) |data| {
        try tmp.dir.writeFile(io, .{ .sub_path = "stdin.txt", .data = data });
    }

    var results: [2]RunResult = undefined;
    const bins = [2][]const u8{ gnu_ln, zln_exe };
    const dirs = [2]Io.Dir{ gnu_dir, zig_dir };
    for (bins, dirs, 0..) |bin, dir, idx| {
        var argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.append(gpa, bin);
        try argv.appendSlice(gpa, case.argv);

        var stdin_file: ?Io.File = null;
        if (case.stdin != null) {
            stdin_file = try tmp.dir.openFile(io, "stdin.txt", .{});
        }
        defer if (stdin_file) |f| f.close(io);

        results[idx] = try runCapture(gpa, io, argv.items, dir, stdin_file);
    }
    defer results[0].deinit(gpa);
    defer results[1].deinit(gpa);

    // exit codes must match
    try std.testing.expectEqual(results[0].exit_code, results[1].exit_code);

    // normalized stdout / stderr must match byte-for-byte
    inline for (.{ "stdout", "stderr" }) |stream| {
        const gnu_out = try normalize(gpa, @field(results[0], stream), gnu_ln);
        defer gpa.free(gnu_out);
        const zln_out = try normalize(gpa, @field(results[1], stream), zln_exe);
        defer gpa.free(zln_out);
        try std.testing.expectEqualStrings(gnu_out, zln_out);
    }

    // filesystem end-state of the probes must match
    for (case.probes) |probe| {
        const gnu_state = try describeProbe(gpa, io, gnu_dir, probe);
        defer gpa.free(gnu_state);
        const zln_state = try describeProbe(gpa, io, zig_dir, probe);
        defer gpa.free(zln_state);
        try std.testing.expectEqualStrings(gnu_state, zln_state);
    }
}

// ---------------------------------------------------------------------------
// Critical: -f must never destroy the destination when the link cannot succeed
// ---------------------------------------------------------------------------

test "force same file: ln -f f.txt f.txt preserves f.txt and errors" {
    try runCase(.{
        .argv = &.{ "-f", "f.txt", "f.txt" },
        .setup = &.{.{ .file = .{ .path = "f.txt", .data = "data\n" } }},
        .probes = &.{"f.txt"},
    });
}

test "force symbolic same file: ln -sf x x preserves x and errors" {
    try runCase(.{
        .argv = &.{ "-sf", "x", "x" },
        .setup = &.{.{ .file = .{ .path = "x", .data = "hi\n" } }},
        .probes = &.{"x"},
    });
}

test "force with unlinkable target: ln -f /dev/null dest preserves dest" {
    try runCase(.{
        .argv = &.{ "-f", "/dev/null", "dest" },
        .setup = &.{.{ .file = .{ .path = "dest", .data = "keep\n" } }},
        .probes = &.{"dest"},
    });
}

test "force with missing target: dest preserved, 'failed to access' diagnostic" {
    try runCase(.{
        .argv = &.{ "-f", "nothere", "dest" },
        .setup = &.{.{ .file = .{ .path = "dest", .data = "keep3\n" } }},
        .probes = &.{"dest"},
    });
}

// ---------------------------------------------------------------------------
// High: -n/--no-dereference (the atomic-switch deploy idiom)
// ---------------------------------------------------------------------------

test "-sfn replaces a symlink-to-directory instead of descending into it" {
    try runCase(.{
        .argv = &.{ "-sfn", "release-v2", "cur" },
        .setup = &.{
            .{ .dir = "release-v1" },
            .{ .dir = "release-v2" },
            .{ .symlink = .{ .target = "release-v1", .path = "cur" } },
        },
        .probes = &.{ "cur", "release-v1/release-v2" },
    });
}

test "-sfn with a real directory destination still links inside it" {
    try runCase(.{
        .argv = &.{ "-sfn", "t", "realdir" },
        .setup = &.{
            .{ .file = .{ .path = "t", .data = "t\n" } },
            .{ .dir = "realdir" },
        },
        .probes = &.{ "realdir", "realdir/t" },
    });
}

test "without -n, -sf descends into the symlinked directory (GNU behavior)" {
    try runCase(.{
        .argv = &.{ "-sf", "release-v2", "cur" },
        .setup = &.{
            .{ .dir = "release-v1" },
            .{ .dir = "release-v2" },
            .{ .symlink = .{ .target = "release-v1", .path = "cur" } },
        },
        .probes = &.{ "cur", "release-v1/release-v2" },
    });
}

// ---------------------------------------------------------------------------
// High: dangling symlink destination must be replaced by -sf
// ---------------------------------------------------------------------------

test "-sf replaces a dangling symlink destination" {
    try runCase(.{
        .argv = &.{ "-sf", "real", "lk" },
        .setup = &.{
            .{ .file = .{ .path = "real", .data = "r\n" } },
            .{ .symlink = .{ .target = "/nonexistent", .path = "lk" } },
        },
        .probes = &.{"lk"},
    });
}

// ---------------------------------------------------------------------------
// Medium: -r without -s must error, not silently hard-link
// ---------------------------------------------------------------------------

test "-r without -s errors 'cannot do --relative without --symbolic'" {
    try runCase(.{
        .argv = &.{ "-r", "a", "b" },
        .setup = &.{.{ .file = .{ .path = "a", .data = "a\n" } }},
        .probes = &.{"b"},
    });
}

test "-t combined with -T errors" {
    try runCase(.{
        .argv = &.{ "-T", "-t", "d", "a" },
        .setup = &.{
            .{ .dir = "d" },
            .{ .file = .{ .path = "a", .data = "a\n" } },
        },
        .probes = &.{"d/a"},
    });
}

// ---------------------------------------------------------------------------
// Medium: one-operand form
// ---------------------------------------------------------------------------

test "one-operand symbolic: ln -s ABS creates ./basename" {
    try runCase(.{
        .argv = &.{ "-s", "/usr/bin/true" },
        .probes = &.{"true"},
    });
}

test "one-operand hard: ln sub/t.txt creates ./t.txt" {
    try runCase(.{
        .argv = &.{"sub/t.txt"},
        .setup = &.{
            .{ .dir = "sub" },
            .{ .file = .{ .path = "sub/t.txt", .data = "t\n" } },
        },
        .probes = &.{"t.txt"},
    });
}

test "one-operand verbose prints ./name like GNU" {
    try runCase(.{
        .argv = &.{ "-sv", "/usr/bin/true" },
        .probes = &.{"true"},
    });
}

// ---------------------------------------------------------------------------
// Low: relative path canonicalization
// ---------------------------------------------------------------------------

test "-sr canonicalizes '.' and '..' components (GNU emits a/b/f)" {
    try runCase(.{
        .argv = &.{ "-sr", "a/./b/../b/f", "lk2" },
        .setup = &.{
            .{ .dir = "a/b" },
            .{ .file = .{ .path = "a/b/f", .data = "f\n" } },
        },
        .probes = &.{"lk2"},
    });
}

test "-sr computes up-dir relative links" {
    try runCase(.{
        .argv = &.{ "-sr", "x", "p/q/lx" },
        .setup = &.{
            .{ .file = .{ .path = "x", .data = "x\n" } },
            .{ .dir = "p/q" },
        },
        .probes = &.{"p/q/lx"},
    });
}

// ---------------------------------------------------------------------------
// Low: interactive semantics
// ---------------------------------------------------------------------------

test "interactive decline exits 1 and keeps destination" {
    try runCase(.{
        .argv = &.{ "-i", "t", "d" },
        .setup = &.{
            .{ .file = .{ .path = "t", .data = "t\n" } },
            .{ .file = .{ .path = "d", .data = "old\n" } },
        },
        .stdin = "n\n",
        .probes = &.{"d"},
    });
}

test "interactive accept replaces destination" {
    try runCase(.{
        .argv = &.{ "-si", "t", "d" },
        .setup = &.{
            .{ .file = .{ .path = "t", .data = "t\n" } },
            .{ .file = .{ .path = "d", .data = "old\n" } },
        },
        .stdin = "y\n",
        .probes = &.{"d"},
    });
}

test "-i then -f: force wins (last flag), no prompt" {
    // stdin is /dev/null: if zln wrongly prompted, it would read EOF, decline
    // and exit 1 — GNU replaces silently with exit 0.
    try runCase(.{
        .argv = &.{ "-i", "-f", "t", "d" },
        .setup = &.{
            .{ .file = .{ .path = "t", .data = "t\n" } },
            .{ .file = .{ .path = "d", .data = "old\n" } },
        },
        .probes = &.{"d"},
    });
}

test "-f then -i: interactive wins, decline exits 1" {
    try runCase(.{
        .argv = &.{ "-f", "-i", "t", "d" },
        .setup = &.{
            .{ .file = .{ .path = "t", .data = "t\n" } },
            .{ .file = .{ .path = "d", .data = "old\n" } },
        },
        .stdin = "n\n",
        .probes = &.{"d"},
    });
}

// ---------------------------------------------------------------------------
// Diagnostics parity
// ---------------------------------------------------------------------------

test "hard link EEXIST diagnostic (no '=> target' part)" {
    try runCase(.{
        .argv = &.{ "A", "B" },
        .setup = &.{
            .{ .file = .{ .path = "A", .data = "a\n" } },
            .{ .file = .{ .path = "B", .data = "b\n" } },
        },
        .probes = &.{ "A", "B" },
    });
}

test "symlink EEXIST diagnostic" {
    try runCase(.{
        .argv = &.{ "-s", "A", "B" },
        .setup = &.{
            .{ .file = .{ .path = "A", .data = "a\n" } },
            .{ .file = .{ .path = "B", .data = "b\n" } },
        },
        .probes = &.{"B"},
    });
}

test "-sfT onto a real directory: cannot overwrite directory" {
    try runCase(.{
        .argv = &.{ "-sfT", "t", "d" },
        .setup = &.{
            .{ .file = .{ .path = "t", .data = "t\n" } },
            .{ .dir = "d" },
        },
        .probes = &.{"d"},
    });
}

test "hard link to a directory is refused" {
    try runCase(.{
        .argv = &.{ "dirx", "h" },
        .setup = &.{.{ .dir = "dirx" }},
        .probes = &.{"h"},
    });
}

test "multi-source destination that is not a directory" {
    try runCase(.{
        .argv = &.{ "u", "v", "w" },
        .setup = &.{
            .{ .file = .{ .path = "u", .data = "u\n" } },
            .{ .file = .{ .path = "v", .data = "v\n" } },
            .{ .file = .{ .path = "w", .data = "w\n" } },
        },
        .probes = &.{"w"},
    });
}

test "-t with a non-directory target" {
    try runCase(.{
        .argv = &.{ "-t", "t", "u" },
        .setup = &.{
            .{ .file = .{ .path = "t", .data = "t\n" } },
            .{ .file = .{ .path = "u", .data = "u\n" } },
        },
        .probes = &.{ "t", "u" },
    });
}

test "missing operand and Try-help line" {
    try runCase(.{ .argv = &.{} });
}

test "unrecognized long option" {
    try runCase(.{ .argv = &.{"--frobnicate"} });
}

test "invalid short option" {
    try runCase(.{ .argv = &.{"-z"} });
}

// ---------------------------------------------------------------------------
// Flag mechanics & misc parity
// ---------------------------------------------------------------------------

test "attached short-option value -tDIR" {
    try runCase(.{
        .argv = &.{ "-s", "-tdd", "x" },
        .setup = &.{
            .{ .dir = "dd" },
            .{ .file = .{ .path = "x", .data = "x\n" } },
        },
        .probes = &.{"dd/x"},
    });
}

test "verbose symlink and target-directory naming" {
    try runCase(.{
        .argv = &.{ "-sv", "-t", "dd", "x" },
        .setup = &.{
            .{ .dir = "dd" },
            .{ .file = .{ .path = "x", .data = "x\n" } },
        },
        .probes = &.{"dd/x"},
    });
}

test "verbose hard link output format" {
    try runCase(.{
        .argv = &.{ "-v", "t", "vh" },
        .setup = &.{.{ .file = .{ .path = "t", .data = "t\n" } }},
        .probes = &.{"vh"},
    });
}

test "-f onto an existing hard link of the same inode succeeds" {
    try runCase(.{
        .argv = &.{ "-f", "x", "y" },
        .setup = &.{
            .{ .file = .{ .path = "x", .data = "x\n" } },
            .{ .hardlink = .{ .old = "x", .new = "y" } },
        },
        .probes = &.{ "x", "y" },
    });
}

test "-sf replaces a hard link of the target with a symlink" {
    try runCase(.{
        .argv = &.{ "-sf", "x", "y" },
        .setup = &.{
            .{ .file = .{ .path = "x", .data = "x\n" } },
            .{ .hardlink = .{ .old = "x", .new = "y" } },
        },
        .probes = &.{ "x", "y" },
    });
}

test "hard link to a dangling symlink: failed to access" {
    try runCase(.{
        .argv = &.{ "dl", "hd" },
        .setup = &.{.{ .symlink = .{ .target = "/nonexistent", .path = "dl" } }},
        .probes = &.{"hd"},
    });
}

test "hard link dereferences a good symlink target like GNU" {
    try runCase(.{
        .argv = &.{ "gs", "hs" },
        .setup = &.{
            .{ .file = .{ .path = "x", .data = "x\n" } },
            .{ .symlink = .{ .target = "x", .path = "gs" } },
        },
        .probes = &.{"hs"},
    });
}

test "-s allows creating a dangling symlink" {
    try runCase(.{
        .argv = &.{ "-s", "nothere", "dangle" },
        .probes = &.{"dangle"},
    });
}

test "-T with one operand: missing destination diagnostic" {
    try runCase(.{
        .argv = &.{ "-T", "x" },
        .setup = &.{.{ .file = .{ .path = "x", .data = "x\n" } }},
    });
}

test "-T with three operands: extra operand diagnostic" {
    try runCase(.{
        .argv = &.{ "-T", "a", "b", "c" },
        .setup = &.{
            .{ .file = .{ .path = "a", .data = "a\n" } },
        },
    });
}

test "multiple sources into a directory" {
    try runCase(.{
        .argv = &.{ "-s", "u", "v", "dd" },
        .setup = &.{
            .{ .file = .{ .path = "u", .data = "u\n" } },
            .{ .file = .{ .path = "v", .data = "v\n" } },
            .{ .dir = "dd" },
        },
        .probes = &.{ "dd/u", "dd/v" },
    });
}
