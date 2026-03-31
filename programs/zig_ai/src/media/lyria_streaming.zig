// Lyria RealTime Streaming Library
// Persistent WebSocket connection for real-time music generation
// Designed for chat app integration with dynamic prompt blending
//
// Usage:
//   const session = try LyriaStream.init(allocator, api_key);
//   defer session.deinit();
//
//   try session.setPrompts(&.{
//       .{ .text = "jazz", .weight = 0.7 },
//       .{ .text = "house", .weight = 0.3 },
//   });
//   try session.play();
//
//   while (session.isConnected()) {
//       if (try session.getAudioChunk()) |chunk| {
//           // Send to speakers or app
//           defer allocator.free(chunk);
//       }
//       // Handle UI input, update prompts, etc.
//   }

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const net = std.Io.net;
const tls = std.crypto.tls;
const Allocator = std.mem.Allocator;

// ============================================================================
// Public Types
// ============================================================================

/// Weighted prompt for music style blending
pub const WeightedPrompt = struct {
    text: []const u8,
    weight: f32 = 1.0,
};

/// Music generation configuration
pub const MusicConfig = struct {
    bpm: ?u16 = null,
    temperature: f32 = 1.1,
    guidance: f32 = 4.0,
    density: ?f32 = null,
    brightness: ?f32 = null,
    mute_bass: bool = false,
    mute_drums: bool = false,
    only_bass_and_drums: bool = false,
};

/// Audio format information
pub const AudioFormat = struct {
    sample_rate: u32 = 48000,
    channels: u16 = 2,
    bits_per_sample: u16 = 16,
};

/// Session state
pub const SessionState = enum {
    disconnected,
    connecting,
    setup,
    ready,
    playing,
    paused,
    failed,
};

// ============================================================================
// Constants
// ============================================================================

const LYRIA_WS_HOST = "generativelanguage.googleapis.com";
const LYRIA_WS_PORT: u16 = 443;
const LYRIA_MODEL = "models/lyria-realtime-exp";

// ============================================================================
// Lyria Streaming Session
// ============================================================================

