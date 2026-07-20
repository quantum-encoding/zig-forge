//! Externally-anchored GNU-parity tests for zsum.
//!
//! Primary anchor: the REAL GNU `sum` binary (Homebrew coreutils 9.10). For a
//! spread of representative inputs and flags we run BOTH the freshly built
//! `zsum` and the reference `sum` with identical argv over the same files, and
//! assert byte-identical stdout AND identical exit codes. The expected bytes
//! come from a program zsum's author did not write — a true external anchor.
//!
//! Second layer: literal anchors that hard-code GNU sum's exact output bytes
//! (captured from `gsum`, GNU coreutils 9.10) so the wire format stays pinned
//! even on a machine with no GNU binary. These are NOT roundtrip tests — they
//! assert the exact GNU bytes, independently of zsum's own encoder. The key
//! regression they guard: the BSD checksum MUST be zero-padded to 5 digits
//! ("03762"), never space-padded ("   3762").
//!
//! If the GNU reference binary is not installed, the live-diff cases SKIP (they
//! never silently pass), so the anchor can never rot into a self-comparison.
//!
//! `std.process.run` always feeds an EMPTY stdin, so no-operand cases exercise
//! the empty-input path; the checksum algorithm itself is fully covered by the
//! multi-kilobyte file fixtures (file mode and stdin share one read loop).

const std = @import("std");
const build_options = @import("build_options");

const zsum_bin = build_options.zsum_bin;

// Candidate paths for the GNU reference binary (Homebrew coreutils). Note that
// macOS /usr/bin/sum is BSD sum with a different format, so it is NOT listed.
const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/sum",
    "/opt/homebrew/bin/gsum",
    "/usr/local/opt/coreutils/libexec/gnubin/sum",
    "/usr/local/bin/gsum",
};

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |c| c,
        else => 255,
    };
}

const Out = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,
    gpa: std.mem.Allocator,
    fn deinit(self: *Out) void {
        self.gpa.free(self.stdout);
        self.gpa.free(self.stderr);
    }
};

/// Run `bin` with `args` in `dir` (or no cwd if null).
fn runIn(gpa: std.mem.Allocator, dir: ?std.Io.Dir, bin: []const u8, args: []const []const u8) !Out {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, bin);
    try argv.appendSlice(gpa, args);

    const res = try std.process.run(gpa, std.testing.io, .{
        .argv = argv.items,
        .cwd = if (dir) |d| .{ .dir = d } else .inherit,
    });
    return .{ .stdout = res.stdout, .stderr = res.stderr, .code = exitCode(res.term), .gpa = gpa };
}

fn firstGnu() ?[]const u8 {
    const io = std.testing.io;
    for (gnu_candidates) |p| {
        std.Io.Dir.accessAbsolute(io, p, .{}) catch continue;
        return p;
    }
    return null;
}

/// Diff zsum vs GNU sum for identical args in a temp dir seeded with `fixtures`
/// (name/contents pairs). Asserts identical stdout AND identical exit codes.
/// SKIPs if GNU is unavailable.
const Fixture = struct { name: []const u8, data: []const u8 };

fn expectMatchesGnu(fixtures: []const Fixture, args: []const []const u8) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const gnu = firstGnu() orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (fixtures) |f| try tmp.dir.writeFile(io, .{ .sub_path = f.name, .data = f.data });

    var zr = try runIn(gpa, tmp.dir, zsum_bin, args);
    defer zr.deinit();
    var gr = try runIn(gpa, tmp.dir, gnu, args);
    defer gr.deinit();

    std.testing.expectEqualSlices(u8, gr.stdout, zr.stdout) catch |e| {
        std.debug.print("stdout mismatch args={any}\n  gnu:  '{s}'\n  zsum: '{s}'\n", .{ args, gr.stdout, zr.stdout });
        return e;
    };
    std.testing.expectEqual(gr.code, zr.code) catch |e| {
        std.debug.print("exit mismatch args={any} gnu={d} zsum={d}\n", .{ args, gr.code, zr.code });
        return e;
    };
}

