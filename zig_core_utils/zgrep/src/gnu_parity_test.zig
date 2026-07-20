//! GNU-grep parity tests for zgrep.
//!
//! EXTERNAL ANCHORING (per zig-forge/CLAUDE.md golden rule):
//!   * No GNU coreutils `grep`/`ggrep` binary is installed on this machine, so
//!     the expected output bytes below are written literally and each is
//!     justified against DOCUMENTED GNU grep / POSIX behaviour (cited inline).
//!   * Where GNU and BSD grep agree, the test ALSO cross-checks zgrep's output
//!     byte-for-byte against the independent BSD `grep` at /usr/bin/grep
//!     (grep 2.6.0-FreeBSD) — a real third-party implementation the zgrep
//!     author did not write. `crossCheck()` is that anchor.
//!   * None of these are roundtrip (decode(encode(x))==x) tests: every case
//!     pins a concrete input -> concrete expected output taken from an external
//!     source, so deleting the roundtrip-free set still covers match/no-match,
//!     counting, inversion, alternation, BRE-vs-ERE and exit codes.
//!
//! The `test` build step depends on the install step, so the binary exists at
//! its default install path (zig-out/bin/zgrep) relative to the build root,
//! which is the test process's working directory. ZGREP_BIN overrides it.

const std = @import("std");
const Io = std.Io;

const BSD_GREP = "/usr/bin/grep";
// Fixtures live in the system temp dir (absolute), never in the repo tree, so a
// chronos `git add .` tick can't accidentally track test scratch.
const TMP_DIR = "/tmp/zgrep-parity-tests";

fn theIo() Io {
    return Io.Threaded.global_single_threaded.io();
}

/// Path to the zgrep binary under test.
fn zgrepBin() []const u8 {
    if (std.c.getenv("ZGREP_BIN")) |p| return std.mem.span(p);
    return "zig-out/bin/zgrep";
}

const Result = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8,
    fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

fn readAll(gpa: std.mem.Allocator, f: Io.File) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(gpa);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = std.posix.read(f.handle, &buf) catch break;
        if (n == 0) break;
        try list.appendSlice(gpa, buf[0..n]);
    }
    return list.toOwnedSlice(gpa);
}

fn spawnCapture(
    gpa: std.mem.Allocator,
    argv: []const []const u8,
    stdin: std.process.SpawnOptions.StdIo,
) !Result {
    // The global single-threaded Io uses a `.failing` allocator, but
    // process.spawn allocates an argv arena, so build a Threaded backed by a
    // real allocator for the spawn/wait.
    var t = Io.Threaded.init(gpa, .{});
    defer t.deinit();
    const io = t.io();
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = stdin,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    // Outputs here are tiny (well under a pipe buffer), so a sequential
    // read-then-wait cannot deadlock.
    const out = try readAll(gpa, child.stdout.?);
    errdefer gpa.free(out);
    const err = try readAll(gpa, child.stderr.?);
    const term = child.wait(io) catch |e| {
        gpa.free(err);
        return e;
    };
    const code: u8 = switch (term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = out, .stderr = err, .code = code };
}

/// Run `bin` with `args` (each an argv entry AFTER the binary), feeding `input`
/// on stdin via a temp file. Returns captured stdout/stderr/exit.
fn runStdin(gpa: std.mem.Allocator, bin: []const u8, args: []const []const u8, input: []const u8) !Result {
    const io = theIo();
    Io.Dir.cwd().createDirPath(io, TMP_DIR) catch {};
    const in_path = try std.fmt.allocPrint(gpa, "{s}/in.txt", .{TMP_DIR});
    defer gpa.free(in_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = in_path, .data = input });

    const in_file = try Io.Dir.cwd().openFile(io, in_path, .{});
    defer in_file.close(io);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, bin);
    try argv.appendSlice(gpa, args);
    return spawnCapture(gpa, argv.items, .{ .file = in_file });
}

