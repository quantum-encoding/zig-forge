//! NATS Client Library
//!
//! Provides both callback-based and channel-based subscription models.
//! Handles INFO/CONNECT handshake, PING/PONG keepalive, and
//! request/reply with inbox pattern.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const posix = std.posix;

const is_linux = builtin.os.tag == .linux;

pub const Message = struct {
    subject: []const u8,
    reply_to: ?[]const u8,
    payload: []const u8,
    sid: u64,
    allocator: std.mem.Allocator,

    // All fields are owned copies
    pub fn deinit(self: *Message) void {
        self.allocator.free(self.subject);
        if (self.reply_to) |r| self.allocator.free(r);
        self.allocator.free(self.payload);
    }
};

pub const SubscriptionCallback = *const fn (msg: *Message) void;

pub const SubscriptionHandler = union(enum) {
    callback: SubscriptionCallback,
    channel: *ChannelSubscription,
};

pub const ChannelSubscription = struct {
    messages: std.ArrayListUnmanaged(Message),
    max_pending: usize,
    allocator: std.mem.Allocator,
    sid: u64,
    subject: []const u8, // owned

    pub fn init(allocator: std.mem.Allocator, sid: u64, subject: []const u8, max_pending: usize) !*ChannelSubscription {
        const self = try allocator.create(ChannelSubscription);
        self.* = .{
            .messages = .empty,
            .max_pending = max_pending,
            .allocator = allocator,
            .sid = sid,
            .subject = try allocator.dupe(u8, subject),
        };
        return self;
    }

    pub fn deinit(self: *ChannelSubscription) void {
        for (self.messages.items) |*msg| {
            msg.deinit();
        }
        self.messages.deinit(self.allocator);
        self.allocator.free(self.subject);
        self.allocator.destroy(self);
    }

    /// Get next message (non-blocking). Returns null if none available.
    pub fn next(self: *ChannelSubscription) ?Message {
        if (self.messages.items.len == 0) return null;
        return self.messages.orderedRemove(0);
    }

    /// Check if messages are available.
    pub fn pending(self: *const ChannelSubscription) usize {
        return self.messages.items.len;
    }

    fn push(self: *ChannelSubscription, msg: Message) void {
        if (self.messages.items.len >= self.max_pending) {
            // Drop oldest message
            var old = self.messages.orderedRemove(0);
            old.deinit();
        }
        self.messages.append(self.allocator, msg) catch {};
    }
};

pub const ClientConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 4222,
    name: ?[]const u8 = null,
    verbose: bool = false,
    pedantic: bool = false,
    auth_token: ?[]const u8 = null,
    user: ?[]const u8 = null,
    pass: ?[]const u8 = null,
};

