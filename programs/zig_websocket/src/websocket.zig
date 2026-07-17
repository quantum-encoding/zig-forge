//! zig_websocket - RFC 6455 WebSocket Protocol Library
//!
//! A pure Zig implementation of the WebSocket protocol (RFC 6455).
//! Handles frame parsing, building, masking, and handshake validation.
//!
//! Features:
//! - Frame parsing (text, binary, ping, pong, close, continuation)
//! - Frame building with proper masking
//! - Handshake validation (Sec-WebSocket-Key -> Sec-WebSocket-Accept)
//! - Connection state machine
//! - Message fragmentation support
//! - Close frame handling with status codes
//! - Zero-copy where possible

const std = @import("std");
const crypto = std.crypto;

/// Maximum accepted frame payload size (bytes). A frame whose declared
/// payload length exceeds this is rejected before any allocation, which
/// defends against attacker-controlled allocation bombs and length-field
/// integer overflow in the header+payload arithmetic. 64 MiB.
pub const max_frame_size: u64 = 64 * 1024 * 1024;

/// WebSocket frame opcodes (RFC 6455 Section 5.2)
pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,

    pub fn isControl(self: Opcode) bool {
        return @intFromEnum(self) >= 0x8;
    }

    pub fn isReserved(self: Opcode) bool {
        const val = @intFromEnum(self);
        return (val >= 0x3 and val <= 0x7) or (val >= 0xB);
    }
};

/// WebSocket close status codes (RFC 6455 Section 7.4)
pub const CloseCode = enum(u16) {
    normal_closure = 1000,
    going_away = 1001,
    protocol_error = 1002,
    unsupported_data = 1003,
    reserved_1004 = 1004,
    no_status_received = 1005,
    abnormal_closure = 1006,
    invalid_frame_payload = 1007,
    policy_violation = 1008,
    message_too_big = 1009,
    missing_extension = 1010,
    internal_error = 1011,
    service_restart = 1012,
    try_again_later = 1013,
    bad_gateway = 1014,
    tls_handshake = 1015,

    pub fn isValid(code: u16) bool {
        return switch (code) {
            1000...1003, 1007...1015 => true,
            else => false,
        };
    }
};

/// WebSocket frame header
pub const FrameHeader = struct {
    fin: bool,
    rsv1: bool = false,
    rsv2: bool = false,
    rsv3: bool = false,
    opcode: Opcode,
    mask: bool,
    payload_len: u64,

    /// Serialize frame header to bytes
    pub fn toBytes(self: FrameHeader, allocator: std.mem.Allocator, masking_key: ?[4]u8) ![]u8 {
        var buffer = std.array_list.AlignedManaged(u8, null).init(allocator);
        defer buffer.deinit();

        // First byte: FIN (1 bit) | RSV (3 bits) | Opcode (4 bits)
        var byte1: u8 = 0;
        if (self.fin) byte1 |= 0x80;
        if (self.rsv1) byte1 |= 0x40;
        if (self.rsv2) byte1 |= 0x20;
        if (self.rsv3) byte1 |= 0x10;
        byte1 |= (@intFromEnum(self.opcode) & 0x0F);
        try buffer.append(byte1);

        // Second byte: MASK (1 bit) | Payload length (7 bits)
        var byte2: u8 = 0;
        if (self.mask) byte2 |= 0x80;

        if (self.payload_len < 126) {
            byte2 |= @as(u8, @truncate(self.payload_len & 0x7F));
            try buffer.append(byte2);
        } else if (self.payload_len < 65536) {
            byte2 |= 126;
            try buffer.append(byte2);
            try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, @as(u16, @truncate(self.payload_len)))));
        } else {
            byte2 |= 127;
            try buffer.append(byte2);
            try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u64, self.payload_len)));
        }

        // Append masking key if present
        if (masking_key) |key| {
            try buffer.appendSlice(&key);
        }

        return buffer.toOwnedSlice();
    }

    /// Parse frame header from bytes
    pub fn fromBytes(data: []const u8) !struct { header: FrameHeader, header_len: usize } {
        if (data.len < 2) return error.IncompleteHeader;

        const byte1 = data[0];
        const byte2 = data[1];

        const fin = (byte1 & 0x80) != 0;
        const rsv1 = (byte1 & 0x40) != 0;
        const rsv2 = (byte1 & 0x20) != 0;
        const rsv3 = (byte1 & 0x10) != 0;

        const opcode_val = byte1 & 0x0F;
        const opcode: Opcode = switch (opcode_val) {
            0x0 => .continuation,
            0x1 => .text,
            0x2 => .binary,
            0x8 => .close,
            0x9 => .ping,
            0xA => .pong,
            else => return error.ReservedOpcode,
        };

        if (opcode.isReserved()) return error.ReservedOpcode;

        const mask = (byte2 & 0x80) != 0;
        const payload_len_7 = byte2 & 0x7F;
        var header_len: usize = 2;
        var payload_len: u64 = 0;

        if (payload_len_7 == 126) {
            if (data.len < 4) return error.IncompleteHeader;
            payload_len = std.mem.readInt(u16, data[2..4], .big);
            header_len = 4;
        } else if (payload_len_7 == 127) {
            if (data.len < 10) return error.IncompleteHeader;
            payload_len = std.mem.readInt(u64, data[2..10], .big);
            header_len = 10;
        } else {
            payload_len = payload_len_7;
        }

        if (mask) {
            if (data.len < header_len + 4) return error.IncompleteHeader;
            header_len += 4;
        }

        return .{
            .header = FrameHeader{
                .fin = fin,
                .rsv1 = rsv1,
                .rsv2 = rsv2,
                .rsv3 = rsv3,
                .opcode = opcode,
                .mask = mask,
                .payload_len = payload_len,
            },
            .header_len = header_len,
        };
    }
};

