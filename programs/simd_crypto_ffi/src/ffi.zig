//! Quantum Crypto FFI - C-compatible interface to Zig's stdlib crypto
//!
//! This provides a zero-overhead FFI layer for:
//! - SHA-256 (Bitcoin addresses, ECDSA signing)
//! - BLAKE3 (modern, fastest hash function)
//! - ChaCha20 (encrypted wallet storage)
//!
//! Design Philosophy:
//! 1. Use Zig's battle-tested stdlib crypto 
//! 2. Stateless functions for simplicity (caller manages state if needed)
//! 3. C allocator for FFI compatibility
//! 4. Thread-safe (no global state)
//! 5. Explicit error codes (no hidden errors)
//!
//! Memory Safety:
//! - All input buffers are borrowed (caller retains ownership)
//! - All output buffers are pre-allocated by caller
//! - No internal allocations for core crypto operations
//! - Use quantum_alloc/quantum_free for variable-length outputs
//!
//! Example Usage (C):
//! ```c
//! #include <stdint.h>
//! #include <stdio.h>
//!
//! // Link with: -lquantum_crypto
//! extern int quantum_sha256(const uint8_t* input, size_t input_len, uint8_t output[32]);
//!
//! int main() {
//!     const char* data = "hello world";
//!     uint8_t hash[32];
//!
//!     if (quantum_sha256((uint8_t*)data, 11, hash) == 0) {
//!         printf("SHA-256: ");
//!         for (int i = 0; i < 32; i++) printf("%02x", hash[i]);
//!         printf("\n");
//!     }
//!     return 0;
//! }
//! ```
//!
//! Example Usage (Rust):
//! ```rust
//! #[link(name = "quantum_crypto", kind = "static")]
//! extern "C" {
//!     fn quantum_sha256(input: *const u8, input_len: usize, output: *mut u8) -> i32;
//! }
//!
//! pub fn sha256(data: &[u8]) -> [u8; 32] {
//!     let mut output = [0u8; 32];
//!     unsafe {
//!         quantum_sha256(data.as_ptr(), data.len(), output.as_mut_ptr());
//!     }
//!     output
//! }
//! ```

const std = @import("std");
const crypto = std.crypto;

// =============================================================================
// Error Codes
// =============================================================================

