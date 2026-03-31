const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

// Check AVX-512 support at runtime
pub fn hasAvx512() bool {
    // Use CPUID to check AVX-512 support
    // AVX-512F bit is in ECX[16] of leaf 7, subleaf 0
    const leaf7 = std.Target.Cpu.Arch.x86_64.getCpuId(7, 0);
    return (leaf7.ecx & (1 << 16)) != 0;
}

// Dynamic vector width based on CPU capabilities
pub const VecWidth = if (@import("builtin").target.cpu.arch == .x86_64) blk: {
    // At comptime, assume AVX-512 is available for optimal codegen
    // Runtime will check and use appropriate path
    break :blk 16;
} else 8;

pub const VecType = @Vector(VecWidth, u32);

// SHA-256 constants
const k = [_]u32{
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

// Initial hash values
const h0 = [_]u32{ 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };

// Rotate right
fn rotr_vec(v: VecType, n: u5) VecType {
    return (v >> @splat(n)) | (v << @splat(@as(u5, @intCast(32 - @as(u6, n)))));
}

// SHA-256 sigma functions
fn sigma0_vec(a: VecType) VecType {
    return rotr_vec(a, 2) ^ rotr_vec(a, 13) ^ rotr_vec(a, 22);
}

fn sigma1_vec(e: VecType) VecType {
    return rotr_vec(e, 6) ^ rotr_vec(e, 11) ^ rotr_vec(e, 25);
}

fn ch_vec(e: VecType, f: VecType, g: VecType) VecType {
    return (e & f) ^ (~e & g);
}

fn maj_vec(a: VecType, b: VecType, c: VecType) VecType {
    return (a & b) ^ (a & c) ^ (b & c);
}

// Message schedule sigma
fn sigma0_msg_vec(x: VecType) VecType {
    return rotr_vec(x, 7) ^ rotr_vec(x, 18) ^ (x >> @splat(3));
}

fn sigma1_msg_vec(x: VecType) VecType {
    return rotr_vec(x, 17) ^ rotr_vec(x, 19) ^ (x >> @splat(10));
}

// SHA-256 compression for VecWidth blocks in parallel
fn sha256_compress(state: *[8]VecType, w: *[64]VecType) void {
    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];
    var e = state[4];
    var f = state[5];
    var g = state[6];
    var h = state[7];

    // Unroll the main compression loop for maximum performance
    comptime var i = 0;
    inline while (i < 64) : (i += 1) {
        const temp1 = h + sigma1_vec(e) + ch_vec(e, f, g) + @as(VecType, @splat(k[i])) + w[i];
        const temp2 = sigma0_vec(a) + maj_vec(a, b, c);
        h = g;
        g = f;
        f = e;
        e = d + temp1;
        d = c;
        c = b;
        b = a;
        a = temp1 + temp2;
    }

    state[0] +|= a;
    state[1] +|= b;
    state[2] +|= c;
    state[3] +|= d;
    state[4] +|= e;
    state[5] +|= f;
    state[6] +|= g;
    state[7] +|= h;
}

// Prepare message schedule with proper alignment for AVX-512
fn prepare_message_schedule(data: []const []const u8, w: *[64]VecType) void {
    // For each word position
    for (0..16) |word_idx| {
        const offset = word_idx * 4;
        var word: VecType = @splat(0);

        // Load word from each input (up to VecWidth inputs)
        comptime var input_i = 0;
        inline while (input_i < VecWidth) : (input_i += 1) {
            if (input_i < data.len and offset + 3 < data[input_i].len) {
                word[input_i] = std.mem.readInt(u32, data[input_i][offset..][0..4], .big);
            }
        }
        w[word_idx] = word;
    }

    // Extend to 64 words
    comptime var i = 16;
    inline while (i < 64) : (i += 1) {
        w[i] = sigma1_msg_vec(w[i - 2]) + w[i - 7] + sigma0_msg_vec(w[i - 15]) + w[i - 16];
    }
}

// Single SHA-256 hash for VecWidth inputs
fn sha256_batch(out: []*[32]u8, data: []const []const u8) void {
    var state: [8]VecType = undefined;
    for (0..8) |i| {
        state[i] = @splat(h0[i]);
    }

    var w: [64]VecType = undefined;
    prepare_message_schedule(data, &w);

    sha256_compress(&state, &w);

    // Output results
    for (0..8) |state_i| {
        comptime var out_i = 0;
        inline while (out_i < VecWidth) : (out_i += 1) {
            if (out_i < out.len) {
                std.mem.writeInt(u32, out[out_i][state_i * 4..][0..4], state[state_i][out_i], .big);
            }
        }
    }
}

// Double SHA-256 for mining
pub fn sha256dBatch(out: []*[32]u8, data: []const []const u8) !void {
    // First SHA-256
    var mid: [VecWidth][32]u8 align(64) = undefined; // AVX-512 alignment
    var mid_ptrs: [VecWidth]*[32]u8 = undefined;
    for (0..VecWidth) |i| {
        mid_ptrs[i] = &mid[i];
    }
    sha256_batch(&mid_ptrs, data);

    // Second SHA-256 on the mids
    var mid_slices: [VecWidth][]const u8 = undefined;
    for (0..VecWidth) |i| {
        mid_slices[i] = &mid[i];
    }
    sha256_batch(out, &mid_slices);
}

// Fallback for single hash
pub fn sha256dSimd(out: *[32]u8, data: []const u8) !void {
    var outs: [1]*[32]u8 = .{out};
    var datas: [1][]const u8 = .{data};
    try sha256dBatch(&outs, &datas);
}