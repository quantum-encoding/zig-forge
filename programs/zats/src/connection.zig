//! NATS Client Connection
//!
//! Per-client connection state machine with growable recv buffer,
//! \r\n line extraction, and send queue with backpressure tracking.

const std = @import("std");
const protocol = @import("protocol.zig");
const posix = std.posix;

pub const ConnectionState = enum {
    connected, // TCP connected, INFO not yet sent
    info_sent, // INFO sent, waiting for CONNECT
    ready, // CONNECT received, fully operational
    closing, // Close initiated
};

pub const DEFAULT_MAX_PENDING: usize = 64 * 1024 * 1024; // 64 MB (matches NATS default)
pub const DEFAULT_RECV_BUFFER_SIZE: usize = 64 * 1024; // 64 KB initial
pub const MAX_RECV_BUFFER_SIZE: usize = 2 * 1024 * 1024; // 2 MB max growth

pub const QueuedMessage = struct {
    data: []u8,
};

pub const ClientConnection = struct {
    fd: posix.socket_t,
    id: u64,
    recv_buffer: []u8,
    recv_len: usize,
    send_queue: std.ArrayListUnmanaged(QueuedMessage),
    pending_bytes: usize,
    max_pending_bytes: usize,
    state: ConnectionState,
    verbose: bool,
    pedantic: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, fd: posix.socket_t, id: u64) !ClientConnection {
        const recv_buffer = try allocator.alloc(u8, DEFAULT_RECV_BUFFER_SIZE);
        return .{
            .fd = fd,
            .id = id,
            .recv_buffer = recv_buffer,
            .recv_len = 0,
            .send_queue = .empty,
            .pending_bytes = 0,
            .max_pending_bytes = DEFAULT_MAX_PENDING,
            .state = .connected,
            .verbose = false,
            .pedantic = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ClientConnection) void {
        // Free any queued messages
        for (self.send_queue.items) |msg| {
            self.allocator.free(msg.data);
        }
        self.send_queue.deinit(self.allocator);
        self.allocator.free(self.recv_buffer);
    }

    /// Append received bytes to the recv buffer, growing if needed.
    pub fn appendRecvData(self: *ClientConnection, data: []const u8) !void {
        if (self.recv_len + data.len > self.recv_buffer.len) {
            // Grow buffer
            const new_size = @min(
                MAX_RECV_BUFFER_SIZE,
                @max(self.recv_buffer.len * 2, self.recv_len + data.len),
            );
            if (new_size < self.recv_len + data.len) {
                return error.BufferFull;
            }
            self.recv_buffer = try self.allocator.realloc(self.recv_buffer, new_size);
        }
        @memcpy(self.recv_buffer[self.recv_len..][0..data.len], data);
        self.recv_len += data.len;
    }

    /// Try to parse the next command from the recv buffer.
    /// Returns null if no complete command is available.
    pub fn nextCommand(self: *ClientConnection) ?protocol.ParseResult {
        if (self.recv_len == 0) return null;

        const result = protocol.parse(self.recv_buffer[0..self.recv_len]) catch |err| {
            switch (err) {
                error.IncompleteLine, error.IncompletePayload => return null,
                else => {
                    // Invalid data — could log or mark connection for close
                    return null;
                },
            }
        };

        // Shift remaining data forward
        const remaining = self.recv_len - result.bytes_consumed;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.recv_buffer[0..remaining], self.recv_buffer[result.bytes_consumed..self.recv_len]);
        }
        self.recv_len = remaining;

        return result;
    }

    /// Queue a message for sending. Tracks pending bytes for backpressure.
    pub fn queueSend(self: *ClientConnection, data: []const u8) !void {
        const owned = try self.allocator.dupe(u8, data);
        try self.send_queue.append(self.allocator, .{ .data = owned });
        self.pending_bytes += owned.len;
    }

    /// Queue a pre-formatted NATS MSG for sending.
    pub fn queueMsg(self: *ClientConnection, subject: []const u8, sid: []const u8, reply_to: ?[]const u8, payload: []const u8) !void {
        // Use a stack buffer for encoding
        var encode_buf: [65536]u8 = undefined;
        const encoded = protocol.encodeMsg(&encode_buf, subject, sid, reply_to, payload);
        if (encoded.len == 0) return error.EncodeFailed;

        const owned = try self.allocator.dupe(u8, encoded);
        try self.send_queue.append(self.allocator, .{ .data = owned });
        self.pending_bytes += owned.len;
    }

    /// Queue a pre-formatted NATS HMSG for sending (message with headers).
    pub fn queueHmsg(self: *ClientConnection, subject: []const u8, sid: []const u8, reply_to: ?[]const u8, headers: []const u8, payload: []const u8) !void {
        var encode_buf: [65536]u8 = undefined;
        const encoded = protocol.encodeHmsg(&encode_buf, subject, sid, reply_to, headers, payload);
        if (encoded.len == 0) return error.EncodeFailed;

        const owned = try self.allocator.dupe(u8, encoded);
        try self.send_queue.append(self.allocator, .{ .data = owned });
        self.pending_bytes += owned.len;
    }

    /// Check if this connection is a slow consumer (pending exceeds limit).
    pub fn isSlowConsumer(self: *const ClientConnection) bool {
        return self.pending_bytes > self.max_pending_bytes;
    }

    /// Flush the send queue to the socket. Returns number of messages sent.
    pub fn flushSendQueue(self: *ClientConnection) !usize {
        var sent: usize = 0;
        while (self.send_queue.items.len > 0) {
            const msg = self.send_queue.items[0];
            sendAll(self.fd, msg.data) catch {
                return sent;
            };
            self.pending_bytes -= msg.data.len;
            self.allocator.free(msg.data);
            _ = self.send_queue.orderedRemove(0);
            sent += 1;
        }
        return sent;
    }

    /// Send data directly on the socket (bypasses queue — used for urgent messages like PING/PONG).
    pub fn sendDirect(self: *ClientConnection, data: []const u8) !void {
        try sendAll(self.fd, data);
    }
};

