//! Externally-anchored parity tests for zseq (GNU `seq`).
//!
//! ANCHOR: expectations are diffed byte-for-byte against the real GNU coreutils
//! `seq` binary (coreutils 9.10) discovered on this machine. The expected bytes
//! are NOT written by us — they are whatever the reference binary emits for the
//! same argv. This is a true external anchor per the zig-forge CLAUDE.md golden
//! rule (not a roundtrip, not a self-hash). If no GNU `seq` is present the test
//! errors rather than silently passing with no anchor.
//!
//! A handful of cases anchor to GNU's *observable contract* rather than exact
//! bytes, because the diagnostic text necessarily embeds the program name
//! ("zseq" vs "seq"): NaN rejection anchors to exit==1 + empty stdout; --help /
//! --version anchor to stdout==non-empty, stderr==empty, exit==0. Each such
//! case still checks the reference binary produces the same contract.
//!
//! The `zseq` path and the GNU binary path are injected by build.zig via the
//! generated `build_options` module.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/seq",
    "/opt/homebrew/bin/gseq",
    "/usr/local/opt/coreutils/libexec/gnubin/seq",
    "/usr/local/bin/gseq",
};

fn findGnu() ?[]const u8 {
    if (build_options.gnu_path.len > 0) {
        if (fileExists(build_options.gnu_path)) return build_options.gnu_path;
    }
    for (gnu_candidates) |c| {
        if (fileExists(c)) return c;
    }
    return null;
}

fn fileExists(path: []const u8) bool {
    var t = Io.Threaded.init(std.testing.allocator, .{});
    defer t.deinit();
    Io.Dir.cwd().access(t.io(), path, .{}) catch return false;
    return true;
}

const Captured = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8, // 255 if terminated by signal / unknown
};

fn runCapture(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) !Captured {
    var t = Io.Threaded.init(allocator, .{});
    defer t.deinit();
    const io = t.io();

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe);
    for (args) |a| try argv.append(allocator, a);

    const result = try std.process.run(allocator, io, .{ .argv = argv.items });
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .stdout = result.stdout, .stderr = result.stderr, .exit_code = code };
}

/// Run the same argv through both binaries and assert byte-identical stdout
/// (the primary anchor).
fn expectParity(args: []const []const u8) !void {
    const allocator = std.testing.allocator;
    const gnu = findGnu() orelse {
        std.debug.print("no GNU seq binary found; cannot anchor\n", .{});
        return error.NoGnuReference;
    };

    const z = try runCapture(allocator, build_options.zseq_path, args);
    defer allocator.free(z.stdout);
    defer allocator.free(z.stderr);
    const g = try runCapture(allocator, gnu, args);
    defer allocator.free(g.stdout);
    defer allocator.free(g.stderr);

    if (!std.mem.eql(u8, z.stdout, g.stdout)) {
        std.debug.print("PARITY MISMATCH for argv {any}\n  zseq: [{s}]\n  gnu:  [{s}]\n", .{ args, z.stdout, g.stdout });
        return error.ParityMismatch;
    }
}

// ---------------------------------------------------------------------------
// Normal-operation parity (exact bytes vs GNU).
// ---------------------------------------------------------------------------

test "single operand: LAST" {
    try expectParity(&.{"5"});
    try expectParity(&.{"1"});
    try expectParity(&.{"0"});
    try expectParity(&.{"10"});
}

test "two operands: FIRST LAST" {
    try expectParity(&.{ "2", "5" });
    try expectParity(&.{ "-3", "3" });
    try expectParity(&.{ "5", "1" }); // empty: first>last, positive default step
    try expectParity(&.{ "100", "100" });
}

test "three operands: FIRST INCREMENT LAST" {
    try expectParity(&.{ "0", "2", "10" });
    try expectParity(&.{ "5", "-1", "1" }); // descending
    try expectParity(&.{ "1", "1", "1000" });
}