/// Run zsum only in a fixture temp dir and assert exact stdout + exit code.
fn expectZsum(fixtures: []const Fixture, args: []const []const u8, want_stdout: []const u8, want_code: u8) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (fixtures) |f| try tmp.dir.writeFile(io, .{ .sub_path = f.name, .data = f.data });

    var zr = try runIn(gpa, tmp.dir, zsum_bin, args);
    defer zr.deinit();

    std.testing.expectEqualSlices(u8, want_stdout, zr.stdout) catch |e| {
        std.debug.print("stdout mismatch args={any}\n  want: '{s}'\n  got:  '{s}'\n", .{ args, want_stdout, zr.stdout });
        return e;
    };
    try std.testing.expectEqual(want_code, zr.code);
}

// A block of representative fixtures reused across the live-diff tests.
fn onekb() [1024]u8 {
    var kb: [1024]u8 = undefined;
    for (&kb, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    return kb;
}
fn big5000() [5000]u8 {
    var b: [5000]u8 = undefined;
    @memset(&b, 'A');
    return b;
}

// ---------------------------------------------------------------------------
// Layer 1: live diff against the real GNU `sum`.
// ---------------------------------------------------------------------------

test "GNU parity: each fixture in BSD (default, -r) and SysV (-s, --sysv)" {
    const kb = onekb();
    const big = big5000();
    const fx = [_]Fixture{
        .{ .name = "hello.txt", .data = "hello world\n" },
        .{ .name = "fox.txt", .data = "The quick brown fox\n" },
        .{ .name = "empty.txt", .data = "" },
        .{ .name = "onekb.bin", .data = &kb },
        .{ .name = "big.txt", .data = &big },
    };
    const names = [_][]const u8{ "hello.txt", "fox.txt", "empty.txt", "onekb.bin", "big.txt" };
    for (names) |n| {
        try expectMatchesGnu(&fx, &.{n});
        try expectMatchesGnu(&fx, &.{ "-r", n });
        try expectMatchesGnu(&fx, &.{ "-s", n });
        try expectMatchesGnu(&fx, &.{ "--sysv", n });
    }
}

test "GNU parity: multiple operands in one run (shared-writer offset)" {
    const big = big5000();
    const fx = [_]Fixture{
        .{ .name = "hello.txt", .data = "hello world\n" },
        .{ .name = "fox.txt", .data = "The quick brown fox\n" },
        .{ .name = "big.txt", .data = &big },
    };
    try expectMatchesGnu(&fx, &.{ "hello.txt", "fox.txt", "big.txt" });
    try expectMatchesGnu(&fx, &.{ "-s", "hello.txt", "fox.txt" });
}

test "GNU parity: bundled short options and -- separator" {
    const fx = [_]Fixture{.{ .name = "hello.txt", .data = "hello world\n" }};
    // getopt semantics: last of a cluster wins.
    try expectMatchesGnu(&fx, &.{ "-rs", "hello.txt" }); // -> SysV
    try expectMatchesGnu(&fx, &.{ "-sr", "hello.txt" }); // -> BSD
    try expectMatchesGnu(&fx, &.{ "--", "hello.txt" });
}

test "GNU parity: empty stdin no-operand path (no-filename format branch)" {
    // std.process.run feeds an empty stdin; exercises the no-filename branch.
    try expectMatchesGnu(&.{}, &.{});
    try expectMatchesGnu(&.{}, &.{"-s"});
    try expectMatchesGnu(&.{}, &.{"-r"});
}

test "GNU parity: error operands set exit 1 and print no checksum line" {
    // Missing file.
    try expectMatchesGnu(&.{}, &.{"nope_missing.xyz"});
    // Unknown short option.
    const fx = [_]Fixture{.{ .name = "good.txt", .data = "hello world\n" }};
    try expectMatchesGnu(&fx, &.{ "-x", "good.txt" });
    // Unknown long option.
    try expectMatchesGnu(&fx, &.{ "--bogus", "good.txt" });
    // A failed operand followed by a good one: exit 1, good line still printed.
    try expectMatchesGnu(&fx, &.{ "nope.xyz", "good.txt" });
}

test "GNU parity: directory operand -> Is a directory, exit 1" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const gnu = firstGnu() orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "adir");

    var zr = try runIn(gpa, tmp.dir, zsum_bin, &.{"adir"});
    defer zr.deinit();
    var gr = try runIn(gpa, tmp.dir, gnu, &.{"adir"});
    defer gr.deinit();

    try std.testing.expectEqualSlices(u8, gr.stdout, zr.stdout); // both empty
    try std.testing.expectEqual(gr.code, zr.code); // both 1
    try std.testing.expectEqual(@as(u8, 1), zr.code);
}

