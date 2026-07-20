//! Externally-anchored GNU-parity tests for zcksum (GNU `cksum` clone).
//!
//! ANCHOR (per zig-forge/CLAUDE.md golden rule §1): every expected value comes
//! from the REAL GNU coreutils `cksum` binary (9.x, Homebrew `gcksum` / the
//! coreutils gnubin `cksum`), not from zcksum itself. Each case runs BOTH
//! binaries on the SAME input and byte-compares stdout + exit code, and for the
//! error cases asserts the diagnostic reason (the strerror text libc/GNU
//! produce). These are NOT roundtrip tests.
//!
//! A small set of literal-byte assertions (empty-input CRC `4294967295 0`) is
//! transcribed from the POSIX cksum definition so the suite still anchors to
//! real external bytes even if no GNU binary is installed.
//!
//! The cases here bite the fixes applied in this pass:
//!   - HIGH: read() EISDIR on a directory fd was treated as EOF -> the tool
//!     printed `4294967295 0 <dir>` exit 0. GNU errors "Is a directory" exit 1.
//!     `directory arg errors like GNU` is the mutation-test anchor.
//!   - open() error reason (Permission denied vs No such file or directory).
//!   - --help/--version routed to stdout (were on stderr).
//!   - unknown option rejected (was treated as a filename).
//!
//! Run via `zig build test`.

const std = @import("std");
const build_options = @import("build_options");

const ZCKSUM: []const u8 = build_options.zcksum_path;

const GNU_CANDIDATES = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/cksum",
    "/opt/homebrew/bin/gcksum",
    "/usr/local/opt/coreutils/libexec/gnubin/cksum",
    "/usr/local/bin/gcksum",
};

extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn getuid() c_uint;

var temp_counter: u64 = 0;
var temp_base: u64 = 0;