/// WebSocket frame
pub const Frame = struct {
    fin: bool,
    opcode: Opcode,
    payload: []u8,
    masking_key: ?[4]u8 = null,

    /// Create a new unmasked frame
    pub fn init(allocator: std.mem.Allocator, fin: bool, opcode: Opcode, payload: []const u8) !Frame {
        const owned_payload = try allocator.dupe(u8, payload);
        return Frame{
            .fin = fin,
            .opcode = opcode,
            .payload = owned_payload,
        };
    }

    /// Create a masked frame (for client-to-server)
    pub fn initMasked(allocator: std.mem.Allocator, fin: bool, opcode: Opcode, payload: []const u8) !Frame {
        // RFC 6455 §5.3 requires the masking key to be derived from a strong
        // source of entropy — it is the defense against intermediary
        // cache-poisoning attacks. Use the CSPRNG, never a clock-seeded PRNG.
        var key: [4]u8 = undefined;
        std.crypto.random.bytes(&key);

        const owned_payload = try allocator.dupe(u8, payload);
        return Frame{
            .fin = fin,
            .opcode = opcode,
            .payload = owned_payload,
            .masking_key = key,
        };
    }

    /// Serialize frame to bytes
    pub fn toBytes(self: *const Frame, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.array_list.AlignedManaged(u8, null).init(allocator);
        defer buffer.deinit();

        const header = FrameHeader{
            .fin = self.fin,
            .opcode = self.opcode,
            .mask = self.masking_key != null,
            .payload_len = self.payload.len,
        };

        const header_bytes = try header.toBytes(allocator, self.masking_key);
        defer allocator.free(header_bytes);

        try buffer.appendSlice(header_bytes);

        // Append payload (masked if applicable)
        if (self.masking_key) |key| {
            const masked_payload = try allocator.dupe(u8, self.payload);
            defer allocator.free(masked_payload);

            for (masked_payload, 0..) |*byte, i| {
                byte.* ^= key[i % 4];
            }
            try buffer.appendSlice(masked_payload);
        } else {
            try buffer.appendSlice(self.payload);
        }

        return buffer.toOwnedSlice();
    }

    /// Parse frame from bytes (returns frame and bytes consumed)
    pub fn fromBytes(allocator: std.mem.Allocator, data: []const u8) !struct { frame: Frame, bytes_consumed: usize } {
        const parse_result = try FrameHeader.fromBytes(data);
        const header = parse_result.header;
        const header_len = parse_result.header_len;

        // Bound the attacker-controlled payload length before doing any
        // arithmetic on it, then compute header_len + payload_len with an
        // overflow-checked add so a length near 2^64 cannot wrap the bounds
        // check and produce an inverted slice range.
        if (header.payload_len > max_frame_size) return error.FrameTooLarge;
        const total = std.math.add(usize, header_len, @intCast(header.payload_len)) catch return error.FrameTooLarge;

        if (data.len < total) {
            return error.IncompleteFrame;
        }

        const payload_start = header_len;
        const payload_end = total;
        const payload = try allocator.dupe(u8, data[payload_start..payload_end]);

        // Unmask payload if masked
        var masking_key: ?[4]u8 = null;
        if (header.mask) {
            const key_slice = data[header_len - 4 .. header_len];
            var key: [4]u8 = undefined;
            @memcpy(&key, key_slice);
            masking_key = key;
            for (payload, 0..) |*byte, i| {
                byte.* ^= masking_key.?[i % 4];
            }
        }

        return .{
            .frame = Frame{
                .fin = header.fin,
                .opcode = header.opcode,
                .payload = payload,
                .masking_key = masking_key,
            },
            .bytes_consumed = total,
        };
    }

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
    }
};

