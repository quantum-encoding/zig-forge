//! Externally-anchored parity tests for zgzip / zgunzip.
//!
//! Per zig-forge/CLAUDE.md's golden rule, these are NOT roundtrip-only tests.
//! Every test anchors to a source the library author did not write:
//!
//!   * The system gzip/gunzip binary (Apple gzip 487.0.1 on this host, a
//!     conformant RFC 1952 implementation). zgzip output is decoded by the
//!     EXTERNAL gunzip, and EXTERNAL gzip output is decoded by zgunzip — each
//!     direction is validated by a different implementation, so neither is a
//!     self-roundtrip. These tests skip (not fail) if no system gzip exists.
//!
//!   * Byte-literal gzip streams produced offline by GNU/Apple `gzip -n` and
//!     the documented RFC 1952 trailer layout (CRC32 then ISIZE, both u32 LE,
//!     §2.3.1). These vectors are embedded so the format anchor holds even
//!     with no gzip binary installed.
//!
//! The binary paths come from build.zig via addOptionPath (absolute).

const std = @import("std");
const build_options = @import("build_options");

const zgzip_bin: []const u8 = build_options.zgzip_bin;
const zgunzip_bin: []const u8 = build_options.zgunzip_bin;
const system_gzip = "/usr/bin/gzip";
const system_gunzip = "/usr/bin/gunzip";

// ---------------------------------------------------------------------------
// Embedded external vectors (offline output of `gzip -n`, mtime zeroed).
// ---------------------------------------------------------------------------

// `gzip -n -c` of PLAINTEXT_FOX. 63 bytes. Trailer: CRC32=0x6d93c138, ISIZE=44.
const FOX_PLAIN = "The quick brown fox jumps over the lazy dog\n";
const FOX_GZ = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x0b, 0xc9, 0x48, 0x55, 0x28, 0x2c,
    0xcd, 0x4c, 0xce, 0x56, 0x48, 0x2a, 0xca, 0x2f, 0xcf, 0x53, 0x48, 0xcb, 0xaf, 0x50, 0xc8, 0x2a,
    0xcd, 0x2d, 0x28, 0x56, 0xc8, 0x2f, 0x4b, 0x2d, 0x52, 0x28, 0x01, 0x4a, 0xe7, 0x24, 0x56, 0x55,
    0x2a, 0xa4, 0xe4, 0xa7, 0x73, 0x01, 0x00, 0x38, 0xc1, 0x93, 0x6d, 0x2c, 0x00, 0x00, 0x00,
};

// `cat (gzip -n <<<AAA) (gzip -n <<<BBB)` — a two-member gzip stream.
// Decoding all members (as GNU does) yields "AAA\nBBB\n".
const MULTI_GZ = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x73, 0x74, 0x74, 0xe4, 0x02, 0x00,
    0xe9, 0x90, 0x03, 0x7a, 0x04, 0x00, 0x00, 0x00, 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x03, 0x73, 0x72, 0x72, 0xe2, 0x02, 0x00, 0x9d, 0xd2, 0xdd, 0x41, 0x04, 0x00, 0x00, 0x00,
};
const MULTI_PLAIN = "AAA\nBBB\n";

// ---------------------------------------------------------------------------
// Test scaffolding. File I/O goes through libc (like main.zig) to avoid the
// Io-instance plumbing of std's 0.16 filesystem; subprocesses go through
// std.process.run.
// ---------------------------------------------------------------------------

const c = struct {
    extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
    extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
    extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
    extern "c" fn symlink(target: [*:0]const u8, linkpath: [*:0]const u8) c_int;
    extern "c" fn unlink(path: [*:0]const u8) c_int;
    extern "c" fn rmdir(path: [*:0]const u8) c_int;
    extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
    extern "c" fn getpid() c_int;
};

var tmp_counter: u32 = 0;
// Darwin open(2) flags.
const O_RDONLY: c_int = 0x0000;
const O_WRONLY: c_int = 0x0001;
const O_CREAT: c_int = 0x0200;
const O_TRUNC: c_int = 0x0400;

