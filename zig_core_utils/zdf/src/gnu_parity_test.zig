//! GNU-df parity tests for zdf.
//!
//! EXTERNAL ANCHOR: these tests diff zdf's output and exit status against the
//! real GNU coreutils `df` binary (`gdf`, coreutils 9.10) installed on this
//! machine. The expected values are NOT written by us — they are whatever the
//! reference GNU binary emits for the same invocation. This satisfies the
//! zig-forge golden rule (§1): inputs and expected outputs both come from a
//! source the library author did not write. There are no roundtrip tests here.
//!
//! Stable vs. drifting fields: a filesystem's TOTAL size / inode count and its
//! device + mount-point are stable between two consecutive process launches,
//! so those are asserted for exact equality. The Used/Available columns can
//! drift by a few blocks in the milliseconds between spawning gdf and zdf, so
//! they are deliberately NOT asserted for exact equality.
//!
//! A few tests are anchored to documented POSIX/GNU behavior (exit status,
//! stdout routing) with the reference binary confirming the same behavior.

const std = @import("std");
const build_options = @import("build_options");

const ZDF = build_options.zdf_exe;

const gdf_candidates = [_][]const u8{
    "/opt/homebrew/bin/gdf",
    "/opt/homebrew/opt/coreutils/libexec/gnubin/df",
    "/usr/local/bin/gdf",
};

const Captured = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: ?u8, // null if killed by signal
};

fn tryRun(a: std.mem.Allocator, argv: []const []const u8) ?Captured {
    const res = std.process.run(a, std.testing.io, .{ .argv = argv }) catch return null;
    const code: ?u8 = switch (res.term) {
        .exited => |c| c,
        else => null,
    };
    return .{ .stdout = res.stdout, .stderr = res.stderr, .exit_code = code };
}

fn run(a: std.mem.Allocator, argv: []const []const u8) !Captured {
    return tryRun(a, argv) orelse error.SpawnFailed;
}

/// Returns the path to a working GNU df, or null if none is installed
/// (spawning it as `<path> --version` is the existence probe).
fn findGdf(a: std.mem.Allocator) ?[]const u8 {
    for (gdf_candidates) |c| {
        if (tryRun(a, &.{ c, "--version" })) |_| return c;
    }
    return null;
}

fn firstDataLine(out: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, out, '\n');
    _ = it.next(); // header
    while (it.next()) |l| {
        if (l.len != 0) return l;
    }
    return null;
}

fn headerLine(out: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, out, '\n');
    return it.next();
}

fn tokens(a: std.mem.Allocator, line: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, line, " \t");
    while (it.next()) |t| try list.append(a, t);
    return list.items;
}

// --- block-mode: total size + header must match gdf exactly ----------------

test "gdf parity: -k / header + device + mount + total-blocks are byte-identical" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gdf = findGdf(a) orelse return error.SkipZigTest;

    const g = try run(a, &.{ gdf, "-k", "/" });
    const z = try run(a, &.{ ZDF, "-k", "/" });
    try std.testing.expectEqual(@as(?u8, 0), g.exit_code);
    try std.testing.expectEqual(@as(?u8, 0), z.exit_code);

    // Header is fully deterministic (column widths driven by stable values).
    try std.testing.expectEqualStrings(headerLine(g.stdout).?, headerLine(z.stdout).?);

    const gt = try tokens(a, firstDataLine(g.stdout).?);
    const zt = try tokens(a, firstDataLine(z.stdout).?);
    // tokens: [device, 1K-blocks, Used, Available, Use%, mount]
    try std.testing.expectEqual(@as(usize, 6), gt.len);
    try std.testing.expectEqual(gt.len, zt.len);
    try std.testing.expectEqualStrings(gt[0], zt[0]); // device
    try std.testing.expectEqualStrings(gt[1], zt[1]); // total 1K-blocks (stable)
    try std.testing.expectEqualStrings(gt[gt.len - 1], zt[zt.len - 1]); // mount
}

test "gdf parity: -T / prints the same filesystem type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gdf = findGdf(a) orelse return error.SkipZigTest;

    const g = try run(a, &.{ gdf, "-k", "-T", "/" });
    const z = try run(a, &.{ ZDF, "-k", "-T", "/" });
    try std.testing.expectEqualStrings(headerLine(g.stdout).?, headerLine(z.stdout).?);

    const gt = try tokens(a, firstDataLine(g.stdout).?);
    const zt = try tokens(a, firstDataLine(z.stdout).?);
    // tokens: [device, Type, 1K-blocks, Used, Available, Use%, mount]
    try std.testing.expectEqual(@as(usize, 7), gt.len);
    try std.testing.expectEqualStrings(gt[0], zt[0]); // device
    try std.testing.expectEqualStrings(gt[1], zt[1]); // fstype
    try std.testing.expectEqualStrings(gt[2], zt[2]); // total
    try std.testing.expectEqualStrings(gt[gt.len - 1], zt[zt.len - 1]); // mount
}

test "gdf parity: -B1M / header text + scaled total match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gdf = findGdf(a) orelse return error.SkipZigTest;

    const g = try run(a, &.{ gdf, "-B1M", "/" });
    const z = try run(a, &.{ ZDF, "-B1M", "/" });
    // Header must literally read "1M-blocks", proving -B is parsed & threaded.
    try std.testing.expectEqualStrings(headerLine(g.stdout).?, headerLine(z.stdout).?);
    try std.testing.expect(std.mem.indexOf(u8, headerLine(z.stdout).?, "1M-blocks") != null);

    const gt = try tokens(a, firstDataLine(g.stdout).?);
    const zt = try tokens(a, firstDataLine(z.stdout).?);
    try std.testing.expectEqualStrings(gt[1], zt[1]); // total in 1M-blocks (stable)
}

