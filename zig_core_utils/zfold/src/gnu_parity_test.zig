//! Externally-anchored GNU-parity tests for zfold.
//!
//! Every case is anchored against the REAL GNU `fold` binary (GNU coreutils
//! 9.10). Each test writes the input to a temp file, runs BOTH the freshly
//! built `zfold` and the reference `fold` over that file with identical argv,
//! and asserts byte-identical stdout AND identical exit codes. This is a true
//! external anchor: the expected bytes come from a program zfold's author did
//! not write. (fold reads a FILE argument identically to stdin, so file-mode
//! exercises the exact same code path.)
//!
//! A handful of literal anchors additionally pin the exact stdout bytes with
//! the documented GNU behavior cited in-source.
//!
//! If the GNU reference binary is not installed, the live-diff cases SKIP (they
//! do not silently pass), so the anchor can never rot into a roundtrip.

const std = @import("std");
const build_options = @import("build_options");

// Candidate paths for the GNU reference binary (Homebrew coreutils).
const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/fold",
    "/opt/homebrew/bin/gfold",
    "/usr/local/opt/coreutils/libexec/gnubin/fold",
    "/usr/local/bin/gfold",
};

const zfold_bin = build_options.zfold_bin;

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

/// Run `bin` with `flags` over an input file living in `dir` (relative name).
fn runOver(gpa: std.mem.Allocator, dir: std.Io.Dir, bin: []const u8, flags: []const []const u8, file_arg: []const u8) !Out {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, bin);
    try argv.appendSlice(gpa, flags);
    try argv.append(gpa, file_arg);

    const res = try std.process.run(gpa, std.testing.io, .{
        .argv = argv.items,
        .cwd = .{ .dir = dir },
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

/// Diff zfold vs GNU fold for identical flags + input. Asserts identical stdout
/// bytes and identical exit codes. SKIPs if GNU is unavailable.
fn expectMatchesGnu(flags: []const []const u8, input: []const u8) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const gnu = firstGnu() orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "input", .data = input });

    var zr = try runOver(gpa, tmp.dir, zfold_bin, flags, "input");
    defer zr.deinit();
    var gr = try runOver(gpa, tmp.dir, gnu, flags, "input");
    defer gr.deinit();

    std.testing.expectEqualSlices(u8, gr.stdout, zr.stdout) catch |e| {
        std.debug.print("stdout mismatch flags={any}\n  gnu:   {x}\n  zfold: {x}\n", .{ flags, gr.stdout, zr.stdout });
        return e;
    };
    std.testing.expectEqual(gr.code, zr.code) catch |e| {
        std.debug.print("exit mismatch flags={any} gnu={d} zfold={d}\n", .{ flags, gr.code, zr.code });
        return e;
    };
}

/// Run zfold only and assert exact stdout + exit code (literal anchor).
fn expectZfold(flags: []const []const u8, input: []const u8, want_stdout: []const u8, want_code: u8) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "input", .data = input });

    var zr = try runOver(gpa, tmp.dir, zfold_bin, flags, "input");
    defer zr.deinit();

    try std.testing.expectEqualSlices(u8, want_stdout, zr.stdout);
    try std.testing.expectEqual(want_code, zr.code);
}

// ---------------------------------------------------------------------------
// Column / wrapping correctness (anchored live against GNU fold)
// ---------------------------------------------------------------------------

test "hard wrap at width" {
    try expectMatchesGnu(&.{"-w3"}, "abcdefghij");
}

test "carriage return resets column (fold.c adjust_column: CR -> column=0)" {
    try expectMatchesGnu(&.{"-w3"}, "abc\rdefghi");
}

test "backspace decrements column (fold.c adjust_column: BS -> column--)" {
    try expectMatchesGnu(&.{"-w3"}, "ab\x08cdef");
    try expectMatchesGnu(&.{"-w3"}, "abcde\x08\x08\x08xyz");
}

test "tab advances to next 8-col tab stop (default, TAB_WIDTH=8)" {
    try expectMatchesGnu(&.{"-w4"}, "a\tbcdefg");
    try expectMatchesGnu(&.{"-w10"}, "a\tb\tc\tdef");
}

test "single char wider than width is emitted alone" {
    try expectMatchesGnu(&.{"-w4"}, "\tX");
}