pub const NatsClient = struct {
    fd: posix.socket_t,
    allocator: std.mem.Allocator,
    recv_buffer: []u8,
    recv_len: usize,
    next_sid: u64,
    subscriptions: std.AutoHashMapUnmanaged(u64, SubscriptionHandler),
    config: ClientConfig,
    connected: bool,
    server_info: ?[]u8, // owned copy of server INFO json

    pub fn init(allocator: std.mem.Allocator, config: ClientConfig) !NatsClient {
        return .{
            .fd = 0,
            .allocator = allocator,
            .recv_buffer = try allocator.alloc(u8, 64 * 1024),
            .recv_len = 0,
            .next_sid = 1,
            .subscriptions = .{},
            .config = config,
            .connected = false,
            .server_info = null,
        };
    }

    pub fn deinit(self: *NatsClient) void {
        // Free channel subscriptions
        var it = self.subscriptions.iterator();
        while (it.next()) |entry| {
            switch (entry.value_ptr.*) {
                .channel => |ch| ch.deinit(),
                .callback => {},
            }
        }
        self.subscriptions.deinit(self.allocator);
        self.allocator.free(self.recv_buffer);
        if (self.server_info) |info| self.allocator.free(info);
        if (self.fd != 0) {
            _ = std.c.close(self.fd);
        }
    }

    /// Connect to the NATS server.
    pub fn connect(self: *NatsClient) !void {
        // Create socket
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketCreationFailed;
        self.fd = @intCast(fd);

        // Parse host IP
        const ip = parseIp(self.config.host) orelse return error.InvalidAddress;

        // Connect
        const addr = std.c.sockaddr.in{
            .family = std.c.AF.INET,
            .port = std.mem.nativeToBig(u16, self.config.port),
            .addr = std.mem.nativeToBig(u32, ip),
        };

        if (std.c.connect(self.fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) < 0) {
            return error.ConnectionFailed;
        }

        // Read INFO from server
        try self.readAndProcessUntilReady();

        // Send CONNECT
        var buf: [512]u8 = undefined;
        var pos: usize = 0;

        const header = std.fmt.bufPrint(buf[pos..], "CONNECT {{\"verbose\":{s},\"pedantic\":{s},\"lang\":\"zig\",\"version\":\"1.0.0\"", .{
            if (self.config.verbose) "true" else "false",
            if (self.config.pedantic) "true" else "false",
        }) catch return error.BufferTooSmall;
        pos += header.len;

        if (self.config.name) |name| {
            const n = std.fmt.bufPrint(buf[pos..], ",\"name\":\"{s}\"", .{name}) catch return error.BufferTooSmall;
            pos += n.len;
        }
        if (self.config.auth_token) |token| {
            const n = std.fmt.bufPrint(buf[pos..], ",\"auth_token\":\"{s}\"", .{token}) catch return error.BufferTooSmall;
            pos += n.len;
        }
        if (self.config.user) |user| {
            const n = std.fmt.bufPrint(buf[pos..], ",\"user\":\"{s}\"", .{user}) catch return error.BufferTooSmall;
            pos += n.len;
        }
        if (self.config.pass) |pass| {
            const n = std.fmt.bufPrint(buf[pos..], ",\"pass\":\"{s}\"", .{pass}) catch return error.BufferTooSmall;
            pos += n.len;
        }

        @memcpy(buf[pos..][0..4], "}\r\n\x00");
        pos += 3;

        try self.sendAll(buf[0..pos]);
        self.connected = true;
    }

    /// Publish a message to a subject.
    pub fn publish(self: *NatsClient, subject: []const u8, payload: []const u8) !void {
        var buf: [65536]u8 = undefined;
        const encoded = protocol.encodePub(&buf, subject, null, payload);
        if (encoded.len == 0) return error.EncodeFailed;
        try self.sendAll(encoded);
    }

    /// Publish with a reply-to subject.
    pub fn publishWithReply(self: *NatsClient, subject: []const u8, reply_to: []const u8, payload: []const u8) !void {
        var buf: [65536]u8 = undefined;
        const encoded = protocol.encodePub(&buf, subject, reply_to, payload);
        if (encoded.len == 0) return error.EncodeFailed;
        try self.sendAll(encoded);
    }

    /// Subscribe with a callback handler. Returns the subscription ID.
    pub fn subscribe(self: *NatsClient, subject: []const u8, callback: SubscriptionCallback) !u64 {
        const sid = self.next_sid;
        self.next_sid += 1;

        // Send SUB command
        var buf: [256]u8 = undefined;
        var sid_buf: [20]u8 = undefined;
        const sid_str = std.fmt.bufPrint(&sid_buf, "{d}", .{sid}) catch return error.BufferTooSmall;
        const encoded = protocol.encodeSub(&buf, subject, null, sid_str);
        try self.sendAll(encoded);

        try self.subscriptions.put(self.allocator, sid, .{ .callback = callback });
        return sid;
    }

    /// Subscribe with a queue group and callback. Returns the subscription ID.
    pub fn subscribeQueue(self: *NatsClient, subject: []const u8, queue: []const u8, callback: SubscriptionCallback) !u64 {
        const sid = self.next_sid;
        self.next_sid += 1;

        var buf: [256]u8 = undefined;
        var sid_buf: [20]u8 = undefined;
        const sid_str = std.fmt.bufPrint(&sid_buf, "{d}", .{sid}) catch return error.BufferTooSmall;
        const encoded = protocol.encodeSub(&buf, subject, queue, sid_str);
        try self.sendAll(encoded);

        try self.subscriptions.put(self.allocator, sid, .{ .callback = callback });
        return sid;
    }

    /// Subscribe with a channel (bounded queue). Returns the ChannelSubscription.
    pub fn subscribeChannel(self: *NatsClient, subject: []const u8, max_pending: usize) !*ChannelSubscription {
        const sid = self.next_sid;
        self.next_sid += 1;

        var buf: [256]u8 = undefined;
        var sid_buf: [20]u8 = undefined;
        const sid_str = std.fmt.bufPrint(&sid_buf, "{d}", .{sid}) catch return error.BufferTooSmall;
        const encoded = protocol.encodeSub(&buf, subject, null, sid_str);
        try self.sendAll(encoded);

        const ch = try ChannelSubscription.init(self.allocator, sid, subject, max_pending);
        try self.subscriptions.put(self.allocator, sid, .{ .channel = ch });
        return ch;
    }

    /// Unsubscribe from a subscription.
    pub fn unsubscribe(self: *NatsClient, sid: u64) !void {
        var buf: [64]u8 = undefined;
        var sid_buf: [20]u8 = undefined;
        const sid_str = std.fmt.bufPrint(&sid_buf, "{d}", .{sid}) catch return error.BufferTooSmall;
        const encoded = protocol.encodeUnsub(&buf, sid_str, null);
        try self.sendAll(encoded);

        if (self.subscriptions.fetchRemove(sid)) |entry| {
            switch (entry.value) {
                .channel => |ch| ch.deinit(),
                .callback => {},
            }
        }
    }

    /// Request/reply pattern. Publishes to subject with auto-generated inbox,
    /// waits for a single response with timeout.
    pub fn request(self: *NatsClient, subject: []const u8, payload: []const u8, timeout_ms: u32) !Message {
        // Generate unique inbox subject
        var inbox_buf: [64]u8 = undefined;
        const inbox = std.fmt.bufPrint(&inbox_buf, "_INBOX.{d}.{d}", .{ @as(u64, @intCast(std.c.time(null))), self.next_sid }) catch return error.BufferTooSmall;

        // Subscribe to inbox via channel
        const ch = try self.subscribeChannel(inbox, 1);
        defer {
            self.unsubscribe(ch.sid) catch {};
        }

        // Publish with reply-to
        try self.publishWithReply(subject, inbox, payload);

        // Wait for response with timeout
        const start = std.c.time(null);
        const timeout_sec: i64 = @intCast(@as(u64, timeout_ms) / 1000);
        const deadline = start + @max(timeout_sec, 1);

        while (std.c.time(null) < deadline) {
            try self.poll();
            if (ch.next()) |msg| {
                return msg;
            }
        }

        return error.Timeout;
    }

    /// Process incoming data — dispatch to callbacks and fill channels.
    pub fn poll(self: *NatsClient) !void {
        var buf: [8192]u8 = undefined;

        // Set non-blocking for poll
        setNonblocking(self.fd);
        defer setBlocking(self.fd);

        const result = std.c.recv(self.fd, @ptrCast(&buf), buf.len, 0);
        if (result <= 0) return; // No data or error

        const n: usize = @intCast(result);
        try self.appendRecvData(buf[0..n]);
        try self.processRecvBuffer();
    }

    fn readAndProcessUntilReady(self: *NatsClient) !void {
        // Read until we get INFO
        var buf: [4096]u8 = undefined;
        const result = std.c.recv(self.fd, @ptrCast(&buf), buf.len, 0);
        if (result <= 0) return error.ConnectionClosed;

        const n: usize = @intCast(result);
        try self.appendRecvData(buf[0..n]);

        // Process — expecting INFO
        try self.processRecvBuffer();
    }

    fn appendRecvData(self: *NatsClient, data: []const u8) !void {
        if (self.recv_len + data.len > self.recv_buffer.len) {
            const new_size = @max(self.recv_buffer.len * 2, self.recv_len + data.len);
            self.recv_buffer = try self.allocator.realloc(self.recv_buffer, new_size);
        }
        @memcpy(self.recv_buffer[self.recv_len..][0..data.len], data);
        self.recv_len += data.len;
    }

    fn processRecvBuffer(self: *NatsClient) !void {
        while (self.recv_len > 0) {
            const result = protocol.parse(self.recv_buffer[0..self.recv_len]) catch |err| {
                switch (err) {
                    error.IncompleteLine, error.IncompletePayload => return,
                    else => return,
                }
            };

            switch (result.command) {
                .info => |info| {
                    if (self.server_info) |old| self.allocator.free(old);
                    self.server_info = try self.allocator.dupe(u8, info.json);
                },
                .ping => {
                    try self.sendAll("PONG\r\n");
                },
                .msg => |msg_data| {
                    const sid = std.fmt.parseInt(u64, msg_data.sid, 10) catch {
                        self.consumeBytes(result.bytes_consumed);
                        continue;
                    };

                    if (self.subscriptions.getPtr(sid)) |handler| {
                        var msg = Message{
                            .subject = try self.allocator.dupe(u8, msg_data.subject),
                            .reply_to = if (msg_data.reply_to) |r| try self.allocator.dupe(u8, r) else null,
                            .payload = try self.allocator.dupe(u8, msg_data.payload),
                            .sid = sid,
                            .allocator = self.allocator,
                        };

                        switch (handler.*) {
                            .callback => |cb| {
                                cb(&msg);
                            },
                            .channel => |ch| {
                                ch.push(msg);
                            },
                        }
                    }
                },
                .ok => {},
                .err => {},
                .pong => {},
                else => {},
            }

            self.consumeBytes(result.bytes_consumed);
        }
    }

    fn consumeBytes(self: *NatsClient, n: usize) void {
        const remaining = self.recv_len - n;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.recv_buffer[0..remaining], self.recv_buffer[n..self.recv_len]);
        }
        self.recv_len = remaining;
    }

    fn sendAll(self: *NatsClient, data: []const u8) !void {
        var total: usize = 0;
        while (total < data.len) {
            const result = std.c.send(self.fd, @ptrCast(data[total..].ptr), data[total..].len, 0);
            if (result < 0) return error.SendFailed;
            total += @intCast(result);
        }
    }

    /// Close the connection.
    pub fn close(self: *NatsClient) void {
        if (self.fd != 0) {
            _ = std.c.close(self.fd);
            self.fd = 0;
        }
        self.connected = false;
    }
};

