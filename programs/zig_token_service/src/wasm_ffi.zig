//! Token Service WASM FFI
//!
//! Standalone WebAssembly JWT authentication module.
//! No external dependencies - all crypto implemented inline.
//! Designed for browser-based auth systems.

const std = @import("std");

// ==========================================================================
// WASM Memory - Fixed buffers (no allocator needed)
// ==========================================================================

var g_secret: [256]u8 = undefined;
var g_secret_len: usize = 0;
var g_result_buf: [8192]u8 = undefined;
var g_result_len: usize = 0;
var g_error_code: i32 = 0;
var g_input_buf: [4096]u8 = undefined;

// Error codes
pub const ERR_OK: i32 = 0;
pub const ERR_NOT_INITIALIZED: i32 = -1;
pub const ERR_INVALID_INPUT: i32 = -2;
pub const ERR_SIGN_FAILED: i32 = -3;
pub const ERR_VERIFY_FAILED: i32 = -4;
pub const ERR_TOKEN_EXPIRED: i32 = -5;
pub const ERR_BUFFER_TOO_SMALL: i32 = -7;

// Import timestamp from JavaScript (i32 to avoid BigInt issues)
extern "env" fn js_get_timestamp() i32;

// Import random bytes from JavaScript (crypto.getRandomValues)
extern "env" fn js_get_random_bytes(ptr: [*]u8, len: u32) void;

// ==========================================================================
// UUID Generation
// ==========================================================================

const hex_chars = "0123456789abcdef";

fn formatUuid(bytes: *const [16]u8, out: *[36]u8) void {
    var idx: usize = 0;
    for (0..16) |i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[idx] = '-';
            idx += 1;
        }
        out[idx] = hex_chars[bytes[i] >> 4];
        out[idx + 1] = hex_chars[bytes[i] & 0x0F];
        idx += 2;
    }
}

/// Generate UUID v4 (random)
export fn uuid_v4() u32 {
    var bytes: [16]u8 = undefined;
    js_get_random_bytes(&bytes, 16);

    // Set version 4
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    // Set variant (RFC 4122)
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    var uuid_str: [36]u8 = undefined;
    formatUuid(&bytes, &uuid_str);

    @memcpy(g_result_buf[0..36], &uuid_str);
    g_result_len = 36;
    g_error_code = ERR_OK;

    return 36;
}

/// Generate UUID v7 (timestamp-sortable)
export fn uuid_v7() u32 {
    const timestamp_ms: u64 = @as(u64, @intCast(js_get_timestamp())) * 1000;

    var bytes: [16]u8 = undefined;
    js_get_random_bytes(&bytes, 16);

    // First 48 bits are timestamp (big-endian)
    bytes[0] = @truncate(timestamp_ms >> 40);
    bytes[1] = @truncate(timestamp_ms >> 32);
    bytes[2] = @truncate(timestamp_ms >> 24);
    bytes[3] = @truncate(timestamp_ms >> 16);
    bytes[4] = @truncate(timestamp_ms >> 8);
    bytes[5] = @truncate(timestamp_ms);

    // Set version 7
    bytes[6] = (bytes[6] & 0x0F) | 0x70;
    // Set variant (RFC 4122)
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    var uuid_str: [36]u8 = undefined;
    formatUuid(&bytes, &uuid_str);

    @memcpy(g_result_buf[0..36], &uuid_str);
    g_result_len = 36;
    g_error_code = ERR_OK;

    return 36;
}

// ==========================================================================
// Base58 Encoding/Decoding (Bitcoin alphabet)
// ==========================================================================

