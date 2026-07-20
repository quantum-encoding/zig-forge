//! Externally-anchored GNU parity tests for `zod` (a GNU `od` clone).
//!
//! Primary anchor: the real GNU coreutils `od` binary (9.x). Each differential
//! case runs BOTH binaries on the same fixture bytes and byte-compares stdout
//! plus the exit code. None of the expected outputs are produced by zod itself.
//!
//! Secondary anchor: literal-expected cases whose bytes were produced by the
//! real GNU `od (GNU coreutils) 9.10` under LC_ALL=C and transcribed verbatim,
//! so the suite still asserts real GNU bytes even with no GNU binary installed.
//! These pin the trailing partial-group fixes (-t o4/x4/u4 and the final odd
//! byte for -t u2) that the audit flagged as silently dropped.
//!
//! Run via `zig build test`.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

/// build_options.zod_exe may be relative to the build root (the test runner's
/// cwd); children run with cwd set to a fixture dir, so resolve to absolute.
fn resolveZodExe(arena: std.mem.Allocator, io: Io) ![]const u8 {
    const configured: []const u8 = build_options.zod_exe;
    if (std.fs.path.isAbsolute(configured)) return configured;
    return try Io.Dir.cwd().realPathFileAlloc(io, configured, arena);
}

/// Locations where a GNU coreutils `od` may live. macOS /usr/bin/od is BSD od
/// (different output) and is deliberately excluded; on Linux /usr/bin/od is GNU.
const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/od",
    "/opt/homebrew/bin/god",
    "/usr/local/opt/coreutils/libexec/gnubin/od",
    "/usr/local/bin/god",
};

fn findGnuOd(io: Io) ?[]const u8 {
    for (gnu_candidates) |path| {
        const f = Io.Dir.openFile(Io.Dir.cwd(), io, path, .{}) catch continue;
        f.close(io);
        return path;
    }
    if (@import("builtin").os.tag == .linux) {
        const f = Io.Dir.openFile(Io.Dir.cwd(), io, "/usr/bin/od", .{}) catch return null;
        f.close(io);
        return "/usr/bin/od";
    }
    return null;
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

fn runTool(
    arena: std.mem.Allocator,
    io: Io,
    exe: []const u8,
    args: []const []const u8,
    fixture_dir: Io.Dir,
) !RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.append(arena, exe);
    for (args) |a| try argv.append(arena, a);

    // GNU od's -t c / -t a rendering of high bytes is locale-dependent; force
    // the C locale so the reference matches zod's byte-oriented output. zod is
    // locale-independent, so this only constrains GNU. (The Io std snapshots
    // env at Init, so we must set it on the child explicitly, not via setenv.)
    var envmap = std.process.Environ.Map.init(arena);
    try envmap.put("LC_ALL", "C");
    try envmap.put("LANG", "C");

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .dir = fixture_dir },
        .environ_map = &envmap,
        .stdin = .ignore,
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

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const T19 = "ABCDEFGHIJKLMNOPQRS"; // 19 bytes -> trailing 3-byte partial group

fn floatsFixture() [13 * 4]u8 {
    const floats = [_]f32{
        0.0,        1.0,          3.14159,      781.0352, 204057.08,
        5.32913e7,  1.3912061e10, 7.651876e-39, 0.001,    12345.678,
        1e7,        9999999.0,    1e8,
    };
    var bytes: [floats.len * 4]u8 = undefined;
    for (floats, 0..) |v, i| std.mem.writeInt(u32, bytes[i * 4 ..][0..4], @bitCast(v), .little);
    return bytes;
}

const Fixture = struct { name: []const u8, data: []const u8 };

fn writeFixtures(io: Io, dir: Io.Dir, arena: std.mem.Allocator) !void {
    var all256: [256]u8 = undefined;
    for (&all256, 0..) |*b, i| b.* = @intCast(i);
    // Deterministic pseudo-pattern (no RNG -> reproducible failures).
    var patt: [200]u8 = undefined;
    for (&patt, 0..) |*b, i| b.* = @intCast((i *% 37 +% 11) & 0xff);
    const floats = floatsFixture();

    const fixtures = [_]Fixture{
        .{ .name = "t19.bin", .data = T19 },
        .{ .name = "hello.bin", .data = "Hello, World!" },
        .{ .name = "all256.bin", .data = &all256 },
        .{ .name = "zeros.bin", .data = &([_]u8{0} ** 64) }, // exercises '*'
        .{ .name = "patt.bin", .data = &patt },
        .{ .name = "empty.bin", .data = "" },
        .{ .name = "one.bin", .data = "A" },
        .{ .name = "floats.bin", .data = &floats },
    };
    for (fixtures) |f| try dir.writeFile(io, .{ .sub_path = f.name, .data = f.data });
    _ = arena;
}

