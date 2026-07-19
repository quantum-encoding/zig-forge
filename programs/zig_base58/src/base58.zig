//! Base58 / Base58Check encoding for Bitcoin, Tron, Dogecoin, Litecoin,
//! Ripple, and IPFS.
//!
//! ## Algorithm
//!
//! Base58 is a positional notation with a 58-character alphabet that avoids
//! the visually-ambiguous glyphs `0`, `O`, `I`, `l`. Encoding is done by
//! repeated division of the binary input by 58; leading zero bytes in the
//! input are preserved as leading copies of the alphabet's first character.
//!
//! Base58Check appends a 4-byte checksum derived from **double SHA-256**:
//!   `checksum = SHA256(SHA256(version || payload))[0..4]`
//! Per Bitcoin / Tron / DOGE / LTC consensus rules. A single SHA-256 is
//! **wrong** and produces addresses every external system will reject as
//! malformed; previous versions of this library had that bug — see the audit
//! report in `/programs/zig_base58/` for details.
//!
//! ## Alphabets
//!
//! Bitcoin, Tron, IPFS, Dogecoin and Litecoin share one alphabet. Ripple/XRP
//! uses a different ordering of the same 58 characters. Pass an explicit
//! `Alphabet` to the `*With` variants when in doubt; the default helpers
//! (`encode`, `decode`, `encodeCheck`, `decodeCheck`) use the Bitcoin/Tron
//! alphabet.
//!
//! ## Recommended API
//!
//! For wallet code, prefer the versioned helpers. They prevent the common bug
//! of forgetting the network's version byte (0x00 BTC, 0x05 BTC P2SH, 0x1E
//! DOGE, 0x30 LTC, 0x41 Tron):
//! ```zig
//! const address = try base58.encodeCheckVersioned(allocator, 0x41, &hash20);
//! const hash20  = try base58.decodeCheckVersioned(allocator, 0x41, address);
//! //                                              ^ rejects with WrongVersion
//! //                                                if address is for another
//! //                                                network.
//! ```

const std = @import("std");
const mem = std.mem;
const Sha256 = std.crypto.hash.sha2.Sha256;

// ============================================================================
// Alphabets
// ============================================================================

/// A Base58 alphabet plus its precomputed reverse lookup table.
/// Build at comptime via `Alphabet.fromChars` or use one of the built-in
/// constants (`Alphabet.bitcoin`, `Alphabet.ripple`, `Alphabet.flickr`).
pub const Alphabet = struct {
    chars: [58]u8,
    /// `decode_table[c]` is the digit (0..57) for character `c`, or 255 if
    /// `c` is not part of this alphabet.
    decode_table: [256]u8,

    pub fn fromChars(chars: *const [58]u8) Alphabet {
        var table: [256]u8 = [_]u8{255} ** 256;
        for (chars, 0..) |c, i| {
            table[c] = @intCast(i);
        }
        return .{ .chars = chars.*, .decode_table = table };
    }

    /// Bitcoin / Tron / IPFS / Dogecoin / Litecoin alphabet.
    pub const bitcoin: Alphabet = fromChars("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz");

    /// Ripple / XRP alphabet. Same character set as bitcoin, different order.
    pub const ripple: Alphabet = fromChars("rpshnaf39wBUDNEGHJKLM4PQRST7VWXYZ2bcdeCg65jkm8oFqi1tuvAxyz");

    /// Flickr short-URL alphabet (lowercase first).
    pub const flickr: Alphabet = fromChars("123456789abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ");
};

// ============================================================================
// Limits and errors
// ============================================================================

/// Maximum Base58-encoded input length the decoder will accept. Caps memory
/// allocation to defeat OOM DoS via crafted inputs (e.g. a malicious QR code
/// or paste-from-clipboard). All legitimate Base58Check uses fit comfortably:
///   * BTC/Tron addresses: 25–35 chars
///   * BIP32 xprv/xpub:    111 chars
///   * IPFS CIDv0:         46 chars
pub const MAX_DECODE_INPUT: usize = 1024;

/// Maximum raw-byte input length the encoder will accept. Base58 base
/// conversion is O(n²) (a full carry-propagation pass per input byte), so an
/// attacker who can feed arbitrarily large input to `encode`/`encodeCheck*`
/// turns the encoder into a CPU-DoS — the exact asymmetry the decoder's
/// `MAX_DECODE_INPUT` guard exists to prevent. 4096 covers every legitimate
/// use with huge margin:
///   * BTC/Tron addresses (hash160):  21 bytes pre-checksum
///   * BIP32 xprv/xpub serialization: 78 bytes pre-checksum
///   * IPFS CIDv0 (sha256 multihash):  34 bytes
pub const MAX_ENCODE_INPUT: usize = 4096;

