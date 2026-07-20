//! Externally-anchored parity tests for zb2sum (GNU b2sum work-alike).
//!
//! Two classes of anchor, per zig-forge/CLAUDE.md's golden rule (NO roundtrip-only tests):
//!
//!  1. SPEC vectors written literally in this file. The BLAKE2b-512 digests of
//!     "abc" and the empty string are the reference vectors published with the
//!     BLAKE2 algorithm (RFC 7693 "The BLAKE2 Cryptographic Hash and MAC",
//!     Appendix A gives BLAKE2b-512("abc"); the empty-input digest is the
//!     canonical value emitted by the BLAKE2 reference implementation and every
//!     conforming library). zb2sum did not author these bytes.
//!
//!  2. LIVE diff against the real GNU coreutils `b2sum` binary (gb2sum). When a
//!     GNU binary is present on this machine we run it side-by-side with zb2sum
//!     for a spread of flags/inputs and require byte-identical stdout + matching
//!     exit codes. GNU is the external authority. If no GNU binary is found the
//!     GNU-diff tests skip (the spec-vector tests still run and still bite).
//!
//! The single most important anchor is `test "l256 is real BLAKE2b-256, not
//! truncated BLAKE2b-512"`: it pins the fix for the critical -l/--length bug and
//! is the designated mutation-test target.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;

const zb_exe: []const u8 = build_options.zb_exe;

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/b2sum",
    "/opt/homebrew/bin/gb2sum",
    "/usr/local/bin/b2sum",
    "/usr/bin/b2sum",
};

// ---- Spec (RFC 7693 / BLAKE2 reference) vectors, written literally ----------
const abc_512 = "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923";
const empty_512 = "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce";
// GNU coreutils 9.10 reference output for the length-parameterized digests.
const abc_256 = "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319";
const abc_8 = "6b";
const abc_384 = "6f56a82c8e7ef526dfe182eb5212f7db9df1317e57815dbda46083fc30f54ee6c66ba83be64b302d7cba6ce15bb556f4";

const RunOut = struct {
    stdout: []u8,
    stderr: []u8,
    code: u8, // 255 == terminated by signal / abnormal
};

fn run(gpa: std.mem.Allocator, argv: []const []const u8) !RunOut {
    // The global single-threaded Io uses a failing allocator; process spawning
    // needs a real one, so stand up a Threaded backed by the test allocator.
    var t = Io.Threaded.init(gpa, .{});
    defer t.deinit();
    const io = t.io();
    const r = try std.process.run(gpa, io, .{ .argv = argv });
    const code: u8 = switch (r.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = r.stdout, .stderr = r.stderr, .code = code };
}

fn gnuBin() ?[]const u8 {
    var t = Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    const io = t.io();
    for (gnu_candidates) |c| {
        Io.Dir.cwd().access(io, c, .{}) catch continue;
        return c;
    }
    return null;
}

/// Per-test scratch dir under the system temp, unique to the process.
const Fixtures = struct {
    dir: []u8,
    abc: []u8, // file containing "abc"
    empty: []u8, // empty file
    gpa: std.mem.Allocator,

    fn init(gpa: std.mem.Allocator, name: []const u8) !Fixtures {
        var t = Io.Threaded.init(gpa, .{});
        defer t.deinit();
        const io = t.io();
        const dir = try std.fmt.allocPrint(gpa, "/tmp/zb2sum_parity_{s}", .{name});
        Io.Dir.cwd().deleteTree(io, dir) catch {};
        Io.Dir.cwd().createDirPath(io, dir) catch {};
        const abc = try std.fmt.allocPrint(gpa, "{s}/abc", .{dir});
        const empty = try std.fmt.allocPrint(gpa, "{s}/empty", .{dir});
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = abc, .data = "abc" });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = empty, .data = "" });
        return .{ .dir = dir, .abc = abc, .empty = empty, .gpa = gpa };
    }

    fn deinit(self: *Fixtures) void {
        var t = Io.Threaded.init(self.gpa, .{});
        defer t.deinit();
        const io = t.io();
        Io.Dir.cwd().deleteTree(io, self.dir) catch {};
        self.gpa.free(self.dir);
        self.gpa.free(self.abc);
        self.gpa.free(self.empty);
    }

    fn writeFile(self: *Fixtures, name: []const u8, data: []const u8) ![]u8 {
        var t = Io.Threaded.init(self.gpa, .{});
        defer t.deinit();
        const io = t.io();
        const p = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ self.dir, name });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = data });
        return p;
    }
};