test "fractional increments render with derived fixed precision (GNU %.*f)" {
    try expectParity(&.{ "1", "0.5", "3" });
    try expectParity(&.{ "0.1", "0.1", "1" });
    try expectParity(&.{ "1", "0.1", "2" }); // drift-prone
    try expectParity(&.{ "3", "0.5", "5" });
    try expectParity(&.{ "0.5", "0.5", "5" });
}

test "-s / --separator" {
    try expectParity(&.{ "-s", ",", "1", "5" });
    try expectParity(&.{ "-s", ", ", "1", "3" });
    try expectParity(&.{ "--separator=|", "1", "4" });
    try expectParity(&.{ "-s", "x", "5" });
}

test "-w / --equal-width leading-zero padding" {
    try expectParity(&.{ "-w", "0", "9" });
    try expectParity(&.{ "-w", "8", "10" });
    try expectParity(&.{ "-w", "95", "105" });
    try expectParity(&.{ "-w", "-1", "1" });
    try expectParity(&.{ "-w", "0.5", "0.5", "3" });
}

// ---------------------------------------------------------------------------
// -f / --format printf conversions. These are the conversions the audit found
// broken (%g rendered as %f; %e/%f truncated instead of rounding; %a printed
// raw IEEE-754 bits).
// ---------------------------------------------------------------------------

test "%f fixed-point" {
    try expectParity(&.{ "-f", "%f", "1", "3" });
    try expectParity(&.{ "-f", "%.2f", "1", "3" });
    try expectParity(&.{ "-f", "%.0f", "5", "5" });
    try expectParity(&.{ "-f", "%10.2f", "1", "3" });
    try expectParity(&.{ "-f", "%-10.2f", "1", "3" });
    try expectParity(&.{ "-f", "%+.2f", "1", "3" });
    try expectParity(&.{ "-f", "%010.2f", "1", "3" });
    try expectParity(&.{ "-f", "%5.1f", "-1", "1" });
}

test "%e / %E scientific (printf exponent: sign + >=2 digits, rounded)" {
    try expectParity(&.{ "-f", "%e", "1", "3" });
    try expectParity(&.{ "-f", "%E", "1", "3" });
    try expectParity(&.{ "-f", "%.3e", "1", "3" });
    try expectParity(&.{ "-f", "%.0e", "1", "3" });
    try expectParity(&.{ "-f", "%e", "0", "0" });
}

test "%g / %G significant-digit semantics (bug fix)" {
    // Pre-fix these printed "1.000000" etc.; GNU strips trailing zeros and
    // switches to exponential by magnitude.
    try expectParity(&.{ "-f", "%g", "1", "5" });
    try expectParity(&.{ "-f", "%.3g", "1", "5" });
    try expectParity(&.{ "-f", "%g", "1000000", "1000000" }); // -> 1e+06
    try expectParity(&.{ "-f", "%g", "0.00001", "0.00001" }); // -> 1e-05
    try expectParity(&.{ "-f", "%g", "0.0001", "0.0001" }); // -> 0.0001
    try expectParity(&.{ "-f", "%g", "100.5", "100.5" });
    try expectParity(&.{ "-f", "%G", "1000000", "1000000" }); // -> 1E+06
    try expectParity(&.{ "-f", "%.10g", "3.14159265358979", "3.14159265358979" });
    try expectParity(&.{ "-f", "%.5g", "1.23456789", "1.23456789" });
    try expectParity(&.{ "-f", "%.2g", "0.0001234", "0.0001234" });
    try expectParity(&.{ "-f", "%g", "950", "950" });
}

test "%a / %A hex-float (bug fix: was raw bit pattern)" {
    // Default precision: GNU emits e.g. 0x1p+0, 0x1.fep+7.
    try expectParity(&.{ "-f", "%a", "1", "2" });
    try expectParity(&.{ "-f", "%a", "0.5", "0.5" });
    try expectParity(&.{ "-f", "%a", "255", "255" });
    try expectParity(&.{ "-f", "%A", "1", "2" });
}

test "literal text and %% in format" {
    try expectParity(&.{ "-f", "num=%g ", "1", "3" });
    try expectParity(&.{ "-f", "%%", "1", "2" });
    try expectParity(&.{ "-f", "[%.1f]", "1", "2" });
}

