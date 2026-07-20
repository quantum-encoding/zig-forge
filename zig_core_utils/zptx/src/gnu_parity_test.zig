//! Externally-anchored tests for zptx (GNU `ptx` reimplementation).
//!
//! The external anchor is the REAL GNU coreutils binary `ptx` (verified here as
//! `/opt/homebrew/bin/gptx`, coreutils 9.10). Each test that compares behaviour
//! runs BOTH the freshly-built `zptx` (path injected by build.zig via
//! build_options) AND the system `gptx`, then diffs an observable property:
//!
//!   * process exit status / termination signal  (portability + error handling)
//!   * number of index lines for a no-wrap width  (tokenization + ignore-file)
//!   * the ordered sequence of index KEYWORDS      (sort order, incl. -f folding)
//!
//! Why not diff full output byte-for-byte? zptx's column geometry and its
//! wrap-around handling legitimately differ from GNU's (documented scope gap);
//! the audit noted this. The keyword *sequence* and the *set of indexed words*
//! do match GNU exactly, and those are what these tests pin. These are true
//! external anchors: the expected values come from running the reference binary,
//! not from zptx's own output (no roundtrip-only tests — repo golden rule).
//!
//! If gptx is not installed, the comparison tests SkipZigTest so the suite stays
//! portable; the pure-zptx safety tests (crash/overflow regressions) always run.

const std = @import("std");
const build_options = @import("build_options");

const ZPTX = build_options.zptx_path;
const GPTX = "/opt/homebrew/bin/gptx";

const RunOut = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *RunOut, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }

    /// Exit code if the process exited normally, else null (e.g. killed by a
    /// signal — which is exactly what the old Linux-only syscalls did: SIGSYS).
    fn exitCode(self: RunOut) ?u8 {
        return switch (self.term) {
            .exited => |c| c,
            else => null,
        };
    }
};

fn run(argv: []const []const u8) !RunOut {
    const gpa = std.testing.allocator;
    const res = try std.process.run(gpa, std.testing.io, .{ .argv = argv });
    return .{ .term = res.term, .stdout = res.stdout, .stderr = res.stderr };
}

fn gptxAvailable() bool {
    const f = std.Io.Dir.cwd().openFile(std.testing.io, GPTX, .{}) catch return false;
    f.close(std.testing.io);
    return true;
}

/// Create/overwrite a fixture file with `bytes`. Uses posix.openat (portable,
/// bounds-checked path) + libc.write (no dependence on the reshuffled std.fs).
fn writeFixture(path: []const u8, bytes: []const u8) !void {
    const fd = try std.posix.openat(
        std.posix.AT.FDCWD,
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    );
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return error.WriteFixtureFailed;
        off += @intCast(n);
    }
}

/// Extract the ordered keyword sequence from ptx output. The keyword is the
/// first token of the right-hand column, which for the default gap (3) and an
/// even width `w` begins at or just after column w/2 in BOTH implementations.
/// Verified against gptx for the fixtures below.
fn keywords(gpa: std.mem.Allocator, output: []const u8, w: usize) !std.ArrayListUnmanaged([]const u8) {
    var list = std.ArrayListUnmanaged([]const u8).empty;
    errdefer list.deinit(gpa);
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const start = w / 2;
        if (start >= line.len) continue;
        var i = start;
        while (i < line.len and line[i] == ' ') i += 1;
        const kw_start = i;
        while (i < line.len and line[i] != ' ') i += 1;
        if (i > kw_start) try list.append(gpa, line[kw_start..i]);
    }
    return list;
}

fn expectSameKeywords(gpa: std.mem.Allocator, a: []const u8, b: []const u8, w: usize) !void {
    var ka = try keywords(gpa, a, w);
    defer ka.deinit(gpa);
    var kb = try keywords(gpa, b, w);
    defer kb.deinit(gpa);
    try std.testing.expectEqual(ka.items.len, kb.items.len);
    for (ka.items, kb.items) |x, y| {
        try std.testing.expectEqualStrings(x, y);
    }
}

fn countLines(output: []const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len != 0) n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Safety / portability regressions (pure zptx — always run).
// ---------------------------------------------------------------------------

