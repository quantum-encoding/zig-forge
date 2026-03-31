// Gemini Live WebSocket Client
// TLS + WebSocket connection to wss://generativelanguage.googleapis.com
// API key passed in URL query parameter (not header)

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;
const tls = std.crypto.tls;
const Allocator = std.mem.Allocator;

const GEMINI_WS_HOST = "generativelanguage.googleapis.com";
const GEMINI_WS_PORT: u16 = 443;
const GEMINI_WS_PATH_PREFIX = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent";

/// WebSocket opcodes (RFC 6455)
const OpCode = enum(u8) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
};

/// TLS connection wrapper
const TlsConnection = struct {
    stream: net.Stream,
    stream_reader: net.Stream.Reader,
    stream_writer: net.Stream.Writer,
    tls_client: tls.Client,
    read_buffer: []u8,
    write_buffer: []u8,
    stream_read_buf: []u8,
    stream_write_buf: []u8,
    allocator: Allocator,

    fn init(allocator: Allocator, stream: net.Stream, io: Io, host: []const u8) !*TlsConnection {
        const buf_len = tls.Client.min_buffer_len;

        const read_buffer = try allocator.alloc(u8, buf_len);
        errdefer allocator.free(read_buffer);

        const write_buffer = try allocator.alloc(u8, buf_len);
        errdefer allocator.free(write_buffer);

        const stream_read_buf = try allocator.alloc(u8, buf_len);
        errdefer allocator.free(stream_read_buf);

        const stream_write_buf = try allocator.alloc(u8, buf_len);
        errdefer allocator.free(stream_write_buf);

        const conn = try allocator.create(TlsConnection);
        errdefer allocator.destroy(conn);

        conn.* = .{
            .stream = stream,
            .stream_reader = stream.reader(io, stream_read_buf),
            .stream_writer = stream.writer(io, stream_write_buf),
            .tls_client = undefined,
            .read_buffer = read_buffer,
            .write_buffer = write_buffer,
            .stream_read_buf = stream_read_buf,
            .stream_write_buf = stream_write_buf,
            .allocator = allocator,
        };

        var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
        getRandomBytes(&entropy);

        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        const realtime_now: std.Io.Timestamp = .{
            .nanoseconds = @as(i96, ts.sec) * 1_000_000_000 + @as(i96, ts.nsec),
        };

        conn.tls_client = tls.Client.init(
            &conn.stream_reader.interface,
            &conn.stream_writer.interface,
            .{
                .ca = .{ .no_verification = {} },
                .host = .{ .explicit = host },
                .read_buffer = read_buffer,
                .write_buffer = write_buffer,
                .entropy = &entropy,
                .realtime_now = realtime_now,
            },
        ) catch |err| return err;

        return conn;
    }

    fn deinit(self: *TlsConnection) void {
        _ = self.tls_client.end() catch {};
        self.allocator.free(self.read_buffer);
        self.allocator.free(self.write_buffer);
        self.allocator.free(self.stream_read_buf);
        self.allocator.free(self.stream_write_buf);
        self.allocator.destroy(self);
    }

    fn writeAll(self: *TlsConnection, data: []const u8) !void {
        try self.tls_client.writer.writeAll(data);
        try self.tls_client.writer.flush();
        try self.stream_writer.interface.flush();
    }

    fn read(self: *TlsConnection, buf: []u8) !usize {
        var w: Io.Writer = .fixed(buf);
        while (true) {
            const n = self.tls_client.reader.stream(&w, .limited(buf.len)) catch |err| {
                return err;
            };
            if (n != 0) return n;
        }
    }
};

