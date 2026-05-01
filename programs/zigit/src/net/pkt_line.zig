// pkt-line — git's wire framing for the smart HTTP/SSH protocol.
//
// Every "line" is prefixed by a 4-character ASCII hex length (most-
// significant first) that includes the 4 bytes of the prefix itself.
// So a one-byte payload "x" is encoded as `0005x`. Three special
// short prefixes:
//
//   0000 = flush packet  (end of a section)
//   0001 = delim packet  (sub-section separator inside a fetch response)
//   0002 = response-end  (v2 only — end of a server reply)
//
// Both encoded length and decoded payload exclude the trailing
// newline that real git appends to most pkt-lines for human
// readability — we honour it on emit (caller can pass `\n`-terminated
// payloads explicitly) but strip nothing on read.

const std = @import("std");

pub const max_payload: usize = 65516; // 65520 − 4 prefix bytes

pub const Packet = union(enum) {
    flush,
    delim,
    response_end,
    /// Borrows from the input bytes — copy if needed.
    data: []const u8,
};

/// Parse a single pkt-line from `bytes` starting at `offset`.
/// Returns the packet plus the byte cursor past it.
pub fn read(bytes: []const u8, offset: usize) !struct { packet: Packet, advance: usize } {
    if (bytes.len < offset + 4) return error.UnexpectedEofInPktLine;
    const len = try std.fmt.parseInt(u16, bytes[offset .. offset + 4], 16);

    if (len == 0) return .{ .packet = .flush, .advance = 4 };
    if (len == 1) return .{ .packet = .delim, .advance = 4 };
    if (len == 2) return .{ .packet = .response_end, .advance = 4 };
    if (len == 3) return error.MalformedPktLineLength;
    if (len < 4) return error.MalformedPktLineLength;

    const total = @as(usize, len);
    if (bytes.len < offset + total) return error.UnexpectedEofInPktLine;
    return .{
        .packet = .{ .data = bytes[offset + 4 .. offset + total] },
        .advance = total,
    };
}

/// Write `payload` as one data pkt-line to `w`. Errors if payload
/// exceeds `max_payload` since the 4-char hex length tops out at
/// 65520 = max_payload + 4.
pub fn writeData(w: *std.Io.Writer, payload: []const u8) !void {
    if (payload.len > max_payload) return error.PktLinePayloadTooLong;
    const total: u16 = @intCast(payload.len + 4);
    var prefix_buf: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&prefix_buf, "{x:0>4}", .{total}) catch unreachable;
    try w.writeAll(&prefix_buf);
    try w.writeAll(payload);
}

pub fn writeFlush(w: *std.Io.Writer) !void {
    try w.writeAll("0000");
}

pub fn writeDelim(w: *std.Io.Writer) !void {
    try w.writeAll("0001");
}

const testing = std.testing;

test "read data packet" {
    const bytes = "0006xy\x00\x00";
    const got = try read(bytes, 0);
    try testing.expect(got.packet == .data);
    try testing.expectEqualStrings("xy", got.packet.data);
    try testing.expectEqual(@as(usize, 6), got.advance);
}

test "read flush packet" {
    const got = try read("0000", 0);
    try testing.expect(got.packet == .flush);
    try testing.expectEqual(@as(usize, 4), got.advance);
}

test "read delim and response_end" {
    const d = try read("0001", 0);
    try testing.expect(d.packet == .delim);
    const r = try read("0002", 0);
    try testing.expect(r.packet == .response_end);
}

test "read rejects malformed length" {
    try testing.expectError(error.MalformedPktLineLength, read("0003", 0));
}

test "writeData round-trips" {
    var allocating: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 64);
    defer allocating.deinit();
    try writeData(&allocating.writer, "command=ls-refs\n");
    const expected = "0014command=ls-refs\n";
    try testing.expectEqualStrings(expected, allocating.written());

    const got = try read(allocating.written(), 0);
    try testing.expect(got.packet == .data);
    try testing.expectEqualStrings("command=ls-refs\n", got.packet.data);
}

test "writeFlush emits 0000" {
    var allocating: std.Io.Writer.Allocating = try .initCapacity(testing.allocator, 16);
    defer allocating.deinit();
    try writeFlush(&allocating.writer);
    try testing.expectEqualStrings("0000", allocating.written());
}
