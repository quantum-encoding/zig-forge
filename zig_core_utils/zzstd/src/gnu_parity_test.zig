//! Externally-anchored parity tests for zzstd.
//!
//! Per zig-forge/CLAUDE.md's golden rule, these are NOT roundtrip-only tests.
//! Every test anchors to a source the test author did not write:
//!
//!   * The system zstd binary (the real Zstandard CLI v1.5.7 by Yann Collet,
//!     /opt/homebrew/bin/zstd). It PRODUCES the compressed inputs that zzstd
//!     must decode, and independently validates behavior. zzstd never decodes
//!     its own output — it has no compressor — so nothing here is a
//!     self-roundtrip. Tests that need the binary skip (not fail) if absent.
//!
//!   * An EMBEDDED zstd frame produced offline by `zstd -19` (FOX_ZST below).
//!     The expected plaintext (FOX_PLAIN) is the literal input that was fed to
//!     the reference compressor. This format anchor holds with no binary
//!     installed.
//!
//! The zzstd binary path comes from build.zig via addOptionPath (absolute).

const std = @import("std");
const build_options = @import("build_options");

const zzstd_bin: []const u8 = build_options.zzstd_bin;
const system_zstd = "/opt/homebrew/bin/zstd";

// ---------------------------------------------------------------------------
// Embedded external vector: `zstd -19` of FOX_PLAIN, captured offline from the
// reference CLI (v1.5.7). 57 bytes. First 4 bytes are the zstd magic
// 0x28 0xb5 0x2f 0xfd (little-endian 0xFD2FB528).
// ---------------------------------------------------------------------------
const FOX_PLAIN = "The quick brown fox jumps over the lazy dog\n";
const FOX_ZST = [_]u8{
    0x28, 0xb5, 0x2f, 0xfd, 0x24, 0x2c, 0x61, 0x01, 0x00, 0x54, 0x68, 0x65,
    0x20, 0x71, 0x75, 0x69, 0x63, 0x6b, 0x20, 0x62, 0x72, 0x6f, 0x77, 0x6e,
    0x20, 0x66, 0x6f, 0x78, 0x20, 0x6a, 0x75, 0x6d, 0x70, 0x73, 0x20, 0x6f,
    0x76, 0x65, 0x72, 0x20, 0x74, 0x68, 0x65, 0x20, 0x6c, 0x61, 0x7a, 0x79,
    0x20, 0x64, 0x6f, 0x67, 0x0a, 0xe4, 0xa7, 0xbc, 0x87,
};

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

fn haveSystemZstd() bool {
    var b1: [256]u8 = undefined;
    return c.access(zbuf(&b1, system_zstd), 0) == 0;
}

/// Make a fresh unique temp directory. Returns an absolute path owned by the
/// testing allocator; caller frees it and rmdir's the (emptied) directory.
fn makeTmpDir() ![]u8 {
    tmp_counter += 1;
    const path = try std.fmt.allocPrint(std.testing.allocator, "/tmp/zzstd_test_{d}_{d}", .{ c.getpid(), tmp_counter });
    var zb: [4096]u8 = undefined;
    if (c.mkdir(zbuf(&zb, path), 0o700) != 0) return error.MkdirFailed;
    return path;
}

