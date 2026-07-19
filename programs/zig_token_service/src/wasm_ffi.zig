//! Token Service WASM FFI
//!
//! Standalone WebAssembly JWT authentication module.
//! No external dependencies - all crypto implemented inline.
//! Designed for browser-based auth systems.
//!
//! TRUST MODEL — READ BEFORE USING
//!
//! `init()` copies the HMAC signing secret into this module's memory, which on
//! the wasm32 target is the browser page's memory. Anyone with access to the
//! page can extract it and mint arbitrary tokens. Expiry is checked against
//! `js_get_timestamp()`, i.e. the client's own clock, which the client can
//! move at will. This module is therefore a UX / offline convenience, NOT a
//! security boundary: every token minted or accepted here MUST be re-verified
//! server-side (see `src/lib.zig`, which delegates to the audited `zig_jwt`)
//! with the secret held privately. Do not ship this as the sole verifier.
//!
//! What it does guarantee: `verify_token` pins the header `alg` to HS256 and
//! refuses anything else (including `alg:none`) before computing the HMAC, and
//! compares signatures in constant time. `sign_token` JSON-escapes the subject
//! so a hostile `user_id` cannot inject claims.

const std = @import("std");
const builtin = @import("builtin");

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

// Host imports.
//
// On the freestanding wasm32 target these resolve to `env.js_get_timestamp`
// and `env.js_get_random_bytes` — the imports `web/demo.html` and
// `web/token-service.js` supply (do NOT rename them: the import field name is
// the identifier and is part of the WASM ABI). On native targets (used by the
// `zig build test` step so the inline crypto actually compiles and runs) they
// resolve to local stand-ins: a fixed clock and libc's arc4random_buf. The
// untaken branch is never referenced, so it is never semantically analyzed —
// `std.c` is not compiled for the wasm build.
const host = if (builtin.target.cpu.arch.isWasm()) wasm_host else native_host;

const wasm_host = struct {
    // Import timestamp from JavaScript (i32 to avoid BigInt issues)
    extern "env" fn js_get_timestamp() i32;
    // Import random bytes from JavaScript (crypto.getRandomValues)
    extern "env" fn js_get_random_bytes(ptr: [*]u8, len: u32) void;
};

const native_host = struct {
    fn js_get_timestamp() i32 {
        // Fixed, deterministic clock for tests (2023-11-14T22:13:20Z).
        return 1_700_000_000;
    }
    fn js_get_random_bytes(ptr: [*]u8, len: u32) void {
        std.c.arc4random_buf(ptr, len);
    }
};

const js_get_timestamp = host.js_get_timestamp;
const js_get_random_bytes = host.js_get_random_bytes;

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

    // Decode using repeated multiplication. `result` holds a base-256
    // big-integer stored little-endian (result[0] is the least-significant
    // byte); it is reversed to big-endian on output below.
    var result: [512]u8 = undefined;
    var result_len: usize = 0;

    for (str) |c| {
        const val = decode_table[c];
        if (val < 0) {
            g_error_code = ERR_INVALID_INPUT;
            return 0;
        }

        // result = result * 58 + val
        var carry: u32 = @intCast(val);
        var i: usize = 0;
        while (i < result_len) : (i += 1) {
            carry += @as(u32, result[i]) * 58;
            result[i] = @truncate(carry);
            carry >>= 8;
        }
        // Append any remaining carry as new most-significant bytes.
        while (carry > 0) {
            if (result_len >= result.len) {
                g_error_code = ERR_BUFFER_TOO_SMALL;
                return 0;
            }
            result[result_len] = @truncate(carry);
            result_len += 1;
            carry >>= 8;
        }
    }

    // Add leading zeros
    const total_len = leading_ones + result_len;
    if (total_len > g_result_buf.len) {
        g_error_code = ERR_BUFFER_TOO_SMALL;
        return 0;
    }

    // Leading '1's become leading zero bytes; then emit the big-integer
    // most-significant byte first (reverse of the little-endian buffer).
    @memset(g_result_buf[0..leading_ones], 0);
    for (0..result_len) |k| {
        g_result_buf[leading_ones + k] = result[result_len - 1 - k];
    }
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

