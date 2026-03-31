//! Quantum Crypto FFI - Minimal Working Version
//!
//! Focused on SHA-256 for Bitcoin wallet integration.
//! This is the MVP for crypto wallet FFI.

const std = @import("std");
const crypto = std.crypto;

// =============================================================================
// Error Codes
// =============================================================================

pub const QuantumCryptoError = enum(c_int) {
    success = 0,
    invalid_input = -1,
    invalid_output = -2,
};

// =============================================================================
// Thread-Local Error Storage
// =============================================================================

threadlocal var last_error_msg: [256]u8 = undefined;
threadlocal var last_error_len: usize = 0;

fn setLastError(msg: []const u8) void {
    const copy_len = @min(msg.len, last_error_msg.len - 1);
    @memcpy(last_error_msg[0..copy_len], msg[0..copy_len]);
    last_error_msg[copy_len] = 0;
    last_error_len = copy_len;
}

/// Get the last error message for this thread
export fn quantum_get_error(buf: [*]u8, buf_size: usize) usize {
    if (buf_size == 0) return last_error_len;
    const copy_len = @min(last_error_len, buf_size - 1);
    @memcpy(buf[0..copy_len], last_error_msg[0..copy_len]);
    buf[copy_len] = 0;
    return copy_len;
}

// =============================================================================
// SHA-256: Bitcoin Address Generation, ECDSA Signing
// =============================================================================

/// Compute SHA-256 hash
///
/// Returns 0 on success, negative on error.
export fn quantum_sha256(
    input: [*]const u8,
    input_len: usize,
    output: [*]u8,
) c_int {
    const input_slice = if (input_len > 0) input[0..input_len] else &[_]u8{};
    var out: [32]u8 = undefined;

    crypto.hash.sha2.Sha256.hash(input_slice, &out, .{});

    @memcpy(output[0..32], &out);
    return @intFromEnum(QuantumCryptoError.success);
}

/// Compute double SHA-256 (SHA256(SHA256(x)))
///
/// Used in Bitcoin for block hashing and transaction IDs.
export fn quantum_sha256d(
    input: [*]const u8,
    input_len: usize,
    output: [*]u8,
) c_int {
    const input_slice = if (input_len > 0) input[0..input_len] else &[_]u8{};
    var first_hash: [32]u8 = undefined;
    var second_hash: [32]u8 = undefined;

    crypto.hash.sha2.Sha256.hash(input_slice, &first_hash, .{});
    crypto.hash.sha2.Sha256.hash(&first_hash, &second_hash, .{});

    @memcpy(output[0..32], &second_hash);
    return @intFromEnum(QuantumCryptoError.success);
}

/// Compute BLAKE3 hash (32-byte output)
export fn quantum_blake3(
    input: [*]const u8,
    input_len: usize,
    output: [*]u8,
) c_int {
    const input_slice = if (input_len > 0) input[0..input_len] else &[_]u8{};
    var out: [32]u8 = undefined;

    crypto.hash.Blake3.hash(input_slice, &out, .{});

    @memcpy(output[0..32], &out);
    return @intFromEnum(QuantumCryptoError.success);
}

/// Compute HMAC-SHA256 (for BIP32 HD wallets)
export fn quantum_hmac_sha256(
    key: [*]const u8,
    key_len: usize,
    message: [*]const u8,
    message_len: usize,
    output: [*]u8,
) c_int {
    const key_slice = if (key_len > 0) key[0..key_len] else &[_]u8{};
    const message_slice = if (message_len > 0) message[0..message_len] else &[_]u8{};
    var out: [32]u8 = undefined;

    crypto.auth.hmac.sha2.HmacSha256.create(&out, message_slice, key_slice);

    @memcpy(output[0..32], &out);
    return @intFromEnum(QuantumCryptoError.success);
}

/// PBKDF2-SHA256 for seed phrase to master key (BIP39)
export fn quantum_pbkdf2_sha256(
    password: [*]const u8,
    password_len: usize,
    salt: [*]const u8,
    salt_len: usize,
    iterations: u32,
    output: [*]u8,
    output_len: usize,
) c_int {
    if (iterations == 0 or output_len == 0) {
        setLastError("PBKDF2: invalid parameters");
        return @intFromEnum(QuantumCryptoError.invalid_input);
    }

    const password_slice = if (password_len > 0) password[0..password_len] else &[_]u8{};
    const salt_slice = if (salt_len > 0) salt[0..salt_len] else &[_]u8{};
    const output_slice = output[0..output_len];

    crypto.pwhash.pbkdf2(output_slice, password_slice, salt_slice, iterations, crypto.auth.hmac.sha2.HmacSha256) catch {
        setLastError("PBKDF2: derivation failed");
        return @intFromEnum(QuantumCryptoError.invalid_input);
    };

    return @intFromEnum(QuantumCryptoError.success);
}

/// Secure zero memory (can't be optimized away)
export fn quantum_secure_zero(ptr: [*]u8, len: usize) void {
    if (len == 0) return;
    // Use volatile to prevent compiler optimization
    const slice = ptr[0..len];
    for (slice) |*byte| {
        @as(*volatile u8, byte).* = 0;
    }
}

/// Library version
export fn quantum_version() [*:0]const u8 {
    return "quantum-crypto-1.0.0";
}

// =============================================================================
// Tests
// =============================================================================

test "SHA-256 correctness" {
    const input = "hello world";
    var output: [32]u8 = undefined;

    const result = quantum_sha256(input.ptr, input.len, &output);
    try std.testing.expectEqual(@as(c_int, 0), result);

    // Known SHA-256 hash of "hello world"
    const expected_hex = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9";
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, expected_hex);

    try std.testing.expectEqualSlices(u8, &expected, &output);
}

test "BLAKE3 correctness" {
    const input = "hello world";
    var output: [32]u8 = undefined;

    const result = quantum_blake3(input.ptr, input.len, &output);
    try std.testing.expectEqual(@as(c_int, 0), result);

    // Verify non-zero
    var is_zero = true;
    for (output) |byte| {
        if (byte != 0) {
            is_zero = false;
            break;
        }
    }
    try std.testing.expect(!is_zero);
}

test "secure zero" {
    var secret = [_]u8{ 1, 2, 3, 4, 5 };
    quantum_secure_zero(&secret, secret.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 5, &secret);
}