/// Run with explicit argv (stdin ignored) — for file/recursive/error tests.
fn runArgs(gpa: std.mem.Allocator, bin: []const u8, args: []const []const u8) !Result {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, bin);
    try argv.appendSlice(gpa, args);
    return spawnCapture(gpa, argv.items, .ignore);
}

/// External-implementation anchor: assert zgrep's stdout matches BSD grep's
/// stdout byte-for-byte for the same args + stdin (only valid where GNU==BSD).
fn crossCheck(gpa: std.mem.Allocator, args: []const []const u8, input: []const u8) !void {
    const zbin = zgrepBin();
    var z = try runStdin(gpa, zbin, args, input);
    defer z.deinit(gpa);
    var b = try runStdin(gpa, BSD_GREP, args, input);
    defer b.deinit(gpa);
    std.testing.expectEqualStrings(b.stdout, z.stdout) catch |e| {
        std.debug.print("crossCheck mismatch: bsd=[{s}] zg=[{s}]\n", .{ b.stdout, z.stdout });
        return e;
    };
}

// --- Basic matching (regression guard for the SIGSYS/raw-syscall crash) -----
// POSIX: grep writes each selected (matching) line to stdout; exit 0 if a line
// is selected, 1 if none. (IEEE Std 1003.1 grep, "EXIT STATUS".)

test "literal match prints the matching line, exit 0" {
    const gpa = std.testing.allocator;
    var r = try runStdin(gpa, zgrepBin(), &.{"hello"}, "hello\nworld\n");
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("hello\n", r.stdout);
    try std.testing.expectEqual(@as(u8, 0), r.code);
}

test "no match: empty stdout, exit 1" {
    const gpa = std.testing.allocator;
    var r = try runStdin(gpa, zgrepBin(), &.{"zzz"}, "hello\nworld\n");
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("", r.stdout);
    try std.testing.expectEqual(@as(u8, 1), r.code);
}

test "cross-check BSD grep: literal, -v, -n, -i, -o, -c" {
    const gpa = std.testing.allocator;
    const in = "alpha\nBETA\nalpha beta\ngamma\n";
    try crossCheck(gpa, &.{"alpha"}, in);
    try crossCheck(gpa, &.{ "-v", "alpha" }, in);
    try crossCheck(gpa, &.{ "-n", "beta" }, in);
    try crossCheck(gpa, &.{ "-i", "beta" }, in);
    try crossCheck(gpa, &.{ "-o", "alpha" }, in);
    try crossCheck(gpa, &.{ "-c", "alpha" }, in);
}

// --- -c with -m (audit medium: -c -m1 printed nothing) ----------------------
// GNU grep manual, -m NUM: "grep stops reading ... after NUM matching lines";
// combined with -c the printed count is min(total, NUM). So `-c -m1` over two
// matches prints "1".

test "-c -m1 prints 1 (not empty)" {
    const gpa = std.testing.allocator;
    var r = try runStdin(gpa, zgrepBin(), &.{ "-c", "-m1", "a" }, "a\na\na\n");
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("1\n", r.stdout);
    try std.testing.expectEqual(@as(u8, 0), r.code);
}

test "-m1 prints exactly one matching line" {
    const gpa = std.testing.allocator;
    var r = try runStdin(gpa, zgrepBin(), &.{ "-m1", "a" }, "a\na\na\n");
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("a\n", r.stdout);
}

// --- ERE groups + alternation (audit medium: (ab|cd) compiled to "abcd") ----
// POSIX ERE: `(ab|cd)` matches a string containing "ab" OR "cd". Anchored to
// the POSIX ERE grammar (IEEE Std 1003.1, "Extended Regular Expressions").

test "ERE (ab|cd) matches ab" {
    const gpa = std.testing.allocator;
    var r = try runStdin(gpa, zgrepBin(), &.{ "-E", "(ab|cd)" }, "ab\n");
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("ab\n", r.stdout);
    try std.testing.expectEqual(@as(u8, 0), r.code);
}