pub const Error = error{
    InvalidCharacter,
    InvalidChecksum,
    InputTooLong,
    WrongVersion,
    PayloadTooShort,
};

// ============================================================================
// Core encode / decode
// ============================================================================

/// Encode `data` to Base58 using the Bitcoin/Tron alphabet. Caller owns the
/// returned slice.
pub fn encode(allocator: mem.Allocator, data: []const u8) ![]u8 {
    return encodeWith(allocator, &Alphabet.bitcoin, data);
}

/// Decode a Base58 string using the Bitcoin/Tron alphabet. Caller owns the
/// returned slice. Rejects inputs longer than `MAX_DECODE_INPUT`.
pub fn decode(allocator: mem.Allocator, encoded: []const u8) ![]u8 {
    return decodeWith(allocator, &Alphabet.bitcoin, encoded);
}

/// Encode `data` under the given alphabet. See `Alphabet` for built-in
/// constants (`bitcoin`, `ripple`, `flickr`).
pub fn encodeWith(allocator: mem.Allocator, alphabet: *const Alphabet, data: []const u8) ![]u8 {
    if (data.len > MAX_ENCODE_INPUT) return Error.InputTooLong;
    if (data.len == 0) {
        return allocator.alloc(u8, 0);
    }

    // Each leading zero byte in input becomes one leading copy of the alphabet's
    // first character.
    var leading_zeros: usize = 0;
    for (data) |byte| {
        if (byte == 0) leading_zeros += 1 else break;
    }

    // Base58 expands by at most ~1.366x; +1 covers ceiling.
    const max_len = ((data.len * 138) / 100) + 1;
    var buf = try allocator.alloc(u8, max_len);
    defer allocator.free(buf);

    var buf_len: usize = 0;
    for (data[leading_zeros..]) |byte| {
        var carry: u16 = byte;
        var i: usize = 0;
        while (i < buf_len) : (i += 1) {
            const temp = @as(u16, buf[i]) * 256 + carry;
            buf[i] = @intCast(temp % 58);
            carry = temp / 58;
        }
        while (carry > 0) {
            buf[buf_len] = @intCast(carry % 58);
            buf_len += 1;
            carry = carry / 58;
        }
    }

    reverseInPlace(buf[0..buf_len]);

    var result = try allocator.alloc(u8, leading_zeros + buf_len);
    for (0..leading_zeros) |k| result[k] = alphabet.chars[0];
    for (0..buf_len) |k| result[leading_zeros + k] = alphabet.chars[buf[k]];

    return result;
}

/// Decode `encoded` under the given alphabet. Rejects inputs longer than
/// `MAX_DECODE_INPUT` (DoS guard).
pub fn decodeWith(allocator: mem.Allocator, alphabet: *const Alphabet, encoded: []const u8) ![]u8 {
    if (encoded.len > MAX_DECODE_INPUT) return Error.InputTooLong;
    if (encoded.len == 0) return allocator.alloc(u8, 0);

    const zero_char = alphabet.chars[0];

    var leading_zeros: usize = 0;
    for (encoded) |c| {
        if (c == zero_char) leading_zeros += 1 else break;
    }

    var buf = try allocator.alloc(u8, encoded.len);
    defer allocator.free(buf);

    var buf_len: usize = 0;
    for (encoded[leading_zeros..]) |c| {
        const digit = alphabet.decode_table[c];
        if (digit == 255) return Error.InvalidCharacter;

        var carry: u16 = digit;
        var i: usize = 0;
        while (i < buf_len) : (i += 1) {
            const temp = @as(u16, buf[i]) * 58 + carry;
            buf[i] = @intCast(temp % 256);
            carry = temp / 256;
        }
        while (carry > 0) {
            buf[buf_len] = @intCast(carry % 256);
            buf_len += 1;
            carry = carry / 256;
        }
    }

    reverseInPlace(buf[0..buf_len]);

    var result = try allocator.alloc(u8, leading_zeros + buf_len);
    for (0..leading_zeros) |k| result[k] = 0;
    for (0..buf_len) |k| result[leading_zeros + k] = buf[k];

    return result;
}

fn reverseInPlace(s: []u8) void {
    var i: usize = 0;
    var j: usize = s.len;
    while (i < j) {
        j -= 1;
        const t = s[i];
        s[i] = s[j];
        s[j] = t;
        i += 1;
    }
}