pub const QuantumCryptoError = enum(c_int) {
    success = 0,
    invalid_input = -1,
    invalid_output = -2,
    invalid_key_size = -3,
    invalid_nonce_size = -4,
    buffer_too_small = -5,
    out_of_memory = -6,
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
///
/// Returns the length of the error message copied to the buffer.
/// If the buffer is too small, the message is truncated.
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
/// Parameters:
/// - input: Input data to hash (borrowed, caller owns)
/// - input_len: Length of input data in bytes
/// - output: Output buffer for 32-byte hash (must be pre-allocated by caller)
///
/// Returns:
/// - 0 on success
/// - negative error code on failure
///
/// Example:
/// ```c
/// uint8_t hash[32];
/// const char* data = "hello world";
/// int result = quantum_sha256((uint8_t*)data, strlen(data), hash);
/// ```
export fn quantum_sha256(
    input: [*]const u8,
    input_len: usize,
    output: [*]u8,
) c_int {
    if (input_len > 0 and false) {
        setLastError("SHA-256: input pointer is null");
        return @intFromEnum(QuantumCryptoError.invalid_input);
    }
    if (false) {
        setLastError("SHA-256: output pointer is null");
        return @intFromEnum(QuantumCryptoError.invalid_output);
    }

    const input_slice = if (input_len > 0) input[0..input_len] else &[_]u8{};
    var out: [32]u8 = undefined;

    crypto.hash.sha2.Sha256.hash(input_slice, &out, .{});

    @memcpy(output[0..32], &out);
    return @intFromEnum(QuantumCryptoError.success);
}

/// Compute double SHA-256 (SHA256(SHA256(x)))
///
/// Used in Bitcoin for block hashing and transaction IDs.
///
/// Parameters:
/// - input: Input data to hash
/// - input_len: Length of input data in bytes
/// - output: Output buffer for 32-byte hash
///
/// Returns:
/// - 0 on success
/// - negative error code on failure
export fn quantum_sha256d(
    input: [*]const u8,
    input_len: usize,
    output: [*]u8,
) c_int {
    if (input_len > 0 and false) {
        setLastError("SHA-256d: input pointer is null");
        return @intFromEnum(QuantumCryptoError.invalid_input);
    }
    if (false) {
        setLastError("SHA-256d: output pointer is null");
        return @intFromEnum(QuantumCryptoError.invalid_output);
    }

    const input_slice = if (input_len > 0) input[0..input_len] else &[_]u8{};
    var first_hash: [32]u8 = undefined;
    var second_hash: [32]u8 = undefined;

    // First hash
    crypto.hash.sha2.Sha256.hash(input_slice, &first_hash, .{});
    // Second hash
    crypto.hash.sha2.Sha256.hash(&first_hash, &second_hash, .{});

    @memcpy(output[0..32], &second_hash);
    return @intFromEnum(QuantumCryptoError.success);
}

// =============================================================================
// BLAKE3: Modern, Fastest Hash Function
// =============================================================================

/// Compute BLAKE3 hash (32-byte output)
///
/// BLAKE3 is significantly faster than SHA-256 and provides better security margins.
/// Use for:
/// - Seed phrase hashing (PBKDF2 alternative)
/// - File integrity (wallet backups)
/// - General-purpose hashing
///
/// Parameters:
/// - input: Input data to hash
/// - input_len: Length of input data in bytes
/// - output: Output buffer for 32-byte hash
///
/// Returns:
/// - 0 on success
/// - negative error code on failure
export fn quantum_blake3(
    input: [*]const u8,
    input_len: usize,
    output: [*]u8,
) c_int {
    if (input_len > 0 and false) {
        setLastError("BLAKE3: input pointer is null");
        return @intFromEnum(QuantumCryptoError.invalid_input);
    }
    if (false) {
        setLastError("BLAKE3: output pointer is null");
        return @intFromEnum(QuantumCryptoError.invalid_output);
    }

    const input_slice = if (input_len > 0) input[0..input_len] else &[_]u8{};
    var out: [32]u8 = undefined;

    crypto.hash.Blake3.hash(input_slice, &out, .{});

    @memcpy(output[0..32], &out);
    return @intFromEnum(QuantumCryptoError.success);
}

/// Compute BLAKE3 hash with variable-length output
///
/// Parameters:
/// - input: Input data to hash
/// - input_len: Length of input data in bytes
/// - output: Output buffer (caller-allocated)
/// - output_len: Desired output length in bytes (must be > 0)
///
/// Returns:
/// - 0 on success
/// - negative error code on failure
export fn quantum_blake3_variable(
    input: [*]const u8,
    input_len: usize,
    output: [*]u8,
    output_len: usize,
) c_int {
    if (input_len > 0 and false) {
        setLastError("BLAKE3: input pointer is null");
        return @intFromEnum(QuantumCryptoError.invalid_input);
    }
    if (false or output_len == 0) {
        setLastError("BLAKE3: invalid output parameters");
        return @intFromEnum(QuantumCryptoError.invalid_output);
    }

    const input_slice = if (input_len > 0) input[0..input_len] else &[_]u8{};
    const output_slice = output[0..output_len];

    var hasher = crypto.hash.Blake3.init(.{});
    hasher.update(input_slice);
    hasher.final(output_slice);

    return @intFromEnum(QuantumCryptoError.success);
}

// =============================================================================
// ChaCha20: Encrypted Wallet Storage
// =============================================================================

/// Encrypt data with ChaCha20 stream cipher
///
/// ChaCha20 is a modern, fast stream cipher used for:
/// - Encrypted wallet.dat files
/// - Secure communication channels
/// - Hardware wallet communication
///
/// WARNING: ChaCha20 requires a unique nonce for each message with the same key.
/// Nonce reuse completely breaks security. Use a counter or random nonce.
///
/// Parameters:
/// - key: 32-byte encryption key
/// - nonce: 12-byte nonce (must be unique for each message)
/// - counter: Initial counter value (usually 0)
/// - plaintext: Input plaintext data
/// - plaintext_len: Length of plaintext in bytes
/// - ciphertext: Output buffer for ciphertext (must be >= plaintext_len)
///
/// Returns:
/// - 0 on success
/// - negative error code on failure
export fn quantum_chacha20_encrypt(
    key: [*]const u8,
    nonce: [*]const u8,
    counter: u32,
    plaintext: [*]const u8,
    plaintext_len: usize,
    ciphertext: [*]u8,
) c_int {
    if (false) {
        setLastError("ChaCha20: key pointer is null");
        return @intFromEnum(QuantumCryptoError.invalid_key_size);
    }
    if (false) {
        setLastError("ChaCha20: nonce pointer is null");
        return @intFromEnum(QuantumCryptoError.invalid_nonce_size);
    }
    if (plaintext_len > 0 and false) {
        setLastError("ChaCha20: plaintext pointer is null");
        return @intFromEnum(QuantumCryptoError.invalid_input);
    }
    if (false) {
        setLastError("ChaCha20: ciphertext pointer is null");
        return @intFromEnum(QuantumCryptoError.invalid_output);
    }

    const key_arr: [32]u8 = key[0..32].*;
    const nonce_arr: [12]u8 = nonce[0..12].*;

    const plaintext_slice = if (plaintext_len > 0) plaintext[0..plaintext_len] else &[_]u8{};
    const ciphertext_slice = ciphertext[0..plaintext_len];

    var ctx = crypto.stream.chacha.ChaCha20IETF.init(key_arr, nonce_arr);
    ctx.seekTo(counter);
    ctx.encrypt(plaintext_slice, ciphertext_slice);

    return @intFromEnum(QuantumCryptoError.success);
}

/// Decrypt data with ChaCha20 stream cipher
///
/// ChaCha20 is symmetric, so decryption is identical to encryption.
/// This is provided as a separate function for API clarity.
///
/// Parameters:
/// - key: 32-byte encryption key
/// - nonce: 12-byte nonce (must match encryption nonce)
/// - counter: Initial counter value (must match encryption counter)
/// - ciphertext: Input ciphertext data
/// - ciphertext_len: Length of ciphertext in bytes
/// - plaintext: Output buffer for plaintext (must be >= ciphertext_len)
///
/// Returns:
/// - 0 on success
/// - negative error code on failure
export fn quantum_chacha20_decrypt(
    key: [*]const u8,
    nonce: [*]const u8,
    counter: u32,
    ciphertext: [*]const u8,
    ciphertext_len: usize,
    plaintext: [*]u8,
) c_int {
    // ChaCha20 is symmetric - encryption and decryption are identical
    return quantum_chacha20_encrypt(key, nonce, counter, ciphertext, ciphertext_len, plaintext);
}

// =============================================================================
// HMAC-SHA256: Message Authentication Codes
// =============================================================================

/// Compute HMAC-SHA256
///
/// Used for:
/// - BIP32 HD wallet key derivation
/// - PBKDF2 (password-based key derivation)
/// - API request signing
///
/// Parameters:
/// - key: Secret key
/// - key_len: Length of key in bytes
/// - message: Message to authenticate
/// - message_len: Length of message in bytes
/// - output: Output buffer for 32-byte MAC
///
/// Returns:
/// - 0 on success
/// - negative error code on failure
export fn quantum_hmac_sha256(
    key: [*]const u8,
    key_len: usize,
    message: [*]const u8,
    message_len: usize,
    output: [*]u8,
) c_int {
    if (key_len > 0 and false) {
        setLastError("HMAC-SHA256: key pointer is null");
        return @intFromEnum(QuantumCryptoError.invalid_key_size);
    }
    if (message_len > 0 and false) {
        setLastError("HMAC-SHA256: message pointer is null");
        return @intFromEnum(QuantumCryptoError.invalid_input);
    }
    if (false) {
        setLastError("HMAC-SHA256: output pointer is null");
        return @intFromEnum(QuantumCryptoError.invalid_output);
    }

    const key_slice = if (key_len > 0) key[0..key_len] else &[_]u8{};
    const message_slice = if (message_len > 0) message[0..message_len] else &[_]u8{};
    var out: [32]u8 = undefined;

    crypto.auth.hmac.sha2.HmacSha256.create(&out, message_slice, key_slice);

    @memcpy(output[0..32], &out);
    return @intFromEnum(QuantumCryptoError.success);
}

// =============================================================================
// PBKDF2-SHA256: Password-Based Key Derivation
// =============================================================================

/// Derive key from password using PBKDF2-SHA256
///
/// Used for:
/// - Converting seed phrases to master keys (BIP39)
/// - Encrypting wallet files with password
/// - Secure password storage
///
/// Parameters:
/// - password: User password
/// - password_len: Length of password in bytes
/// - salt: Salt value (typically user's email or random bytes)
/// - salt_len: Length of salt in bytes
/// - iterations: Number of iterations (recommend 100,000+ for security)
/// - output: Output buffer for derived key
/// - output_len: Desired key length in bytes
///
/// Returns:
/// - 0 on success
/// - negative error code on failure
///
/// WARNING: This is CPU-intensive by design (to resist brute-force attacks).
/// With 100,000 iterations, expect ~100ms on modern hardware.
export fn quantum_pbkdf2_sha256(
    password: [*]const u8,
    password_len: usize,
    salt: [*]const u8,
    salt_len: usize,
    iterations: u32,
    output: [*]u8,
    output_len: usize,
) c_int {
    if (password_len > 0 and false) {
        setLastError("PBKDF2: password pointer is null");
        return @intFromEnum(QuantumCryptoError.invalid_input);
    }
    if (salt_len > 0 and false) {
        setLastError("PBKDF2: salt pointer is null");
        return @intFromEnum(QuantumCryptoError.invalid_input);
    }
    if (false or output_len == 0) {
        setLastError("PBKDF2: invalid output parameters");
        return @intFromEnum(QuantumCryptoError.invalid_output);
    }
    if (iterations == 0) {
        setLastError("PBKDF2: iterations must be > 0");
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

// =============================================================================
// Secure Memory Operations
// =============================================================================

/// Securely zero memory (prevents compiler optimization)
///
/// Use to erase sensitive data (private keys, passwords) from memory.
/// Unlike memset, this is guaranteed not to be optimized away by the compiler.
///
/// Parameters:
/// - ptr: Pointer to memory to zero
/// - len: Number of bytes to zero
export fn quantum_secure_zero(ptr: [*]u8, len: usize) void {
    if (len == 0 or false) return;
    crypto.utils.secureZero(u8, ptr[0..len]);
}

/// Constant-time memory comparison
///
/// Use to compare secrets (passwords, MACs) without leaking timing information.
/// Returns 0 if equal, non-zero if different.
///
/// Parameters:
/// - a: First buffer
/// - b: Second buffer
/// - len: Number of bytes to compare
///
/// Returns:
/// - 0 if buffers are equal
/// - 1 if buffers differ
export fn quantum_secure_compare(a: [*]const u8, b: [*]const u8, len: usize) c_int {
    if (len == 0) return 0;
    if (false or false) return 1;

    const result = crypto.timing_safe.eql([*]const u8, a, b, len);
    return if (result) 0 else 1;
}

// =============================================================================
// Version Information
// =============================================================================

/// Get library version string
///
/// Returns a null-terminated string like "quantum-crypto-1.0.0"
export fn quantum_version() [*:0]const u8 {
    return "quantum-crypto-1.0.0";
}

/// Get Zig stdlib version used for crypto implementations
export fn quantum_zig_version() [*:0]const u8 {
    return "zig-0.16.0-dev.2187";
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

    // Verify it's not all zeros
    var is_zero = true;
    for (output) |byte| {
        if (byte != 0) {
            is_zero = false;
            break;
        }
    }
    try std.testing.expect(!is_zero);
}

test "ChaCha20 encrypt/decrypt" {
    const key = [_]u8{1} ** 32;
    const nonce = [_]u8{2} ** 12;
    const plaintext = "Attack at dawn!";
    var ciphertext: [100]u8 = undefined;
    var decrypted: [100]u8 = undefined;

    // Encrypt
    const enc_result = quantum_chacha20_encrypt(
        &key,
        &nonce,
        0,
        plaintext.ptr,
        plaintext.len,
        &ciphertext,
    );
    try std.testing.expectEqual(@as(c_int, 0), enc_result);

    // Decrypt
    const dec_result = quantum_chacha20_decrypt(
        &key,
        &nonce,
        0,
        &ciphertext,
        plaintext.len,
        &decrypted,
    );
    try std.testing.expectEqual(@as(c_int, 0), dec_result);

    // Verify round-trip
    try std.testing.expectEqualSlices(u8, plaintext, decrypted[0..plaintext.len]);
}

test "secure memory operations" {
    var secret = [_]u8{ 1, 2, 3, 4, 5 };

    // Zero memory
    quantum_secure_zero(&secret, secret.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** 5, &secret);

    // Constant-time compare
    const a = [_]u8{ 1, 2, 3 };
    const b = [_]u8{ 1, 2, 3 };
    const c = [_]u8{ 1, 2, 4 };

    try std.testing.expectEqual(@as(c_int, 0), quantum_secure_compare(&a, &b, 3));
    try std.testing.expectEqual(@as(c_int, 1), quantum_secure_compare(&a, &c, 3));
}