test "ERE (ab|cd) matches cd inside a larger line" {
    const gpa = std.testing.allocator;
    var r = try runStdin(gpa, zgrepBin(), &.{ "-E", "(ab|cd)" }, "xxcdyy\n");
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("xxcdyy\n", r.stdout);
}

test "ERE (ab|cd) does NOT match ef" {
    const gpa = std.testing.allocator;
    var r = try runStdin(gpa, zgrepBin(), &.{ "-E", "(ab|cd)" }, "ef\n");
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("", r.stdout);
    try std.testing.expectEqual(@as(u8, 1), r.code);
}

test "ERE prefix(a|b)suffix distributes correctly" {
    const gpa = std.testing.allocator;
    // (foo|bar)baz matches "foobaz" and "barbaz" but not "quxbaz".
    var yes1 = try runStdin(gpa, zgrepBin(), &.{ "-E", "(foo|bar)baz" }, "foobaz\n");
    defer yes1.deinit(gpa);
    try std.testing.expectEqualStrings("foobaz\n", yes1.stdout);
    var yes2 = try runStdin(gpa, zgrepBin(), &.{ "-E", "(foo|bar)baz" }, "barbaz\n");
    defer yes2.deinit(gpa);
    try std.testing.expectEqualStrings("barbaz\n", yes2.stdout);
    var no = try runStdin(gpa, zgrepBin(), &.{ "-E", "(foo|bar)baz" }, "quxbaz\n");
    defer no.deinit(gpa);
    try std.testing.expectEqualStrings("", no.stdout);
}

// --- BRE vs ERE default (audit medium: default treated + as a metachar) -----
// POSIX BRE (grep's default, no -E): `+ ? | ( )` are ORDINARY characters, so
// `a+b` matches the literal text "a+b". BSD grep defaults to BRE too, so this
// is additionally cross-checked against /usr/bin/grep.

test "default (BRE): a+b is literal" {
    const gpa = std.testing.allocator;
    var r = try runStdin(gpa, zgrepBin(), &.{"a+b"}, "a+b\naab\n");
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("a+b\n", r.stdout);
    // Independent-implementation anchor:
    try crossCheck(gpa, &.{"a+b"}, "a+b\naab\n");
}

test "-E (ERE): a+b is a quantifier" {
    const gpa = std.testing.allocator;
    var r = try runStdin(gpa, zgrepBin(), &.{ "-E", "a+b" }, "aab\nb\n");
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("aab\n", r.stdout);
}

test "default (BRE): literal parens, cross-checked against BSD grep" {
    const gpa = std.testing.allocator;
    // In BRE, "(x)" matches the literal 3-char text "(x)".
    try crossCheck(gpa, &.{"(x)"}, "(x)\nx\n");
    try crossCheck(gpa, &.{"a|b"}, "a|b\na\n");
}

// --- Character-class offset overflow (audit medium: u16 truncation) ---------
// A pattern whose expanded [class] exceeds 65535 bytes must not panic or read
// out of bounds; it must still match. Anchored to the semantic fact that
// [a-z] matches 'm'. (Pre-fix this truncated the u16 class offset.)

test "huge character class does not overflow and still matches" {
    const gpa = std.testing.allocator;
    // Build "[" ++ ("a-z" * 30000) ++ "]" -> expands to ~780000 class bytes.
    var pat: std.ArrayListUnmanaged(u8) = .empty;
    defer pat.deinit(gpa);
    try pat.append(gpa, '[');
    var k: usize = 0;
    while (k < 30000) : (k += 1) try pat.appendSlice(gpa, "a-z");
    try pat.append(gpa, ']');
    var r = try runStdin(gpa, zgrepBin(), &.{ "-E", pat.items }, "m\n");
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("m\n", r.stdout);
    try std.testing.expectEqual(@as(u8, 0), r.code);
}

// --- Long line crossing a read-buffer boundary (audit HIGH: data loss) ------
// A line longer than the old 8 KB leftover buffer, straddling a 256 KB read
// chunk, previously had its tail silently dropped. GNU grep matches regardless
// of line length; here the needle sits ~20 KB into such a line.