/// The leading hex field of a `HASH  FILE` line.
fn leadingHash(out: []const u8) []const u8 {
    var n: usize = 0;
    while (n < out.len and out[n] != ' ') : (n += 1) {}
    return out[0..n];
}

// ===========================================================================
// Spec-anchored tests (always run; no external binary required)
// ===========================================================================

test "spec: BLAKE2b-512 of \"abc\" matches RFC 7693 vector" {
    const gpa = std.testing.allocator;
    var fx = try Fixtures.init(gpa, "t1");
    defer fx.deinit();

    const r = try run(gpa, &.{ zb_exe, fx.abc });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expectEqualStrings(abc_512, leadingHash(r.stdout));
}

test "spec: BLAKE2b-512 of empty input matches reference vector" {
    const gpa = std.testing.allocator;
    var fx = try Fixtures.init(gpa, "t2");
    defer fx.deinit();

    const r = try run(gpa, &.{ zb_exe, fx.empty });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expectEqualStrings(empty_512, leadingHash(r.stdout));
}

// The designated mutation-test anchor. If hashFile ever reverts to computing
// BLAKE2b-512 and truncating (init(.{}) without expected_out_bits), this fails:
// the truncated-512 prefix (ba80a53f...) differs from the real BLAKE2b-256.
test "l256 is real BLAKE2b-256, not truncated BLAKE2b-512" {
    const gpa = std.testing.allocator;
    var fx = try Fixtures.init(gpa, "t3");
    defer fx.deinit();

    const r = try run(gpa, &.{ zb_exe, "-l", "256", fx.abc });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    const got = leadingHash(r.stdout);
    try std.testing.expectEqualStrings(abc_256, got); // real BLAKE2b-256
    // And it must NOT be the first 64 hex chars of the BLAKE2b-512 digest.
    try std.testing.expect(!std.mem.eql(u8, got, abc_512[0..64]));
}

test "l8 and l384 match GNU reference vectors" {
    const gpa = std.testing.allocator;
    var fx = try Fixtures.init(gpa, "t4");
    defer fx.deinit();

    {
        const r = try run(gpa, &.{ zb_exe, "-l", "8", fx.abc });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try std.testing.expectEqualStrings(abc_8, leadingHash(r.stdout));
    }
    {
        const r = try run(gpa, &.{ zb_exe, "-l", "384", fx.abc });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try std.testing.expectEqualStrings(abc_384, leadingHash(r.stdout));
    }
}

test "oversized -l does not crash and exits 1" {
    const gpa = std.testing.allocator;
    var fx = try Fixtures.init(gpa, "t5");
    defer fx.deinit();

    const r = try run(gpa, &.{ zb_exe, "-l", "99999", fx.abc });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    // Was a SIGABRT (code 255) integer-overflow panic; must now be a clean exit 1.
    try std.testing.expectEqual(@as(u8, 1), r.code);
}

test "check: garbage file reports no formatted lines and exits 1" {
    const gpa = std.testing.allocator;
    var fx = try Fixtures.init(gpa, "t6");
    defer fx.deinit();

    const garbage = try fx.writeFile("garbage", "this is not a checksum line\n");
    defer gpa.free(garbage);

    const r = try run(gpa, &.{ zb_exe, "-c", garbage });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "no properly formatted checksum lines found") != null);
}

// ===========================================================================
// Live GNU-diff tests (skip when no GNU binary is present)
// ===========================================================================

fn expectSameAsGnu(gpa: std.mem.Allocator, gnu: []const u8, zb_args: []const []const u8, gnu_args: []const []const u8) !void {
    const rz = try run(gpa, zb_args);
    defer gpa.free(rz.stdout);
    defer gpa.free(rz.stderr);
    const rg = try run(gpa, gnu_args);
    defer gpa.free(rg.stdout);
    defer gpa.free(rg.stderr);
    _ = gnu;
    try std.testing.expectEqualStrings(rg.stdout, rz.stdout);
    try std.testing.expectEqual(rg.code, rz.code);
}

