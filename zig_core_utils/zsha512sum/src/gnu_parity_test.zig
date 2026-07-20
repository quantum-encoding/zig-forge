//! Externally-anchored parity tests for zsha512sum (GNU `sha512sum` work-alike).
//!
//! Two classes of anchor, per zig-forge/CLAUDE.md's golden rule (NO
//! roundtrip-only tests — this file never asserts decode(encode(x))==x):
//!
//!  1. SPEC vectors written literally below. The SHA-512 digests of "abc" and
//!     the empty string are the published reference values (FIPS 180-4 /
//!     NIST "Secure Hash Standard" example for SHA-512("abc"); the empty-input
//!     digest cf83e13… is the canonical value emitted by every conforming
//!     implementation). zsha512sum did not author these bytes.
//!
//!  2. LIVE diff against the real GNU coreutils `sha512sum` (gsha512sum). When
//!     the GNU binary is present we run it side-by-side with zsha512sum for a
//!     spread of flags/inputs and require byte-identical stdout + matching exit
//!     codes. GNU is the external authority. GNU emits diagnostics prefixed with
//!     its own program name ("gsha512sum:"), so stderr is compared only after
//!     normalizing the program-name prefix away; stdout is compared verbatim.
//!     If no GNU binary is found the GNU-diff tests skip; the spec-vector and
//!     documented-behavior tests still run and still bite.
//!
//! The designated MUTATION-TEST anchor is
//!   `check: final line without trailing newline is still verified`
//! which pins the fix for the High-severity silent-pass bug (a checksum file
//! whose last line lacks '\n' was dropped, verifying NOTHING yet exiting 0).

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;

const z_exe: []const u8 = build_options.z_exe;

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/sha512sum",
    "/opt/homebrew/bin/gsha512sum",
    "/usr/local/bin/gsha512sum",
    "/usr/bin/sha512sum",
};

// ---- Published SHA-512 reference vectors, written literally ------------------
// FIPS 180-4 example / NIST test vector for SHA-512("abc"):
const abc_512 = "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f";
// Canonical SHA-512 of the empty string:
const empty_512 = "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e";

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

/// Per-test scratch dir with a couple of well-known fixture files.
const Fixtures = struct {
    dir: []u8,
    abc: []u8, // file containing "abc"
    empty: []u8, // empty file
    subdir: []u8, // a directory (to test the "Is a directory" path)
    gpa: std.mem.Allocator,

    fn init(gpa: std.mem.Allocator, name: []const u8) !Fixtures {
        var t = Io.Threaded.init(gpa, .{});
        defer t.deinit();
        const io = t.io();
        const dir = try std.fmt.allocPrint(gpa, "/tmp/zsha512sum_parity_{s}", .{name});
        Io.Dir.cwd().deleteTree(io, dir) catch {};
        Io.Dir.cwd().createDirPath(io, dir) catch {};
        const abc = try std.fmt.allocPrint(gpa, "{s}/abc", .{dir});
        const empty = try std.fmt.allocPrint(gpa, "{s}/empty", .{dir});
        const subdir = try std.fmt.allocPrint(gpa, "{s}/subdir", .{dir});
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = abc, .data = "abc" });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = empty, .data = "" });
        Io.Dir.cwd().createDirPath(io, subdir) catch {};
        return .{ .dir = dir, .abc = abc, .empty = empty, .subdir = subdir, .gpa = gpa };
    }

    fn deinit(self: *Fixtures) void {
        var t = Io.Threaded.init(self.gpa, .{});
        defer t.deinit();
        const io = t.io();
        Io.Dir.cwd().deleteTree(io, self.dir) catch {};
        self.gpa.free(self.dir);
        self.gpa.free(self.abc);
        self.gpa.free(self.empty);
        self.gpa.free(self.subdir);
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

test "spec: SHA-512 of \"abc\" matches FIPS 180-4 vector" {
    const gpa = std.testing.allocator;
    var fx = try Fixtures.init(gpa, "t1");
    defer fx.deinit();

    const r = try run(gpa, &.{ z_exe, fx.abc });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expectEqualStrings(abc_512, leadingHash(r.stdout));
}

test "spec: SHA-512 of empty input matches reference vector" {
    const gpa = std.testing.allocator;
    var fx = try Fixtures.init(gpa, "t2");
    defer fx.deinit();

    const r = try run(gpa, &.{ z_exe, fx.empty });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expectEqualStrings(empty_512, leadingHash(r.stdout));
}

// ---- Documented-GNU-behavior tests (assert exact bytes / exit codes) --------
// Sources: GNU coreutils `sha512sum` observed reference output (coreutils 9.10)
// and the POSIX/coreutils spec for `md5sum`-family verification. These pin the
// audited bug fixes even when no GNU binary is on the machine.

test "directory argument is 'Is a directory' + exit 1, not empty-digest exit 0" {
    const gpa = std.testing.allocator;
    var fx = try Fixtures.init(gpa, "t3");
    defer fx.deinit();

    const r = try run(gpa, &.{ z_exe, fx.subdir });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(@as(u8, 1), r.code);
    // Must NOT have hashed the directory as empty input.
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, empty_512) == null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "Is a directory") != null);
}

