//! Base58 Encoding Library (Zig 0.16)
//!
//! Bitcoin-style Base58 encoding with optional Base58Check checksums.
//! Implements the standard Base58 alphabet used by Bitcoin and IPFS.
//!
//! Example:
//! ```zig
//! const base58 = @import("base58");
//!
//! // Encode bytes to Base58
//! const encoded = try base58.encode(allocator, &input_bytes);
//! defer allocator.free(encoded);
//!
//! // Decode Base58 string to bytes
//! const decoded = try base58.decode(allocator, encoded);
//! defer allocator.free(decoded);
//!
//! // Base58Check (with SHA256 checksum)
//! const checked = try base58.encodeCheck(allocator, &input_bytes);
//! defer allocator.free(checked);
//! ```

const std = @import("std");
const mem = std.mem;
const math = std.math;

/// Standard Bitcoin/IPFS Base58 alphabet
const ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/// Base58 error types
pub const Error = error{
    InvalidCharacter,
    InvalidChecksum,
    EmptyInput,
};

/// Encodes data to Base58 string
/// Caller owns the returned memory
pub fn encode(allocator: mem.Allocator, data: []const u8) ![]u8 {
    if (data.len == 0) {
        return allocator.alloc(u8, 0);
    }

    // Count leading zeros
    var leading_zeros: usize = 0;
    for (data) |byte| {
        if (byte == 0) {
            leading_zeros += 1;
        } else {
            break;
        }
    }

    // Allocate buffer for encoding (base58 is ~1.37x larger than base256)
    const max_len = ((data.len * 138) / 100) + 1;
    var buf = try allocator.alloc(u8, max_len);
    errdefer allocator.free(buf);

    var buf_len: usize = 0;

    // Process non-leading-zero bytes
    for (data[leading_zeros..]) |byte| {
        var carry: u16 = byte;
        var i: usize = 0;

        while (i < buf_len) : (i += 1) {
            const temp = @as(u16, buf[i]) * 256 + carry;
            buf[i] = @as(u8, @intCast(temp % 58));
            carry = temp / 58;
        }

        while (carry > 0) {
            buf[buf_len] = @as(u8, @intCast(carry % 58));
            buf_len += 1;
            carry = carry / 58;
        }
    }

    // Reverse the buffer
    var i: usize = 0;
    var j: usize = buf_len;
    while (i < j) {
        j -= 1;
        const temp = buf[i];
        buf[i] = buf[j];
        buf[j] = temp;
        i += 1;
    }

    // Add leading '1' for each leading zero byte
    var result = try allocator.alloc(u8, leading_zeros + buf_len);
    errdefer allocator.free(result);

    for (0..leading_zeros) |idx| {
        result[idx] = '1';
    }

    for (0..buf_len) |idx| {
        result[leading_zeros + idx] = ALPHABET[buf[idx]];
    }

    allocator.free(buf);
    return result;
}

/// Decodes a Base58 string to bytes
/// Caller owns the returned memory
pub fn decode(allocator: mem.Allocator, encoded: []const u8) ![]u8 {
    if (encoded.len == 0) {
        return allocator.alloc(u8, 0);
    }

    // Count leading '1's
    var leading_ones: usize = 0;
    for (encoded) |char| {
        if (char == '1') {
            leading_ones += 1;
        } else {
            break;
        }
    }

    // Create reverse alphabet lookup
    var alphabet_map: [256]u8 = undefined;
    for (0..256) |idx| {
        alphabet_map[idx] = 255;
    }
    for (0..ALPHABET.len) |idx| {
        alphabet_map[ALPHABET[idx]] = @as(u8, @intCast(idx));
    }

    // Decode
    var buf = try allocator.alloc(u8, encoded.len);
    errdefer allocator.free(buf);
    var buf_len: usize = 0;

    for (encoded[leading_ones..]) |char| {
        if (alphabet_map[char] == 255) {
            return error.InvalidCharacter;
        }

        const digit = alphabet_map[char];
        var carry: u16 = digit;
        var i: usize = 0;

        while (i < buf_len) : (i += 1) {
            const temp = @as(u16, buf[i]) * 58 + carry;
            buf[i] = @as(u8, @intCast(temp % 256));
            carry = temp / 256;
        }

        while (carry > 0) {
            buf[buf_len] = @as(u8, @intCast(carry % 256));
            buf_len += 1;
            carry = carry / 256;
        }
    }

    // Reverse the buffer
    var i: usize = 0;
    var j: usize = buf_len;
    while (i < j) {
        j -= 1;
        const temp = buf[i];
        buf[i] = buf[j];
        buf[j] = temp;
        i += 1;
    }

    // Add leading zero bytes
    var result = try allocator.alloc(u8, leading_ones + buf_len);
    errdefer allocator.free(result);

    for (0..leading_ones) |idx| {
        result[idx] = 0;
    }
    for (0..buf_len) |idx| {
        result[leading_ones + idx] = buf[idx];
    }

    allocator.free(buf);
    return result;
}

