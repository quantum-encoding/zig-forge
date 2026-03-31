//! VoidNote Keys — WASM FFI
//!
//! Cryptographic primitives for the VoidNote API key system.
//! Provides:
//!   - generate_api_key() → "vn_" + 64 hex chars (32 random bytes)
//!   - hmac_sha256(secret, message) → 64-char hex HMAC
//!   - hmac_sha256_verify(secret, message, expected_hex) → 1 (valid) or 0 (invalid)
//!
//! No external dependencies — SHA-256 and HMAC implemented inline.
//! Target: wasm32-freestanding for Cloudflare Workers.
//!
//! JS host must provide:
//!   env.js_get_random_bytes(ptr: i32, len: i32) → void
//!   (fills memory[ptr..ptr+len] with crypto-secure random bytes)

const std = @import("std");

// ==========================================================================
// WASM Memory — fixed global buffers, no allocator
// ==========================================================================

/// Result buffer — API key: 67 bytes, HMAC hex: 64 bytes
var g_result_buf: [256]u8 = undefined;
var g_result_len: usize = 0;
var g_error_code: i32 = 0;

pub const ERR_OK: i32 = 0;
pub const ERR_INVALID_INPUT: i32 = -1;

const hex_chars = "0123456789abcdef";

/// Import crypto-secure random bytes from the JS host (crypto.getRandomValues)
extern "env" fn js_get_random_bytes(ptr: [*]u8, len: u32) void;

// ==========================================================================
// SHA-256 (standalone, no std dependency for WASM portability)
// ==========================================================================

const Sha256 = struct {
    state: [8]u32,
    buf: [64]u8,
    buf_len: usize,
    total_len: u64,

    const K: [64]u32 = .{
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    };

    fn init() Sha256 {
        return .{
            .state = .{
                0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
            },
            .buf = undefined,
            .buf_len = 0,
            .total_len = 0,
        };
    }

    fn rotr(x: u32, comptime n: comptime_int) u32 {
        return (x >> n) | (x << (32 - n));
    }

    fn processBlock(self: *Sha256, block: *const [64]u8) void {
        var w: [64]u32 = undefined;
        for (0..16) |i| {
            w[i] = (@as(u32, block[i * 4]) << 24) |
                   (@as(u32, block[i * 4 + 1]) << 16) |
                   (@as(u32, block[i * 4 + 2]) << 8) |
                   @as(u32, block[i * 4 + 3]);
        }
        for (16..64) |i| {
            const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
            const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] +% s0 +% w[i - 7] +% s1;
        }
        var a = self.state[0]; var b = self.state[1];
        var c = self.state[2]; var d = self.state[3];
        var e = self.state[4]; var f = self.state[5];
        var g = self.state[6]; var h = self.state[7];
        for (0..64) |i| {
            const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
            const ch = (e & f) ^ (~e & g);
            const temp1 = h +% S1 +% ch +% K[i] +% w[i];
            const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
            const maj = (a & b) ^ (a & c) ^ (b & c);
            const temp2 = S0 +% maj;
            h = g; g = f; f = e; e = d +% temp1;
            d = c; c = b; b = a; a = temp1 +% temp2;
        }
        self.state[0] +%= a; self.state[1] +%= b;
        self.state[2] +%= c; self.state[3] +%= d;
        self.state[4] +%= e; self.state[5] +%= f;
        self.state[6] +%= g; self.state[7] +%= h;
    }

    fn update(self: *Sha256, data: []const u8) void {
        var input = data;
        self.total_len += data.len;
        if (self.buf_len > 0) {
            const to_copy = @min(64 - self.buf_len, input.len);
            @memcpy(self.buf[self.buf_len..][0..to_copy], input[0..to_copy]);
            self.buf_len += to_copy;
            input = input[to_copy..];
            if (self.buf_len == 64) {
                self.processBlock(&self.buf);
                self.buf_len = 0;
            }
        }
        while (input.len >= 64) {
            self.processBlock(@ptrCast(input[0..64]));
            input = input[64..];
        }
        if (input.len > 0) {
            @memcpy(self.buf[0..input.len], input);
            self.buf_len = input.len;
        }
    }

    fn final(self: *Sha256) [32]u8 {
        const bit_len = self.total_len * 8;
        self.buf[self.buf_len] = 0x80;
        self.buf_len += 1;
        if (self.buf_len > 56) {
            @memset(self.buf[self.buf_len..64], 0);
            self.processBlock(&self.buf);
            self.buf_len = 0;
        }
        @memset(self.buf[self.buf_len..56], 0);
        for (0..8) |i| {
            self.buf[56 + i] = @truncate(bit_len >> @intCast((7 - i) * 8));
        }
        self.processBlock(&self.buf);
        var result: [32]u8 = undefined;
        for (0..8) |i| {
            result[i * 4]     = @truncate(self.state[i] >> 24);
            result[i * 4 + 1] = @truncate(self.state[i] >> 16);
            result[i * 4 + 2] = @truncate(self.state[i] >> 8);
            result[i * 4 + 3] = @truncate(self.state[i]);
        }
        return result;
    }
};

