//! WebSocket Protocol Implementation (RFC 6455)
//! Zero-copy frame parsing and building optimized for exchange APIs

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const crypto = std.crypto;
const Sha1 = crypto.hash.Sha1;

// Random bytes helper for Zig 0.16.2187+
fn getRandomBytes(buf: []u8) void {
    _ = linux.getrandom(buf.ptr, buf.len, 0);
}

/// WebSocket opcode types
pub const Opcode = enum(u8) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,

    pub fn fromByte(byte: u8) ?Opcode {
        return switch (byte & 0x0F) {
            0x0 => .continuation,
            0x1 => .text,
            0x2 => .binary,
            0x8 => .close,
            0x9 => .ping,
            0xA => .pong,
            else => null,
        };
    }
};

/// WebSocket frame header
pub const FrameHeader = struct {
    fin: bool,
    opcode: Opcode,
    masked: bool,
    payload_len: u64,
    mask_key: ?[4]u8,
};

/// WebSocket handshake request builder
pub const HandshakeBuilder = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
    sec_key: [24]u8, // Base64-encoded 16-byte random value

    pub fn init(host: []const u8, port: u16, path: []const u8) HandshakeBuilder {
        var builder: HandshakeBuilder = .{
            .host = host,
            .port = port,
            .path = path,
            .sec_key = undefined,
        };

        // Generate random Sec-WebSocket-Key (16 bytes → 24 base64 chars)
        var random_bytes: [16]u8 = undefined;
        getRandomBytes(&random_bytes);
        _ = std.base64.standard.Encoder.encode(&builder.sec_key, &random_bytes);

        return builder;
    }

    /// Build HTTP upgrade request
    pub fn buildRequest(self: *const HandshakeBuilder, buffer: []u8) ![]const u8 {
        // RFC 6455: Only include port in Host header if non-default (not 443 for wss://)
        const request = if (self.port == 443)
            try std.fmt.bufPrint(
                buffer,
                "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
                .{ self.path, self.host, self.sec_key[0..] },
            )
        else
            try std.fmt.bufPrint(
                buffer,
                "GET {s} HTTP/1.1\r\nHost: {s}:{}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
                .{ self.path, self.host, self.port, self.sec_key[0..] },
            );
        return request;
    }

    /// Verify handshake response
    pub fn verifyResponse(self: *const HandshakeBuilder, response: []const u8) !void {
        // Check HTTP/1.1 101 Switching Protocols
        if (std.mem.indexOf(u8, response, "HTTP/1.1 101") == null) {
            return error.InvalidHandshakeResponse;
        }

        // Calculate expected Sec-WebSocket-Accept
        const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        var sha1_input: [24 + ws_guid.len]u8 = undefined;
        @memcpy(sha1_input[0..24], &self.sec_key);
        @memcpy(sha1_input[24..], ws_guid);

        var sha1_hash: [Sha1.digest_length]u8 = undefined;
        Sha1.hash(&sha1_input, &sha1_hash, .{});

        var expected_accept: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&expected_accept, &sha1_hash);

        // Find Sec-WebSocket-Accept in response
        const accept_header = "Sec-WebSocket-Accept: ";
        const accept_pos = std.mem.indexOf(u8, response, accept_header) orelse
            return error.MissingAcceptHeader;

        const accept_start = accept_pos + accept_header.len;
        const accept_end = std.mem.indexOfPos(u8, response, accept_start, "\r\n") orelse
            return error.InvalidAcceptHeader;

        const received_accept = response[accept_start..accept_end];

        if (!std.mem.eql(u8, expected_accept[0..], received_accept)) {
            return error.InvalidAcceptValue;
        }
    }
};

/// WebSocket frame parser (zero-copy where possible)
pub const FrameParser = struct {
    /// Parse frame header from buffer
    pub fn parseHeader(buffer: []const u8) !struct { header: FrameHeader, header_len: usize } {
        if (buffer.len < 2) return error.IncompleteFrame;

        const byte0 = buffer[0];
        const byte1 = buffer[1];

        const fin = (byte0 & 0x80) != 0;
        const opcode = Opcode.fromByte(byte0) orelse return error.InvalidOpcode;
        const masked = (byte1 & 0x80) != 0;
        const payload_len_byte = byte1 & 0x7F;

        var payload_len: u64 = 0;
        var header_len: usize = 2;

        if (payload_len_byte <= 125) {
            payload_len = payload_len_byte;
        } else if (payload_len_byte == 126) {
            if (buffer.len < 4) return error.IncompleteFrame;
            payload_len = std.mem.readInt(u16, buffer[2..4][0..2], .big);
            header_len = 4;
        } else if (payload_len_byte == 127) {
            if (buffer.len < 10) return error.IncompleteFrame;
            payload_len = std.mem.readInt(u64, buffer[2..10][0..8], .big);
            header_len = 10;
        }

        var mask_key: ?[4]u8 = null;
        if (masked) {
            if (buffer.len < header_len + 4) return error.IncompleteFrame;
            mask_key = buffer[header_len..][0..4].*;
            header_len += 4;
        }

        return .{
            .header = .{
                .fin = fin,
                .opcode = opcode,
                .masked = masked,
                .payload_len = payload_len,
                .mask_key = mask_key,
            },
            .header_len = header_len,
        };
    }

    /// Unmask payload in-place
    pub fn unmaskPayload(payload: []u8, mask_key: [4]u8) void {
        for (payload, 0..) |*byte, i| {
            byte.* ^= mask_key[i % 4];
        }
    }
};