// ============================================================================
// Base58Check  (double SHA-256, Bitcoin/Tron/DOGE/LTC compatible)
// ============================================================================

/// Bitcoin's double SHA-256: `SHA256(SHA256(data))`.
fn sha256d(data: []const u8) [32]u8 {
    var first: [32]u8 = undefined;
    Sha256.hash(data, &first, .{});
    var second: [32]u8 = undefined;
    Sha256.hash(&first, &second, .{});
    return second;
}

/// Constant-time comparison of two 4-byte checksums. Checksums themselves are
/// public so timing leakage is not a real attack — this is defensive habit.
fn checksumEql(a: []const u8, b: []const u8) bool {
    if (a.len != 4 or b.len != 4) return false;
    var ax: [4]u8 = undefined;
    var bx: [4]u8 = undefined;
    @memcpy(&ax, a);
    @memcpy(&bx, b);
    return std.crypto.timing_safe.eql([4]u8, ax, bx);
}

/// Encode `data` with a 4-byte SHA-256d checksum appended.
///
/// **The caller is responsible for prepending the network version byte.** For
/// wallet code, prefer `encodeCheckVersioned` which makes the version byte an
/// explicit parameter — this form is kept for backward compatibility and for
/// callers that need to handle non-standard versioning (e.g. multi-byte
/// version prefixes used by BIP32 xprv/xpub).
pub fn encodeCheck(allocator: mem.Allocator, data: []const u8) ![]u8 {
    var payload = try allocator.alloc(u8, data.len + 4);
    defer allocator.free(payload);

    @memcpy(payload[0..data.len], data);
    const checksum = sha256d(payload[0..data.len]);
    @memcpy(payload[data.len..], checksum[0..4]);

    return encode(allocator, payload);
}

/// Decode `encoded` and verify the trailing 4-byte SHA-256d checksum. Returns
/// the payload with the checksum stripped (still includes the version byte,
/// if the encoder prepended one). For wallet code, prefer
/// `decodeCheckVersioned` which also verifies the version byte.
pub fn decodeCheck(allocator: mem.Allocator, encoded: []const u8) ![]u8 {
    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    if (decoded.len < 4) return Error.InvalidChecksum;

    const checksum = sha256d(decoded[0 .. decoded.len - 4]);
    if (!checksumEql(checksum[0..4], decoded[decoded.len - 4 ..])) {
        return Error.InvalidChecksum;
    }

    const result = try allocator.alloc(u8, decoded.len - 4);
    @memcpy(result, decoded[0 .. decoded.len - 4]);
    return result;
}

// ============================================================================
// Versioned API (preferred for wallet use)
// ============================================================================

/// Encode `payload` as a Base58Check address with the given version byte.
///
/// The wire format is `<version><payload><SHA256d(version||payload)[0..4]>`.
/// `payload` should NOT include the version byte — pass the raw `hash160`
/// (or whatever the network prescribes) and let this function place the
/// version byte at the head.
///
/// Example (Tron mainnet address):
/// ```zig
/// const address = try base58.encodeCheckVersioned(allocator, 0x41, &hash160);
/// ```
pub fn encodeCheckVersioned(
    allocator: mem.Allocator,
    version: u8,
    payload: []const u8,
) ![]u8 {
    var buf = try allocator.alloc(u8, 1 + payload.len + 4);
    defer allocator.free(buf);

    buf[0] = version;
    @memcpy(buf[1 .. 1 + payload.len], payload);
    const checksum = sha256d(buf[0 .. 1 + payload.len]);
    @memcpy(buf[1 + payload.len ..], checksum[0..4]);

    return encode(allocator, buf);
}

/// Decode `encoded` as `<version><payload><checksum>`, verify both the
/// checksum AND the version byte, and return just the payload bytes.
///
/// Returns:
///   * `Error.WrongVersion` if the embedded version byte does not match
///     `expected_version` (catches cross-network address reuse)
///   * `Error.InvalidChecksum` if the checksum is wrong (catches typos)
///   * `Error.PayloadTooShort` if the decoded length is < 5 bytes
pub fn decodeCheckVersioned(
    allocator: mem.Allocator,
    expected_version: u8,
    encoded: []const u8,
) ![]u8 {
    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    // Need at least 1 version byte + 4 checksum bytes.
    if (decoded.len < 5) return Error.PayloadTooShort;

    const checksum = sha256d(decoded[0 .. decoded.len - 4]);
    if (!checksumEql(checksum[0..4], decoded[decoded.len - 4 ..])) {
        return Error.InvalidChecksum;
    }

    if (decoded[0] != expected_version) return Error.WrongVersion;

    const payload_len = decoded.len - 5;
    const result = try allocator.alloc(u8, payload_len);
    @memcpy(result, decoded[1 .. 1 + payload_len]);
    return result;
}

