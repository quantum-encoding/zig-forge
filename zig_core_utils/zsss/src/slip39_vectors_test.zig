//! Official SLIP-0039 test vectors.
//!
//! Data: `tests/slip-0039-vectors.json`, archived verbatim from the reference
//! implementation at
//! <https://github.com/trezor/python-shamir-mnemonic/blob/master/vectors.json>,
//! which the spec names as the canonical vector set (see docs/slip-0039.md,
//! "Test vectors").
//!
//! Each vector is a quadruple [description, mnemonics, master_secret, xprv]:
//!   * a non-empty master secret means the mnemonics MUST combine to it, using
//!     the passphrase "TREZOR";
//!   * an empty master secret means combining them MUST fail. These negative
//!     vectors are the important half: a decoder that accepts an invalid share
//!     set is the failure mode that loses funds.
//!
//! The fourth element is the BIP-0032 master extended private key derived from
//! the master secret. Checking it is an independent confirmation that the
//! recovered bytes are exactly right, not merely self-consistent, so this file
//! also derives and compares it (spec: "Specification for backing up BIP-0032
//! Hierarchical Deterministic Wallets").

const std = @import("std");
const testing = std.testing;
const slip39 = @import("slip39.zig");

/// `tests/slip-0039-vectors.json`, wired in as the anonymous import
/// `slip39_vectors` by build.zig so that the archive stays in `tests/` rather
/// than being duplicated next to the source.
const vectors_json = @embedFile("slip39_vectors");

const PASSPHRASE = "TREZOR";

// =============================================================================
// BIP-0032 master key derivation (verification aid, not part of SLIP-39)
// =============================================================================

const HmacSha512 = std.crypto.auth.hmac.sha2.HmacSha512;
const Sha256 = std.crypto.hash.sha2.Sha256;

const BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/// Base58 encode, big-endian, with the usual leading-zero-byte to '1' mapping.
fn base58Encode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var leading_zeros: usize = 0;
    while (leading_zeros < input.len and input[leading_zeros] == 0) leading_zeros += 1;

    // log(256)/log(58) ~= 1.365; two bytes of slack for the zero prefix.
    const digits = try allocator.alloc(u8, input.len * 138 / 100 + 2);
    defer allocator.free(digits);
    @memset(digits, 0);

    var digit_count: usize = 0;
    for (input[leading_zeros..]) |byte| {
        var carry: u32 = byte;
        var i: usize = 0;
        while (i < digit_count or carry != 0) : (i += 1) {
            carry += @as(u32, digits[i]) * 256;
            digits[i] = @intCast(carry % 58);
            carry /= 58;
            if (i >= digit_count) digit_count = i + 1;
        }
    }

    const out = try allocator.alloc(u8, leading_zeros + digit_count);
    @memset(out[0..leading_zeros], BASE58_ALPHABET[0]);
    for (0..digit_count) |i| {
        out[leading_zeros + i] = BASE58_ALPHABET[digits[digit_count - 1 - i]];
    }
    return out;
}

/// The BIP-32 master extended private key (xprv) for a seed.
fn bip32MasterXprv(allocator: std.mem.Allocator, seed: []const u8) ![]u8 {
    var i: [HmacSha512.mac_length]u8 = undefined;
    HmacSha512.create(&i, seed, "Bitcoin seed");
    const private_key = i[0..32];
    const chain_code = i[32..64];

    // version(4) depth(1) parent_fingerprint(4) child_number(4) chain_code(32)
    // 0x00 || key(32) = 78 bytes, then a 4-byte double-SHA256 checksum.
    var payload: [82]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], 0x0488ADE4, .big); // mainnet xprv
    payload[4] = 0; // depth
    @memset(payload[5..9], 0); // parent fingerprint
    @memset(payload[9..13], 0); // child number
    @memcpy(payload[13..45], chain_code);
    payload[45] = 0;
    @memcpy(payload[46..78], private_key);

    var first: [32]u8 = undefined;
    Sha256.hash(payload[0..78], &first, .{});
    var second: [32]u8 = undefined;
    Sha256.hash(&first, &second, .{});
    @memcpy(payload[78..82], second[0..4]);

    std.crypto.secureZero(u8, &i);
    return base58Encode(allocator, &payload);
}

test "BIP-32 xprv helper matches BIP-32 test vector 1" {
    // BIP-0032 test vector 1: seed 000102030405060708090a0b0c0d0e0f.
    const seed = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0xa, 0xb, 0xc, 0xd, 0xe, 0xf };
    const xprv = try bip32MasterXprv(testing.allocator, &seed);
    defer testing.allocator.free(xprv);
    try testing.expectEqualStrings(
        "xprv9s21ZrQH143K3QTDL4LXw2F7HEK3wJUD2nW2nRk4stbPy6cq3jPPqjiChkVvvNKmPGJxWUtg6LnF5kejMRNNU3TGtRBeJgk33yuGBxrMPHi",
        xprv,
    );
}

// =============================================================================
// Vector runner
// =============================================================================

