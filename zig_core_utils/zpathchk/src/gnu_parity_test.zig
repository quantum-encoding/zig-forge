// Externally-anchored parity tests for zpathchk.
//
// PRIMARY ANCHOR: the real GNU coreutils `pathchk` binary (gpathchk 9.10),
// installed via Homebrew at /opt/homebrew/bin/gpathchk. Each case runs BOTH
// zpathchk and the genuine GNU binary under an identical environment
// (LC_ALL=C, same cwd) and compares the observable contract: the process exit
// code, and — for the cases whose diagnostic text is program-independent — the
// stderr bytes with the program name normalized away.
//
// This is a true external anchor: the expected outputs are produced by a
// binary this repo did not write. There are NO roundtrip tests here.
//
// SECONDARY ANCHOR: for a subset of cases we ALSO assert the exact GNU stderr
// bytes literally in-source (captured from `LC_ALL=C gpathchk ...`), so the
// suite still asserts real GNU behavior even on a machine where the GNU binary
// is absent. Those literals are cited with the command that produced them.

const std = @import("std");
const testing = std.testing;

const GNU_CANDIDATES = [_][]const u8{
    "/opt/homebrew/bin/gpathchk",
    "/opt/homebrew/opt/coreutils/libexec/gnubin/pathchk",
    "/usr/bin/pathchk",
};

extern "c" fn access(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

fn fileExists(path: []const u8) bool {
    if (path.len >= 4096) return false;
    var buf: [4096]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const p: [*:0]const u8 = @ptrCast(&buf);
    return access(p, 0) == 0; // F_OK
}

fn zpathchkBin() []const u8 {
    if (getenv("ZPATHCHK_BIN")) |v| return std.mem.span(v);
    return "zig-out/bin/zpathchk";
}

fn gnuBin() ?[]const u8 {
    for (GNU_CANDIDATES) |c| {
        if (fileExists(c)) return c;
    }
    return null;
}

const RunResult = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: RunResult, a: std.mem.Allocator) void {
        a.free(self.stdout);
        a.free(self.stderr);
    }
};

fn run(a: std.mem.Allocator, bin: []const u8, args: []const []const u8) !RunResult {
    var argv = std.ArrayListUnmanaged([]const u8).empty;
    defer argv.deinit(a);
    try argv.append(a, bin);
    for (args) |arg| try argv.append(a, arg);

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("LC_ALL", "C");
    try env.put("PATH", "/usr/bin:/bin");

    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const res = try std.process.run(a, io, .{
        .argv = argv.items,
        .environ_map = &env,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });

    const code: u8 = switch (res.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .stdout = res.stdout, .stderr = res.stderr };
}

// Replace occurrences of the program's own name (with and without a leading
// path) with a fixed token so diagnostics can be compared across the two
// differently-named binaries.
fn normalize(a: std.mem.Allocator, text: []const u8, bin: []const u8) ![]u8 {
    const base = std.fs.path.basename(bin);
    // First strip the full invocation path, then the basename.
    const s1 = try std.mem.replaceOwned(u8, a, text, bin, "PROG");
    defer a.free(s1);
    return std.mem.replaceOwned(u8, a, s1, base, "PROG");
}

const Case = struct {
    name: []const u8,
    args: []const []const u8,
    compare_stderr: bool, // false => program-specific text (version/help/quotearg); compare exit only
};

