//! Tier-1 externally-anchored test vectors for zig_voidnote_keys.
//!
//! Per /CLAUDE.md golden rule #1: this module authenticates live Stripe /
//! AlchemyPay payment webhooks and mints production API keys with SHA-256 /
//! HMAC-SHA256. Before it can be relied on, its crypto output MUST be pinned
//! to test vectors whose inputs AND expected outputs come from a source the
//! author did not write. Roundtrip tests do not count.
//!
//! Anchors used here:
//!   - SHA-256: NIST FIPS 180-2 / CAVP known-answer vectors
//!     (empty string, "abc", 448-bit and 896-bit multi-block messages).
//!   - HMAC-SHA256: all seven RFC 4231 §4 test cases, including the
//!     truncation case (TC5) and the two >64-byte-key cases (TC6, TC7)
//!     that exercise HMAC's key-hashing branch.
//!
//! The HMAC cases are driven THROUGH the module's exported `hmac_sha256`
//! entry point (not std.crypto directly), so they validate the actual FFI
//! path a webhook verifier calls — hex formatting, buffer plumbing, and all.
//!
//! Removing or weakening this file requires a re-audit, not a refactor.

const std = @import("std");
const testing = std.testing;
const wfk = @import("wasm_ffi.zig");

// ==========================================================================
// SHA-256 — NIST FIPS 180-2 / CAVP known-answer vectors
// ==========================================================================
//
// std.crypto.hash.sha2.Sha256 is the primitive the module's HMAC is built
// on. Pin it to the published NIST vectors so a regression in std or in the
// wasm build surfaces here rather than in a rejected payment webhook.

const Sha256 = std.crypto.hash.sha2.Sha256;

fn sha256Hex(msg: []const u8) [64]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(msg, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "SHA-256 NIST vector: empty string" {
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &sha256Hex(""),
    );
}

test "SHA-256 NIST vector: abc" {
    try testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &sha256Hex("abc"),
    );
}

test "SHA-256 NIST vector: 448-bit message (two-block boundary)" {
    // FIPS 180-2 Appendix B.2 — 56-byte input exercises the padding edge
    // where the 0x80 + length no longer fit in the final block.
    try testing.expectEqualStrings(
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
        &sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
    );
}

test "SHA-256 NIST vector: 896-bit multi-block message" {
    try testing.expectEqualStrings(
        "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1",
        &sha256Hex("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn" ++
            "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"),
    );
}

// ==========================================================================
// HMAC-SHA256 — RFC 4231 §4 test cases, driven through the FFI export
// ==========================================================================

/// Call the exported `hmac_sha256` with the given secret/message and return
/// the 64-char lowercase hex result read back via the exported result buffer.
fn hmacHex(secret: []const u8, msg: []const u8) []const u8 {
    const len = wfk.hmac_sha256(
        secret.ptr,
        @intCast(secret.len),
        msg.ptr,
        @intCast(msg.len),
    );
    try_len_is_64(len);
    return wfk.get_result_ptr()[0..len];
}

fn try_len_is_64(len: u32) void {
    // hmac_sha256 returns 64 on success for any accepted input; a 0 here
    // means the input-bounds guard rejected the vector, which would be a bug
    // in the test setup (RFC keys are all ≤ 131 bytes ≤ 4096).
    std.debug.assert(len == 64);
}

test "HMAC-SHA256 RFC 4231 TC1" {
    const key = [_]u8{0x0b} ** 20;
    try testing.expectEqualStrings(
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
        hmacHex(&key, "Hi There"),
    );
}

test "HMAC-SHA256 RFC 4231 TC2 (Jefe)" {
    try testing.expectEqualStrings(
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
        hmacHex("Jefe", "what do ya want for nothing?"),
    );
}

test "HMAC-SHA256 RFC 4231 TC3 (0xdd x50)" {
    const key = [_]u8{0xaa} ** 20;
    const data = [_]u8{0xdd} ** 50;
    try testing.expectEqualStrings(
        "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe",
        hmacHex(&key, &data),
    );
}

