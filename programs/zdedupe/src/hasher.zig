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
const libc = @import("sys.zig").c;

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
    /// Polled between reads; a cancelled hash returns `error.Cancelled`.
    /// Bytes read are added to its `bytes_done` (see `hashForScanAt`).
    monitor: ?*types.Monitor = null,

    pub fn init(algorithm: types.Config.HashAlgorithm) FileHasher {
        return .{ .algorithm = algorithm };
    }

    /// Hash entire file
    pub fn hashFile(self: *const FileHasher, path: []const u8) !Hash {
        return self.hashFileLimited(path, null);
    }

    /// Hash the file `name` inside the open directory `dir_fd`.
    pub fn hashFileAt(self: *const FileHasher, dir_fd: c_int, name: [*:0]const u8) !Hash {
        return self.hashAtLimited(dir_fd, name, null);
    }

    /// Quick hash of the file `name` inside the open directory `dir_fd`.
    pub fn hashFileQuickAt(self: *const FileHasher, dir_fd: c_int, name: [*:0]const u8, max_bytes: usize) !Hash {
        return self.hashAtLimited(dir_fd, name, max_bytes);
    }

    fn hashAtLimited(self: *const FileHasher, dir_fd: c_int, name: [*:0]const u8, max_bytes: ?usize) !Hash {
        const fd = try openRegularFileAt(dir_fd, name);
        defer _ = libc.close(fd);
        return switch (self.algorithm) {
            .blake3 => hashFd(std.crypto.hash.Blake3, fd, max_bytes, self.monitor, 0),
            .sha256 => hashFd(std.crypto.hash.sha2.Sha256, fd, max_bytes, self.monitor, 0),
        };
    }

    /// The two reads a duplicate scan makes of a candidate, of the file
    /// `name` in `dir_fd` (or `AT_FDCWD` and an absolute path). `size` is
    /// the size the walk saw. `budget` is this file's share of the phase's
    /// `Monitor.bytes_total` (`probeBytes` / `FileEntry.readBytes`):
    /// `bytes_done` advances by what is read, capped at the share, and is
    /// topped up to it when the file is done, so the phase ends exactly at
    /// its total however the file turned out.
    pub fn hashForScanAt(self: *const FileHasher, dir_fd: c_int, name: [*:0]const u8, read: ScanRead, size: u64, budget: u64) !Hash {
        const fd = try openRegularFileAt(dir_fd, name);
        defer _ = libc.close(fd);
        return switch (self.algorithm) {
            .blake3 => scanFd(std.crypto.hash.Blake3, fd, read, size, self.monitor, budget),
            .sha256 => scanFd(std.crypto.hash.sha2.Sha256, fd, read, size, self.monitor, budget),
        };
    }

    /// `hashForScanAt` by absolute path.
    pub fn hashForScan(self: *const FileHasher, path: []const u8, read: ScanRead, size: u64, budget: u64) !Hash {
        var path_buf: [4096]u8 = undefined;
        if (path.len >= path_buf.len) return error.PathTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        return self.hashForScanAt(AT_FDCWD, @ptrCast(&path_buf), read, size, budget);
    }

    /// Hash first N bytes of file (quick hash for fast rejection)
    pub fn hashFileQuick(self: *const FileHasher, path: []const u8, max_bytes: usize) !Hash {
        return self.hashFileLimited(path, max_bytes);
    }

    fn hashFileLimited(self: *const FileHasher, path: []const u8, max_bytes: ?usize) !Hash {
        return switch (self.algorithm) {
            .blake3 => hashFileWith(std.crypto.hash.Blake3, path, max_bytes, self.monitor),
            .sha256 => hashFileWith(std.crypto.hash.sha2.Sha256, path, max_bytes, self.monitor),
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

    return openRegularFileAt(AT_FDCWD, path_z);
}

const AT_FDCWD: c_int = if (builtin.os.tag.isDarwin()) -2 else -100;

/// `openRegularFile` relative to an open directory: the kernel resolves one
/// name instead of every component of an absolute path. On a scan of millions
/// of files the vnode cache cannot hold the tree, so each of those components
/// is a real lookup - this is what keeps hashing fast at scale.
pub fn openRegularFileAt(dir_fd: c_int, name: [*:0]const u8) !c_int {
    const fd = libc.openat(dir_fd, name, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, @as(libc.mode_t, 0));
    if (fd < 0) return error.CannotOpenFile;
    errdefer _ = libc.close(fd);

    const st = pstat.fstat(fd) catch return error.CannotOpenFile;
    if (!st.isFile()) return error.NotRegularFile;
    return fd;
}

/// Hash file using BLAKE3 (fastest, cryptographically secure)
pub fn hashFileBlake3(path: []const u8, max_bytes: ?usize) !Hash {
    return hashFileWith(std.crypto.hash.Blake3, path, max_bytes, null);
}

/// Hash file using SHA256
pub fn hashFileSha256(path: []const u8, max_bytes: ?usize) !Hash {
    return hashFileWith(std.crypto.hash.sha2.Sha256, path, max_bytes, null);
}

/// The one file-reading hash loop. `monitor`, when given, is polled between
/// reads so cancelling does not have to wait out a multi-gigabyte file.
fn hashFileWith(comptime Hasher: type, path: []const u8, max_bytes: ?usize, monitor: ?*types.Monitor) !Hash {
    const fd = try openRegularFile(path);
    defer _ = libc.close(fd);
    return hashFd(Hasher, fd, max_bytes, monitor, 0);
}

pub const ScanRead = enum {
    /// Cheap rejection: the first `DEFAULT_QUICK_HASH_SIZE` bytes, plus, for
    /// a file of `probe_sample_min` or more, `probeSamples` blocks spread
    /// over the rest. Big files of one size (disk images, VM bundles) tend to
    /// share their first block; without samples each such pair is read
    /// whole before it turns out to differ.
    probe,
    /// The whole content, by data extents (see `feedSparse`).
    full,
};

pub const probe_sample_min: u64 = 64 * 1024 * 1024;
/// One sample per this many bytes, between 15 and 4096 samples: a 64 GiB
/// image gets 1024 (4 MiB of reads), enough to catch two VM images of one
/// size that differ in scattered places, as installs of two OS versions do.
pub const probe_stride: u64 = 64 * 1024 * 1024;

pub fn probeSamples(size: u64) u64 {
    return std.math.clamp(size / probe_stride, 15, 4096);
}

/// Bytes `ScanRead.probe` reads from a file of `size`.
pub fn probeBytes(size: u64) u64 {
    const prefix: u64 = DEFAULT_QUICK_HASH_SIZE;
    if (size < probe_sample_min) return @min(size, prefix);
    return prefix * (1 + probeSamples(size));
}

fn scanFd(comptime Hasher: type, fd: c_int, read: ScanRead, size: u64, monitor: ?*types.Monitor, budget_bytes: u64) !Hash {
    switch (read) {
        .full => return hashFd(Hasher, fd, null, monitor, budget_bytes),
        .probe => {
            if (size < probe_sample_min) return hashFd(Hasher, fd, DEFAULT_QUICK_HASH_SIZE, monitor, budget_bytes);
            var budget: Budget = .{ .monitor = monitor, .left = budget_bytes };
            defer budget.finish();
            var hasher = Hasher.init(.{});
            var buf: [DEFAULT_QUICK_HASH_SIZE]u8 = undefined;
            const last = size - buf.len;
            var k: u64 = 0;
            const samples = probeSamples(size);
            while (k <= samples) : (k += 1) {
                if (monitor) |m| if (m.cancelled()) return error.Cancelled;
                // Block-aligned, so a sample never straddles two extents.
                const offset = (last / samples * k) & ~@as(u64, buf.len - 1);
                const n = try preadAll(fd, &buf, offset);
                hasher.update(std.mem.asBytes(&offset));
                hasher.update(buf[0..n]);
                budget.add(n);
            }
            var result: Hash = undefined;
            hasher.final(&result);
            return result;
        },
    }
}

/// Fill `buf` from `offset`, short only at end of file.
fn preadAll(fd: c_int, buf: []u8, offset: u64) !usize {
    var got: usize = 0;
    while (got < buf.len) {
        const n = libc.pread(fd, buf[got..].ptr, buf.len - got, @intCast(offset + got));
        if (n == 0) break;
        if (n < 0) {
            if (libc.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }
        got += @intCast(n);
    }
    return got;
}

/// One file's share of a phase's byte progress; see `hashForScanAt`.
const Budget = struct {
    monitor: ?*types.Monitor,
    left: u64,

    fn add(self: *Budget, n: u64) void {
        const take = @min(n, self.left);
        if (take == 0) return;
        self.left -= take;
        if (self.monitor) |m| m.addBytes(take);
    }

    fn finish(self: *Budget) void {
        self.add(self.left);
    }
};

// lseek whence values for extent queries; Darwin and Linux number them oppositely.
const SEEK_HOLE: c_int = if (builtin.os.tag.isDarwin()) 3 else 4;
const SEEK_DATA: c_int = if (builtin.os.tag.isDarwin()) 4 else 3;
const holes_reported = builtin.os.tag.isDarwin() or is_linux;

/// All zeros, fed for holes.
const zero_block: [BUFFER_SIZE]u8 = @splat(0);

/// Feed the whole content of `fd` to `hasher`, reading only its data extents:
/// a hole reads back as zeros, so zeros are fed for it without a read. The
/// digest is the one a plain read gives - a sparse file and its dense copy
/// hash the same - but a mostly empty disk image costs what is on disk, not
/// its nominal size, in I/O. Returns false, having fed nothing, when the
/// filesystem does not answer extent queries; the caller then reads plainly.
fn feedSparse(comptime Hasher: type, hasher: *Hasher, fd: c_int, monitor: ?*types.Monitor, budget: *Budget) !bool {
    if (comptime !holes_reported) return false;
    var buf: [BUFFER_SIZE]u8 = undefined;
    var pos: i64 = 0;
    var fed = false;
    while (true) {
        if (monitor) |m| if (m.cancelled()) return error.Cancelled;
        const data = libc.lseek(fd, pos, SEEK_DATA);
        if (data < 0) switch (libc.errno(data)) {
            .INTR => continue,
            // Nothing but hole from `pos` to the end of the file.
            .NXIO => {
                const st = pstat.fstat(fd) catch return error.ReadFailed;
                if (st.size > pos) try feedZeros(Hasher, hasher, st.size - @as(u64, @intCast(pos)), monitor);
                return true;
            },
            else => return if (fed) error.ReadFailed else false,
        };
        if (data > pos) {
            try feedZeros(Hasher, hasher, @intCast(data - pos), monitor);
            fed = true;
        }
        const hole = libc.lseek(fd, data, SEEK_HOLE);
        if (hole < data) return if (fed) error.ReadFailed else false;

        var offset = data;
        while (offset < hole) {
            if (monitor) |m| if (m.cancelled()) return error.Cancelled;
            const want: usize = @intCast(@min(@as(i64, buf.len), hole - offset));
            const n = libc.pread(fd, &buf, want, offset);
            // The file shrank under us: hash what is there, as a plain read would.
            if (n == 0) return true;
            if (n < 0) {
                if (libc.errno(n) == .INTR) continue;
                return error.ReadFailed;
            }
            const got: usize = @intCast(n);
            hasher.update(buf[0..got]);
            budget.add(got);
            offset += n;
            fed = true;
        }
        pos = hole;
    }
}

fn feedZeros(comptime Hasher: type, hasher: *Hasher, len: u64, monitor: ?*types.Monitor) !void {
    var left = len;
    while (left > 0) {
        if (monitor) |m| if (m.cancelled()) return error.Cancelled;
        const n: usize = @intCast(@min(left, zero_block.len));
        hasher.update(zero_block[0..n]);
        left -= n;
    }
}

fn hashFd(comptime Hasher: type, fd: c_int, max_bytes: ?usize, monitor: ?*types.Monitor, budget_bytes: u64) !Hash {
    var budget: Budget = .{ .monitor = monitor, .left = budget_bytes };
    defer budget.finish();
    var hasher = Hasher.init(.{});
    // A whole file is read by its data extents; holes are fed as zeros.
    if (max_bytes == null and try feedSparse(Hasher, &hasher, fd, monitor, &budget)) {
        var result: Hash = undefined;
        hasher.final(&result);
        return result;
    }
    var buf: [BUFFER_SIZE]u8 = undefined;
    var total_read: usize = 0;

    while (true) {
        // Check if we've read enough for quick hash
        if (max_bytes) |max| {
            if (total_read >= max) break;
        }
        if (monitor) |m| {
            if (m.cancelled()) return error.Cancelled;
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
        budget.add(bytes_read);
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

/// FIFOs are a POSIX thing; the test below skips on Windows.
const mkfifo = if (@import("builtin").os.tag == .windows) undefined else struct {
    extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;
}.mkfifo;

test "hashFile refuses non-regular files instead of hanging or hashing empty" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
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

test "a sparse file hashes like its dense copy, and like its bytes" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const Scratch = @import("testing_scratch.zig").Scratch;
    const allocator = std.testing.allocator;
    var scratch = try Scratch.init(allocator, "hasher-sparse");
    defer scratch.deinit();

    // Data at the start, in the middle across a block boundary, and in the
    // last partial block; holes between, and none at the very end.
    const size: u64 = 3 * 1024 * 1024 + 123;
    const head = [_]u8{'a'} ** 4096;
    const middle = [_]u8{'b'} ** 5000;
    const tail = [_]u8{'c'} ** 100;
    const extents = [_]Scratch.Extent{
        .{ .offset = 0, .data = &head },
        .{ .offset = 1024 * 1024 + 2048, .data = &middle },
        .{ .offset = size - tail.len, .data = &tail },
    };
    const content = try allocator.alloc(u8, size);
    defer allocator.free(content);
    @memset(content, 0);
    for (extents) |e| @memcpy(content[e.offset..][0..e.data.len], e.data);

    try scratch.writeSparse("sparse.img", size, &extents);
    try scratch.writeFile("dense.img", content);
    // Nothing but a hole, and a hole up to one block at the end.
    try scratch.writeSparse("empty.img", size, &.{});
    try scratch.writeSparse("late.img", size, &.{.{ .offset = size - tail.len, .data = &tail }});

    const sparse = try scratch.join("sparse.img");
    defer allocator.free(sparse);
    const dense = try scratch.join("dense.img");
    defer allocator.free(dense);
    const empty = try scratch.join("empty.img");
    defer allocator.free(empty);
    const late = try scratch.join("late.img");
    defer allocator.free(late);

    const want = hashBytesBlake3(content);
    try std.testing.expectEqual(want, try hashFileBlake3(sparse, null));
    try std.testing.expectEqual(want, try hashFileBlake3(dense, null));
    try std.testing.expectEqual(hashBytesSha256(content), try hashFileSha256(sparse, null));

    @memset(content, 0);
    try std.testing.expectEqual(hashBytesBlake3(content), try hashFileBlake3(empty, null));
    @memcpy(content[size - tail.len ..], &tail);
    try std.testing.expectEqual(hashBytesBlake3(content), try hashFileBlake3(late, null));
}

test "the probe tells big same-size files apart past their first block, and agrees on copies" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const Scratch = @import("testing_scratch.zig").Scratch;
    const allocator = std.testing.allocator;
    var scratch = try Scratch.init(allocator, "hasher-probe");
    defer scratch.deinit();

    // Two disk images with the same header, differing at the 7th sample.
    const size: u64 = probe_sample_min + 8 * 1024 * 1024;
    const header = [_]u8{'h'} ** 4096;
    const sampled = ((size - 4096) / probeSamples(size) * 7) & ~@as(u64, 4095);
    const one = [_]u8{'1'} ** 4096;
    const two = [_]u8{'2'} ** 4096;
    try scratch.writeSparse("a.img", size, &.{ .{ .offset = 0, .data = &header }, .{ .offset = sampled, .data = &one } });
    try scratch.writeSparse("b.img", size, &.{ .{ .offset = 0, .data = &header }, .{ .offset = sampled, .data = &two } });
    try scratch.writeSparse("a-copy.img", size, &.{ .{ .offset = 0, .data = &header }, .{ .offset = sampled, .data = &one } });

    const h = FileHasher.init(.blake3);
    var probes: [3]Hash = undefined;
    for ([_][]const u8{ "a.img", "b.img", "a-copy.img" }, &probes) |name, *probe| {
        const path = try scratch.join(name);
        defer allocator.free(path);
        probe.* = try h.hashForScan(path, .probe, size, probeBytes(size));
    }
    try std.testing.expect(!std.mem.eql(u8, &probes[0], &probes[1]));
    try std.testing.expectEqual(probes[0], probes[2]);

    // Below the threshold the probe is the plain 4 KiB prefix hash.
    try scratch.writeFile("small", &header);
    const small = try scratch.join("small");
    defer allocator.free(small);
    try std.testing.expectEqual(try h.hashFileQuick(small, 4096), try h.hashForScan(small, .probe, header.len, probeBytes(header.len)));
}

test "byte progress lands exactly on each file's share" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const Scratch = @import("testing_scratch.zig").Scratch;
    const allocator = std.testing.allocator;
    var scratch = try Scratch.init(allocator, "hasher-bytes");
    defer scratch.deinit();

    const data = [_]u8{'d'} ** 10_000;
    try scratch.writeSparse("f", 1024 * 1024, &.{.{ .offset = 0, .data = &data }});
    const path = try scratch.join("f");
    defer allocator.free(path);

    var monitor: types.Monitor = .{};
    var h = FileHasher.init(.blake3);
    h.monitor = &monitor;
    // A share smaller than what is read (a compressed file reads more than
    // it allocates) and one larger (the file shrank): either way, exact.
    _ = try h.hashForScan(path, .full, 1024 * 1024, 4096);
    try std.testing.expectEqual(@as(u64, 4096), monitor.bytes_done.load(.acquire));
    _ = try h.hashForScan(path, .full, 1024 * 1024, 1_000_000);
    try std.testing.expectEqual(@as(u64, 1_004_096), monitor.bytes_done.load(.acquire));
}
