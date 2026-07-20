//! Externally-anchored GNU parity tests for znohup (GNU `nohup`).
//!
//! Primary anchor: the real GNU coreutils `nohup` binary (9.x, homebrew
//! gnubin / gnohup). Every parity case runs BOTH binaries with the same argv
//! and compares stdout, exit code, and — where the message is program-name
//! independent — a stderr substring. None of the expected values are produced
//! by znohup itself.
//!
//! Note on the tty path: under this test runner stdin/stdout/stderr are pipes,
//! never terminals, so nohup's `nohup.out` redirect + "appending output"
//! diagnostics do not fire. Those are exercised only structurally (the code is
//! fixed per the audit) and left to manual `script`-based verification; the
//! automated anchors here cover the exec/exit/option surface that IS reachable
//! without a controlling terminal.
//!
//! Secondary anchor: literal-expected cases whose bytes are transcribed from
//! GNU nohup's documented diagnostics (coreutils src/nohup.c and the POSIX
//! nohup spec), with only the program name substituted. These assert real
//! bytes even if no GNU binary is installed.
//!
//! Run via `zig build test`.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

fn resolveExe(arena: std.mem.Allocator, io: Io) ![]const u8 {
    const configured: []const u8 = build_options.znohup_exe;
    if (std.fs.path.isAbsolute(configured)) return configured;
    return try Io.Dir.cwd().realPathFileAlloc(io, configured, arena);
}

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/nohup",
    "/opt/homebrew/bin/gnohup",
    "/usr/local/opt/coreutils/libexec/gnubin/nohup",
    "/usr/local/bin/gnohup",
};

fn findGnuNohup(io: Io) ?[]const u8 {
    for (gnu_candidates) |path| {
        const f = Io.Dir.openFile(Io.Dir.cwd(), io, path, .{}) catch continue;
        f.close(io);
        return path;
    }
    if (@import("builtin").os.tag == .linux) {
        const f = Io.Dir.openFile(Io.Dir.cwd(), io, "/usr/bin/nohup", .{}) catch return null;
        f.close(io);
        return "/usr/bin/nohup";
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
    cwd: Io.Dir,
) !RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.append(arena, exe);
    for (args) |a| try argv.append(arena, a);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .dir = cwd },
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

const Case = struct {
    name: []const u8,
    args: []const []const u8,
    /// Compare full stdout bytes against GNU (true for successful exec cases).
    compare_stdout: bool = true,
    /// A substring GNU emits on stderr that is program-name independent
    /// (a strerror phrase or literal token). Checked on znohup's stderr too.
    stderr_needle: ?[]const u8 = null,
    expect_exit: u8 = 0,
};

// `.` and `..` are not commands; use absolute paths so execvp does not walk
// PATH for the negative cases (keeps them deterministic across machines).
const parity_cases = [_]Case{
    // Successful exec: stdout must byte-match GNU's (both just exec the child).
    .{ .name = "plain command exec", .args = &.{ "/bin/echo", "hello", "world" } },
    // `--` end-of-options terminator (audit medium): GNU consumes it, runs echo.
    .{ .name = "-- terminator then command", .args = &.{ "--", "/bin/echo", "hi" } },
    // A command whose first arg looks like an option, guarded by `--`.
    .{ .name = "-- guards an option-like command name", .args = &.{ "--", "/bin/echo", "--version" } },
    // Command not found -> errno ENOENT -> exit 127 + strerror tail (audit low).
    .{
        .name = "not found exits 127 with strerror",
        .args = &.{"/nonexistent_znohup_xyz"},
        .compare_stdout = true, // both empty
        .stderr_needle = "No such file or directory",
        .expect_exit = 127,
    },
    // Missing operand -> exit 125 (audit low: the "Try ... --help" hint line).
    .{
        .name = "missing operand exits 125 with hint",
        .args = &.{},
        .stderr_needle = "missing operand",
        .expect_exit = 125,
    },
    // --version -> exit 0 (audit medium). stdout text is intentionally NOT
    // byte-identical to GNU (different project), so only the exit code anchors.
    .{ .name = "--version exits 0", .args = &.{"--version"}, .compare_stdout = false, .expect_exit = 0 },
    // --help -> exit 0.
    .{ .name = "--help exits 0", .args = &.{"--help"}, .compare_stdout = false, .expect_exit = 0 },
};

