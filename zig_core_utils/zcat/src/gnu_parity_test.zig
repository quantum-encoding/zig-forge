//! Externally-anchored GNU parity tests for zcat.
//!
//! Primary anchor: the real GNU coreutils `cat` binary (9.x). Every parity
//! case runs BOTH binaries on the same fixture bytes and byte-compares stdout
//! plus the exit code. This is a true external anchor — none of the expected
//! outputs are produced by zcat itself.
//!
//! Secondary anchor: a handful of literal-expected cases whose bytes are
//! transcribed from GNU cat's documented behavior (coreutils cat.c and the
//! POSIX cat spec), so the suite still asserts real bytes if no GNU binary
//! is installed.
//!
//! Run via `zig build test`.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

/// May be relative to the build root (the test runner's cwd); children run
/// with cwd set to a fixture tmp dir, so resolve it to an absolute path first.
fn resolveZcatExe(arena: std.mem.Allocator, io: Io) ![]const u8 {
    const configured: []const u8 = build_options.zcat_exe;
    if (std.fs.path.isAbsolute(configured)) return configured;
    return try Io.Dir.cwd().realPathFileAlloc(io, configured, arena);
}

/// Locations where a GNU coreutils `cat` may live. The audit reference is
/// the homebrew coreutils gnubin path; /usr/bin/cat is GNU on Linux.
const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/cat",
    "/opt/homebrew/bin/gcat",
    "/usr/local/opt/coreutils/libexec/gnubin/cat",
    "/usr/local/bin/gcat",
};

fn findGnuCat(io: Io) ?[]const u8 {
    for (gnu_candidates) |path| {
        const f = Io.Dir.openFile(Io.Dir.cwd(), io, path, .{}) catch continue;
        f.close(io);
        return path;
    }
    if (@import("builtin").os.tag == .linux) {
        // On Linux /usr/bin/cat is GNU coreutils.
        const f = Io.Dir.openFile(Io.Dir.cwd(), io, "/usr/bin/cat", .{}) catch return null;
        f.close(io);
        return "/usr/bin/cat";
    }
    return null;
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

/// Spawn `exe` with `flag_args` + `file_args`, cwd set to the fixture dir,
/// optionally feeding `stdin_fixture` (a fixture filename) as stdin.
fn runTool(
    arena: std.mem.Allocator,
    io: Io,
    exe: []const u8,
    case: Case,
    fixture_dir: Io.Dir,
) !RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.append(arena, exe);
    for (case.args) |a| try argv.append(arena, a);

    const stdin_file: ?Io.File = if (case.stdin_fixture) |name|
        try fixture_dir.openFile(io, name, .{})
    else
        null;
    defer if (stdin_file) |f| f.close(io);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .dir = fixture_dir },
        .stdin = if (stdin_file) |f| .{ .file = f } else .ignore,
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
    stdin_fixture: ?[]const u8 = null,
    /// Expected exit code shared by both binaries (also cross-checked
    /// against what GNU actually returned).
    expect_exit: u8 = 0,
};

const Fixture = struct { name: []const u8, data: []const u8 };

fn allBytesFixture() [257]u8 {
    var buf: [257]u8 = undefined;
    for (0..256) |i| buf[i] = @intCast(i);
    buf[256] = '\n';
    return buf;
}

fn writeFixtures(io: Io, dir: Io.Dir, arena: std.mem.Allocator) !void {
    const all_bytes = allBytesFixture();

    // > 64 KiB of every byte value, so the fast path crosses its read-buffer
    // boundary mid-stream and non-ASCII bytes survive verbatim.
    var big: std.ArrayListUnmanaged(u8) = .empty;
    var pat: [256]u8 = undefined;
    for (0..256) |i| pat[i] = @intCast(i);
    for (0..300) |_| try big.appendSlice(arena, &pat);

    // A single 200 KB line (no newline until the end) — regression fixture for
    // the old 64 KiB line-buffer truncation bug in the processed path.
    var long_line: std.ArrayListUnmanaged(u8) = .empty;
    try long_line.appendNTimes(arena, 'x', 200_000);
    try long_line.append(arena, '\n');

    const fixtures = [_]Fixture{
        .{ .name = "plain.txt", .data = "hello\nworld\n" },
        .{ .name = "blanks.txt", .data = "one\n\n\n\ntwo\n\nthree\n" },
        .{ .name = "nonl.txt", .data = "alpha\nbeta" },
        .{ .name = "crlf.txt", .data = "line1\r\nline2\n" },
        .{ .name = "midcr.txt", .data = "a\rb\n" },
        .{ .name = "endcr.txt", .data = "tail\r" },
        .{ .name = "startnl.txt", .data = "\nx\n" },
        .{ .name = "tabs.txt", .data = "a\tb\n\tc\n" },
        .{ .name = "allbytes.bin", .data = &all_bytes },
        .{ .name = "big.bin", .data = big.items },
        .{ .name = "longline.txt", .data = long_line.items },
        .{ .name = "empty.txt", .data = "" },
    };
    for (fixtures) |f| {
        try dir.writeFile(io, .{ .sub_path = f.name, .data = f.data });
    }
}