test "HMAC-SHA256 RFC 4231 TC4 (25-byte key, 0xcd x50)" {
    const key = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
        0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12,
        0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19,
    };
    const data = [_]u8{0xcd} ** 50;
    try testing.expectEqualStrings(
        "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b",
        hmacHex(&key, &data),
    );
}

test "HMAC-SHA256 RFC 4231 TC5 (truncation — compare 128-bit prefix)" {
    // RFC 4231 TC5 publishes only the 128-bit truncated MAC. The module
    // always emits the full 256-bit hex, so we compare the first 32 hex
    // chars (16 bytes) against the published truncated value.
    const key = [_]u8{0x0c} ** 20;
    const full = hmacHex(&key, "Test With Truncation");
    try testing.expectEqualStrings("a3b6167473100ee06e0c796c2955552b", full[0..32]);
}

test "HMAC-SHA256 RFC 4231 TC6 (131-byte key — hash-key-first branch)" {
    const key = [_]u8{0xaa} ** 131;
    try testing.expectEqualStrings(
        "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
        hmacHex(&key, "Test Using Larger Than Block-Size Key - Hash Key First"),
    );
}

test "HMAC-SHA256 RFC 4231 TC7 (131-byte key, long message)" {
    const key = [_]u8{0xaa} ** 131;
    const data = "This is a test using a larger than block-size key and a " ++
        "larger than block-size data. The key needs to be hashed before " ++
        "being used by the HMAC algorithm.";
    try testing.expectEqualStrings(
        "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2",
        hmacHex(&key, data),
    );
}

// ==========================================================================
// FFI behaviour — verify path and result-buffer hygiene
// ==========================================================================

test "hmac_sha256_verify accepts the correct MAC and rejects a wrong one" {
    const key = [_]u8{0x0b} ** 20;
    const msg = "Hi There";
    const good = "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7";
    const bad = "0000000000000000000000000000000000000000000000000000000000000000";

    try testing.expectEqual(
        @as(i32, 1),
        wfk.hmac_sha256_verify(&key, key.len, msg.ptr, @intCast(msg.len), good.ptr, @intCast(good.len)),
    );
    try testing.expectEqual(
        @as(i32, 0),
        wfk.hmac_sha256_verify(&key, key.len, msg.ptr, @intCast(msg.len), bad.ptr, @intCast(bad.len)),
    );
}

test "hmac_sha256_verify wipes the result buffer (F4 — no MAC oracle)" {
    const key = [_]u8{0x0b} ** 20;
    const msg = "Hi There";
    const good = "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7";

    _ = wfk.hmac_sha256_verify(&key, key.len, msg.ptr, @intCast(msg.len), good.ptr, @intCast(good.len));

    // After a verify, no computed MAC may remain readable.
    try testing.expectEqual(@as(u32, 0), wfk.get_result_len());
    const ptr = wfk.get_result_ptr();
    for (0..64) |i| try testing.expectEqual(@as(u8, 0), ptr[i]);
}

test "hmac_sha256 rejects out-of-bounds inputs" {
    const secret = "s";
    const msg = "m";
    // secret_len == 0 rejected
    try testing.expectEqual(@as(u32, 0), wfk.hmac_sha256(secret.ptr, 0, msg.ptr, 1));
    // secret_len > 4096 rejected
    try testing.expectEqual(@as(u32, 0), wfk.hmac_sha256(secret.ptr, 4097, msg.ptr, 1));
}

test "generate_api_key produces vn_ + 64 hex on native (std.crypto.random)" {
    const n = wfk.generate_api_key();
    try testing.expectEqual(@as(u32, 67), n);
    const key = wfk.get_result_ptr()[0..n];
    try testing.expect(std.mem.startsWith(u8, key, "vn_"));
    for (key[3..]) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try testing.expect(is_hex);
    }
    wfk.clear_result_buf();
    try testing.expectEqual(@as(u32, 0), wfk.get_result_len());
}