test "check: empty checksum file reports no formatted lines and exits 1" {
    const gpa = std.testing.allocator;
    var fx = try Fixtures.init(gpa, "t4");
    defer fx.deinit();

    const sum = try fx.writeFile("empty.sum", "");
    defer gpa.free(sum);
    const r = try run(gpa, &.{ z_exe, "-c", sum });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "no properly formatted checksum lines found") != null);
}

test "check: garbage checksum file reports no formatted lines and exits 1" {
    const gpa = std.testing.allocator;
    var fx = try Fixtures.init(gpa, "t5");
    defer fx.deinit();

    const sum = try fx.writeFile("garbage.sum", "this is not a checksum line\n");
    defer gpa.free(sum);
    const r = try run(gpa, &.{ z_exe, "-c", sum });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "no properly formatted checksum lines found") != null);
}

// *** DESIGNATED MUTATION-TEST ANCHOR ***
// Remove the residual-line flush in checkFile and this goes RED: a single-line
// manifest with no trailing '\n' verified NOTHING yet exited 0 (silent pass).
test "check: final line without trailing newline is still verified" {
    const gpa = std.testing.allocator;
    var fx = try Fixtures.init(gpa, "t6");
    defer fx.deinit();

    // NOTE: no trailing newline. The one line references fx.abc with the real digest.
    const body = try std.fmt.allocPrint(gpa, "{s}  {s}", .{ abc_512, fx.abc });
    defer gpa.free(body);
    const sum = try fx.writeFile("nonl.sum", body);
    defer gpa.free(sum);

    const r = try run(gpa, &.{ z_exe, "-c", sum });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    // The line MUST have been processed: an "OK" line must appear.
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, ": OK") != null);
}

test "check: uppercase-hex digest verifies OK (case-insensitive)" {
    const gpa = std.testing.allocator;
    var fx = try Fixtures.init(gpa, "t7");
    defer fx.deinit();

    var upper: [abc_512.len]u8 = undefined;
    for (abc_512, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
    const body = try std.fmt.allocPrint(gpa, "{s}  {s}\n", .{ upper, fx.abc });
    defer gpa.free(body);
    const sum = try fx.writeFile("upper.sum", body);
    defer gpa.free(sum);

    const r = try run(gpa, &.{ z_exe, "-c", sum });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, ": OK") != null);
}

test "check: BSD --tag output is verifiable by -c" {
    const gpa = std.testing.allocator;
    var fx = try Fixtures.init(gpa, "t8");
    defer fx.deinit();

    // Produce a --tag manifest with zsha512sum itself, then verify it.
    const rt = try run(gpa, &.{ z_exe, "--tag", fx.abc });
    defer gpa.free(rt.stdout);
    defer gpa.free(rt.stderr);
    try std.testing.expect(std.mem.startsWith(u8, rt.stdout, "SHA512 ("));
    const sum = try fx.writeFile("tag.sum", rt.stdout);
    defer gpa.free(sum);

    const r = try run(gpa, &.{ z_exe, "-c", sum });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, ": OK") != null);
}

