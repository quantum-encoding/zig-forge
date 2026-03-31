//! AVX-512 16-way Parallel SHA-256d with Midstate Optimization
//!
//! Uses pre-computed midstate to skip Block 1 processing.
//! Each batch hashes 16 different nonces in parallel.
//!
//! Optimizations:
//! 1. Midstate: Skip Block 1 (64 rounds saved per hash)
//! 2. Double-hash schedule: Pre-compute words 8-15 (constant padding)
//!
//! Performance: ~50% faster than full 2-block SIMD

const std = @import("std");
const midstate_scalar = @import("sha256_midstate.zig");

/// AVX-512 vector type for 16 x u32 lanes
const Vec16u32 = @Vector(16, u32);

/// SHA-256 round constants
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

/// SHA-256 IV
const H_INIT: [8]Vec16u32 = .{
    @splat(0x6a09e667),
    @splat(0xbb67ae85),
    @splat(0x3c6ef372),
    @splat(0xa54ff53a),
    @splat(0x510e527f),
    @splat(0x9b05688c),
    @splat(0x1f83d9ab),
    @splat(0x5be0cd19),
};

/// Pre-computed double-hash padding block (words 8-15)
/// Word 8: 0x80000000, Words 9-14: 0, Word 15: 0x00000100
const DOUBLE_HASH_PADDING: [8]Vec16u32 = .{
    @splat(0x80000000), // word 8
    @splat(0),          // word 9
    @splat(0),          // word 10
    @splat(0),          // word 11
    @splat(0),          // word 12
    @splat(0),          // word 13
    @splat(0),          // word 14
    @splat(0x00000100), // word 15
};

inline fn rotr_vec(v: Vec16u32, comptime n: u5) Vec16u32 {
    const shift_right: u5 = n;
    const shift_left: u5 = 32 - @as(u6, n);
    return (v >> @splat(shift_right)) | (v << @splat(shift_left));
}

inline fn Ch(x: Vec16u32, y: Vec16u32, z: Vec16u32) Vec16u32 {
    return (x & y) ^ (~x & z);
}

inline fn Maj(x: Vec16u32, y: Vec16u32, z: Vec16u32) Vec16u32 {
    return (x & y) ^ (x & z) ^ (y & z);
}

inline fn Sigma0(x: Vec16u32) Vec16u32 {
    return rotr_vec(x, 2) ^ rotr_vec(x, 13) ^ rotr_vec(x, 22);
}

inline fn Sigma1(x: Vec16u32) Vec16u32 {
    return rotr_vec(x, 6) ^ rotr_vec(x, 11) ^ rotr_vec(x, 25);
}

inline fn sigma0(x: Vec16u32) Vec16u32 {
    return rotr_vec(x, 7) ^ rotr_vec(x, 18) ^ (x >> @splat(3));
}

inline fn sigma1(x: Vec16u32) Vec16u32 {
    return rotr_vec(x, 17) ^ rotr_vec(x, 19) ^ (x >> @splat(10));
}