const base58_alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/// Encode data as Base58
export fn base58_encode(data_ptr: [*]const u8, data_len: u32) u32 {
    if (data_len == 0 or data_len > 256) {
        g_error_code = ERR_INVALID_INPUT;
        return 0;
    }

    const data = data_ptr[0..data_len];

    // Count leading zeros
    var leading_zeros: usize = 0;
    for (data) |b| {
        if (b != 0) break;
        leading_zeros += 1;
    }

    // Allocate enough space (Base58 is ~137% of input)
    var temp: [512]u8 = undefined;
    var temp_len: usize = 0;

    // Convert to base58 using repeated division
    var num: [512]u8 = undefined;
    @memcpy(num[0..data_len], data);
    var num_len: usize = data_len;

    while (num_len > 0) {
        var remainder: u32 = 0;
        var new_len: usize = 0;

        for (0..num_len) |i| {
            const value = remainder * 256 + num[i];
            const digit = value / 58;
            remainder = value % 58;

            if (new_len > 0 or digit > 0) {
                num[new_len] = @truncate(digit);
                new_len += 1;
            }
        }

        temp[temp_len] = base58_alphabet[@intCast(remainder)];
        temp_len += 1;
        num_len = new_len;
    }

    // Add leading '1's for leading zeros
    for (0..leading_zeros) |_| {
        temp[temp_len] = '1';
        temp_len += 1;
    }

    // Reverse into result buffer
    for (0..temp_len) |i| {
        g_result_buf[i] = temp[temp_len - 1 - i];
    }
    g_result_len = temp_len;
    g_error_code = ERR_OK;

    return @intCast(temp_len);
}

/// Decode Base58 string
export fn base58_decode(str_ptr: [*]const u8, str_len: u32) u32 {
    if (str_len == 0 or str_len > 512) {
        g_error_code = ERR_INVALID_INPUT;
        return 0;
    }

    const str = str_ptr[0..str_len];

    // Build decode table
    var decode_table: [256]i16 = undefined;
    for (&decode_table) |*v| v.* = -1;
    for (base58_alphabet, 0..) |c, i| {
        decode_table[c] = @intCast(i);
    }

    // Count leading '1's (zeros in output)
    var leading_ones: usize = 0;
    for (str) |c| {
        if (c != '1') break;
        leading_ones += 1;
    }

    // Decode using repeated multiplication
    var result: [512]u8 = undefined;
    var result_len: usize = 0;

    for (str) |c| {
        const val = decode_table[c];
        if (val < 0) {
            g_error_code = ERR_INVALID_INPUT;
            return 0;
        }

        var carry: u32 = @intCast(val);
        var i: usize = 0;
        while (i < result_len or carry > 0) {
            if (i < result_len) {
                carry += @as(u32, result[result_len - 1 - i]) * 58;
            }
            if (i >= result_len) {
                result_len += 1;
            }
            result[result_len - 1 - i] = @truncate(carry);
            carry >>= 8;
            i += 1;
        }
    }

    // Add leading zeros
    const total_len = leading_ones + result_len;
    if (total_len > g_result_buf.len) {
        g_error_code = ERR_BUFFER_TOO_SMALL;
        return 0;
    }

    @memset(g_result_buf[0..leading_ones], 0);
    @memcpy(g_result_buf[leading_ones..][0..result_len], result[0..result_len]);
    g_result_len = total_len;
    g_error_code = ERR_OK;

    return @intCast(total_len);
}

// ==========================================================================
// Base64URL Encoding/Decoding
// ==========================================================================

const base64url_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

fn base64UrlEncode(input: []const u8, output: []u8) usize {
    var out_idx: usize = 0;
    var i: usize = 0;

    while (i + 3 <= input.len) : (i += 3) {
        const b0 = input[i];
        const b1 = input[i + 1];
        const b2 = input[i + 2];

        output[out_idx] = base64url_alphabet[b0 >> 2];
        output[out_idx + 1] = base64url_alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
        output[out_idx + 2] = base64url_alphabet[((b1 & 0x0F) << 2) | (b2 >> 6)];
        output[out_idx + 3] = base64url_alphabet[b2 & 0x3F];
        out_idx += 4;
    }

    const remaining = input.len - i;
    if (remaining == 1) {
        const b0 = input[i];
        output[out_idx] = base64url_alphabet[b0 >> 2];
        output[out_idx + 1] = base64url_alphabet[(b0 & 0x03) << 4];
        out_idx += 2;
    } else if (remaining == 2) {
        const b0 = input[i];
        const b1 = input[i + 1];
        output[out_idx] = base64url_alphabet[b0 >> 2];
        output[out_idx + 1] = base64url_alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
        output[out_idx + 2] = base64url_alphabet[(b1 & 0x0F) << 2];
        out_idx += 3;
    }

    return out_idx;
}

