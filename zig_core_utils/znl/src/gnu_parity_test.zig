//! Externally-anchored GNU-parity tests for znl.
//!
//! ANCHOR: every expected byte string in this file was captured from the real
//! GNU coreutils `nl` (GNU coreutils 9.10, /opt/homebrew/bin/gnl) — NOT from
//! znl itself. These are golden vectors from a different implementation, per
//! the zig-forge golden rule (external anchor, no roundtrip-only tests).
//!
//! Two layers:
//!   1. `expectOutput` — compares znl's bytes against the literal GNU-produced
//!      output recorded in comments. Runs everywhere, even with no GNU binary.
//!   2. live cross-check — when a GNU `nl` binary is present on this machine, it
//!      re-runs the SAME inputs through GNU and asserts znl == GNU byte for byte.
//!      This is the strongest anchor and self-documents that the literals above
//!      still match the reference.
//!
//! The znl binary under test is passed in from build.zig via build options
//! (`znl_bin`) so `zig build test` exercises the real compiled executable.

const std = @import("std");
const build_options = @import("build_options");

const znl_bin = build_options.znl_bin;
const io = std.testing.io;

// Candidate paths for a real GNU `nl` (Homebrew coreutils / Linux). Used only
// for the optional live cross-check; absence never fails a test.
const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/nl",
    "/opt/homebrew/bin/gnl",
    "/usr/bin/nl", // GNU on Linux
};

fn termCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |c| c,
        else => 255,
    };
}

/// Write `input` into `dir` as input.txt and run `bin flags... input.txt`.
/// Caller owns result.stdout / result.stderr.
fn runWithFile(
    alloc: std.mem.Allocator,
    dir: std.Io.Dir,
    bin: []const u8,
    flags: []const []const u8,
    input: []const u8,
) !std.process.RunResult {
    try dir.writeFile(io, .{ .sub_path = "input.txt", .data = input });
    const file_path = try dir.realPathFileAlloc(io, "input.txt", alloc);
    defer alloc.free(file_path);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, bin);
    for (flags) |f| try argv.append(alloc, f);
    try argv.append(alloc, file_path);

    return std.process.run(alloc, io, .{ .argv = argv.items });
}

fn findGnu() ?[]const u8 {
    for (gnu_candidates) |c| {
        std.Io.Dir.accessAbsolute(io, c, .{}) catch continue;
        return c;
    }
    return null;
}

/// Run znl over `input` with `flags` and assert stdout == `expected`
/// (a literal GNU-produced byte string) and exit code 0. When a GNU binary is
/// available, additionally assert znl == GNU live.
fn expectOutput(flags: []const []const u8, input: []const u8, expected: []const u8) !void {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const r = try runWithFile(alloc, tmp.dir, znl_bin, flags, input);
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);

    try std.testing.expectEqual(@as(u8, 0), termCode(r.term));
    try std.testing.expectEqualStrings(expected, r.stdout);

    if (findGnu()) |gnu| {
        const g = try runWithFile(alloc, tmp.dir, gnu, flags, input);
        defer alloc.free(g.stdout);
        defer alloc.free(g.stderr);
        try std.testing.expectEqualStrings(g.stdout, r.stdout);
    }
}

/// Run znl with `flags` (plus a valid file) and assert the exit code.
/// Cross-checks against GNU when available.
fn expectExit(flags: []const []const u8, expected_code: u8) !void {
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const r = try runWithFile(alloc, tmp.dir, znl_bin, flags, "alpha\n");
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);
    try std.testing.expectEqual(expected_code, termCode(r.term));

    if (findGnu()) |gnu| {
        const g = try runWithFile(alloc, tmp.dir, gnu, flags, "alpha\n");
        defer alloc.free(g.stdout);
        defer alloc.free(g.stderr);
        try std.testing.expectEqual(termCode(g.term), termCode(r.term));
    }
}

const three_lines = "alpha\n\nbeta\n"; // alpha, blank, beta

// --- Content parity (literals captured from GNU nl 9.10) ---

test "default: number non-empty body lines, blank line padded" {
    // GNU: `printf 'alpha\n\nbeta\n' | nl`
    //   "     1\talpha\n" (width 6, tab sep) + "       \n" (7-space pad = w6+sep1) + "     2\tbeta\n"
    try expectOutput(&.{}, three_lines, "     1\talpha\n       \n     2\tbeta\n");
}

test "-b a: number all lines including blank" {
    // GNU: `nl -b a` numbers the blank line too.
    try expectOutput(&.{ "-b", "a" }, three_lines, "     1\talpha\n     2\t\n     3\tbeta\n");
}