var io_threaded: std.Io.Threaded = undefined;
var io_inited = false;

fn getIo() std.Io {
    if (!io_inited) {
        io_threaded = .init(std.testing.allocator, .{});
        io_inited = true;
    }
    return io_threaded.io();
}

const RunResult = std.process.RunResult;

fn run(argv: []const []const u8) !RunResult {
    return std.process.run(std.testing.allocator, getIo(), .{ .argv = argv });
}

fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |code| code,
        else => null,
    };
}

fn zbuf(buf: []u8, path: []const u8) [*:0]const u8 {
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf.ptr);
}

fn haveSystemGzip() bool {
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    return c.access(zbuf(&b1, system_gzip), 0) == 0 and c.access(zbuf(&b2, system_gunzip), 0) == 0;
}

/// Make a fresh unique temp directory. Returns an absolute path owned by the
/// testing allocator; caller frees it and rmdir's the (emptied) directory.
fn makeTmpDir() ![]u8 {
    tmp_counter += 1;
    const path = try std.fmt.allocPrint(std.testing.allocator, "/tmp/zgzip_test_{d}_{d}", .{ c.getpid(), tmp_counter });
    var zb: [4096]u8 = undefined;
    if (c.mkdir(zbuf(&zb, path), 0o700) != 0) return error.MkdirFailed;
    return path;
}

fn rmTmpDir(dir: []const u8) void {
    // The tests only create flat files under `dir`; unlink them all, then rmdir.
    var zb: [4096]u8 = undefined;
    if (std.c.opendir(zbuf(&zb, dir))) |dp| {
        while (std.c.readdir(dp)) |ent| {
            const name = ent.name[0..ent.namlen];
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const full = joinZ(dir, name) catch continue;
            defer std.testing.allocator.free(full);
            removeAbs(full);
        }
        _ = std.c.closedir(dp);
    }
    var zb2: [4096]u8 = undefined;
    _ = c.rmdir(zbuf(&zb2, dir));
}

fn joinZ(dir: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ dir, name });
}

fn removeAbs(path: []const u8) void {
    var zb: [4096]u8 = undefined;
    _ = c.unlink(zbuf(&zb, path));
}