const parity_cases = [_]Case{
    // The audit's critical finding: plain `zcat FILE` printed NOTHING.
    .{ .name = "plain file, no flags", .args = &.{"plain.txt"} },
    .{ .name = "empty file", .args = &.{"empty.txt"} },
    .{ .name = "binary all-byte-values passthrough", .args = &.{"allbytes.bin"} },
    .{ .name = "large binary crosses buffer boundary", .args = &.{"big.bin"} },
    .{ .name = "multiple files concatenate", .args = &.{ "plain.txt", "blanks.txt", "nonl.txt" } },
    .{ .name = "-n numbers all lines", .args = &.{ "-n", "blanks.txt" } },
    .{ .name = "-n numbering continues across files", .args = &.{ "-n", "plain.txt", "blanks.txt" } },
    .{ .name = "-n last line without newline", .args = &.{ "-n", "nonl.txt" } },
    .{ .name = "-b skips blank lines", .args = &.{ "-b", "blanks.txt" } },
    .{ .name = "-b overrides -n (audit finding)", .args = &.{ "-nb", "blanks.txt" } },
    .{ .name = "-s squeezes blank runs", .args = &.{ "-s", "blanks.txt" } },
    .{ .name = "-sn squeeze + number", .args = &.{ "-sn", "blanks.txt" } },
    .{ .name = "-E marks line ends", .args = &.{ "-E", "blanks.txt" } },
    .{ .name = "-E renders CRLF as ^M$ (coreutils >= 9.4)", .args = &.{ "-E", "crlf.txt" } },
    .{ .name = "-E lone CR mid-line stays raw", .args = &.{ "-E", "midcr.txt" } },
    .{ .name = "-E CR at EOF stays raw", .args = &.{ "-E", "endcr.txt" } },
    .{ .name = "-E CR/LF split across two files", .args = &.{ "-E", "endcr.txt", "startnl.txt" } },
    .{ .name = "-E no trailing newline", .args = &.{ "-E", "nonl.txt" } },
    .{ .name = "-T shows tabs", .args = &.{ "-T", "tabs.txt" } },
    .{ .name = "-v M- notation incl 0x80-0x9F/0xFF (audit finding)", .args = &.{ "-v", "allbytes.bin" } },
    .{ .name = "-e = -vE", .args = &.{ "-e", "crlf.txt" } },
    .{ .name = "-t = -vT", .args = &.{ "-t", "tabs.txt" } },
    .{ .name = "-A on all byte values", .args = &.{ "-A", "allbytes.bin" } },
    .{ .name = "-A on CRLF", .args = &.{ "-A", "crlf.txt" } },
    .{ .name = "-bE blank lines keep $ but no number", .args = &.{ "-bE", "blanks.txt" } },
    .{ .name = "-u accepted and ignored (audit finding)", .args = &.{ "-u", "plain.txt" } },
    .{ .name = "-n on 200KB single line (audit truncation finding)", .args = &.{ "-n", "longline.txt" } },
    .{ .name = "stdin passthrough", .args = &.{}, .stdin_fixture = "plain.txt" },
    .{ .name = "stdin via '-' operand mixed with file", .args = &.{ "plain.txt", "-" }, .stdin_fixture = "nonl.txt" },
    .{ .name = "stdin -n on 200KB line (audit stdin truncation)", .args = &.{"-n"}, .stdin_fixture = "longline.txt" },
    .{ .name = "stdin -sE", .args = &.{"-sE"}, .stdin_fixture = "blanks.txt" },
    .{ .name = "stdin -A binary", .args = &.{"-A"}, .stdin_fixture = "allbytes.bin" },
    // Error paths: stdout and exit code must match GNU (stderr text differs
    // only by program name; checked separately below).
    .{ .name = "missing file exits 1", .args = &.{"no-such-file.txt"}, .expect_exit = 1 },
    .{ .name = "missing file still cats the others", .args = &.{ "plain.txt", "no-such-file.txt", "nonl.txt" }, .expect_exit = 1 },
    .{ .name = "directory operand exits 1 (audit finding)", .args = &.{"subdir"}, .expect_exit = 1 },
};

