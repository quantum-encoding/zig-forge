// Lyria RealTime WebSocket Client
// Uses Zig 0.16 std.Io for networking and TLS
// Adapted for Google's BidiGenerateMusic API

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;
const tls = std.crypto.tls;
const Allocator = std.mem.Allocator;

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
            // Fallback: use PRNG seeded from timestamp
            var seed: u64 = 0x9e3779b97f4a7c15;
            if (std.time.Instant.now()) |instant| {
                seed ^= @bitCast(instant.timestamp.sec);
            } else |_| {}
            var prng = std.Random.DefaultPrng.init(seed);
            prng.fill(buf);
        },
    }
}

const LYRIA_WS_HOST = "generativelanguage.googleapis.com";
const LYRIA_WS_PORT: u16 = 443;
const LYRIA_MODEL = "models/lyria-realtime-exp";

/// WebSocket opcodes (RFC 6455)
const OpCode = enum(u8) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
};

/// Lyria RealTime WebSocket client using Zig 0.16 Io
pub const LyriaWsClient = struct {
    allocator: Allocator,
    io_threaded: *Io.Threaded,
    stream: ?net.Stream = null,
    tls_connection: ?*TlsConnection = null,
    connected: bool = false,
    closed: bool = false,

    const Self = @This();

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

            // Generate entropy for TLS
            var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
            getRandomBytes(&entropy);

            // Get current realtime for certificate validation
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(.REALTIME, &ts);
            const realtime_now: std.Io.Timestamp = .{
                .nanoseconds = @as(i96, ts.sec) * 1_000_000_000 + @as(i96, ts.nsec),
            };

            // Initialize TLS client
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
            ) catch |err| {
                std.debug.print("TLS init error: {any}\n", .{err});
                return err;
            };

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

    /// Connect to Lyria RealTime WebSocket
    pub fn connect(self: *Self, api_key: []const u8) !void {
        const io = self.io_threaded.io();

        // Resolve hostname using getaddrinfo
        std.debug.print("LyriaWS: Resolving {s}...\n", .{LYRIA_WS_HOST});

        var host_buf: [256]u8 = undefined;
        @memcpy(host_buf[0..LYRIA_WS_HOST.len], LYRIA_WS_HOST);
        host_buf[LYRIA_WS_HOST.len] = 0;

        var hints: std.c.addrinfo = std.mem.zeroes(std.c.addrinfo);
        hints.family = std.posix.AF.INET;
        hints.socktype = std.posix.SOCK.STREAM;

        var result: ?*std.c.addrinfo = null;
        const rc = std.c.getaddrinfo(@ptrCast(&host_buf), null, &hints, &result);
        if (@intFromEnum(rc) != 0 or result == null) {
            std.debug.print("LyriaWS: DNS resolution failed\n", .{});
            return error.HostUnreachable;
        }
        defer std.c.freeaddrinfo(result.?);

        // Extract IPv4 address from result
        const sockaddr_ptr: *const std.posix.sockaddr.in = @ptrCast(@alignCast(result.?.addr));
        const ip_bytes: [4]u8 = @bitCast(sockaddr_ptr.addr);

        std.debug.print("LyriaWS: Resolved to {}.{}.{}.{}\n", .{
            ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3],
        });

        // Build IP address
        const addr = net.IpAddress{ .ip4 = .{
            .bytes = ip_bytes,
            .port = LYRIA_WS_PORT,
        } };

        std.debug.print("LyriaWS: Connecting to port {d}...\n", .{LYRIA_WS_PORT});

        self.stream = net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch |err| {
            std.debug.print("LyriaWS: TCP connect failed: {any}\n", .{err});
            return err;
        };
        errdefer if (self.stream) |*s| s.close(io);

        // TLS handshake
        std.debug.print("LyriaWS: TLS handshake...\n", .{});

        self.tls_connection = TlsConnection.init(
            self.allocator,
            self.stream.?,
            io,
            LYRIA_WS_HOST,
        ) catch |err| {
            std.debug.print("LyriaWS: TLS init failed: {any}\n", .{err});
            return err;
        };
        errdefer if (self.tls_connection) |tc| tc.deinit();

        // WebSocket handshake
        try self.doHandshake(api_key);

        self.connected = true;
        std.debug.print("LyriaWS: Connected to Lyria RealTime\n", .{});
    }

    /// Perform WebSocket upgrade handshake
    fn doHandshake(self: *Self, api_key: []const u8) !void {
        const tc = self.tls_connection orelse return error.NotConnected;

        // Generate Sec-WebSocket-Key
        var key_bytes: [16]u8 = undefined;
        getRandomBytes(&key_bytes);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &key_bytes);

        // Build handshake request
        var buf: [2048]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf,
            "/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateMusic?key={s}",
            .{api_key},
        );

        var request_buf: [4096]u8 = undefined;
        const request = try std.fmt.bufPrint(&request_buf,
            "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n",
            .{ path, LYRIA_WS_HOST, key },
        );

        // Send handshake
        try tc.writeAll(request);

        // Read response
        var response_buf: [1024]u8 = undefined;
        const n = try tc.read(&response_buf);
        const response = response_buf[0..n];

        // Verify 101 Switching Protocols
        if (!std.mem.startsWith(u8, response, "HTTP/1.1 101")) {
            std.debug.print("LyriaWS: Handshake failed: {s}\n", .{response[0..@min(100, response.len)]});
            return error.HandshakeFailed;
        }
    }

    /// Send a text message (JSON)
    pub fn sendText(self: *Self, message: []const u8) !void {
        if (!self.connected or self.closed) return error.NotConnected;
        try self.writeFrame(.text, message);
    }

    /// Write a WebSocket frame with masking
    fn writeFrame(self: *Self, opcode: OpCode, payload: []const u8) !void {
        const tc = self.tls_connection orelse return error.NotConnected;

        var header: [14]u8 = undefined;
        var header_len: usize = 2;

        // First byte: FIN + opcode
        header[0] = 0x80 | @intFromEnum(opcode);

        // Second byte: MASK + payload length
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
            header[2] = @intCast((len64 >> 56) & 0xFF);
            header[3] = @intCast((len64 >> 48) & 0xFF);
            header[4] = @intCast((len64 >> 40) & 0xFF);
            header[5] = @intCast((len64 >> 32) & 0xFF);
            header[6] = @intCast((len64 >> 24) & 0xFF);
            header[7] = @intCast((len64 >> 16) & 0xFF);
            header[8] = @intCast((len64 >> 8) & 0xFF);
            header[9] = @intCast(len64 & 0xFF);
            header_len = 10;
        }

        // Generate mask
        var mask: [4]u8 = undefined;
        getRandomBytes(&mask);
        @memcpy(header[header_len..][0..4], &mask);
        header_len += 4;

        // Send header
        try tc.writeAll(header[0..header_len]);

        // Send masked payload
        if (payload.len > 0) {
            const masked = try self.allocator.alloc(u8, payload.len);
            defer self.allocator.free(masked);

            for (payload, 0..) |b, i| {
                masked[i] = b ^ mask[i % 4];
            }
            try tc.writeAll(masked);
        }
    }

    /// Receive a message (blocks until message received)
    pub fn receive(self: *Self) !?Message {
        if (!self.connected or self.closed) return null;
        const tc = self.tls_connection orelse return null;

        // Read frame header
        var header: [2]u8 = undefined;
        const h_read = try tc.read(&header);
        if (h_read < 2) return null;

        const fin = (header[0] & 0x80) != 0;
        _ = fin;
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

            // Unmask if needed
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
            // Respond with pong
            try self.writeFrame(.pong, payload);
            self.allocator.free(payload);
            return self.receive();
        } else if (opcode == .pong) {
            self.allocator.free(payload);
            return self.receive();
        }

        return Message{
            .opcode = opcode,
            .payload = payload,
            .allocator = self.allocator,
        };
    }

    /// Close the connection
    pub fn close(self: *Self) void {
        // Send close frame if still connected
        if (self.connected and !self.closed) {
            self.writeFrame(.close, &[_]u8{ 0x03, 0xe8 }) catch {}; // 1000
        }

        // Always clean up TLS connection if it exists
        if (self.tls_connection) |tc| {
            tc.deinit();
            self.tls_connection = null;
        }

        // Always clean up stream if it exists
        if (self.stream) |*s| {
            s.close(self.io_threaded.io());
            self.stream = null;
        }

        self.connected = false;
        self.closed = true;
    }
};

