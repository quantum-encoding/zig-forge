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

pub const Error = error{
    InvalidCharacter,
    InvalidChecksum,
    EmptyInput,
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
    errdefer allocator.free(results);

    for (items, 0..) |item, i| {
        results[i] = try encode(allocator, item);
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

// ----- Tier 2: failure-mode tests -----

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
