//! Externally-anchored parity tests for ztsort.
//!
//! ANCHOR: the real GNU coreutils `tsort` binary (installed as `gtsort` by
//! Homebrew, coreutils 9.10). Each test runs BOTH ztsort and GNU tsort on the
//! same input and asserts byte-identical stdout + identical exit status. This
//! is a true external anchor: the expected bytes come from a program this
//! repository did not write. Where the diagnostic text embeds the program name
//! (`gtsort:` vs `ztsort:`) we normalize that single token before comparing --
//! everything else must match byte-for-byte.
//!
//! GNU's tie-break among equally-valid topological orders is
//! implementation-specific, so the stdout-diff cases below use inputs whose
//! topological order is UNIQUE (linear chains / forced orders) or whose cyclic
//! output GNU makes deterministic. Inputs with multiple valid orderings are not
//! diffed against GNU (both outputs would be "correct" yet differ).
//!
//! A subset of tests additionally assert literal expected bytes taken from the
//! documented GNU behavior, so they still bite if the GNU binary is absent.

const std = @import("std");
const testing = std.testing;
const io = testing.io;

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/tsort",
    "/opt/homebrew/bin/gtsort",
    "/usr/bin/tsort",
};

fn gnuBin() ?[]const u8 {
    for (gnu_candidates) |c| {
        std.Io.Dir.accessAbsolute(io, c, .{}) catch continue;
        return c;
    }
    return null;
}

