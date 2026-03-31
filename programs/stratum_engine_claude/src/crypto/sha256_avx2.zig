//! AVX2 8-way Parallel SHA-256d Implementation
//! Hashes 8 block headers simultaneously using AVX2 SIMD instructions
//!
//! Performance: ~8x faster than scalar implementation
//! Requires: AVX2 CPU support (Intel Haswell 2013+, AMD Excavator 2015+)

const std = @import("std");

/// AVX2 vector type for 8 x u32 lanes
const Vec8u32 = @Vector(8, u32);

/// SHA-256 round constants (same for all lanes)
const K = [64]u32{
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

/// Right rotate vector (each lane independently)
inline fn rotr_vec(v: Vec8u32, comptime n: u5) Vec8u32 {
    const shift_amt: u5 = @intCast(32 - @as(u32, n));
    return (v >> @splat(n)) | (v << @splat(shift_amt));
}

/// SHA-256 Ch function (vectorized)
inline fn Ch(x: Vec8u32, y: Vec8u32, z: Vec8u32) Vec8u32 {
    return (x & y) ^ (~x & z);
}

/// SHA-256 Maj function (vectorized)
inline fn Maj(x: Vec8u32, y: Vec8u32, z: Vec8u32) Vec8u32 {
    return (x & y) ^ (x & z) ^ (y & z);
}

/// SHA-256 Σ0 function (vectorized)
inline fn Sigma0(x: Vec8u32) Vec8u32 {
    return rotr_vec(x, 2) ^ rotr_vec(x, 13) ^ rotr_vec(x, 22);
}

/// SHA-256 Σ1 function (vectorized)
inline fn Sigma1(x: Vec8u32) Vec8u32 {
    return rotr_vec(x, 6) ^ rotr_vec(x, 11) ^ rotr_vec(x, 25);
}

/// SHA-256 σ0 function (vectorized)
inline fn sigma0(x: Vec8u32) Vec8u32 {
    return rotr_vec(x, 7) ^ rotr_vec(x, 18) ^ (x >> @splat(3));
}

/// SHA-256 σ1 function (vectorized)
inline fn sigma1(x: Vec8u32) Vec8u32 {
    return rotr_vec(x, 17) ^ rotr_vec(x, 19) ^ (x >> @splat(10));
}

/// Single SHA-256 compression function (8-way parallel)
fn sha256_compress_avx2(
    h: *[8]Vec8u32,
    w: *[64]Vec8u32,
) void {
    // Initialize working variables
    var a = h[0];
    var b = h[1];
    var c = h[2];
    var d = h[3];
    var e = h[4];
    var f = h[5];
    var g = h[6];
    var hh = h[7];

    // Compression rounds
    comptime var i: usize = 0;
    inline while (i < 64) : (i += 1) {
        const T1 = hh +% Sigma1(e) +% Ch(e, f, g) +% @as(Vec8u32, @splat(K[i])) +% w[i];
        const T2 = Sigma0(a) +% Maj(a, b, c);
        hh = g;
        g = f;
        f = e;
        e = d +% T1;
        d = c;
        c = b;
        b = a;
        a = T1 +% T2;
    }

    // Add to hash state
    h[0] +%= a;
    h[1] +%= b;
    h[2] +%= c;
    h[3] +%= d;
    h[4] +%= e;
    h[5] +%= f;
    h[6] +%= g;
    h[7] +%= hh;
}

/// Prepare message schedule (8-way parallel)
fn prepare_schedule_avx2(block: *[16]Vec8u32, w: *[64]Vec8u32) void {
    // Copy first 16 words
    comptime var i: usize = 0;
    inline while (i < 16) : (i += 1) {
        w[i] = block[i];
    }

    // Expand to 64 words
    inline while (i < 64) : (i += 1) {
        w[i] = w[i - 16] +% sigma0(w[i - 15]) +% w[i - 7] +% sigma1(w[i - 2]);
    }
}

/// Load first block (bytes 0-63) of 8 headers into AVX2 format
fn load_block1_avx2(headers: *const [8][80]u8, block: *[16]Vec8u32) void {
    for (0..16) |word| {
        const offset = word * 4;
        var temp: [8]u32 = undefined;
        for (0..8) |lane| {
            const bytes = headers[lane][offset..][0..4];
            temp[lane] = std.mem.readInt(u32, bytes, .big);
        }
        block[word] = temp;
    }
}

/// Load second block (bytes 64-79 + padding) of 8 headers into AVX2 format
/// Block 2 layout: bytes 64-79 (4 words) + 0x80 padding + zeros + length (0x280 = 640 bits)
fn load_block2_avx2(headers: *const [8][80]u8, block: *[16]Vec8u32) void {
    // Words 0-3: bytes 64-79 of each header (includes nonce at 76-79!)
    for (0..4) |word| {
        const offset = 64 + word * 4;
        var temp: [8]u32 = undefined;
        for (0..8) |lane| {
            const bytes = headers[lane][offset..][0..4];
            temp[lane] = std.mem.readInt(u32, bytes, .big);
        }
        block[word] = temp;
    }

    // Word 4: padding start (0x80 followed by zeros)
    block[4] = @splat(0x80000000);

    // Words 5-14: zeros
    for (5..15) |word| {
        block[word] = @splat(0);
    }

    // Word 15: length in bits (80 * 8 = 640 = 0x280)
    block[15] = @splat(0x00000280);
}

/// Load 32-byte hash results for second SHA256 pass (with padding)
fn load_hash_block_avx2(intermediate: *const [8][32]u8, block: *[16]Vec8u32) void {
    // Words 0-7: the 32-byte intermediate hash
    for (0..8) |word| {
        const offset = word * 4;
        var temp: [8]u32 = undefined;
        for (0..8) |lane| {
            const bytes = intermediate[lane][offset..][0..4];
            temp[lane] = std.mem.readInt(u32, bytes, .big);
        }
        block[word] = temp;
    }

    // Word 8: padding start
    block[8] = @splat(0x80000000);

    // Words 9-14: zeros
    for (9..15) |word| {
        block[word] = @splat(0);
    }

    // Word 15: length in bits (32 * 8 = 256 = 0x100)
    block[15] = @splat(0x00000100);
}

/// Store 8 hashes from AVX2 format (de-transposed)
fn store_hashes_avx2(h: *const [8]Vec8u32, hashes: *[8][32]u8) void {
    for (0..8) |word| {
        const vec: [8]u32 = h[word];
        for (0..8) |lane| {
            const offset = word * 4;
            std.mem.writeInt(u32, hashes[lane][offset..][0..4], vec[lane], .big);
        }
    }
}

/// SHA-256 IV (initial hash values)
const H_INIT: [8]Vec8u32 = .{
    @splat(0x6a09e667),
    @splat(0xbb67ae85),
    @splat(0x3c6ef372),
    @splat(0xa54ff53a),
    @splat(0x510e527f),
    @splat(0x9b05688c),
    @splat(0x1f83d9ab),
    @splat(0x5be0cd19),
};

/// SHA-256 of 80-byte input (8-way parallel, proper 2-block processing)
pub fn sha256_x8(headers: *const [8][80]u8, hashes: *[8][32]u8) void {
    // Initialize state with IV
    var h: [8]Vec8u32 = H_INIT;
    var w: [64]Vec8u32 = undefined;
    var block: [16]Vec8u32 = undefined;

    // Block 1: bytes 0-63
    load_block1_avx2(headers, &block);
    prepare_schedule_avx2(&block, &w);
    sha256_compress_avx2(&h, &w);

    // Block 2: bytes 64-79 + padding (NONCE IS HERE!)
    load_block2_avx2(headers, &block);
    prepare_schedule_avx2(&block, &w);
    sha256_compress_avx2(&h, &w);

    // Store first SHA-256 result
    store_hashes_avx2(&h, hashes);
}

/// Double SHA-256 (8-way parallel) - Bitcoin mining hash
/// SHA256d(x) = SHA256(SHA256(x))
pub fn sha256d_x8(headers: *const [8][80]u8, hashes: *[8][32]u8) void {
    // First SHA-256: hash 80-byte headers (2 blocks)
    var intermediate: [8][32]u8 = undefined;
    sha256_x8(headers, &intermediate);

    // Second SHA-256: hash 32-byte results (1 block with padding)
    var h: [8]Vec8u32 = H_INIT;
    var w: [64]Vec8u32 = undefined;
    var block: [16]Vec8u32 = undefined;

    load_hash_block_avx2(&intermediate, &block);
    prepare_schedule_avx2(&block, &w);
    sha256_compress_avx2(&h, &w);

    store_hashes_avx2(&h, hashes);
}

test "avx2 single hash matches scalar" {
    const sha256d = @import("sha256d.zig");
    const testing = std.testing;

    // Test input
    const input = [_]u8{0} ** 80;

    // Scalar reference
    var expected: [32]u8 = undefined;
    sha256d.sha256d(&input, &expected);

    // AVX2 version (all 8 lanes same input)
    var headers: [8][80]u8 = undefined;
    for (0..8) |i| {
        @memcpy(&headers[i], &input);
    }

    var hashes: [8][32]u8 = undefined;
    sha256d_x8(&headers, &hashes);

    // All 8 outputs should match scalar
    for (0..8) |i| {
        try testing.expectEqualSlices(u8, &expected, &hashes[i]);
    }
}
