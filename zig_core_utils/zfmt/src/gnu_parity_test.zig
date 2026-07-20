//! Externally-anchored GNU parity tests for zfmt.
//!
//! Primary anchor: the real GNU coreutils `fmt` binary (9.x). Every parity
//! case runs BOTH binaries on the same fixture bytes / flags and byte-compares
//! stdout plus the exit code. This is a true external anchor — none of the
//! expected outputs are produced by zfmt itself. It exercises the cost-based
//! minimum-raggedness reflow (which zfmt ports from coreutils fmt.c), so a
//! divergence in the break algorithm shows up as a stdout mismatch.
//!
//! Secondary anchor: literal-expected cases whose bytes are transcribed from
//! GNU fmt's documented behavior, so the suite still asserts real bytes even
//! if no GNU binary is installed.
//!
//! Run via `zig build test`.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

fn resolveZfmtExe(arena: std.mem.Allocator, io: Io) ![]const u8 {
    const configured: []const u8 = build_options.zfmt_exe;
    if (std.fs.path.isAbsolute(configured)) return configured;
    return try Io.Dir.cwd().realPathFileAlloc(io, configured, arena);
}

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/fmt",
    "/opt/homebrew/bin/gfmt",
    "/usr/local/opt/coreutils/libexec/gnubin/fmt",
    "/usr/local/bin/gfmt",
};

