//! Externally-anchored parity tests for zcut against GNU coreutils `cut`.
//!
//! These are NOT roundtrip tests. Every expected value below is either:
//!   (a) the exact bytes emitted by the real GNU `cut` binary (captured with
//!       `gcut … | xxd` on 2026-07-19, coreutils via Homebrew), embedded here
//!       literally, AND
//!   (b) re-diffed live against the GNU binary at test time when one is found
//!       on the system (the coreutils gnubin `cut` / `gcut`) — a true external
//!       anchor, not a hash pinned over our own output.
//!
//! If no GNU binary is present the literal-bytes assertions still run (they are
//! the anchor); the live cross-check is skipped.
//!
//! Inputs are fed to both binaries as a temp FILE argument rather than stdin.
//! `cut` treats a file path and stdin identically (verified: byte-for-byte
//! equal output), and this keeps the harness on the simple `std.process.run`
//! path. The zcut binary under test is located via the `zcut_path` build option
//! (absolute install path injected by build.zig), so the test is cwd-independent.

const std = @import("std");
const build_options = @import("build_options");

const ZCUT = build_options.zcut_path;

extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn unlink(path: [*:0]const u8) c_int;

/// Candidate paths for a real GNU cut, most-specific first.
const GNU_CANDIDATES = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/cut",
    "/opt/homebrew/bin/gcut",
    "/usr/bin/gcut",
};

// Per-process base derived from ASLR (differs between concurrent test runs),
// combined with a monotonic counter for uniqueness within a run.
var temp_counter: u64 = 0;
var temp_base: u64 = 0;