fn writeAbs(path: []const u8, bytes: []const u8) !void {
    var zb: [4096]u8 = undefined;
    const fd = c.open(zbuf(&zb, path), O_WRONLY | O_CREAT | O_TRUNC, @as(c_int, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

fn readAbs(path: []const u8) ![]u8 {
    var zb: [4096]u8 = undefined;
    const fd = c.open(zbuf(&zb, path), O_RDONLY);
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(std.testing.allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try list.appendSlice(std.testing.allocator, buf[0..@intCast(n)]);
    }
    return list.toOwnedSlice(std.testing.allocator);
}

fn existsAbs(path: []const u8) bool {
    var zb: [4096]u8 = undefined;
    return c.access(zbuf(&zb, path), 0) == 0;
}

fn symlinkAbs(target: []const u8, linkpath: []const u8) !void {
    var tb: [4096]u8 = undefined;
    var lb: [4096]u8 = undefined;
    if (c.symlink(zbuf(&tb, target), zbuf(&lb, linkpath)) != 0) return error.SymlinkFailed;
}

fn le32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .little);
}

// ---------------------------------------------------------------------------
// ANCHOR 1 (primary, mutation target): the EXTERNAL gunzip must be able to
// decode zgzip's output. This is what the flush()->finish() fix restores: a
// stream without the final block + CRC32/ISIZE trailer fails here.
// ---------------------------------------------------------------------------
test "zgzip output decodes under system gunzip (external decoder)" {
    if (!haveSystemGzip()) return error.SkipZigTest;

    const payload = "hello world hello world\n" ** 40; // compressible, multi-block-ish

    const dir = try makeTmpDir();
    defer {
        rmTmpDir(dir);
        std.testing.allocator.free(dir);
    }
    const src = try joinZ(dir, "data.txt");
    defer std.testing.allocator.free(src);
    try writeAbs(src, payload);

    // zgzip -kc data.txt  -> stdout is the .gz stream
    const gz = try run(&.{ zgzip_bin, "-kc", src });
    defer std.testing.allocator.free(gz.stdout);
    defer std.testing.allocator.free(gz.stderr);
    try std.testing.expectEqual(@as(?u8, 0), exitCode(gz.term));
    try std.testing.expect(gz.stdout.len > 0);

    // Write the produced stream and hand it to the EXTERNAL gunzip.
    const gzfile = try joinZ(dir, "data.txt.gz");
    defer std.testing.allocator.free(gzfile);
    try writeAbs(gzfile, gz.stdout);

    const dec = try run(&.{ system_gunzip, "-c", gzfile });
    defer std.testing.allocator.free(dec.stdout);
    defer std.testing.allocator.free(dec.stderr);
    try std.testing.expectEqual(@as(?u8, 0), exitCode(dec.term)); // 1 == truncated stream
    try std.testing.expectEqualStrings(payload, dec.stdout);
}

// ---------------------------------------------------------------------------
// ANCHOR 2: zgzip's trailer conforms to RFC 1952 §2.3.1 — the last 8 bytes are
// CRC32(input) then ISIZE, each u32 little-endian; header begins 1f 8b 08.
// This is a pure-format anchor (no subprocess): the flush bug omitted the
// trailer entirely, so these byte checks fail without the fix.
// ---------------------------------------------------------------------------
test "zgzip trailer matches RFC 1952 (magic + CRC32 + ISIZE)" {
    const payload = "The quick brown fox jumps over the lazy dog\n";

    const dir = try makeTmpDir();
    defer {
        rmTmpDir(dir);
        std.testing.allocator.free(dir);
    }
    const src = try joinZ(dir, "fox.txt");
    defer std.testing.allocator.free(src);
    try writeAbs(src, payload);

    const gz = try run(&.{ zgzip_bin, "-kc", src });
    defer std.testing.allocator.free(gz.stdout);
    defer std.testing.allocator.free(gz.stderr);
    try std.testing.expectEqual(@as(?u8, 0), exitCode(gz.term));

    const out = gz.stdout;
    try std.testing.expect(out.len >= 18);
    // RFC 1952 §2.3: ID1=0x1f ID2=0x8b CM=8 (deflate).
    try std.testing.expectEqual(@as(u8, 0x1f), out[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), out[1]);
    try std.testing.expectEqual(@as(u8, 0x08), out[2]);
    // Trailer: CRC32 then ISIZE, u32 LE.
    const crc = le32(out[out.len - 8 ..][0..4]);
    const isize_field = le32(out[out.len - 4 ..][0..4]);
    try std.testing.expectEqual(std.hash.Crc32.hash(payload), crc);
    try std.testing.expectEqual(@as(u32, payload.len), isize_field);
}

// ---------------------------------------------------------------------------
// ANCHOR 3: zgunzip must decode a gzip stream produced by GNU/Apple gzip.
// Uses an EMBEDDED byte vector (offline `gzip -n`), so it holds with no binary
// installed. Validates the decoder against a stream the library did not write.
// ---------------------------------------------------------------------------
test "zgunzip decodes embedded GNU gzip vector (external encoder)" {
    const dir = try makeTmpDir();
    defer {
        rmTmpDir(dir);
        std.testing.allocator.free(dir);
    }
    const gzfile = try joinZ(dir, "fox.gz");
    defer std.testing.allocator.free(gzfile);
    try writeAbs(gzfile, &FOX_GZ);

    const dec = try run(&.{ zgunzip_bin, "-c", gzfile });
    defer std.testing.allocator.free(dec.stdout);
    defer std.testing.allocator.free(dec.stderr);
    try std.testing.expectEqual(@as(?u8, 0), exitCode(dec.term));
    try std.testing.expectEqualStrings(FOX_PLAIN, dec.stdout);
}

// ---------------------------------------------------------------------------
// ANCHOR 4: concatenated multi-member gzip (GNU emits every member). Uses the
// embedded two-member vector; the pre-fix single-member decoder truncated to
// "AAA\n".
// ---------------------------------------------------------------------------
test "zgunzip decodes all members of a concatenated gzip stream" {
    const dir = try makeTmpDir();
    defer {
        rmTmpDir(dir);
        std.testing.allocator.free(dir);
    }
    const gzfile = try joinZ(dir, "multi.gz");
    defer std.testing.allocator.free(gzfile);
    try writeAbs(gzfile, &MULTI_GZ);

    const dec = try run(&.{ zgunzip_bin, "-c", gzfile });
    defer std.testing.allocator.free(dec.stdout);
    defer std.testing.allocator.free(dec.stderr);
    try std.testing.expectEqual(@as(?u8, 0), exitCode(dec.term));
    try std.testing.expectEqualStrings(MULTI_PLAIN, dec.stdout);
}

// ---------------------------------------------------------------------------
// ANCHOR 5: exit status on error. GNU gzip exits non-zero (1) on bad input;
// zgunzip on a non-gzip file must not exit 0.
// ---------------------------------------------------------------------------
test "zgunzip exits non-zero on non-gzip input (GNU parity)" {
    const dir = try makeTmpDir();
    defer {
        rmTmpDir(dir);
        std.testing.allocator.free(dir);
    }
    const bad = try joinZ(dir, "notgzip.gz");
    defer std.testing.allocator.free(bad);
    try writeAbs(bad, "this is definitely not a gzip stream at all, no magic here");

    const dec = try run(&.{ zgunzip_bin, "-c", bad });
    defer std.testing.allocator.free(dec.stdout);
    defer std.testing.allocator.free(dec.stderr);
    try std.testing.expect(exitCode(dec.term) != @as(?u8, 0));

    // Cross-check the same file against the system gunzip: it must also fail.
    if (haveSystemGzip()) {
        const sys = try run(&.{ system_gunzip, "-c", bad });
        defer std.testing.allocator.free(sys.stdout);
        defer std.testing.allocator.free(sys.stderr);
        try std.testing.expect(exitCode(sys.term) != @as(?u8, 0));
    }
}

// ---------------------------------------------------------------------------
// ANCHOR 6: --version goes to stdout (GNU behavior), not stderr.
// ---------------------------------------------------------------------------
test "--version is written to stdout (GNU parity)" {
    const res = try run(&.{ zgzip_bin, "--version" });
    defer std.testing.allocator.free(res.stdout);
    defer std.testing.allocator.free(res.stderr);
    try std.testing.expectEqual(@as(?u8, 0), exitCode(res.term));
    try std.testing.expect(res.stdout.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "zgzip") != null);
    try std.testing.expectEqual(@as(usize, 0), res.stderr.len);
}

