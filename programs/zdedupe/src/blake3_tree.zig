//! BLAKE3 by subtree: one file hashed on many threads, with the digest a plain
//! BLAKE3 hash of the whole gives.
//!
//! BLAKE3 hashes 1 KiB chunks and combines them in a binary tree whose shape
//! depends only on the input's length. A run of 2^k whole chunks that starts at
//! a multiple of 2^k chunks is a complete subtree of that tree: its chaining
//! value depends only on its bytes and its position. So a file can be cut into
//! such runs, each hashed on any thread (`Hasher.subtreeCv`), and the values
//! combined afterwards, in order, with the rest of the file (`Hasher.final`).
//!
//! std.crypto.hash.Blake3 keeps chaining values and parent nodes private, and
//! its hashParallel needs the whole input in memory plus 32 bytes per KiB of
//! it. This file implements those steps from the BLAKE3 specification
//! (unkeyed hashing only), and its tests hold every tree shape to std's digest.

const std = @import("std");
const builtin = @import("builtin");

pub const chunk_len: usize = 1024;
const block_len: usize = 64;
pub const digest_length = 32;

/// A chaining value: eight little-endian words.
pub const Cv = [8]u32;

const iv: Cv = .{ 0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19 };

const chunk_start: u32 = 1 << 0;
const chunk_end: u32 = 1 << 1;
const parent: u32 = 1 << 2;
const root: u32 = 1 << 3;

/// For each of the seven rounds, which message word feeds each G input:
/// round 0 takes them in order, each later round permutes the one before.
const schedule: [7][16]u8 = blk: {
    const permutation = [16]u8{ 2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8 };
    var s: [7][16]u8 = undefined;
    for (0..16) |i| s[0][i] = i;
    for (1..7) |r| {
        for (0..16) |i| s[r][i] = s[r - 1][permutation[i]];
    }
    break :blk s;
};

inline fn g(s: *[16]u32, comptime a: u8, comptime b: u8, comptime c: u8, comptime d: u8, mx: u32, my: u32) void {
    s[a] = s[a] +% s[b] +% mx;
    s[d] = std.math.rotr(u32, s[d] ^ s[a], 16);
    s[c] = s[c] +% s[d];
    s[b] = std.math.rotr(u32, s[b] ^ s[c], 12);
    s[a] = s[a] +% s[b] +% my;
    s[d] = std.math.rotr(u32, s[d] ^ s[a], 8);
    s[c] = s[c] +% s[d];
    s[b] = std.math.rotr(u32, s[b] ^ s[c], 7);
}

fn compress(cv: *const Cv, block: *const [16]u32, counter: u64, len: u32, flags: u32) [16]u32 {
    var s: [16]u32 = .{
        cv[0],                cv[1],                     cv[2], cv[3], cv[4], cv[5], cv[6], cv[7],
        iv[0],                iv[1],                     iv[2], iv[3],
        @truncate(counter), @truncate(counter >> 32), len,   flags,
    };
    inline for (schedule) |m| {
        g(&s, 0, 4, 8, 12, block[m[0]], block[m[1]]);
        g(&s, 1, 5, 9, 13, block[m[2]], block[m[3]]);
        g(&s, 2, 6, 10, 14, block[m[4]], block[m[5]]);
        g(&s, 3, 7, 11, 15, block[m[6]], block[m[7]]);
        g(&s, 0, 5, 10, 15, block[m[8]], block[m[9]]);
        g(&s, 1, 6, 11, 12, block[m[10]], block[m[11]]);
        g(&s, 2, 7, 8, 13, block[m[12]], block[m[13]]);
        g(&s, 3, 4, 9, 14, block[m[14]], block[m[15]]);
    }
    inline for (0..8) |i| {
        s[i] ^= s[i + 8];
        s[i + 8] ^= cv[i];
    }
    return s;
}

/// Several chunks at once, one per vector lane: the same compressions as
/// `ChunkState`, so each lane's result is that chunk's chaining value. The
/// lane count is what measured fastest per target (an M5 Max; an i7-11800H at
/// x86's baseline, with AVX2 and with AVX-512): two vector registers per word
/// where there are 32 of them (aarch64, AVX-512), one where SSE2's 16 would
/// otherwise spill.
const lanes = switch (builtin.cpu.arch) {
    .aarch64 => 8,
    .x86_64 => if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx512f))
        16
    else if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx2))
        8
    else
        4,
    else => 4,
};

/// Whether whole files hash faster here than with std.crypto.hash.Blake3: on
/// aarch64 (~3.0 against 2.15 GB/s per core, M5 Max) and with AVX-512 (4.2
/// against 3.8), not at x86's SSE2 baseline (1.6 against 1.9) or with AVX2
/// (level). hasher.zig picks by it; the subtree paths use this file anyway,
/// for what splitting a file across cores is worth.
pub const beats_std = builtin.cpu.arch == .aarch64 or
    (builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .avx512f));

