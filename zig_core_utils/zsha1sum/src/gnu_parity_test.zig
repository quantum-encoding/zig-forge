//! Externally-anchored GNU-parity tests for zsha1sum (GNU `sha1sum` clone).
//!
//! ANCHOR (per zig-forge/CLAUDE.md golden rule §1): expected values come from
//! sources zsha1sum's author did NOT write:
//!   1. The REAL GNU coreutils `sha1sum` binary (9.x, Homebrew `gsha1sum` / the
//!      coreutils gnubin `sha1sum`). Each parity case runs BOTH binaries on the
//!      SAME input and byte-compares stdout + exit code. For error cases the
//!      GNU diagnostic *content* (strerror / GNU wording) is asserted.
//!   2. Published SHA-1 test vectors (FIPS 180 / RFC 3174): SHA1("") =
//!      da39a3ee5e6b4b0d3255bfef95601890afd80709 and SHA1("abc") =
//!      a9993e364706816aba3e25717850c26c9cd0d89d. These hold even with no GNU
//!      binary installed.
//! These are NOT roundtrip tests — no case hashes zsha1sum output and re-checks it.
//!
//! The cases bite the fixes applied in this pass:
//!   - HIGH: hashing a directory printed the empty-string digest with exit 0.
//!     GNU errors "Is a directory" exit 1. -> "directory arg errors like GNU"
//!     is the mutation-test anchor.
//!   - HIGH: a check file whose last line lacks a trailing newline skipped that
//!     entry entirely. -> "check: last line without trailing newline".
//!   - MED: unknown options were silently ignored. -> "unknown ... option".
//!   - MED: BSD --tag lines were not recognized in --check. -> "check: --tag".
//!   - MED: short reads / >1024-byte lines dropped data. -> "check: many lines
//!     spanning read buffers, last line unterminated".
//!   - GNU-parity: summary wording, "no properly formatted lines", tag+check
//!     rejection, escaped filenames.
//!
//! Run via `zig build test`.

const std = @import("std");
const build_options = @import("build_options");

const ZSHA1: []const u8 = build_options.zsha1sum_path;

const GNU_CANDIDATES = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/sha1sum",
    "/opt/homebrew/bin/gsha1sum",
    "/usr/local/opt/coreutils/libexec/gnubin/sha1sum",
    "/usr/local/bin/gsha1sum",
};

const SHA1_EMPTY = "da39a3ee5e6b4b0d3255bfef95601890afd80709";
const SHA1_ABC = "a9993e364706816aba3e25717850c26c9cd0d89d";

extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn rmdir(path: [*:0]const u8) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;

var temp_counter: u64 = 0;
var temp_base: u64 = 0;

fn uniqueId() u64 {
    if (temp_base == 0) temp_base = @truncate(@intFromPtr(&temp_counter));
    temp_counter += 1;
    return temp_base ^ (temp_counter *% 0x9E3779B97F4A7C15);
}

/// Create a file with the given bytes; returns its absolute path.
fn writeTempFile(buf: []u8, data: []const u8) ![:0]const u8 {
    const path = try std.fmt.bufPrintZ(buf, "/tmp/zsha1_{x}_{x}", .{ uniqueId(), temp_counter });
    const fd = try std.posix.openatZ(
        std.posix.AT.FDCWD,
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    );
    defer _ = close(fd);
    var written: usize = 0;
    while (written < data.len) {
        const n = write(fd, data[written..].ptr, data.len - written);
        if (n < 0) return error.WriteFailed;
        written += @intCast(n);
    }
    return path;
}