fn parseIp(ip_str: []const u8) ?u32 {
    var parts: [4]u8 = undefined;
    var part_idx: usize = 0;
    var current: u32 = 0;

    for (ip_str) |c| {
        if (c == '.') {
            if (part_idx >= 3) return null;
            if (current > 255) return null;
            parts[part_idx] = @intCast(current);
            part_idx += 1;
            current = 0;
        } else if (c >= '0' and c <= '9') {
            current = current * 10 + (c - '0');
        } else {
            return null;
        }
    }

    if (part_idx != 3 or current > 255) return null;
    parts[3] = @intCast(current);

    return @as(u32, parts[0]) << 24 | @as(u32, parts[1]) << 16 | @as(u32, parts[2]) << 8 | @as(u32, parts[3]);
}

fn setNonblocking(fd: posix.socket_t) void {
    if (is_linux) {
        _ = std.os.linux.fcntl(@intCast(fd), @intCast(std.c.F.SETFL), @as(c_uint, 0o4000));
    } else {
        _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_uint, 0x0004));
    }
}

fn setBlocking(fd: posix.socket_t) void {
    if (is_linux) {
        _ = std.os.linux.fcntl(@intCast(fd), @intCast(std.c.F.SETFL), @as(c_uint, 0));
    } else {
        _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_uint, 0));
    }
}