/// Copy `s` into `out` as the BODY of a JSON string (no surrounding quotes),
/// escaping per RFC 8259 §7. Returns the number of bytes written, or null if
/// `out` is too small.
///
/// Without this, a `user_id` containing `"` or `\` breaks out of the `sub`
/// string in the hand-built payload and injects arbitrary claims — the
/// JSON-IN-FMT anti-pattern (zig-forge CLAUDE.md §1) expressed via @memcpy.
/// Worst case is 6 bytes out per byte in (`\u00XX`), so callers must size
/// `out` at 6x the maximum subject length.
fn jsonEscapeInto(s: []const u8, out: []u8) ?usize {
    var n: usize = 0;
    for (s) |c| {
        const esc: []const u8 = switch (c) {
            '"' => "\\\"",
            '\\' => "\\\\",
            0x08 => "\\b",
            0x0c => "\\f",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => {
                if (c < 0x20) {
                    // Remaining control characters must be \u00XX escaped.
                    if (n + 6 > out.len) return null;
                    @memcpy(out[n..][0..4], "\\u00");
                    out[n + 4] = hex_chars[c >> 4];
                    out[n + 5] = hex_chars[c & 0x0F];
                    n += 6;
                    continue;
                }
                // Everything else (including UTF-8 continuation bytes) is
                // copied verbatim, as JSON permits.
                if (n + 1 > out.len) return null;
                out[n] = c;
                n += 1;
                continue;
            },
        };
        if (n + esc.len > out.len) return null;
        @memcpy(out[n..][0..esc.len], esc);
        n += esc.len;
    }
    return n;
}