fn hmacSha256(key: []const u8, message: []const u8) [32]u8 {
    var key_block: [64]u8 = undefined;
    @memset(&key_block, 0);
    if (key.len > 64) {
        var h = Sha256.init();
        h.update(key);
        const hash = h.final();
        @memcpy(key_block[0..32], &hash);
    } else {
        @memcpy(key_block[0..key.len], key);
    }
    var o_pad: [64]u8 = undefined;
    var i_pad: [64]u8 = undefined;
    for (0..64) |i| {
        o_pad[i] = key_block[i] ^ 0x5c;
        i_pad[i] = key_block[i] ^ 0x36;
    }
    var inner = Sha256.init();
    inner.update(&i_pad);
    inner.update(message);
    const inner_hash = inner.final();
    var outer = Sha256.init();
    outer.update(&o_pad);
    outer.update(&inner_hash);
    return outer.final();
}

// ==========================================================================
// Exported API
// ==========================================================================

/// Generate a VoidNote API key: "vn_" + 64 lowercase hex chars (32 random bytes).
/// Returns 67 on success, 0 on error.
/// Read the key with get_result_ptr() / get_result_len().
export fn generate_api_key() u32 {
    var raw: [32]u8 = undefined;
    js_get_random_bytes(&raw, 32);

    g_result_buf[0] = 'v';
    g_result_buf[1] = 'n';
    g_result_buf[2] = '_';
    for (raw, 0..) |byte, i| {
        g_result_buf[3 + i * 2]     = hex_chars[byte >> 4];
        g_result_buf[3 + i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    g_result_len = 67;
    g_error_code = ERR_OK;
    return 67;
}

/// Compute HMAC-SHA256(secret, message).
/// Writes 64 lowercase hex chars to the result buffer.
/// Returns 64 on success, 0 on invalid input.
/// Read result with get_result_ptr() / get_result_len().
export fn hmac_sha256(
    secret_ptr: [*]const u8,
    secret_len: u32,
    msg_ptr: [*]const u8,
    msg_len: u32,
) u32 {
    if (secret_len == 0 or secret_len > 4096 or msg_len > 65536) {
        g_error_code = ERR_INVALID_INPUT;
        return 0;
    }
    const mac = hmacSha256(secret_ptr[0..secret_len], msg_ptr[0..msg_len]);
    for (mac, 0..) |byte, i| {
        g_result_buf[i * 2]     = hex_chars[byte >> 4];
        g_result_buf[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    g_result_len = 64;
    g_error_code = ERR_OK;
    return 64;
}

/// Constant-time HMAC-SHA256 verification.
/// expected_hex_ptr must point to exactly 64 lowercase hex chars.
/// Returns 1 if valid, 0 if invalid.
export fn hmac_sha256_verify(
    secret_ptr: [*]const u8,
    secret_len: u32,
    msg_ptr: [*]const u8,
    msg_len: u32,
    expected_hex_ptr: [*]const u8,
    expected_hex_len: u32,
) i32 {
    if (expected_hex_len != 64) return 0;
    const len = hmac_sha256(secret_ptr, secret_len, msg_ptr, msg_len);
    if (len == 0) return 0;
    // Constant-time compare to prevent timing attacks
    var diff: u8 = 0;
    for (0..64) |i| {
        diff |= g_result_buf[i] ^ expected_hex_ptr[i];
    }
    return if (diff == 0) @as(i32, 1) else @as(i32, 0);
}

/// Pointer to the result buffer (JS reads result from here after a call)
export fn get_result_ptr() [*]const u8 {
    return &g_result_buf;
}

/// Length of the most recent result
export fn get_result_len() u32 {
    return @intCast(g_result_len);
}

/// Last error code (0 = ok, -1 = invalid input)
export fn get_error_code() i32 {
    return g_error_code;
}