/// WebSocket close frame
pub const CloseFrame = struct {
    code: u16,
    reason: []const u8,

    pub fn parse(payload: []const u8) !CloseFrame {
        if (payload.len == 0) {
            return CloseFrame{
                .code = @intFromEnum(CloseCode.normal_closure),
                .reason = "",
            };
        }

        if (payload.len < 2) return error.InvalidCloseFrame;

        const code = std.mem.readInt(u16, payload[0..2], .big);
        if (!CloseCode.isValid(code)) return error.InvalidCloseCode;

        const reason = payload[2..];

        // Validate UTF-8 (RFC 6455 §8.1) with a real validator: rejects
        // truncated sequences, overlong encodings, surrogates and > U+10FFFF.
        if (!std.unicode.utf8ValidateSlice(reason)) return error.InvalidUtf8;

        return CloseFrame{
            .code = code,
            .reason = reason,
        };
    }

    pub fn toBytes(self: CloseFrame, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.array_list.AlignedManaged(u8, null).init(allocator);
        defer buffer.deinit();

        try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, self.code)));
        try buffer.appendSlice(self.reason);

        return buffer.toOwnedSlice();
    }
};

/// WebSocket handshake validation
pub const Handshake = struct {
    /// Generate Sec-WebSocket-Accept from Sec-WebSocket-Key
    pub fn generateAccept(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
        const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

        // Concatenate key + magic
        var combined = std.array_list.AlignedManaged(u8, null).init(allocator);
        defer combined.deinit();

        try combined.appendSlice(key);
        try combined.appendSlice(magic);

        // SHA1 hash
        var hash: [20]u8 = undefined;
        crypto.hash.Sha1.hash(combined.items, &hash, .{});

        // Base64 encode
        const b64_len = std.base64.standard.Encoder.calcSize(hash.len);
        const b64_buf = try allocator.alloc(u8, b64_len);
        _ = std.base64.standard.Encoder.encode(b64_buf, &hash);

        return b64_buf;
    }

    /// Validate handshake
    pub fn validate(allocator: std.mem.Allocator, key: []const u8, accept: []const u8) !bool {
        const expected = try generateAccept(allocator, key);
        defer allocator.free(expected);

        return std.mem.eql(u8, expected, accept);
    }
};

/// WebSocket connection state
pub const ConnectionState = enum {
    connecting,
    open,
    closing,
    closed,
};

/// WebSocket connection
pub const Connection = struct {
    allocator: std.mem.Allocator,
    state: ConnectionState = .connecting,
    is_server: bool = true,
    pending_close: bool = false,
    close_code: ?u16 = null,
    fragments: std.array_list.AlignedManaged(u8, null),
    pending_pong: ?[]u8 = null,
    fragment_opcode: ?Opcode = null,

    pub fn init(allocator: std.mem.Allocator, is_server: bool) Connection {
        return Connection{
            .allocator = allocator,
            .is_server = is_server,
            .fragments = std.array_list.AlignedManaged(u8, null).init(allocator),
        };
    }

    pub fn deinit(self: *Connection) void {
        self.fragments.deinit();
        if (self.pending_pong) |pong| {
            self.allocator.free(pong);
        }
    }

    /// Process incoming frame
    pub fn processFrame(self: *Connection, frame: *Frame) !void {
        if (frame.opcode.isControl()) {
            // Control frames must not be fragmented
            if (!frame.fin) return error.FragmentedControlFrame;

            // Control frames must have payload <= 125 bytes
            if (frame.payload.len > 125) return error.ControlFrameTooLarge;

            switch (frame.opcode) {
                .close => {
                    self.state = .closing;
                    if (frame.payload.len > 0) {
                        const close_frame = try CloseFrame.parse(frame.payload);
                        self.close_code = close_frame.code;
                    }
                },
                .ping => {
                    // Store pong payload to be sent by caller
                    if (self.pending_pong) |old_pong| {
                        self.allocator.free(old_pong);
                    }
                    self.pending_pong = try self.allocator.dupe(u8, frame.payload);
                },
                .pong => {},
                else => return error.InvalidControlFrame,
            }
        } else {
            // Data frames
            switch (frame.opcode) {
                .continuation => {
                    if (self.fragments.items.len == 0) {
                        return error.UnexpectedContinuation;
                    }
                    try self.fragments.appendSlice(frame.payload);
                    if (frame.fin) {
                        // Message complete - opcode already stored from first frame
                    }
                },
                .text, .binary => {
                    if (self.fragments.items.len > 0) {
                        return error.FragmentationError;
                    }
                    if (!frame.fin) {
                        // Start of fragmented message - store opcode
                        self.fragment_opcode = frame.opcode;
                        try self.fragments.appendSlice(frame.payload);
                    }
                },
                else => return error.InvalidDataFrame,
            }
        }
    }

    /// Create close frame
    pub fn createCloseFrame(self: *Connection, code: u16, reason: []const u8) !Frame {
        var payload = std.array_list.AlignedManaged(u8, null).init(self.allocator);
        defer payload.deinit();

        // RFC 6455 §5.5.1 / §7.1.5: the 2-byte close code is transmitted in
        // network byte order (big-endian), not the host's native order.
        try payload.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u16, code)));
        try payload.appendSlice(reason);

        return Frame.init(
            self.allocator,
            true,
            .close,
            payload.items,
        );
    }

    /// Get pending pong payload and clear it
    pub fn getPendingPong(self: *Connection) ?[]u8 {
        const pong = self.pending_pong;
        self.pending_pong = null;
        return pong;
    }

    /// Get reassembled message and clear fragments
    pub fn getReassembledMessage(self: *Connection) !?struct { opcode: Opcode, payload: []u8 } {
        if (self.fragments.items.len == 0) return null;

        const opcode = self.fragment_opcode orelse .text;
        // Make a copy of the payload before clearing fragments
        const payload = try self.allocator.dupe(u8, self.fragments.items);
        self.fragment_opcode = null;
        self.fragments.clearAndFree();

        return .{
            .opcode = opcode,
            .payload = payload,
        };
    }

    /// Check if connection is closed
    pub fn isClosed(self: Connection) bool {
        return self.state == .closed;
    }
};