fn parseHex(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    _ = try std.fmt.hexToBytes(out, hex);
    return out;
}

const Counts = struct {
    positive: usize = 0,
    negative: usize = 0,
};

test "official SLIP-0039 vectors" {
    const allocator = testing.allocator;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, vectors_json, .{});
    defer parsed.deinit();

    const vectors = parsed.value.array.items;
    // The archived file must not silently shrink; if it is refreshed upstream
    // this assertion is the prompt to re-check the new cases by hand.
    try testing.expectEqual(@as(usize, 45), vectors.len);

    var counts = Counts{};
    var failures: usize = 0;

    for (vectors) |vector| {
        const fields = vector.array.items;
        const description = fields[0].string;
        const expected_secret_hex = fields[2].string;
        const expected_xprv = fields[3].string;

        const mnemonic_values = fields[1].array.items;
        const mnemonics = try allocator.alloc([]const u8, mnemonic_values.len);
        defer allocator.free(mnemonics);
        for (mnemonic_values, 0..) |m, i| mnemonics[i] = m.string;

        if (expected_secret_hex.len == 0) {
            counts.negative += 1;
            // MUST fail. An Ok here means a share set the spec calls invalid
            // was accepted.
            if (slip39.combineMnemonics(allocator, mnemonics, PASSPHRASE)) |secret| {
                defer allocator.free(secret);
                std.debug.print(
                    "NEGATIVE VECTOR ACCEPTED: {s}\n  recovered {x}\n",
                    .{ description, secret },
                );
                failures += 1;
            } else |_| {}
            continue;
        }

        counts.positive += 1;
        const expected_secret = try parseHex(allocator, expected_secret_hex);
        defer allocator.free(expected_secret);

        const secret = slip39.combineMnemonics(allocator, mnemonics, PASSPHRASE) catch |err| {
            std.debug.print("POSITIVE VECTOR FAILED: {s}\n  error {t}\n", .{ description, err });
            failures += 1;
            continue;
        };
        defer allocator.free(secret);

        if (!std.mem.eql(u8, expected_secret, secret)) {
            std.debug.print(
                "POSITIVE VECTOR MISMATCH: {s}\n  want {x}\n  got  {x}\n",
                .{ description, expected_secret, secret },
            );
            failures += 1;
            continue;
        }

        // Independent confirmation of the recovered bytes via BIP-32.
        const xprv = try bip32MasterXprv(allocator, secret);
        defer allocator.free(xprv);
        if (!std.mem.eql(u8, expected_xprv, xprv)) {
            std.debug.print(
                "XPRV MISMATCH: {s}\n  want {s}\n  got  {s}\n",
                .{ description, expected_xprv, xprv },
            );
            failures += 1;
            continue;
        }

        // Re-encoding each share of a valid set must reproduce the exact
        // mnemonic from the vector: this pins our encoder to the canonical
        // form, which a decode-only test would not catch.
        for (mnemonics) |mnemonic| {
            var share = try slip39.Share.fromMnemonic(allocator, mnemonic);
            defer share.deinit(allocator);
            const reencoded = try share.toMnemonic(allocator);
            defer allocator.free(reencoded);
            if (!std.mem.eql(u8, mnemonic, reencoded)) {
                std.debug.print(
                    "RE-ENCODE MISMATCH: {s}\n  want {s}\n  got  {s}\n",
                    .{ description, mnemonic, reencoded },
                );
                failures += 1;
            }
        }
    }

    try testing.expectEqual(@as(usize, 0), failures);
    // The archived vector set is 15 must-succeed and 30 must-fail cases; if a
    // refresh changes the split, the counts here need re-checking by hand.
    try testing.expectEqual(@as(usize, 15), counts.positive);
    try testing.expectEqual(@as(usize, 30), counts.negative);
}

test "every positive vector's shares also recover with a wrong passphrase to something else" {
    // The spec has no passphrase check by design ("Passphrase verification"),
    // so a wrong passphrase must yield a *different* secret rather than an
    // error. Verifying that here documents the behaviour and guards against
    // accidentally adding a passphrase check that would break deniability.
    const allocator = testing.allocator;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, vectors_json, .{});
    defer parsed.deinit();

    var checked: usize = 0;
    for (parsed.value.array.items) |vector| {
        const fields = vector.array.items;
        if (fields[2].string.len == 0) continue;

        const mnemonic_values = fields[1].array.items;
        const mnemonics = try allocator.alloc([]const u8, mnemonic_values.len);
        defer allocator.free(mnemonics);
        for (mnemonic_values, 0..) |m, i| mnemonics[i] = m.string;

        const expected = try parseHex(allocator, fields[2].string);
        defer allocator.free(expected);

        const other = try slip39.combineMnemonics(allocator, mnemonics, "NOT-TREZOR");
        defer allocator.free(other);

        try testing.expectEqual(expected.len, other.len);
        try testing.expect(!std.mem.eql(u8, expected, other));
        checked += 1;
    }
    try testing.expectEqual(@as(usize, 15), checked);
}
