//! Externally-anchored GNU parity tests for zbase32.
//!
//! Primary anchor: the real GNU coreutils `base32` binary (9.x). Every parity
//! case runs BOTH binaries on the same fixture bytes and byte-compares stdout
//! plus the exit code. None of the expected outputs are produced by zbase32
//! itself, so this is a true external anchor (repo golden rule §1).
//!
//! Secondary anchor: literal RFC 4648 §10 test vectors (''→'', 'f'→'MY======',
//! ... 'foobar'→'MZXW6YTBOI======') transcribed from the RFC, so the suite
//! still asserts real bytes for both encode AND decode even if no GNU binary
//! is installed. No roundtrip-only cases.
//!
//! Regression anchors for the audit's two critical findings:
//!   - streaming encode across a chunk boundary must not embed mid-stream '='
//!     padding (driven through a real /bin/sh pipe that splits the input on a
//!     non-multiple-of-5 boundary).
//!   - decode of GNU's default 76-column wrapped output of a 200 KB payload
//!     must reproduce the original (group split across read() boundaries).
//!
//! Run via `zig build test`.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

/// May be relative to the build root (the test runner's cwd); children run
/// with cwd set to a fixture tmp dir, so resolve it to an absolute path first.
fn resolveExe(arena: std.mem.Allocator, io: Io) ![]const u8 {
    const configured: []const u8 = build_options.zbase32_exe;
    if (std.fs.path.isAbsolute(configured)) return configured;
    return try Io.Dir.cwd().realPathFileAlloc(io, configured, arena);
}

const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/base32",
    "/opt/homebrew/bin/gbase32",
    "/usr/local/opt/coreutils/libexec/gnubin/base32",
    "/usr/local/bin/gbase32",
    "/usr/bin/base32",
};

