//! File hashing utilities using BLAKE3
//!
//! Supports:
//! - Full file hashing
//! - Partial/quick hashing (first N bytes)
//! - Streaming for large files
//! - Memory-mapped I/O for performance

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const pstat = @import("pstat.zig");
const libc = std.c;

const is_linux = builtin.os.tag == .linux;

/// Hash digest (32 bytes for BLAKE3)
pub const Hash = [32]u8;

/// Buffer size for streaming hash (64KB for good I/O performance)
pub const BUFFER_SIZE: usize = 64 * 1024;

/// Default quick hash size (first 4KB)
pub const DEFAULT_QUICK_HASH_SIZE: usize = 4096;

/// File hasher using BLAKE3
pub const FileHasher = struct {
    /// Hash algorithm to use
    algorithm: types.Config.HashAlgorithm,

    pub fn init(algorithm: types.Config.HashAlgorithm) FileHasher {
        return .{ .algorithm = algorithm };
    }

    /// Hash entire file
    pub fn hashFile(self: *const FileHasher, path: []const u8) !Hash {
        return switch (self.algorithm) {
            .blake3 => hashFileBlake3(path, null),
            .sha256 => hashFileSha256(path, null),
        };
    }

    /// Hash first N bytes of file (quick hash for fast rejection)
    pub fn hashFileQuick(self: *const FileHasher, path: []const u8, max_bytes: usize) !Hash {
        return switch (self.algorithm) {
            .blake3 => hashFileBlake3(path, max_bytes),
            .sha256 => hashFileSha256(path, max_bytes),
        };
    }

    /// Hash data in memory
    pub fn hashBytes(self: *const FileHasher, data: []const u8) Hash {
        return switch (self.algorithm) {
            .blake3 => hashBytesBlake3(data),
            .sha256 => hashBytesSha256(data),
        };
    }
};

/// Open `path` read-only and verify it is a regular file.
///
/// O_NONBLOCK makes open() on a FIFO return immediately instead of blocking
/// until a writer appears — without it a scan that reaches a named pipe
/// (steam.pipe, wine sockets, …) hangs the whole run forever. Regular-file
/// reads are unaffected by the flag. The fstat guard then rejects anything
/// that is not a regular file: a writerless FIFO opened with O_NONBLOCK
/// reads as instant EOF, so without the guard every such special file would
/// hash identically to an empty file and be reported as a "duplicate" —
/// offering non-duplicates for deletion. The walk-time type check cannot
/// replace this: the path can change type between walk and hash.
fn openRegularFile(path: []const u8) !c_int {
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);

    const fd = libc.open(path_z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, @as(libc.mode_t, 0));
    if (fd < 0) return error.CannotOpenFile;
    errdefer _ = libc.close(fd);

    const st = pstat.fstat(fd) catch return error.CannotOpenFile;
    if (!st.isFile()) return error.NotRegularFile;
    return fd;
}