test "unrecognized long and short options exit 1 with a diagnostic" {
    const gpa = std.testing.allocator;
    var fx = try Fixtures.init(gpa, "t9");
    defer fx.deinit();

    {
        const r = try run(gpa, &.{ z_exe, "--frobnicate", fx.abc });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try std.testing.expectEqual(@as(u8, 1), r.code);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "unrecognized option") != null);
    }
    {
        const r = try run(gpa, &.{ z_exe, "-x", fx.abc });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try std.testing.expectEqual(@as(u8, 1), r.code);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "invalid option") != null);
    }
}

test "check: mismatch warning uses GNU singular/plural wording" {
    const gpa = std.testing.allocator;
    var fx = try Fixtures.init(gpa, "t10");
    defer fx.deinit();

    // One wrong digest (all zeros) → singular "1 computed checksum did NOT match".
    const zeros = "0" ** abc_512.len;
    const body1 = try std.fmt.allocPrint(gpa, "{s}  {s}\n", .{ zeros, fx.abc });
    defer gpa.free(body1);
    const sum1 = try fx.writeFile("bad1.sum", body1);
    defer gpa.free(sum1);
    {
        const r = try run(gpa, &.{ z_exe, "-c", sum1 });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try std.testing.expectEqual(@as(u8, 1), r.code);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "WARNING: 1 computed checksum did NOT match") != null);
    }
    // Two wrong digests → plural "2 computed checksums did NOT match".
    const body2 = try std.fmt.allocPrint(gpa, "{s}  {s}\n{s}  {s}\n", .{ zeros, fx.abc, zeros, fx.empty });
    defer gpa.free(body2);
    const sum2 = try fx.writeFile("bad2.sum", body2);
    defer gpa.free(sum2);
    {
        const r = try run(gpa, &.{ z_exe, "-c", sum2 });
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try std.testing.expectEqual(@as(u8, 1), r.code);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "WARNING: 2 computed checksums did NOT match") != null);
    }
}

// ===========================================================================
// Live GNU-diff tests (skip when no GNU binary is present)
// ===========================================================================

/// Compare stdout verbatim and exit code; stderr only after stripping the
/// leading program-name token from each diagnostic line (GNU uses
/// "gsha512sum:", zsha512sum uses "zsha512sum:").
fn normalizeStderr(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| {
        // Drop a leading "<prog>: " prefix if present.
        const stripped = if (std.mem.indexOf(u8, line, ": ")) |idx|
            line[idx + 2 ..]
        else
            line;
        // Also drop the "Try '<prog> --help'..." hint line, which embeds the path.
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "Try '")) continue;
        try out.appendSlice(gpa, stripped);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

fn expectSameAsGnu(gpa: std.mem.Allocator, z_args: []const []const u8, gnu_args: []const []const u8) !void {
    const rz = try run(gpa, z_args);
    defer gpa.free(rz.stdout);
    defer gpa.free(rz.stderr);
    const rg = try run(gpa, gnu_args);
    defer gpa.free(rg.stdout);
    defer gpa.free(rg.stderr);
    try std.testing.expectEqualStrings(rg.stdout, rz.stdout);
    try std.testing.expectEqual(rg.code, rz.code);
    const nz = try normalizeStderr(gpa, rz.stderr);
    defer gpa.free(nz);
    const ng = try normalizeStderr(gpa, rg.stderr);
    defer gpa.free(ng);
    try std.testing.expectEqualStrings(ng, nz);
}

test "gnu-diff: default / -b / --tag stdout byte-identical" {
    const gpa = std.testing.allocator;
    const gnu = gnuBin() orelse return error.SkipZigTest;
    var fx = try Fixtures.init(gpa, "g1");
    defer fx.deinit();

    const cases = [_][]const []const u8{
        &.{fx.abc},
        &.{ fx.abc, fx.empty },
        &.{ "-b", fx.abc },
        &.{ "-t", fx.abc },
        &.{ "--tag", fx.abc },
        &.{ "-z", fx.abc },
        &.{fx.empty},
    };
    for (cases) |extra| {
        var z_argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer z_argv.deinit(gpa);
        var gnu_argv: std.ArrayListUnmanaged([]const u8) = .empty;
        defer gnu_argv.deinit(gpa);
        try z_argv.append(gpa, z_exe);
        try gnu_argv.append(gpa, gnu);
        try z_argv.appendSlice(gpa, extra);
        try gnu_argv.appendSlice(gpa, extra);
        try expectSameAsGnu(gpa, z_argv.items, gnu_argv.items);
    }
}