// ---------------------------------------------------------------------------
// CRITICAL fix: output to a *regular file* (seekable fd). The previous code
// re-created a File.Writer per print(), so every write clobbered the last at
// offset 0 and `zseq 5 > f` produced a 1-byte file. A pipe (what
// std.process.run uses) never exposed the bug, so this test redirects the
// child's stdout to an actual file, reads it back, and diffs against GNU.
// ---------------------------------------------------------------------------

fn runToFile(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8, path: []const u8) ![]u8 {
    var t = Io.Threaded.init(allocator, .{});
    defer t.deinit();
    const io = t.io();

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, exe);
    for (args) |a| try argv.append(allocator, a);

    const out_file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdout = .{ .file = out_file },
        .stderr = .ignore,
    });
    out_file.close(io); // child holds its own dup; close the parent handle
    _ = try child.wait(io);

    var buf: [1 << 16]u8 = undefined;
    const contents = try Io.Dir.cwd().readFile(io, path, &buf);
    return allocator.dupe(u8, contents);
}

fn deleteTemp(allocator: std.mem.Allocator, path: []const u8) void {
    var t = Io.Threaded.init(allocator, .{});
    defer t.deinit();
    Io.Dir.cwd().deleteFile(t.io(), path) catch {};
}

fn expectFileParity(args: []const []const u8) !void {
    const allocator = std.testing.allocator;
    const gnu = findGnu() orelse return error.NoGnuReference;

    const path = "zseq_parity_redirect.tmp";
    defer deleteTemp(allocator, path);

    const zbytes = try runToFile(allocator, build_options.zseq_path, args, path);
    defer allocator.free(zbytes);

    const g = try runCapture(allocator, gnu, args);
    defer allocator.free(g.stdout);
    defer allocator.free(g.stderr);

    if (!std.mem.eql(u8, zbytes, g.stdout)) {
        std.debug.print("FILE-REDIRECT MISMATCH for argv {any}\n  zseq(file): [{s}] ({d} bytes)\n  gnu(stdout): [{s}] ({d} bytes)\n", .{ args, zbytes, zbytes.len, g.stdout, g.stdout.len });
        return error.FileRedirectMismatch;
    }
    // Guard against the exact regression: a 1-byte (lone newline) file.
    if (zbytes.len <= 1 and g.stdout.len > 1) return error.FileRedirectTruncated;
}

test "CRITICAL: redirect to a regular file matches GNU (no offset-0 clobber)" {
    try expectFileParity(&.{"5"});
    try expectFileParity(&.{ "1", "10" });
    try expectFileParity(&.{ "0", "2", "20" });
    try expectFileParity(&.{ "-s", ",", "1", "8" });
}

// ---------------------------------------------------------------------------
// HIGH fix: large magnitude beyond i64 range used to panic in @intFromFloat.
// GNU seq formats it; anchor the formatted value of the first emitted line.
// (The full sequence count at the f64 resolution limit is a known GNU
// pathology under -f/-w and is deliberately not compared.)
// ---------------------------------------------------------------------------

fn firstLine(s: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, s, '\n') orelse s.len;
    return s[0..nl];
}

test "HIGH: 1e19 (beyond i64) formats instead of panicking; first line matches GNU" {
    const allocator = std.testing.allocator;
    const gnu = findGnu() orelse return error.NoGnuReference;

    const args = [_][]const u8{ "-f", "%.0f", "1e19", "1e19" };
    const z = try runCapture(allocator, build_options.zseq_path, &args);
    defer allocator.free(z.stdout);
    defer allocator.free(z.stderr);
    const g = try runCapture(allocator, gnu, &args);
    defer allocator.free(g.stdout);
    defer allocator.free(g.stderr);

    try std.testing.expectEqual(@as(u8, 0), z.exit_code); // no panic/abort
    try std.testing.expectEqualStrings("10000000000000000000", firstLine(z.stdout));
    try std.testing.expectEqualStrings(firstLine(g.stdout), firstLine(z.stdout));
}