// ============================================================================
// Streaming helpers
// ============================================================================
//
// NOTE: Base58 base conversion is inherently non-streamable — carries
// propagate non-locally across the entire input. These helpers buffer the full
// input into a fixed-size slab and call the batch encoder/decoder at .finish/
// .finalize. They are convenience APIs, not true streams. Their bounded
// capacity prevents unbounded growth from feed loops.

pub const StreamEncoder = struct {
    allocator: mem.Allocator,
    buffer: []u8,
    pos: usize = 0,

    pub fn init(allocator: mem.Allocator, capacity: usize) !StreamEncoder {
        return .{
            .allocator = allocator,
            .buffer = try allocator.alloc(u8, capacity),
        };
    }

    pub fn deinit(self: *StreamEncoder) void {
        self.allocator.free(self.buffer);
    }

    pub fn write(self: *StreamEncoder, data: []const u8) !void {
        if (self.pos + data.len > self.buffer.len) {
            return error.BufferTooSmall;
        }
        @memcpy(self.buffer[self.pos .. self.pos + data.len], data);
        self.pos += data.len;
    }

    pub fn finish(self: *StreamEncoder) ![]u8 {
        return encode(self.allocator, self.buffer[0..self.pos]);
    }
};

pub const StreamDecoder = struct {
    allocator: mem.Allocator,
    buffer: []u8,
    pos: usize = 0,

    pub fn init(allocator: mem.Allocator, capacity: usize) !StreamDecoder {
        return .{
            .allocator = allocator,
            .buffer = try allocator.alloc(u8, capacity),
        };
    }

    pub fn deinit(self: *StreamDecoder) void {
        self.allocator.free(self.buffer);
    }

    pub fn feed(self: *StreamDecoder, encoded_chunk: []const u8) !void {
        if (self.pos + encoded_chunk.len > self.buffer.len) {
            return error.BufferTooSmall;
        }
        @memcpy(self.buffer[self.pos .. self.pos + encoded_chunk.len], encoded_chunk);
        self.pos += encoded_chunk.len;
    }

    pub fn finalize(self: *StreamDecoder) ![]u8 {
        return decode(self.allocator, self.buffer[0..self.pos]);
    }
};

/// Encode multiple byte slices using a single allocator. Each output slice is
/// independently allocated and owned by the caller.
pub fn encodeBatch(allocator: mem.Allocator, items: []const []const u8) ![][]u8 {
    const results = try allocator.alloc([]u8, items.len);
    var produced: usize = 0;
    // On any failure, free the inner slices already produced AND the outer
    // array. A plain `errdefer allocator.free(results)` would leak every
    // `results[0..produced]` slice already allocated by `encode`.
    errdefer {
        for (results[0..produced]) |r| allocator.free(r);
        allocator.free(results);
    }

    for (items, 0..) |item, i| {
        results[i] = try encode(allocator, item);
        produced = i + 1;
    }

    return results;
}

// ============================================================================
// Tests
// ============================================================================
//
// The tests are organized in three tiers:
//
//   1. Externally-anchored vectors. Inputs and outputs both come from
//      published sources outside this codebase (Bitcoin Core test fixtures,
//      Tron/XRP block explorers). These are the gate criterion — they would
//      fail under the SHA-256 vs SHA-256d bug that previous versions had.
//
//   2. Failure-mode tests. Mutated checksum, wrong version byte, oversize
//      input. Verifies the defensive checks fire on hostile input.
//
//   3. Internal-consistency tests. Encode/decode roundtrips. Cheap to keep
//      but never sufficient on their own.
//
// Rule: if you remove all tier-3 tests, tier-1 must still cover encode AND
// decode for every public function. The previous version of this file failed
// that rule and shipped a checksum bug for two months.

// ----- Tier 1: externally-anchored vectors -----