fn sendAll(fd: posix.socket_t, data: []const u8) !void {
    var total: usize = 0;
    while (total < data.len) {
        const result = std.c.send(fd, @ptrCast(data[total..].ptr), data[total..].len, 0);
        if (result < 0) {
            return error.SendFailed;
        }
        if (result == 0) return error.SendFailed;
        total += @intCast(result);
    }
}

// --- Tests ---

test "connection init and deinit" {
    const allocator = std.testing.allocator;
    var conn = try ClientConnection.init(allocator, 0, 1);
    defer conn.deinit();

    try std.testing.expectEqual(ConnectionState.connected, conn.state);
    try std.testing.expectEqual(@as(usize, 0), conn.recv_len);
    try std.testing.expectEqual(@as(usize, 0), conn.pending_bytes);
}

test "connection append and parse" {
    const allocator = std.testing.allocator;
    var conn = try ClientConnection.init(allocator, 0, 1);
    defer conn.deinit();

    try conn.appendRecvData("PING\r\nPONG\r\n");

    // First command
    const cmd1 = conn.nextCommand().?;
    try std.testing.expect(cmd1.command == .ping);

    // Second command
    const cmd2 = conn.nextCommand().?;
    try std.testing.expect(cmd2.command == .pong);

    // No more
    try std.testing.expect(conn.nextCommand() == null);
}

test "connection incomplete data" {
    const allocator = std.testing.allocator;
    var conn = try ClientConnection.init(allocator, 0, 1);
    defer conn.deinit();

    try conn.appendRecvData("PIN");
    try std.testing.expect(conn.nextCommand() == null);

    try conn.appendRecvData("G\r\n");
    const cmd = conn.nextCommand().?;
    try std.testing.expect(cmd.command == .ping);
}

test "connection queue and backpressure" {
    const allocator = std.testing.allocator;
    var conn = try ClientConnection.init(allocator, 0, 1);
    defer conn.deinit();

    conn.max_pending_bytes = 100;

    try conn.queueSend("Hello, World!\r\n");
    try std.testing.expectEqual(@as(usize, 15), conn.pending_bytes);
    try std.testing.expect(!conn.isSlowConsumer());

    // Fill past limit
    const big = try allocator.alloc(u8, 200);
    defer allocator.free(big);
    @memset(big, 'X');

    try conn.queueSend(big);
    try std.testing.expect(conn.isSlowConsumer());
}

test "connection PUB payload parsing" {
    const allocator = std.testing.allocator;
    var conn = try ClientConnection.init(allocator, 0, 1);
    defer conn.deinit();

    try conn.appendRecvData("PUB foo 5\r\nHello\r\n");

    const cmd = conn.nextCommand().?;
    try std.testing.expect(cmd.command == .pub_msg);
    try std.testing.expectEqualStrings("foo", cmd.command.pub_msg.subject);
    try std.testing.expectEqualStrings("Hello", cmd.command.pub_msg.payload);
}