// Tests
test "Opcode enum values" {
    const testing = std.testing;

    try testing.expectEqual(@as(u4, 0x0), @intFromEnum(Opcode.continuation));
    try testing.expectEqual(@as(u4, 0x1), @intFromEnum(Opcode.text));
    try testing.expectEqual(@as(u4, 0x2), @intFromEnum(Opcode.binary));
    try testing.expectEqual(@as(u4, 0x8), @intFromEnum(Opcode.close));
}

test "Opcode.isControl" {
    const testing = std.testing;

    try testing.expect(!Opcode.text.isControl());
    try testing.expect(Opcode.ping.isControl());
    try testing.expect(Opcode.pong.isControl());
    try testing.expect(Opcode.close.isControl());
}

test "CloseCode.isValid" {
    const testing = std.testing;

    try testing.expect(CloseCode.isValid(1000));
    try testing.expect(CloseCode.isValid(1001));
    try testing.expect(!CloseCode.isValid(1004));
    try testing.expect(!CloseCode.isValid(999));
}

test "Frame header serialization and parsing" {
    const testing = std.testing;
    const allocator = std.heap.c_allocator;

    // Create and serialize a frame header
    const header = FrameHeader{
        .fin = true,
        .opcode = .text,
        .mask = false,
        .payload_len = 5,
    };

    const bytes = try header.toBytes(allocator, null);
    defer allocator.free(bytes);

    try testing.expectEqual(@as(usize, 2), bytes.len);

    // Parse it back
    const parsed = try FrameHeader.fromBytes(bytes);
    try testing.expect(parsed.header.fin);
    try testing.expectEqual(Opcode.text, parsed.header.opcode);
    try testing.expect(!parsed.header.mask);
    try testing.expectEqual(@as(u64, 5), parsed.header.payload_len);
}

test "Frame with masking" {
    const testing = std.testing;
    const allocator = std.heap.c_allocator;

    const payload = "Hello";
    var frame = try Frame.initMasked(allocator, true, .text, payload);
    defer frame.deinit(allocator);

    try testing.expect(frame.masking_key != null);
    try testing.expectEqual(@as(usize, 5), frame.payload.len);
}

test "Handshake accept generation" {
    const testing = std.testing;
    const allocator = std.heap.c_allocator;

    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    const accept = try Handshake.generateAccept(allocator, key);
    defer allocator.free(accept);

    // Expected value from RFC 6455 Section 1.2
    const expected = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=";
    try testing.expectEqualStrings(expected, accept);
}

test "UTF-8 validation (real validator, RFC 6455 §8.1)" {
    const testing = std.testing;
    const v = std.unicode.utf8ValidateSlice;

    // Valid UTF-8
    try testing.expect(v("Hello"));
    try testing.expect(v(""));
    try testing.expect(v("héllo 世界")); // multibyte

    // Invalid UTF-8 the fake validator used to accept
    try testing.expect(!v(&[_]u8{0xFF})); // invalid lead byte
    try testing.expect(!v(&[_]u8{0xC0})); // truncated sequence
    try testing.expect(!v(&[_]u8{ 0xC1, 0x41 })); // bad continuation byte
    try testing.expect(!v(&[_]u8{ 0xC0, 0x80 })); // overlong encoding of NUL
    try testing.expect(!v(&[_]u8{ 0xED, 0xA0, 0x80 })); // UTF-16 surrogate U+D800
    try testing.expect(!v(&[_]u8{ 0xF4, 0x90, 0x80, 0x80 })); // > U+10FFFF
}