/// Read the JSON string that starts at `json[start]` (i.e. `start` is the byte
/// just after the opening quote), decoding the escapes `jsonEscapeInto` can
/// emit, and writing the unescaped bytes to `out`. Returns the number of bytes
/// written, or null on a malformed / oversized string.
///
/// A naive `indexOf(pos, "\"")` scan would stop at an ESCAPED quote and report
/// a truncated subject, so extraction has to understand escaping too.
fn jsonUnescapeStringInto(json: []const u8, start: usize, out: []u8) ?usize {
    var i = start;
    var n: usize = 0;
    while (i < json.len) {
        const c = json[i];
        if (c == '"') return n; // unescaped closing quote
        if (n >= out.len) return null;
        if (c != '\\') {
            out[n] = c;
            n += 1;
            i += 1;
            continue;
        }
        if (i + 1 >= json.len) return null;
        const e = json[i + 1];
        switch (e) {
            '"', '\\', '/' => {
                out[n] = e;
                n += 1;
                i += 2;
            },
            'b' => {
                out[n] = 0x08;
                n += 1;
                i += 2;
            },
            'f' => {
                out[n] = 0x0c;
                n += 1;
                i += 2;
            },
            'n' => {
                out[n] = '\n';
                n += 1;
                i += 2;
            },
            'r' => {
                out[n] = '\r';
                n += 1;
                i += 2;
            },
            't' => {
                out[n] = '\t';
                n += 1;
                i += 2;
            },
            'u' => {
                // Only the \u00XX form this module emits is decoded; any
                // other \u escape (including surrogate pairs) is refused
                // rather than mis-decoded.
                if (i + 6 > json.len) return null;
                if (json[i + 2] != '0' or json[i + 3] != '0') return null;
                const hi = hexVal(json[i + 4]) orelse return null;
                const lo = hexVal(json[i + 5]) orelse return null;
                out[n] = (hi << 4) | lo;
                n += 1;
                i += 6;
            },
            else => return null,
        }
    }
    return null; // ran off the end without a closing quote
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Locate the value of a top-level JSON string member `"<key>":"…"` and return
/// the index of its first content byte (just past the opening quote).
/// Tolerates whitespace around the colon. Returns null if absent.
fn findStringValueStart(json: []const u8, key: []const u8) ?usize {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, json, search, key)) |k| {
        // The key must itself be quoted: "key"
        if (k == 0 or json[k - 1] != '"') {
            search = k + 1;
            continue;
        }
        var i = k + key.len;
        if (i >= json.len or json[i] != '"') {
            search = k + 1;
            continue;
        }
        i += 1;
        while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) i += 1;
        if (i >= json.len or json[i] != ':') {
            search = k + 1;
            continue;
        }
        i += 1;
        while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) i += 1;
        if (i >= json.len or json[i] != '"') {
            search = k + 1;
            continue;
        }
        return i + 1;
    }
    return null;
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

    // Build payload. Sized for the worst case: 256 subject bytes each
    // expanding to a 6-byte \u00XX escape, plus the fixed members.
    var payload_buf: [1664]u8 = undefined;
    var pos: usize = 0;

    const prefix = "{\"sub\":\"";
    @memcpy(payload_buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    // JSON-escape the subject rather than @memcpy-ing it raw: an unescaped
    // `"` would otherwise close the string and let the caller append claims.
    const escaped_len = jsonEscapeInto(user_id_ptr[0..user_id_len], payload_buf[pos..]) orelse {
        g_error_code = ERR_INVALID_INPUT;
        return 0;
    };
    pos += escaped_len;

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

    // ceil(1664/3)*4 = 2220, rounded up.
    var encoded_payload: [2304]u8 = undefined;
    const payload_len = base64UrlEncode(payload, &encoded_payload);

    // Create signing input: header.payload
    var signing_input: [2688]u8 = undefined;
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
    return @intCast(g_result_len);
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

    // Enforce the header algorithm BEFORE doing any crypto. The HMAC compare
    // below already makes `alg:none` / alg-confusion forgeries fail, but
    // being algorithm-blind means a token whose header claims RS256 (or
    // anything else) would still be accepted on an HMAC match. Fail closed on
    // anything that is not exactly HS256, matching the native zig_jwt path.
    {
        var header_json: [256]u8 = undefined;
        const header_len = base64UrlDecode(token[0..dot1.?], &header_json) orelse {
            g_error_code = ERR_VERIFY_FAILED;
            return 0;
        };
        const header = header_json[0..header_len];

        const alg_start = findStringValueStart(header, "alg") orelse {
            g_error_code = ERR_VERIFY_FAILED;
            return 0;
        };
        var alg_buf: [32]u8 = undefined;
        const alg_len = jsonUnescapeStringInto(header, alg_start, &alg_buf) orelse {
            g_error_code = ERR_VERIFY_FAILED;
            return 0;
        };
        // `alg` is a public, enum-like header field that the caller supplied
        // themselves, not a secret — an early exit leaks nothing they do not
        // already know. The signature comparison below is the constant-time one.
        // zig-lens-ignore: EQL-FOR-SECRETS public enum-like header field, attacker-supplied, no secret compared
        if (!std.mem.eql(u8, alg_buf[0..alg_len], "HS256")) {
            g_error_code = ERR_VERIFY_FAILED;
            return 0;
        }
    }

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

    // Decode payload to check expiration. Sized for the largest payload a
    // `token_len <= 4096` token can carry (base64 decodes to 3/4 of input).
    const payload_b64 = token[dot1.? + 1 .. dot2.?];
    var payload: [3072]u8 = undefined;
    const payload_len = base64UrlDecode(payload_b64, &payload) orelse {
        g_error_code = ERR_VERIFY_FAILED;
        return 0;
    };

    // Simple exp extraction (look for "exp":). Parsed with saturating
    // arithmetic and a digit cap: a payload carrying a 400-digit `exp` would
    // otherwise overflow i64 and panic (integer overflow is checked in
    // Debug/ReleaseSafe), turning a malformed token into a crash.
    const payload_str = payload[0..payload_len];
    if (std.mem.indexOf(u8, payload_str, "\"exp\":")) |exp_idx| {
        var exp_start = exp_idx + 6;
        var exp_val: i64 = 0;
        var digits: usize = 0;
        while (exp_start < payload_len and payload_str[exp_start] >= '0' and payload_str[exp_start] <= '9') {
            if (digits < 19) {
                exp_val = std.math.add(i64, std.math.mul(i64, exp_val, 10) catch std.math.maxInt(i64), payload_str[exp_start] - '0') catch std.math.maxInt(i64);
            } else {
                // More digits than i64 can hold: clamp (far-future expiry).
                exp_val = std.math.maxInt(i64);
            }
            digits += 1;
            exp_start += 1;
        }
        if (digits == 0) {
            // "exp" present but not a number — refuse rather than silently
            // treating the token as never expiring.
            g_error_code = ERR_VERIFY_FAILED;
            return 0;
        }

        const now: i64 = js_get_timestamp();
        if (exp_val < now) {
            g_error_code = ERR_TOKEN_EXPIRED;
            return 0;
        }
    }

    // Extract subject for result, decoding JSON escapes. A plain scan to the
    // next `"` would truncate a subject that legitimately contains an escaped
    // quote (which sign_token now emits).
    g_result_len = 0;
    if (findStringValueStart(payload_str, "sub")) |sub_start| {
        const sub_len = jsonUnescapeStringInto(payload_str, sub_start, &g_result_buf) orelse {
            g_error_code = ERR_VERIFY_FAILED;
            return 0;
        };
        g_result_len = sub_len;
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

// ==========================================================================
// Tests (native target only — externally-anchored vectors for the inline
// SHA-256 / HMAC-SHA256 / Base64URL / Base58 / mini-JWT implementations).
//
// These run under `zig build test`, which compiles this file for the native
// target. Inputs AND expected outputs come from sources this repo did not
// author: NIST FIPS 180-2 SHA-256 examples, RFC 4231 HMAC-SHA256 KATs,
// RFC 4648 Base64URL examples, Bitcoin Core base58_encode_decode vectors, and
// the canonical jwt.io HS256 token. Per zig-forge CLAUDE.md golden rule §1,
// these are not roundtrip-only self-consistency tests.
// ==========================================================================

const testing = std.testing;

fn sha256Hex(data: []const u8) [64]u8 {
    var h = Sha256.init();
    h.update(data);
    const digest = h.final();
    return std.fmt.bytesToHex(digest, .lower);
}

fn hmacHex(key: []const u8, msg: []const u8) [64]u8 {
    const mac = hmacSha256(key, msg);
    return std.fmt.bytesToHex(mac, .lower);
}

test "SHA-256 KAT: NIST FIPS 180-2 one-block \"abc\"" {
    try testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &sha256Hex("abc"),
    );
}

test "SHA-256 KAT: empty string" {
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &sha256Hex(""),
    );
}