/// WebSocket frame builder (optimized for minimal allocations)
pub const FrameBuilder = struct {
    /// Build frame into pre-allocated buffer
    pub fn buildFrame(
        buffer: []u8,
        opcode: Opcode,
        payload: []const u8,
        masked: bool,
    ) ![]const u8 {
        var pos: usize = 0;

        // Byte 0: FIN=1, RSV=0, Opcode
        buffer[pos] = 0x80 | @intFromEnum(opcode);
        pos += 1;

        // Byte 1: MASK + Payload length
        const payload_len = payload.len;
        const mask_byte: u8 = if (masked) 0x80 else 0x00;

        if (payload_len <= 125) {
            buffer[pos] = mask_byte | @as(u8, @intCast(payload_len));
            pos += 1;
        } else if (payload_len <= 65535) {
            buffer[pos] = mask_byte | 126;
            pos += 1;
            std.mem.writeInt(u16, buffer[pos..][0..2], @as(u16, @intCast(payload_len)), .big);
            pos += 2;
        } else {
            buffer[pos] = mask_byte | 127;
            pos += 1;
            std.mem.writeInt(u64, buffer[pos..][0..8], @as(u64, @intCast(payload_len)), .big);
            pos += 8;
        }

        // Masking key (if client → server)
        var mask_key: [4]u8 = undefined;
        if (masked) {
            getRandomBytes(&mask_key);
            @memcpy(buffer[pos..][0..4], &mask_key);
            pos += 4;
        }

        // Payload
        @memcpy(buffer[pos..][0..payload_len], payload);

        // Apply mask if needed
        if (masked) {
            FrameParser.unmaskPayload(buffer[pos..][0..payload_len], mask_key);
        }

        pos += payload_len;

        return buffer[0..pos];
    }

    /// Build text frame (convenience wrapper)
    pub fn buildTextFrame(buffer: []u8, text: []const u8, masked: bool) ![]const u8 {
        return buildFrame(buffer, .text, text, masked);
    }

    /// Build binary frame
    pub fn buildBinaryFrame(buffer: []u8, data: []const u8, masked: bool) ![]const u8 {
        return buildFrame(buffer, .binary, data, masked);
    }

    /// Build ping frame
    pub fn buildPingFrame(buffer: []u8, masked: bool) ![]const u8 {
        return buildFrame(buffer, .ping, &.{}, masked);
    }

    /// Build pong frame
    pub fn buildPongFrame(buffer: []u8, ping_payload: []const u8, masked: bool) ![]const u8 {
        return buildFrame(buffer, .pong, ping_payload, masked);
    }

    /// Build close frame
    pub fn buildCloseFrame(buffer: []u8, masked: bool) ![]const u8 {
        return buildFrame(buffer, .close, &.{}, masked);
    }
};

// Tests
test "handshake builder" {
    const builder = HandshakeBuilder.init("example.com", 443, "/ws");

    var buffer: [1024]u8 = undefined;
    const request = try builder.buildRequest(&buffer);

    try std.testing.expect(std.mem.indexOf(u8, request, "GET /ws HTTP/1.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "Host: example.com:443") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "Upgrade: websocket") != null);
}

test "frame parser - simple text frame" {
    // Frame: FIN=1, TEXT, MASK=0, len=5, payload="Hello"
    const frame = [_]u8{ 0x81, 0x05, 'H', 'e', 'l', 'l', 'o' };

    const result = try FrameParser.parseHeader(&frame);

    try std.testing.expect(result.header.fin);
    try std.testing.expect(result.header.opcode == .text);
    try std.testing.expect(!result.header.masked);
    try std.testing.expectEqual(@as(u64, 5), result.header.payload_len);
    try std.testing.expectEqual(@as(usize, 2), result.header_len);
}

test "frame builder - ping/pong" {
    var buffer: [256]u8 = undefined;

    // Build ping
    const ping = try FrameBuilder.buildPingFrame(&buffer, false);
    try std.testing.expectEqual(@as(usize, 2), ping.len);
    try std.testing.expectEqual(@as(u8, 0x89), ping[0]); // FIN + PING
    try std.testing.expectEqual(@as(u8, 0x00), ping[1]); // No mask, len=0

    // Build pong
    const pong = try FrameBuilder.buildPongFrame(&buffer, &.{}, false);
    try std.testing.expectEqual(@as(usize, 2), pong.len);
    try std.testing.expectEqual(@as(u8, 0x8A), pong[0]); // FIN + PONG
}