test "Connection state machine" {
    const testing = std.testing;
    const allocator = std.heap.c_allocator;

    var conn = Connection.init(allocator, true);
    defer conn.deinit();

    try testing.expectEqual(ConnectionState.connecting, conn.state);
    try testing.expect(!conn.isClosed());

    conn.state = .open;
    try testing.expect(!conn.isClosed());

    conn.state = .closed;
    try testing.expect(conn.isClosed());
}

test "Frame round-trip encoding/decoding" {
    const testing = std.testing;
    const allocator = std.heap.c_allocator;

    const original_payload = "WebSocket test message";
    var frame = try Frame.init(allocator, true, .text, original_payload);
    defer frame.deinit(allocator);

    const bytes = try frame.toBytes(allocator);
    defer allocator.free(bytes);

    const parsed = try Frame.fromBytes(allocator, bytes);
    defer allocator.free(parsed.frame.payload);

    try testing.expectEqual(frame.fin, parsed.frame.fin);
    try testing.expectEqual(frame.opcode, parsed.frame.opcode);
    try testing.expectEqualSlices(u8, original_payload, parsed.frame.payload);
}

test "Ping frame generates pending pong" {
    const testing = std.testing;
    const allocator = std.heap.c_allocator;

    var conn = Connection.init(allocator, true);
    defer conn.deinit();

    const ping_payload = "test ping";
    var ping_frame = try Frame.init(allocator, true, .ping, ping_payload);
    defer ping_frame.deinit(allocator);

    try conn.processFrame(&ping_frame);

    const pong = conn.getPendingPong();
    defer if (pong) |p| allocator.free(p);

    try testing.expect(pong != null);
    try testing.expectEqualSlices(u8, ping_payload, pong.?);

    // Second call should return null
    try testing.expect(conn.getPendingPong() == null);
}

test "Fragment reassembly across 3 frames" {
    const testing = std.testing;
    const allocator = std.heap.c_allocator;

    var conn = Connection.init(allocator, true);
    defer conn.deinit();

    // First frame: start of fragmented text message
    var frame1 = try Frame.init(allocator, false, .text, "Hello ");
    defer frame1.deinit(allocator);
    try conn.processFrame(&frame1);

    // Second frame: continuation
    var frame2 = try Frame.init(allocator, false, .continuation, "World");
    defer frame2.deinit(allocator);
    try conn.processFrame(&frame2);

    // Third frame: final continuation
    var frame3 = try Frame.init(allocator, true, .continuation, "!");
    defer frame3.deinit(allocator);
    try conn.processFrame(&frame3);

    const msg = try conn.getReassembledMessage();
    defer if (msg) |m| allocator.free(m.payload);

    try testing.expect(msg != null);
    try testing.expectEqual(Opcode.text, msg.?.opcode);
    try testing.expectEqualSlices(u8, "Hello World!", msg.?.payload);
}

test "Close frame with reason text parsing and encoding roundtrip" {
    const testing = std.testing;
    const allocator = std.heap.c_allocator;

    // Create close frame with reason
    const close_code: u16 = @intFromEnum(CloseCode.normal_closure);
    const reason = "Going away";

    // Create a close frame directly
    const close = CloseFrame{
        .code = close_code,
        .reason = reason,
    };

    // Encode it
    const encoded = try close.toBytes(allocator);
    defer allocator.free(encoded);

    // Parse it back
    const parsed = try CloseFrame.parse(encoded);
    try testing.expectEqual(close_code, parsed.code);
    try testing.expectEqualSlices(u8, reason, parsed.reason);

    // Encode again and verify round-trip
    const encoded2 = try parsed.toBytes(allocator);
    defer allocator.free(encoded2);

    try testing.expectEqualSlices(u8, encoded, encoded2);
}

test "CloseCode validation for reserved codes" {
    const testing = std.testing;

    // Valid codes
    try testing.expect(CloseCode.isValid(1000));
    try testing.expect(CloseCode.isValid(1001));
    try testing.expect(CloseCode.isValid(1011));
    try testing.expect(CloseCode.isValid(1015));

    // Reserved/invalid codes
    try testing.expect(!CloseCode.isValid(1004));
    try testing.expect(!CloseCode.isValid(1005));
    try testing.expect(!CloseCode.isValid(1006));
    try testing.expect(!CloseCode.isValid(999));
    try testing.expect(!CloseCode.isValid(2000));
}