/// Hash file using BLAKE3 (fastest, cryptographically secure)
pub fn hashFileBlake3(path: []const u8, max_bytes: ?usize) !Hash {
    const fd = try openRegularFile(path);
    defer _ = libc.close(fd);

    var hasher = std.crypto.hash.Blake3.init(.{});
    var buf: [BUFFER_SIZE]u8 = undefined;
    var total_read: usize = 0;

    while (true) {
        // Check if we've read enough for quick hash
        if (max_bytes) |max| {
            if (total_read >= max) break;
        }

        const bytes_to_read = if (max_bytes) |max|
            @min(BUFFER_SIZE, max - total_read)
        else
            BUFFER_SIZE;

        const n = libc.read(fd, &buf, bytes_to_read);
        if (n == 0) break; // genuine EOF
        if (n < 0) {
            // read() failed. EINTR is retryable; anything else must propagate
            // so a partial-prefix hash is never returned as a valid digest.
            if (libc.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }

        const bytes_read: usize = @intCast(n);
        hasher.update(buf[0..bytes_read]);
        total_read += bytes_read;
    }

    var result: Hash = undefined;
    hasher.final(&result);
    return result;
}

/// Hash file using SHA256
pub fn hashFileSha256(path: []const u8, max_bytes: ?usize) !Hash {
    const fd = try openRegularFile(path);
    defer _ = libc.close(fd);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [BUFFER_SIZE]u8 = undefined;
    var total_read: usize = 0;

    while (true) {
        if (max_bytes) |max| {
            if (total_read >= max) break;
        }

        const bytes_to_read = if (max_bytes) |max|
            @min(BUFFER_SIZE, max - total_read)
        else
            BUFFER_SIZE;

        const n = libc.read(fd, &buf, bytes_to_read);
        if (n == 0) break; // genuine EOF
        if (n < 0) {
            // read() failed. EINTR is retryable; anything else must propagate
            // so a partial-prefix hash is never returned as a valid digest.
            if (libc.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }

        const bytes_read: usize = @intCast(n);
        hasher.update(buf[0..bytes_read]);
        total_read += bytes_read;
    }

    var result: Hash = undefined;
    hasher.final(&result);
    return result;
}

/// Hash bytes in memory using BLAKE3
pub fn hashBytesBlake3(data: []const u8) Hash {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(data);
    var result: Hash = undefined;
    hasher.final(&result);
    return result;
}

/// Hash bytes in memory using SHA256
pub fn hashBytesSha256(data: []const u8) Hash {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    var result: Hash = undefined;
    hasher.final(&result);
    return result;
}

/// Format hash as hexadecimal string
pub fn hashToHex(hash: *const Hash, buf: *[64]u8) []const u8 {
    const charset = "0123456789abcdef";
    for (hash.*, 0..) |byte, i| {
        buf[i * 2] = charset[byte >> 4];
        buf[i * 2 + 1] = charset[byte & 0x0f];
    }
    return buf[0..64];
}

/// Compare two hashes for equality
pub fn hashEqual(a: *const Hash, b: *const Hash) bool {
    return std.mem.eql(u8, a, b);
}

/// Hash comparison for sorting
pub fn hashLessThan(_: void, a: Hash, b: Hash) bool {
    return std.mem.order(u8, &a, &b) == .lt;
}

// ============================================================================
// Batch hashing for parallelization
// ============================================================================

/// Batch hash multiple files (for parallel processing)
pub const BatchHasher = struct {
    allocator: std.mem.Allocator,
    algorithm: types.Config.HashAlgorithm,
    results: std.StringHashMap(HashResult),

    pub const HashResult = struct {
        hash: ?Hash,
        err: ?anyerror,
    };

    pub fn init(allocator: std.mem.Allocator, algorithm: types.Config.HashAlgorithm) BatchHasher {
        return .{
            .allocator = allocator,
            .algorithm = algorithm,
            .results = std.StringHashMap(HashResult).init(allocator),
        };
    }

    pub fn deinit(self: *BatchHasher) void {
        self.results.deinit();
    }

    /// Hash multiple files sequentially
    pub fn hashFiles(self: *BatchHasher, paths: []const []const u8) void {
        const hasher = FileHasher.init(self.algorithm);

        for (paths) |path| {
            const result = hasher.hashFile(path);
            if (result) |hash| {
                self.results.put(path, .{ .hash = hash, .err = null }) catch {};
            } else |err| {
                self.results.put(path, .{ .hash = null, .err = err }) catch {};
            }
        }
    }

    /// Get hash result for a path
    pub fn getResult(self: *const BatchHasher, path: []const u8) ?HashResult {
        return self.results.get(path);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "hashBytesBlake3" {
    const data = "Hello, World!";
    const hash = hashBytesBlake3(data);

    var hex_buf: [64]u8 = undefined;
    const hex = hashToHex(&hash, &hex_buf);

    // Known BLAKE3 hash of "Hello, World!"
    try std.testing.expectEqualStrings(
        "288a86a79f20a3d6dccdca7713beaed178798296bdfa7913fa2a62d9727bf8f8",
        hex,
    );
}

test "hashBytesSha256" {
    const data = "Hello, World!";
    const hash = hashBytesSha256(data);

    var hex_buf: [64]u8 = undefined;
    const hex = hashToHex(&hash, &hex_buf);

    // Known SHA256 hash of "Hello, World!"
    try std.testing.expectEqualStrings(
        "dffd6021bb2bd5b0af676290809ec3a53191dd81c7f70a4b28688a362182986f",
        hex,
    );
}

test "hashEqual" {
    const a = hashBytesBlake3("test");
    const b = hashBytesBlake3("test");
    const c = hashBytesBlake3("different");

    try std.testing.expect(hashEqual(&a, &b));
    try std.testing.expect(!hashEqual(&a, &c));
}

test "FileHasher" {
    const hasher = FileHasher.init(.blake3);

    // Test in-memory hashing
    const hash = hasher.hashBytes("test data");
    try std.testing.expect(hash.len == 32);
}

test "hashToHex format" {
    const hash: Hash = [_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };

    var buf: [64]u8 = undefined;
    const hex = hashToHex(&hash, &buf);

    try std.testing.expectEqualStrings(
        "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
        hex,
    );
}

test "hashBytesBlake3 empty data" {
    const data = "";
    const hash = hashBytesBlake3(data);

    var hex_buf: [64]u8 = undefined;
    const hex = hashToHex(&hash, &hex_buf);

    // Known BLAKE3 hash of empty string
    try std.testing.expectEqualStrings(
        "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262",
        hex,
    );
}

test "hashBytesSha256 empty data" {
    const data = "";
    const hash = hashBytesSha256(data);

    var hex_buf: [64]u8 = undefined;
    const hex = hashToHex(&hash, &hex_buf);

    // Known SHA256 hash of empty string
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        hex,
    );
}

test "hashLessThan sorting" {
    const hash_a: Hash = [_]u8{0x00} ** 32;
    const hash_b: Hash = [_]u8{0xff} ** 32;
    const hash_c: Hash = [_]u8{0x80} ** 32;

    try std.testing.expect(hashLessThan({}, hash_a, hash_b));
    try std.testing.expect(!hashLessThan({}, hash_b, hash_a));
    try std.testing.expect(hashLessThan({}, hash_c, hash_b));
    try std.testing.expect(hashLessThan({}, hash_a, hash_c));
}

test "BatchHasher initialization" {
    const allocator = std.testing.allocator;
    var bh = BatchHasher.init(allocator, .blake3);
    defer bh.deinit();

    try std.testing.expect(bh.results.count() == 0);
}

test "hashToHex all zeros" {
    const hash: Hash = [_]u8{0x00} ** 32;
    var buf: [64]u8 = undefined;
    const hex = hashToHex(&hash, &buf);

    try std.testing.expectEqualStrings(
        "0000000000000000000000000000000000000000000000000000000000000000",
        hex,
    );
}

test "hashToHex all ones" {
    const hash: Hash = [_]u8{0xff} ** 32;
    var buf: [64]u8 = undefined;
    const hex = hashToHex(&hash, &buf);

    try std.testing.expectEqualStrings(
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        hex,
    );
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

test "hashFile refuses non-regular files instead of hanging or hashing empty" {
    // A FIFO is the dangerous case twice over: opened without O_NONBLOCK it
    // blocks the worker forever (observed hanging a full $HOME scan on
    // steam.pipe); opened with O_NONBLOCK but without the fstat guard it
    // reads instant EOF, hashing identically to an empty file — and every
    // special file in the scan becomes a false "duplicate" eligible for
    // deletion. Both hash algorithms must reject it. This test completing at
    // all proves the no-hang half; the expectError proves the no-false-dupe
    // half (remove the isFile() guard and it goes red with a real digest).
    const Scratch = @import("testing_scratch.zig").Scratch;
    var scratch = try Scratch.init(std.testing.allocator, "hasher-fifo");
    defer scratch.deinit();

    const fifo_path = try scratch.joinZ("pipe.fifo");
    defer std.testing.allocator.free(fifo_path);
    if (mkfifo(fifo_path, 0o600) != 0) return error.SkipZigTest;

    try std.testing.expectError(error.NotRegularFile, hashFileBlake3(fifo_path, null));
    try std.testing.expectError(error.NotRegularFile, hashFileSha256(fifo_path, null));
    try std.testing.expectError(error.NotRegularFile, hashFileBlake3(fifo_path, 4096));
}