test "SHA-256 KAT: NIST FIPS 180-2 two-block message" {
    try testing.expectEqualStrings(
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
        &sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
    );
}

test "SHA-256 KAT: one million 'a' (multi-block streaming)" {
    var h = Sha256.init();
    var block: [1000]u8 = undefined;
    @memset(&block, 'a');
    var i: usize = 0;
    while (i < 1000) : (i += 1) h.update(&block);
    const digest = h.final();
    try testing.expectEqualStrings(
        "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
        &std.fmt.bytesToHex(digest, .lower),
    );
}

test "HMAC-SHA256 KAT: RFC 4231 Test Case 1" {
    const key = [_]u8{0x0b} ** 20;
    try testing.expectEqualStrings(
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
        &hmacHex(&key, "Hi There"),
    );
}

test "HMAC-SHA256 KAT: RFC 4231 Test Case 2 (short key 'Jefe')" {
    try testing.expectEqualStrings(
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
        &hmacHex("Jefe", "what do ya want for nothing?"),
    );
}

test "HMAC-SHA256 KAT: RFC 4231 Test Case 4 (0xcd x50 message)" {
    const key = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19 };
    const msg = [_]u8{0xcd} ** 50;
    try testing.expectEqualStrings(
        "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b",
        &hmacHex(&key, &msg),
    );
}

test "HMAC-SHA256 KAT: RFC 4231 Test Case 6 (key longer than block, 131 bytes)" {
    const key = [_]u8{0xaa} ** 131;
    try testing.expectEqualStrings(
        "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
        &hmacHex(&key, "Test Using Larger Than Block-Size Key - Hash Key First"),
    );
}

test "Base64URL encode: RFC 4648 examples (unpadded)" {
    var out: [16]u8 = undefined;
    // "Man" -> "TWFu", "Ma" -> "TWE", "M" -> "TQ" (base64url, no padding)
    try testing.expectEqualStrings("TWFu", out[0..base64UrlEncode("Man", &out)]);
    try testing.expectEqualStrings("TWE", out[0..base64UrlEncode("Ma", &out)]);
    try testing.expectEqualStrings("TQ", out[0..base64UrlEncode("M", &out)]);
    // URL-safe alphabet: index 62 -> '-', 63 -> '_' (standard Base64 would
    // emit '+' and '/' here). 3 input bytes -> 4 output chars.
    try testing.expectEqualStrings("-_-_", out[0..base64UrlEncode(&[_]u8{ 0xfb, 0xff, 0xbf }, &out)]);
}