// ---------------------------------------------------------------------------
// ANCHOR 7 (security): zgzip must not clobber an existing output without -f,
// and must never follow a symlink at the output path. GNU refuses to overwrite
// without -f. A symlink `victim` target must survive intact.
// ---------------------------------------------------------------------------
test "zgzip refuses to overwrite existing output and never follows symlink" {
    const dir = try makeTmpDir();
    defer {
        rmTmpDir(dir);
        std.testing.allocator.free(dir);
    }

    // Case A: plain existing output is not clobbered without -f.
    const a_src = try joinZ(dir, "a.txt");
    defer std.testing.allocator.free(a_src);
    try writeAbs(a_src, "fresh source\n");
    const a_gz = try joinZ(dir, "a.txt.gz");
    defer std.testing.allocator.free(a_gz);
    try writeAbs(a_gz, "PRE-EXISTING MUST SURVIVE");

    const r1 = try run(&.{ zgzip_bin, "-k", a_src });
    defer std.testing.allocator.free(r1.stdout);
    defer std.testing.allocator.free(r1.stderr);
    try std.testing.expect(exitCode(r1.term) != @as(?u8, 0)); // refused
    const a_after = try readAbs(a_gz);
    defer std.testing.allocator.free(a_after);
    try std.testing.expectEqualStrings("PRE-EXISTING MUST SURVIVE", a_after);
    // Source must still exist (not deleted on failure).
    try std.testing.expect(existsAbs(a_src));

    // Case B: output path is a symlink -> the symlink target must be untouched.
    const victim = try joinZ(dir, "victim.txt");
    defer std.testing.allocator.free(victim);
    try writeAbs(victim, "VICTIM CONTENTS MUST SURVIVE\n");
    const b_src = try joinZ(dir, "in.txt");
    defer std.testing.allocator.free(b_src);
    try writeAbs(b_src, "attacker payload\n");
    const b_link = try joinZ(dir, "in.txt.gz");
    defer std.testing.allocator.free(b_link);
    try symlinkAbs(victim, b_link);

    const r2 = try run(&.{ zgzip_bin, "-k", b_src });
    defer std.testing.allocator.free(r2.stdout);
    defer std.testing.allocator.free(r2.stderr);
    try std.testing.expect(exitCode(r2.term) != @as(?u8, 0)); // refused (EEXIST/ELOOP)
    const victim_after = try readAbs(victim);
    defer std.testing.allocator.free(victim_after);
    try std.testing.expectEqualStrings("VICTIM CONTENTS MUST SURVIVE\n", victim_after);
}