const V = @Vector(lanes, u32);

inline fn gv(s: *[16]V, comptime a: u8, comptime b: u8, comptime c: u8, comptime d: u8, mx: V, my: V) void {
    s[a] = s[a] +% s[b] +% mx;
    s[d] = std.math.rotr(V, s[d] ^ s[a], 16);
    s[c] = s[c] +% s[d];
    s[b] = std.math.rotr(V, s[b] ^ s[c], 12);
    s[a] = s[a] +% s[b] +% my;
    s[d] = std.math.rotr(V, s[d] ^ s[a], 8);
    s[c] = s[c] +% s[d];
    s[b] = std.math.rotr(V, s[b] ^ s[c], 7);
}

/// Chaining values of `lanes` whole chunks, numbered from `counter`.
fn chunkCvs(input: *const [lanes * chunk_len]u8, counter: u64) [lanes]Cv {
    var cv: [8]V = undefined;
    inline for (0..8) |i| cv[i] = @splat(iv[i]);
    var lo: V = undefined;
    var hi: V = undefined;
    inline for (0..lanes) |j| {
        lo[j] = @truncate(counter + j);
        hi[j] = @truncate((counter + j) >> 32);
    }
    for (0..chunk_len / block_len) |b| {
        var m: [16]V = undefined;
        inline for (0..16) |i| {
            inline for (0..lanes) |j| m[i][j] = std.mem.readInt(u32, input[j * chunk_len + b * block_len + i * 4 ..][0..4], .little);
        }
        const flags: u32 = (if (b == 0) chunk_start else 0) | (if (b == chunk_len / block_len - 1) chunk_end else 0);
        var s: [16]V = .{
            cv[0],            cv[1],            cv[2],             cv[3],           cv[4], cv[5], cv[6], cv[7],
            @splat(iv[0]),    @splat(iv[1]),    @splat(iv[2]),     @splat(iv[3]),
            lo,               hi,               @splat(block_len), @splat(flags),
        };
        inline for (schedule) |o| {
            gv(&s, 0, 4, 8, 12, m[o[0]], m[o[1]]);
            gv(&s, 1, 5, 9, 13, m[o[2]], m[o[3]]);
            gv(&s, 2, 6, 10, 14, m[o[4]], m[o[5]]);
            gv(&s, 3, 7, 11, 15, m[o[6]], m[o[7]]);
            gv(&s, 0, 5, 10, 15, m[o[8]], m[o[9]]);
            gv(&s, 1, 6, 11, 12, m[o[10]], m[o[11]]);
            gv(&s, 2, 7, 8, 13, m[o[12]], m[o[13]]);
            gv(&s, 3, 4, 9, 14, m[o[14]], m[o[15]]);
        }
        inline for (0..8) |i| cv[i] = s[i] ^ s[i + 8];
    }
    var out: [lanes]Cv = undefined;
    inline for (0..lanes) |j| {
        inline for (0..8) |i| out[j][i] = cv[i][j];
    }
    return out;
}

fn words(bytes: *const [block_len]u8) [16]u32 {
    var w: [16]u32 = undefined;
    inline for (0..16) |i| w[i] = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
    return w;
}

/// A node not yet compressed: a chunk's last block, or a parent.
const Output = struct {
    cv: Cv,
    block: [16]u32,
    counter: u64,
    len: u32,
    flags: u32,

    fn chainingValue(self: *const Output) Cv {
        return compress(&self.cv, &self.block, self.counter, self.len, self.flags)[0..8].*;
    }

    fn rootBytes(self: *const Output) [digest_length]u8 {
        const w = compress(&self.cv, &self.block, 0, self.len, self.flags | root);
        var out: [digest_length]u8 = undefined;
        inline for (0..8) |i| std.mem.writeInt(u32, out[i * 4 ..][0..4], w[i], .little);
        return out;
    }
};

fn parentOutput(left: Cv, right: Cv) Output {
    return .{ .cv = iv, .block = left ++ right, .counter = 0, .len = block_len, .flags = parent };
}

fn parentCv(left: Cv, right: Cv) Cv {
    return parentOutput(left, right).chainingValue();
}