// ---------------------------------------------------------------------------
// Differential anchor vs the real GNU od.
// ---------------------------------------------------------------------------

const diff_inputs = [_][]const u8{
    "t19.bin", "hello.bin", "all256.bin", "zeros.bin", "patt.bin", "empty.bin", "one.bin",
};
const diff_formats = [_][]const u8{
    "o1", "o2", "o4", "x1", "x2", "x4",
    "d1", "d2", "d4", "d8", "u1", "u2", "u4", "c", "a",
};
const diff_radixes = [_][]const u8{ "o", "x", "d", "n" };
const diff_opt_sets = [_][]const []const u8{
    &.{"-w8"},        &.{"-w32"},
    &.{ "-j", "3" },  &.{ "-N", "10" },
    &.{"-v"},         &.{ "-A", "n", "-t", "x1" },
    // Glued short-option forms the audit said were dropped.
    &.{"-tx1"},       &.{"-Ax"},         &.{"-N8"},
};

test "GNU parity: stdout bytes and exit codes match the real GNU od" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zod_exe = try resolveZodExe(arena, io);
    const gnu = findGnuOd(io) orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixtures(io, tmp.dir, arena);

    var failures: usize = 0;
    const check = struct {
        fn run(
            a: std.mem.Allocator,
            ioo: Io,
            ze: []const u8,
            ge: []const u8,
            dir: Io.Dir,
            args: []const []const u8,
            label: []const u8,
            fails: *usize,
        ) !void {
            const z = try runTool(a, ioo, ze, args, dir);
            const g = try runTool(a, ioo, ge, args, dir);
            if (!std.mem.eql(u8, z.stdout, g.stdout)) {
                std.debug.print("FAIL [{s}]: stdout differs (zod {d}B, gnu {d}B)\n  zod: {s}\n  gnu: {s}\n", .{
                    label, z.stdout.len, g.stdout.len, z.stdout, g.stdout,
                });
                fails.* += 1;
            } else if (z.exit_code != g.exit_code) {
                std.debug.print("FAIL [{s}]: exit zod={d} gnu={d}\n", .{ label, z.exit_code, g.exit_code });
                fails.* += 1;
            }
        }
    };

    for (diff_inputs) |input| {
        for (diff_formats) |fmt| {
            try check.run(arena, io, zod_exe, gnu, tmp.dir, &.{ "-t", fmt, input }, fmt, &failures);
        }
        for (diff_radixes) |radix| {
            try check.run(arena, io, zod_exe, gnu, tmp.dir, &.{ "-A", radix, input }, input, &failures);
        }
        for (diff_opt_sets) |opts| {
            var argv: std.ArrayListUnmanaged([]const u8) = .empty;
            for (opts) |o| try argv.append(arena, o);
            try argv.append(arena, input);
            try check.run(arena, io, zod_exe, gnu, tmp.dir, argv.items, opts[0], &failures);
        }
    }
    // Structured float32 values (shortest-repr fragile on random bytes, so use
    // known values) — exercises the -t f4 exponent/notation boundary fix.
    try check.run(arena, io, zod_exe, gnu, tmp.dir, &.{ "-t", "f4", "floats.bin" }, "f4", &failures);

    try std.testing.expectEqual(@as(usize, 0), failures);
}

// ---------------------------------------------------------------------------
// Literal anchors — bytes from real `od (GNU coreutils) 9.10`, LC_ALL=C.
// Independent of an installed GNU binary. Input for o4/x4/u4/u2 is the 19-byte
// "ABCDEFGHIJKLMNOPQRS" so the final line is a 3-byte partial group.
// ---------------------------------------------------------------------------

