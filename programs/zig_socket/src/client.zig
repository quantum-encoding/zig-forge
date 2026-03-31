// WebSocket Client - Connects to WSS/WS endpoints
// Uses Zig's std.Io for TLS connections and zig_websocket for framing

const std = @import("std");
const websocket = @import("websocket.zig");
const Frame = websocket.Frame;
const Opcode = websocket.Opcode;
const Handshake = websocket.Handshake;
const ConnectionState = websocket.ConnectionState;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = std.Io.net;
const http = std.http;
const crypto = std.crypto;
const tls = crypto.tls;

/// WebSocket client for connecting to wss:// or ws:// endpoints
pub const Client = struct {
    allocator: Allocator,
    io_threaded: *Io.Threaded,
    http_client: http.Client,
    connection: ?*http.Client.Connection = null,
    state: ConnectionState = .connecting,
    host: []const u8 = "",
    path: []const u8 = "",
    sec_websocket_key: [24]u8 = undefined,

    pub fn init(allocator: Allocator) !Client {
        const io_threaded = try allocator.create(Io.Threaded);
        io_threaded.* = Io.Threaded.init(allocator, .{
            .environ = .{ .block = std.mem.span(std.c.environ) },
        });

        return .{
            .allocator = allocator,
            .io_threaded = io_threaded,
            .http_client = http.Client{
                .allocator = allocator,
                .io = io_threaded.io(),
            },
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.connection) |conn| {
            conn.destroy(self.io_threaded.io());
        }
        self.http_client.deinit();
        self.io_threaded.deinit();
        self.allocator.destroy(self.io_threaded);
        if (self.host.len > 0) self.allocator.free(self.host);
        if (self.path.len > 0) self.allocator.free(self.path);
    }

    /// Connect to a WebSocket URL and perform upgrade handshake
    pub fn connect(self: *Client, url: []const u8) !void {
        // Parse URL
        const parsed = try parseWsUrl(url);
        self.host = try self.allocator.dupe(u8, parsed.host);
        self.path = try self.allocator.dupe(u8, parsed.path);

        // Generate Sec-WebSocket-Key (16 random bytes, base64 encoded)
        var random_bytes: [16]u8 = undefined;
        // Use timestamp as seed for PRNG
        var seed: u64 = 0x9e3779b97f4a7c15;
        if (std.time.Instant.now()) |instant| {
            seed ^= @bitCast(instant.timestamp.sec);
        } else |_| {}
        var prng = std.Random.DefaultPrng.init(seed);
        prng.fill(&random_bytes);
        _ = std.base64.standard.Encoder.encode(&self.sec_websocket_key, &random_bytes);

        // Convert wss:// to https:// for the HTTP upgrade request
        var https_url_buf: [2048]u8 = undefined;
        const https_url = blk: {
            if (std.mem.startsWith(u8, url, "wss://")) {
                const rest = url[6..];
                const len = std.fmt.bufPrint(&https_url_buf, "https://{s}", .{rest}) catch return error.UrlTooLong;
                break :blk https_url_buf[0..len.len];
            } else if (std.mem.startsWith(u8, url, "ws://")) {
                const rest = url[5..];
                const len = std.fmt.bufPrint(&https_url_buf, "http://{s}", .{rest}) catch return error.UrlTooLong;
                break :blk https_url_buf[0..len.len];
            } else {
                break :blk url;
            }
        };

        const uri = try std.Uri.parse(https_url);

        // Create HTTP request with WebSocket upgrade headers
        var req = self.http_client.request(.GET, uri, .{
            .extra_headers = &[_]http.Header{
                .{ .name = "Upgrade", .value = "websocket" },
                .{ .name = "Connection", .value = "Upgrade" },
                .{ .name = "Sec-WebSocket-Key", .value = &self.sec_websocket_key },
                .{ .name = "Sec-WebSocket-Version", .value = "13" },
            },
        }) catch |err| {
            std.debug.print("WebSocket: Failed to create request: {any}\n", .{err});
            return err;
        };
        errdefer req.deinit();

        // Send the upgrade request headers (GET has no body)
        // For WebSocket upgrade, we just need to flush the headers
        if (req.connection) |conn| {
            conn.flush() catch |err| {
                std.debug.print("WebSocket: Failed to flush: {any}\n", .{err});
                return err;
            };
        }

        // Receive response head
        const response = req.receiveHead(&.{}) catch |err| {
            std.debug.print("WebSocket: Failed to receive response: {any}\n", .{err});
            return err;
        };

        // Check for 101 Switching Protocols
        if (response.head.status != .switching_protocols) {
            std.debug.print("WebSocket: Server returned {any} instead of 101\n", .{response.head.status});
            return error.UpgradeFailed;
        }

        // Keep the connection alive for WebSocket communication
        self.connection = req.connection;
        req.connection = null; // Prevent request from closing the connection

        self.state = .open;
        std.debug.print("WebSocket: Connected to {s}\n", .{self.host});
    }

    /// Send a text message
    pub fn sendText(self: *Client, message: []const u8) !void {
        try self.sendFrame(.text, message);
    }

    /// Send a binary message
    pub fn sendBinary(self: *Client, data: []const u8) !void {
        try self.sendFrame(.binary, data);
    }

    /// Send a WebSocket frame
    fn sendFrame(self: *Client, opcode: Opcode, payload: []const u8) !void {
        if (self.state != .open) return error.ConnectionNotOpen;
        const conn = self.connection orelse return error.ConnectionNotOpen;

        // Create masked frame (client must mask)
        var frame = try Frame.initMasked(self.allocator, true, opcode, payload);
        defer frame.deinit(self.allocator);

        const frame_bytes = try frame.toBytes(self.allocator);
        defer self.allocator.free(frame_bytes);

        // Write to connection
        const writer = conn.writer();
        writer.writeAll(frame_bytes) catch |err| {
            std.debug.print("WebSocket: Write error: {any}\n", .{err});
            return error.WriteFailed;
        };
        conn.flush() catch {};
    }

    /// Receive a message (blocks until message received)
    pub fn receive(self: *Client) !?Message {
        if (self.state != .open) return null;
        const conn = self.connection orelse return null;

        var reader = conn.reader();

        // Read frame header (at least 2 bytes)
        var header_buf: [14]u8 = undefined; // Max header size
        reader.readSliceAll(header_buf[0..2]) catch |err| {
            if (err == error.EndOfStream) {
                self.state = .closed;
                return null;
            }
            return err;
        };

        // Parse minimal header
        const byte1 = header_buf[0];
        const byte2 = header_buf[1];

        const fin = (byte1 & 0x80) != 0;
        const opcode_val = byte1 & 0x0F;
        const opcode: Opcode = switch (opcode_val) {
            0x0 => .continuation,
            0x1 => .text,
            0x2 => .binary,
            0x8 => .close,
            0x9 => .ping,
            0xA => .pong,
            else => return error.InvalidOpcode,
        };

        const masked = (byte2 & 0x80) != 0;
        var payload_len: u64 = byte2 & 0x7F;

        // Extended payload length
        if (payload_len == 126) {
            reader.readSliceAll(header_buf[2..4]) catch return error.ReadFailed;
            payload_len = std.mem.readInt(u16, header_buf[2..4], .big);
        } else if (payload_len == 127) {
            reader.readSliceAll(header_buf[2..10]) catch return error.ReadFailed;
            payload_len = std.mem.readInt(u64, header_buf[2..10], .big);
        }

        // Masking key (if present)
        var masking_key: ?[4]u8 = null;
        if (masked) {
            var key: [4]u8 = undefined;
            reader.readSliceAll(&key) catch return error.ReadFailed;
            masking_key = key;
        }

        // Read payload
        const payload = try self.allocator.alloc(u8, @intCast(payload_len));
        errdefer self.allocator.free(payload);

        if (payload_len > 0) {
            reader.readSliceAll(payload) catch return error.ReadFailed;

            // Unmask if needed
            if (masking_key) |key| {
                for (payload, 0..) |*byte, i| {
                    byte.* ^= key[i % 4];
                }
            }
        }

        // Handle control frames
        if (opcode == .close) {
            self.state = .closing;
            // Send close response
            self.sendFrame(.close, &[_]u8{ 0x03, 0xe8 }) catch {}; // 1000 = normal
            self.state = .closed;
        } else if (opcode == .ping) {
            // Respond with pong
            self.sendFrame(.pong, payload) catch {};
            self.allocator.free(payload);
            return self.receive(); // Get next message
        } else if (opcode == .pong) {
            self.allocator.free(payload);
            return self.receive(); // Ignore pong, get next message
        }

        return Message{
            .opcode = opcode,
            .payload = payload,
            .fin = fin,
            .allocator = self.allocator,
        };
    }

    /// Close the connection gracefully
    pub fn close(self: *Client) void {
        if (self.state == .closed) return;

        // Send close frame
        self.sendFrame(.close, &[_]u8{ 0x03, 0xe8 }) catch {}; // 1000 = normal closure

        if (self.connection) |conn| {
            conn.destroy(self.io_threaded.io());
            self.connection = null;
        }

        self.state = .closed;
    }

    pub fn isOpen(self: *const Client) bool {
        return self.state == .open;
    }
};