test "tier1: BTC encode test vectors (Bitcoin Core base58_encode_decode.json)" {
    const allocator = std.testing.allocator;

    // From bitcoin/bitcoin src/test/data/base58_encode_decode.json
    const cases = [_]struct { hex: []const u8, b58: []const u8 }{
        .{ .hex = "", .b58 = "" },
        .{ .hex = "61", .b58 = "2g" },
        .{ .hex = "626262", .b58 = "a3gV" },
        .{ .hex = "636363", .b58 = "aPEr" },
        .{ .hex = "73696d706c792061206c6f6e6720737472696e67", .b58 = "2cFupjhnEsSn59qHXstmK2ffpLv2" },
        .{ .hex = "00eb15231dfceb60925886b67d065299925915aeb172c06647", .b58 = "1NS17iag9jJgTHD1VXjvLCEnZuQ3rJDE9L" },
        .{ .hex = "516b6fcd0f", .b58 = "ABnLTmg" },
        .{ .hex = "bf4f89001e670274dd", .b58 = "3SEo3LWLoPntC" },
        .{ .hex = "572e4794", .b58 = "3EFU7m" },
        .{ .hex = "ecac89cad93923c02321", .b58 = "EJDM8drfXA6uyA" },
        .{ .hex = "10c8511e", .b58 = "Rt5zm" },
        .{ .hex = "00000000000000000000", .b58 = "1111111111" },
        // The canonical "whole alphabet" vector: its Base58 output is the full
        // 58-char alphabet in order, so it exercises every output symbol, and
        // its single 0x00 lead byte checks leading-zero handling.
        .{
            .hex = "000111d38e5fc9071ffcd20b4a763cc9ae4f252bb4e48fd66a835e252ada93ff480d6dd43dc62a641155a5",
            .b58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz",
        },
    };

    for (cases) |c| {
        var hex_buf: [128]u8 = undefined;
        const bytes = try std.fmt.hexToBytes(&hex_buf, c.hex);

        const encoded = try encode(allocator, bytes);
        defer allocator.free(encoded);
        try std.testing.expectEqualSlices(u8, c.b58, encoded);

        const decoded = try decode(allocator, c.b58);
        defer allocator.free(decoded);
        try std.testing.expectEqualSlices(u8, bytes, decoded);
    }
}

test "tier1: Satoshi's BTC address Base58Check round-trips via versioned API" {
    // 1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa is the address that received the
    // genesis block reward. Documented on Bitcoin's wiki, block explorers,
    // and embedded in countless other libraries.
    //
    // Step (a): decode it with the plain decoder. This uses no SHA, so it
    //           cannot be affected by the SHA bug — its output is ground truth.
    // Step (b): re-encode the version + hash via encodeCheckVersioned. If
    //           encodeCheckVersioned uses single SHA-256 (the bug) the
    //           checksum mismatches and the output diverges from Satoshi's
    //           address.
    // Step (c): decodeCheckVersioned must return the same 20-byte hash.

    const allocator = std.testing.allocator;
    const satoshi = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa";

    const decoded = try decode(allocator, satoshi);
    defer allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 25), decoded.len);
    try std.testing.expectEqual(@as(u8, 0x00), decoded[0]); // BTC P2PKH mainnet
    const hash160 = decoded[1..21];

    const reencoded = try encodeCheckVersioned(allocator, 0x00, hash160);
    defer allocator.free(reencoded);
    try std.testing.expectEqualSlices(u8, satoshi, reencoded);

    const recovered = try decodeCheckVersioned(allocator, 0x00, satoshi);
    defer allocator.free(recovered);
    try std.testing.expectEqualSlices(u8, hash160, recovered);
}

test "tier1: Tron USDT contract address round-trips with version 0x41" {
    // TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t is the canonical USDT (TRC20)
    // contract on Tron mainnet. Documented on Tronscan and Tether's own
    // documentation. Version byte for Tron mainnet is 0x41.
    const allocator = std.testing.allocator;
    const usdt_tron = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t";

    const decoded = try decode(allocator, usdt_tron);
    defer allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 25), decoded.len);
    try std.testing.expectEqual(@as(u8, 0x41), decoded[0]); // Tron mainnet
    const hash20 = decoded[1..21];

    const reencoded = try encodeCheckVersioned(allocator, 0x41, hash20);
    defer allocator.free(reencoded);
    try std.testing.expectEqualSlices(u8, usdt_tron, reencoded);

    const recovered = try decodeCheckVersioned(allocator, 0x41, usdt_tron);
    defer allocator.free(recovered);
    try std.testing.expectEqualSlices(u8, hash20, recovered);
}