test "Base64URL decode: inverse of the RFC 4648 examples" {
    var out: [16]u8 = undefined;
    try testing.expectEqualStrings("Man", out[0..(base64UrlDecode("TWFu", &out).?)]);
    try testing.expectEqualStrings("Ma", out[0..(base64UrlDecode("TWE", &out).?)]);
    try testing.expectEqualStrings("M", out[0..(base64UrlDecode("TQ", &out).?)]);
    // Invalid character must be rejected.
    try testing.expect(base64UrlDecode("T*", &out) == null);
}

test "Base58 encode: Bitcoin Core base58_encode_decode vectors" {
    // hex input -> expected base58 (from bitcoin/src/test/data/base58_encode_decode.json)
    try testing.expectEqual(@as(u32, 2), base58_encode(&[_]u8{0x61}, 1));
    try testing.expectEqualStrings("2g", g_result_buf[0..g_result_len]);

    try testing.expectEqual(@as(u32, 4), base58_encode(&[_]u8{ 0x62, 0x62, 0x62 }, 3));
    try testing.expectEqualStrings("a3gV", g_result_buf[0..g_result_len]);

    try testing.expectEqual(@as(u32, 4), base58_encode(&[_]u8{ 0x63, 0x63, 0x63 }, 3));
    try testing.expectEqualStrings("aPEr", g_result_buf[0..g_result_len]);
}

test "Base58 encode: leading zero bytes map to leading '1's" {
    // Two leading zero bytes -> two leading '1's, then encode(0x61)=="2g".
    try testing.expectEqual(@as(u32, 4), base58_encode(&[_]u8{ 0x00, 0x00, 0x61 }, 3));
    try testing.expectEqualStrings("112g", g_result_buf[0..g_result_len]);
}

test "Base58 decode: inverse of the Bitcoin Core vectors" {
    try testing.expectEqual(@as(u32, 1), base58_decode("2g", 2));
    try testing.expectEqualSlices(u8, &[_]u8{0x61}, g_result_buf[0..g_result_len]);

    try testing.expectEqual(@as(u32, 3), base58_decode("a3gV", 4));
    try testing.expectEqualSlices(u8, &[_]u8{ 0x62, 0x62, 0x62 }, g_result_buf[0..g_result_len]);

    // Invalid Base58 character ('0' is not in the alphabet) must be rejected.
    try testing.expectEqual(@as(u32, 0), base58_decode("0", 1));
    try testing.expectEqual(ERR_INVALID_INPUT, g_error_code);
}

test "Base58 multi-byte round-trips a 5-byte Bitcoin Core vector" {
    // hex 516b6fcd0f <-> "ABnLTmg" (bitcoin/src/test/data/base58_encode_decode.json).
    // This 5-byte value forces the big-integer carry to extend past one byte —
    // the exact path the previous decode implementation corrupted.
    const raw = [_]u8{ 0x51, 0x6b, 0x6f, 0xcd, 0x0f };

    try testing.expectEqual(@as(u32, 7), base58_encode(&raw, raw.len));
    try testing.expectEqualStrings("ABnLTmg", g_result_buf[0..g_result_len]);

    try testing.expectEqual(@as(u32, 5), base58_decode("ABnLTmg", 7));
    try testing.expectEqualSlices(u8, &raw, g_result_buf[0..g_result_len]);
}

test "verify_token: canonical jwt.io HS256 token verifies under its secret" {
    // External anchor: the jwt.io default example. This exercises the inline
    // Base64URL + HMAC-SHA256 + SHA-256 together against a token this repo did
    // not mint. Secret: "your-256-bit-secret". Payload has no "exp", so the
    // client-clock expiry branch is skipped.
    const secret = "your-256-bit-secret";
    try testing.expectEqual(ERR_OK, init(secret, secret.len));

    const token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." ++
        "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ." ++
        "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";

    try testing.expectEqual(@as(i32, 1), verify_token(token, token.len));
    try testing.expectEqualStrings("1234567890", g_result_buf[0..g_result_len]);
}