/// Persistent streaming session for real-time music generation
pub const LyriaStream = struct {
    allocator: Allocator,
    io_threaded: *Io.Threaded,
    stream: ?net.Stream = null,
    tls_conn: ?*TlsConnection = null,
    state: SessionState = .disconnected,
    audio_format: AudioFormat = .{},

    // Current prompts (owned)
    current_prompts: std.ArrayList(OwnedPrompt),

    const Self = @This();

    const OwnedPrompt = struct {
        text: []u8,
        weight: f32,
    };

    /// Initialize a new streaming session
    pub fn init(allocator: Allocator) !*Self {
        const io_threaded = try allocator.create(Io.Threaded);
        io_threaded.* = Io.Threaded.init(allocator, .{
            .environ = .{ .block = .{ .slice = @ptrCast(std.mem.span(std.c.environ)) } },
        });

        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .io_threaded = io_threaded,
            .current_prompts = .{ .items = &.{}, .capacity = 0 },
        };

        return self;
    }

    /// Clean up all resources
    pub fn deinit(self: *Self) void {
        self.close();

        // Free owned prompts
        for (self.current_prompts.items) |p| {
            self.allocator.free(p.text);
        }
        self.current_prompts.deinit(self.allocator);

        self.io_threaded.deinit();
        self.allocator.destroy(self.io_threaded);
        self.allocator.destroy(self);
    }

    /// Connect to Lyria RealTime service
    pub fn connect(self: *Self, api_key: []const u8) !void {
        if (self.state != .disconnected) {
            return error.AlreadyConnected;
        }

        self.state = .connecting;
        errdefer self.state = .failed;

        const io = self.io_threaded.io();

        // DNS resolution
        var host_buf: [256]u8 = undefined;
        @memcpy(host_buf[0..LYRIA_WS_HOST.len], LYRIA_WS_HOST);
        host_buf[LYRIA_WS_HOST.len] = 0;

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
            .port = LYRIA_WS_PORT,
        } };

        // TCP connect
        self.stream = try net.IpAddress.connect(&addr, io, .{ .mode = .stream });
        errdefer if (self.stream) |*s| s.close(io);

        // TLS handshake
        self.tls_conn = try TlsConnection.init(self.allocator, self.stream.?, io, LYRIA_WS_HOST);
        errdefer if (self.tls_conn) |tc| tc.deinit();

        // WebSocket upgrade
        try self.doWebSocketHandshake(api_key);

        self.state = .setup;

        // Send model setup
        const setup_msg = try std.fmt.allocPrint(self.allocator,
            \\{{"setup":{{"model":"{s}"}}}}
        , .{LYRIA_MODEL});
        defer self.allocator.free(setup_msg);
        try self.sendText(setup_msg);

        // Wait for setupComplete
        while (try self.receiveRaw()) |msg| {
            defer self.allocator.free(msg);
            if (std.mem.indexOf(u8, msg, "setupComplete") != null) {
                self.state = .ready;
                return;
            }
        }

        return error.SetupFailed;
    }

    /// Update prompts for music style blending
    /// Can be called while playing to smoothly transition styles
    pub fn setPrompts(self: *Self, prompts: []const WeightedPrompt) !void {
        if (self.state == .disconnected or self.state == .failed) {
            return error.NotConnected;
        }

        // Update internal prompt list
        for (self.current_prompts.items) |p| {
            self.allocator.free(p.text);
        }
        self.current_prompts.clearRetainingCapacity();

        for (prompts) |p| {
            try self.current_prompts.append(self.allocator, .{
                .text = try self.allocator.dupe(u8, p.text),
                .weight = p.weight,
            });
        }

        // Build and send JSON message
        var json: std.ArrayListUnmanaged(u8) = .empty;
        defer json.deinit(self.allocator);

        try json.appendSlice(self.allocator, "{\"client_content\":{\"weighted_prompts\":[");

        for (prompts, 0..) |p, i| {
            if (i > 0) try json.append(self.allocator, ',');
            const escaped = try escapeJson(self.allocator, p.text);
            defer self.allocator.free(escaped);
            const prompt_json = try std.fmt.allocPrint(self.allocator,
                "{{\"text\":\"{s}\",\"weight\":{d}}}",
                .{ escaped, p.weight },
            );
            defer self.allocator.free(prompt_json);
            try json.appendSlice(self.allocator, prompt_json);
        }

        try json.appendSlice(self.allocator, "]}}");
        try self.sendText(json.items);
    }

    /// Update music generation config
    pub fn setConfig(self: *Self, config: MusicConfig) !void {
        if (self.state == .disconnected or self.state == .failed) {
            return error.NotConnected;
        }

        var json: std.ArrayListUnmanaged(u8) = .empty;
        defer json.deinit(self.allocator);

        try json.appendSlice(self.allocator, "{\"music_generation_config\":{");

        var first = true;

        // Temperature
        try json.appendSlice(self.allocator, "\"temperature\":");
        try appendFloatUnmanaged(&json, self.allocator, config.temperature);
        first = false;

        // Guidance
        if (!first) try json.append(self.allocator, ',');
        try json.appendSlice(self.allocator, "\"guidance\":");
        try appendFloatUnmanaged(&json, self.allocator, config.guidance);

        // BPM
        if (config.bpm) |bpm| {
            try json.append(self.allocator, ',');
            const bpm_str = try std.fmt.allocPrint(self.allocator, "\"bpm\":{d}", .{bpm});
            defer self.allocator.free(bpm_str);
            try json.appendSlice(self.allocator, bpm_str);
        }

        // Density
        if (config.density) |d| {
            try json.append(self.allocator, ',');
            try json.appendSlice(self.allocator, "\"density\":");
            try appendFloatUnmanaged(&json, self.allocator, d);
        }

        // Brightness
        if (config.brightness) |b| {
            try json.append(self.allocator, ',');
            try json.appendSlice(self.allocator, "\"brightness\":");
            try appendFloatUnmanaged(&json, self.allocator, b);
        }

        // Mute options
        if (config.mute_bass) {
            try json.appendSlice(self.allocator, ",\"muteBass\":true");
        }
        if (config.mute_drums) {
            try json.appendSlice(self.allocator, ",\"muteDrums\":true");
        }
        if (config.only_bass_and_drums) {
            try json.appendSlice(self.allocator, ",\"onlyBassAndDrums\":true");
        }

        try json.appendSlice(self.allocator, ",\"musicGenerationMode\":\"QUALITY\"}}");
        try self.sendText(json.items);
    }

    /// Start or resume playback
    pub fn play(self: *Self) !void {
        if (self.state == .disconnected or self.state == .failed) {
            return error.NotConnected;
        }
        try self.sendText("{\"playback_control\":\"PLAY\"}");
        self.state = .playing;
    }

    /// Pause playback
    pub fn pause(self: *Self) !void {
        if (self.state != .playing) return;
        try self.sendText("{\"playback_control\":\"PAUSE\"}");
        self.state = .paused;
    }

    /// Stop playback
    pub fn stop(self: *Self) !void {
        if (self.state == .disconnected or self.state == .failed) return;
        try self.sendText("{\"playback_control\":\"STOP\"}");
        self.state = .ready;
    }

    /// Reset context (required after changing BPM or scale)
    pub fn resetContext(self: *Self) !void {
        if (self.state == .disconnected or self.state == .failed) {
            return error.NotConnected;
        }
        try self.sendText("{\"playback_control\":\"RESET_CONTEXT\"}");
    }

    /// Get next audio chunk (decoded PCM)
    /// Returns null if no audio available yet
    /// Caller owns the returned memory
    pub fn getAudioChunk(self: *Self) !?[]u8 {
        if (self.state == .disconnected or self.state == .failed) {
            return null;
        }

        const msg = try self.receiveRaw() orelse return null;
        defer self.allocator.free(msg);

        // Parse JSON and extract audio
        if (std.json.parseFromSlice(std.json.Value, self.allocator, msg, .{
            .allocate = .alloc_always,
        })) |parsed| {
            defer parsed.deinit();

            // Extract serverContent.audioChunks[].data
            if (parsed.value.object.get("serverContent") orelse
                parsed.value.object.get("server_content")) |sc|
            {
                if (sc.object.get("audioChunks") orelse
                    sc.object.get("audio_chunks")) |chunks|
                {
                    for (chunks.array.items) |chunk| {
                        if (chunk.object.get("data")) |data| {
                            return decodeBase64(self.allocator, data.string) catch continue;
                        }
                    }
                }
            }
        } else |_| {}

        return null;
    }

    /// Check if session is connected
    pub fn isConnected(self: *const Self) bool {
        return self.state != .disconnected and self.state != .failed;
    }

    /// Get current session state
    pub fn getState(self: *const Self) SessionState {
        return self.state;
    }

    /// Get audio format info
    pub fn getAudioFormat(self: *const Self) AudioFormat {
        return self.audio_format;
    }

    /// Close the connection gracefully
    pub fn close(self: *Self) void {
        if (self.state == .disconnected) return;

        // Send WebSocket close frame
        if (self.tls_conn != null) {
            self.sendCloseFrame() catch {};
        }

        // Clean up TLS
        if (self.tls_conn) |tc| {
            tc.deinit();
            self.tls_conn = null;
        }

        // Clean up stream
        if (self.stream) |*s| {
            s.close(self.io_threaded.io());
            self.stream = null;
        }

        self.state = .disconnected;
    }

    // ========================================================================
    // Private Methods
    // ========================================================================

    fn doWebSocketHandshake(self: *Self, api_key: []const u8) !void {
        const tc = self.tls_conn orelse return error.NotConnected;

        // Generate Sec-WebSocket-Key
        var key_bytes: [16]u8 = undefined;
        getRandomBytes(&key_bytes);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &key_bytes);

        // Build request
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

        try tc.writeAll(request);

        // Read response
        var response_buf: [1024]u8 = undefined;
        const n = try tc.read(&response_buf);

        if (!std.mem.startsWith(u8, response_buf[0..n], "HTTP/1.1 101")) {
            return error.WebSocketUpgradeFailed;
        }
    }

    fn sendText(self: *Self, message: []const u8) !void {
        const tc = self.tls_conn orelse return error.NotConnected;
        try self.writeFrame(tc, 0x01, message); // 0x01 = text frame
    }

    fn sendCloseFrame(self: *Self) !void {
        const tc = self.tls_conn orelse return;
        try self.writeFrame(tc, 0x08, &[_]u8{ 0x03, 0xe8 }); // 1000 = normal closure
    }

    fn writeFrame(self: *Self, tc: *TlsConnection, opcode: u8, payload: []const u8) !void {
        var header: [14]u8 = undefined;
        var header_len: usize = 2;

        header[0] = 0x80 | opcode; // FIN + opcode

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

        // Mask
        var mask: [4]u8 = undefined;
        getRandomBytes(&mask);
        @memcpy(header[header_len..][0..4], &mask);
        header_len += 4;

        try tc.writeAll(header[0..header_len]);

        if (payload.len > 0) {
            const masked = try self.allocator.alloc(u8, payload.len);
            defer self.allocator.free(masked);
            for (payload, 0..) |b, i| {
                masked[i] = b ^ mask[i % 4];
            }
            try tc.writeAll(masked);
        }
    }

    fn receiveRaw(self: *Self) !?[]u8 {
        const tc = self.tls_conn orelse return null;

        var header: [2]u8 = undefined;
        const h_read = tc.read(&header) catch return null;
        if (h_read < 2) return null;

        const opcode = header[0] & 0x0F;
        const masked = (header[1] & 0x80) != 0;
        var payload_len: u64 = header[1] & 0x7F;

        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            _ = try tc.read(&ext);
            payload_len = (@as(u64, ext[0]) << 8) | ext[1];
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            _ = try tc.read(&ext);
            payload_len = std.mem.readInt(u64, &ext, .big);
        }

        var mask_key: [4]u8 = undefined;
        if (masked) {
            _ = try tc.read(&mask_key);
        }

        const payload = try self.allocator.alloc(u8, @intCast(payload_len));
        errdefer self.allocator.free(payload);

        if (payload_len > 0) {
            var total: usize = 0;
            while (total < payload_len) {
                const n = try tc.read(payload[total..]);
                if (n == 0) break;
                total += n;
            }

            if (masked) {
                for (payload, 0..) |*b, i| {
                    b.* ^= mask_key[i % 4];
                }
            }
        }

        // Handle control frames
        if (opcode == 0x08) { // Close
            self.state = .disconnected;
            self.allocator.free(payload);
            return null;
        } else if (opcode == 0x09) { // Ping
            self.writeFrame(tc, 0x0A, payload) catch {}; // Pong
            self.allocator.free(payload);
            return self.receiveRaw();
        } else if (opcode == 0x0A) { // Pong
            self.allocator.free(payload);
            return self.receiveRaw();
        }

        return payload;
    }
};

