//! Externally-anchored GNU parity tests for zchroot.
//!
//! Primary anchor: the real GNU coreutils `chroot` binary (9.x, installed as
//! `gchroot` via Homebrew, or `chroot` on the gnubin path). Every parity case
//! runs BOTH binaries with the same argv and compares the exit code plus the
//! program-name-normalized stderr. None of the expected outputs are produced
//! by zchroot itself — this is a true external anchor.
//!
//! Scope note: `chroot(2)` requires root, so the successful drop-privileges
//! path (setgroups/setgid/setuid ordering, name resolution) cannot be
//! exercised as an unprivileged test user — for every case here chroot fails
//! first with EPERM, exactly as it does for the real GNU binary. What these
//! tests DO pin externally: argument parsing, option diagnostics, exit codes,
//! the `--` / NEWROOT capture fix, `--version`, and the strerror-based chroot
//! error wording.
//!
//! Secondary anchor: literal-expected cases whose bytes are transcribed from
//! GNU chroot's observed output (coreutils 9.10), so the suite still asserts
//! real documented bytes when no GNU binary is installed.
//!
//! Run via `zig build test`.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

fn resolveZchrootExe(arena: std.mem.Allocator, io: Io) ![]const u8 {
    const configured: []const u8 = build_options.zchroot_exe;
    if (std.fs.path.isAbsolute(configured)) return configured;
    return try Io.Dir.cwd().realPathFileAlloc(io, configured, arena);
}

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/chroot",
    "/opt/homebrew/bin/gchroot",
    "/usr/local/opt/coreutils/libexec/gnubin/chroot",
    "/usr/local/bin/gchroot",
};

