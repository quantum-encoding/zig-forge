//! Unix socket IPC protocol for the Cognitive Telemetry Kit.
//!
//! Replaces D-Bus with a cross-platform transport. Length-prefixed messages
//! over a Unix domain socket at /tmp/ctk.sock (configurable).
//!
//! Protocol: [1 byte: message type][4 bytes: payload length (big-endian u32)][payload]

const std = @import("std");

pub const DEFAULT_SOCKET_PATH = "/tmp/ctk.sock";

pub const MessageType = enum(u8) {
    event = 0, // observation → intelligence
    decision_request = 1, // observation → policy engine
    decision_response = 2, // policy engine → observation
    query = 3, // client → server (e.g. GetCurrentState)
    query_response = 4, // server → client
    subscribe = 5, // client subscribes to event stream
    heartbeat = 6, // keepalive
};

pub const Message = struct {
    msg_type: MessageType,
    payload: []const u8,

    /// Encode message into a caller-provided buffer.
    /// Returns the slice of buf that was written.
    pub fn encode(self: *const Message, buf: []u8) ?[]const u8 {
        const header_len = 5; // 1 type + 4 length
        const total = header_len + self.payload.len;
        if (total > buf.len) return null;

        buf[0] = @intFromEnum(self.msg_type);
        const len: u32 = @intCast(self.payload.len);
        buf[1] = @intCast((len >> 24) & 0xFF);
        buf[2] = @intCast((len >> 16) & 0xFF);
        buf[3] = @intCast((len >> 8) & 0xFF);
        buf[4] = @intCast(len & 0xFF);
        @memcpy(buf[header_len..][0..self.payload.len], self.payload);
        return buf[0..total];
    }

    /// Decode a message from a buffer. Payload points into the input buffer.
    pub fn decode(buf: []const u8) ?Message {
        if (buf.len < 5) return null;
        const msg_type: MessageType = @enumFromInt(buf[0]);
        const len: u32 = @as(u32, buf[1]) << 24 |
            @as(u32, buf[2]) << 16 |
            @as(u32, buf[3]) << 8 |
            @as(u32, buf[4]);
        if (buf.len < 5 + len) return null;
        return .{
            .msg_type = msg_type,
            .payload = buf[5..][0..len],
        };
    }

    /// Total wire size of this message.
    pub fn wireSize(self: *const Message) usize {
        return 5 + self.payload.len;
    }
};

/// Well-known query commands (sent as payload in query messages).
pub const Query = struct {
    pub const GET_CURRENT_STATE = "get_current_state";
    pub const GET_STATE_FOR_PID = "get_state_for_pid";
    pub const GET_RECENT_STATES = "get_recent_states";
    pub const GET_ALL_PIDS = "get_all_pids";
    pub const GET_STATS = "get_stats";
    pub const PING = "ping";
    pub const SHUTDOWN = "shutdown";
};

test "ipc: encode/decode roundtrip" {
    const msg = Message{
        .msg_type = .event,
        .payload = "{\"test\":true}",
    };
    var buf: [256]u8 = undefined;
    const encoded = msg.encode(&buf).?;
    try std.testing.expectEqual(@as(usize, 5 + 13), encoded.len);

    const decoded = Message.decode(encoded).?;
    try std.testing.expectEqual(MessageType.event, decoded.msg_type);
    try std.testing.expectEqualStrings("{\"test\":true}", decoded.payload);
}