test "literal anchors: documented GNU od output bytes (partial-group fixes)" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zod_exe = try resolveZodExe(arena, io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "t19.bin", .data = T19 });
    try tmp.dir.writeFile(io, .{ .sub_path = "hello.bin", .data = "Hello, World!" });

    const LiteralCase = struct {
        name: []const u8,
        args: []const []const u8,
        expected: []const u8,
    };
    const cases = [_]LiteralCase{
        // Trailing 3-byte group "QRS" -> zero-padded final word 00024651121.
        // Pre-fix zod dropped this line entirely (audit high-severity finding).
        .{
            .name = "-t o4 trailing partial group",
            .args = &.{ "-t", "o4", "t19.bin" },
            .expected = "0000000 10420641101 11021643105 11422645111 12023647115\n" ++
                "0000020 00024651121\n0000023\n",
        },
        .{
            .name = "-t x4 trailing partial group",
            .args = &.{ "-t", "x4", "t19.bin" },
            .expected = "0000000 44434241 48474645 4c4b4a49 504f4e4d\n" ++
                "0000020 00535251\n0000023\n",
        },
        .{
            .name = "-t u4 trailing partial group",
            .args = &.{ "-t", "u4", "t19.bin" },
            .expected = "0000000 1145258561 1212630597 1280002633 1347374669\n" ++
                "0000020    5460561\n0000023\n",
        },
        // Final odd byte 'S' (0x53=83), zero-padded to u16.
        .{
            .name = "-t u2 final odd byte",
            .args = &.{ "-t", "u2", "t19.bin" },
            .expected = "0000000 16961 17475 17989 18503 19017 19531 20045 20559\n" ++
                "0000020 21073    83\n0000023\n",
        },
        // Plain hex dump with hex address radix.
        .{
            .name = "-A x -t x1 hex dump",
            .args = &.{ "-A", "x", "-t", "x1", "hello.bin" },
            .expected = "000000 48 65 6c 6c 6f 2c 20 57 6f 72 6c 64 21\n00000d\n",
        },
    };

    for (cases) |case| {
        const r = try runTool(arena, io, zod_exe, case.args, tmp.dir);
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        std.testing.expectEqualStrings(case.expected, r.stdout) catch |err| {
            std.debug.print("literal anchor failed: {s}\n", .{case.name});
            return err;
        };
    }
}

// ---------------------------------------------------------------------------
// CLI-contract anchors: crashes-turned-errors and GNU exit-status parity.
// ---------------------------------------------------------------------------

test "malformed numeric args are rejected (exit 1), not a panic" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zod_exe = try resolveZodExe(arena, io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "t19.bin", .data = T19 });

    // Pre-fix: integer-overflow panic (exit 134).
    {
        const r = try runTool(arena, io, zod_exe, &.{ "-N", "99999999999999999999999", "t19.bin" }, tmp.dir);
        try std.testing.expectEqual(@as(u8, 1), r.exit_code);
    }
    // Pre-fix: null-unwrap panic on numeric-suffix with non-numeric prefix.
    {
        const r = try runTool(arena, io, zod_exe, &.{ "-N", "5xk", "t19.bin" }, tmp.dir);
        try std.testing.expectEqual(@as(u8, 1), r.exit_code);
    }
}

test "unknown option is rejected with exit 1 and empty stdout (GNU parity)" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zod_exe = try resolveZodExe(arena, io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "t19.bin", .data = T19 });

    const r = try runTool(arena, io, zod_exe, &.{ "-Z", "t19.bin" }, tmp.dir);
    try std.testing.expectEqual(@as(u8, 1), r.exit_code);
    try std.testing.expectEqual(@as(usize, 0), r.stdout.len);
}

test "file open error yields exit 1 (GNU parity)" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zod_exe = try resolveZodExe(arena, io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const r = try runTool(arena, io, zod_exe, &.{"no_such_file_zzz"}, tmp.dir);
    try std.testing.expectEqual(@as(u8, 1), r.exit_code);
}

test "--help and --version go to stdout with exit 0 (GNU parity)" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const zod_exe = try resolveZodExe(arena, io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const r = try runTool(arena, io, zod_exe, &.{"--help"}, tmp.dir);
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, r.stdout, "Usage:") != null);
    }
    {
        const r = try runTool(arena, io, zod_exe, &.{"--version"}, tmp.dir);
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        try std.testing.expect(std.mem.startsWith(u8, r.stdout, "zod "));
    }
}
