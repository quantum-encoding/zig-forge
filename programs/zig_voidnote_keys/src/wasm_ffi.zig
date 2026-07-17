//! VoidNote Keys — WASM FFI
//!
//! Cryptographic primitives for the VoidNote API key system.
//! Provides:
//!   - generate_api_key() → "vn_" + 64 hex chars (32 random bytes)
//!   - hmac_sha256(secret, message) → 64-char hex HMAC
//!   - hmac_sha256_verify(secret, message, expected_hex) → 1 (valid) or 0 (invalid)
//!   - clear_result_buf() → MUST be called after copying a sensitive result
//!
//! SHA-256 and HMAC-SHA256 come from std.crypto (audited, pure Zig, compiles
//! for wasm32-freestanding) — no hand-rolled crypto. See src/tier1_anchors.zig
//! for the NIST CAVP SHA-256 + RFC 4231 HMAC external-vector test suite.
//! Target: wasm32-freestanding for Cloudflare Workers.
//!
//! JS host must provide:
//!   env.js_get_random_bytes(ptr: i32, len: i32) → void
//!   (fills memory[ptr..ptr+len] with crypto-secure random bytes)
//!
//! ──────────────────────────────────────────────────────────────────────
//!  LIFECYCLE CONTRACT — read before integrating
//! ──────────────────────────────────────────────────────────────────────
//!
//! The result buffer (g_result_buf) is a GLOBAL inside the WASM instance.
//! After generate_api_key() / hmac_sha256() returns, the result bytes
//! remain in g_result_buf until the next call overwrites them OR until
//! clear_result_buf() is called.
//!
//! For SENSITIVE results (a freshly-generated API key, in particular), the
//! JS host MUST follow this sequence:
//!
//!   const len = wasm.generate_api_key();
//!   const ptr = wasm.get_result_ptr();
//!   const key = new TextDecoder().decode(
//!       new Uint8Array(wasm.memory.buffer, ptr, len)
//!   );
//!   wasm.clear_result_buf();   // ← required, NOT optional
//!
//! Without that final call, the key bytes persist in WASM linear memory
//! and are recoverable by any subsequent caller using the same WASM
//! instance (e.g. another route handler in the same Worker request). The
//! HMAC functions also leak the MAC bytes via the same channel — clear
//! after reading those too if they're sensitive in your threat model.

const std = @import("std");
const builtin = @import("builtin");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

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

/// Import crypto-secure random bytes from the JS host (crypto.getRandomValues).
/// Only linked on the wasm32-freestanding target; native builds (the test
/// target) use a std.Random CSPRNG via getRandomBytes below so the module can
/// be compiled and exercised without a JS host.
extern "env" fn js_get_random_bytes(ptr: [*]u8, len: u32) void;

/// Fill ptr[0..len] with crypto-secure random bytes. On wasm this delegates to
/// the JS host import (unchanged ABI); on native it uses a std.Random CSPRNG.
/// The comptime branch means the extern symbol is never referenced in a native
/// build, so the test executable links cleanly.
fn getRandomBytes(ptr: [*]u8, len: u32) void {
    if (comptime builtin.target.cpu.arch == .wasm32) {
        js_get_random_bytes(ptr, len);
    } else {
        // Native (test-only) path — production is wasm and always uses the JS
        // host import above. Seed a CSPRNG from a monotonic + address entropy
        // mix so the generate_api_key test can exercise the full code path
        // without a JS host. This branch is never compiled into the shipped
        // wasm binary (comptime-eliminated).
        var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
        const t: u128 = @bitCast(std.time.nanoTimestamp());
        var i: usize = 0;
        while (i < seed.len) : (i += 1) {
            seed[i] = @truncate((t >> @intCast((i % 16) * 8)) ^ @intFromPtr(ptr));
        }
        var csprng = std.Random.DefaultCsprng.init(seed);
        csprng.random().bytes(ptr[0..len]);
    }
}

// ==========================================================================
// SHA-256 / HMAC-SHA256 — std.crypto (audited, constant-time, pure Zig)
// ==========================================================================
//
// The hand-rolled FIPS-180-4 SHA-256 + FIPS-198 HMAC that previously lived
// here (~150 LOC) had zero tests and authenticated live payment webhooks —
// the exact zig_base58 failure class. It is replaced by std.crypto, whose
// output is pinned to NIST CAVP SHA-256 and all seven RFC 4231 HMAC-SHA256
// vectors in src/tier1_anchors.zig. std.crypto.auth.hmac.sha2.HmacSha256
// compiles for wasm32-freestanding and produces byte-identical output.

fn hmacSha256(key: []const u8, message: []const u8) [HmacSha256.mac_length]u8 {
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, message, key);
    return mac;
}

