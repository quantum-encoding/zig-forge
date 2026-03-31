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
        var key: [4]u8 = undefined;
        // Use a simple deterministic seed for masking key
        // In production, use a proper cryptographic RNG
        // Zig 0.16 compatible - use clock_gettime instead of Instant
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        const seed: u64 = @bitCast(ts.sec *% 1_000_000_000 +% ts.nsec);
        var rng = std.Random.DefaultPrng.init(seed);
        const rand = rng.random();
        rand.bytes(&key);

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

        if (data.len < header_len + header.payload_len) {
            return error.IncompleteFrame;
        }

        const payload_start = header_len;
        const payload_end = header_len + @as(usize, header.payload_len);
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
            .bytes_consumed = header_len + @as(usize, header.payload_len),
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

        // Validate UTF-8
        if (!isValidUtf8(reason)) return error.InvalidUtf8;

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

        try payload.appendSlice(&std.mem.toBytes(code));
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

/// UTF-8 validation helper
fn isValidUtf8(data: []const u8) bool {
    var i: usize = 0;
    while (i < data.len) {
        const byte = data[i];

        if (byte < 0x80) {
            i += 1;
        } else if ((byte & 0xE0) == 0xC0) {
            if (i + 1 >= data.len) return false;
            i += 2;
        } else if ((byte & 0xF0) == 0xE0) {
            if (i + 2 >= data.len) return false;
            i += 3;
        } else if ((byte & 0xF8) == 0xF0) {
            if (i + 3 >= data.len) return false;
            i += 4;
        } else {
            return false;
        }
    }
    return true;
}

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

test "UTF-8 validation" {
    const testing = std.testing;

    // Valid UTF-8
    try testing.expect(isValidUtf8("Hello"));
    try testing.expect(isValidUtf8(""));

    // Invalid UTF-8
    try testing.expect(!isValidUtf8(&[_]u8{0xFF}));
    try testing.expect(!isValidUtf8(&[_]u8{0xC0})); // Incomplete sequence
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