test "gnu-diff: default / -l / --tag / binary stdout byte-identical" {
    const gpa = std.testing.allocator;
    const gnu = gnuBin() orelse return error.SkipZigTest;
    var fx = try Fixtures.init(gpa, "t7");
    defer fx.deinit();

    const cases = [_][]const []const u8{
        &.{fx.abc}, // default 512
        &.{ "-l", "256", fx.abc },
        &.{ "-l", "8", fx.abc },
        &.{ "-l", "384", fx.abc },
        &.{ "--tag", fx.abc },
        &.{ "--tag", "-l", "256", fx.abc },
        &.{ "-b", fx.abc }, // binary mode marker
        &.{fx.empty}, // empty file
    };
    for (cases) |extra| {
        var zb_argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer zb_argv.deinit(gpa);
        var gnu_argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer gnu_argv.deinit(gpa);
        try zb_argv.append(gpa, zb_exe);
        try gnu_argv.append(gpa, gnu);
        try zb_argv.appendSlice(gpa, extra);
        try gnu_argv.appendSlice(gpa, extra);
        try expectSameAsGnu(gpa, gnu, zb_argv.items, gnu_argv.items);
    }
}

test "gnu-diff: stdin hashing prints the '-' digest identically" {
    const gpa = std.testing.allocator;
    const gnu = gnuBin() orelse return error.SkipZigTest;

    // Feed the same bytes on stdin to both via `sh -c` and compare.
    const zb_cmd = try std.fmt.allocPrint(gpa, "printf abc | {s}", .{zb_exe});
    defer gpa.free(zb_cmd);
    const gnu_cmd = try std.fmt.allocPrint(gpa, "printf abc | {s}", .{gnu});
    defer gpa.free(gnu_cmd);

    const rz = try run(gpa, &.{ "/bin/sh", "-c", zb_cmd });
    defer gpa.free(rz.stdout);
    defer gpa.free(rz.stderr);
    const rg = try run(gpa, &.{ "/bin/sh", "-c", gnu_cmd });
    defer gpa.free(rg.stdout);
    defer gpa.free(rg.stderr);

    try std.testing.expectEqual(@as(u8, 0), rz.code);
    try std.testing.expectEqualStrings(rg.stdout, rz.stdout);
}

test "gnu-diff: zb2sum verifies GNU-produced checksum files (standard + --tag)" {
    const gpa = std.testing.allocator;
    const gnu = gnuBin() orelse return error.SkipZigTest;
    var fx = try Fixtures.init(gpa, "t8");
    defer fx.deinit();

    // Standard -l 256 sums produced by GNU, verified by zb2sum.
    {
        const rg = try run(gpa, &.{ gnu, "-l", "256", fx.abc });
        defer gpa.free(rg.stdout);
        defer gpa.free(rg.stderr);
        const sums = try fx.writeFile("std.sums", rg.stdout);
        defer gpa.free(sums);
        const rz = try run(gpa, &.{ zb_exe, "-c", sums });
        defer gpa.free(rz.stdout);
        defer gpa.free(rz.stderr);
        try std.testing.expectEqual(@as(u8, 0), rz.code);
        try std.testing.expect(std.mem.indexOf(u8, rz.stdout, "OK") != null);
    }
    // BSD --tag sums produced by GNU, verified by zb2sum.
    {
        const rg = try run(gpa, &.{ gnu, "--tag", "-l", "256", fx.abc });
        defer gpa.free(rg.stdout);
        defer gpa.free(rg.stderr);
        const sums = try fx.writeFile("tag.sums", rg.stdout);
        defer gpa.free(sums);
        const rz = try run(gpa, &.{ zb_exe, "-c", sums });
        defer gpa.free(rz.stdout);
        defer gpa.free(rz.stderr);
        try std.testing.expectEqual(@as(u8, 0), rz.code);
        try std.testing.expect(std.mem.indexOf(u8, rz.stdout, "OK") != null);
    }
}

test "gnu-diff: tampered checksum yields FAILED and exit 1 like GNU" {
    const gpa = std.testing.allocator;
    const gnu = gnuBin() orelse return error.SkipZigTest;
    var fx = try Fixtures.init(gpa, "t9");
    defer fx.deinit();

    // A well-formed line whose hash is wrong (all zeros).
    const bad = try std.fmt.allocPrint(
        gpa,
        "0000000000000000000000000000000000000000000000000000000000000000  {s}\n",
        .{fx.abc},
    );
    defer gpa.free(bad);
    const sums = try fx.writeFile("bad.sums", bad);
    defer gpa.free(sums);

    const rz = try run(gpa, &.{ zb_exe, "-c", sums });
    defer gpa.free(rz.stdout);
    defer gpa.free(rz.stderr);
    const rg = try run(gpa, &.{ gnu, "-c", sums });
    defer gpa.free(rg.stdout);
    defer gpa.free(rg.stderr);

    try std.testing.expectEqual(rg.code, rz.code); // both 1
    try std.testing.expectEqual(@as(u8, 1), rz.code);
    try std.testing.expect(std.mem.indexOf(u8, rz.stdout, "FAILED") != null);
}