fn rmTmpDir(dir: []const u8) void {
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

/// Compress `plain` with the system zstd into `dst_zst` (external encoder).
fn sysCompress(plain: []const u8, dst_zst: []const u8) !void {
    // Write plaintext to a sibling of dst without the .zst suffix.
    std.debug.assert(std.mem.endsWith(u8, dst_zst, ".zst"));
    const src = dst_zst[0 .. dst_zst.len - 4];
    try writeAbs(src, plain);
    const r = try run(&.{ system_zstd, "-q", "-f", "-19", src, "-o", dst_zst });
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    if (exitCode(r.term) != @as(?u8, 0)) return error.SysCompressFailed;
    removeAbs(src); // leave only the .zst behind
}

// ---------------------------------------------------------------------------
// ANCHOR 1 (primary, mutation target): zzstd must decompress a frame produced
// by the SYSTEM zstd and reproduce the original plaintext EXACTLY. External
// encoder → the anchor is the reference CLI's bytes, not our own output.
// ---------------------------------------------------------------------------
test "zzstd decodes a system-zstd frame to exact plaintext (external encoder)" {
    if (!haveSystemZstd()) return error.SkipZigTest;

    const payload = "hello zstd world\n" ** 60 ++ "tail line no newline"; // compressible + odd tail

    const dir = try makeTmpDir();
    defer {
        rmTmpDir(dir);
        std.testing.allocator.free(dir);
    }
    const zst = try joinZ(dir, "data.txt.zst");
    defer std.testing.allocator.free(zst);
    try sysCompress(payload, zst);

    // zzstd -dc data.txt.zst -> stdout is the decompressed plaintext.
    const dec = try run(&.{ zzstd_bin, "-dc", zst });
    defer std.testing.allocator.free(dec.stdout);
    defer std.testing.allocator.free(dec.stderr);
    try std.testing.expectEqual(@as(?u8, 0), exitCode(dec.term));
    try std.testing.expectEqualStrings(payload, dec.stdout);
}

// ---------------------------------------------------------------------------
// ANCHOR 2: zzstd decodes the EMBEDDED reference-zstd frame vector (offline
// `zstd -19`). Expected output is the literal plaintext fed to the reference
// compressor. Holds with no binary installed.
// ---------------------------------------------------------------------------
test "zzstd decodes embedded reference zstd vector (external encoder)" {
    const dir = try makeTmpDir();
    defer {
        rmTmpDir(dir);
        std.testing.allocator.free(dir);
    }
    const zst = try joinZ(dir, "fox.txt.zst");
    defer std.testing.allocator.free(zst);
    try writeAbs(zst, &FOX_ZST);

    const dec = try run(&.{ zzstd_bin, "-dc", zst });
    defer std.testing.allocator.free(dec.stdout);
    defer std.testing.allocator.free(dec.stderr);
    try std.testing.expectEqual(@as(?u8, 0), exitCode(dec.term));
    try std.testing.expectEqualStrings(FOX_PLAIN, dec.stdout);
}

// ---------------------------------------------------------------------------
// ANCHOR 3 (CRITICAL data-safety bug): a corrupt-but-magic-valid frame must
// make zzstd FAIL (nonzero exit) and MUST NOT delete the source .zst. The
// pre-fix code swallowed the streamRemaining error, exited 0, and unlink'd the
// source — irrecoverable loss. GNU zstd exits 1 and keeps the source.
// ---------------------------------------------------------------------------
test "corrupt frame: zzstd fails nonzero and never deletes the source" {
    const dir = try makeTmpDir();
    defer {
        rmTmpDir(dir);
        std.testing.allocator.free(dir);
    }
    const zst = try joinZ(dir, "bad.txt.zst");
    defer std.testing.allocator.free(zst);
    // Valid magic (0x28 0xb5 0x2f 0xfd) then garbage — decode must error.
    const corrupt = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd } ++ "GARBAGEGARBAGEGARBAGE".*;
    try writeAbs(zst, &corrupt);

    const r = try run(&.{ zzstd_bin, "-d", zst }); // no -k, no -c: would unlink on success
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    try std.testing.expect(exitCode(r.term) != @as(?u8, 0)); // must NOT be 0

    // The source must still exist — this is the whole point of the fix.
    try std.testing.expect(existsAbs(zst));

    // Cross-check: the system zstd also fails on the same bytes (nonzero).
    if (haveSystemZstd()) {
        const s = try run(&.{ system_zstd, "-d", "-c", zst });
        defer std.testing.allocator.free(s.stdout);
        defer std.testing.allocator.free(s.stderr);
        try std.testing.expect(exitCode(s.term) != @as(?u8, 0));
    }
}