/// Create a file at an exact absolute path (used for names with backslashes).
fn writeNamedFile(path: [*:0]const u8, data: []const u8) !void {
    const fd = try std.posix.openatZ(
        std.posix.AT.FDCWD,
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    );
    defer _ = close(fd);
    var written: usize = 0;
    while (written < data.len) {
        const n = write(fd, data[written..].ptr, data.len - written);
        if (n < 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

const Captured = struct {
    stdout: []u8,
    stderr: []u8,
    exit: ?u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *Captured) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

fn runBin(allocator: std.mem.Allocator, bin: []const u8, args: []const []const u8) !Captured {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, bin);
    try argv.appendSlice(allocator, args);

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();

    const res = try std.process.run(allocator, threaded.io(), .{ .argv = argv.items });
    return .{
        .stdout = res.stdout,
        .stderr = res.stderr,
        .exit = switch (res.term) {
            .exited => |c| c,
            else => null,
        },
        .allocator = allocator,
    };
}

fn findGnu() ?[]const u8 {
    for (GNU_CANDIDATES) |cand| {
        var path_buf: [256]u8 = undefined;
        const cand_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{cand}) catch continue;
        const fd = std.posix.openatZ(std.posix.AT.FDCWD, cand_z, .{ .ACCMODE = .RDONLY }, 0) catch continue;
        _ = close(fd);
        return cand;
    }
    return null;
}

/// zsha1sum(args) must match GNU sha1sum(args) byte-for-byte on stdout AND exit.
/// (Stderr is not byte-compared: the program-name prefix differs. Stderr
/// *content* is asserted separately in the error cases.)
fn expectGnuStdoutParity(args: []const []const u8) !void {
    const gnu = findGnu() orelse return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var z = try runBin(allocator, ZSHA1, args);
    defer z.deinit();
    var g = try runBin(allocator, gnu, args);
    defer g.deinit();

    std.testing.expectEqualSlices(u8, g.stdout, z.stdout) catch |e| {
        std.debug.print("stdout mismatch args={any}\n  gnu: {s}\n  zig: {s}\n", .{ args, g.stdout, z.stdout });
        return e;
    };
    try std.testing.expectEqual(g.exit, z.exit);
}

// ---------------------------------------------------------------------------
// Digest correctness — anchored to published SHA-1 vectors AND GNU.
// ---------------------------------------------------------------------------

test "empty input digest matches published vector and GNU" {
    const allocator = std.testing.allocator;
    var buf: [80]u8 = undefined;
    const path = try writeTempFile(&buf, "");
    defer _ = unlink(path);

    var z = try runBin(allocator, ZSHA1, &.{path});
    defer z.deinit();
    // Published FIPS-180/RFC-3174 vector; not produced by zsha1sum.
    try std.testing.expect(std.mem.startsWith(u8, z.stdout, SHA1_EMPTY));
    try std.testing.expectEqual(@as(?u8, 0), z.exit);

    try expectGnuStdoutParity(&.{path});
}

test "\"abc\" digest matches published vector and GNU" {
    const allocator = std.testing.allocator;
    var buf: [80]u8 = undefined;
    const path = try writeTempFile(&buf, "abc");
    defer _ = unlink(path);

    var z = try runBin(allocator, ZSHA1, &.{path});
    defer z.deinit();
    try std.testing.expect(std.mem.startsWith(u8, z.stdout, SHA1_ABC));
    try std.testing.expectEqual(@as(?u8, 0), z.exit);

    try expectGnuStdoutParity(&.{path});
}

test "large binary content matches GNU" {
    const allocator = std.testing.allocator;
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(allocator);
    var s: u64 = 0x1234_5678_9abc_def0;
    var i: usize = 0;
    while (i < 200000) : (i += 1) {
        s = s *% 6364136223846793005 +% 1442695040888963407;
        try data.append(allocator, @truncate(s >> 33));
    }
    var buf: [80]u8 = undefined;
    const path = try writeTempFile(&buf, data.items);
    defer _ = unlink(path);
    try expectGnuStdoutParity(&.{path});
}

test "multiple file operands match GNU" {
    var b1: [80]u8 = undefined;
    var b2: [80]u8 = undefined;
    const p1 = try writeTempFile(&b1, "alpha\n");
    defer _ = unlink(p1);
    const p2 = try writeTempFile(&b2, "beta beta\x00binary");
    defer _ = unlink(p2);
    try expectGnuStdoutParity(&.{ p1, p2 });
}

test "binary-mode marker matches GNU" {
    var buf: [80]u8 = undefined;
    const path = try writeTempFile(&buf, "hello world");
    defer _ = unlink(path);
    try expectGnuStdoutParity(&.{ "-b", path });
}

test "--tag output matches GNU" {
    var buf: [80]u8 = undefined;
    const path = try writeTempFile(&buf, "tag me");
    defer _ = unlink(path);
    try expectGnuStdoutParity(&.{ "--tag", path });
}

// ---------------------------------------------------------------------------
// Error handling (the fixes).
// ---------------------------------------------------------------------------

// HIGH finding + MUTATION-TEST ANCHOR: a directory operand. Pre-fix, open()
// succeeded and read() returned EISDIR(<0)/0 which the loop swallowed as EOF,
// so zsha1sum printed `da39a3ee...  <dir>` with exit 0. GNU errors, exit 1.
test "directory arg errors like GNU (exit 1, Is a directory)" {
    const allocator = std.testing.allocator;
    var namebuf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&namebuf, "/tmp/zsha1_dir_{x}", .{uniqueId()});
    if (mkdir(dir, 0o755) != 0) return error.SkipZigTest;
    defer _ = rmdir(dir);

    var z = try runBin(allocator, ZSHA1, &.{dir});
    defer z.deinit();

    // Must NOT emit a bogus checksum.
    try std.testing.expectEqualSlices(u8, "", z.stdout);
    try std.testing.expectEqual(@as(?u8, 1), z.exit);
    // strerror(EISDIR) text — an external (libc/GNU) string, not ours.
    try std.testing.expect(std.mem.indexOf(u8, z.stderr, "Is a directory") != null);

    if (findGnu()) |gnu| {
        var g = try runBin(allocator, gnu, &.{dir});
        defer g.deinit();
        try std.testing.expectEqualSlices(u8, "", g.stdout);
        try std.testing.expectEqual(z.exit, g.exit);
        try std.testing.expect(std.mem.indexOf(u8, g.stderr, "Is a directory") != null);
    }
}

