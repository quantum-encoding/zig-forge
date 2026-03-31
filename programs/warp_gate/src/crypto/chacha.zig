//! ═══════════════════════════════════════════════════════════════════════════
//! CHACHA20-POLY1305 Encryption
//! ═══════════════════════════════════════════════════════════════════════════
//!
//! AEAD encryption for Warp Gate transfers using Zig's stdlib crypto.
//! Each chunk is independently encrypted with a unique nonce derived
//! from the chunk sequence number.

const std = @import("std");
const builtin = @import("builtin");
const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

// Cross-platform random bytes
fn getRandomBytes(buf: []u8) void {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos => {
            std.c.arc4random_buf(buf.ptr, buf.len);
        },
        .linux => {
            _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
        },
        else => {
            // Fallback for other platforms
            for (buf) |*b| {
                b.* = 0;
            }
        },
    }
}

pub const KEY_SIZE = 32;
pub const NONCE_SIZE = 12;
pub const TAG_SIZE = 16;

/// Encrypted message with nonce and tag prepended
/// Format: [nonce: 12 bytes][ciphertext][tag: 16 bytes]
pub const EncryptedData = struct {
    nonce: [NONCE_SIZE]u8,
    ciphertext: []u8,
    tag: [TAG_SIZE]u8,
};

/// Encrypt a chunk with ChaCha20-Poly1305
pub fn encrypt(key: *const [KEY_SIZE]u8, plaintext: []const u8) ![]u8 {
    // Generate random nonce
    var nonce: [NONCE_SIZE]u8 = undefined;
    getRandomBytes(&nonce);

    // Allocate output: nonce + ciphertext + tag
    const output_len = NONCE_SIZE + plaintext.len + TAG_SIZE;
    var output = try std.heap.page_allocator.alloc(u8, output_len);
    errdefer std.heap.page_allocator.free(output);

    // Copy nonce to output
    @memcpy(output[0..NONCE_SIZE], &nonce);

    // Encrypt in place (ciphertext goes after nonce, tag at end)
    var tag: [TAG_SIZE]u8 = undefined;
    ChaCha20Poly1305.encrypt(
        output[NONCE_SIZE .. NONCE_SIZE + plaintext.len],
        &tag,
        plaintext,
        &.{}, // No additional data
        nonce,
        key.*,
    );

    // Append tag
    @memcpy(output[NONCE_SIZE + plaintext.len ..], &tag);

    return output;
}

/// Decrypt a chunk
pub fn decrypt(key: *const [KEY_SIZE]u8, encrypted: []const u8) ![]u8 {
    if (encrypted.len < NONCE_SIZE + TAG_SIZE) {
        return error.InvalidCiphertext;
    }

    // Extract components
    const nonce = encrypted[0..NONCE_SIZE].*;
    const ciphertext_len = encrypted.len - NONCE_SIZE - TAG_SIZE;
    const ciphertext = encrypted[NONCE_SIZE .. NONCE_SIZE + ciphertext_len];
    const tag = encrypted[NONCE_SIZE + ciphertext_len ..][0..TAG_SIZE].*;

    // Allocate plaintext
    const plaintext = try std.heap.page_allocator.alloc(u8, ciphertext_len);
    errdefer std.heap.page_allocator.free(plaintext);

    // Decrypt
    ChaCha20Poly1305.decrypt(
        plaintext,
        ciphertext,
        tag,
        &.{}, // No additional data
        nonce,
        key.*,
    ) catch return error.AuthenticationFailed;

    return plaintext;
}

/// Encrypt with sequence number as nonce (for ordered streams)
pub fn encryptWithSeq(
    key: *const [KEY_SIZE]u8,
    plaintext: []const u8,
    sequence: u64,
    output: []u8,
) !void {
    if (output.len < plaintext.len + TAG_SIZE) {
        return error.BufferTooSmall;
    }

    // Derive nonce from sequence
    var nonce: [NONCE_SIZE]u8 = [_]u8{0} ** NONCE_SIZE;
    std.mem.writeInt(u64, nonce[4..12], sequence, .big);

    var tag: [TAG_SIZE]u8 = undefined;
    ChaCha20Poly1305.encrypt(
        output[0..plaintext.len],
        &tag,
        plaintext,
        &.{},
        nonce,
        key.*,
    );

    @memcpy(output[plaintext.len .. plaintext.len + TAG_SIZE], &tag);
}