test "byte mode counts every byte (no CR/BS/tab column magic)" {
    try expectMatchesGnu(&.{ "-b", "-w3" }, "abc\rdefghi");
    try expectMatchesGnu(&.{ "-b", "-w4" }, "a\tbcdefg");
    try expectMatchesGnu(&.{ "-b", "-w3" }, "ab\x08cdef");
}

test "character mode equals column mode in C locale" {
    try expectMatchesGnu(&.{ "-c", "-w3" }, "abc\rdefghi");
    try expectMatchesGnu(&.{ "-c", "-w4" }, "a\tbcdefg");
}

test "break at spaces (-s)" {
    try expectMatchesGnu(&.{ "-s", "-w5" }, "aa bb cc dd ee");
    try expectMatchesGnu(&.{ "-s", "-w10" }, "the quick brown fox jumps");
    try expectMatchesGnu(&.{ "-s", "-w4" }, "aaaaaaaa bb");
    try expectMatchesGnu(&.{ "-s", "-w6" }, "a b c d e f g h i j");
}

test "obsolete -WIDTH shorthand" {
    try expectMatchesGnu(&.{"-10"}, "abcdefghijklm");
    try expectMatchesGnu(&.{"-5"}, "abcdefghijklmnop");
}

test "newlines reset column and are preserved" {
    try expectMatchesGnu(&.{"-3"}, "abcdef\nghijkl\nm");
    try expectMatchesGnu(&.{"-3"}, "\n\nabc\n");
}

test "no trailing newline is preserved" {
    try expectMatchesGnu(&.{"-w3"}, "abcdef");
}

test "empty input" {
    try expectMatchesGnu(&.{"-w3"}, "");
}

test "default width 80" {
    const long = "x" ** 200;
    try expectMatchesGnu(&.{}, long);
}

test "mixed content stress" {
    try expectMatchesGnu(&.{"-w8"}, "hello\tworld\rfoo\x08bar baz\nqux");
    try expectMatchesGnu(&.{ "-s", "-w8" }, "hello\tworld foo bar baz\nqux");
}

// ---------------------------------------------------------------------------
// Argument / exit-code parity (anchored live against GNU fold)
// ---------------------------------------------------------------------------

test "width 0 is rejected with exit 1" {
    try expectMatchesGnu(&.{"-w0"}, "abc");
}

test "non-numeric width is rejected with exit 1" {
    try expectMatchesGnu(&.{ "-w", "abc" }, "abc");
}

test "overflowing width is rejected with exit 1" {
    try expectMatchesGnu(&.{ "-w", "999999999999999999999999" }, "abc");
}

test "unknown option is rejected with exit 1" {
    try expectMatchesGnu(&.{"-Z"}, "abc");
}

test "non-GNU -T option is rejected with exit 1" {
    // GNU fold has no -T; it must error, not silently accept a tab width.
    try expectMatchesGnu(&.{ "-T", "4" }, "abc");
}

// ---------------------------------------------------------------------------
// Literal anchors (documented GNU/POSIX behavior pinned in-source)
// ---------------------------------------------------------------------------

test "literal: CR resets the column (GNU coreutils fold.c adjust_column)" {
    // `printf 'abc\rdefghi' | fold -w3` under GNU (coreutils 9.10) yields
    // "abc\rdef\nghi": the CR resets the column to 0 so 'def' occupies a fresh
    // 3 columns and only THEN does a fold occur before 'ghi'. The pre-fix zfold
    // treated CR as a 0-width control char and produced a spurious extra fold
    // right after the CR ("abc\r\ndef\nghi").
    try expectZfold(&.{"-w3"}, "abc\rdefghi", "abc\rdef\nghi", 0);
}

test "literal: plain hard wrap inserts newlines every WIDTH columns" {
    try expectZfold(&.{"-w3"}, "abcdefghij", "abc\ndef\nghi\nj", 0);
}

test "literal: width 0 error exits 1 with empty stdout" {
    try expectZfold(&.{"-w0"}, "abc", "", 1);
}

test "literal: missing file exits 1" {
    // No temp file needed; the point is the open failure.
    const gpa = std.testing.allocator;
    const res = try std.process.run(gpa, std.testing.io, .{
        .argv = &.{ zfold_bin, "/nonexistent_zfold_xyz_12345" },
    });
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    try std.testing.expectEqualSlices(u8, "", res.stdout);
    try std.testing.expectEqual(@as(u8, 1), exitCode(res.term));
}