test "gdf parity: -B512 / header reads 512B-blocks and total matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gdf = findGdf(a) orelse return error.SkipZigTest;

    const g = try run(a, &.{ gdf, "-B512", "/" });
    const z = try run(a, &.{ ZDF, "-B512", "/" });
    try std.testing.expectEqualStrings(headerLine(g.stdout).?, headerLine(z.stdout).?);
    const gt = try tokens(a, firstDataLine(g.stdout).?);
    const zt = try tokens(a, firstDataLine(z.stdout).?);
    try std.testing.expectEqualStrings(gt[1], zt[1]);
}

// --- human-readable: SI vs binary must differ and match gdf's rounding -----

test "gdf parity: -h / (binary, base 1024) size column matches gdf" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gdf = findGdf(a) orelse return error.SkipZigTest;

    const g = try run(a, &.{ gdf, "-h", "/" });
    const z = try run(a, &.{ ZDF, "-h", "/" });
    try std.testing.expectEqualStrings(headerLine(g.stdout).?, headerLine(z.stdout).?);
    const gt = try tokens(a, firstDataLine(g.stdout).?);
    const zt = try tokens(a, firstDataLine(z.stdout).?);
    try std.testing.expectEqualStrings(gt[0], zt[0]); // device
    try std.testing.expectEqualStrings(gt[1], zt[1]); // Size (total, GNU round-up)
    try std.testing.expectEqualStrings(gt[gt.len - 1], zt[zt.len - 1]); // mount
}

test "gdf parity: -H / (SI, base 1000) size differs from -h and matches gdf --si" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gdf = findGdf(a) orelse return error.SkipZigTest;

    const g = try run(a, &.{ gdf, "-H", "/" });
    const z = try run(a, &.{ ZDF, "-H", "/" });
    try std.testing.expectEqualStrings(headerLine(g.stdout).?, headerLine(z.stdout).?);
    const gt = try tokens(a, firstDataLine(g.stdout).?);
    const zt = try tokens(a, firstDataLine(z.stdout).?);
    try std.testing.expectEqualStrings(gt[1], zt[1]); // SI size (total, stable)

    // Regression guard for the old "-H is just an alias of -h" bug: the SI
    // total must not equal the binary total for a terabyte-scale volume.
    const zh = try run(a, &.{ ZDF, "-h", "/" });
    const zht = try tokens(a, firstDataLine(zh.stdout).?);
    try std.testing.expect(!std.mem.eql(u8, zt[1], zht[1]));
}

// --- exit-status & routing: documented POSIX/GNU behavior, gdf confirms -----

test "exit status: missing operand path exits 1 (matches gdf, POSIX >0)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const missing = "/zdf_no_such_path_9f3a2b";

    const z = try run(a, &.{ ZDF, missing });
    try std.testing.expectEqual(@as(?u8, 1), z.exit_code);
    try std.testing.expect(z.stderr.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, z.stderr, missing) != null);

    if (findGdf(a)) |gdf| {
        const g = try run(a, &.{ gdf, missing });
        try std.testing.expectEqual(@as(?u8, 1), g.exit_code);
    }
}

test "exit status: unknown option exits 1 with a diagnostic on stderr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const z = try run(a, &.{ ZDF, "-Z" });
    try std.testing.expectEqual(@as(?u8, 1), z.exit_code);
    try std.testing.expect(z.stderr.len > 0);
    try std.testing.expect(z.stdout.len == 0);

    if (findGdf(a)) |gdf| {
        const g = try run(a, &.{ gdf, "-Z" });
        try std.testing.expectEqual(@as(?u8, 1), g.exit_code);
    }
}

test "routing: --version writes to stdout and exits 0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const z = try run(a, &.{ ZDF, "--version" });
    try std.testing.expectEqual(@as(?u8, 0), z.exit_code);
    try std.testing.expect(std.mem.startsWith(u8, z.stdout, "zdf "));
    try std.testing.expect(z.stderr.len == 0);
}

test "routing: --help writes to stdout and exits 0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const z = try run(a, &.{ ZDF, "--help" });
    try std.testing.expectEqual(@as(?u8, 0), z.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, z.stdout, "Usage: zdf") != null);
    try std.testing.expect(z.stderr.len == 0);
}

// --- crash-safety: the original panicked (integer overflow) on `zdf /` ------

test "crash-safety: listing and per-path stat exit 0 without panicking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The original Linux-ABI struct made `zdf /` read garbage and panic on
    // `f_blocks * block_size` (exit 134). Both of these must now exit 0.
    const per_path = try run(a, &.{ ZDF, "-k", "/" });
    try std.testing.expectEqual(@as(?u8, 0), per_path.exit_code);

    const listing = try run(a, &.{ZDF});
    try std.testing.expectEqual(@as(?u8, 0), listing.exit_code);
    // A real listing must contain at least the root mount.
    try std.testing.expect(std.mem.indexOf(u8, listing.stdout, " /\n") != null or
        std.mem.endsWith(u8, listing.stdout, " /\n"));
}