fn findGnuFmt(io: Io) ?[]const u8 {
    for (gnu_candidates) |path| {
        const f = Io.Dir.openFile(Io.Dir.cwd(), io, path, .{}) catch continue;
        f.close(io);
        return path;
    }
    if (@import("builtin").os.tag == .linux) {
        const f = Io.Dir.openFile(Io.Dir.cwd(), io, "/usr/bin/fmt", .{}) catch return null;
        f.close(io);
        return "/usr/bin/fmt";
    }
    return null;
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

const Case = struct {
    name: []const u8,
    args: []const []const u8,
    stdin_fixture: ?[]const u8 = null,
    expect_exit: u8 = 0,
};

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

const Fixture = struct { name: []const u8, data: []const u8 };

fn writeFixtures(io: Io, dir: Io.Dir, arena: std.mem.Allocator) !void {
    // A > 4096-word single paragraph — the old fixed-cap truncation regression.
    var big_para: std.ArrayListUnmanaged(u8) = .empty;
    for (0..6000) |i| {
        if (i != 0) try big_para.append(arena, ' ');
        try big_para.print(arena, "word{d}", .{i});
    }
    try big_para.append(arena, '\n');

    // A paragraph whose first line has > 256 columns of leading indent — the
    // old uninitialized/OOB stack read.
    var deep_indent: std.ArrayListUnmanaged(u8) = .empty;
    try deep_indent.appendNTimes(arena, ' ', 300);
    try deep_indent.appendSlice(arena, "deeply indented text word word word word word word word word word word word word word\n");

    const fixtures = [_]Fixture{
        .{ .name = "simple.txt", .data = "The quick brown fox jumps over the lazy dog and then runs away quickly into the deep dark forest.\n" },
        .{ .name = "lorem.txt", .data = "Lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua ut enim ad minim veniam quis nostrud exercitation ullamco laboris.\n" },
        .{ .name = "sentences.txt", .data = "First sentence here. Second one now! Third question? Fourth statement follows along nicely here today.\n" },
        .{ .name = "indent.txt", .data = "    indented paragraph one two three four five six seven eight nine ten eleven twelve thirteen fourteen\n" },
        .{ .name = "twopara.txt", .data = "Para one word word word word word word word word word word word word word word word word here.\n\nPara two more more more more more more more more more more more more more more more more here.\n" },
        .{ .name = "crown.txt", .data = "  First line of crown paragraph continues here with many words to wrap around lines nicely today.\n     Second line indent different here also many words to fill and wrap around several lines here.\n" },
        .{ .name = "tagged.txt", .data = "1. Tagged paragraph first line then continuation lines with more words to wrap around here now yes.\n   continuation of tagged one two three four five six seven eight nine ten eleven twelve today.\n" },
        .{ .name = "split.txt", .data = "short line\na much longer line that certainly exceeds the default width limit of seventy five columns here indeed yes.\n" },
        .{ .name = "prefix.txt", .data = "# comment one two three four five six seven eight nine ten eleven twelve thirteen fourteen here\n# more comment words here to fill and wrap around the lines nicely for the prefix test case now yes\nnot a comment line stays as is unchanged\n" },
        .{ .name = "tabs.txt", .data = "\ttabbed line word word word word word word word word word word word word word word word word here\n" },
        .{ .name = "blanks.txt", .data = "\n\n\nword word word word\n\n\n" },
        .{ .name = "empty.txt", .data = "" },
        .{ .name = "bigpara.txt", .data = big_para.items },
        .{ .name = "deepindent.txt", .data = deep_indent.items },
    };
    for (fixtures) |f| {
        try dir.writeFile(io, .{ .sub_path = f.name, .data = f.data });
    }
}

const parity_cases = [_]Case{
    // Default width reflow (the core min-raggedness algorithm).
    .{ .name = "simple default", .args = &.{}, .stdin_fixture = "simple.txt" },
    .{ .name = "simple -w30", .args = &.{"-w30"}, .stdin_fixture = "simple.txt" },
    .{ .name = "simple -w20", .args = &.{"-w20"}, .stdin_fixture = "simple.txt" },
    .{ .name = "simple -w50", .args = &.{"-w50"}, .stdin_fixture = "simple.txt" },
    .{ .name = "simple -w10", .args = &.{"-w10"}, .stdin_fixture = "simple.txt" },
    .{ .name = "lorem default", .args = &.{}, .stdin_fixture = "lorem.txt" },
    .{ .name = "lorem -w40", .args = &.{"-w40"}, .stdin_fixture = "lorem.txt" },
    .{ .name = "lorem -g50", .args = &.{"-g50"}, .stdin_fixture = "lorem.txt" },
    .{ .name = "lorem -w60 -g40", .args = &.{ "-w60", "-g40" }, .stdin_fixture = "lorem.txt" },
    .{ .name = "lorem -35 old syntax", .args = &.{"-35"}, .stdin_fixture = "lorem.txt" },
    // Sentence spacing affects cost (SENTENCE_BONUS / final).
    .{ .name = "sentences default", .args = &.{}, .stdin_fixture = "sentences.txt" },
    .{ .name = "sentences -u", .args = &.{"-u"}, .stdin_fixture = "sentences.txt" },
    .{ .name = "sentences -w25", .args = &.{"-w25"}, .stdin_fixture = "sentences.txt" },
    // Indentation preservation.
    .{ .name = "indent default", .args = &.{}, .stdin_fixture = "indent.txt" },
    .{ .name = "indent -w30", .args = &.{"-w30"}, .stdin_fixture = "indent.txt" },
    // Multiple paragraphs / blank-line handling.
    .{ .name = "twopara default", .args = &.{}, .stdin_fixture = "twopara.txt" },
    .{ .name = "twopara -w30", .args = &.{"-w30"}, .stdin_fixture = "twopara.txt" },
    .{ .name = "blanks preserved", .args = &.{}, .stdin_fixture = "blanks.txt" },
    // Crown / tagged / split / prefix modes.
    .{ .name = "crown -c", .args = &.{"-c"}, .stdin_fixture = "crown.txt" },
    .{ .name = "crown -c -w30", .args = &.{ "-c", "-w30" }, .stdin_fixture = "crown.txt" },
    .{ .name = "tagged -t", .args = &.{"-t"}, .stdin_fixture = "tagged.txt" },
    .{ .name = "tagged -t -w30", .args = &.{ "-t", "-w30" }, .stdin_fixture = "tagged.txt" },
    .{ .name = "split -s", .args = &.{"-s"}, .stdin_fixture = "split.txt" },
    .{ .name = "split -s -w20", .args = &.{ "-s", "-w20" }, .stdin_fixture = "split.txt" },
    .{ .name = "prefix -p#", .args = &.{ "-p", "#" }, .stdin_fixture = "prefix.txt" },
    .{ .name = "prefix -p# -w30", .args = &.{ "-p", "#", "-w30" }, .stdin_fixture = "prefix.txt" },
    // Tabs on input.
    .{ .name = "tabs default", .args = &.{}, .stdin_fixture = "tabs.txt" },
    .{ .name = "tabs -w30", .args = &.{"-w30"}, .stdin_fixture = "tabs.txt" },
    // Regression: large paragraph must not truncate (old 4096-word cap).
    .{ .name = "bigpara default (truncation regression)", .args = &.{}, .stdin_fixture = "bigpara.txt" },
    .{ .name = "bigpara -w40", .args = &.{"-w40"}, .stdin_fixture = "bigpara.txt" },
    // Regression: > 256 column indent must not OOB (old fixed stack buffer).
    .{ .name = "deep indent (OOB regression)", .args = &.{}, .stdin_fixture = "deepindent.txt" },
    // Empty input.
    .{ .name = "empty stdin", .args = &.{}, .stdin_fixture = "empty.txt" },
    // File operand path (not stdin).
    .{ .name = "file operand", .args = &.{"simple.txt"} },
    .{ .name = "two file operands", .args = &.{ "simple.txt", "lorem.txt" } },
    // Error paths: exit code must match GNU (exit 1).
    .{ .name = "missing file exits 1", .args = &.{"no-such-file.txt"}, .expect_exit = 1 },
    .{ .name = "missing file still fmts others", .args = &.{ "simple.txt", "no-such-file.txt", "lorem.txt" }, .expect_exit = 1 },
};

test "GNU parity: stdout bytes and exit codes match the real GNU fmt" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zfmt_exe = try resolveZfmtExe(arena, io);
    const gnu = findGnuFmt(io) orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixtures(io, tmp.dir, arena);

    var failures: usize = 0;
    for (parity_cases) |case| {
        const z = try runTool(arena, io, zfmt_exe, case, tmp.dir);
        const g = try runTool(arena, io, gnu, case, tmp.dir);

        if (!std.mem.eql(u8, z.stdout, g.stdout)) {
            std.debug.print("FAIL [{s}]: stdout differs (zfmt {d} bytes, gnu {d} bytes)\n", .{
                case.name, z.stdout.len, g.stdout.len,
            });
            std.debug.print("  zfmt: {s}\n", .{z.stdout[0..@min(z.stdout.len, 200)]});
            std.debug.print("  gnu : {s}\n", .{g.stdout[0..@min(g.stdout.len, 200)]});
            failures += 1;
            continue;
        }
        if (z.exit_code != g.exit_code) {
            std.debug.print("FAIL [{s}]: exit code zfmt={d} gnu={d}\n", .{ case.name, z.exit_code, g.exit_code });
            failures += 1;
            continue;
        }
        if (g.exit_code != case.expect_exit) {
            std.debug.print("FAIL [{s}]: stale expectation — GNU itself exited {d}, expected {d}\n", .{
                case.name, g.exit_code, case.expect_exit,
            });
            failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "error diagnostics carry GNU-parity text and exit 1" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zfmt_exe = try resolveZfmtExe(arena, io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ok.txt", .data = "hello world\n" });

    // Missing file: GNU fmt prints
    // "fmt: cannot open 'X' for reading: No such file or directory", exit 1.
    {
        const r = try runTool(arena, io, zfmt_exe, .{
            .name = "enoent",
            .args = &.{"no-such-file.txt"},
        }, tmp.dir);
        try std.testing.expectEqual(@as(u8, 1), r.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "cannot open") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "No such file or directory") != null);
    }
    // Invalid option: GNU fmt exits 1 with "invalid option".
    {
        const r = try runTool(arena, io, zfmt_exe, .{
            .name = "badopt",
            .args = &.{"-Z"},
            .stdin_fixture = "ok.txt",
        }, tmp.dir);
        try std.testing.expectEqual(@as(u8, 1), r.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "invalid option") != null);
    }
    // Invalid width: GNU fmt exits 1 with "invalid width".
    {
        const r = try runTool(arena, io, zfmt_exe, .{
            .name = "badwidth",
            .args = &.{"-wabc"},
            .stdin_fixture = "ok.txt",
        }, tmp.dir);
        try std.testing.expectEqual(@as(u8, 1), r.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "invalid width") != null);
    }
}

