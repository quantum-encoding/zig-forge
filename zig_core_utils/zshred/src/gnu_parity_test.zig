//! Externally-anchored GNU parity tests for zshred.
//!
//! shred's random passes are, by design, non-reproducible, so a naive
//! byte-for-byte diff of the shredded file against GNU is impossible. Instead
//! each anchor targets a property GNU's `shred` documents and that a broken
//! implementation violates:
//!
//!  * Primary anchor — the real GNU `shred` binary (coreutils 9.x). Cases run
//!    BOTH binaries on identical fresh fixtures and compare the *observable
//!    result*: file size (block-rounding + --exact), removal (-u), the
//!    byte-exact all-zero content of a -z/-n0 pass, exit codes, and the
//!    --version/--help stream discipline. None of these expected values are
//!    produced by zshred itself.
//!
//!  * Standalone anchors that run even without a GNU binary, each citing the
//!    documented GNU/POSIX behavior with the expected bytes literal in the
//!    test:
//!      - the "random" pass must not be a constant fill (the macOS
//!        std.os.linux.getrandom bug wrote a constant 0xAA/0x00) and two
//!        independent shreds must differ — GNU shred(1): "overwrite ... to
//!        make it harder ... using random data";
//!      - `-x -z -n0` writes exactly the file's bytes as zeros — shred(1):
//!        "-z add a final overwrite with zeros", "-x do not round file sizes
//!        up", "-n0" = no random passes;
//!      - --version / --help go to stdout with exit 0 (GNU coreutils / POSIX
//!        utility conventions);
//!      - an invalid pass count exits 1 without a panic (GNU: "invalid number
//!        of passes");
//!      - every operand is processed (no silent file cap) — GNU shreds all
//!        FILE arguments.
//!
//! Run via `zig build test`.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

/// May be relative to the build root (the test runner's cwd); children run
/// with cwd set to a fixture tmp dir, so resolve it to an absolute path first.
fn resolveZshredExe(arena: std.mem.Allocator, io: Io) ![]const u8 {
    const configured: []const u8 = build_options.zshred_exe;
    if (std.fs.path.isAbsolute(configured)) return configured;
    return try Io.Dir.cwd().realPathFileAlloc(io, configured, arena);
}

/// Locations where a GNU coreutils `shred` may live. The audit reference is
/// the homebrew coreutils gnubin path; /usr/bin/shred is GNU on Linux.
const gnu_candidates = [_][]const u8{
    "/opt/homebrew/opt/coreutils/libexec/gnubin/shred",
    "/opt/homebrew/bin/gshred",
    "/usr/local/opt/coreutils/libexec/gnubin/shred",
    "/usr/local/bin/gshred",
};

fn findGnuShred(io: Io) ?[]const u8 {
    for (gnu_candidates) |path| {
        const f = Io.Dir.openFile(Io.Dir.cwd(), io, path, .{}) catch continue;
        f.close(io);
        return path;
    }
    if (@import("builtin").os.tag == .linux) {
        const f = Io.Dir.openFile(Io.Dir.cwd(), io, "/usr/bin/shred", .{}) catch return null;
        f.close(io);
        return "/usr/bin/shred";
    }
    return null;
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

/// Spawn `exe args...` with cwd set to `dir`, capturing stdout/stderr/exit.
fn run(
    arena: std.mem.Allocator,
    io: Io,
    exe: []const u8,
    args: []const []const u8,
    dir: Io.Dir,
) !RunResult {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.append(arena, exe);
    for (args) |a| try argv.append(arena, a);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .cwd = .{ .dir = dir },
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

fn writeFixture(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = name, .data = bytes });
}

/// Read a file back, or null if it no longer exists (shredded away by -u).
fn readBack(arena: std.mem.Allocator, io: Io, dir: Io.Dir, name: []const u8) !?[]u8 {
    dir.access(io, name, .{}) catch return null;
    return try dir.readFileAlloc(io, name, arena, .unlimited);
}

fn fileSize(io: Io, dir: Io.Dir, name: []const u8) !?u64 {
    const st = dir.statFile(io, name, .{}) catch return null;
    return st.size;
}

fn fill(arena: std.mem.Allocator, byte: u8, n: usize) ![]u8 {
    const b = try arena.alloc(u8, n);
    @memset(b, byte);
    return b;
}