fn ztsortBin() []const u8 {
    if (std.c.getenv("ZTSORT_BIN")) |p| return std.mem.span(p);
    return "zig-out/bin/ztsort";
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8, // 128+signo if signalled, exit status otherwise

    fn deinit(self: *RunResult, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

/// Run `bin file` (single file operand) and capture stdout/stderr/exit.
fn run(a: std.mem.Allocator, bin: []const u8, file: []const u8) !RunResult {
    const res = try std.process.run(a, io, .{ .argv = &.{ bin, file } });
    return .{
        .stdout = res.stdout,
        .stderr = res.stderr,
        .exit_code = switch (res.term) {
            .exited => |c| c,
            .signal => |s| @intCast((128 + @intFromEnum(s)) & 0xff),
            else => 255,
        },
    };
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    /// Absolute path to the written input file (also the operand both binaries see).
    path: []u8,

    fn deinit(self: *Fixture, a: std.mem.Allocator) void {
        a.free(self.path);
        self.tmp.cleanup();
    }
};

/// Write `input` to a fresh temp file; return an absolute-path fixture.
fn writeTemp(a: std.mem.Allocator, input: []const u8) !Fixture {
    var tmp = testing.tmpDir(.{});
    errdefer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.txt", .data = input });
    const cwd = try std.process.currentPathAlloc(io, a);
    defer a.free(cwd);
    const path = try std.fmt.allocPrint(a, "{s}/.zig-cache/tmp/{s}/in.txt", .{ cwd, tmp.sub_path });
    return .{ .tmp = tmp, .path = path };
}

/// Replace the GNU program-name token (`tsort:` / `gtsort:`) with `ztsort:`,
/// the only legitimately-different token in the diagnostics.
fn normalizeProgName(a: std.mem.Allocator, s: []const u8, gnu_path: []const u8) ![]u8 {
    const base = std.fs.path.basename(gnu_path); // "tsort" or "gtsort"
    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(a);
    var i: usize = 0;
    while (i < s.len) {
        if (std.mem.startsWith(u8, s[i..], base) and
            i + base.len < s.len and s[i + base.len] == ':')
        {
            try out.appendSlice(a, "ztsort");
            i += base.len;
        } else {
            try out.append(a, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

/// Core anchor: ztsort and GNU tsort agree on stdout and exit code for `input`.
fn expectParity(input: []const u8) !void {
    const a = testing.allocator;
    const gnu = gnuBin() orelse return error.SkipZigTest;

    var fx = try writeTemp(a, input);
    defer fx.deinit(a);

    var z = try run(a, ztsortBin(), fx.path);
    defer z.deinit(a);
    var g = try run(a, gnu, fx.path);
    defer g.deinit(a);

    try testing.expectEqualStrings(g.stdout, z.stdout);
    try testing.expectEqual(g.exit_code, z.exit_code);
}

/// Anchor including stderr, with the program-name token normalized.
fn expectParityWithStderr(input: []const u8) !void {
    const a = testing.allocator;
    const gnu = gnuBin() orelse return error.SkipZigTest;

    var fx = try writeTemp(a, input);
    defer fx.deinit(a);

    var z = try run(a, ztsortBin(), fx.path);
    defer z.deinit(a);
    var g = try run(a, gnu, fx.path);
    defer g.deinit(a);

    try testing.expectEqualStrings(g.stdout, z.stdout);
    try testing.expectEqual(g.exit_code, z.exit_code);

    const gn = try normalizeProgName(a, g.stderr, gnu);
    defer a.free(gn);
    // Both binaries see the same operand path, so after program-name
    // normalization the diagnostic bytes must match exactly.
    try testing.expectEqualStrings(gn, z.stderr);
}

// ---------------------------------------------------------------------------
// stdout parity: unique-order DAGs (GNU output is forced, so bytes must match)
// ---------------------------------------------------------------------------

test "parity: linear chain" {
    try expectParity("a b\nb c\nc d\n");
}

test "parity: longer forced chain" {
    try expectParity("first second\nsecond third\nthird fourth\nfourth fifth\n");
}

test "parity: single pair" {
    try expectParity("x y\n");
}

test "parity: diamond with forced tail" {
    // foo -> bar -> baz plus foo -> baz: order is forced (foo, bar, baz).
    try expectParity("foo bar\nbar baz\nfoo baz\n");
}

test "parity: self-loop is not a cycle (emit node, exit 0)" {
    try expectParityWithStderr("a a\n");
}

test "parity: whitespace/newline mix, forced order" {
    try expectParity("a\tb\n b   c \n\nc\td\n");
}

// ---------------------------------------------------------------------------
// Error / cycle parity: stdout, stderr (normalized), and exit code
// ---------------------------------------------------------------------------

test "parity: odd number of tokens is fatal" {
    try expectParityWithStderr("a b c\n");
}

test "parity: two-node cycle reports loop and still emits total order" {
    try expectParityWithStderr("a b\nb a\n");
}

test "parity: three-node cycle" {
    try expectParityWithStderr("a b\nb c\nc a\n");
}

test "parity: cycle with acyclic tail (only cycle members reported)" {
    try expectParityWithStderr("a b\nb c\nc b\nc d\n");
}

test "parity: two disjoint cycles reported separately" {
    try expectParityWithStderr("a b\nb a\nc d\nd c\n");
}

// ---------------------------------------------------------------------------
// Documented-bytes anchors (bite even if the GNU binary is absent).
// Expected bytes are GNU tsort's exact output format (coreutils manual +
// verified against gtsort 9.10).
// ---------------------------------------------------------------------------

test "odd-token diagnostic exact bytes + exit 1" {
    const a = testing.allocator;
    var fx = try writeTemp(a, "a b c\n");
    defer fx.deinit(a);

    var z = try run(a, ztsortBin(), fx.path);
    defer z.deinit(a);

    try testing.expectEqual(@as(u8, 1), z.exit_code);
    try testing.expectEqualStrings("", z.stdout);
    const expected = try std.fmt.allocPrint(a, "ztsort: {s}: input contains an odd number of tokens\n", .{fx.path});
    defer a.free(expected);
    try testing.expectEqualStrings(expected, z.stderr);
}

test "two-node cycle exact bytes: stdout a,b, exit 1, loop report on stderr" {
    const a = testing.allocator;
    var fx = try writeTemp(a, "a b\nb a\n");
    defer fx.deinit(a);

    var z = try run(a, ztsortBin(), fx.path);
    defer z.deinit(a);

    try testing.expectEqual(@as(u8, 1), z.exit_code);
    try testing.expectEqualStrings("a\nb\n", z.stdout);
    const expected = try std.fmt.allocPrint(a, "ztsort: {s}: input contains a loop:\nztsort: a\nztsort: b\n", .{fx.path});
    defer a.free(expected);
    try testing.expectEqualStrings(expected, z.stderr);
}

// ---------------------------------------------------------------------------
// Security regression: the critical OOB (fixed 4096-byte stack buffer for the
// FILE operand, filled with @memcpy + a NUL write past the end). A >= 4096-byte
// operand must NOT crash. The pre-fix code aborts with "index out of bounds"
// (exit 134 / SIGABRT) in a safe build, or is a genuine stack smash in
// ReleaseFast. GNU tsort simply reports the open() failure and exits 1 -- on
// macOS that is ENAMETOOLONG ("File name too long") because the single path
// component exceeds NAME_MAX. We assert: (1) a clean exit, never a
// signal-death, and (2) byte-for-byte parity with GNU (normalized).
// ---------------------------------------------------------------------------

fn expectLongNameParity(len: usize) !void {
    const a = testing.allocator;
    const long = try a.alloc(u8, len);
    defer a.free(long);
    @memset(long, 'q');

    var z = try run(a, ztsortBin(), long);
    defer z.deinit(a);

    // Must be a clean process exit, never a crash (128+signo). The pre-fix bug
    // yields SIGABRT (134) in safe builds; a bogus success (0) would mean the
    // error was swallowed.
    try testing.expect(z.exit_code < 128);
    try testing.expectEqual(@as(u8, 1), z.exit_code);
    try testing.expectEqualStrings("", z.stdout);
    try testing.expect(z.stderr.len > 0);

    if (gnuBin()) |gnu| {
        var g = try run(a, gnu, long);
        defer g.deinit(a);
        try testing.expectEqual(g.exit_code, z.exit_code);
        const gn = try normalizeProgName(a, g.stderr, gnu);
        defer a.free(gn);
        try testing.expectEqualStrings(gn, z.stderr);
    }
}

test "OOB regression: 4100-byte filename does not crash, matches GNU" {
    try expectLongNameParity(4100);
}

test "OOB regression: exactly-4096-byte filename does not crash, matches GNU" {
    try expectLongNameParity(4096);
}