/// Received WebSocket message
pub const Message = struct {
    opcode: Opcode,
    payload: []u8,
    fin: bool,
    allocator: Allocator,

    pub fn deinit(self: *Message) void {
        self.allocator.free(self.payload);
    }

    pub fn isText(self: *const Message) bool {
        return self.opcode == .text;
    }

    pub fn isBinary(self: *const Message) bool {
        return self.opcode == .binary;
    }

    pub fn isClose(self: *const Message) bool {
        return self.opcode == .close;
    }

    /// Get payload as string (for text messages)
    pub fn text(self: *const Message) []const u8 {
        return self.payload;
    }
};

/// Parsed WebSocket URL
const ParsedWsUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
    use_tls: bool,
};

fn parseWsUrl(url: []const u8) !ParsedWsUrl {
    var use_tls = true;
    var rest = url;

    if (std.mem.startsWith(u8, url, "wss://")) {
        rest = url[6..];
        use_tls = true;
    } else if (std.mem.startsWith(u8, url, "ws://")) {
        rest = url[5..];
        use_tls = false;
    } else {
        return error.InvalidProtocol;
    }

    // Find path
    var host_end: usize = rest.len;
    for (rest, 0..) |c, i| {
        if (c == '/') {
            host_end = i;
            break;
        }
    }

    const host_part = rest[0..host_end];
    var host = host_part;
    var port: u16 = if (use_tls) 443 else 80;

    // Check for port
    if (std.mem.indexOf(u8, host_part, ":")) |colon| {
        host = host_part[0..colon];
        port = std.fmt.parseInt(u16, host_part[colon + 1 ..], 10) catch return error.InvalidPort;
    }

    const path = if (host_end < rest.len) rest[host_end..] else "/";

    return ParsedWsUrl{
        .host = host,
        .port = port,
        .path = path,
        .use_tls = use_tls,
    };
}

// Tests
test "URL parsing wss" {
    const parsed = try parseWsUrl("wss://example.com/path?key=value");
    try std.testing.expectEqualStrings("example.com", parsed.host);
    try std.testing.expectEqual(@as(u16, 443), parsed.port);
    try std.testing.expectEqualStrings("/path?key=value", parsed.path);
    try std.testing.expect(parsed.use_tls);
}

test "URL parsing ws with port" {
    const parsed = try parseWsUrl("ws://localhost:8080/ws");
    try std.testing.expectEqualStrings("localhost", parsed.host);
    try std.testing.expectEqual(@as(u16, 8080), parsed.port);
    try std.testing.expectEqualStrings("/ws", parsed.path);
    try std.testing.expect(!parsed.use_tls);
}