/// Write `data` to a unique temp file and return its path (valid until deleted).
fn writeTempFile(buf: *[64]u8, data: []const u8) ![:0]const u8 {
    if (temp_base == 0) temp_base = @truncate(@intFromPtr(&temp_counter));
    temp_counter += 1;
    const id: u64 = temp_base ^ (temp_counter *% 0x9E3779B97F4A7C15);
    const path = try std.fmt.bufPrintZ(buf, "/tmp/zcut_parity_{x}_{x}", .{ id, temp_counter });
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

/// Run `bin` with `args ++ file_path` and capture stdout/stderr/exit.
fn runBin(
    allocator: std.mem.Allocator,
    bin: []const u8,
    args: []const []const u8,
    file_path: []const u8,
) !Captured {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, bin);
    try argv.appendSlice(allocator, args);
    try argv.append(allocator, file_path);

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

/// Assert zcut(args, input-as-file) matches `expected_stdout` and `expected_exit`
/// exactly (literal anchor), AND — when a GNU binary exists — that GNU produces
/// identical stdout + exit for the same invocation (live external anchor).
fn expectParity(
    args: []const []const u8,
    input: []const u8,
    expected_stdout: []const u8,
    expected_exit: u8,
) !void {
    const allocator = std.testing.allocator;

    var path_buf: [64]u8 = undefined;
    const path = try writeTempFile(&path_buf, input);
    defer _ = unlink(path);

    var z = try runBin(allocator, ZCUT, args, path);
    defer z.deinit();

    std.testing.expectEqualSlices(u8, expected_stdout, z.stdout) catch |e| {
        std.debug.print("zcut stdout mismatch for args={any}\n  want: {any}\n  got:  {any}\n", .{ args, expected_stdout, z.stdout });
        return e;
    };
    try std.testing.expectEqual(@as(?u8, expected_exit), z.exit);

    if (findGnu()) |gnu| {
        var g = try runBin(allocator, gnu, args, path);
        defer g.deinit();
        std.testing.expectEqualSlices(u8, g.stdout, z.stdout) catch |e| {
            std.debug.print("zcut vs GNU stdout divergence for args={any}\n", .{args});
            return e;
        };
        try std.testing.expectEqual(g.exit, z.exit);
    }
}

// ---------------------------------------------------------------------------
// Ordering + dedup: the defining semantic of cut. GNU selects each position at
// most once, in ascending order, regardless of the order given on the CLI.
// (gcut -d: -f3,1 <<<'a:b:c'  ->  'a:c')
// ---------------------------------------------------------------------------

test "fields: out-of-order list is emitted ascending" {
    try expectParity(&.{ "-d:", "-f3,1" }, "a:b:c\n", "a:c\n", 0);
}

test "fields: overlapping ranges are deduplicated" {
    try expectParity(&.{ "-d:", "-f1-3,2-4" }, "a:b:c:d\n", "a:b:c:d\n", 0);
}

test "fields: a repeated single field is emitted once" {
    try expectParity(&.{ "-d:", "-f2,2" }, "a:b:c\n", "b\n", 0);
}

test "chars: out-of-order list is emitted ascending" {
    try expectParity(&.{"-c3,1"}, "abcd\n", "ac\n", 0);
}

test "bytes: contiguous range" {
    try expectParity(&.{"-b1-3"}, "abcdef\n", "abc\n", 0);
}

test "chars: open-ended range to end of line" {
    try expectParity(&.{"-c2-"}, "hello\n", "ello\n", 0);
}

// ---------------------------------------------------------------------------
// Complement
// ---------------------------------------------------------------------------

test "fields: --complement selects the rest ascending" {
    try expectParity(&.{ "-d:", "-f2", "--complement" }, "a:b:c\n", "a:c\n", 0);
}

// ---------------------------------------------------------------------------
// --output-delimiter is used verbatim (GNU does NOT interpret escapes).
// (gcut -d: -f1,3 --output-delimiter='\t' <<<'a:b:c'  ->  bytes 61 5c 74 63 0a)
// ---------------------------------------------------------------------------

test "output-delimiter is literal, not escape-interpreted" {
    try expectParity(&.{ "-d:", "-f1,3", "--output-delimiter=\\t" }, "a:b:c\n", "a\\tc\n", 0);
}

test "output-delimiter single char replaces input delimiter" {
    try expectParity(&.{ "-d:", "-f1-3", "--output-delimiter=," }, "a:b:c\n", "a,b,c\n", 0);
}

// Regression: the old octal-escape parser panicked (integer overflow / SIGABRT)
// on '\0400'. GNU treats the string literally; zcut must not crash and must emit
// the literal delimiter bytes. (gcut -> 61 5c 30 34 30 30 63 0a  ->  'a\0400c')
test "output-delimiter octal string does not crash, emitted literally" {
    try expectParity(&.{ "-d:", "-f1,3", "--output-delimiter=\\0400" }, "a:b:c\n", "a\\0400c\n", 0);
}

// ---------------------------------------------------------------------------
// -s (only-delimited): a non-delimited line is emitted as NOTHING, not even a
// trailing newline. (gcut -d: -s -f1 on $'a:b\nnodelim\nc:d\n'  ->  'a\nc\n')
// ---------------------------------------------------------------------------

test "only-delimited suppresses non-delimited lines entirely" {
    try expectParity(&.{ "-d:", "-s", "-f1" }, "a:b\nnodelim\nc:d\n", "a\nc\n", 0);
}

test "field mode passes non-delimited line through when -s absent" {
    try expectParity(&.{ "-d:", "-f1" }, "nodelim\n", "nodelim\n", 0);
}

// ---------------------------------------------------------------------------
// -z (zero-terminated) uses NUL as the line delimiter.
// (gcut -z -d: -f2 on 'a:b\0c:d\0'  ->  'b\0d\0')
// ---------------------------------------------------------------------------

test "zero-terminated uses NUL line delimiter" {
    try expectParity(&.{ "-z", "-d:", "-f2" }, "a:b\x00c:d\x00", "b\x00d\x00", 0);
}

// ---------------------------------------------------------------------------
// Error / exit-status parity. GNU exits 1 in each of these cases.
// ---------------------------------------------------------------------------

test "multi-char delimiter is rejected (exit 1)" {
    try expectParity(&.{ "-d::", "-f1" }, "a:b\n", "", 1);
}

test "-s outside field mode is rejected (exit 1)" {
    try expectParity(&.{ "-s", "-c1" }, "ab\n", "", 1);
}

test "-d outside field mode is rejected (exit 1)" {
    try expectParity(&.{ "-d:", "-c1" }, "ab\n", "", 1);
}

// A missing file must set a nonzero exit status even though stdout is empty.
// GNU: `cut -f1 /nonexistent` -> stderr message, exit 1.
test "missing input file yields exit 1" {
    const allocator = std.testing.allocator;
    var z = try runBin(allocator, ZCUT, &.{"-f1"}, "/zcut_nonexistent_path_xyz_123");
    defer z.deinit();
    try std.testing.expectEqualSlices(u8, "", z.stdout);
    try std.testing.expectEqual(@as(?u8, 1), z.exit);

    if (findGnu()) |gnu| {
        var g = try runBin(allocator, gnu, &.{"-f1"}, "/zcut_nonexistent_path_xyz_123");
        defer g.deinit();
        try std.testing.expectEqual(g.exit, z.exit);
    }
}
