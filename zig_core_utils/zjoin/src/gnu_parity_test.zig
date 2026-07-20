//! Externally-anchored GNU parity tests for zjoin.
//!
//! Primary anchor: the real GNU coreutils `join` binary (9.x). Every parity
//! case runs BOTH binaries on the same fixture bytes, under LC_ALL=C, and
//! byte-compares stdout plus the exit code (and, for diagnostics, stderr with
//! the program-name prefix normalized). This is a true external anchor — none
//! of the expected outputs are produced by zjoin itself.
//!
//! Secondary anchor: a set of literal-expected cases whose bytes are
//! transcribed from GNU join's documented behavior (the coreutils manual and
//! the POSIX join spec), so the suite still asserts real bytes even when no
//! GNU binary is installed.
//!
//! Run via `zig build test`.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

fn resolveZjoinExe(arena: std.mem.Allocator, io: Io) ![]const u8 {
    const configured: []const u8 = build_options.zjoin_exe;
    if (std.fs.path.isAbsolute(configured)) return configured;
    return try Io.Dir.cwd().realPathFileAlloc(io, configured, arena);
}

/// Locations where a GNU coreutils `join` may live. The audit reference is the
/// homebrew coreutils gnubin path; /usr/bin/join is GNU on Linux.
const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/join",
    "/opt/homebrew/bin/gjoin",
    "/usr/local/opt/coreutils/libexec/gnubin/join",
    "/usr/local/bin/gjoin",
};