const ChunkState = struct {
    cv: Cv = iv,
    counter: u64,
    block: [block_len]u8 = @splat(0),
    block_used: u8 = 0,
    blocks_compressed: u8 = 0,

    fn len(self: *const ChunkState) usize {
        return @as(usize, self.blocks_compressed) * block_len + self.block_used;
    }

    fn startFlag(self: *const ChunkState) u32 {
        return if (self.blocks_compressed == 0) chunk_start else 0;
    }

    fn update(self: *ChunkState, input: []const u8) void {
        var in = input;
        while (in.len > 0) {
            // A full block is compressed only once more input arrives: the
            // chunk's last block is compressed with CHUNK_END by `output`.
            if (self.block_used == block_len) {
                self.cv = compress(&self.cv, &words(&self.block), self.counter, block_len, self.startFlag())[0..8].*;
                self.blocks_compressed += 1;
                self.block = @splat(0);
                self.block_used = 0;
            }
            const take = @min(block_len - self.block_used, in.len);
            @memcpy(self.block[self.block_used..][0..take], in[0..take]);
            self.block_used += @intCast(take);
            in = in[take..];
        }
    }

    fn output(self: *const ChunkState) Output {
        return .{ .cv = self.cv, .block = words(&self.block), .counter = self.counter, .len = self.block_used, .flags = self.startFlag() | chunk_end };
    }
};

/// Hashes a run of chunks that starts at chunk `first_chunk` of the whole
/// input. `first_chunk` must be a multiple of the largest power of two of
/// chunks the run covers, so the run's subtrees are the whole input's.
pub const Hasher = struct {
    chunk: ChunkState,
    first_chunk: u64,
    /// Chunks of this run finished and pushed below.
    pushed: u64 = 0,
    /// Chaining values of this run's finished subtrees, largest first.
    stack: [54]Cv = undefined,
    stack_len: u8 = 0,

    pub fn init(first_chunk: u64) Hasher {
        return .{ .chunk = .{ .counter = first_chunk }, .first_chunk = first_chunk };
    }

    pub fn update(self: *Hasher, input: []const u8) void {
        var in = input;
        while (in.len > 0) {
            // A full chunk is pushed only once more input arrives: the last
            // chunk may be the root (`final`), or end a subtree (`subtreeCv`).
            if (self.chunk.len() == chunk_len) {
                self.push(self.chunk.output().chainingValue());
                self.chunk = .{ .counter = self.first_chunk + self.pushed };
            }
            // Whole chunks with more input after them, `lanes` at a time.
            if (self.chunk.len() == 0 and in.len > lanes * chunk_len) {
                for (chunkCvs(in[0 .. lanes * chunk_len], self.chunk.counter)) |cv| self.push(cv);
                self.chunk = .{ .counter = self.first_chunk + self.pushed };
                in = in[lanes * chunk_len ..];
                continue;
            }
            const take = @min(chunk_len - self.chunk.len(), in.len);
            self.chunk.update(in[0..take]);
            in = in[take..];
        }
    }

    /// Merge a finished chunk in: each trailing zero of the count of chunks
    /// pushed so far closes one more subtree.
    fn push(self: *Hasher, cv: Cv) void {
        self.pushed += 1;
        var new = cv;
        var n = self.pushed;
        while (n & 1 == 0) : (n >>= 1) {
            self.stack_len -= 1;
            new = parentCv(self.stack[self.stack_len], new);
        }
        self.stack[self.stack_len] = new;
        self.stack_len += 1;
    }

    /// The chaining value of the run, which must be a whole subtree: a power
    /// of two of whole chunks.
    pub fn subtreeCv(self: *const Hasher) Cv {
        std.debug.assert(self.chunk.len() == chunk_len and std.math.isPowerOfTwo(self.pushed + 1));
        var copy = self.*;
        copy.push(copy.chunk.output().chainingValue());
        std.debug.assert(copy.stack_len == 1);
        return copy.stack[0];
    }

    /// The digest of the whole input, this run being its end. `before` holds
    /// the chaining values of the subtrees before it, in order, each of the
    /// same power of two of chunks, so this run starts at chunk
    /// `before.len * that`.
    pub fn final(self: *const Hasher, before: []const Cv) [digest_length]u8 {
        var stack: [54]Cv = undefined;
        var len: usize = 0;
        for (before, 1..) |cv, count| {
            var new = cv;
            var n = count;
            while (n & 1 == 0) : (n >>= 1) {
                len -= 1;
                new = parentCv(stack[len], new);
            }
            stack[len] = new;
            len += 1;
        }
        // This run's subtrees are all smaller than the ones before, so they
        // stack on top as they are.
        for (self.stack[0..self.stack_len]) |cv| {
            stack[len] = cv;
            len += 1;
        }
        var out = self.chunk.output();
        while (len > 0) {
            len -= 1;
            out = parentOutput(stack[len], out.chainingValue());
        }
        return out.rootBytes();
    }
};