test "verify_token: tampered signature is rejected" {
    const secret = "your-256-bit-secret";
    try testing.expectEqual(ERR_OK, init(secret, secret.len));

    // Same token, last signature char flipped.
    const token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." ++
        "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ." ++
        "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5d";

    try testing.expectEqual(@as(i32, 0), verify_token(token, token.len));
    try testing.expectEqual(ERR_VERIFY_FAILED, g_error_code);
}

test "verify_token: wrong secret is rejected" {
    const secret = "not-the-right-secret";
    try testing.expectEqual(ERR_OK, init(secret, secret.len));

    const token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." ++
        "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ." ++
        "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";

    try testing.expectEqual(@as(i32, 0), verify_token(token, token.len));
    try testing.expectEqual(ERR_VERIFY_FAILED, g_error_code);
}

test "sign_token then verify_token round-trips and extracts the subject" {
    const secret = "my-secret-key-123";
    try testing.expectEqual(ERR_OK, init(secret, secret.len));

    const user = "user123";
    const tok_len = sign_token(user, user.len, 3600);
    try testing.expect(tok_len > 0);

    // Copy the token out before verify overwrites g_result_buf.
    var token: [512]u8 = undefined;
    @memcpy(token[0..tok_len], g_result_buf[0..tok_len]);

    try testing.expectEqual(@as(i32, 1), verify_token(&token, tok_len));
    try testing.expectEqualStrings("user123", g_result_buf[0..g_result_len]);
}

test "sign_token: a hostile subject cannot inject claims (JSON-IN-FMT)" {
    const secret = "my-secret-key-123";
    try testing.expectEqual(ERR_OK, init(secret, secret.len));

    // The classic break-out payload: an unescaped copy would close the `sub`
    // string and add an `admin` claim.
    const user = "x\",\"admin\":true,\"sub\":\"y";
    const tok_len = sign_token(user, user.len, 3600);
    try testing.expect(tok_len > 0);

    var token: [1024]u8 = undefined;
    @memcpy(token[0..tok_len], g_result_buf[0..tok_len]);

    // The payload segment must contain no unescaped quote from the subject:
    // decode it and check there is exactly one `admin`-free `sub` member.
    var dot1: usize = 0;
    var dot2: usize = 0;
    var seen: usize = 0;
    for (token[0..tok_len], 0..) |c, i| {
        if (c == '.') {
            if (seen == 0) dot1 = i else dot2 = i;
            seen += 1;
        }
    }
    var payload: [2048]u8 = undefined;
    const plen = base64UrlDecode(token[dot1 + 1 .. dot2], &payload).?;
    const decoded = payload[0..plen];
    // `admin` appears only INSIDE the escaped subject (\"admin\"), never as a
    // real member: the bare-quoted forms must be absent.
    try testing.expect(std.mem.indexOf(u8, decoded, "\"admin\"") == null);
    // ...and `sub` must occur exactly once as a real member.
    const first_sub = std.mem.indexOf(u8, decoded, "\"sub\":\"").?;
    try testing.expectEqual(@as(usize, 1), first_sub); // right after the '{'
    try testing.expect(std.mem.indexOfPos(u8, decoded, first_sub + 1, "\"sub\":\"") == null);

    // And the subject must round-trip literally through verification.
    try testing.expectEqual(@as(i32, 1), verify_token(&token, tok_len));
    try testing.expectEqualStrings(user, g_result_buf[0..g_result_len]);
}

test "sign_token: control characters in the subject are \\u00XX escaped" {
    const secret = "my-secret-key-123";
    try testing.expectEqual(ERR_OK, init(secret, secret.len));

    const user = "a\x01b\nc";
    const tok_len = sign_token(user, user.len, 3600);
    try testing.expect(tok_len > 0);

    var token: [1024]u8 = undefined;
    @memcpy(token[0..tok_len], g_result_buf[0..tok_len]);

    try testing.expectEqual(@as(i32, 1), verify_token(&token, tok_len));
    try testing.expectEqualStrings(user, g_result_buf[0..g_result_len]);
}