test "Large payload frame header - 126-byte length" {
    const testing = std.testing;
    const allocator = std.heap.c_allocator;

    // Create a 126-byte payload
    const payload = try allocator.alloc(u8, 126);
    defer allocator.free(payload);
    @memset(payload, 0x42);

    const header = FrameHeader{
        .fin = true,
        .opcode = .binary,
        .mask = false,
        .payload_len = 126,
    };

    const bytes = try header.toBytes(allocator, null);
    defer allocator.free(bytes);

    // Header should be 4 bytes (2 + 2 for extended length)
    try testing.expectEqual(@as(usize, 4), bytes.len);

    const parsed = try FrameHeader.fromBytes(bytes);
    try testing.expectEqual(@as(u64, 126), parsed.header.payload_len);
}

test "Large payload frame header - 65536-byte length" {
    const testing = std.testing;
    const allocator = std.heap.c_allocator;

    const header = FrameHeader{
        .fin = true,
        .opcode = .binary,
        .mask = false,
        .payload_len = 65536,
    };

    const bytes = try header.toBytes(allocator, null);
    defer allocator.free(bytes);

    // Header should be 10 bytes (2 + 8 for extended length)
    try testing.expectEqual(@as(usize, 10), bytes.len);

    const parsed = try FrameHeader.fromBytes(bytes);
    try testing.expectEqual(@as(u64, 65536), parsed.header.payload_len);
}

test "Multiple frames encoded and decoded sequentially" {
    const testing = std.testing;
    const allocator = std.heap.c_allocator;

    var buffer = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer buffer.deinit();

    // Encode 3 frames into buffer
    const messages = [_][]const u8{ "Frame 1", "Frame 2", "Frame 3" };
    for (messages) |msg| {
        var frame = try Frame.init(allocator, true, .text, msg);
        defer frame.deinit(allocator);

        const frame_bytes = try frame.toBytes(allocator);
        defer allocator.free(frame_bytes);

        try buffer.appendSlice(frame_bytes);
    }

    // Decode all frames from buffer
    var offset: usize = 0;
    var decoded_count: usize = 0;

    while (offset < buffer.items.len) {
        const remaining = buffer.items[offset..];
        const parse_result = try Frame.fromBytes(allocator, remaining);
        defer allocator.free(parse_result.frame.payload);

        try testing.expectEqual(Opcode.text, parse_result.frame.opcode);
        try testing.expect(parse_result.frame.fin);
        try testing.expectEqualSlices(u8, messages[decoded_count], parse_result.frame.payload);

        offset += parse_result.bytes_consumed;
        decoded_count += 1;
    }

    try testing.expectEqual(@as(usize, 3), decoded_count);
}

test "Masked frame XOR correctness verification" {
    const testing = std.testing;
    const allocator = std.heap.c_allocator;

    const original_payload = "Test payload for masking";
    var frame = try Frame.initMasked(allocator, true, .text, original_payload);
    defer frame.deinit(allocator);

    const masking_key = frame.masking_key.?;

    // Manually verify XOR: apply mask twice should give original
    const test_data = try allocator.dupe(u8, original_payload);
    defer allocator.free(test_data);

    // First XOR
    for (test_data, 0..) |*byte, i| {
        byte.* ^= masking_key[i % 4];
    }

    // Should now be masked (different from original)
    try testing.expect(!std.mem.eql(u8, original_payload, test_data));

    // Second XOR
    for (test_data, 0..) |*byte, i| {
        byte.* ^= masking_key[i % 4];
    }

    // Should be back to original
    try testing.expectEqualSlices(u8, original_payload, test_data);
}

test "Empty payload frame handling" {
    const testing = std.testing;
    const allocator = std.heap.c_allocator;

    var frame = try Frame.init(allocator, true, .text, "");
    defer frame.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), frame.payload.len);

    const bytes = try frame.toBytes(allocator);
    defer allocator.free(bytes);

    const parsed = try Frame.fromBytes(allocator, bytes);
    defer allocator.free(parsed.frame.payload);

    try testing.expectEqual(@as(usize, 0), parsed.frame.payload.len);
}

// ============================================================================
// RFC 6455 §5.7 external byte vectors + hostile-input vectors
//
// The worked examples in RFC 6455 §5.7 give exact wire bytes. These are the
// external anchor for the frame codec (per the repo golden rule): the inputs
// AND the expected outputs come from the spec, not from this implementation.
// The native-endian close-code bug and the fake UTF-8 validator both survived
// for months because every prior test was a self-consistent roundtrip.
// ============================================================================