fn writeTempFile(buf: *[80]u8, data: []const u8) ![:0]const u8 {
    if (temp_base == 0) temp_base = @truncate(@intFromPtr(&temp_counter));
    temp_counter += 1;
    const id: u64 = temp_base ^ (temp_counter *% 0x9E3779B97F4A7C15);
    const path = try std.fmt.bufPrintZ(buf, "/tmp/zcksum_parity_{x}_{x}", .{ id, temp_counter });
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

/// zcksum(args) must match GNU cksum(args) byte-for-byte on stdout AND exit.
/// (Stderr is not byte-compared because the program-name prefix differs;
/// stderr *content* is asserted separately in the error cases.)
fn expectGnuStdoutParity(args: []const []const u8) !void {
    const gnu = findGnu() orelse return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var z = try runBin(allocator, ZCKSUM, args);
    defer z.deinit();
    var g = try runBin(allocator, gnu, args);
    defer g.deinit();

    std.testing.expectEqualSlices(u8, g.stdout, z.stdout) catch |e| {
        std.debug.print("stdout mismatch args={any}\n  gnu: {s}\n  zck: {s}\n", .{ args, g.stdout, z.stdout });
        return e;
    };
    try std.testing.expectEqual(g.exit, z.exit);
}

// ---------------------------------------------------------------------------
// Content parity: the default POSIX CRC + byte count + name field.
// ---------------------------------------------------------------------------

test "empty input CRC matches literal POSIX value and GNU" {
    const allocator = std.testing.allocator;
    var buf: [80]u8 = undefined;
    const path = try writeTempFile(&buf, "");
    defer _ = unlink(path);

    // Literal external anchor: POSIX cksum of the empty stream is 4294967295 0.
    var z = try runBin(allocator, ZCKSUM, &.{path});
    defer z.deinit();
    var expected: std.ArrayListUnmanaged(u8) = .empty;
    defer expected.deinit(allocator);
    try expected.appendSlice(allocator, "4294967295 0 ");
    try expected.appendSlice(allocator, path);
    try expected.append(allocator, '\n');
    try std.testing.expectEqualSlices(u8, expected.items, z.stdout);
    try std.testing.expectEqual(@as(?u8, 0), z.exit);

    try expectGnuStdoutParity(&.{path});
}

test "ascii content matches GNU" {
    var buf: [80]u8 = undefined;
    const path = try writeTempFile(&buf, "hello");
    defer _ = unlink(path);
    try expectGnuStdoutParity(&.{path});
}

test "binary content (deterministic 200000 bytes) matches GNU" {
    const allocator = std.testing.allocator;
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(allocator);
    // Deterministic PRNG so both binaries hash identical bytes.
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

// ---------------------------------------------------------------------------
// Error cases (the fixes).
// ---------------------------------------------------------------------------

// HIGH finding + MUTATION-TEST ANCHOR: a directory operand. Pre-fix, read()
// returned EISDIR(<0) which `if (n_ret <= 0) break;` swallowed as EOF, so
// zcksum printed `4294967295 0 <dir>` with exit 0. GNU errors, exit 1.
test "directory arg errors like GNU (exit 1, Is a directory)" {
    const allocator = std.testing.allocator;

    var z = try runBin(allocator, ZCKSUM, &.{"/tmp"});
    defer z.deinit();

    // Must NOT have produced a bogus checksum on stdout.
    try std.testing.expectEqualSlices(u8, "", z.stdout);
    try std.testing.expectEqual(@as(?u8, 1), z.exit);
    // strerror(EISDIR) text — an external (libc/GNU) string, not ours.
    try std.testing.expect(std.mem.indexOf(u8, z.stderr, "Is a directory") != null);

    if (findGnu()) |gnu| {
        var g = try runBin(allocator, gnu, &.{"/tmp"});
        defer g.deinit();
        try std.testing.expectEqualSlices(u8, "", g.stdout);
        try std.testing.expectEqual(z.exit, g.exit);
        try std.testing.expect(std.mem.indexOf(u8, g.stderr, "Is a directory") != null);
    }
}

test "nonexistent file errors like GNU (exit 1, No such file or directory)" {
    const allocator = std.testing.allocator;
    const missing = "/nonexistent_zcksum_path_xyz";

    var z = try runBin(allocator, ZCKSUM, &.{missing});
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

test "unreadable file reports Permission denied like GNU" {
    // root bypasses file perms; skip so the assertion stays meaningful.
    if (getuid() == 0) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var buf: [80]u8 = undefined;
    const path = try writeTempFile(&buf, "secret");
    defer _ = unlink(path);
    if (chmod(path.ptr, 0) != 0) return error.SkipZigTest;
    defer _ = chmod(path.ptr, 0o644);

    var z = try runBin(allocator, ZCKSUM, &.{path});
    defer z.deinit();
    try std.testing.expectEqualSlices(u8, "", z.stdout);
    try std.testing.expectEqual(@as(?u8, 1), z.exit);
    try std.testing.expect(std.mem.indexOf(u8, z.stderr, "Permission denied") != null);

    if (findGnu()) |gnu| {
        var g = try runBin(allocator, gnu, &.{path});
        defer g.deinit();
        try std.testing.expectEqual(z.exit, g.exit);
        try std.testing.expect(std.mem.indexOf(u8, g.stderr, "Permission denied") != null);
    }
}

test "unknown option is rejected, not treated as a filename" {
    const allocator = std.testing.allocator;

    var z = try runBin(allocator, ZCKSUM, &.{"-x"});
    defer z.deinit();
    // No checksum line: pre-fix, `-x` fell through as a path.
    try std.testing.expectEqualSlices(u8, "", z.stdout);
    try std.testing.expectEqual(@as(?u8, 1), z.exit);
    try std.testing.expect(std.mem.indexOf(u8, z.stderr, "invalid option") != null);

    if (findGnu()) |gnu| {
        var g = try runBin(allocator, gnu, &.{"-x"});
        defer g.deinit();
        try std.testing.expectEqual(z.exit, g.exit);
        try std.testing.expect(std.mem.indexOf(u8, g.stderr, "invalid option") != null);
    }
}

// ---------------------------------------------------------------------------
// --help / --version stream routing (must be stdout, exit 0).
// ---------------------------------------------------------------------------

test "--help goes to stdout with exit 0" {
    const allocator = std.testing.allocator;
    var z = try runBin(allocator, ZCKSUM, &.{"--help"});
    defer z.deinit();
    try std.testing.expect(z.stdout.len > 0);
    try std.testing.expectEqualSlices(u8, "", z.stderr);
    try std.testing.expectEqual(@as(?u8, 0), z.exit);

    // GNU also documents --help on stdout; confirm the external contract.
    if (findGnu()) |gnu| {
        var g = try runBin(allocator, gnu, &.{"--help"});
        defer g.deinit();
        try std.testing.expect(g.stdout.len > 0);
        try std.testing.expectEqualSlices(u8, "", g.stderr);
        try std.testing.expectEqual(@as(?u8, 0), g.exit);
    }
}

test "--version goes to stdout with exit 0" {
    const allocator = std.testing.allocator;
    var z = try runBin(allocator, ZCKSUM, &.{"--version"});
    defer z.deinit();
    try std.testing.expect(z.stdout.len > 0);
    try std.testing.expectEqualSlices(u8, "", z.stderr);
    try std.testing.expectEqual(@as(?u8, 0), z.exit);

    if (findGnu()) |gnu| {
        var g = try runBin(allocator, gnu, &.{"--version"});
        defer g.deinit();
        try std.testing.expect(g.stdout.len > 0);
        try std.testing.expectEqualSlices(u8, "", g.stderr);
        try std.testing.expectEqual(@as(?u8, 0), g.exit);
    }
}