// ============================================================================
// TLS Connection Wrapper
// ============================================================================

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

        var rts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &rts);
        const realtime_now: std.Io.Timestamp = .{
            .nanoseconds = @as(i96, rts.sec) * 1_000_000_000 + @as(i96, rts.nsec),
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

// ============================================================================
// Utilities
// ============================================================================

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

fn decodeBase64(allocator: Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.standard;
    const decoded_len = decoder.Decoder.calcSizeForSlice(encoded) catch return error.InvalidBase64;
    const buffer = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(buffer);
    decoder.Decoder.decode(buffer, encoded) catch return error.InvalidBase64;
    return buffer;
}

fn escapeJson(allocator: Allocator, s: []const u8) ![]u8 {
    var extra: usize = 0;
    for (s) |c| {
        switch (c) {
            '"', '\\', '\n', '\r', '\t' => extra += 1,
            else => if (c < 0x20) { extra += 5; },
        }
    }

    const result = try allocator.alloc(u8, s.len + extra);
    var i: usize = 0;

    for (s) |c| {
        switch (c) {
            '"' => { result[i] = '\\'; result[i + 1] = '"'; i += 2; },
            '\\' => { result[i] = '\\'; result[i + 1] = '\\'; i += 2; },
            '\n' => { result[i] = '\\'; result[i + 1] = 'n'; i += 2; },
            '\r' => { result[i] = '\\'; result[i + 1] = 'r'; i += 2; },
            '\t' => { result[i] = '\\'; result[i + 1] = 't'; i += 2; },
            else => {
                if (c < 0x20) {
                    _ = std.fmt.bufPrint(result[i..][0..6], "\\u{x:0>4}", .{c}) catch unreachable;
                    i += 6;
                } else {
                    result[i] = c;
                    i += 1;
                }
            },
        }
    }

    return result[0..i];
}

fn appendFloatUnmanaged(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, value: f32) !void {
    var buf: [32]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "{d:.2}", .{value}) catch "0";
    try list.appendSlice(alloc, str);
}

// ============================================================================
// Tests
// ============================================================================

test "LyriaStream init/deinit" {
    const allocator = std.testing.allocator;
    const session = try LyriaStream.init(allocator);
    defer session.deinit();
    try std.testing.expect(session.state == .disconnected);
}

test "WeightedPrompt" {
    const prompts = [_]WeightedPrompt{
        .{ .text = "jazz", .weight = 0.7 },
        .{ .text = "house", .weight = 0.3 },
    };
    try std.testing.expectEqual(@as(f32, 0.7), prompts[0].weight);
    try std.testing.expectEqual(@as(f32, 0.3), prompts[1].weight);
}