// --- Tests ---

test "parse IP address" {
    const ip = parseIp("127.0.0.1").?;
    try std.testing.expectEqual(@as(u32, 0x7f000001), ip);

    const ip2 = parseIp("192.168.1.1").?;
    try std.testing.expectEqual(@as(u32, 0xc0a80101), ip2);

    try std.testing.expect(parseIp("invalid") == null);
    try std.testing.expect(parseIp("256.0.0.1") == null);
    try std.testing.expect(parseIp("1.2.3") == null);
}

test "client init and deinit" {
    const allocator = std.testing.allocator;
    var client = try NatsClient.init(allocator, .{});
    defer client.deinit();

    try std.testing.expect(!client.connected);
    try std.testing.expectEqual(@as(u64, 1), client.next_sid);
}

test "channel subscription" {
    const allocator = std.testing.allocator;
    var ch = try ChannelSubscription.init(allocator, 1, "test.subject", 3);
    defer ch.deinit();

    try std.testing.expectEqual(@as(usize, 0), ch.pending());
    try std.testing.expect(ch.next() == null);

    // Push messages
    ch.push(.{
        .subject = try allocator.dupe(u8, "test.subject"),
        .reply_to = null,
        .payload = try allocator.dupe(u8, "msg1"),
        .sid = 1,
        .allocator = allocator,
    });

    try std.testing.expectEqual(@as(usize, 1), ch.pending());

    var msg = ch.next().?;
    defer msg.deinit();
    try std.testing.expectEqualStrings("msg1", msg.payload);
    try std.testing.expectEqual(@as(usize, 0), ch.pending());
}

test "channel subscription max pending" {
    const allocator = std.testing.allocator;
    var ch = try ChannelSubscription.init(allocator, 1, "test", 2);
    defer ch.deinit();

    // Push 3 messages — oldest should be dropped
    ch.push(.{
        .subject = try allocator.dupe(u8, "t"),
        .reply_to = null,
        .payload = try allocator.dupe(u8, "first"),
        .sid = 1,
        .allocator = allocator,
    });
    ch.push(.{
        .subject = try allocator.dupe(u8, "t"),
        .reply_to = null,
        .payload = try allocator.dupe(u8, "second"),
        .sid = 1,
        .allocator = allocator,
    });
    ch.push(.{
        .subject = try allocator.dupe(u8, "t"),
        .reply_to = null,
        .payload = try allocator.dupe(u8, "third"),
        .sid = 1,
        .allocator = allocator,
    });

    try std.testing.expectEqual(@as(usize, 2), ch.pending());

    var msg1 = ch.next().?;
    defer msg1.deinit();
    try std.testing.expectEqualStrings("second", msg1.payload); // "first" was dropped

    var msg2 = ch.next().?;
    defer msg2.deinit();
    try std.testing.expectEqualStrings("third", msg2.payload);
}