/// SHA-256 compression (16-way parallel)
fn sha256_compress(h: *[8]Vec16u32, w: *const [64]Vec16u32) void {
    var a = h[0];
    var b = h[1];
    var c = h[2];
    var d = h[3];
    var e = h[4];
    var f = h[5];
    var g = h[6];
    var hh = h[7];

    comptime var i: usize = 0;
    inline while (i < 64) : (i += 1) {
        const T1 = hh +% Sigma1(e) +% Ch(e, f, g) +% @as(Vec16u32, @splat(K[i])) +% w[i];
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

    h[0] +%= a;
    h[1] +%= b;
    h[2] +%= c;
    h[3] +%= d;
    h[4] +%= e;
    h[5] +%= f;
    h[6] +%= g;
    h[7] +%= hh;
}

/// Prepare message schedule (16-way parallel)
fn prepare_schedule(block: *const [16]Vec16u32, w: *[64]Vec16u32) void {
    comptime var i: usize = 0;
    inline while (i < 16) : (i += 1) {
        w[i] = block[i];
    }
    inline while (i < 64) : (i += 1) {
        w[i] = w[i - 16] +% sigma0(w[i - 15]) +% w[i - 7] +% sigma1(w[i - 2]);
    }
}

/// Store 16 hashes from vectorized state
fn store_hashes(h: *const [8]Vec16u32, hashes: *[16][32]u8) void {
    for (0..8) |word| {
        const vec: [16]u32 = h[word];
        for (0..16) |lane| {
            std.mem.writeInt(u32, hashes[lane][word * 4 ..][0..4], vec[lane], .big);
        }
    }
}

/// Hash 16 nonces in parallel using precomputed midstate
pub fn hashBatchWithMidstate(
    midstate: *const midstate_scalar.Midstate,
    base_nonce: u32,
    hashes_out: *[16][32]u8,
) void {
    // Load midstate into vectors (same value across all lanes)
    var state: [8]Vec16u32 = undefined;
    for (0..8) |i| {
        state[i] = @splat(midstate.state[i]);
    }

    // Prepare Block 2 with 16 different nonces
    var block2: [16]Vec16u32 = undefined;

    // Words 0-2: same for all lanes (merkle_end, time, nbits from template)
    for (0..3) |word| {
        const offset = word * 4;
        const val = std.mem.readInt(u32, midstate.block2_template[offset..][0..4], .big);
        block2[word] = @splat(val);
    }

    // Word 3: NONCE - different for each lane!
    var nonce_vec: [16]u32 = undefined;
    for (0..16) |lane| {
        const nonce = base_nonce +% @as(u32, @intCast(lane));
        // Nonce is stored little-endian in the header but read big-endian for SHA256
        nonce_vec[lane] = @byteSwap(nonce);
    }
    block2[3] = nonce_vec;

    // Word 4: padding (0x80000000)
    block2[4] = @splat(0x80000000);

    // Words 5-14: zeros
    for (5..15) |word| {
        block2[word] = @splat(0);
    }

    // Word 15: length (640 bits = 0x00000280)
    block2[15] = @splat(0x00000280);

    // Compress Block 2
    var w: [64]Vec16u32 = undefined;
    prepare_schedule(&block2, &w);
    sha256_compress(&state, &w);

    // First SHA256 complete - state contains the intermediate hash
    // Double hash: SHA256 of the intermediate hash (32 bytes)
    // Optimization: Keep hash in vectors, avoid byte conversion
    var double_block: [16]Vec16u32 = undefined;

    // Words 0-7: The intermediate hash (already in big-endian vector form)
    inline for (0..8) |i| {
        double_block[i] = state[i];
    }

    // Words 8-15: Pre-computed constant padding
    inline for (0..8) |i| {
        double_block[8 + i] = DOUBLE_HASH_PADDING[i];
    }

    // Reset state to IV for double hash
    state = H_INIT;

    prepare_schedule(&double_block, &w);
    sha256_compress(&state, &w);

    store_hashes(&state, hashes_out);
}

test "avx512 midstate matches scalar" {
    const testing = std.testing;

    // Create test header
    var header: [80]u8 = undefined;
    for (0..80) |i| {
        header[i] = @intCast(i * 7 % 256);
    }

    // Compute midstate
    const midstate = midstate_scalar.Midstate.init(&header);

    // Test batch of 16 nonces
    const base_nonce: u32 = 1000;
    var simd_hashes: [16][32]u8 = undefined;
    hashBatchWithMidstate(&midstate, base_nonce, &simd_hashes);

    // Compare each lane with scalar
    for (0..16) |lane| {
        const nonce = base_nonce + @as(u32, @intCast(lane));
        var scalar_hash: [32]u8 = undefined;
        midstate.hash(nonce, &scalar_hash);

        try testing.expectEqualSlices(u8, &scalar_hash, &simd_hashes[lane]);
    }
}