test "GNU parity: stdout, exit codes, and strerror tails match real GNU nohup" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const exe = try resolveExe(arena, io);
    const gnu = findGnuNohup(io) orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var failures: usize = 0;
    for (parity_cases) |case| {
        const z = try runTool(arena, io, exe, case.args, tmp.dir);
        const g = try runTool(arena, io, gnu, case.args, tmp.dir);

        if (case.compare_stdout and !std.mem.eql(u8, z.stdout, g.stdout)) {
            std.debug.print("FAIL [{s}]: stdout differs\n  znohup: {s}\n  gnu:    {s}\n", .{
                case.name, z.stdout, g.stdout,
            });
            failures += 1;
            continue;
        }
        if (z.exit_code != g.exit_code) {
            std.debug.print("FAIL [{s}]: exit code znohup={d} gnu={d}\n", .{ case.name, z.exit_code, g.exit_code });
            failures += 1;
            continue;
        }
        if (g.exit_code != case.expect_exit) {
            std.debug.print("FAIL [{s}]: stale expectation — GNU exited {d}, expected {d}\n", .{
                case.name, g.exit_code, case.expect_exit,
            });
            failures += 1;
            continue;
        }
        if (case.stderr_needle) |needle| {
            if (std.mem.indexOf(u8, g.stderr, needle) == null) {
                std.debug.print("FAIL [{s}]: needle '{s}' absent from GNU stderr (stale) — got: {s}\n", .{
                    case.name, needle, g.stderr,
                });
                failures += 1;
                continue;
            }
            if (std.mem.indexOf(u8, z.stderr, needle) == null) {
                std.debug.print("FAIL [{s}]: needle '{s}' absent from znohup stderr — got: {s}\n", .{
                    case.name, needle, z.stderr,
                });
                failures += 1;
                continue;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "GNU parity: non-executable file exits 126 (found but not invocable)" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const exe = try resolveExe(arena, io);
    const gnu = findGnuNohup(io) orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A regular file with no execute bit (writeFile creates 0o666&~umask, so
    // no execute bit is ever set). execvp -> EACCES -> exit 126.
    try tmp.dir.writeFile(io, .{ .sub_path = "noexec", .data = "not a program\n" });
    const abs = try tmp.dir.realPathFileAlloc(io, "noexec", arena);

    const z = try runTool(arena, io, exe, &.{abs}, tmp.dir);
    const g = try runTool(arena, io, gnu, &.{abs}, tmp.dir);

    try std.testing.expectEqual(g.exit_code, z.exit_code);
    try std.testing.expectEqual(@as(u8, 126), g.exit_code);
    // Both must report the EACCES strerror text.
    try std.testing.expect(std.mem.indexOf(u8, g.stderr, "Permission denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, z.stderr, "Permission denied") != null);
}

// Literal-expected anchors, independent of an installed GNU binary. Bytes are
// transcribed from GNU nohup's documented diagnostics (coreutils src/nohup.c),
// with only the program name substituted ("znohup" for "nohup"/"gnohup").
test "literal anchors: documented GNU nohup diagnostics" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const exe = try resolveExe(arena, io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // GNU nohup with no operand:
    //   nohup: missing operand
    //   Try 'PROG --help' for more information.
    // and exits 125 (coreutils src/nohup.c usage(EXIT_CANCELED=125)).
    {
        const r = try runTool(arena, io, exe, &.{}, tmp.dir);
        try std.testing.expectEqual(@as(u8, 125), r.exit_code);
        try std.testing.expectEqualStrings(
            "znohup: missing operand\nTry 'znohup --help' for more information.\n",
            r.stderr,
        );
    }

    // GNU nohup on a missing command:
    //   nohup: failed to run command 'X': No such file or directory
    // and exits 127 (EXIT_ENOENT). We assert the full znohup line shape with
    // the strerror(ENOENT) tail GNU also appends.
    {
        const r = try runTool(arena, io, exe, &.{"/no/such/znohup/cmd"}, tmp.dir);
        try std.testing.expectEqual(@as(u8, 127), r.exit_code);
        try std.testing.expectEqualStrings(
            "znohup: failed to run command '/no/such/znohup/cmd': No such file or directory\n",
            r.stderr,
        );
    }
}

// Regression anchor for the HIGH stack-overflow finding (main.zig:133-135):
// a command name >= 4096 bytes previously overran a fixed stack buffer via an
// unbounded @memcpy. The fix removed that buffer entirely (errno-based exit),
// so an over-long name must now exit cleanly with 127 (ENOENT), not SIGABRT.
test "no stack overflow on a >4KB command name" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const exe = try resolveExe(arena, io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const long_name = try arena.alloc(u8, 6000);
    @memset(long_name, 'a');

    const r = try runTool(arena, io, exe, &.{long_name}, tmp.dir);
    // Must NOT abort (134 = 128+SIGABRT). A 6000-char relative name is not
    // found on PATH -> ENOENT -> 127.
    try std.testing.expect(r.exit_code != 134);
    try std.testing.expectEqual(@as(u8, 127), r.exit_code);
}