test "nonexistent file errors like GNU (exit 1, No such file or directory)" {
    const allocator = std.testing.allocator;
    const missing = "/nonexistent_zsha1_path_xyz";

    var z = try runBin(allocator, ZSHA1, &.{missing});
    defer z.deinit();
    try std.testing.expectEqualSlices(u8, "", z.stdout);
    try std.testing.expectEqual(@as(?u8, 1), z.exit);
    try std.testing.expect(std.mem.indexOf(u8, z.stderr, "No such file or directory") != null);

    if (findGnu()) |gnu| {
        var g = try runBin(allocator, gnu, &.{missing});
        defer g.deinit();
        try std.testing.expectEqual(z.exit, g.exit);
        try std.testing.expect(std.mem.indexOf(u8, g.stderr, "No such file or directory") != null);
    }
}

test "unknown short option is rejected like GNU" {
    const allocator = std.testing.allocator;
    var z = try runBin(allocator, ZSHA1, &.{"-Z"});
    defer z.deinit();
    try std.testing.expectEqualSlices(u8, "", z.stdout);
    try std.testing.expectEqual(@as(?u8, 1), z.exit);
    try std.testing.expect(std.mem.indexOf(u8, z.stderr, "invalid option") != null);

    if (findGnu()) |gnu| {
        var g = try runBin(allocator, gnu, &.{"-Z"});
        defer g.deinit();
        try std.testing.expectEqual(z.exit, g.exit);
        try std.testing.expect(std.mem.indexOf(u8, g.stderr, "invalid option") != null);
    }
}

test "unknown long option is rejected like GNU" {
    const allocator = std.testing.allocator;
    var z = try runBin(allocator, ZSHA1, &.{"--bogus"});
    defer z.deinit();
    try std.testing.expectEqualSlices(u8, "", z.stdout);
    try std.testing.expectEqual(@as(?u8, 1), z.exit);
    try std.testing.expect(std.mem.indexOf(u8, z.stderr, "unrecognized option") != null);

    if (findGnu()) |gnu| {
        var g = try runBin(allocator, gnu, &.{"--bogus"});
        defer g.deinit();
        try std.testing.expectEqual(z.exit, g.exit);
        try std.testing.expect(std.mem.indexOf(u8, g.stderr, "unrecognized option") != null);
    }
}

// ---------------------------------------------------------------------------
// --check mode. Each builds the checksum file with the REAL GNU binary, then
// requires zsha1sum -c and gsha1sum -c to produce identical stdout + exit.
// ---------------------------------------------------------------------------

/// Run GNU on `gen_args` and capture stdout into a temp checksum file. Returns
/// the checksum-file path (caller unlinks). Skips the test if GNU is absent.
fn gnuSumsToFile(allocator: std.mem.Allocator, gen_args: []const []const u8, out_buf: []u8) !?[:0]const u8 {
    const gnu = findGnu() orelse return null;
    var g = try runBin(allocator, gnu, gen_args);
    defer g.deinit();
    if (g.exit != 0) return error.GnuGenFailed;
    const path = try writeTempFile(out_buf, g.stdout);
    return path;
}

test "check: standard sums verify identically to GNU" {
    const allocator = std.testing.allocator;
    var fb: [80]u8 = undefined;
    const f = try writeTempFile(&fb, "verify me\n");
    defer _ = unlink(f);

    var sb: [80]u8 = undefined;
    const sums = (try gnuSumsToFile(allocator, &.{f}, &sb)) orelse return error.SkipZigTest;
    defer _ = unlink(sums);

    try expectGnuStdoutParity(&.{ "-c", sums });
}

