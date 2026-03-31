//! SHA-256 Midstate Optimization for Bitcoin Mining
//!
//! The Bitcoin header is 80 bytes, requiring 2 SHA256 blocks:
//! - Block 1: bytes 0-63 (version, prevhash, partial merkle) - CONSTANT per job
//! - Block 2: bytes 64-79 + padding (merkle end, time, nbits, NONCE) - varies
//!
//! By pre-computing the SHA256 state after Block 1, we skip 64 rounds per hash.
//! This gives ~33% speedup for SHA256d mining.

const std = @import("std");

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

/// SHA-256 initial hash values
const H_INIT = [8]u32{
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
};

inline fn rotr(x: u32, comptime n: u5) u32 {
    return (x >> n) | (x << @as(u5, 32 - @as(u6, n)));
}

inline fn ch(x: u32, y: u32, z: u32) u32 {
    return (x & y) ^ (~x & z);
}

inline fn maj(x: u32, y: u32, z: u32) u32 {
    return (x & y) ^ (x & z) ^ (y & z);
}

inline fn sigma0(x: u32) u32 {
    return rotr(x, 2) ^ rotr(x, 13) ^ rotr(x, 22);
}

inline fn sigma1(x: u32) u32 {
    return rotr(x, 6) ^ rotr(x, 11) ^ rotr(x, 25);
}

inline fn s0(x: u32) u32 {
    return rotr(x, 7) ^ rotr(x, 18) ^ (x >> 3);
}

inline fn s1(x: u32) u32 {
    return rotr(x, 17) ^ rotr(x, 19) ^ (x >> 10);
}

/// Prepare message schedule from 64-byte block
fn prepareMessageSchedule(block: *const [64]u8, w: *[64]u32) void {
    // Parse block into 16 big-endian u32s
    for (0..16) |i| {
        w[i] = std.mem.readInt(u32, block[i * 4 ..][0..4], .big);
    }

    // Extend to 64 words
    for (16..64) |i| {
        w[i] = w[i - 16] +% s0(w[i - 15]) +% w[i - 7] +% s1(w[i - 2]);
    }
}

/// SHA-256 compression function
fn sha256Compress(state: *[8]u32, w: *const [64]u32) void {
    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];
    var e = state[4];
    var f = state[5];
    var g = state[6];
    var h = state[7];

    for (0..64) |i| {
        const t1 = h +% sigma1(e) +% ch(e, f, g) +% K[i] +% w[i];
        const t2 = sigma0(a) +% maj(a, b, c);
        h = g;
        g = f;
        f = e;
        e = d +% t1;
        d = c;
        c = b;
        b = a;
        a = t1 +% t2;
    }

    state[0] +%= a;
    state[1] +%= b;
    state[2] +%= c;
    state[3] +%= d;
    state[4] +%= e;
    state[5] +%= f;
    state[6] +%= g;
    state[7] +%= h;
}

/// Midstate: pre-computed SHA256 state after Block 1
pub const Midstate = struct {
    /// SHA256 state after compressing Block 1 (bytes 0-63)
    state: [8]u32,

    /// Block 2 template with padding (nonce at offset 12)
    /// Layout: [merkle_end:4][time:4][nbits:4][nonce:4][0x80][zeros][0x0280]
    block2_template: [64]u8,

    /// Compute midstate from 80-byte header (call once per job)
    pub fn init(header: *const [80]u8) Midstate {
        // Start with SHA256 IV
        var state = H_INIT;

        // Compress Block 1 (bytes 0-63)
        var w: [64]u32 = undefined;
        prepareMessageSchedule(header[0..64], &w);
        sha256Compress(&state, &w);

        // Prepare Block 2 template
        var block2: [64]u8 = [_]u8{0} ** 64;
        @memcpy(block2[0..16], header[64..80]); // Last 16 bytes of header
        block2[16] = 0x80; // Padding start
        // Length in bits: 80 * 8 = 640 = 0x0280 (big-endian at end)
        block2[62] = 0x02;
        block2[63] = 0x80;

        return .{
            .state = state,
            .block2_template = block2,
        };
    }

    /// Hash with precomputed midstate (call for each nonce)
    pub fn hash(self: *const Midstate, nonce: u32, hash_out: *[32]u8) void {
        // Copy midstate
        var state = self.state;

        // Copy block2 template and insert nonce at offset 12 (little-endian)
        var block2 = self.block2_template;
        block2[12] = @intCast(nonce & 0xFF);
        block2[13] = @intCast((nonce >> 8) & 0xFF);
        block2[14] = @intCast((nonce >> 16) & 0xFF);
        block2[15] = @intCast((nonce >> 24) & 0xFF);

        // Compress Block 2
        var w: [64]u32 = undefined;
        prepareMessageSchedule(&block2, &w);
        sha256Compress(&state, &w);

        // First SHA256 complete - serialize state to bytes
        var first_hash: [32]u8 = undefined;
        for (0..8) |i| {
            std.mem.writeInt(u32, first_hash[i * 4 ..][0..4], state[i], .big);
        }

        // Double hash: SHA256 of first_hash
        state = H_INIT;

        // Prepare 32-byte message with padding
        var double_block: [64]u8 = [_]u8{0} ** 64;
        @memcpy(double_block[0..32], &first_hash);
        double_block[32] = 0x80; // Padding
        // Length: 32 * 8 = 256 = 0x0100 (big-endian at end)
        double_block[62] = 0x01;
        double_block[63] = 0x00;

        prepareMessageSchedule(&double_block, &w);
        sha256Compress(&state, &w);

        // Output final hash
        for (0..8) |i| {
            std.mem.writeInt(u32, hash_out[i * 4 ..][0..4], state[i], .big);
        }
    }
};

test "midstate matches full sha256d" {
    const sha256d = @import("sha256d.zig");
    const testing = std.testing;

    // Test with various headers
    var header: [80]u8 = undefined;
    for (0..80) |i| {
        header[i] = @intCast(i);
    }

    // Test multiple nonces
    const nonces = [_]u32{ 0, 1, 1000, 0xDEADBEEF, 0xFFFFFFFF };

    for (nonces) |nonce| {
        // Set nonce in header
        header[76] = @intCast(nonce & 0xFF);
        header[77] = @intCast((nonce >> 8) & 0xFF);
        header[78] = @intCast((nonce >> 16) & 0xFF);
        header[79] = @intCast((nonce >> 24) & 0xFF);

        // Full SHA256d
        var expected: [32]u8 = undefined;
        sha256d.sha256d(&header, &expected);

        // Midstate version
        const midstate = Midstate.init(&header);
        var result: [32]u8 = undefined;
        midstate.hash(nonce, &result);

        try testing.expectEqualSlices(u8, &expected, &result);
    }
}