test "tier1: XRP genesis account address (external XRPL vector) over Ripple alphabet" {
    // rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh is the XRP Ledger genesis ("root")
    // account — the account that held all XRP at ledger inception. It is
    // documented across the XRPL docs, xrpscan/bithomp explorers, and the
    // ripple-address-codec golden fixtures.
    //
    // XRP classic addresses are Base58Check with:
    //   * the *Ripple* alphabet (a different ordering of the same 58 chars),
    //   * the same double-SHA-256 checksum as Bitcoin,
    //   * account-ID version prefix 0x00.
    //
    // The 20-byte account ID below is the externally-published value for this
    // account (derivable from the "masterpassphrase" secret and shown by every
    // XRPL address decoder). A wrong ordering in `Alphabet.ripple` (:68), a
    // single-SHA-256 checksum, or a wrong version byte all break this test —
    // so it is a genuine two-sided external anchor, not a roundtrip.
    const allocator = std.testing.allocator;
    const xrp_addr = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh";
    const account_id_hex = "b5f762798a53d543a014caf8b297cff8f2f937e8";

    var account_id: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&account_id, account_id_hex);

    // Step (a): plain-decode with the Ripple alphabet (no SHA — ground truth).
    const decoded = try decodeWith(allocator, &Alphabet.ripple, xrp_addr);
    defer allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 25), decoded.len);
    try std.testing.expectEqual(@as(u8, 0x00), decoded[0]); // XRP account-ID prefix
    try std.testing.expectEqualSlices(u8, &account_id, decoded[1..21]);

    // Step (b): rebuild <version||accountID||SHA256d[0..4]> and re-encode under
    // the Ripple alphabet — must reproduce the on-ledger address byte-exact.
    var framed: [25]u8 = undefined;
    framed[0] = 0x00;
    @memcpy(framed[1..21], &account_id);
    const checksum = sha256d(framed[0..21]);
    @memcpy(framed[21..25], checksum[0..4]);

    const reencoded = try encodeWith(allocator, &Alphabet.ripple, &framed);
    defer allocator.free(reencoded);
    try std.testing.expectEqualSlices(u8, xrp_addr, reencoded);
}

test "tier1: BIP32 test-vector-1 master xpub (external) over encodeCheck/decodeCheck" {
    // BIP32 (BIP-0032) "Test vector 1", chain m, serialized extended PUBLIC
    // key. The 78-byte serialization and the resulting Base58Check string are
    // both published in the BIP text and reproduced by every HD-wallet library.
    //
    // This is the only coverage of the length-generic, multi-byte-version
    // `encodeCheck`/`decodeCheck` path against an external anchor: the versioned
    // helpers only exercise 1-byte version prefixes, whereas an xpub carries a
    // 4-byte version (0x0488B21E). A single-SHA-256 checksum or an off-by-one
    // in the big-int conversion diverges from the published xpub.
    const allocator = std.testing.allocator;

    // version(4) depth(1) parent-fpr(4) child(4) chaincode(32) pubkey(33) = 78
    const serialized_hex =
        "0488b21e000000000000000000" ++
        "873dff81c02f525623fd1fe5167eac3a55a049de3d314bb42ee227ffed37d508" ++
        "0339a36013301597daef41fbe593a02cc513d0b55527ec2df1050e2e8ff49c85c2";
    const expected_xpub =
        "xpub661MyMwAqRbcFtXgS5sYJABqqG9YLmC4Q1Rdap9gSE8Nqtwyb" ++
        "GhePY2gZ29ESFjqJoCu1Rupje8YtGqsefD265TMg7usUDFdp6W1EGMcet8";

    var serialized: [78]u8 = undefined;
    _ = try std.fmt.hexToBytes(&serialized, serialized_hex);

    const encoded = try encodeCheck(allocator, &serialized);
    defer allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, expected_xpub, encoded);

    const decoded = try decodeCheck(allocator, expected_xpub);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(u8, &serialized, decoded);
}

test "tier1: Flickr short-URL codes (external) over the Flickr alphabet" {
    // Flickr's flic.kr short URLs are the photo ID converted to Base58 under
    // the *Flickr* alphabet (lowercase-first ordering, :71) with no checksum.
    // Both pairs below are externally published:
    //   * 3447346323 -> "6fCxXz"  (Douglas F. Shearer's canonical "Flickr short
    //                               URLs explained" write-up, the reference
    //                               explainer every later implementation cites)
    //   * 6857269519 -> "brXijP"  (widely reproduced flic.kr/p/brXijP example)
    //
    // The Flickr alphabet previously had ZERO tests, so a mis-ordered
    // `Alphabet.flickr` constant at :71 would have gone undetected (exactly the
    // roundtrip-only gap the repo golden rule forbids). Photo IDs are encoded
    // as their minimal big-endian byte representation; neither ID has a leading
    // zero byte, so the codes map one-to-one with no leading-'1' padding.
    const allocator = std.testing.allocator;

    const cases = [_]struct { id_be_hex: []const u8, code: []const u8 }{
        .{ .id_be_hex = "cd7a5493", .code = "6fCxXz" }, // 3447346323
        .{ .id_be_hex = "0198b9a10f", .code = "brXijP" }, // 6857269519
    };

    for (cases) |c| {
        var id_buf: [8]u8 = undefined;
        const id_bytes = try std.fmt.hexToBytes(&id_buf, c.id_be_hex);

        const encoded = try encodeWith(allocator, &Alphabet.flickr, id_bytes);
        defer allocator.free(encoded);
        try std.testing.expectEqualSlices(u8, c.code, encoded);

        const decoded = try decodeWith(allocator, &Alphabet.flickr, c.code);
        defer allocator.free(decoded);
        try std.testing.expectEqualSlices(u8, id_bytes, decoded);
    }
}