fn findGnuJoin(io: Io) ?[]const u8 {
    for (gnu_candidates) |path| {
        const f = Io.Dir.openFile(Io.Dir.cwd(), io, path, .{}) catch continue;
        f.close(io);
        return path;
    }
    if (@import("builtin").os.tag == .linux) {
        const f = Io.Dir.openFile(Io.Dir.cwd(), io, "/usr/bin/join", .{}) catch return null;
        f.close(io);
        return "/usr/bin/join";
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
};

/// Spawn `exe` under `/usr/bin/env LC_ALL=C` with `case.args`, cwd set to the
/// fixture dir, optionally feeding `case.stdin_fixture` as stdin.
fn runTool(
    arena: std.mem.Allocator,
    io: Io,
    exe: []const u8,
    case: Case,
    fixture_dir: Io.Dir,
) !RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.append(arena, "/usr/bin/env");
    try argv.append(arena, "LC_ALL=C");
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

fn buildWideFixtures(arena: std.mem.Allocator) ![2]Fixture {
    // A single line with 70 blank-separated fields, so an -o 1.70 reference
    // exercises the old 64-field silent-truncation cap.
    var w1: std.ArrayListUnmanaged(u8) = .empty;
    try w1.appendSlice(arena, "k");
    for (1..70) |n| {
        try w1.append(arena, ' ');
        try w1.print(arena, "f{d}", .{n});
    }
    try w1.append(arena, '\n');
    return .{
        Fixture{ .name = "wide1.txt", .data = w1.items },
        Fixture{ .name = "wide2.txt", .data = "k Z\n" },
    };
}

fn writeFixtures(io: Io, dir: Io.Dir, arena: std.mem.Allocator) !void {
    const wide = try buildWideFixtures(arena);
    const fixtures = [_]Fixture{
        // Core sorted inputs.
        .{ .name = "f1.txt", .data = "a 1\nb 2\nc 3\n" },
        .{ .name = "f2.txt", .data = "b y\n" },
        // b has two matches -> cartesian product on the right.
        .{ .name = "bmul.txt", .data = "a x\nb y\nb z\nc w\n" },
        // dup keys on BOTH sides -> full cartesian.
        .{ .name = "d1.txt", .data = "k 1\nk 2\n" },
        .{ .name = "d2.txt", .data = "k a\nk b\n" },
        // tab-separated (default-separator collapse + single-space output).
        .{ .name = "tab1.txt", .data = "a\t1\n" },
        .{ .name = "tab2.txt", .data = "a\tx\n" },
        // multiple spaces between fields.
        .{ .name = "msp1.txt", .data = "a   1\n" },
        .{ .name = "msp2.txt", .data = "a   x\n" },
        // leading blanks (skipped).
        .{ .name = "lead1.txt", .data = "  a 1\n" },
        .{ .name = "lead2.txt", .data = "a x\n" },
        // colon-separated, passwd-shaped (sorted: bin < root).
        .{ .name = "p1.txt", .data = "bin:x:1\nroot:x:0\n" },
        .{ .name = "p2.txt", .data = "bin:1:1\nroot:0:0\n" },
        // join on non-default fields.
        .{ .name = "j1.txt", .data = "1 apple\n2 fig\n3 pear\n" },
        .{ .name = "j2.txt", .data = "apple red\nfig purple\npear green\n" },
        // case-folding (-i): A/B upper vs a/b lower.
        .{ .name = "up1.txt", .data = "A 1\nB 2\n" },
        .{ .name = "lo2.txt", .data = "a x\nb y\n" },
        // unsorted left input for --check-order diagnostics.
        .{ .name = "u1.txt", .data = "c 3\na 1\nb 2\n" },
        .{ .name = "s2.txt", .data = "a x\nb y\nc z\n" },
        // empty file.
        .{ .name = "empty.txt", .data = "" },
        wide[0],
        wide[1],
    };
    for (fixtures) |f| {
        try dir.writeFile(io, .{ .sub_path = f.name, .data = f.data });
    }
}

/// stdout+exit parity cases. Expected outputs come from the real GNU join.
const parity_cases = [_]Case{
    .{ .name = "default join, single match", .args = &.{ "f1.txt", "f2.txt" } },
    .{ .name = "-a1 interleaves unpairables in sorted order", .args = &.{ "-a1", "f1.txt", "f2.txt" } },
    .{ .name = "-a2 unpairables", .args = &.{ "-a2", "f1.txt", "bmul.txt" } },
    .{ .name = "-v1 suppress joined", .args = &.{ "-v1", "f1.txt", "f2.txt" } },
    .{ .name = "-v2 suppress joined", .args = &.{ "-v2", "f1.txt", "bmul.txt" } },
    .{ .name = "-a1 -a2 both", .args = &.{ "-a1", "-a2", "f1.txt", "bmul.txt" } },
    .{ .name = "cartesian: two right matches", .args = &.{ "f1.txt", "bmul.txt" } },
    .{ .name = "cartesian: dup keys both sides", .args = &.{ "d1.txt", "d2.txt" } },
    // The single biggest defect from the audit: tab / multispace / leading-blank.
    .{ .name = "tab-separated default sep", .args = &.{ "tab1.txt", "tab2.txt" } },
    .{ .name = "multi-space default sep", .args = &.{ "msp1.txt", "msp2.txt" } },
    .{ .name = "leading-blank lines", .args = &.{ "lead1.txt", "lead2.txt" } },
    // -t separator.
    .{ .name = "-t: colon separator", .args = &.{ "-t:", "p1.txt", "p2.txt" } },
    .{ .name = "-t: with -a1 unpaired", .args = &.{ "-t:", "-a1", "p1.txt", "p2.txt" } },
    // join on non-default fields.
    .{ .name = "-1 2 -2 1 cross-field join", .args = &.{ "-1", "2", "-2", "1", "j1.txt", "j2.txt" } },
    .{ .name = "-j 1 equivalent", .args = &.{ "-j", "1", "f1.txt", "f2.txt" } },
    // case-insensitive.
    .{ .name = "-i case-insensitive", .args = &.{ "-i", "up1.txt", "lo2.txt" } },
    // -o output formatting.
    .{ .name = "-o explicit spec", .args = &.{ "-o", "0,1.2,2.2", "f1.txt", "bmul.txt" } },
    .{ .name = "-o auto", .args = &.{ "-o", "auto", "f1.txt", "f2.txt" } },
    .{ .name = "-o auto -a1 -e fills unpaired", .args = &.{ "-o", "auto", "-a1", "-e", "X", "f1.txt", "f2.txt" } },
    .{ .name = "-o spec applied to unpaired with -e", .args = &.{ "-a1", "-o", "1.1,2.2", "-e", "NULL", "f1.txt", "f2.txt" } },
    .{ .name = "-v1 -o spec formats unpaired", .args = &.{ "-v1", "-o", "1.1,2.2", "-e", "NULL", "f1.txt", "f2.txt" } },
    // >64 fields must not be truncated.
    .{ .name = "-o 1.70 on a 70-field line", .args = &.{ "-o", "1.70", "wide1.txt", "wide2.txt" } },
    // empty inputs.
    .{ .name = "empty right file", .args = &.{ "f1.txt", "empty.txt" } },
    .{ .name = "empty left file -a2", .args = &.{ "-a2", "empty.txt", "f2.txt" } },
    .{ .name = "both empty", .args = &.{ "empty.txt", "empty.txt" } },
    // sortedness handling.
    .{ .name = "unsorted left, default (warns, exit 1)", .args = &.{ "u1.txt", "s2.txt" } },
    .{ .name = "unsorted left, --check-order (exit 1)", .args = &.{ "--check-order", "u1.txt", "s2.txt" } },
    .{ .name = "unsorted left, --nocheck-order (exit 0)", .args = &.{ "--nocheck-order", "u1.txt", "s2.txt" } },
    // invalid arguments (exit 1).
    .{ .name = "invalid field number -1 abc", .args = &.{ "-1", "abc", "f1.txt", "f2.txt" } },
    .{ .name = "field number zero -1 0", .args = &.{ "-1", "0", "f1.txt", "f2.txt" } },
    .{ .name = "invalid file number -a3", .args = &.{ "-a3", "f1.txt", "f2.txt" } },
    .{ .name = "invalid -o file spec 3.1", .args = &.{ "-o", "3.1", "f1.txt", "f2.txt" } },
    .{ .name = "invalid -o specifier 0.1", .args = &.{ "-o", "0.1", "f1.txt", "f2.txt" } },
    // stdin via '-'.
    .{ .name = "left from stdin via -", .args = &.{ "-", "f2.txt" }, .stdin_fixture = "f1.txt" },
    .{ .name = "right from stdin via -", .args = &.{ "f1.txt", "-" }, .stdin_fixture = "bmul.txt" },
};

test "GNU parity: stdout bytes and exit codes match the real GNU join" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zjoin_exe = try resolveZjoinExe(arena, io);
    const gnu = findGnuJoin(io) orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixtures(io, tmp.dir, arena);

    var failures: usize = 0;
    for (parity_cases) |case| {
        const z = try runTool(arena, io, zjoin_exe, case, tmp.dir);
        const g = try runTool(arena, io, gnu, case, tmp.dir);

        if (!std.mem.eql(u8, z.stdout, g.stdout)) {
            std.debug.print("FAIL [{s}]: stdout differs\n  zjoin: \"{s}\"\n  gnu:   \"{s}\"\n", .{
                case.name, z.stdout, g.stdout,
            });
            failures += 1;
            continue;
        }
        if (z.exit_code != g.exit_code) {
            std.debug.print("FAIL [{s}]: exit zjoin={d} gnu={d}\n", .{ case.name, z.exit_code, g.exit_code });
            failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

/// Strip the leading "prog: " program-name token from each stderr line so
/// diagnostics can be compared across zjoin and gjoin.
fn normalizeStderr(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(arena, '\n');
        first = false;
        // Strip the leading "<prog>: " program-name token. The GNU binary may
        // be installed as "join" (gnubin) or "gjoin"; ours is "zjoin". Check
        // the more specific names before the bare "join: ".
        const prefixes = [_][]const u8{ "zjoin: ", "gjoin: ", "join: " };
        var stripped = false;
        for (prefixes) |p| {
            if (std.mem.startsWith(u8, line, p)) {
                try out.appendSlice(arena, "X: ");
                try out.appendSlice(arena, line[p.len..]);
                stripped = true;
                break;
            }
        }
        if (!stripped) try out.appendSlice(arena, line);
    }
    return out.items;
}

/// Diagnostic cases where zjoin is expected to match GNU's stderr text
/// (program-name prefix normalized). These have no "Try '<argv0> --help'"
/// line, so the whole normalized stderr can be compared.
const diagnostic_cases = [_]Case{
    .{ .name = "invalid field number", .args = &.{ "-1", "abc", "f1.txt", "f2.txt" } },
    .{ .name = "field number zero", .args = &.{ "-1", "0", "f1.txt", "f2.txt" } },
    .{ .name = "invalid file number", .args = &.{ "-a3", "f1.txt", "f2.txt" } },
    .{ .name = "invalid file number in field spec", .args = &.{ "-o", "3.1", "f1.txt", "f2.txt" } },
    .{ .name = "invalid field specifier", .args = &.{ "-o", "0.1", "f1.txt", "f2.txt" } },
    .{ .name = "disorder warning (default)", .args = &.{ "u1.txt", "s2.txt" } },
    .{ .name = "disorder fatal (--check-order)", .args = &.{ "--check-order", "u1.txt", "s2.txt" } },
};

test "GNU parity: diagnostics match the real GNU join (program name normalized)" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zjoin_exe = try resolveZjoinExe(arena, io);
    const gnu = findGnuJoin(io) orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixtures(io, tmp.dir, arena);

    var failures: usize = 0;
    for (diagnostic_cases) |case| {
        const z = try runTool(arena, io, zjoin_exe, case, tmp.dir);
        const g = try runTool(arena, io, gnu, case, tmp.dir);
        const zn = try normalizeStderr(arena, z.stderr);
        const gn = try normalizeStderr(arena, g.stderr);
        if (!std.mem.eql(u8, zn, gn)) {
            std.debug.print("FAIL [{s}]: stderr differs\n  zjoin: \"{s}\"\n  gnu:   \"{s}\"\n", .{
                case.name, zn, gn,
            });
            failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

// ---------------------------------------------------------------------------
// Literal anchors, independent of an installed GNU binary. Bytes transcribed
// from GNU join's documented behavior (coreutils manual "join" section and
// the POSIX join spec), NOT generated by zjoin.
// ---------------------------------------------------------------------------

test "literal anchors: documented GNU join output bytes" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zjoin_exe = try resolveZjoinExe(arena, io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixtures(io, tmp.dir, arena);

    const LiteralCase = struct {
        name: []const u8,
        args: []const []const u8,
        expected: []const u8,
        expect_exit: u8 = 0,
    };
    const cases = [_]LiteralCase{
        // POSIX join: "the default output ... consists of the join field,
        // followed by ... the remaining fields of file1, followed by ... the
        // remaining fields of file2." Single space as output separator.
        .{ .name = "default join line", .args = &.{ "f1.txt", "f2.txt" }, .expected = "b 2 y\n" },
        // POSIX/GNU default separator: "the input is separated ... by runs of
        // blank characters" — a TAB is a blank, output separator is one space.
        .{ .name = "tab collapses to single space", .args = &.{ "tab1.txt", "tab2.txt" }, .expected = "a 1 x\n" },
        // Multiple spaces collapse; leading blanks are ignored.
        .{ .name = "multi-space collapses", .args = &.{ "msp1.txt", "msp2.txt" }, .expected = "a 1 x\n" },
        .{ .name = "leading blanks ignored", .args = &.{ "lead1.txt", "lead2.txt" }, .expected = "a 1 x\n" },
        // GNU -a: unpairable lines are printed *interleaved* in the sorted
        // merge position, not appended after the joined output.
        .{ .name = "-a1 interleaved", .args = &.{ "-a1", "f1.txt", "f2.txt" }, .expected = "a 1\nb 2 y\nc 3\n" },
        // Cartesian product for the repeated key "b" in the second file; the
        // singleton keys a and c also join, all interleaved in sorted order.
        .{ .name = "cartesian right", .args = &.{ "f1.txt", "bmul.txt" }, .expected = "a 1 x\nb 2 y\nb 2 z\nc 3 w\n" },
        // GNU manual, -o auto: "the first line of each file determines the
        // number of fields output for each line" and applies -e to absent ones.
        .{ .name = "-o auto -a1 -e", .args = &.{ "-o", "auto", "-a1", "-e", "X", "f1.txt", "f2.txt" }, .expected = "a 1 X\nb 2 y\nc 3 X\n" },
        // GNU manual, -o + -e: the format is applied to unpaired lines too,
        // substituting -e for fields from the missing file.
        .{ .name = "-a1 -o with -e on unpaired", .args = &.{ "-a1", "-o", "1.1,2.2", "-e", "NULL", "f1.txt", "f2.txt" }, .expected = "a NULL\nb y\nc NULL\n" },
        // -t: colon separator, output also uses the colon.
        .{ .name = "-t: colon in and out", .args = &.{ "-t:", "p1.txt", "p2.txt" }, .expected = "bin:x:1:1:1\nroot:x:0:0:0\n" },
    };

    var failures: usize = 0;
    for (cases) |case| {
        const r = try runTool(arena, io, zjoin_exe, .{ .name = case.name, .args = case.args }, tmp.dir);
        if (r.exit_code != case.expect_exit) {
            std.debug.print("literal anchor [{s}]: exit {d}, expected {d}\n", .{ case.name, r.exit_code, case.expect_exit });
            failures += 1;
            continue;
        }
        if (!std.mem.eql(u8, r.stdout, case.expected)) {
            std.debug.print("literal anchor [{s}]: stdout differs\n  got:      \"{s}\"\n  expected: \"{s}\"\n", .{
                case.name, r.stdout, case.expected,
            });
            failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

// GNU writes --help and --version to STDOUT and exits 0 (the audit found zjoin
// wrote them to stderr). We do not anchor the exact help text — only that it
// lands on stdout, stderr is empty, and the exit code is 0.
test "help and version go to stdout with exit 0" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zjoin_exe = try resolveZjoinExe(arena, io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for ([_][]const u8{ "--help", "--version" }) |flag| {
        const r = try runTool(arena, io, zjoin_exe, .{ .name = flag, .args = &.{flag} }, tmp.dir);
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        try std.testing.expect(r.stdout.len > 0);
        try std.testing.expectEqual(@as(usize, 0), r.stderr.len);
    }
}