test "-w 40: wide field must not drop the number (HIGH bug regression)" {
    // GNU right-justifies into 40 columns: 39 spaces then '1'.
    const line1 = " " ** 39 ++ "1\talpha\n";
    const line2 = " " ** 39 ++ "2\t\n";
    const line3 = " " ** 39 ++ "3\tbeta\n";
    try expectOutput(&.{ "-w", "40", "-b", "a" }, three_lines, line1 ++ line2 ++ line3);
}

test "-w 100: very wide field" {
    const line1 = " " ** 99 ++ "1\talpha\n";
    const line2 = " " ** 99 ++ "2\t\n";
    const line3 = " " ** 99 ++ "3\tbeta\n";
    try expectOutput(&.{ "-w", "100", "-b", "a" }, three_lines, line1 ++ line2 ++ line3);
}

test "-n rz -w 4: right justified, zero padded" {
    // GNU: "0001\talpha\n" + "     \n" (w4+sep1 = 5-space pad) + "0002\tbeta\n"
    try expectOutput(&.{ "-n", "rz", "-w", "4" }, three_lines, "0001\talpha\n     \n0002\tbeta\n");
}

test "-n ln: left justified, no leading zeros" {
    // GNU: "1     \talpha\n" (num left-justified in 6 cols) + "       \n" + "2     \tbeta\n"
    try expectOutput(&.{ "-n", "ln" }, three_lines, "1     \talpha\n       \n2     \tbeta\n");
}

test "-s long separator: unnumbered pad tracks width+separator (MED bug regression)" {
    // 70-char separator; pad on the blank line must be width(6)+sep(70) spaces.
    const sep = "X" ** 70;
    const pad = " " ** (6 + 70);
    const expected = "     1" ++ sep ++ "alpha\n" ++ pad ++ "\n" ++ "     2" ++ sep ++ "beta\n";
    try expectOutput(&.{ "-s", sep }, three_lines, expected);
}

test "-v -i: starting line number and increment" {
    // GNU: start at 10, increment 5, number all lines.
    try expectOutput(&.{ "-v", "10", "-i", "5", "-b", "a" }, three_lines, "    10\talpha\n    15\t\n    20\tbeta\n");
}

test "-d single char pads with ':' (section delimiter parity)" {
    // GNU: `-d '#'` => delimiter string "#:"; a line "#:" is a footer marker
    // (renumbers, not printed). Input: H, "#:", footerline. body 'H' => 1;
    // "#:" => section change to footer (blank line emitted); footer numbered => 1.
    const input = "H\n#:\nfooterline\n";
    try expectOutput(&.{ "-d", "#", "-b", "a", "-f", "a" }, input, "     1\tH\n\n     1\tfooterline\n");
}

// --- Exit-code parity (GNU exits 1 on these) ---

test "invalid body numbering style exits 1" {
    try expectExit(&.{ "-b", "x" }, 1);
}

test "invalid field width exits 1" {
    try expectExit(&.{ "-w", "abc" }, 1);
}

test "invalid number format exits 1" {
    try expectExit(&.{ "-n", "zz" }, 1);
}

test "unknown short option exits 1" {
    try expectExit(&.{"-Z"}, 1);
}

test "unknown long option exits 1" {
    try expectExit(&.{"--bogus"}, 1);
}

test "missing file exits 1" {
    const alloc = std.testing.allocator;
    const r = try std.process.run(alloc, io, .{ .argv = &.{ znl_bin, "/nonexistent/znl/path" } });
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);
    try std.testing.expectEqual(@as(u8, 1), termCode(r.term));
}

test "directory argument exits 1" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir_path);
    const r = try std.process.run(alloc, io, .{ .argv = &.{ znl_bin, dir_path } });
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);
    try std.testing.expectEqual(@as(u8, 1), termCode(r.term));
}

// --- Stream routing parity: --help / --version go to stdout, exit 0 ---

test "--version writes to stdout and exits 0" {
    const alloc = std.testing.allocator;
    const r = try std.process.run(alloc, io, .{ .argv = &.{ znl_bin, "--version" } });
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);
    try std.testing.expectEqual(@as(u8, 0), termCode(r.term));
    try std.testing.expect(r.stdout.len > 0); // GNU nl writes --version to stdout
    try std.testing.expectEqual(@as(usize, 0), r.stderr.len);
}

test "--help writes to stdout and exits 0" {
    const alloc = std.testing.allocator;
    const r = try std.process.run(alloc, io, .{ .argv = &.{ znl_bin, "--help" } });
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);
    try std.testing.expectEqual(@as(u8, 0), termCode(r.term));
    try std.testing.expect(r.stdout.len > 0); // GNU nl writes --help to stdout
    try std.testing.expectEqual(@as(usize, 0), r.stderr.len);
}