// ---------------------------------------------------------------------------
// ANCHOR 4: exit status on a nonexistent input. GNU zstd exits 1; the pre-fix
// zzstd exited 0. Cross-checked against the system binary.
// ---------------------------------------------------------------------------
test "nonexistent input exits nonzero (GNU parity)" {
    const dir = try makeTmpDir();
    defer {
        rmTmpDir(dir);
        std.testing.allocator.free(dir);
    }
    const missing = try joinZ(dir, "does_not_exist.zst");
    defer std.testing.allocator.free(missing);

    const r = try run(&.{ zzstd_bin, "-d", missing });
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    try std.testing.expect(exitCode(r.term) != @as(?u8, 0));

    if (haveSystemZstd()) {
        const s = try run(&.{ system_zstd, "-d", missing });
        defer std.testing.allocator.free(s.stdout);
        defer std.testing.allocator.free(s.stderr);
        try std.testing.expect(exitCode(s.term) != @as(?u8, 0));
    }
}

// ---------------------------------------------------------------------------
// ANCHOR 5: unknown suffix on decompress exits nonzero (GNU parity). The
// pre-fix code printed "unknown suffix" but exited 0.
// ---------------------------------------------------------------------------
test "unknown suffix on decompress exits nonzero (GNU parity)" {
    const dir = try makeTmpDir();
    defer {
        rmTmpDir(dir);
        std.testing.allocator.free(dir);
    }
    const plain = try joinZ(dir, "plain.txt");
    defer std.testing.allocator.free(plain);
    try writeAbs(plain, "not compressed\n");

    const r = try run(&.{ zzstd_bin, "-d", plain });
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    try std.testing.expect(exitCode(r.term) != @as(?u8, 0));
}

// ---------------------------------------------------------------------------
// ANCHOR 6 (path-safety): without -f, zzstd must NOT clobber an existing output
// and must never follow a symlink at the output path; source survives. GNU
// refuses to overwrite without -f.
// ---------------------------------------------------------------------------
test "refuses to overwrite existing output and never follows symlink" {
    if (!haveSystemZstd()) return error.SkipZigTest;

    const dir = try makeTmpDir();
    defer {
        rmTmpDir(dir);
        std.testing.allocator.free(dir);
    }

    // Case A: an existing output.txt is not clobbered without -f.
    const a_zst = try joinZ(dir, "a.txt.zst");
    defer std.testing.allocator.free(a_zst);
    try sysCompress("decompressed A contents\n", a_zst);
    const a_out = try joinZ(dir, "a.txt");
    defer std.testing.allocator.free(a_out);
    try writeAbs(a_out, "PRE-EXISTING MUST SURVIVE");

    const r1 = try run(&.{ zzstd_bin, "-d", a_zst });
    defer std.testing.allocator.free(r1.stdout);
    defer std.testing.allocator.free(r1.stderr);
    try std.testing.expect(exitCode(r1.term) != @as(?u8, 0)); // refused
    const a_after = try readAbs(a_out);
    defer std.testing.allocator.free(a_after);
    try std.testing.expectEqualStrings("PRE-EXISTING MUST SURVIVE", a_after);
    try std.testing.expect(existsAbs(a_zst)); // source not deleted on failure

    // Case B: output path is a symlink -> its target must be untouched.
    const victim = try joinZ(dir, "victim.txt");
    defer std.testing.allocator.free(victim);
    try writeAbs(victim, "VICTIM CONTENTS MUST SURVIVE\n");
    const b_zst = try joinZ(dir, "in.txt.zst");
    defer std.testing.allocator.free(b_zst);
    try sysCompress("attacker payload\n", b_zst);
    const b_link = try joinZ(dir, "in.txt");
    defer std.testing.allocator.free(b_link);
    try symlinkAbs(victim, b_link);

    const r2 = try run(&.{ zzstd_bin, "-d", b_zst });
    defer std.testing.allocator.free(r2.stdout);
    defer std.testing.allocator.free(r2.stderr);
    try std.testing.expect(exitCode(r2.term) != @as(?u8, 0)); // refused (EEXIST/ELOOP)
    const victim_after = try readAbs(victim);
    defer std.testing.allocator.free(victim_after);
    try std.testing.expectEqualStrings("VICTIM CONTENTS MUST SURVIVE\n", victim_after);
}