/// Decrypt with sequence number
pub fn decryptWithSeq(
    key: *const [KEY_SIZE]u8,
    ciphertext: []const u8,
    sequence: u64,
    output: []u8,
) !void {
    if (ciphertext.len < TAG_SIZE) {
        return error.InvalidCiphertext;
    }

    const plaintext_len = ciphertext.len - TAG_SIZE;
    if (output.len < plaintext_len) {
        return error.BufferTooSmall;
    }

    // Derive nonce from sequence
    var nonce: [NONCE_SIZE]u8 = [_]u8{0} ** NONCE_SIZE;
    std.mem.writeInt(u64, nonce[4..12], sequence, .big);

    const tag = ciphertext[plaintext_len..][0..TAG_SIZE].*;

    ChaCha20Poly1305.decrypt(
        output[0..plaintext_len],
        ciphertext[0..plaintext_len],
        tag,
        &.{},
        nonce,
        key.*,
    ) catch return error.AuthenticationFailed;
}

/// Securely zero memory
pub fn secureZero(buf: []u8) void {
    // Use volatile memset to prevent optimization
    const ptr: [*]volatile u8 = @ptrCast(buf.ptr);
    for (0..buf.len) |i| {
        ptr[i] = 0;
    }
}

/// X25519 key exchange for establishing shared secret
pub const KeyExchange = struct {
    secret_key: [32]u8,
    public_key: [32]u8,

    pub fn generate() KeyExchange {
        var secret_key: [32]u8 = undefined;
        std.c.arc4random_buf(&secret_key, secret_key.len);

        const public_key = std.crypto.dh.X25519.recoverPublicKey(secret_key) catch unreachable;

        return KeyExchange{
            .secret_key = secret_key,
            .public_key = public_key,
        };
    }

    /// Compute shared secret from peer's public key
    pub fn computeShared(self: *const KeyExchange, peer_public: [32]u8) ![32]u8 {
        return std.crypto.dh.X25519.scalarmult(self.secret_key, peer_public) catch
            return error.InvalidPublicKey;
    }

    pub fn deinit(self: *KeyExchange) void {
        secureZero(&self.secret_key);
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════

test "encrypt/decrypt round-trip" {
    const key = [_]u8{0x42} ** KEY_SIZE;
    const plaintext = "Hello, Warp Gate!";

    const encrypted = try encrypt(&key, plaintext);
    defer std.heap.page_allocator.free(encrypted);

    const decrypted = try decrypt(&key, encrypted);
    defer std.heap.page_allocator.free(decrypted);

    try std.testing.expectEqualStrings(plaintext, decrypted);
}

test "decrypt with wrong key fails" {
    const key1 = [_]u8{0x42} ** KEY_SIZE;
    const key2 = [_]u8{0x43} ** KEY_SIZE;
    const plaintext = "Secret message";

    const encrypted = try encrypt(&key1, plaintext);
    defer std.heap.page_allocator.free(encrypted);

    try std.testing.expectError(error.AuthenticationFailed, decrypt(&key2, encrypted));
}

test "sequence-based encryption" {
    const key = [_]u8{0x42} ** KEY_SIZE;
    const plaintext = "Chunk data";
    var output: [256]u8 = undefined;
    var decrypted: [256]u8 = undefined;

    try encryptWithSeq(&key, plaintext, 42, &output);
    try decryptWithSeq(&key, output[0 .. plaintext.len + TAG_SIZE], 42, &decrypted);

    try std.testing.expectEqualStrings(plaintext, decrypted[0..plaintext.len]);
}

test "key exchange produces shared secret" {
    var alice = KeyExchange.generate();
    defer alice.deinit();

    var bob = KeyExchange.generate();
    defer bob.deinit();

    const alice_shared = try alice.computeShared(bob.public_key);
    const bob_shared = try bob.computeShared(alice.public_key);

    try std.testing.expectEqualSlices(u8, &alice_shared, &bob_shared);
}