// ==========================================================================
// Secure wipe helpers
// ==========================================================================
//
// std.crypto.secureZero would normally do this — but we keep this module's
// dependency surface minimal (per the file header) so we write the volatile
// loop inline. The `volatile` cast prevents LLVM dead-store elimination
// from dropping the writes when it can prove the buffer is freed/unused.

fn zeroResultBuf() void {
    const ptr: [*]volatile u8 = &g_result_buf;
    var i: usize = 0;
    while (i < g_result_buf.len) : (i += 1) ptr[i] = 0;
}

fn secureWipe(buf: []u8) void {
    const ptr: [*]volatile u8 = buf.ptr;
    var i: usize = 0;
    while (i < buf.len) : (i += 1) ptr[i] = 0;
}

// ==========================================================================
// Exported API
// ==========================================================================

/// Generate a VoidNote API key: "vn_" + 64 lowercase hex chars (32 random bytes).
/// Returns 67 on success, 0 on error.
/// Read the key with get_result_ptr() / get_result_len(), then call
/// clear_result_buf() to wipe it. See the file-header LIFECYCLE CONTRACT.
pub export fn generate_api_key() u32 {
    // Wipe any leftover bytes from a previous call. Defense-in-depth: even
    // if a previous caller forgot to clear_result_buf(), we don't leave a
    // longer/older result mingled with the new key in g_result_buf.
    zeroResultBuf();

    var raw: [32]u8 = undefined;
    getRandomBytes(&raw, 32);

    g_result_buf[0] = 'v';
    g_result_buf[1] = 'n';
    g_result_buf[2] = '_';
    for (raw, 0..) |byte, i| {
        g_result_buf[3 + i * 2]     = hex_chars[byte >> 4];
        g_result_buf[3 + i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    // Wipe the local random buffer too — it's stack-allocated and may
    // outlive this function via stack reuse / core-dump exposure.
    secureWipe(&raw);
    g_result_len = 67;
    g_error_code = ERR_OK;
    return 67;
}

/// Compute HMAC-SHA256(secret, message).
/// Writes 64 lowercase hex chars to the result buffer.
/// Returns 64 on success, 0 on invalid input.
/// Read result with get_result_ptr() / get_result_len(), then call
/// clear_result_buf() if the MAC is sensitive in your threat model.
pub export fn hmac_sha256(
    secret_ptr: [*]const u8,
    secret_len: u32,
    msg_ptr: [*]const u8,
    msg_len: u32,
) u32 {
    if (secret_len == 0 or secret_len > 4096 or msg_len > 65536) {
        g_error_code = ERR_INVALID_INPUT;
        return 0;
    }
    // Wipe any leftover result bytes before writing the new MAC.
    zeroResultBuf();
    var mac = hmacSha256(secret_ptr[0..secret_len], msg_ptr[0..msg_len]);
    for (mac, 0..) |byte, i| {
        g_result_buf[i * 2]     = hex_chars[byte >> 4];
        g_result_buf[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    // Local MAC copy is no longer needed; wipe it.
    secureWipe(&mac);
    g_result_len = 64;
    g_error_code = ERR_OK;
    return 64;
}

/// Constant-time HMAC-SHA256 verification.
/// expected_hex_ptr must point to exactly 64 lowercase hex chars.
/// Returns 1 if valid, 0 if invalid.
pub export fn hmac_sha256_verify(
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
    // hmac_sha256() left the computed MAC hex in g_result_buf. Wipe it so a
    // verification never leaves a valid MAC readable via get_result_ptr()
    // (a forgeable-signature oracle for a subsequent caller in the same
    // WASM instance). See F4 in the audit report.
    zeroResultBuf();
    g_result_len = 0;
    return if (diff == 0) @as(i32, 1) else @as(i32, 0);
}

/// Pointer to the result buffer (JS reads result from here after a call)
pub export fn get_result_ptr() [*]const u8 {
    return &g_result_buf;
}

/// Length of the most recent result
pub export fn get_result_len() u32 {
    return @intCast(g_result_len);
}

/// Last error code (0 = ok, -1 = invalid input)
pub export fn get_error_code() i32 {
    return g_error_code;
}

/// Wipe the result buffer.
///
/// JS host MUST call this after copying a sensitive result (a freshly-
/// generated API key from generate_api_key(), or an HMAC of a sensitive
/// message) out to JS memory. Without it, the buffer retains the bytes
/// until the next call overwrites them — and a subsequent caller using
/// the same WASM instance (e.g. a different route handler in the same
/// Cloudflare Worker request) could recover them via get_result_ptr().
///
/// Implemented as a volatile loop so dead-store elimination cannot drop
/// the writes. Also resets g_result_len = 0 and g_error_code = ERR_OK so a
/// subsequent caller can't observe stale state.
pub export fn clear_result_buf() void {
    zeroResultBuf();
    g_result_len = 0;
    g_error_code = ERR_OK;
}