fn allSameByte(b: []const u8) bool {
    if (b.len == 0) return true;
    for (b) |x| if (x != b[0]) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Primary anchor: observable result matches the real GNU shred.
// ---------------------------------------------------------------------------

test "GNU parity: block-rounding / --exact / -z / -u / exit codes match real GNU shred" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zshred = try resolveZshredExe(arena, io);
    const gnu = findGnuShred(io) orelse return error.SkipZigTest;

    // Fixture byte-lengths chosen to exercise block rounding: below a block,
    // exactly one block, mid-way into a second block, exactly two blocks.
    const sizes = [_]usize{ 10, 4096, 5000, 8192 };

    var failures: usize = 0;

    // --- Default (block-rounded) random pass: resulting file SIZE must match.
    for (sizes) |n| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const data = try fill(arena, 'A', n);
        try writeFixture(io, tmp.dir, "z.bin", data);
        try writeFixture(io, tmp.dir, "g.bin", data);

        const rz = try run(arena, io, zshred, &.{ "-n1", "z.bin" }, tmp.dir);
        const rg = try run(arena, io, gnu, &.{ "-n1", "g.bin" }, tmp.dir);

        const sz = try fileSize(io, tmp.dir, "z.bin");
        const sg = try fileSize(io, tmp.dir, "g.bin");
        if (rz.exit_code != 0 or rg.exit_code != 0) {
            std.debug.print("FAIL [default n1 {d}B]: exit z={d} g={d}\n", .{ n, rz.exit_code, rg.exit_code });
            failures += 1;
        } else if (sz == null or sg == null or sz.? != sg.?) {
            std.debug.print("FAIL [default n1 {d}B]: size z={?d} gnu={?d}\n", .{ n, sz, sg });
            failures += 1;
        }
    }

    // --- --exact: no rounding, size stays == original for both.
    for (sizes) |n| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const data = try fill(arena, 'A', n);
        try writeFixture(io, tmp.dir, "z.bin", data);
        try writeFixture(io, tmp.dir, "g.bin", data);

        _ = try run(arena, io, zshred, &.{ "-x", "-n1", "z.bin" }, tmp.dir);
        _ = try run(arena, io, gnu, &.{ "-x", "-n1", "g.bin" }, tmp.dir);

        const sz = try fileSize(io, tmp.dir, "z.bin");
        const sg = try fileSize(io, tmp.dir, "g.bin");
        if (sz == null or sg == null or sz.? != sg.? or sz.? != n) {
            std.debug.print("FAIL [exact n1 {d}B]: size z={?d} gnu={?d} orig={d}\n", .{ n, sz, sg, n });
            failures += 1;
        }
    }

    // --- -x -z -n0: byte-exact all-zeros, identical bytes for both binaries.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const data = "ABCDEFGHIJKLMNOP"; // 16 bytes
        try writeFixture(io, tmp.dir, "z.bin", data);
        try writeFixture(io, tmp.dir, "g.bin", data);

        _ = try run(arena, io, zshred, &.{ "-x", "-z", "-n0", "z.bin" }, tmp.dir);
        _ = try run(arena, io, gnu, &.{ "-x", "-z", "-n0", "g.bin" }, tmp.dir);

        const bz = (try readBack(arena, io, tmp.dir, "z.bin")).?;
        const bg = (try readBack(arena, io, tmp.dir, "g.bin")).?;
        if (!std.mem.eql(u8, bz, bg)) {
            std.debug.print("FAIL [-x -z -n0]: zshred bytes != gnu bytes ({d} vs {d})\n", .{ bz.len, bg.len });
            failures += 1;
        }
    }

    // --- default -z -n0: block-rounded all-zeros; both binaries same size+bytes.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const data = try fill(arena, 'Q', 10);
        try writeFixture(io, tmp.dir, "z.bin", data);
        try writeFixture(io, tmp.dir, "g.bin", data);

        _ = try run(arena, io, zshred, &.{ "-z", "-n0", "z.bin" }, tmp.dir);
        _ = try run(arena, io, gnu, &.{ "-z", "-n0", "g.bin" }, tmp.dir);

        const bz = (try readBack(arena, io, tmp.dir, "z.bin")).?;
        const bg = (try readBack(arena, io, tmp.dir, "g.bin")).?;
        if (!std.mem.eql(u8, bz, bg)) {
            std.debug.print("FAIL [default -z -n0]: bytes differ z={d} g={d}\n", .{ bz.len, bg.len });
            failures += 1;
        }
    }

    // --- -u removes the file for both.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFixture(io, tmp.dir, "z.bin", "secret");
        try writeFixture(io, tmp.dir, "g.bin", "secret");
        _ = try run(arena, io, zshred, &.{ "-u", "z.bin" }, tmp.dir);
        _ = try run(arena, io, gnu, &.{ "-u", "g.bin" }, tmp.dir);
        if ((try readBack(arena, io, tmp.dir, "z.bin")) != null or
            (try readBack(arena, io, tmp.dir, "g.bin")) != null)
        {
            std.debug.print("FAIL [-u]: a file survived removal\n", .{});
            failures += 1;
        }
    }

    // --- invalid / overflowing pass counts: exit code parity (both = 1).
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try writeFixture(io, tmp.dir, "z.bin", "x");
        try writeFixture(io, tmp.dir, "g.bin", "x");
        const bad = [_][]const u8{ "abc", "99999999999999999999999999" };
        for (bad) |val| {
            const rz = try run(arena, io, zshred, &.{ "-n", val, "z.bin" }, tmp.dir);
            const rg = try run(arena, io, gnu, &.{ "-n", val, "g.bin" }, tmp.dir);
            if (rz.exit_code != rg.exit_code or rz.exit_code == 0) {
                std.debug.print("FAIL [-n {s}]: exit z={d} gnu={d}\n", .{ val, rz.exit_code, rg.exit_code });
                failures += 1;
            }
        }
    }

    try std.testing.expectEqual(@as(usize, 0), failures);
}