// HIGH finding + anchor: last line without a trailing newline must still be
// verified. Pre-fix it stayed buffered and was silently skipped (exit 0, no
// OK/FAILED). We build the sums file WITHOUT a trailing newline explicitly.
test "check: last line without trailing newline is still verified" {
    const allocator = std.testing.allocator;
    var fb: [80]u8 = undefined;
    const f = try writeTempFile(&fb, "no newline tail");
    defer _ = unlink(f);

    // Ask GNU for the checksum, then strip the trailing '\n'.
    const gnu = findGnu() orelse return error.SkipZigTest;
    var g = try runBin(allocator, gnu, &.{f});
    defer g.deinit();
    try std.testing.expect(g.exit.? == 0);
    var line = g.stdout;
    if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];

    var sb: [80]u8 = undefined;
    const sums = try writeTempFile(&sb, line);
    defer _ = unlink(sums);

    var z = try runBin(allocator, ZSHA1, &.{ "-c", sums });
    defer z.deinit();
    // The entry MUST be reported (not silently skipped).
    try std.testing.expect(std.mem.indexOf(u8, z.stdout, ": OK") != null);
    try std.testing.expectEqual(@as(?u8, 0), z.exit);

    try expectGnuStdoutParity(&.{ "-c", sums });
}

test "check: BSD --tag format is recognized" {
    const allocator = std.testing.allocator;
    var fb: [80]u8 = undefined;
    const f = try writeTempFile(&fb, "tagged content\n");
    defer _ = unlink(f);

    var sb: [80]u8 = undefined;
    const sums = (try gnuSumsToFile(allocator, &.{ "--tag", f }, &sb)) orelse return error.SkipZigTest;
    defer _ = unlink(sums);

    var z = try runBin(allocator, ZSHA1, &.{ "-c", sums });
    defer z.deinit();
    try std.testing.expect(std.mem.indexOf(u8, z.stdout, ": OK") != null);
    try std.testing.expectEqual(@as(?u8, 0), z.exit);

    try expectGnuStdoutParity(&.{ "-c", sums });
}

test "check: single mismatch wording matches GNU" {
    const allocator = std.testing.allocator;
    var fb: [80]u8 = undefined;
    const f = try writeTempFile(&fb, "real content\n");
    defer _ = unlink(f);

    // A deliberately wrong hash for f.
    var sb: [96]u8 = undefined;
    const line = try std.fmt.bufPrint(&sb, "0000000000000000000000000000000000000000  {s}\n", .{f});
    var s2b: [80]u8 = undefined;
    const sums = try writeTempFile(&s2b, line);
    defer _ = unlink(sums);

    var z = try runBin(allocator, ZSHA1, &.{ "-c", sums });
    defer z.deinit();
    try std.testing.expect(std.mem.indexOf(u8, z.stdout, ": FAILED") != null);
    try std.testing.expect(std.mem.indexOf(u8, z.stderr, "1 computed checksum did NOT match") != null);
    try std.testing.expectEqual(@as(?u8, 1), z.exit);

    try expectGnuStdoutParity(&.{ "-c", sums });
}

test "check: no properly formatted lines errors like GNU" {
    const allocator = std.testing.allocator;
    var sb: [80]u8 = undefined;
    const sums = try writeTempFile(&sb, "this is not a checksum line\nnor is this\n");
    defer _ = unlink(sums);

    var z = try runBin(allocator, ZSHA1, &.{ "-c", sums });
    defer z.deinit();
    try std.testing.expectEqual(@as(?u8, 1), z.exit);
    try std.testing.expect(std.mem.indexOf(u8, z.stderr, "no properly formatted checksum lines found") != null);

    try expectGnuStdoutParity(&.{ "-c", sums });
}

test "check: --tag combined with -c is rejected like GNU" {
    const allocator = std.testing.allocator;
    var z = try runBin(allocator, ZSHA1, &.{ "--tag", "-c", "whatever" });
    defer z.deinit();
    try std.testing.expectEqual(@as(?u8, 1), z.exit);
    try std.testing.expect(std.mem.indexOf(u8, z.stderr, "meaningless when verifying") != null);

    if (findGnu()) |gnu| {
        var g = try runBin(allocator, gnu, &.{ "--tag", "-c", "whatever" });
        defer g.deinit();
        try std.testing.expectEqual(z.exit, g.exit);
        try std.testing.expect(std.mem.indexOf(u8, g.stderr, "meaningless when verifying") != null);
    }
}