// Literal-expected anchors, independent of an installed GNU binary. Bytes
// transcribed from GNU fmt's documented behavior (coreutils fmt manual +
// the min-raggedness algorithm in fmt.c), NOT generated by zfmt.
test "literal anchors: documented GNU fmt output bytes" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zfmt_exe = try resolveZfmtExe(arena, io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const LiteralCase = struct {
        name: []const u8,
        args: []const []const u8,
        input: []const u8,
        expected: []const u8,
    };
    const cases = [_]LiteralCase{
        // Reflow to a narrow width: greedy and min-raggedness agree here
        // because every word is 4 chars, so the fill is unambiguous. GNU fmt
        // -w20 on twelve 4-letter words packs four per 19-column line.
        .{
            .name = "-w20 uniform 4-letter fill",
            .args = &.{"-w20"},
            .input = "aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj kkkk llll\n",
            .expected = "aaaa bbbb cccc dddd\neeee ffff gggg hhhh\niiii jjjj kkkk llll\n",
        },
        // -s split-only: never refills; only splits lines longer than width.
        // A short line passes through unchanged; a long line is split on
        // whitespace. (coreutils fmt manual: "Split lines only.")
        .{
            .name = "-s -w20 split only",
            .args = &.{ "-s", "-w20" },
            .input = "short\naaaa bbbb cccc dddd eeee ffff\n",
            .expected = "short\naaaa bbbb cccc dddd\neeee ffff\n",
        },
        // Blank lines separate paragraphs and are preserved verbatim. The
        // first paragraph's 5 words split 3+2 (not 4+1): min-raggedness
        // balances the two lines around goal_width rather than greedily
        // packing the first line.
        .{
            .name = "blank line separates paragraphs",
            .args = &.{"-w20"},
            .input = "aaaa bbbb cccc dddd eeee\n\nffff gggg hhhh iiii\n",
            .expected = "aaaa bbbb cccc\ndddd eeee\n\nffff gggg hhhh iiii\n",
        },
        // Leading indentation of the first line is preserved on every output
        // line (non-crown default: other_indent == first_indent).
        .{
            .name = "indent preserved on all lines",
            .args = &.{"-w20"},
            .input = "  aaaa bbbb cccc dddd eeee ffff\n",
            .expected = "  aaaa bbbb cccc\n  dddd eeee ffff\n",
        },
    };

    for (cases) |case| {
        try tmp.dir.writeFile(io, .{ .sub_path = "in.txt", .data = case.input });
        const r = try runTool(arena, io, zfmt_exe, .{
            .name = case.name,
            .args = case.args,
            .stdin_fixture = "in.txt",
        }, tmp.dir);
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        std.testing.expectEqualStrings(case.expected, r.stdout) catch |err| {
            std.debug.print("literal anchor failed: {s}\n", .{case.name});
            return err;
        };
    }
}