test "portable: file input exits normally (SIGSYS regression)" {
    // Before the fix, readFile used std.os.linux.open/read/close — invalid
    // syscall numbers on macOS → the process died with SIGSYS (Term.signal),
    // exit 140 in a shell. A normal .exited{0} here proves the portable path.
    var out = try run(&.{ ZPTX, "/tmp/zptx_parity_basic.txt" });
    defer out.deinit(std.testing.allocator);
    // fixture may not exist on first run; create then re-run.
    try writeFixture("/tmp/zptx_parity_basic.txt", "the quick brown fox\n");
    var out2 = try run(&.{ ZPTX, "/tmp/zptx_parity_basic.txt" });
    defer out2.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u8, 0), out2.exitCode());
    try std.testing.expect(out2.stdout.len > 0);
}

test "portable: '-' (stdin path) exits normally, no SIGSYS" {
    // Exercises readStdin's portable posix.read. std.process.run gives the child
    // /dev/null on stdin, so read returns 0 → empty index → clean exit 0.
    var out = try run(&.{ ZPTX, "-" });
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u8, 0), out.exitCode());
}

test "no stack overflow: -w 600, over-long token, gap>=width" {
    const A = std.testing.allocator;
    try writeFixture("/tmp/zptx_parity_basic.txt", "the quick brown fox\n");

    // -w 600 -> left/right widths ~300, previously overflowed 256-byte buffers.
    var o1 = try run(&.{ ZPTX, "-w", "600", "/tmp/zptx_parity_basic.txt" });
    defer o1.deinit(A);
    try std.testing.expectEqual(@as(?u8, 0), o1.exitCode());

    // A single 400-char word previously overflowed the 256-byte right_buf.
    var big: [402]u8 = undefined;
    @memset(big[0..400], 'x');
    big[400] = '\n';
    big[401] = 0;
    try writeFixture("/tmp/zptx_parity_big.txt", big[0..401]);
    var o2 = try run(&.{ ZPTX, "/tmp/zptx_parity_big.txt" });
    defer o2.deinit(A);
    try std.testing.expectEqual(@as(?u8, 0), o2.exitCode());

    // gap >= width: width-gap previously underflowed usize -> huge -> OOB/hang.
    var o3 = try run(&.{ ZPTX, "-w", "2", "-g", "5", "/tmp/zptx_parity_basic.txt" });
    defer o3.deinit(A);
    try std.testing.expectEqual(@as(?u8, 0), o3.exitCode());
}

test "unknown option: diagnostic to stderr and exit 1" {
    // GNU ptx exits 1 with 'unrecognized option' on an unknown flag; zptx
    // previously ignored it and exited 0.
    try writeFixture("/tmp/zptx_parity_basic.txt", "the quick brown fox\n");
    var out = try run(&.{ ZPTX, "--bogus", "/tmp/zptx_parity_basic.txt" });
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u8, 1), out.exitCode());
    try std.testing.expect(std.mem.indexOf(u8, out.stderr, "unrecognized option") != null);
}

// ---------------------------------------------------------------------------
// Cross-checks against the real GNU binary (skip if gptx absent).
// ---------------------------------------------------------------------------

test "gptx parity: exit-code agreement (normal + unknown option)" {
    if (!gptxAvailable()) return error.SkipZigTest;
    const A = std.testing.allocator;
    try writeFixture("/tmp/zptx_parity_basic.txt", "the quick brown fox\n");

    var z = try run(&.{ ZPTX, "/tmp/zptx_parity_basic.txt" });
    defer z.deinit(A);
    var g = try run(&.{ GPTX, "/tmp/zptx_parity_basic.txt" });
    defer g.deinit(A);
    try std.testing.expectEqual(g.exitCode(), z.exitCode()); // both 0

    var zb = try run(&.{ ZPTX, "--bogus", "/tmp/zptx_parity_basic.txt" });
    defer zb.deinit(A);
    var gb = try run(&.{ GPTX, "--bogus", "/tmp/zptx_parity_basic.txt" });
    defer gb.deinit(A);
    try std.testing.expectEqual(gb.exitCode(), zb.exitCode()); // both 1
    try std.testing.expectEqual(@as(?u8, 1), zb.exitCode());
}