test "GNU parity: permission-denied file -> Permission denied, exit 1" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const gnu = firstGnu() orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Create the file with mode 000 so the same user cannot read it.
    try tmp.dir.writeFile(io, .{
        .sub_path = "noperm.txt",
        .data = "x",
        .flags = .{ .permissions = .fromMode(0o000) },
    });

    var zr = try runIn(gpa, tmp.dir, zsum_bin, &.{"noperm.txt"});
    defer zr.deinit();
    var gr = try runIn(gpa, tmp.dir, gnu, &.{"noperm.txt"});
    defer gr.deinit();

    try std.testing.expectEqualSlices(u8, gr.stdout, zr.stdout); // both empty
    try std.testing.expectEqual(gr.code, zr.code);
    try std.testing.expectEqual(@as(u8, 1), zr.code);
}

// ---------------------------------------------------------------------------
// Layer 2: literal GNU-output anchors (GNU coreutils 9.10 `gsum`).
// ---------------------------------------------------------------------------

test "literal: BSD default output is zero-padded to 5 digits" {
    // `gsum hello.txt` -> "03762     1 hello.txt\n"  (GNU coreutils 9.10).
    // Pre-fix zsum emitted "   3762     1 hello.txt\n" (space-padded) — differs
    // from GNU byte-for-byte on every BSD line. This anchor guards that.
    const fx = [_]Fixture{.{ .name = "hello.txt", .data = "hello world\n" }};
    try expectZsum(&fx, &.{"hello.txt"}, "03762     1 hello.txt\n", 0);
}

test "literal: SysV output is unpadded with 512-byte blocks" {
    // `gsum -s hello.txt` -> "1126 1 hello.txt\n"  (GNU coreutils 9.10).
    const fx = [_]Fixture{.{ .name = "hello.txt", .data = "hello world\n" }};
    try expectZsum(&fx, &.{ "-s", "hello.txt" }, "1126 1 hello.txt\n", 0);
}

test "literal: empty file is 00000 0, 5000-byte file is 24691 5" {
    // `gsum empty.txt` -> "00000     0 empty.txt\n"
    // `gsum big.txt` (5000×'A') -> "24691     5 big.txt\n"
    const big = big5000();
    const fx = [_]Fixture{
        .{ .name = "empty.txt", .data = "" },
        .{ .name = "big.txt", .data = &big },
    };
    try expectZsum(&fx, &.{"empty.txt"}, "00000     0 empty.txt\n", 0);
    try expectZsum(&fx, &.{"big.txt"}, "24691     5 big.txt\n", 0);
}

test "literal: missing file exits 1 with empty stdout and a GNU-style message" {
    const gpa = std.testing.allocator;
    const res = try std.process.run(gpa, std.testing.io, .{
        .argv = &.{ zsum_bin, "definitely_missing_zsum_xyz_12345" },
    });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    try std.testing.expectEqualSlices(u8, "", res.stdout);
    try std.testing.expectEqual(@as(u8, 1), exitCode(res.term));
    // GNU diagnostic text (program-name prefix aside).
    try std.testing.expect(std.mem.indexOf(u8, res.stderr, "No such file or directory") != null);
}

test "literal: unknown option exits 1 with empty stdout" {
    const gpa = std.testing.allocator;
    const res = try std.process.run(gpa, std.testing.io, .{
        .argv = &.{ zsum_bin, "-Z" },
    });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    try std.testing.expectEqualSlices(u8, "", res.stdout);
    try std.testing.expectEqual(@as(u8, 1), exitCode(res.term));
    try std.testing.expect(std.mem.indexOf(u8, res.stderr, "invalid option") != null);
}

test "more than 64 operands are all processed (no fixed-array cap)" {
    // The old code buffered operands into a fixed [64] array and silently
    // dropped the 65th+. 100 copies of one file must yield 100 output lines.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "hello world\n" });

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(gpa);
    for (0..100) |_| try args.append(gpa, "hello.txt");

    var zr = try runIn(gpa, tmp.dir, zsum_bin, args.items);
    defer zr.deinit();

    var lines: usize = 0;
    for (zr.stdout) |c| {
        if (c == '\n') lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 100), lines);
    try std.testing.expectEqual(@as(u8, 0), zr.code);
}