test "RFC 6455 §5.7 — single-frame unmasked text \"Hello\" encodes to exact bytes" {
    const allocator = std.testing.allocator;
    var frame = try Frame.init(allocator, true, .text, "Hello");
    defer frame.deinit(allocator);

    const bytes = try frame.toBytes(allocator);
    defer allocator.free(bytes);

    // RFC 6455 §5.7: 0x81 0x05 0x48 0x65 0x6c 0x6c 0x6f
    const expected = [_]u8{ 0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f };
    try std.testing.expectEqualSlices(u8, &expected, bytes);
}

test "RFC 6455 §5.7 — decode single-frame unmasked \"Hello\"" {
    const allocator = std.testing.allocator;
    const wire = [_]u8{ 0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f };

    const r = try Frame.fromBytes(allocator, &wire);
    defer allocator.free(r.frame.payload);

    try std.testing.expect(r.frame.fin);
    try std.testing.expectEqual(Opcode.text, r.frame.opcode);
    try std.testing.expectEqualSlices(u8, "Hello", r.frame.payload);
    try std.testing.expectEqual(@as(usize, wire.len), r.bytes_consumed);
}

test "RFC 6455 §5.7 — single-frame masked text \"Hello\" encodes to exact bytes" {
    const allocator = std.testing.allocator;
    var frame = try Frame.init(allocator, true, .text, "Hello");
    defer frame.deinit(allocator);
    // Fixed key from the RFC example (production keys are CSPRNG-random).
    frame.masking_key = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };

    const bytes = try frame.toBytes(allocator);
    defer allocator.free(bytes);

    // RFC 6455 §5.7 masked "Hello": 0x81 0x85 <key> 0x7f 0x9f 0x4d 0x51 0x58
    const expected = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    try std.testing.expectEqualSlices(u8, &expected, bytes);
}

test "RFC 6455 §5.7 — decode masked \"Hello\" unmasks to plaintext" {
    const allocator = std.testing.allocator;
    const wire = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 };

    const r = try Frame.fromBytes(allocator, &wire);
    defer allocator.free(r.frame.payload);

    try std.testing.expectEqual(Opcode.text, r.frame.opcode);
    try std.testing.expect(r.frame.masking_key != null);
    try std.testing.expectEqualSlices(u8, "Hello", r.frame.payload);
    try std.testing.expectEqual(@as(usize, wire.len), r.bytes_consumed);
}

test "RFC 6455 §5.7 — fragmented text \"Hel\"+\"lo\" decodes and reassembles" {
    const allocator = std.testing.allocator;
    var conn = Connection.init(allocator, true);
    defer conn.deinit();

    const wire1 = [_]u8{ 0x01, 0x03, 0x48, 0x65, 0x6c }; // fin=0, text,       "Hel"
    const wire2 = [_]u8{ 0x80, 0x02, 0x6c, 0x6f }; //       fin=1, continuation "lo"

    var f1 = try Frame.fromBytes(allocator, &wire1);
    defer allocator.free(f1.frame.payload);
    try std.testing.expect(!f1.frame.fin);
    try std.testing.expectEqual(Opcode.text, f1.frame.opcode);
    try conn.processFrame(&f1.frame);

    var f2 = try Frame.fromBytes(allocator, &wire2);
    defer allocator.free(f2.frame.payload);
    try std.testing.expect(f2.frame.fin);
    try std.testing.expectEqual(Opcode.continuation, f2.frame.opcode);
    try conn.processFrame(&f2.frame);

    const msg = try conn.getReassembledMessage();
    defer if (msg) |m| allocator.free(m.payload);
    try std.testing.expect(msg != null);
    try std.testing.expectEqualSlices(u8, "Hello", msg.?.payload);
}

test "RFC 6455 §5.7 — unmasked Ping/Pong \"Hello\" opcode bytes" {
    const allocator = std.testing.allocator;

    var ping = try Frame.init(allocator, true, .ping, "Hello");
    defer ping.deinit(allocator);
    const pb = try ping.toBytes(allocator);
    defer allocator.free(pb);
    try std.testing.expectEqual(@as(u8, 0x89), pb[0]); // FIN + ping
    try std.testing.expectEqual(@as(u8, 0x05), pb[1]);

    var pong = try Frame.init(allocator, true, .pong, "Hello");
    defer pong.deinit(allocator);
    const qb = try pong.toBytes(allocator);
    defer allocator.free(qb);
    try std.testing.expectEqual(@as(u8, 0x8a), qb[0]); // FIN + pong
    try std.testing.expectEqual(@as(u8, 0x05), qb[1]);
}