/// Gemini Live WebSocket client
pub const GeminiWsClient = struct {
    allocator: Allocator,
    io_threaded: *Io.Threaded,
    stream: ?net.Stream = null,
    tls_connection: ?*TlsConnection = null,
    connected: bool = false,
    closed: bool = false,

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        const io_threaded = try allocator.create(Io.Threaded);
        io_threaded.* = Io.Threaded.init(allocator, .{
            .environ = .{ .block = .{ .slice = @ptrCast(std.mem.span(std.c.environ)) } },
        });

        return .{
            .allocator = allocator,
            .io_threaded = io_threaded,
        };
    }

    pub fn deinit(self: *Self) void {
        self.close();
        self.io_threaded.deinit();
        self.allocator.destroy(self.io_threaded);
    }

    /// Connect to Gemini Live WebSocket (API key in URL)
    pub fn connect(self: *Self, api_key: []const u8) !void {
        const io = self.io_threaded.io();

        // DNS resolution
        var host_buf: [256]u8 = undefined;
        @memcpy(host_buf[0..GEMINI_WS_HOST.len], GEMINI_WS_HOST);
        host_buf[GEMINI_WS_HOST.len] = 0;

        var hints: std.c.addrinfo = std.mem.zeroes(std.c.addrinfo);
        hints.family = std.posix.AF.INET;
        hints.socktype = std.posix.SOCK.STREAM;

        var result: ?*std.c.addrinfo = null;
        const rc = std.c.getaddrinfo(@ptrCast(&host_buf), null, &hints, &result);
        if (@intFromEnum(rc) != 0 or result == null) {
            return error.DnsResolutionFailed;
        }
        defer std.c.freeaddrinfo(result.?);

        const sockaddr_ptr: *const std.posix.sockaddr.in = @ptrCast(@alignCast(result.?.addr));
        const ip_bytes: [4]u8 = @bitCast(sockaddr_ptr.addr);

        const addr = net.IpAddress{ .ip4 = .{
            .bytes = ip_bytes,
            .port = GEMINI_WS_PORT,
        } };

        // TCP connect
        self.stream = try net.IpAddress.connect(&addr, io, .{ .mode = .stream });
        errdefer if (self.stream) |*s| s.close(io);

        // TLS handshake
        self.tls_connection = try TlsConnection.init(self.allocator, self.stream.?, io, GEMINI_WS_HOST);
        errdefer if (self.tls_connection) |tc| tc.deinit();

        // WebSocket upgrade (API key in query parameter)
        try self.doHandshake(api_key);

        self.connected = true;
        self.closed = false;
    }

    /// WebSocket upgrade handshake — API key in URL query parameter
    fn doHandshake(self: *Self, api_key: []const u8) !void {
        const tc = self.tls_connection orelse return error.NotConnected;

        // Generate Sec-WebSocket-Key
        var key_bytes: [16]u8 = undefined;
        getRandomBytes(&key_bytes);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &key_bytes);

        var request_buf: [4096]u8 = undefined;
        const request = try std.fmt.bufPrint(&request_buf,
            "GET {s}?key={s} HTTP/1.1\r\n" ++
                "Host: {s}\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: {s}\r\n" ++
                "Sec-WebSocket-Version: 13\r\n" ++
                "\r\n",
            .{ GEMINI_WS_PATH_PREFIX, api_key, GEMINI_WS_HOST, key },
        );

        try tc.writeAll(request);

        // Read response
        var response_buf: [2048]u8 = undefined;
        const n = try tc.read(&response_buf);

        if (!std.mem.startsWith(u8, response_buf[0..n], "HTTP/1.1 101")) {
            return error.WebSocketUpgradeFailed;
        }
    }

    /// Send a text message (JSON)
    pub fn sendText(self: *Self, message: []const u8) !void {
        if (!self.connected or self.closed) return error.NotConnected;
        try self.writeFrame(.text, message);
    }

    /// Receive a message (blocks until data arrives)
    /// Caller owns the returned memory
    pub fn receive(self: *Self) !?[]u8 {
        if (!self.connected or self.closed) return null;
        const tc = self.tls_connection orelse return null;

        // Read frame header
        var header: [2]u8 = undefined;
        const h_read = tc.read(&header) catch return null;
        if (h_read < 2) return null;

        const opcode: OpCode = @enumFromInt(header[0] & 0x0F);
        const masked = (header[1] & 0x80) != 0;
        var payload_len: u64 = header[1] & 0x7F;

        // Extended length
        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            _ = try tc.read(&ext);
            payload_len = (@as(u64, ext[0]) << 8) | ext[1];
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            _ = try tc.read(&ext);
            payload_len = std.mem.readInt(u64, &ext, .big);
        }

        // Masking key (server shouldn't mask, but handle it)
        var mask_key: [4]u8 = undefined;
        if (masked) {
            _ = try tc.read(&mask_key);
        }

        // Read payload
        const payload = try self.allocator.alloc(u8, @intCast(payload_len));
        errdefer self.allocator.free(payload);

        if (payload_len > 0) {
            var total_read: usize = 0;
            while (total_read < payload_len) {
                const n = try tc.read(payload[total_read..]);
                if (n == 0) break;
                total_read += n;
            }

            if (masked) {
                for (payload, 0..) |*b, i| {
                    b.* ^= mask_key[i % 4];
                }
            }
        }

        // Handle control frames
        if (opcode == .close) {
            self.closed = true;
            self.allocator.free(payload);
            return null;
        } else if (opcode == .ping) {
            try self.writeFrame(.pong, payload);
            self.allocator.free(payload);
            return self.receive();
        } else if (opcode == .pong) {
            self.allocator.free(payload);
            return self.receive();
        }

        return payload;
    }

    /// Close the connection
    pub fn close(self: *Self) void {
        if (self.connected and !self.closed) {
            self.writeFrame(.close, &[_]u8{ 0x03, 0xe8 }) catch {};
        }

        if (self.tls_connection) |tc| {
            tc.deinit();
            self.tls_connection = null;
        }

        if (self.stream) |*s| {
            s.close(self.io_threaded.io());
            self.stream = null;
        }

        self.connected = false;
        self.closed = true;
    }

    /// Write a WebSocket frame with masking (RFC 6455)
    fn writeFrame(self: *Self, opcode: OpCode, payload: []const u8) !void {
        const tc = self.tls_connection orelse return error.NotConnected;

        var header: [14]u8 = undefined;
        var header_len: usize = 2;

        // FIN + opcode
        header[0] = 0x80 | @intFromEnum(opcode);

        // MASK + payload length
        if (payload.len < 126) {
            header[1] = 0x80 | @as(u8, @intCast(payload.len));
        } else if (payload.len < 65536) {
            header[1] = 0x80 | 126;
            header[2] = @intCast((payload.len >> 8) & 0xFF);
            header[3] = @intCast(payload.len & 0xFF);
            header_len = 4;
        } else {
            header[1] = 0x80 | 127;
            const len64: u64 = payload.len;
            inline for (0..8) |i| {
                header[2 + i] = @intCast((len64 >> @intCast(56 - i * 8)) & 0xFF);
            }
            header_len = 10;
        }

        // Generate mask
        var mask: [4]u8 = undefined;
        getRandomBytes(&mask);
        @memcpy(header[header_len..][0..4], &mask);
        header_len += 4;

        try tc.writeAll(header[0..header_len]);

        // Send masked payload
        if (payload.len > 0) {
            const masked_buf = try self.allocator.alloc(u8, payload.len);
            defer self.allocator.free(masked_buf);

            for (payload, 0..) |b, i| {
                masked_buf[i] = b ^ mask[i % 4];
            }
            try tc.writeAll(masked_buf);
        }
    }
};

// Cross-platform secure random bytes
fn getRandomBytes(buf: []u8) void {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos => {
            std.c.arc4random_buf(buf.ptr, buf.len);
        },
        .linux => {
            _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
        },
        else => {
            var seed: u64 = 0x9e3779b97f4a7c15;
            if (std.time.Instant.now()) |instant| {
                seed ^= @bitCast(instant.timestamp.sec);
            } else |_| {}
            var prng = std.Random.DefaultPrng.init(seed);
            prng.fill(buf);
        },
    }
}

test "GeminiWsClient init" {
    const allocator = std.testing.allocator;
    var client = try GeminiWsClient.init(allocator);
    defer client.deinit();
}