/// Received WebSocket message
pub const Message = struct {
    opcode: OpCode,
    payload: []u8,
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
};

// ============================================================================
// Lyria Session API
// ============================================================================

/// Lyria RealTime session
pub const LyriaSession = struct {
    ws: LyriaWsClient,
    allocator: Allocator,
    setup_complete: bool = false,

    pub fn init(allocator: Allocator) !LyriaSession {
        return .{
            .ws = try LyriaWsClient.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LyriaSession) void {
        self.ws.deinit();
    }

    /// Connect and setup Lyria session
    pub fn connect(self: *LyriaSession, api_key: []const u8) !void {
        try self.ws.connect(api_key);

        // Send setup message
        const setup_msg = try std.fmt.allocPrint(self.allocator,
            \\{{"setup":{{"model":"{s}"}}}}
        , .{LYRIA_MODEL});
        defer self.allocator.free(setup_msg);

        try self.ws.sendText(setup_msg);

        // Wait for setupComplete
        while (self.ws.receive()) |maybe_msg| {
            if (maybe_msg) |*msg_ptr| {
                var msg = msg_ptr.*;
                defer msg.deinit();
                // Check for setupComplete
                if (std.mem.indexOf(u8, msg.payload, "setupComplete") != null) {
                    self.setup_complete = true;
                    break;
                }
            } else break;
        } else |_| {}
    }

    /// Set weighted prompts
    pub fn setPrompts(self: *LyriaSession, prompts: []const WeightedPrompt) !void {
        var json: std.ArrayListUnmanaged(u8) = .empty;
        defer json.deinit(self.allocator);

        try json.appendSlice(self.allocator, "{\"client_content\":{\"weighted_prompts\":[");

        for (prompts, 0..) |p, i| {
            if (i > 0) try json.append(self.allocator, ',');
            const prompt_json = try std.fmt.allocPrint(self.allocator,
                "{{\"text\":\"{s}\",\"weight\":{d}}}",
                .{ p.text, p.weight },
            );
            defer self.allocator.free(prompt_json);
            try json.appendSlice(self.allocator, prompt_json);
        }

        try json.appendSlice(self.allocator, "]}}");
        try self.ws.sendText(json.items);
    }

    /// Set music generation config
    pub fn setConfig(self: *LyriaSession, config: MusicConfig) !void {
        var json: std.ArrayListUnmanaged(u8) = .empty;
        defer json.deinit(self.allocator);

        try json.appendSlice(self.allocator, "{\"music_generation_config\":{");
        try json.appendSlice(self.allocator, "\"temperature\":1.1,\"guidance\":4.0");

        if (config.bpm) |bpm| {
            const bpm_str = try std.fmt.allocPrint(self.allocator, ",\"bpm\":{d}", .{bpm});
            defer self.allocator.free(bpm_str);
            try json.appendSlice(self.allocator, bpm_str);
        }

        try json.appendSlice(self.allocator, ",\"musicGenerationMode\":\"QUALITY\"}}");
        try self.ws.sendText(json.items);
    }

    /// Start playback
    pub fn play(self: *LyriaSession) !void {
        try self.ws.sendText("{\"playback_control\":\"PLAY\"}");
    }

    /// Pause playback
    pub fn pause(self: *LyriaSession) !void {
        try self.ws.sendText("{\"playback_control\":\"PAUSE\"}");
    }

    /// Stop playback
    pub fn stop(self: *LyriaSession) !void {
        try self.ws.sendText("{\"playback_control\":\"STOP\"}");
    }

    /// Receive audio chunk (returns base64-decoded PCM data)
    pub fn receiveAudio(self: *LyriaSession) !?[]u8 {
        if (self.ws.receive()) |maybe_msg| {
            if (maybe_msg) |*msg_ptr| {
                var msg = msg_ptr.*;
                defer msg.deinit();

                // Parse JSON and extract audio
                if (std.json.parseFromSlice(std.json.Value, self.allocator, msg.payload, .{
                    .allocate = .alloc_always,
                })) |parsed| {
                    defer parsed.deinit();

                    // Extract server_content.audio_chunks[].data
                    if (parsed.value.object.get("serverContent") orelse
                        parsed.value.object.get("server_content")) |sc|
                    {
                        if (sc.object.get("audioChunks") orelse
                            sc.object.get("audio_chunks")) |chunks|
                        {
                            for (chunks.array.items) |chunk| {
                                if (chunk.object.get("data")) |data| {
                                    // Decode base64
                                    const decoded = decodeBase64(self.allocator, data.string) catch continue;
                                    return decoded;
                                }
                            }
                        }
                    }
                } else |_| {}

                // If binary frame, might be raw audio
                if (msg.isBinary() and msg.payload.len > 100) {
                    return try self.allocator.dupe(u8, msg.payload);
                }
            }
        } else |_| {}

        return null;
    }

    pub fn close(self: *LyriaSession) void {
        self.ws.close();
    }
};

pub const WeightedPrompt = struct {
    text: []const u8,
    weight: f32 = 1.0,
};

pub const MusicConfig = struct {
    bpm: ?u16 = null,
    temperature: f32 = 1.1,
    guidance: f32 = 4.0,
};

fn decodeBase64(allocator: Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.standard;
    const decoded_len = decoder.Decoder.calcSizeForSlice(encoded) catch return error.InvalidBase64;
    const buffer = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(buffer);

    decoder.Decoder.decode(buffer, encoded) catch return error.InvalidBase64;
    return buffer;
}

test "LyriaWsClient init" {
    const allocator = std.testing.allocator;
    var client = try LyriaWsClient.init(allocator);
    defer client.deinit();
}