// ----- Tier 2: failure-mode tests -----

test "tier2: encode rejects oversize input (CPU-DoS guard, mirrors decoder cap)" {
    const allocator = std.testing.allocator;

    var big: [MAX_ENCODE_INPUT + 1]u8 = undefined;
    @memset(&big, 0xFF);

    try std.testing.expectError(Error.InputTooLong, encode(allocator, &big));
    try std.testing.expectError(Error.InputTooLong, encodeWith(allocator, &Alphabet.ripple, &big));

    // Boundary: exactly MAX_ENCODE_INPUT bytes must still succeed.
    var ok_buf: [MAX_ENCODE_INPUT]u8 = undefined;
    @memset(&ok_buf, 0xAB);
    const ok = try encode(allocator, &ok_buf);
    allocator.free(ok);
}

test "tier2: encodeBatch frees already-encoded slices when a later encode fails" {
    // Prove the error-path does not leak: FailingAllocator fails the Nth
    // allocation. encodeBatch allocates the outer array (1) then two slices per
    // item (max_len scratch + result) — we fail partway through so at least one
    // full inner result has been produced, then assert testing.allocator (the
    // backing allocator) sees no leak when the errdefer runs.
    const backing = std.testing.allocator;
    const items = [_][]const u8{ "first", "second", "third", "fourth" };

    // Sweep the fail index across a range that lands mid-loop; every failure
    // must unwind cleanly (FailingAllocator + testing.allocator catch leaks).
    var fail_at: usize = 1;
    while (fail_at < 8) : (fail_at += 1) {
        var fa = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_at });
        const res = encodeBatch(fa.allocator(), &items);
        try std.testing.expectError(error.OutOfMemory, res);
    }
}


test "tier2: decodeCheckVersioned rejects wrong version (cross-network reuse)" {
    const allocator = std.testing.allocator;

    // Satoshi's BTC address (version 0x00). Attempt to read it as a Tron
    // address (expected version 0x41) — must error, NOT silently return
    // garbage bytes.
    const satoshi = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa";
    const result = decodeCheckVersioned(allocator, 0x41, satoshi);
    try std.testing.expectError(Error.WrongVersion, result);
}

test "tier2: decodeCheckVersioned rejects checksum mutation" {
    const allocator = std.testing.allocator;

    var addr: [34]u8 = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa".*;
    // Mutate the last character — the checksum bytes live at the tail.
    addr[addr.len - 1] = if (addr[addr.len - 1] == 'a') 'b' else 'a';

    const result = decodeCheckVersioned(allocator, 0x00, &addr);
    try std.testing.expectError(Error.InvalidChecksum, result);
}

test "tier2: decodeCheck rejects checksum mutation in arbitrary payloads" {
    const allocator = std.testing.allocator;

    const input = "Bitcoin is awesome";
    var encoded = try encodeCheck(allocator, input);
    defer allocator.free(encoded);

    // Flip the last character.
    encoded[encoded.len - 1] = if (encoded[encoded.len - 1] == '2') '3' else '2';
    const result = decodeCheck(allocator, encoded);
    try std.testing.expectError(Error.InvalidChecksum, result);
}

test "tier2: decode rejects oversize input (OOM DoS guard)" {
    const allocator = std.testing.allocator;

    var big: [MAX_DECODE_INPUT + 1]u8 = undefined;
    @memset(&big, '1');

    const result = decode(allocator, &big);
    try std.testing.expectError(Error.InputTooLong, result);
}

test "tier2: decode rejects characters outside the alphabet" {
    const allocator = std.testing.allocator;

    // The four visually-ambiguous chars all rejected.
    inline for ([_]u8{ '0', 'O', 'I', 'l' }) |bad| {
        var buf = [_]u8{ '1', '2', '3', bad, '4', '5', '6' };
        const result = decode(allocator, &buf);
        try std.testing.expectError(Error.InvalidCharacter, result);
    }
}