/// Encodes data with Base58Check (SHA256 checksum)
/// Format: <version><data><checksum>
/// Caller owns the returned memory
pub fn encodeCheck(allocator: mem.Allocator, data: []const u8) ![]u8 {
    // Create buffer: data + 4-byte checksum
    var payload = try allocator.alloc(u8, data.len + 4);
    defer allocator.free(payload);

    @memcpy(payload[0..data.len], data);

    // Calculate SHA256 checksum
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload[0..data.len], &hash, .{});

    // Take first 4 bytes of hash
    @memcpy(payload[data.len..], hash[0..4]);

    // Encode the payload with checksum
    return encode(allocator, payload);
}

/// Decodes a Base58Check string and verifies the checksum
/// Caller owns the returned memory
pub fn decodeCheck(allocator: mem.Allocator, encoded: []const u8) ![]u8 {
    // Decode the Base58 string
    var decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    if (decoded.len < 4) {
        return error.InvalidChecksum;
    }

    // Verify checksum
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(decoded[0 .. decoded.len - 4], &hash, .{});

    if (!mem.eql(u8, hash[0..4], decoded[decoded.len - 4 .. decoded.len])) {
        return error.InvalidChecksum;
    }

    // Return data without checksum
    const result = try allocator.alloc(u8, decoded.len - 4);
    errdefer allocator.free(result);
    @memcpy(result, decoded[0 .. decoded.len - 4]);
    return result;
}

/// Stream encoder for large data
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

/// Stream decoder for large Base58 encoded data
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

/// Encode multiple byte slices efficiently with reusable buffers
pub fn encodeBatch(allocator: mem.Allocator, items: []const []const u8) ![][]u8 {
    const results = try allocator.alloc([]u8, items.len);
    errdefer allocator.free(results);

    for (items, 0..) |item, i| {
        results[i] = try encode(allocator, item);
    }

    return results;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "encode empty input" {
    const allocator = std.heap.c_allocator;

    const result = try encode(allocator, "");
    defer allocator.free(result);
    try std.testing.expectEqual(result.len, 0);
}

test "encode single zero byte" {
    const allocator = std.heap.c_allocator;

    const result = try encode(allocator, &[_]u8{0});
    defer allocator.free(result);
    try std.testing.expectEqualSlices(u8, result, "1");
}

test "encode multiple leading zeros" {
    const allocator = std.heap.c_allocator;

    const result = try encode(allocator, &[_]u8{ 0, 0, 0, 1 });
    defer allocator.free(result);
    try std.testing.expectEqualSlices(u8, result, "1112");
}

test "encode and decode roundtrip" {
    const allocator = std.heap.c_allocator;

    const input = "Hello, World!";
    const encoded = try encode(allocator, input);
    defer allocator.free(encoded);

    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, input, decoded);
}

test "encodeCheck and decodeCheck roundtrip" {
    const allocator = std.heap.c_allocator;

    const input = "Bitcoin is awesome";
    const encoded = try encodeCheck(allocator, input);
    defer allocator.free(encoded);

    const decoded = try decodeCheck(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, input, decoded);
}