test "verify_token: a non-HS256 header alg is refused" {
    // Mint a token whose header says RS256 but whose signature is a valid
    // HMAC-SHA256 under the configured secret. Pre-hardening this verified.
    const secret = "my-secret-key-123";
    try testing.expectEqual(ERR_OK, init(secret, secret.len));

    const header = "{\"alg\":\"RS256\",\"typ\":\"JWT\"}";
    const payload = "{\"sub\":\"mallory\"}";

    var signing_input: [256]u8 = undefined;
    var n = base64UrlEncode(header, &signing_input);
    signing_input[n] = '.';
    n += 1;
    n += base64UrlEncode(payload, signing_input[n..]);

    const mac = hmacSha256(secret, signing_input[0..n]);
    var token: [512]u8 = undefined;
    @memcpy(token[0..n], signing_input[0..n]);
    token[n] = '.';
    const total = n + 1 + base64UrlEncode(&mac, token[n + 1 ..]);

    try testing.expectEqual(@as(i32, 0), verify_token(&token, @intCast(total)));
    try testing.expectEqual(ERR_VERIFY_FAILED, g_error_code);
}

test "verify_token: alg:none with an empty signature is refused" {
    const secret = "my-secret-key-123";
    try testing.expectEqual(ERR_OK, init(secret, secret.len));

    var token: [256]u8 = undefined;
    var n = base64UrlEncode("{\"alg\":\"none\",\"typ\":\"JWT\"}", &token);
    token[n] = '.';
    n += 1;
    n += base64UrlEncode("{\"sub\":\"root\"}", token[n..]);
    token[n] = '.';
    n += 1;

    try testing.expectEqual(@as(i32, 0), verify_token(&token, @intCast(n)));
    try testing.expectEqual(ERR_VERIFY_FAILED, g_error_code);
}

test "verify_token: an absurdly long exp does not overflow i64" {
    const secret = "my-secret-key-123";
    try testing.expectEqual(ERR_OK, init(secret, secret.len));

    // 60-digit exp — pre-hardening this panicked on integer overflow.
    const payload = "{\"sub\":\"a\",\"exp\":" ++ ("9" ** 60) ++ "}";
    const header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";

    var signing_input: [512]u8 = undefined;
    var n = base64UrlEncode(header, &signing_input);
    signing_input[n] = '.';
    n += 1;
    n += base64UrlEncode(payload, signing_input[n..]);

    const mac = hmacSha256(secret, signing_input[0..n]);
    var token: [768]u8 = undefined;
    @memcpy(token[0..n], signing_input[0..n]);
    token[n] = '.';
    const total = n + 1 + base64UrlEncode(&mac, token[n + 1 ..]);

    // Clamps to maxInt(i64) -> far-future -> valid, no crash.
    try testing.expectEqual(@as(i32, 1), verify_token(&token, @intCast(total)));
}

test "verify_token: a non-numeric exp is refused, not ignored" {
    const secret = "my-secret-key-123";
    try testing.expectEqual(ERR_OK, init(secret, secret.len));

    const header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const payload = "{\"sub\":\"a\",\"exp\":\"soon\"}";

    var signing_input: [256]u8 = undefined;
    var n = base64UrlEncode(header, &signing_input);
    signing_input[n] = '.';
    n += 1;
    n += base64UrlEncode(payload, signing_input[n..]);

    const mac = hmacSha256(secret, signing_input[0..n]);
    var token: [512]u8 = undefined;
    @memcpy(token[0..n], signing_input[0..n]);
    token[n] = '.';
    const total = n + 1 + base64UrlEncode(&mac, token[n + 1 ..]);

    try testing.expectEqual(@as(i32, 0), verify_token(&token, @intCast(total)));
    try testing.expectEqual(ERR_VERIFY_FAILED, g_error_code);
}

test "verify_token: expired token (exp < fixed test clock) is rejected" {
    const secret = "my-secret-key-123";
    try testing.expectEqual(ERR_OK, init(secret, secret.len));

    // native js_get_timestamp() == 1_700_000_000; sign with negative TTL so
    // exp lands in the past.
    const user = "user123";
    const tok_len = sign_token(user, user.len, -100);
    try testing.expect(tok_len > 0);

    var token: [512]u8 = undefined;
    @memcpy(token[0..tok_len], g_result_buf[0..tok_len]);

    try testing.expectEqual(@as(i32, 0), verify_token(&token, tok_len));
    try testing.expectEqual(ERR_TOKEN_EXPIRED, g_error_code);
}