// ---------------------------------------------------------------------------
// MEDIUM fix: NaN operands are rejected like GNU (exit 1, empty stdout).
// GNU: `seq nan` -> "invalid 'not-a-number' argument", exit 1.
// ---------------------------------------------------------------------------

test "MEDIUM: NaN operand rejected (exit 1, empty stdout) like GNU" {
    const allocator = std.testing.allocator;
    const gnu = findGnu() orelse return error.NoGnuReference;

    for ([_][]const u8{ "nan", "NaN", "-nan" }) |bad| {
        const args = [_][]const u8{bad};
        const z = try runCapture(allocator, build_options.zseq_path, &args);
        defer allocator.free(z.stdout);
        defer allocator.free(z.stderr);
        const g = try runCapture(allocator, gnu, &args);
        defer allocator.free(g.stdout);
        defer allocator.free(g.stderr);

        // Anchor to GNU's contract: it must also reject.
        try std.testing.expectEqual(@as(u8, 1), g.exit_code);
        try std.testing.expectEqual(@as(usize, 0), g.stdout.len);
        // zseq must match that contract.
        try std.testing.expectEqual(g.exit_code, z.exit_code);
        try std.testing.expectEqual(@as(usize, 0), z.stdout.len);
    }
}

test "invalid float operand rejected (exit 1) like GNU" {
    const allocator = std.testing.allocator;
    const gnu = findGnu() orelse return error.NoGnuReference;
    const args = [_][]const u8{"abc"};
    const z = try runCapture(allocator, build_options.zseq_path, &args);
    defer allocator.free(z.stdout);
    defer allocator.free(z.stderr);
    const g = try runCapture(allocator, gnu, &args);
    defer allocator.free(g.stdout);
    defer allocator.free(g.stderr);
    try std.testing.expectEqual(@as(u8, 1), g.exit_code);
    try std.testing.expectEqual(g.exit_code, z.exit_code);
    try std.testing.expectEqualStrings(g.stdout, z.stdout); // both empty
}

// ---------------------------------------------------------------------------
// MEDIUM fix: --help / --version go to STDOUT with exit 0 (were on stderr).
// GNU contract: stdout non-empty, stderr empty, exit 0.
// ---------------------------------------------------------------------------

test "MEDIUM: --help writes to stdout, exit 0 (GNU contract)" {
    const allocator = std.testing.allocator;
    const gnu = findGnu() orelse return error.NoGnuReference;

    inline for (.{ "--help", "--version" }) |flag| {
        const args = [_][]const u8{flag};
        const g = try runCapture(allocator, gnu, &args);
        defer allocator.free(g.stdout);
        defer allocator.free(g.stderr);
        // Establish the reference contract.
        try std.testing.expectEqual(@as(u8, 0), g.exit_code);
        try std.testing.expect(g.stdout.len > 0);
        try std.testing.expectEqual(@as(usize, 0), g.stderr.len);

        const z = try runCapture(allocator, build_options.zseq_path, &args);
        defer allocator.free(z.stdout);
        defer allocator.free(z.stderr);
        try std.testing.expectEqual(@as(u8, 0), z.exit_code);
        try std.testing.expect(z.stdout.len > 0); // was 0 before the fix
        try std.testing.expectEqual(@as(usize, 0), z.stderr.len);
    }
}

// ---------------------------------------------------------------------------
// LOW fix: a pathologically huge field width/precision must not panic (usize
// overflow) or hang; it is bounded. Anchor: zseq exits cleanly (0) and does not
// crash. (Exact bytes for absurd widths beyond the internal cap are not
// compared; the point is no panic / no unbounded loop.)
// ---------------------------------------------------------------------------

test "LOW: pathological format width does not overflow/panic" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "-f", "%99999999999999999999f", "1", "1" };
    const z = try runCapture(allocator, build_options.zseq_path, &args);
    defer allocator.free(z.stdout);
    defer allocator.free(z.stderr);
    try std.testing.expectEqual(@as(u8, 0), z.exit_code); // not 134 (SIGABRT)
}