test "RFC 6455 §5.7 — 256-byte binary uses 16-bit extended length (0x7E)" {
    // Header of a 256-byte binary frame: 0x82 0x7E 0x01 0x00
    const wire = [_]u8{ 0x82, 0x7e, 0x01, 0x00 };
    const parsed = try FrameHeader.fromBytes(&wire);
    try std.testing.expectEqual(Opcode.binary, parsed.header.opcode);
    try std.testing.expectEqual(@as(u64, 256), parsed.header.payload_len);
    try std.testing.expectEqual(@as(usize, 4), parsed.header_len);
}

test "RFC 6455 §5.7 — 64 KiB binary uses 64-bit extended length (0x7F)" {
    // Header of a 65536-byte binary frame: 0x82 0x7F <8 bytes big-endian 0x10000>
    const wire = [_]u8{ 0x82, 0x7f, 0, 0, 0, 0, 0, 0, 0x01, 0x00 };
    const parsed = try FrameHeader.fromBytes(&wire);
    try std.testing.expectEqual(Opcode.binary, parsed.header.opcode);
    try std.testing.expectEqual(@as(u64, 65536), parsed.header.payload_len);
    try std.testing.expectEqual(@as(usize, 10), parsed.header_len);
}

test "close code 1000 is emitted big-endian on the wire (0x03 0xE8)" {
    const allocator = std.testing.allocator;
    var conn = Connection.init(allocator, true);
    defer conn.deinit();

    var frame = try conn.createCloseFrame(1000, "bye");
    defer frame.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0x03), frame.payload[0]);
    try std.testing.expectEqual(@as(u8, 0xe8), frame.payload[1]);
    try std.testing.expectEqualSlices(u8, "bye", frame.payload[2..]);
}

test "CloseFrame code 1000 round-trips big-endian" {
    const allocator = std.testing.allocator;
    const cf = CloseFrame{ .code = 1000, .reason = "bye" };

    const bytes = try cf.toBytes(allocator);
    defer allocator.free(bytes);
    try std.testing.expectEqual(@as(u8, 0x03), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xe8), bytes[1]);

    const parsed = try CloseFrame.parse(bytes);
    try std.testing.expectEqual(@as(u16, 1000), parsed.code);
    try std.testing.expectEqualSlices(u8, "bye", parsed.reason);
}

// ---- Hostile / malformed input vectors ------------------------------------

test "negative — reserved data opcode 0x3 rejected on the wire" {
    try std.testing.expectError(error.ReservedOpcode, FrameHeader.fromBytes(&[_]u8{ 0x83, 0x00 }));
}

test "negative — reserved control opcode 0xB rejected on the wire" {
    try std.testing.expectError(error.ReservedOpcode, FrameHeader.fromBytes(&[_]u8{ 0x8b, 0x00 }));
}

test "negative — truncated 16-bit extended length is IncompleteHeader" {
    try std.testing.expectError(error.IncompleteHeader, FrameHeader.fromBytes(&[_]u8{ 0x81, 0x7e, 0x01 }));
}

test "negative — oversized 64-bit length rejected before allocating" {
    // 0x7F extended length claiming ~2^63 bytes: must error, must not OOM,
    // must not overflow the header_len + payload_len bounds check.
    const wire = [_]u8{ 0x82, 0x7f, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    try std.testing.expectError(error.FrameTooLarge, Frame.fromBytes(std.testing.allocator, &wire));
}

test "negative — fragmented control frame rejected" {
    const allocator = std.testing.allocator;
    var conn = Connection.init(allocator, true);
    defer conn.deinit();

    var frame = try Frame.init(allocator, false, .ping, "x"); // fin=false control
    defer frame.deinit(allocator);
    try std.testing.expectError(error.FragmentedControlFrame, conn.processFrame(&frame));
}

test "negative — control frame with 126-byte payload rejected" {
    const allocator = std.testing.allocator;
    var conn = Connection.init(allocator, true);
    defer conn.deinit();

    const big = try allocator.alloc(u8, 126);
    defer allocator.free(big);
    @memset(big, 0x42);

    var frame = try Frame.init(allocator, true, .ping, big);
    defer frame.deinit(allocator);
    try std.testing.expectError(error.ControlFrameTooLarge, conn.processFrame(&frame));
}

test "negative — close reason with overlong/surrogate UTF-8 rejected" {
    // code 1000 (0x03 0xE8) followed by an overlong encoding of NUL (0xC0 0x80)
    try std.testing.expectError(error.InvalidUtf8, CloseFrame.parse(&[_]u8{ 0x03, 0xe8, 0xc0, 0x80 }));
    // code 1000 followed by a UTF-16 surrogate (U+D800: 0xED 0xA0 0x80)
    try std.testing.expectError(error.InvalidUtf8, CloseFrame.parse(&[_]u8{ 0x03, 0xe8, 0xed, 0xa0, 0x80 }));
}