test "gptx parity: index line count (tokenization + ignore-file)" {
    if (!gptxAvailable()) return error.SkipZigTest;
    const A = std.testing.allocator;

    // Plain: one index line per (non-ignored) word occurrence, no wrap at -w 200.
    try writeFixture("/tmp/zptx_parity_nine.txt", "the quick brown fox jumps over the lazy dog\n");
    var z = try run(&.{ ZPTX, "-w", "200", "/tmp/zptx_parity_nine.txt" });
    defer z.deinit(A);
    var g = try run(&.{ GPTX, "-w", "200", "/tmp/zptx_parity_nine.txt" });
    defer g.deinit(A);
    try std.testing.expectEqual(countLines(g.stdout), countLines(z.stdout));

    // With an ignore list: 'the' (x2) and 'and' removed. gptx matches
    // case-sensitively; verified both drop the same words.
    try writeFixture("/tmp/zptx_parity_ign.txt", "the\nand\n");
    try writeFixture("/tmp/zptx_parity_ci.txt", "the cat and the dog\n");
    var zi = try run(&.{ ZPTX, "-w", "200", "-i", "/tmp/zptx_parity_ign.txt", "/tmp/zptx_parity_ci.txt" });
    defer zi.deinit(A);
    var gi = try run(&.{ GPTX, "-w", "200", "-i", "/tmp/zptx_parity_ign.txt", "/tmp/zptx_parity_ci.txt" });
    defer gi.deinit(A);
    try std.testing.expectEqual(countLines(gi.stdout), countLines(zi.stdout));
    try std.testing.expectEqual(@as(usize, 2), countLines(zi.stdout)); // cat, dog
}

test "gptx parity: keyword sort order is case-sensitive by default" {
    if (!gptxAvailable()) return error.SkipZigTest;
    const A = std.testing.allocator;
    // ASCII order puts capitalised words before lowercase: Banana, Date, apple, cherry.
    try writeFixture("/tmp/zptx_parity_four.txt", "apple Banana cherry Date\n");
    var z = try run(&.{ ZPTX, "-w", "100", "/tmp/zptx_parity_four.txt" });
    defer z.deinit(A);
    var g = try run(&.{ GPTX, "-w", "100", "/tmp/zptx_parity_four.txt" });
    defer g.deinit(A);
    try expectSameKeywords(A, z.stdout, g.stdout, 100);

    // And pin the literal reference sequence gptx produced (external value).
    var kz = try keywords(A, z.stdout, 100);
    defer kz.deinit(A);
    const expected = [_][]const u8{ "Banana", "Date", "apple", "cherry" };
    try std.testing.expectEqual(expected.len, kz.items.len);
    for (expected, kz.items) |e, got| try std.testing.expectEqualStrings(e, got);
}

test "gptx parity: -f/--ignore-case folds the sort order" {
    if (!gptxAvailable()) return error.SkipZigTest;
    const A = std.testing.allocator;
    // With folding the order becomes apple, Banana, cherry, Date. Previously -f
    // was a no-op (sort was unconditionally case-insensitive).
    try writeFixture("/tmp/zptx_parity_four.txt", "apple Banana cherry Date\n");
    var z = try run(&.{ ZPTX, "-w", "100", "-f", "/tmp/zptx_parity_four.txt" });
    defer z.deinit(A);
    var g = try run(&.{ GPTX, "-w", "100", "-f", "/tmp/zptx_parity_four.txt" });
    defer g.deinit(A);
    try expectSameKeywords(A, z.stdout, g.stdout, 100);

    var kz = try keywords(A, z.stdout, 100);
    defer kz.deinit(A);
    const expected = [_][]const u8{ "apple", "Banana", "cherry", "Date" };
    try std.testing.expectEqual(expected.len, kz.items.len);
    for (expected, kz.items) |e, got| try std.testing.expectEqualStrings(e, got);

    // The folded order must DIFFER from the default order, or -f is a no-op.
    var zdef = try run(&.{ ZPTX, "-w", "100", "/tmp/zptx_parity_four.txt" });
    defer zdef.deinit(A);
    var kdef = try keywords(A, zdef.stdout, 100);
    defer kdef.deinit(A);
    // first keyword differs: default "Banana" vs folded "apple".
    try std.testing.expect(!std.mem.eql(u8, kdef.items[0], kz.items[0]));
}
