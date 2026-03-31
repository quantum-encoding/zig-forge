// Base64 encoding/decoding utilities for image data handling
// Wraps std.base64 with a simpler API for media operations

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Standard Base64 encoder (with + and /)
const standard = std.base64.standard;

/// URL-safe Base64 encoder (with - and _, no padding)
const url_safe = std.base64.url_safe_no_pad;

/// Encode binary data to standard Base64 string
/// Caller owns the returned memory
pub fn encode(allocator: Allocator, data: []const u8) Allocator.Error![]u8 {
    const encoded_len = standard.Encoder.calcSize(data.len);
    const result = try allocator.alloc(u8, encoded_len);
    _ = standard.Encoder.encode(result, data);
    return result;
}

/// Decode standard Base64 string to binary data
/// Caller owns the returned memory
pub fn decode(allocator: Allocator, encoded: []const u8) ![]u8 {
    const decoded_len = try standard.Decoder.calcSizeForSlice(encoded);
    const result = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(result);
    try standard.Decoder.decode(result, encoded);
    return result;
}

/// Encode binary data to URL-safe Base64 string (no padding)
/// Caller owns the returned memory
pub fn encodeUrl(allocator: Allocator, data: []const u8) Allocator.Error![]u8 {
    const encoded_len = url_safe.Encoder.calcSize(data.len);
    const result = try allocator.alloc(u8, encoded_len);
    _ = url_safe.Encoder.encode(result, data);
    return result;
}

/// Decode URL-safe Base64 string to binary data
/// Caller owns the returned memory
pub fn decodeUrl(allocator: Allocator, encoded: []const u8) ![]u8 {
    const decoded_len = try url_safe.Decoder.calcSizeForSlice(encoded);
    const result = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(result);
    try url_safe.Decoder.decode(result, encoded);
    return result;
}

/// Calculate the encoded length for a given input length (standard)
pub fn calcEncodedLen(input_len: usize) usize {
    return standard.Encoder.calcSize(input_len);
}

/// Calculate the encoded length for a given input length (URL-safe, no padding)
pub fn calcEncodedLenUrl(input_len: usize) usize {
    return url_safe.Encoder.calcSize(input_len);
}

// ============================================================================
// Tests
// ============================================================================

test "encode and decode roundtrip" {
    const allocator = std.testing.allocator;

    const original = "Hello, World!";
    const encoded = try encode(allocator, original);
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("SGVsbG8sIFdvcmxkIQ==", encoded);

    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(original, decoded);
}

test "encode and decode URL-safe roundtrip" {
    const allocator = std.testing.allocator;

    const original = "Hello, World!";
    const encoded = try encodeUrl(allocator, original);
    defer allocator.free(encoded);

    // URL-safe has no padding and uses - and _ instead of + and /
    try std.testing.expectEqualStrings("SGVsbG8sIFdvcmxkIQ", encoded);

    const decoded = try decodeUrl(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(original, decoded);
}

test "encode binary data" {
    const allocator = std.testing.allocator;

    // PNG magic bytes
    const png_header = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    const encoded = try encode(allocator, &png_header);
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("iVBORw0KGgo=", encoded);

    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, &png_header, decoded);
}

test "calcEncodedLen" {
    try std.testing.expectEqual(@as(usize, 0), calcEncodedLen(0));
    try std.testing.expectEqual(@as(usize, 4), calcEncodedLen(1));
    try std.testing.expectEqual(@as(usize, 4), calcEncodedLen(2));
    try std.testing.expectEqual(@as(usize, 4), calcEncodedLen(3));
    try std.testing.expectEqual(@as(usize, 8), calcEncodedLen(4));
}