// Escaped-filename fix: a filename containing a backslash makes GNU prefix the
// line with '\' and double the backslash. zsha1sum must un-escape to open the
// file and echo the escaped form in the OK line. GNU generates the sums file.
test "check: backslash-escaped filename verifies like GNU" {
    const allocator = std.testing.allocator;
    var namebuf: [64]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&namebuf, "/tmp/zsha1_esc_{x}\\z", .{uniqueId()});
    writeNamedFile(name, "escaped name body\n") catch return error.SkipZigTest;
    defer _ = unlink(name);

    var sb: [128]u8 = undefined;
    const name_slice: []const u8 = name;
    const sums = (try gnuSumsToFile(allocator, &.{name_slice}, &sb)) orelse return error.SkipZigTest;
    defer _ = unlink(sums);

    var z = try runBin(allocator, ZSHA1, &.{ "-c", sums });
    defer z.deinit();
    try std.testing.expect(std.mem.indexOf(u8, z.stdout, ": OK") != null);
    try std.testing.expectEqual(@as(?u8, 0), z.exit);

    try expectGnuStdoutParity(&.{ "-c", sums });
}

// Anchors the growable-buffer / read-loop rewrite: a checksum file far larger
// than the old fixed 8192-byte read buffer, whose LAST line has no trailing
// newline. Pre-fix, the short-read==EOF heuristic and the unterminated-last-line
// bug would both drop entries. We generate every line with GNU.
test "check: many lines spanning read buffers, last line unterminated" {
    const allocator = std.testing.allocator;
    const gnu = findGnu() orelse return error.SkipZigTest;

    const N = 400;
    var files: std.ArrayListUnmanaged([:0]const u8) = .empty;
    defer {
        for (files.items) |p| _ = unlink(p);
        for (files.items) |p| allocator.free(p);
        files.deinit(allocator);
    }

    var sums_content: std.ArrayListUnmanaged(u8) = .empty;
    defer sums_content.deinit(allocator);

    var idx: usize = 0;
    while (idx < N) : (idx += 1) {
        var body: [32]u8 = undefined;
        const b = try std.fmt.bufPrint(&body, "content-{d}\n", .{idx});
        var pb: [80]u8 = undefined;
        const tmp = try writeTempFile(&pb, b);
        try files.append(allocator, try allocator.dupeZ(u8, tmp));

        var g = try runBin(allocator, gnu, &.{tmp});
        defer g.deinit();
        try std.testing.expect(g.exit.? == 0);
        try sums_content.appendSlice(allocator, g.stdout); // includes trailing \n
    }
    // Drop the final newline so the last entry is unterminated.
    if (sums_content.items.len > 0 and sums_content.items[sums_content.items.len - 1] == '\n') {
        _ = sums_content.pop();
    }

    var sfb: [80]u8 = undefined;
    const sums = try writeTempFile(&sfb, sums_content.items);
    defer _ = unlink(sums);

    var z = try runBin(allocator, ZSHA1, &.{ "-c", "--status", sums });
    defer z.deinit();
    // --status: no output, exit 0 means every one of the N lines verified.
    try std.testing.expectEqualSlices(u8, "", z.stdout);
    try std.testing.expectEqual(@as(?u8, 0), z.exit);

    // And full parity (non-status) with GNU: identical OK lines, same count.
    try expectGnuStdoutParity(&.{ "-c", sums });
}

// ---------------------------------------------------------------------------
// --help / --version stream routing.
// ---------------------------------------------------------------------------

test "--help goes to stdout with exit 0" {
    const allocator = std.testing.allocator;
    var z = try runBin(allocator, ZSHA1, &.{"--help"});
    defer z.deinit();
    try std.testing.expect(z.stdout.len > 0);
    try std.testing.expectEqualSlices(u8, "", z.stderr);
    try std.testing.expectEqual(@as(?u8, 0), z.exit);
}

test "--version goes to stdout with exit 0" {
    const allocator = std.testing.allocator;
    var z = try runBin(allocator, ZSHA1, &.{"--version"});
    defer z.deinit();
    try std.testing.expect(z.stdout.len > 0);
    try std.testing.expectEqualSlices(u8, "", z.stderr);
    try std.testing.expectEqual(@as(?u8, 0), z.exit);
}