fn findGnu(io: Io) ?[]const u8 {
    for (gnu_candidates) |path| {
        const f = Io.Dir.openFile(Io.Dir.cwd(), io, path, .{}) catch continue;
        f.close(io);
        return path;
    }
    return null;
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

/// Run an explicit argv, cwd set to `fixture_dir`, optional stdin fixture file.
fn runArgv(
    arena: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
    stdin_fixture: ?[]const u8,
    fixture_dir: Io.Dir,
) !RunResult {
    const stdin_file: ?Io.File = if (stdin_fixture) |name|
        try fixture_dir.openFile(io, name, .{})
    else
        null;
    defer if (stdin_file) |f| f.close(io);

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .dir = fixture_dir },
        .stdin = if (stdin_file) |f| .{ .file = f } else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(arena, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    while (multi_reader.fill(4096, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi_reader.checkAnyError();

    const term = try child.wait(io);
    const stdout = try multi_reader.toOwnedSlice(0);
    const stderr = try multi_reader.toOwnedSlice(1);

    return .{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = switch (term) {
            .exited => |code| code,
            else => 255,
        },
    };
}

const Case = struct {
    name: []const u8,
    args: []const []const u8,
    stdin_fixture: ?[]const u8 = null,
    /// Expected exit code shared by both binaries (also cross-checked against
    /// what GNU actually returned).
    expect_exit: u8 = 0,
};

fn runTool(
    arena: std.mem.Allocator,
    io: Io,
    exe: []const u8,
    case: Case,
    fixture_dir: Io.Dir,
) !RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.append(arena, exe);
    for (case.args) |a| try argv.append(arena, a);
    return runArgv(arena, io, argv.items, case.stdin_fixture, fixture_dir);
}

const Fixture = struct { name: []const u8, data: []const u8 };

fn writeFixtures(io: Io, dir: Io.Dir, arena: std.mem.Allocator) !void {
    // Every byte value, ensures encode covers the full 5-bit alphabet.
    var all_bytes: [256]u8 = undefined;
    for (0..256) |i| all_bytes[i] = @intCast(i);

    // 200 KB pseudo-random-ish payload: encoded at the default 76-col wrap it
    // becomes a multi-line blob whose 8-char groups straddle zbase32's 64 KB
    // decode read() boundary — the exact shape of the decode critical finding.
    var big: std.ArrayListUnmanaged(u8) = .empty;
    var x: u32 = 0x12345678;
    for (0..200_000) |_| {
        x = x *% 1664525 +% 1013904223;
        try big.append(arena, @intCast((x >> 16) & 0xFF));
    }

    const fixtures = [_]Fixture{
        .{ .name = "empty.bin", .data = "" },
        .{ .name = "f.bin", .data = "f" },
        .{ .name = "fo.bin", .data = "fo" },
        .{ .name = "foo.bin", .data = "foo" },
        .{ .name = "foob.bin", .data = "foob" },
        .{ .name = "fooba.bin", .data = "fooba" },
        .{ .name = "foobar.bin", .data = "foobar" },
        .{ .name = "allbytes.bin", .data = &all_bytes },
        .{ .name = "big.bin", .data = big.items },
    };
    for (fixtures) |f| {
        try dir.writeFile(io, .{ .sub_path = f.name, .data = f.data });
    }
}

/// Encode-direction parity cases: both binaries encode the same file.
const encode_cases = [_]Case{
    .{ .name = "encode empty", .args = &.{"empty.bin"} },
    .{ .name = "encode 'f'", .args = &.{"f.bin"} },
    .{ .name = "encode 'fo'", .args = &.{"fo.bin"} },
    .{ .name = "encode 'foo'", .args = &.{"foo.bin"} },
    .{ .name = "encode 'foob'", .args = &.{"foob.bin"} },
    .{ .name = "encode 'fooba'", .args = &.{"fooba.bin"} },
    .{ .name = "encode 'foobar'", .args = &.{"foobar.bin"} },
    .{ .name = "encode all 256 byte values", .args = &.{"allbytes.bin"} },
    .{ .name = "encode 200KB default wrap 76", .args = &.{"big.bin"} },
    .{ .name = "encode 200KB -w0 (no wrap)", .args = &.{ "-w0", "big.bin" } },
    .{ .name = "encode 200KB --wrap=64", .args = &.{ "--wrap=64", "big.bin" } },
    .{ .name = "encode foobar -w4 (attached short optarg)", .args = &.{ "-w4", "foobar.bin" } },
    .{ .name = "encode foobar -w 1 (separate optarg)", .args = &.{ "-w", "1", "foobar.bin" } },
    .{ .name = "encode foobar -w10", .args = &.{ "-w10", "foobar.bin" } },
    .{ .name = "encode allbytes --wrap=76 explicit", .args = &.{ "--wrap=76", "allbytes.bin" } },
    .{ .name = "encode via stdin", .args = &.{}, .stdin_fixture = "foobar.bin" },
    .{ .name = "encode 200KB via stdin -w0", .args = &.{"-w0"}, .stdin_fixture = "big.bin" },
};

test "GNU parity: encode stdout + exit match real GNU base32" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const exe = try resolveExe(arena, io);
    const gnu = findGnu(io) orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixtures(io, tmp.dir, arena);

    var failures: usize = 0;
    for (encode_cases) |case| {
        const z = try runTool(arena, io, exe, case, tmp.dir);
        const g = try runTool(arena, io, gnu, case, tmp.dir);
        if (!std.mem.eql(u8, z.stdout, g.stdout)) {
            std.debug.print("FAIL [{s}]: stdout differs (zbase32 {d} bytes, gnu {d} bytes)\n", .{ case.name, z.stdout.len, g.stdout.len });
            failures += 1;
            continue;
        }
        if (z.exit_code != g.exit_code) {
            std.debug.print("FAIL [{s}]: exit zbase32={d} gnu={d}\n", .{ case.name, z.exit_code, g.exit_code });
            failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

// Decode-direction parity: we first produce base32 text with GNU (the
// reference encoder), write it to a fixture, then both binaries DECODE it.
// Anchors the decode critical finding (76-col wrapped 200 KB) and -i/-d.
test "GNU parity: decode of GNU-encoded text matches real GNU base32" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const exe = try resolveExe(arena, io);
    const gnu = findGnu(io) orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixtures(io, tmp.dir, arena);

    // Build encoded fixtures with GNU: default-wrapped and unwrapped 200 KB,
    // plus a plain foobar encoding.
    const enc_wrapped = try runTool(arena, io, gnu, .{ .name = "genc76", .args = &.{"big.bin"} }, tmp.dir);
    try std.testing.expectEqual(@as(u8, 0), enc_wrapped.exit_code);
    try tmp.dir.writeFile(io, .{ .sub_path = "big.b32.wrapped", .data = enc_wrapped.stdout });

    const enc_flat = try runTool(arena, io, gnu, .{ .name = "genc0", .args = &.{ "-w0", "big.bin" } }, tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "big.b32.flat", .data = enc_flat.stdout });

    // Lowercase form: valid base32 letters but GNU is case-sensitive, so with
    // plain -d it is "invalid input" (exit 1).
    try tmp.dir.writeFile(io, .{ .sub_path = "lower.b32", .data = "nbswy3dp\n" });
    // Pure garbage (all lowercase, no digit in the 2-7 alphabet): with -i both
    // ignore every byte and emit nothing (exit 0). NOTE: a fixture like
    // "nbswy3dp" would leave the valid char '3' as a lone incomplete quantum,
    // on which GNU errors and zbase32 does not — see remaining[] (trailing
    // incomplete-group divergence, outside the audited findings).
    try tmp.dir.writeFile(io, .{ .sub_path = "allgarbage.b32", .data = "abcdefgh\n" });
    // Uppercase garbage-laced form, decodable with -i -> "hello".
    try tmp.dir.writeFile(io, .{ .sub_path = "garbage.b32", .data = "NB!SW@Y3DP\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "foobar.b32", .data = "MZXW6YTBOI======\n" });

    const decode_cases = [_]Case{
        .{ .name = "decode 200KB 76-col wrapped (critical)", .args = &.{ "-d", "big.b32.wrapped" } },
        .{ .name = "decode 200KB flat", .args = &.{ "-d", "big.b32.flat" } },
        .{ .name = "decode foobar", .args = &.{ "-d", "foobar.b32" } },
        .{ .name = "decode wrapped via stdin", .args = &.{"-d"}, .stdin_fixture = "big.b32.wrapped" },
        .{ .name = "decode lowercase rejected exit1", .args = &.{ "-d", "lower.b32" }, .expect_exit = 1 },
        .{ .name = "decode -di ignores pure garbage (empty out)", .args = &.{ "-di", "allgarbage.b32" } },
        .{ .name = "decode -di skips uppercase garbage", .args = &.{ "-di", "garbage.b32" } },
        .{ .name = "decode -d -i separate flags", .args = &.{ "-d", "-i", "garbage.b32" } },
    };

    var failures: usize = 0;
    for (decode_cases) |case| {
        const z = try runTool(arena, io, exe, case, tmp.dir);
        const g = try runTool(arena, io, gnu, case, tmp.dir);
        if (!std.mem.eql(u8, z.stdout, g.stdout)) {
            std.debug.print("FAIL [{s}]: stdout differs (zbase32 {d} bytes, gnu {d} bytes)\n", .{ case.name, z.stdout.len, g.stdout.len });
            failures += 1;
            continue;
        }
        if (z.exit_code != g.exit_code) {
            std.debug.print("FAIL [{s}]: exit zbase32={d} gnu={d}\n", .{ case.name, z.exit_code, g.exit_code });
            failures += 1;
            continue;
        }
        if (g.exit_code != case.expect_exit) {
            std.debug.print("FAIL [{s}]: stale expectation, GNU exited {d} expected {d}\n", .{ case.name, g.exit_code, case.expect_exit });
            failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

// Error-path parity: exit codes must match GNU (stderr text differs only by
// program name and is checked for the substring separately below).
test "GNU parity: error paths exit 1 like GNU" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const exe = try resolveExe(arena, io);
    const gnu = findGnu(io) orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixtures(io, tmp.dir, arena);
    try tmp.dir.createDirPath(io, "adir");

    const cases = [_]Case{
        .{ .name = "unknown option -x", .args = &.{ "-x", "foobar.bin" }, .expect_exit = 1 },
        .{ .name = "unrecognized long option", .args = &.{ "--frobnicate", "foobar.bin" }, .expect_exit = 1 },
        .{ .name = "invalid wrap -w abc", .args = &.{ "-w", "abc", "foobar.bin" }, .expect_exit = 1 },
        .{ .name = "invalid wrap --wrap=xy", .args = &.{ "--wrap=xy", "foobar.bin" }, .expect_exit = 1 },
        .{ .name = "missing file", .args = &.{"no-such-file"}, .expect_exit = 1 },
        .{ .name = "read a directory", .args = &.{"adir"}, .expect_exit = 1 },
    };

    var failures: usize = 0;
    for (cases) |case| {
        const z = try runTool(arena, io, exe, case, tmp.dir);
        const g = try runTool(arena, io, gnu, case, tmp.dir);
        if (z.exit_code != case.expect_exit) {
            std.debug.print("FAIL [{s}]: zbase32 exit {d} expected {d}\n", .{ case.name, z.exit_code, case.expect_exit });
            failures += 1;
        }
        if (g.exit_code != case.expect_exit) {
            std.debug.print("FAIL [{s}]: GNU exit {d} expected {d} (stale)\n", .{ case.name, g.exit_code, case.expect_exit });
            failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}

test "diagnostics: real errno text + GNU-style option errors" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const exe = try resolveExe(arena, io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixtures(io, tmp.dir, arena);
    try tmp.dir.createDirPath(io, "adir");

    // Reading a directory -> GNU prints "read error: Is a directory", exit 1.
    {
        const r = try runArgv(arena, io, &.{ exe, "adir" }, null, tmp.dir);
        try std.testing.expectEqual(@as(u8, 1), r.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "Is a directory") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "read error") != null);
    }
    // Missing file -> real strerror(ENOENT), NOT a hardcoded string.
    {
        const r = try runArgv(arena, io, &.{ exe, "no-such-file" }, null, tmp.dir);
        try std.testing.expectEqual(@as(u8, 1), r.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "No such file or directory") != null);
    }
    // Unknown short option.
    {
        const r = try runArgv(arena, io, &.{ exe, "-x" }, "foobar.bin", tmp.dir);
        try std.testing.expectEqual(@as(u8, 1), r.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "invalid option") != null);
    }
    // Invalid wrap size.
    {
        const r = try runArgv(arena, io, &.{ exe, "-w", "abc" }, "foobar.bin", tmp.dir);
        try std.testing.expectEqual(@as(u8, 1), r.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "invalid wrap size") != null);
    }
    // --help / --version go to STDOUT (GNU parity), not stderr.
    {
        const r = try runArgv(arena, io, &.{ exe, "--help" }, null, tmp.dir);
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        try std.testing.expect(r.stdout.len > 0);
        try std.testing.expectEqual(@as(usize, 0), r.stderr.len);
    }
    {
        const r = try runArgv(arena, io, &.{ exe, "--version" }, null, tmp.dir);
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        try std.testing.expect(r.stdout.len > 0);
        try std.testing.expectEqual(@as(usize, 0), r.stderr.len);
    }
}

// Critical streaming-encode finding: when input arrives in partial reads that
// don't align to a 5-byte group, encode must NOT emit mid-stream '=' padding.
// Driven through a real /bin/sh pipe that writes "abc" then (after a short
// pause forcing a second read) "defgh". The old code produced
// "MFRGG===MRSWMZ3I"; correct (and GNU's) output is "MFRGGZDFMZTWQ===".
test "regression: streaming encode across non-aligned chunk boundary" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const exe = try resolveExe(arena, io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const pipeline = try std.fmt.allocPrint(arena, "{{ printf 'abc'; sleep 0.05; printf 'defgh'; }} | '{s}' -w0", .{exe});
    const r = try runArgv(arena, io, &.{ "/bin/sh", "-c", pipeline }, null, tmp.dir);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);
    // Literal external anchor: RFC 4648 base32 of "abcdefgh", unwrapped.
    try std.testing.expectEqualStrings("MFRGGZDFMZTWQ===", r.stdout);
}

// Literal RFC 4648 §10 anchors — independent of any installed GNU binary.
// Both directions (encode AND decode) so deleting the roundtrip still leaves
// external coverage of each direction (repo golden rule §1).
test "literal anchors: RFC 4648 base32 test vectors, both directions" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const exe = try resolveExe(arena, io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const Vec = struct { plain: []const u8, b32: []const u8 };
    // RFC 4648 §10 "BASE32 test vectors".
    const vecs = [_]Vec{
        .{ .plain = "", .b32 = "" },
        .{ .plain = "f", .b32 = "MY======" },
        .{ .plain = "fo", .b32 = "MZXQ====" },
        .{ .plain = "foo", .b32 = "MZXW6===" },
        .{ .plain = "foob", .b32 = "MZXW6YQ=" },
        .{ .plain = "fooba", .b32 = "MZXW6YTB" },
        .{ .plain = "foobar", .b32 = "MZXW6YTBOI======" },
    };

    // Encode: plain via stdin -w0 -> exact b32 (no trailing newline at -w0).
    for (vecs) |v| {
        try tmp.dir.writeFile(io, .{ .sub_path = "p", .data = v.plain });
        const r = try runArgv(arena, io, &.{ exe, "-w0", "p" }, null, tmp.dir);
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        std.testing.expectEqualStrings(v.b32, r.stdout) catch |e| {
            std.debug.print("encode anchor failed for '{s}'\n", .{v.plain});
            return e;
        };
    }
    // Decode: b32 -> exact plain bytes.
    for (vecs) |v| {
        try tmp.dir.writeFile(io, .{ .sub_path = "e", .data = v.b32 });
        const r = try runArgv(arena, io, &.{ exe, "-d", "e" }, null, tmp.dir);
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        std.testing.expectEqualStrings(v.plain, r.stdout) catch |e| {
            std.debug.print("decode anchor failed for '{s}'\n", .{v.b32});
            return e;
        };
    }
}