fn base64UrlDecode(input: []const u8, output: []u8) ?usize {
    var decode_table: [256]u8 = undefined;
    for (&decode_table) |*v| v.* = 0xFF;
    for (base64url_alphabet, 0..) |c, i| {
        decode_table[c] = @intCast(i);
    }

    var out_idx: usize = 0;
    var i: usize = 0;
    var buf: u32 = 0;
    var bits: u32 = 0;

    while (i < input.len) : (i += 1) {
        const val = decode_table[input[i]];
        if (val == 0xFF) return null;

        buf = (buf << 6) | val;
        bits += 6;

        if (bits >= 8) {
            bits -= 8;
            output[out_idx] = @truncate(buf >> @intCast(bits));
            out_idx += 1;
        }
    }

    return out_idx;
}

// ==========================================================================
// HMAC-SHA256
// ==========================================================================

const Sha256 = struct {
    state: [8]u32,
    buf: [64]u8,
    buf_len: usize,
    total_len: u64,

    const K: [64]u32 = .{
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    };

    fn init() Sha256 {
        return .{
            .state = .{ 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 },
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

        var a = self.state[0];
        var b = self.state[1];
        var c = self.state[2];
        var d = self.state[3];
        var e = self.state[4];
        var f = self.state[5];
        var g = self.state[6];
        var h = self.state[7];

        for (0..64) |i| {
            const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
            const ch = (e & f) ^ (~e & g);
            const temp1 = h +% S1 +% ch +% K[i] +% w[i];
            const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
            const maj = (a & b) ^ (a & c) ^ (b & c);
            const temp2 = S0 +% maj;

            h = g;
            g = f;
            f = e;
            e = d +% temp1;
            d = c;
            c = b;
            b = a;
            a = temp1 +% temp2;
        }

        self.state[0] +%= a;
        self.state[1] +%= b;
        self.state[2] +%= c;
        self.state[3] +%= d;
        self.state[4] +%= e;
        self.state[5] +%= f;
        self.state[6] +%= g;
        self.state[7] +%= h;
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
            result[i * 4] = @truncate(self.state[i] >> 24);
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
        var hasher = Sha256.init();
        hasher.update(key);
        const hash = hasher.final();
        @memcpy(key_block[0..32], &hash);
    } else {
        @memcpy(key_block[0..key.len], key);
    }

    var o_key_pad: [64]u8 = undefined;
    var i_key_pad: [64]u8 = undefined;
    for (0..64) |i| {
        o_key_pad[i] = key_block[i] ^ 0x5c;
        i_key_pad[i] = key_block[i] ^ 0x36;
    }

    var inner = Sha256.init();
    inner.update(&i_key_pad);
    inner.update(message);
    const inner_hash = inner.final();

    var outer = Sha256.init();
    outer.update(&o_key_pad);
    outer.update(&inner_hash);
    return outer.final();
}

// ==========================================================================
// JWT Functions
// ==========================================================================

fn writeInt(buf: []u8, val: i64) usize {
    var v = val;
    var tmp: [20]u8 = undefined;
    var len: usize = 0;

    if (v < 0) {
        buf[0] = '-';
        v = -v;
        var i: usize = 0;
        while (v > 0) : (i += 1) {
            tmp[i] = @intCast(@as(u64, @intCast(v)) % 10 + '0');
            v = @divTrunc(v, 10);
        }
        len = i;
        for (0..len) |j| {
            buf[1 + j] = tmp[len - 1 - j];
        }
        return len + 1;
    } else if (v == 0) {
        buf[0] = '0';
        return 1;
    } else {
        var i: usize = 0;
        while (v > 0) : (i += 1) {
            tmp[i] = @intCast(@as(u64, @intCast(v)) % 10 + '0');
            v = @divTrunc(v, 10);
        }
        len = i;
        for (0..len) |j| {
            buf[j] = tmp[len - 1 - j];
        }
        return len;
    }
}

// ==========================================================================
// Exported Functions
// ==========================================================================

/// Initialize with secret key
export fn init(secret_ptr: [*]const u8, secret_len: u32) i32 {
    if (secret_len == 0 or secret_len > @as(u32, @intCast(g_secret.len))) {
        g_error_code = ERR_INVALID_INPUT;
        return ERR_INVALID_INPUT;
    }

    @memcpy(g_secret[0..secret_len], secret_ptr[0..secret_len]);
    g_secret_len = secret_len;
    g_error_code = ERR_OK;
    return ERR_OK;
}

/// Sign a JWT token
export fn sign_token(user_id_ptr: [*]const u8, user_id_len: u32, expires_in: i32) u32 {
    if (g_secret_len == 0) {
        g_error_code = ERR_NOT_INITIALIZED;
        return 0;
    }

    if (user_id_len == 0 or user_id_len > 256) {
        g_error_code = ERR_INVALID_INPUT;
        return 0;
    }

    const now: i64 = js_get_timestamp();
    const exp = now + @as(i64, expires_in);

    // Build header: {"alg":"HS256","typ":"JWT"}
    const header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";

    // Build payload
    var payload_buf: [512]u8 = undefined;
    var pos: usize = 0;

    const prefix = "{\"sub\":\"";
    @memcpy(payload_buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    @memcpy(payload_buf[pos..][0..user_id_len], user_id_ptr[0..user_id_len]);
    pos += user_id_len;

    const iat_prefix = "\",\"iat\":";
    @memcpy(payload_buf[pos..][0..iat_prefix.len], iat_prefix);
    pos += iat_prefix.len;

    pos += writeInt(payload_buf[pos..], now);

    const exp_prefix = ",\"exp\":";
    @memcpy(payload_buf[pos..][0..exp_prefix.len], exp_prefix);
    pos += exp_prefix.len;

    pos += writeInt(payload_buf[pos..], exp);

    payload_buf[pos] = '}';
    pos += 1;

    const payload = payload_buf[0..pos];

    // Encode header and payload
    var encoded_header: [64]u8 = undefined;
    const header_len = base64UrlEncode(header, &encoded_header);

    var encoded_payload: [1024]u8 = undefined;
    const payload_len = base64UrlEncode(payload, &encoded_payload);

    // Create signing input: header.payload
    var signing_input: [2048]u8 = undefined;
    @memcpy(signing_input[0..header_len], encoded_header[0..header_len]);
    signing_input[header_len] = '.';
    @memcpy(signing_input[header_len + 1 ..][0..payload_len], encoded_payload[0..payload_len]);
    const signing_len = header_len + 1 + payload_len;

    // Sign with HMAC-SHA256
    const signature = hmacSha256(g_secret[0..g_secret_len], signing_input[0..signing_len]);

    // Encode signature
    var encoded_sig: [64]u8 = undefined;
    const sig_len = base64UrlEncode(&signature, &encoded_sig);

    // Build final token: header.payload.signature
    @memcpy(g_result_buf[0..signing_len], signing_input[0..signing_len]);
    g_result_buf[signing_len] = '.';
    @memcpy(g_result_buf[signing_len + 1 ..][0..sig_len], encoded_sig[0..sig_len]);
    g_result_len = signing_len + 1 + sig_len;

    g_error_code = ERR_OK;
    return g_result_len;
}

/// Verify a JWT token
export fn verify_token(token_ptr: [*]const u8, token_len: u32) i32 {
    if (g_secret_len == 0) {
        g_error_code = ERR_NOT_INITIALIZED;
        return 0;
    }

    if (token_len == 0 or token_len > 4096) {
        g_error_code = ERR_INVALID_INPUT;
        return 0;
    }

    const token = token_ptr[0..token_len];

    // Find the dots
    var dot1: ?usize = null;
    var dot2: ?usize = null;
    for (token, 0..) |c, i| {
        if (c == '.') {
            if (dot1 == null) {
                dot1 = i;
            } else {
                dot2 = i;
                break;
            }
        }
    }

    if (dot1 == null or dot2 == null) {
        g_error_code = ERR_VERIFY_FAILED;
        return 0;
    }

    const signing_input = token[0..dot2.?];
    const provided_sig = token[dot2.? + 1 ..];

    // Compute expected signature
    const expected_sig = hmacSha256(g_secret[0..g_secret_len], signing_input);
    var encoded_expected: [64]u8 = undefined;
    const expected_len = base64UrlEncode(&expected_sig, &encoded_expected);

    // Compare signatures (constant time)
    if (expected_len != provided_sig.len) {
        g_error_code = ERR_VERIFY_FAILED;
        return 0;
    }

    var diff: u8 = 0;
    for (0..expected_len) |i| {
        diff |= encoded_expected[i] ^ provided_sig[i];
    }

    if (diff != 0) {
        g_error_code = ERR_VERIFY_FAILED;
        return 0;
    }

    // Decode payload to check expiration
    const payload_b64 = token[dot1.? + 1 .. dot2.?];
    var payload: [512]u8 = undefined;
    const payload_len = base64UrlDecode(payload_b64, &payload) orelse {
        g_error_code = ERR_VERIFY_FAILED;
        return 0;
    };

    // Simple exp extraction (look for "exp":)
    const payload_str = payload[0..payload_len];
    if (std.mem.indexOf(u8, payload_str, "\"exp\":")) |exp_idx| {
        var exp_start = exp_idx + 6;
        var exp_val: i64 = 0;
        while (exp_start < payload_len and payload_str[exp_start] >= '0' and payload_str[exp_start] <= '9') {
            exp_val = exp_val * 10 + (payload_str[exp_start] - '0');
            exp_start += 1;
        }

        const now: i64 = js_get_timestamp();
        if (exp_val < now) {
            g_error_code = ERR_TOKEN_EXPIRED;
            return 0;
        }
    }

    // Extract subject for result
    if (std.mem.indexOf(u8, payload_str, "\"sub\":\"")) |sub_idx| {
        const sub_start = sub_idx + 7;
        if (std.mem.indexOfPos(u8, payload_str, sub_start, "\"")) |sub_end| {
            const sub = payload_str[sub_start..sub_end];
            @memcpy(g_result_buf[0..sub.len], sub);
            g_result_len = sub.len;
        }
    }

    g_error_code = ERR_OK;
    return 1;
}

/// Get pointer to result buffer
export fn get_result_ptr() [*]const u8 {
    return &g_result_buf;
}

/// Get result length
export fn get_result_len() u32 {
    return @intCast(g_result_len);
}

/// Get error code
export fn get_error_code() i32 {
    return g_error_code;
}

/// Get pointer to input buffer (for JS to write into)
export fn get_input_ptr() [*]u8 {
    return &g_input_buf;
}

/// Get input buffer size
export fn get_input_size() u32 {
    return @intCast(g_input_buf.len);
}

/// Version info
export fn get_version_major() u32 {
    return 0;
}

export fn get_version_minor() u32 {
    return 1;
}

export fn get_version_patch() u32 {
    return 0;
}