fn findGnuChroot(io: Io) ?[]const u8 {
    for (gnu_candidates) |path| {
        const f = Io.Dir.openFile(Io.Dir.cwd(), io, path, .{}) catch continue;
        f.close(io);
        return path;
    }
    if (@import("builtin").os.tag == .linux) {
        const f = Io.Dir.openFile(Io.Dir.cwd(), io, "/usr/sbin/chroot", .{}) catch {
            const g = Io.Dir.openFile(Io.Dir.cwd(), io, "/usr/bin/chroot", .{}) catch return null;
            g.close(io);
            return "/usr/bin/chroot";
        };
        f.close(io);
        return "/usr/sbin/chroot";
    }
    return null;
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

fn runTool(
    arena: std.mem.Allocator,
    io: Io,
    exe: []const u8,
    args: []const []const u8,
) !RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.append(arena, exe);
    for (args) |a| try argv.append(arena, a);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(arena, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    while (multi_reader.fill(4096, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi_reader.checkAnyError();

    const term = try child.wait(io);
    const stdout = try multi_reader.toOwnedSlice(0);
    const stderr = try multi_reader.toOwnedSlice(1);

    return .{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = switch (term) {
            .exited => |code| code,
            else => 255,
        },
    };
}

/// Replace every occurrence of the tool's own invocation path and its
/// basename with the placeholder "PROG", so the two binaries' diagnostics can
/// be byte-compared despite differing program names (gchroot vs zchroot).
fn normalizeProg(arena: std.mem.Allocator, text: []const u8, invocation: []const u8) ![]u8 {
    const base = std.fs.path.basename(invocation);
    // Replace the longer (full path) first to avoid partial overlap.
    const step1 = try std.mem.replaceOwned(u8, arena, text, invocation, "PROG");
    return try std.mem.replaceOwned(u8, arena, step1, base, "PROG");
}

const Case = struct {
    name: []const u8,
    args: []const []const u8,
    expect_exit: u8,
    /// When true, stdout differs by design (e.g. version strings) so only the
    /// exit code is compared, not stderr/stdout bytes.
    exit_only: bool = false,
};

const parity_cases = [_]Case{
    .{ .name = "missing operand", .args = &.{}, .expect_exit = 125 },
    .{ .name = "-- alone is still missing operand", .args = &.{"--"}, .expect_exit = 125 },
    .{ .name = "unrecognized long option", .args = &.{"--bogus"}, .expect_exit = 125 },
    .{ .name = "invalid short option (getopt form)", .args = &.{ "-z", "/x" }, .expect_exit = 125 },
    .{ .name = "chroot failure uses strerror(errno)", .args = &.{ "/nonexist", "/bin/echo", "hi" }, .expect_exit = 125 },
    // Regression anchor: `--` must NOT swallow NEWROOT (audit medium finding).
    .{ .name = "-- then NEWROOT is captured (not missing operand)", .args = &.{ "--", "/nonexist", "/bin/echo", "hi" }, .expect_exit = 125 },
    // NEWROOT "/" satisfies GNU's is-root precondition for --skip-chdir, so
    // both binaries proceed to chroot("/") and fail with the same EPERM.
    // (zchroot does not yet reproduce GNU's rejection of --skip-chdir with a
    // non-root NEWROOT — that unaudited is_root() gate is tracked separately.)
    .{ .name = "--skip-chdir / still runs chroot", .args = &.{ "--skip-chdir", "/", "cmd" }, .expect_exit = 125 },
    // chroot happens before the userspec/groups drop, so as non-root these all
    // surface the chroot EPERM (matching GNU ordering) rather than a user/group
    // resolution error.
    .{ .name = "--userspec numeric: chroot fails first", .args = &.{ "--userspec=1000:1000", "/nonexist", "cmd" }, .expect_exit = 125 },
    .{ .name = "--groups numeric: chroot fails first", .args = &.{ "--groups=1,2,3", "/nonexist", "cmd" }, .expect_exit = 125 },
    // --version prints version text and exits 0 (audit finding: was exit 125).
    .{ .name = "--version exits 0", .args = &.{"--version"}, .expect_exit = 0, .exit_only = true },
    // --help exits 0.
    .{ .name = "--help exits 0", .args = &.{"--help"}, .expect_exit = 0, .exit_only = true },
};

test "GNU parity: exit codes and normalized stderr match the real GNU chroot" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const z_exe = try resolveZchrootExe(arena, io);
    const gnu = findGnuChroot(io) orelse return error.SkipZigTest;

    var failures: usize = 0;
    for (parity_cases) |case| {
        const z = try runTool(arena, io, z_exe, case.args);
        const g = try runTool(arena, io, gnu, case.args);

        if (g.exit_code != case.expect_exit) {
            std.debug.print("FAIL [{s}]: GNU itself exited {d}, expected {d} (stale test)\n", .{
                case.name, g.exit_code, case.expect_exit,
            });
            failures += 1;
            continue;
        }
        if (z.exit_code != g.exit_code) {
            std.debug.print("FAIL [{s}]: exit z={d} gnu={d}\n", .{ case.name, z.exit_code, g.exit_code });
            failures += 1;
            continue;
        }
        if (case.exit_only) continue;

        const zn = try normalizeProg(arena, z.stderr, z_exe);
        const gn = try normalizeProg(arena, g.stderr, gnu);
        if (!std.mem.eql(u8, zn, gn)) {
            std.debug.print("FAIL [{s}]: stderr differs\n  z:  {s}\n  gnu:{s}\n", .{ case.name, zn, gn });
            failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

// Literal-expected anchors, independent of an installed GNU binary. Bytes
// transcribed from GNU coreutils 9.10 `chroot` observed output; the "PROG"
// placeholder stands in for the program name.
test "literal anchors: documented GNU chroot diagnostics and exit codes" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const z_exe = try resolveZchrootExe(arena, io);

    const LiteralCase = struct {
        name: []const u8,
        args: []const []const u8,
        expected_stderr: []const u8,
        expect_exit: u8,
    };
    const cases = [_]LiteralCase{
        // GNU: "chroot: missing operand\nTry 'chroot --help' for more information.\n"
        .{
            .name = "missing operand",
            .args = &.{},
            .expected_stderr = "PROG: missing operand\nTry 'PROG --help' for more information.\n",
            .expect_exit = 125,
        },
        // GNU: unrecognized long option, then the Try line.
        .{
            .name = "unrecognized long option",
            .args = &.{"--bogus"},
            .expected_stderr = "PROG: unrecognized option '--bogus'\nTry 'PROG --help' for more information.\n",
            .expect_exit = 125,
        },
        // GNU getopt: "chroot: invalid option -- 'z'"
        .{
            .name = "invalid short option",
            .args = &.{ "-z", "/x" },
            .expected_stderr = "PROG: invalid option -- 'z'\nTry 'PROG --help' for more information.\n",
            .expect_exit = 125,
        },
        // GNU: "chroot: cannot change root directory to '/nonexist': Operation not permitted"
        // (unprivileged: EPERM). The audit's bug was a hard-coded string that
        // ignored errno AND used non-GNU wording ("cannot chroot to").
        .{
            .name = "chroot failure wording + strerror",
            .args = &.{ "/nonexist", "cmd" },
            .expected_stderr = "PROG: cannot change root directory to '/nonexist': Operation not permitted\n",
            .expect_exit = 125,
        },
        // Regression: `--` must not consume NEWROOT — same chroot error as above.
        .{
            .name = "-- does not swallow NEWROOT",
            .args = &.{ "--", "/nonexist", "cmd" },
            .expected_stderr = "PROG: cannot change root directory to '/nonexist': Operation not permitted\n",
            .expect_exit = 125,
        },
    };

    for (cases) |case| {
        const r = try runTool(arena, io, z_exe, case.args);
        try std.testing.expectEqual(case.expect_exit, r.exit_code);
        const norm = try normalizeProg(arena, r.stderr, z_exe);
        std.testing.expectEqualStrings(case.expected_stderr, norm) catch |err| {
            std.debug.print("literal anchor failed: {s}\n", .{case.name});
            return err;
        };
    }
}

// --version must emit non-empty version text on stdout and exit 0 (the audit
// finding: it previously printed "invalid option '--version'" and exited 125).
test "literal anchor: --version writes stdout and exits 0" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const z_exe = try resolveZchrootExe(arena, io);
    const r = try runTool(arena, io, z_exe, &.{"--version"});
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    try std.testing.expect(r.stdout.len > 0);
    try std.testing.expectEqual(@as(usize, 0), r.stderr.len);
    // Must NOT be the old error text.
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "invalid option") == null);
}
