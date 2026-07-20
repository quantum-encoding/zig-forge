//! GNU-parity differential tests for zbase64.
//!
//! External anchor (see zig-forge/CLAUDE.md "golden rule" §1): these tests do
//! NOT check zbase64 against itself. Two anchor classes:
//!
//!   1. LITERAL SPEC VECTORS — RFC 4648 §10 test vectors (encode AND decode,
//!      both directions), plus the audit's padding-bug regression vectors and
//!      malformed-input rejection cases. Inputs AND expected outputs come from
//!      the RFC / documented GNU behavior, not from this library, so an anchor
//!      still bites when no GNU binary is installed.
//!
//!   2. GNU DIFF — spawn BOTH the built zbase64 and the real GNU `base64`
//!      (coreutils 9.x) on the same inputs/flags and compare stdout byte-for-byte
//!      plus exit status. Skipped (surfaced by `zig build test`) if no GNU
//!      binary is found.
//!
//! Inputs are written to a temp file passed as the FILE operand; both binaries
//! read it through their normal chunked read() loop, so read-boundary handling
//! (the split-group and mid-stream-padding bugs) is exercised exactly as a pipe
//! would. The zbase64 binary path is injected by build.zig via `build_options`.

const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");

const zbase64_exe: []const u8 = build_options.zbase64_exe;

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/base64",
    "/opt/homebrew/bin/gbase64",
    "/usr/local/opt/coreutils/libexec/gnubin/base64",
    "/usr/local/bin/gbase64",
    "/usr/bin/gbase64",
};

// libc allocator for all process plumbing (avoids leak-checker false positives
// from std's spawn internals; these tests assert parity, not allocation).
const gpa = std.heap.c_allocator;

// A real threaded Io backed by libc's allocator and the *actual* process
// environment (the std single-threaded instance can't spawn and has an empty
// environ, which would break child PATH resolution).
var g_threaded: std.Io.Threaded = undefined;
var g_threaded_ready = false;

fn io() std.Io {
    if (!g_threaded_ready) {
        const c_env = std.c.environ;
        var n: usize = 0;
        while (c_env[n] != null) : (n += 1) {}
        const block: std.process.Environ.Block = .{ .slice = @ptrCast(c_env[0..n :null]) };
        g_threaded = std.Io.Threaded.init(std.heap.c_allocator, .{ .environ = .{ .block = block } });
        g_threaded_ready = true;
    }
    return g_threaded.io();
}

var g_zbase64_abs: ?[]const u8 = null;

fn zbase64Abs() []const u8 {
    if (g_zbase64_abs) |p| return p;
    if (std.fs.path.isAbsolute(zbase64_exe)) {
        g_zbase64_abs = zbase64_exe;
        return zbase64_exe;
    }
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.c.getcwd(&cwd_buf, cwd_buf.len) == null) @panic("getcwd failed");
    const cwd = std.mem.sliceTo(&cwd_buf, 0);
    g_zbase64_abs = std.fs.path.join(gpa, &.{ cwd, zbase64_exe }) catch @panic("OOM");
    return g_zbase64_abs.?;
}

const Run = struct {
    stdout: []u8,
    stderr: []u8,
    exit: u8,

    fn free(self: Run) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

fn termExit(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |c| c,
        else => 255,
    };
}

fn runArgs(argv: []const []const u8) !Run {
    const r = try std.process.run(gpa, io(), .{ .argv = argv });
    return .{ .stdout = r.stdout, .stderr = r.stderr, .exit = termExit(r.term) };
}

/// Write exact bytes to `path` via libc (arbitrary binary, no shell escaping).
fn writeFileLibc(path: [:0]const u8, data: []const u8) !void {
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .TRUNC = true }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data.ptr + off, data.len - off);
        if (n < 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

/// Run `bin args...` with `input` supplied as the FILE operand.
fn runOnInput(bin: []const u8, args: []const []const u8, input: []const u8) !Run {
    // mktemp creates a unique file we own.
    const mk = try runArgs(&.{"mktemp"});
    defer mk.free();
    const path = try gpa.dupeZ(u8, std.mem.trimEnd(u8, mk.stdout, "\n"));
    defer {
        _ = std.c.unlink(path.ptr);
        gpa.free(path);
    }
    try writeFileLibc(path, input);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, bin);
    for (args) |a| try argv.append(gpa, a);
    try argv.append(gpa, path);
    return runArgs(argv.items);
}