test "tier2: decodeCheckVersioned rejects payload shorter than 5 bytes" {
    const allocator = std.testing.allocator;

    // "21" decodes to a single byte (0x01). decodeCheckVersioned needs >= 5
    // bytes to have room for version + checksum.
    const result = decodeCheckVersioned(allocator, 0x00, "21");
    try std.testing.expectError(Error.PayloadTooShort, result);
}

// ----- Tier 3: internal consistency -----

test "tier3: encode/decode roundtrip" {
    const allocator = std.testing.allocator;

    const input = "Hello, World!";
    const encoded = try encode(allocator, input);
    defer allocator.free(encoded);

    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, input, decoded);
}

test "tier3: encodeCheck/decodeCheck roundtrip" {
    const allocator = std.testing.allocator;

    const input = "Bitcoin is awesome";
    const encoded = try encodeCheck(allocator, input);
    defer allocator.free(encoded);

    const decoded = try decodeCheck(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, input, decoded);
}

test "tier3: empty input encodes to empty string" {
    const allocator = std.testing.allocator;

    const result = try encode(allocator, "");
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "tier3: single zero byte encodes to \"1\"" {
    const allocator = std.testing.allocator;

    const result = try encode(allocator, &[_]u8{0});
    defer allocator.free(result);
    try std.testing.expectEqualSlices(u8, "1", result);
}

test "tier3: leading zeros preserved as leading \"1\"s" {
    const allocator = std.testing.allocator;

    const result = try encode(allocator, &[_]u8{ 0, 0, 0, 1 });
    defer allocator.free(result);
    try std.testing.expectEqualSlices(u8, "1112", result);
}

test "tier3: stream encoder and decoder are buffered roundtrips" {
    const allocator = std.testing.allocator;

    var encoder = try StreamEncoder.init(allocator, 1024);
    defer encoder.deinit();

    try encoder.write("Hello");
    try encoder.write(" ");
    try encoder.write("Stream");

    const encoded = try encoder.finish();
    defer allocator.free(encoded);

    var decoder = try StreamDecoder.init(allocator, 1024);
    defer decoder.deinit();
    try decoder.feed(encoded);
    const decoded = try decoder.finalize();
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, "Hello Stream", decoded);
}

test "tier3: encodeBatch maps each input independently" {
    const allocator = std.testing.allocator;

    const items = [_][]const u8{ "first", "second", "third" };
    const batch = try encodeBatch(allocator, &items);
    defer {
        for (batch) |item| allocator.free(item);
        allocator.free(batch);
    }

    try std.testing.expectEqual(@as(usize, 3), batch.len);
    for (batch, items) |encoded, original| {
        const decoded = try decode(allocator, encoded);
        defer allocator.free(decoded);
        try std.testing.expectEqualSlices(u8, original, decoded);
    }
}

// ----- Alphabet variants -----

test "alphabet: Ripple alphabet encodes the same data differently than Bitcoin" {
    const allocator = std.testing.allocator;

    // Pick data whose Base58 representation is unambiguous and not all
    // leading-zero/leading-1 (which would be identical across alphabets that
    // share the same first character).
    const data = [_]u8{ 0x12, 0x34, 0x56, 0x78 };

    const btc = try encodeWith(allocator, &Alphabet.bitcoin, &data);
    defer allocator.free(btc);

    const xrp = try encodeWith(allocator, &Alphabet.ripple, &data);
    defer allocator.free(xrp);

    try std.testing.expect(!std.mem.eql(u8, btc, xrp));
}

test "alphabet: Ripple roundtrip preserves bytes" {
    const allocator = std.testing.allocator;

    const data = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05 };
    const encoded = try encodeWith(allocator, &Alphabet.ripple, &data);
    defer allocator.free(encoded);

    const decoded = try decodeWith(allocator, &Alphabet.ripple, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, &data, decoded);
}

test "alphabet: Bitcoin alphabet rejects characters valid only in Ripple ordering" {
    // The two alphabets share the same 58 chars in different orders, so neither
    // can have chars the other lacks. What changes is that the *same* string
    // decodes to different bytes. Verify by encoding under one alphabet and
    // decoding under the other — the result must differ from the original.
    const allocator = std.testing.allocator;

    const original = [_]u8{ 0xAB, 0xCD, 0xEF };
    const xrp_encoded = try encodeWith(allocator, &Alphabet.ripple, &original);
    defer allocator.free(xrp_encoded);

    const btc_decoded = try decodeWith(allocator, &Alphabet.bitcoin, xrp_encoded);
    defer allocator.free(btc_decoded);

    try std.testing.expect(!std.mem.eql(u8, &original, btc_decoded));
}