test "gnu-diff: stdin hashing prints the '-' digest identically" {
    const gpa = std.testing.allocator;
    const gnu = gnuBin() orelse return error.SkipZigTest;

    const z_cmd = try std.fmt.allocPrint(gpa, "printf abc | {s}", .{z_exe});
    defer gpa.free(z_cmd);
    const gnu_cmd = try std.fmt.allocPrint(gpa, "printf abc | {s}", .{gnu});
    defer gpa.free(gnu_cmd);

    const rz = try run(gpa, &.{ "/bin/sh", "-c", z_cmd });
    defer gpa.free(rz.stdout);
    defer gpa.free(rz.stderr);
    const rg = try run(gpa, &.{ "/bin/sh", "-c", gnu_cmd });
    defer gpa.free(rg.stdout);
    defer gpa.free(rg.stderr);

    try std.testing.expectEqual(@as(u8, 0), rz.code);
    try std.testing.expectEqualStrings(rg.stdout, rz.stdout);
}

test "gnu-diff: zsha512sum verifies a GNU-produced manifest (standard + --tag)" {
    const gpa = std.testing.allocator;
    const gnu = gnuBin() orelse return error.SkipZigTest;
    var fx = try Fixtures.init(gpa, "g2");
    defer fx.deinit();

    // Standard manifest produced by GNU, verified by zsha512sum.
    {
        const rg = try run(gpa, &.{ gnu, fx.abc });
        defer gpa.free(rg.stdout);
        defer gpa.free(rg.stderr);
        const sums = try fx.writeFile("gnu.sums", rg.stdout);
        defer gpa.free(sums);
        const rz = try run(gpa, &.{ z_exe, "-c", sums });
        defer gpa.free(rz.stdout);
        defer gpa.free(rz.stderr);
        try std.testing.expectEqual(@as(u8, 0), rz.code);
        try std.testing.expect(std.mem.indexOf(u8, rz.stdout, ": OK") != null);
    }
    // GNU --tag manifest, verified by zsha512sum.
    {
        const rg = try run(gpa, &.{ gnu, "--tag", fx.abc });
        defer gpa.free(rg.stdout);
        defer gpa.free(rg.stderr);
        const sums = try fx.writeFile("gnu_tag.sums", rg.stdout);
        defer gpa.free(sums);
        const rz = try run(gpa, &.{ z_exe, "-c", sums });
        defer gpa.free(rz.stdout);
        defer gpa.free(rz.stderr);
        try std.testing.expectEqual(@as(u8, 0), rz.code);
        try std.testing.expect(std.mem.indexOf(u8, rz.stdout, ": OK") != null);
    }
}

test "gnu-diff: check-mode exit codes and stdout match (OK / FAILED / missing)" {
    const gpa = std.testing.allocator;
    const gnu = gnuBin() orelse return error.SkipZigTest;
    var fx = try Fixtures.init(gpa, "g3");
    defer fx.deinit();

    // A good line, a tampered line, and a missing file, all in one manifest.
    const zeros = "0" ** abc_512.len;
    const body = try std.fmt.allocPrint(
        gpa,
        "{s}  {s}\n{s}  {s}\n{s}  {s}/nope\n",
        .{ abc_512, fx.abc, zeros, fx.empty, abc_512, fx.dir },
    );
    defer gpa.free(body);
    const sums = try fx.writeFile("mixed.sums", body);
    defer gpa.free(sums);

    const rz = try run(gpa, &.{ z_exe, "-c", sums });
    defer gpa.free(rz.stdout);
    defer gpa.free(rz.stderr);
    const rg = try run(gpa, &.{ gnu, "-c", sums });
    defer gpa.free(rg.stdout);
    defer gpa.free(rg.stderr);

    try std.testing.expectEqualStrings(rg.stdout, rz.stdout);
    try std.testing.expectEqual(rg.code, rz.code);
}