test "match on a >8KB line that crosses a read boundary" {
    const gpa = std.testing.allocator;
    var in: std.ArrayListUnmanaged(u8) = .empty;
    defer in.deinit(gpa);
    // First line pads right up to the 256 KB read boundary.
    try in.appendNTimes(gpa, 'x', 256 * 1024 - 50);
    try in.append(gpa, '\n');
    // Second line is long and carries the needle well past 8 KB.
    try in.appendNTimes(gpa, 'A', 20000);
    try in.appendSlice(gpa, "NEEDLE");
    try in.appendNTimes(gpa, 'B', 5000);
    try in.append(gpa, '\n');

    var r = try runStdin(gpa, zgrepBin(), &.{ "-o", "NEEDLE" }, in.items);
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("NEEDLE\n", r.stdout);
    try std.testing.expectEqual(@as(u8, 0), r.code);
}

// --- Recursive symlink loop (audit HIGH: unbounded recursion / DoS) ---------
// GNU grep -r does NOT follow symlinks, so a `loop -> .` self-link must not
// cause infinite recursion. We assert the run TERMINATES and finds the real
// file. (If the guard regressed, the process would recurse until crash/hang and
// this test would fail to produce the expected output.)

test "recursive -r does not follow a symlink loop" {
    const gpa = std.testing.allocator;
    const io = theIo();
    const root = TMP_DIR ++ "/rec";
    Io.Dir.cwd().deleteTree(io, root) catch {};
    try Io.Dir.cwd().createDirPath(io, root);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/f.txt", .data = "needle here\n" });
    // self-referential symlink: root/loop -> .
    Io.Dir.cwd().symLink(io, ".", root ++ "/loop", .{}) catch {};
    defer Io.Dir.cwd().deleteTree(io, root) catch {};

    var r = try runArgs(gpa, zgrepBin(), &.{ "-r", "needle", root });
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    // The real file is found exactly once; the symlink is not descended.
    const expected = root ++ "/f.txt:needle here\n";
    try std.testing.expectEqualStrings(expected, r.stdout);
}

// --- Exit code 2 on file error even when another file matched (audit low) ---
// GNU grep: "the exit status is 2 if there were ... errors", and this takes
// precedence over the match/no-match status. So grepping one matching file and
// one nonexistent file exits 2.

test "exit 2 when a file error occurs alongside a match" {
    const gpa = std.testing.allocator;
    const io = theIo();
    Io.Dir.cwd().createDirPath(io, TMP_DIR) catch {};
    const good = TMP_DIR ++ "/good.txt";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = good, .data = "hit\n" });
    defer Io.Dir.cwd().deleteFile(io, good) catch {};

    var r = try runArgs(gpa, zgrepBin(), &.{ "hit", good, TMP_DIR ++ "/does-not-exist.txt" });
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 2), r.code);
}

// --- Unrecognized option: exit 2 with a diagnostic (audit low) --------------
// GNU grep exits 2 on an unknown option and prints an "unrecognized option"
// diagnostic plus a "Try ... for more information." line to stderr.

test "unrecognized long option exits 2 with diagnostic" {
    const gpa = std.testing.allocator;
    var r = try runArgs(gpa, zgrepBin(), &.{ "--totally-bogus", "x" });
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 2), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "unrecognized option") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "Try 'zgrep --help'") != null);
}

// --- -a/--text is an accepted no-op (audit low: missing flags) --------------
// GNU `-a`/`--text` forces input to be treated as text; zgrep is already
// text-only, so it must be accepted and not alter results.

test "-a is an accepted no-op" {
    const gpa = std.testing.allocator;
    var r = try runStdin(gpa, zgrepBin(), &.{ "-a", "hello" }, "hello\nworld\n");
    defer r.deinit(gpa);
    try std.testing.expectEqualStrings("hello\n", r.stdout);
    try std.testing.expectEqual(@as(u8, 0), r.code);
}