test "decodeCheck rejects invalid checksum" {
    const allocator = std.heap.c_allocator;

    const input = "Test data";
    var encoded = try encodeCheck(allocator, input);
    defer allocator.free(encoded);

    // Corrupt the checksum by modifying the last character
    if (encoded.len > 0) {
        if (encoded[encoded.len - 1] == '2') {
            encoded[encoded.len - 1] = '3';
        } else {
            encoded[encoded.len - 1] = '2';
        }

        const result = decodeCheck(allocator, encoded);
        try std.testing.expectError(error.InvalidChecksum, result);
    }
}

test "known test vector" {
    const allocator = std.heap.c_allocator;

    // Standard test vector: 0x00 0x14 0x1C 0xDA ...
    const test_data = &[_]u8{ 0x00, 0x14, 0x1c, 0xda };
    const encoded = try encode(allocator, test_data);
    defer allocator.free(encoded);

    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, test_data, decoded);
}

test "stream encoder" {
    const allocator = std.heap.c_allocator;

    var encoder = try StreamEncoder.init(allocator, 1024);
    defer encoder.deinit();

    try encoder.write("Hello");
    try encoder.write(" ");
    try encoder.write("Stream");

    const encoded = try encoder.finish();
    defer allocator.free(encoded);

    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, "Hello Stream", decoded);
}

test "decode invalid character" {
    const allocator = std.heap.c_allocator;

    // '0' is not in Base58 alphabet
    const result = decode(allocator, "123O456");
    try std.testing.expectError(error.InvalidCharacter, result);
}

test "stream decoder" {
    const allocator = std.heap.c_allocator;

    var decoder = try StreamDecoder.init(allocator, 1024);
    defer decoder.deinit();

    const original = "Hello Stream";
    const encoded = try encode(allocator, original);
    defer allocator.free(encoded);

    try decoder.feed(encoded);
    const decoded = try decoder.finalize();
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, original, decoded);
}

test "stream decoder partial feeds" {
    const allocator = std.heap.c_allocator;

    var decoder = try StreamDecoder.init(allocator, 1024);
    defer decoder.deinit();

    const original = "Split feed test";
    const encoded = try encode(allocator, original);
    defer allocator.free(encoded);

    // Feed in two parts
    const mid = encoded.len / 2;
    try decoder.feed(encoded[0..mid]);
    try decoder.feed(encoded[mid..]);

    const decoded = try decoder.finalize();
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, original, decoded);
}

test "encodeBatch with multiple items" {
    const allocator = std.heap.c_allocator;

    const items = [_][]const u8{
        "first",
        "second",
        "third",
    };

    const batch = try encodeBatch(allocator, &items);
    defer {
        for (batch) |item| {
            allocator.free(item);
        }
        allocator.free(batch);
    }

    try std.testing.expectEqual(batch.len, 3);

    // Verify each can be decoded back
    for (batch, items) |encoded, original| {
        const decoded = try decode(allocator, encoded);
        defer allocator.free(decoded);
        try std.testing.expectEqualSlices(u8, original, decoded);
    }
}

test "encodeBatch with empty list" {
    const allocator = std.heap.c_allocator;

    const items = [_][]const u8{};
    const batch = try encodeBatch(allocator, &items);
    defer allocator.free(batch);

    try std.testing.expectEqual(batch.len, 0);
}

test "Bitcoin Mainnet P2PKH address (Satoshi)" {
    const allocator = std.heap.c_allocator;

    // Satoshi's address: 1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa
    const satoshi_address = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa";

    // Decode and re-encode to verify
    const decoded = try decode(allocator, satoshi_address);
    defer allocator.free(decoded);

    const reencoded = try encode(allocator, decoded);
    defer allocator.free(reencoded);

    try std.testing.expectEqualSlices(u8, satoshi_address, reencoded);
}

test "Base58Check roundtrip with known data" {
    const allocator = std.heap.c_allocator;

    // Test with a Bitcoin address payload (version byte + pubkey hash + checksum)
    const test_data = &[_]u8{ 0x00, 0x14, 0x1c, 0xda, 0x64, 0xb6, 0x14, 0x61, 0x39, 0xda, 0x71, 0x0f, 0x34, 0x79, 0x83, 0x59, 0x5d, 0xf6, 0x55, 0xd5, 0x08 };

    const encoded = try encodeCheck(allocator, test_data);
    defer allocator.free(encoded);

    const decoded = try decodeCheck(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, test_data, decoded);
}