const CASES = [_]Case{
    // --- exit-code-only cases (program-identity or locale-quoting differs) ---
    .{ .name = "version", .args = &.{"--version"}, .compare_stderr = false },
    .{ .name = "help", .args = &.{"--help"}, .compare_stderr = false },
    // GNU quotes a non-ASCII filename with shell-escape ($'..'); zpathchk prints
    // it raw. The offending-char rendering matches; only the filename quoting
    // differs. Functional contract (exit 1) is asserted.
    .{ .name = "nonascii-name", .args = &.{ "-p", "café" }, .compare_stderr = false },

    // --- full stderr + exit-code parity cases ---
    .{ .name = "missing-operand", .args = &.{}, .compare_stderr = true },
    .{ .name = "invalid-option", .args = &.{ "-z", "foo" }, .compare_stderr = true },
    .{ .name = "unknown-long-option", .args = &.{ "--frobnicate", "x" }, .compare_stderr = true },
    .{ .name = "p-nonportable-at", .args = &.{ "-p", "foo@bar" }, .compare_stderr = true },
    .{ .name = "p-component-15", .args = &.{ "-p", "aaaaaaaaaaaaaaa" }, .compare_stderr = true }, // 15 chars > 14
    .{ .name = "p-component-14-ok", .args = &.{ "-p", "aaaaaaaaaaaaaa" }, .compare_stderr = true }, // 14 chars ok
    .{ .name = "p-total-256", .args = &.{ "-p", "a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/" }, .compare_stderr = true },
    .{ .name = "default-256-comp", .args = &.{"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}, .compare_stderr = true },
    .{ .name = "default-255-ok", .args = &.{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}, .compare_stderr = true },
    .{ .name = "default-empty", .args = &.{""}, .compare_stderr = true },
    .{ .name = "P-empty", .args = &.{ "-P", "" }, .compare_stderr = true },
    .{ .name = "P-leading-dash", .args = &.{ "-P", "--", "-foo" }, .compare_stderr = true },
    .{ .name = "ok-simple-path", .args = &.{"foo/bar/baz"}, .compare_stderr = true },
    .{ .name = "dash-is-operand", .args = &.{ "--", "-" }, .compare_stderr = true },
    .{ .name = "multi-operand-one-bad", .args = &.{ "-p", "ok", "also_ok", "bad@name" }, .compare_stderr = true },
};

test "zpathchk matches GNU pathchk across representative cases" {
    const a = testing.allocator;
    const zbin = zpathchkBin();

    // Confirm our binary exists (built by `zig build`).
    if (!fileExists(zbin)) {
        std.debug.print("zpathchk binary not found at '{s}'\n", .{zbin});
        return error.BinaryMissing;
    }

    const gbin = gnuBin() orelse {
        std.debug.print("SKIP live-diff: no GNU pathchk found; literal-anchor tests still run.\n", .{});
        return error.SkipZigTest;
    };

    var failures: usize = 0;
    for (CASES) |c| {
        const zr = try run(a, zbin, c.args);
        defer zr.deinit(a);
        const gr = try run(a, gbin, c.args);
        defer gr.deinit(a);

        if (zr.code != gr.code) {
            failures += 1;
            std.debug.print("[{s}] EXIT MISMATCH: zpathchk={d} gpathchk={d}\n", .{ c.name, zr.code, gr.code });
        }

        if (c.compare_stderr) {
            const zn = try normalize(a, zr.stderr, zbin);
            defer a.free(zn);
            const gn = try normalize(a, gr.stderr, gbin);
            defer a.free(gn);
            if (!std.mem.eql(u8, zn, gn)) {
                failures += 1;
                std.debug.print("[{s}] STDERR MISMATCH:\n  z: {s}\n  g: {s}\n", .{ c.name, zn, gn });
            }
        }
    }

    try testing.expectEqual(@as(usize, 0), failures);
}

// --------------------------------------------------------------------------
// SECONDARY ANCHOR: exact GNU-produced bytes, hard-coded. These run even with
// no GNU binary present. Program name is normalized to PROG.
// Captured on GNU coreutils 9.10 under LC_ALL=C.
// --------------------------------------------------------------------------

fn zStderrNormalized(a: std.mem.Allocator, args: []const []const u8) !RunResult {
    const zbin = zpathchkBin();
    const r = try run(a, zbin, args);
    const norm = try normalize(a, r.stderr, zbin);
    const out = try normalize(a, r.stdout, zbin);
    a.free(r.stderr);
    a.free(r.stdout);
    return .{ .code = r.code, .stdout = out, .stderr = norm };
}

test "literal GNU anchor: missing operand" {
    const a = testing.allocator;
    const r = try zStderrNormalized(a, &.{});
    defer r.deinit(a);
    // $ LC_ALL=C gpathchk
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings(
        "PROG: missing operand\nTry 'PROG --help' for more information.\n",
        r.stderr,
    );
}

test "literal GNU anchor: invalid option" {
    const a = testing.allocator;
    const r = try zStderrNormalized(a, &.{ "-z", "foo" });
    defer r.deinit(a);
    // $ LC_ALL=C gpathchk -z foo
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings(
        "PROG: invalid option -- 'z'\nTry 'PROG --help' for more information.\n",
        r.stderr,
    );
}

test "literal GNU anchor: -p non-portable character" {
    const a = testing.allocator;
    const r = try zStderrNormalized(a, &.{ "-p", "foo@bar" });
    defer r.deinit(a);
    // $ LC_ALL=C gpathchk -p foo@bar
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings(
        "PROG: non-portable character '@' in file name 'foo@bar'\n",
        r.stderr,
    );
}

test "literal GNU anchor: -p component exceeds 14" {
    const a = testing.allocator;
    const r = try zStderrNormalized(a, &.{ "-p", "aaaaaaaaaaaaaaa" }); // 15 chars
    defer r.deinit(a);
    // $ LC_ALL=C gpathchk -p aaaaaaaaaaaaaaa
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings(
        "PROG: limit 14 exceeded by length 15 of file name component 'aaaaaaaaaaaaaaa'\n",
        r.stderr,
    );
}

test "literal GNU anchor: -p total path exceeds 255" {
    const a = testing.allocator;
    const path = "a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/";
    const r = try zStderrNormalized(a, &.{ "-p", path });
    defer r.deinit(a);
    // $ LC_ALL=C gpathchk -p a/a/.../a/  (length 256)
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings(
        "PROG: limit 255 exceeded by length 256 of file name '" ++ path ++ "'\n",
        r.stderr,
    );
}

test "literal GNU anchor: default mode empty operand" {
    const a = testing.allocator;
    const r = try zStderrNormalized(a, &.{""});
    defer r.deinit(a);
    // $ LC_ALL=C gpathchk ''
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings(
        "PROG: '': No such file or directory\n",
        r.stderr,
    );
}

test "literal GNU anchor: -P empty operand" {
    const a = testing.allocator;
    const r = try zStderrNormalized(a, &.{ "-P", "" });
    defer r.deinit(a);
    // $ LC_ALL=C gpathchk -P ''
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings("PROG: empty file name\n", r.stderr);
}

test "literal GNU anchor: -P leading dash in component" {
    const a = testing.allocator;
    const r = try zStderrNormalized(a, &.{ "-P", "--", "-foo" });
    defer r.deinit(a);
    // $ LC_ALL=C gpathchk -P -- -foo
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expectEqualStrings(
        "PROG: leading '-' in a component of file name '-foo'\n",
        r.stderr,
    );
}

test "regression: --version exits 0 (was misparsed as invalid option)" {
    const a = testing.allocator;
    const r = try zStderrNormalized(a, &.{"--version"});
    defer r.deinit(a);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(r.stdout.len > 0);
    try testing.expectEqualStrings("", r.stderr);
}

// Regression for the HIGH finding: operands past index 256 were silently
// dropped by a fixed 256-slot buffer, so an invalid name at position 257+
// exited 0. Build a long operand list where ONLY the last (position 300+) is
// invalid, and require exit 1.
test "regression: invalid operand past position 256 is still checked" {
    const a = testing.allocator;

    var args = std.ArrayListUnmanaged([]const u8).empty;
    defer args.deinit(a);
    try args.append(a, "-p");
    var i: usize = 0;
    while (i < 300) : (i += 1) try args.append(a, "ok"); // 300 valid names
    try args.append(a, "bad@name"); // invalid, at position ~301

    const zbin = zpathchkBin();
    const r = try run(a, zbin, args.items);
    defer r.deinit(a);
    try testing.expectEqual(@as(u8, 1), r.code);

    // And confirm GNU agrees when available.
    if (gnuBin()) |gbin| {
        const g = try run(a, gbin, args.items);
        defer g.deinit(a);
        try testing.expectEqual(g.code, r.code);
    }
}