// ---------------------------------------------------------------------------
// Standalone anchors (run without a GNU binary). Expected bytes are literal
// and cite the documented GNU/POSIX behavior.
// ---------------------------------------------------------------------------

test "critical: the random pass is not a constant fill and varies between runs" {
    // Anchors the macOS getrandom bug: GNU shred(1) overwrites with random
    // data. A constant fill (0xAA in Debug / 0x00 in ReleaseFast, as the old
    // std.os.linux.getrandom-on-Darwin code produced) or a fixed stream fails
    // the security guarantee.
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zshred = try resolveZshredExe(arena, io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig = try fill(arena, 'A', 4096);
    try writeFixture(io, tmp.dir, "a.bin", orig);
    try writeFixture(io, tmp.dir, "b.bin", orig);

    const ra = try run(arena, io, zshred, &.{ "-x", "-n1", "a.bin" }, tmp.dir);
    const rb = try run(arena, io, zshred, &.{ "-x", "-n1", "b.bin" }, tmp.dir);
    try std.testing.expectEqual(@as(u8, 0), ra.exit_code);
    try std.testing.expectEqual(@as(u8, 0), rb.exit_code);

    const a = (try readBack(arena, io, tmp.dir, "a.bin")).?;
    const b = (try readBack(arena, io, tmp.dir, "b.bin")).?;

    try std.testing.expectEqual(@as(usize, 4096), a.len);
    // Not left as the original plaintext.
    try std.testing.expect(!std.mem.eql(u8, a, orig));
    // Not a constant fill (this is exactly what the getrandom bug produced).
    try std.testing.expect(!allSameByte(a));
    // Two independent shreds must not produce identical bytes.
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

test "literal anchor: -x -z -n0 writes exactly the file's length as zero bytes" {
    // shred(1): -z "add a final overwrite with zeros"; -x "do not round file
    // sizes up to the next full block"; -n0 = zero random passes. So the file
    // must be exactly its original length, all 0x00.
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zshred = try resolveZshredExe(arena, io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data = "ABCDEFGHIJKLMNOP"; // 16 bytes
    try writeFixture(io, tmp.dir, "z.bin", data);
    const r = try run(arena, io, zshred, &.{ "-x", "-z", "-n0", "z.bin" }, tmp.dir);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);

    const bytes = (try readBack(arena, io, tmp.dir, "z.bin")).?;
    const expected = [_]u8{0} ** 16;
    try std.testing.expectEqualSlices(u8, &expected, bytes);
}

test "GNU stream discipline: --version and --help go to stdout with exit 0" {
    // GNU coreutils / POSIX: informative --version/--help are written to
    // stdout and exit 0 (verified: gshred --version => 303 stdout bytes, 0
    // stderr, exit 0). The pre-fix code wrote them to stderr.
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zshred = try resolveZshredExe(arena, io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for ([_][]const u8{ "--version", "--help" }) |flag| {
        const r = try run(arena, io, zshred, &.{flag}, tmp.dir);
        try std.testing.expectEqual(@as(u8, 0), r.exit_code);
        try std.testing.expect(r.stdout.len > 0);
        try std.testing.expectEqual(@as(usize, 0), r.stderr.len);
    }
}

test "invalid pass count exits 1 without panicking" {
    // GNU: "shred: invalid number of passes: 'abc'" => exit 1. The pre-fix
    // hand-rolled parser panicked on u32 overflow ('integer overflow').
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zshred = try resolveZshredExe(arena, io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(io, tmp.dir, "z.bin", "x");

    for ([_][]const u8{ "abc", "99999999999", "99999999999999999999999999" }) |val| {
        const r = try run(arena, io, zshred, &.{ "-n", val, "z.bin" }, tmp.dir);
        try std.testing.expectEqual(@as(u8, 1), r.exit_code);
    }
}

test "no silent operand cap: every FILE argument is shredded and removed" {
    // GNU shred processes all FILE operands. The pre-fix [64] file / [256]
    // arg caps silently dropped operands past the limit. Use 70 files to
    // cross the old 64-file boundary.
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const zshred = try resolveZshredExe(arena, io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const count = 70;
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const name = try std.fmt.allocPrint(arena, "f{d}.bin", .{i});
        try writeFixture(io, tmp.dir, name, "data");
        try names.append(arena, name);
    }

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.append(arena, "-u");
    try argv.append(arena, "-n1");
    for (names.items) |n| try argv.append(arena, n);

    const r = try run(arena, io, zshred, argv.items[0..], tmp.dir);
    try std.testing.expectEqual(@as(u8, 0), r.exit_code);

    // Every file must be gone; a survivor means an operand was silently dropped.
    for (names.items) |n| {
        const back = try readBack(arena, io, tmp.dir, n);
        if (back != null) {
            std.debug.print("FAIL: operand {s} was not shredded (silent cap regression)\n", .{n});
            return error.OperandDropped;
        }
    }
}