// ---------------------------------------------------------------------------
// ANCHOR 8 (data-safety): a failed compress must NOT delete the source file.
// Combined with the flush bug this was total data loss; here we drive a failure
// by pre-placing the output so the (default, no -f) open is refused, and assert
// the source survives.
// ---------------------------------------------------------------------------
test "failed compress leaves the source file intact" {
    const dir = try makeTmpDir();
    defer {
        rmTmpDir(dir);
        std.testing.allocator.free(dir);
    }
    const src = try joinZ(dir, "keepme.txt");
    defer std.testing.allocator.free(src);
    try writeAbs(src, "irreplaceable data\n");
    const gz = try joinZ(dir, "keepme.txt.gz");
    defer std.testing.allocator.free(gz);
    try writeAbs(gz, "blocks the write");

    const r = try run(&.{ zgzip_bin, src }); // no -k: would delete src on success
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    try std.testing.expect(exitCode(r.term) != @as(?u8, 0));

    // The source must still be there and unchanged.
    const survived = try readAbs(src);
    defer std.testing.allocator.free(survived);
    try std.testing.expectEqualStrings("irreplaceable data\n", survived);
}

// ---------------------------------------------------------------------------
// ANCHOR 9: full external round path across the process boundary — zgzip
// compresses, the SYSTEM gzip re-reads (gzip -t validates CRC), proving the
// stream is byte-conformant, not merely self-decodable.
// ---------------------------------------------------------------------------
test "system gzip -t validates zgzip output (CRC-verified)" {
    if (!haveSystemGzip()) return error.SkipZigTest;

    const payload = "conformance payload \x00\x01\x02 with NULs and \xff bytes\n" ** 8;

    const dir = try makeTmpDir();
    defer {
        rmTmpDir(dir);
        std.testing.allocator.free(dir);
    }
    const src = try joinZ(dir, "conf.bin");
    defer std.testing.allocator.free(src);
    try writeAbs(src, payload);

    const gz = try run(&.{ zgzip_bin, "-kc", src });
    defer std.testing.allocator.free(gz.stdout);
    defer std.testing.allocator.free(gz.stderr);
    try std.testing.expectEqual(@as(?u8, 0), exitCode(gz.term));

    const gzfile = try joinZ(dir, "conf.bin.gz");
    defer std.testing.allocator.free(gzfile);
    try writeAbs(gzfile, gz.stdout);

    // `gzip -t` performs a full integrity (CRC + length) test.
    const t = try run(&.{ system_gzip, "-t", gzfile });
    defer std.testing.allocator.free(t.stdout);
    defer std.testing.allocator.free(t.stderr);
    try std.testing.expectEqual(@as(?u8, 0), exitCode(t.term));
}