// ---------------------------------------------------------------------------
// ANCHOR 7: -f forces overwrite of an existing output with the decompressed
// bytes (the external frame decodes correctly on top of the old file).
// ---------------------------------------------------------------------------
test "-f overwrites existing output with decompressed bytes" {
    if (!haveSystemZstd()) return error.SkipZigTest;

    const dir = try makeTmpDir();
    defer {
        rmTmpDir(dir);
        std.testing.allocator.free(dir);
    }
    const zst = try joinZ(dir, "f.txt.zst");
    defer std.testing.allocator.free(zst);
    try sysCompress("the real decompressed contents\n", zst);
    const out = try joinZ(dir, "f.txt");
    defer std.testing.allocator.free(out);
    try writeAbs(out, "STALE DATA TO BE REPLACED");

    const r = try run(&.{ zzstd_bin, "-df", zst });
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    try std.testing.expectEqual(@as(?u8, 0), exitCode(r.term));
    const after = try readAbs(out);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings("the real decompressed contents\n", after);
}

// ---------------------------------------------------------------------------
// ANCHOR 8: -dc keeps the source and writes to stdout (GNU: -c never removes
// the input).
// ---------------------------------------------------------------------------
test "-dc writes to stdout and keeps the source" {
    if (!haveSystemZstd()) return error.SkipZigTest;

    const dir = try makeTmpDir();
    defer {
        rmTmpDir(dir);
        std.testing.allocator.free(dir);
    }
    const zst = try joinZ(dir, "keep.txt.zst");
    defer std.testing.allocator.free(zst);
    try sysCompress("keep me around\n", zst);

    const r = try run(&.{ zzstd_bin, "-dc", zst });
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    try std.testing.expectEqual(@as(?u8, 0), exitCode(r.term));
    try std.testing.expectEqualStrings("keep me around\n", r.stdout);
    try std.testing.expect(existsAbs(zst)); // -c must not delete
}

// ---------------------------------------------------------------------------
// ANCHOR 9: a compression request must fail (nonzero), not silently succeed.
// zzstd has no compressor; GNU's default action is compression, so silently
// exiting 0 while producing nothing is the worst outcome. We assert failure.
// ---------------------------------------------------------------------------
test "compression request exits nonzero (no silent success)" {
    const dir = try makeTmpDir();
    defer {
        rmTmpDir(dir);
        std.testing.allocator.free(dir);
    }
    const src = try joinZ(dir, "plain.txt");
    defer std.testing.allocator.free(src);
    try writeAbs(src, "please compress me\n");

    const r = try run(&.{ zzstd_bin, src }); // default action = compress
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    try std.testing.expect(exitCode(r.term) != @as(?u8, 0));
    // Must not have produced a bogus .zst either.
    const bogus = try joinZ(dir, "plain.txt.zst");
    defer std.testing.allocator.free(bogus);
    try std.testing.expect(!existsAbs(bogus));
}

// ---------------------------------------------------------------------------
// ANCHOR 10: larger binary payload with NULs / high bytes survives the full
// process-boundary path: system zstd compresses, zzstd decompresses to file,
// bytes match exactly, and (default, no -k) the source .zst is removed on
// success — GNU's default.
// ---------------------------------------------------------------------------
test "binary payload: system-compressed frame decompresses byte-exact to file" {
    if (!haveSystemZstd()) return error.SkipZigTest;

    var payload: [8192]u8 = undefined;
    var s: u32 = 0x1234_5678;
    for (&payload) |*b| {
        // simple LCG for reproducible pseudo-random bytes incl. 0x00/0xff
        s = s *% 1664525 +% 1013904223;
        b.* = @truncate(s >> 16);
    }

    const dir = try makeTmpDir();
    defer {
        rmTmpDir(dir);
        std.testing.allocator.free(dir);
    }
    const zst = try joinZ(dir, "blob.bin.zst");
    defer std.testing.allocator.free(zst);
    try sysCompress(&payload, zst);

    const r = try run(&.{ zzstd_bin, "-d", zst }); // to file, remove source on success
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);
    try std.testing.expectEqual(@as(?u8, 0), exitCode(r.term));

    const out = try joinZ(dir, "blob.bin");
    defer std.testing.allocator.free(out);
    const got = try readAbs(out);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualSlices(u8, &payload, got);
    try std.testing.expect(!existsAbs(zst)); // default: source removed after success
}