fn findGnu() ?[]const u8 {
    for (gnu_candidates) |cand| {
        const r = runArgs(&.{ cand, "--version" }) catch continue;
        defer r.free();
        if (r.exit == 0 and std.mem.indexOf(u8, r.stdout, "GNU coreutils") != null)
            return cand;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Class 1: literal spec vectors (RFC 4648 §10) — external, no roundtrip
// ---------------------------------------------------------------------------

const EncVec = struct { in: []const u8, out: []const u8 };

// RFC 4648 §10 "Test Vectors" — https://datatracker.ietf.org/doc/html/rfc4648#section-10
const rfc4648 = [_]EncVec{
    .{ .in = "", .out = "" },
    .{ .in = "f", .out = "Zg==" },
    .{ .in = "fo", .out = "Zm8=" },
    .{ .in = "foo", .out = "Zm9v" },
    .{ .in = "foob", .out = "Zm9vYg==" },
    .{ .in = "fooba", .out = "Zm9vYmE=" },
    .{ .in = "foobar", .out = "Zm9vYmFy" },
};

test "encode matches RFC 4648 §10 vectors (-w0)" {
    const bin = zbase64Abs();
    for (rfc4648) |v| {
        const r = try runOnInput(bin, &.{"-w0"}, v.in);
        defer r.free();
        try testing.expectEqual(@as(u8, 0), r.exit);
        try testing.expectEqualStrings(v.out, r.stdout);
    }
}

test "decode matches RFC 4648 §10 vectors" {
    const bin = zbase64Abs();
    for (rfc4648) |v| {
        const r = try runOnInput(bin, &.{"-d"}, v.out);
        defer r.free();
        try testing.expectEqual(@as(u8, 0), r.exit);
        try testing.expectEqualStrings(v.in, r.stdout);
    }
}

// Padding-bug regression vectors from the audit. Expected outputs are the exact
// bytes GNU `base64 -d` emits (the pre-fix code emitted trailing NUL bytes).
test "decode padded groups do not emit trailing NUL bytes" {
    const bin = zbase64Abs();
    const cases = [_]EncVec{
        .{ .in = "dGVzdA==", .out = "test" }, // 4-byte payload, 2 pad
        .{ .in = "TWFuWFk=", .out = "ManXY" }, // 5-byte payload, 1 pad
        .{ .in = "d29ybGQ", .out = "world" }, // canonical 3-char tail, no pad
    };
    for (cases) |c| {
        const r = try runOnInput(bin, &.{"-d"}, c.in);
        defer r.free();
        try testing.expectEqual(@as(u8, 0), r.exit);
        try testing.expectEqualStrings(c.out, r.stdout);
    }
}

// Invalid inputs GNU rejects with exit 1.
test "decode rejects malformed input with exit 1" {
    const bin = zbase64Abs();
    const bad = [_][]const u8{
        "AAAA====", // excess padding (2nd group starts with '=')
        "AAAAA", // 1-char trailing group
        "dGVz dA==", // space is not whitespace-skipped by default
        "AA=A", // data after padding
        "A===", // '=' before position 2
    };
    for (bad) |b| {
        const r = try runOnInput(bin, &.{"-d"}, b);
        defer r.free();
        try testing.expectEqual(@as(u8, 1), r.exit);
    }
}

// Unknown option must error (GNU exits 1), not be silently ignored.
test "unknown option exits 1" {
    const bin = zbase64Abs();
    const r = try runOnInput(bin, &.{"-Z"}, "x");
    defer r.free();
    try testing.expectEqual(@as(u8, 1), r.exit);
}

// Out-of-range --wrap must not crash (GNU saturates, exit 0).
test "huge --wrap does not crash" {
    const bin = zbase64Abs();
    const r = try runOnInput(bin, &.{ "-w", "999999999999999999999999" }, "x");
    defer r.free();
    try testing.expectEqual(@as(u8, 0), r.exit);
    try testing.expectEqualStrings("eA==\n", r.stdout);
}

// ---------------------------------------------------------------------------
// Class 2: byte-for-byte diff against the real GNU base64 binary
// ---------------------------------------------------------------------------

fn expectSameAsGnu(gnu: []const u8, args: []const []const u8, input: []const u8) !void {
    const z = try runOnInput(zbase64Abs(), args, input);
    defer z.free();
    const g = try runOnInput(gnu, args, input);
    defer g.free();
    testing.expectEqualSlices(u8, g.stdout, z.stdout) catch |e| {
        std.debug.print("stdout differs for args={any} (input {d} bytes)\n", .{ args, input.len });
        return e;
    };
    try testing.expectEqual(g.exit, z.exit);
}

fn randBytes(n: usize, seed: u64) ![]u8 {
    const buf = try gpa.alloc(u8, n);
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().bytes(buf);
    return buf;
}

test "encode: byte-identical to GNU across sizes and wraps" {
    const gnu = findGnu() orelse return error.SkipZigTest;

    // Sizes span the 0/1/2 mod-3 boundaries and cross the 48000-byte read chunk.
    const sizes = [_]usize{ 0, 1, 2, 3, 4, 5, 47, 48, 76, 100, 48000, 48001, 48002, 130000 };
    const wraps = [_][]const u8{ "-w0", "-w1", "-w10", "-w76", "-w130000" };
    for (sizes) |n| {
        const data = try randBytes(n, 0x1234 +% n);
        defer gpa.free(data);
        for (wraps) |w| try expectSameAsGnu(gnu, &.{w}, data);
        try expectSameAsGnu(gnu, &.{}, data); // default wrap
    }
}

test "decode: zbase64 decodes GNU-produced base64 identically (large, wrapped)" {
    const gnu = findGnu() orelse return error.SkipZigTest;

    // GNU encodes (external producer, default wrap=76 with many newlines);
    // zbase64 must decode back to the original and match GNU's own decode.
    const data = try randBytes(200000, 0xC0FFEE);
    defer gpa.free(data);

    const enc = try runOnInput(gnu, &.{}, data);
    defer enc.free();

    try expectSameAsGnu(gnu, &.{"-d"}, enc.stdout);

    const z = try runOnInput(zbase64Abs(), &.{"-d"}, enc.stdout);
    defer z.free();
    try testing.expectEqualSlices(u8, data, z.stdout);
}

test "decode: parity on -w0 (unwrapped) GNU output" {
    const gnu = findGnu() orelse return error.SkipZigTest;
    const data = try randBytes(60000, 0xABCDEF);
    defer gpa.free(data);
    const enc = try runOnInput(gnu, &.{"-w0"}, data);
    defer enc.free();
    try expectSameAsGnu(gnu, &.{"-d"}, enc.stdout);
}

test "decode: full parity (stdout + exit) on valid edge inputs" {
    const gnu = findGnu() orelse return error.SkipZigTest;
    // Well-defined inputs: stdout AND exit must match GNU byte-for-byte.
    const valid = [_][]const u8{
        "dGVz\ndA==", // embedded newline is skipped
        "dA==\ndA==", // two padded groups in a row
        "d29ybGQ", // canonical unpadded 3-char tail
        "Zm9vYmFy", // "foobar"
        "dGVzdA==", // "test"
    };
    for (valid) |in| {
        try expectSameAsGnu(gnu, &.{"-d"}, in);
        try expectSameAsGnu(gnu, &.{"-di"}, in); // ignore-garbage variant
    }
}

test "decode: exit-code parity with GNU on malformed inputs" {
    const gnu = findGnu() orelse return error.SkipZigTest;
    // GNU rejects each of these (exit 1); zbase64 must reject too. GNU may flush
    // a few partial bytes before bailing (implementation-defined on error), so
    // only the exit status is asserted here — the valid-input test above covers
    // exact stdout.
    const bad = [_][]const u8{
        "AAAA====", // excess padding
        "AAAAA", // 1-char trailing group
        "dGVz dA==", // space not skipped by default
        "dGVz\tdA==", // tab not skipped by default
        "AA=A", // data after padding
        "A===", // '=' before position 2
    };
    for (bad) |in| {
        const z = try runOnInput(zbase64Abs(), &.{"-d"}, in);
        defer z.free();
        const g = try runOnInput(gnu, &.{"-d"}, in);
        defer g.free();
        try testing.expectEqual(g.exit, z.exit);
        try testing.expectEqual(@as(u8, 1), z.exit);
    }
}

test "encode/decode parity on all 256 byte values" {
    const gnu = findGnu() orelse return error.SkipZigTest;
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| b.* = @intCast(i);
    try expectSameAsGnu(gnu, &.{"-w0"}, &all);
    try expectSameAsGnu(gnu, &.{}, &all);
}