/// std.crypto.hash.Blake3's interface (unkeyed) over `Hasher`, for code that
/// is generic over its hasher: the same digest, from the vector path.
pub const Blake3 = struct {
    pub const digest_length = 32;
    pub const Options = struct {};

    inner: Hasher = Hasher.init(0),

    pub fn init(_: Options) Blake3 {
        return .{};
    }

    pub fn update(self: *Blake3, input: []const u8) void {
        self.inner.update(input);
    }

    pub fn final(self: *const Blake3, out: []u8) void {
        const digest = self.inner.final(&.{});
        @memcpy(out[0..Blake3.digest_length], &digest);
    }
};

/// BLAKE3 of `input`, cut into runs of `run_chunks` chunks hashed one by one:
/// what a caller does across threads.
fn hashByRuns(input: []const u8, run_chunks: u64, cvs: []Cv) [digest_length]u8 {
    const run_len = run_chunks * chunk_len;
    // The last run, whole or not, is the tail.
    const runs = if (input.len == 0) 1 else std.math.divCeil(usize, input.len, run_len) catch unreachable;
    for (0..runs - 1) |r| {
        var h = Hasher.init(r * run_chunks);
        h.update(input[r * run_len ..][0..run_len]);
        cvs[r] = h.subtreeCv();
    }
    var tail = Hasher.init((runs - 1) * run_chunks);
    tail.update(input[(runs - 1) * run_len ..]);
    return tail.final(cvs[0 .. runs - 1]);
}

test "the empty input hashes to the published BLAKE3 digest" {
    var cvs: [1]Cv = undefined;
    const got = hashByRuns("", 1, &cvs);
    var want: [digest_length]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, "af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262");
    try std.testing.expectEqual(want, got);
}

test "every length up to 40 KiB, cut into runs of 1, 2, 4, 8 and 64 chunks, matches std's BLAKE3" {
    const allocator = std.testing.allocator;
    const max = 40 * 1024 + 7;
    const data = try allocator.alloc(u8, max);
    defer allocator.free(data);
    var prng = std.Random.DefaultPrng.init(0xb1a3e);
    prng.random().bytes(data);
    var cvs: [max / chunk_len + 1]Cv = undefined;
    var n: usize = 0;
    while (n <= max) : (n += if (n < 3 * chunk_len) 1 else 61) {
        var want: [digest_length]u8 = undefined;
        std.crypto.hash.Blake3.hash(data[0..n], &want, .{});
        // 64 chunks: the whole input is one run, hashed `lanes` chunks at a time.
        for ([_]u64{ 1, 2, 4, 8, 64 }) |run_chunks| {
            const got = hashByRuns(data[0..n], run_chunks, &cvs);
            if (!std.mem.eql(u8, &want, &got)) {
                std.debug.print("length {d}, runs of {d} chunks\n", .{ n, run_chunks });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "the std-shaped Blake3 gives std's digest" {
    var data: [3 * lanes * chunk_len + 77]u8 = undefined;
    for (&data, 0..) |*x, i| x.* = @truncate(i *% 7 +% 3);
    var want: [digest_length]u8 = undefined;
    std.crypto.hash.Blake3.hash(&data, &want, .{});
    var h = Blake3.init(.{});
    h.update(data[0..100]);
    h.update(data[100..]);
    var got: [digest_length]u8 = undefined;
    h.final(&got);
    try std.testing.expectEqual(want, got);
}

test "the digest does not depend on how the input is split into updates" {
    var data: [9 * chunk_len + 333]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @truncate(i *% 131 +% 17);
    var want: [digest_length]u8 = undefined;
    std.crypto.hash.Blake3.hash(&data, &want, .{});
    for ([_]usize{ 1, 7, 63, 64, 65, 1000, 1024, 1500, 4096 }) |step| {
        var h = Hasher.init(0);
        var i: usize = 0;
        while (i < data.len) : (i += step) h.update(data[i..@min(data.len, i + step)]);
        try std.testing.expectEqual(want, h.final(&.{}));
    }
}

test "a large input in 64 MiB subtrees matches std's BLAKE3" {
    // The size the scan uses (chunked.zig), and a tail that is a whole subtree.
    const allocator = std.testing.allocator;
    const run = 64 * 1024 * 1024;
    const data = try allocator.alloc(u8, 2 * run);
    defer allocator.free(data);
    var prng = std.Random.DefaultPrng.init(64);
    prng.random().bytes(data);
    var want: [digest_length]u8 = undefined;
    std.crypto.hash.Blake3.hash(data, &want, .{});
    var cvs: [2]Cv = undefined;
    try std.testing.expectEqual(want, hashByRuns(data, run / chunk_len, &cvs));
    std.crypto.hash.Blake3.hash(data[0 .. run + 12345], &want, .{});
    try std.testing.expectEqual(want, hashByRuns(data[0 .. run + 12345], run / chunk_len, &cvs));
}