test "GNU parity: stdout bytes and exit codes match the real GNU cat" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zcat_exe = try resolveZcatExe(arena, io);
    const gnu = findGnuCat(io) orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixtures(io, tmp.dir, arena);
    try tmp.dir.createDirPath(io, "subdir");

    var failures: usize = 0;
    for (parity_cases) |case| {
        const z = try runTool(arena, io, zcat_exe, case, tmp.dir);
        const g = try runTool(arena, io, gnu, case, tmp.dir);

        if (!std.mem.eql(u8, z.stdout, g.stdout)) {
            std.debug.print("FAIL [{s}]: stdout differs (zcat {d} bytes, gnu {d} bytes)\n", .{
                case.name, z.stdout.len, g.stdout.len,
            });
            failures += 1;
            continue;
        }
        if (z.exit_code != g.exit_code) {
            std.debug.print("FAIL [{s}]: exit code zcat={d} gnu={d}\n", .{ case.name, z.exit_code, g.exit_code });
            failures += 1;
            continue;
        }
        if (g.exit_code != case.expect_exit) {
            std.debug.print("FAIL [{s}]: test expectation stale — GNU itself exited {d}, expected {d}\n", .{
                case.name, g.exit_code, case.expect_exit,
            });
            failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "error messages carry POSIX strerror text and exit 1" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zcat_exe = try resolveZcatExe(arena, io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "subdir");

    // POSIX strerror(ENOENT) — same text GNU cat prints after "cat: FILE: ".
    {
        const r = try runTool(arena, io, zcat_exe, .{
            .name = "enoent",
            .args = &.{"no-such-file.txt"},
        }, tmp.dir);
        try std.testing.expectEqual(@as(u8, 1), r.exit_code);
        try std.testing.expectEqual(@as(usize, 0), r.stdout.len);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "No such file or directory") != null);
    }
    // POSIX strerror(EISDIR): GNU cat prints "cat: DIR: Is a directory".
    {
        const r = try runTool(arena, io, zcat_exe, .{
            .name = "eisdir",
            .args = &.{"subdir"},
        }, tmp.dir);
        try std.testing.expectEqual(@as(u8, 1), r.exit_code);
        try std.testing.expectEqual(@as(usize, 0), r.stdout.len);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "Is a directory") != null);
    }
}

// Literal-expected anchors, independent of an installed GNU binary.
// Sources cited per case; bytes transcribed from GNU coreutils cat
// documentation/source, NOT generated by zcat.
test "literal anchors: documented GNU cat output bytes" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zcat_exe = try resolveZcatExe(arena, io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.txt", .data = "hello\n\nworld\n" });
    // 0x00, 0x09, 0x1f, 0x7f, 0x80, 0x9f, 0xa0, 0xfe, 0xff, '\n'
    try tmp.dir.writeFile(io, .{ .sub_path = "np.bin", .data = "\x00\x09\x1f\x7f\x80\x9f\xa0\xfe\xff\n" });

    const LiteralCase = struct {
        name: []const u8,
        args: []const []const u8,
        expected: []const u8,
    };
    const cases = [_]LiteralCase{
        // POSIX cat -n / GNU cat.c: numbers are right-aligned in a 6-column
        // field followed by a TAB ("%6d\t"); blank lines are numbered by -n.
        .{
            .name = "-n format is %6d TAB",
            .args = &.{ "-n", "in.txt" },
            .expected = "     1\thello\n     2\t\n     3\tworld\n",
        },
        // GNU cat manual (-b): "number all nonempty output lines" — blank
        // line emitted without a number; numbering counts only nonblank.
        .{
            .name = "-b leaves blank lines unnumbered",
            .args = &.{ "-b", "in.txt" },
            .expected = "     1\thello\n\n     2\tworld\n",
        },
        // GNU cat manual (-v): control chars print as ^X, DEL as ^?, high
        // bytes as M- plus the low-7-bit rendering: 0x80->M-^@, 0x9f->M-^_,
        // 0xa0->M-space, 0xfe->M-~, 0xff->M-^?. TAB and LF are exempt.
        .{
            .name = "-v ^/M- notation for the documented byte map",
            .args = &.{ "-v", "np.bin" },
            .expected = "^@\t^_^?M-^@M-^_M- M-~M-^?\n",
        },
        // GNU cat manual (-E): "display $ at end of each line".
        .{
            .name = "-E appends $ before each newline",
            .args = &.{ "-E", "in.txt" },
            .expected = "hello$\n$\nworld$\n",
        },
        // GNU cat manual (-s): "suppress repeated adjacent blank lines".
        .{
            .name = "-s squeezes to a single blank line",
            .args = &.{ "-s", "in.txt" },
            .expected = "hello\n\nworld\n",
        },
    };

    for (cases) |case| {
        const r = try runTool(arena, io, zcat_exe, .{
            .name = case.name,
            .args = case.args,
        }, tmp.dir);
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        std.testing.expectEqualStrings(case.expected, r.stdout) catch |err| {
            std.debug.print("literal anchor failed: {s}\n", .{case.name});
            return err;
        };
    }
}
