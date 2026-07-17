//! X-Plane 12 REST + WebSocket client.
//!
//! REST API (startup): Resolve dataref names to session IDs.
//! WebSocket API (runtime): Subscribe to datarefs, receive 10Hz updates.
//!
//! Uses std.http.Client + Io.Threaded for HTTP, then steals the connection
//! for raw WebSocket frame I/O after the upgrade handshake.

const std = @import("std");
const protocol = @import("protocol.zig");
const Io = std.Io;
const http = std.http;

// C sleep for reconnect backoff (std.time.sleep doesn't exist in Zig 0.16)
extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;

pub const XPlaneClient = struct {
    allocator: std.mem.Allocator,
    io_threaded: *Io.Threaded,
    http_client: http.Client,
    host: []const u8,
    port: u16,

    // WebSocket state
    ws_connection: ?*http.Client.Connection = null,
    ws_state: WsState = .disconnected,
    next_req_id: u64 = 1,

    // Receive buffer for WebSocket frames
    recv_buf: [65536]u8 = undefined,
    recv_len: usize = 0,

    // Reconnect state
    reconnect_delay_ms: u64 = 500,

    pub const WsState = enum {
        disconnected,
        connected,
        closing,
    };

    pub const Error = error{
        ConnectionFailed,
        UpgradeFailed,
        NotConnected,
        SendFailed,
        RecvFailed,
        ApiError,
        DatarefNotFound,
        InvalidResponse,
        MissingDataField,
        MissingIdField,
        MissingNameField,
        MissingTypeField,
        WouldBlock,
    };

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !XPlaneClient {
        const io_threaded = try allocator.create(Io.Threaded);
        io_threaded.* = Io.Threaded.init(allocator, .{
            .environ = .{ .block = .{ .slice = @ptrCast(std.mem.span(std.c.environ)) } },
        });

        return .{
            .allocator = allocator,
            .io_threaded = io_threaded,
            .http_client = http.Client{
                .allocator = allocator,
                .io = io_threaded.io(),
            },
            .host = try allocator.dupe(u8, host),
            .port = port,
        };
    }

    pub fn deinit(self: *XPlaneClient) void {
        self.closeWebSocket();
        self.http_client.deinit();
        self.io_threaded.deinit();
        self.allocator.destroy(self.io_threaded);
        self.allocator.free(self.host);
    }

    // =========================================================================
    // REST API Methods (startup)
    // =========================================================================

    /// Make a GET request to the X-Plane REST API. Returns owned body slice.
    fn restGet(self: *XPlaneClient, path: []const u8) ![]u8 {
        var url_buf: [2048]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "http://{s}:{d}{s}", .{
            self.host, self.port, path,
        }) catch return Error.ApiError;

        const uri = std.Uri.parse(url) catch return Error.ApiError;

        var req = self.http_client.request(.GET, uri, .{}) catch
            return Error.ConnectionFailed;
        defer req.deinit();

        req.sendBodiless() catch return Error.ConnectionFailed;

        var response = req.receiveHead(&.{}) catch return Error.ConnectionFailed;

        if (response.head.status != .ok)
            return Error.ApiError;

        var transfer_buf: [8192]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        const body = reader.allocRemaining(self.allocator, std.Io.Limit.limited(1024 * 1024)) catch
            return Error.InvalidResponse;

        return body;
    }

    /// Look up a dataref by name, returning its session ID.
    pub fn findDatarefByName(self: *XPlaneClient, name: []const u8) !u64 {
        // Build the filter URL — need to percent-encode the brackets
        var path_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v3/datarefs?filter%5Bname%5D={s}", .{name}) catch
            return Error.ApiError;

        const body = try self.restGet(path);
        defer self.allocator.free(body);

        const result = protocol.parseDatarefLookup(self.allocator, body) catch
            return Error.DatarefNotFound;
        self.allocator.free(result.name);
        self.allocator.free(result.value_type);
        return result.id;
    }

    /// Get the current value of a dataref by ID.
    pub fn getDatarefValue(self: *XPlaneClient, id: u64) !f64 {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v3/datarefs/{d}/value", .{id}) catch
            return Error.ApiError;

        const body = try self.restGet(path);
        defer self.allocator.free(body);

        return protocol.parseDatarefValue(body) catch Error.InvalidResponse;
    }

    // =========================================================================
    // WebSocket Methods (runtime)
    // =========================================================================

    /// Connect WebSocket to X-Plane streaming API.
    /// Performs HTTP→WebSocket upgrade handshake (RFC 6455).
    pub fn connectWebSocket(self: *XPlaneClient) !void {
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "http://{s}:{d}/api/v3", .{
            self.host, self.port,
        }) catch return Error.ConnectionFailed;

        const uri = std.Uri.parse(url) catch return Error.ConnectionFailed;

        // Generate Sec-WebSocket-Key (16 random bytes, base64 encoded)
        var random_bytes: [16]u8 = undefined;
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        const seed: u64 = @bitCast(ts.sec *% 1_000_000_000 +% ts.nsec);
        var prng = std.Random.DefaultPrng.init(seed);
        prng.fill(&random_bytes);
        var ws_key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&ws_key, &random_bytes);

        var req = self.http_client.request(.GET, uri, .{
            .extra_headers = &[_]http.Header{
                .{ .name = "Upgrade", .value = "websocket" },
                .{ .name = "Connection", .value = "Upgrade" },
                .{ .name = "Sec-WebSocket-Key", .value = &ws_key },
                .{ .name = "Sec-WebSocket-Version", .value = "13" },
            },
        }) catch return Error.ConnectionFailed;

        // Flush request headers
        if (req.connection) |conn| {
            conn.flush() catch return Error.ConnectionFailed;
        }

        // Receive response
        const response = req.receiveHead(&.{}) catch return Error.ConnectionFailed;

        if (response.head.status != .switching_protocols)
            return Error.UpgradeFailed;

        // Steal the connection for raw WebSocket I/O
        self.ws_connection = req.connection;
        req.connection = null; // Prevent req.deinit() from closing it

        self.ws_state = .connected;
        self.recv_len = 0;
        self.reconnect_delay_ms = 500; // Reset backoff on success
    }

    /// Send a text WebSocket frame (client-masked per RFC 6455).
    /// Builds frame inline using stack buffers — zero allocation.
    pub fn wsSendText(self: *XPlaneClient, payload: []const u8) !void {
        const conn = self.ws_connection orelse return Error.NotConnected;

        // Frame header: FIN(1) + opcode text(0x1) = 0x81
        var header_buf: [14]u8 = undefined;
        var header_len: usize = 2;
        header_buf[0] = 0x81;

        // Payload length with MASK bit set
        if (payload.len < 126) {
            header_buf[1] = 0x80 | @as(u8, @truncate(payload.len));
        } else if (payload.len < 65536) {
            header_buf[1] = 0x80 | 126;
            std.mem.writeInt(u16, header_buf[2..4], @truncate(payload.len), .big);
            header_len = 4;
        } else {
            header_buf[1] = 0x80 | 127;
            std.mem.writeInt(u64, header_buf[2..10], payload.len, .big);
            header_len = 10;
        }

        // Generate masking key from PRNG
        var mask_key: [4]u8 = undefined;
        var ts2: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts2);
        const seed2: u64 = @bitCast(ts2.sec *% 1_000_000_000 +% ts2.nsec);
        var prng2 = std.Random.DefaultPrng.init(seed2);
        prng2.fill(&mask_key);

        @memcpy(header_buf[header_len..][0..4], &mask_key);
        header_len += 4;

        const writer = conn.writer();

        // Write header
        writer.writeAll(header_buf[0..header_len]) catch return Error.SendFailed;

        // Write masked payload in chunks
        var masked_chunk: [4096]u8 = undefined;
        var offset: usize = 0;
        while (offset < payload.len) {
            const chunk_len = @min(payload.len - offset, masked_chunk.len);
            for (0..chunk_len) |ci| {
                masked_chunk[ci] = payload[offset + ci] ^ mask_key[(offset + ci) % 4];
            }
            writer.writeAll(masked_chunk[0..chunk_len]) catch return Error.SendFailed;
            offset += chunk_len;
        }

        conn.flush() catch return Error.SendFailed;
    }

    /// Subscribe to datarefs via WebSocket.
    pub fn subscribeDatarefs(self: *XPlaneClient, ids: []const u64) !void {
        var msg_buf: [8192]u8 = undefined;
        const msg = protocol.buildSubscribeMessage(&msg_buf, self.nextReqId(), ids) catch
            return Error.SendFailed;
        try self.wsSendText(msg);
    }

    /// Unsubscribe from all datarefs.
    pub fn unsubscribeAll(self: *XPlaneClient) !void {
        var msg_buf: [512]u8 = undefined;
        const msg = protocol.buildUnsubscribeAllMessage(&msg_buf, self.nextReqId()) catch
            return Error.SendFailed;
        try self.wsSendText(msg);
    }

    /// Poll for incoming WebSocket data. Blocks until a complete frame arrives.
    /// Returns an UpdateBatch if a dataref_update_values message was received,
    /// null if message was non-update (result, pong, etc).
    pub fn poll(self: *XPlaneClient) !?protocol.UpdateBatch {
        while (true) {
            const frame = self.readFrame() catch return Error.RecvFailed;

            switch (frame.opcode) {
                0x1 => { // Text frame
                    const payload = self.recv_buf[0..frame.payload_len];
                    const msg_type = protocol.detectMessageType(payload);
                    switch (msg_type) {
                        .dataref_update_values => {
                            return protocol.parseUpdateValues(payload) catch null;
                        },
                        .result => return null,
                        .unknown => return null,
                    }
                },
                0x8 => { // Close
                    self.ws_state = .closing;
                    return Error.RecvFailed;
                },
                0x9 => { // Ping — respond with pong
                    self.sendPong(self.recv_buf[0..frame.payload_len]) catch {};
                    continue; // Read next frame
                },
                0xA => continue, // Pong — ignore
                else => continue,
            }
        }
    }

    const FrameInfo = struct {
        opcode: u8,
        payload_len: usize,
    };

    /// A single decoded WebSocket frame off the wire (before reassembly).
    const RawFrame = struct {
        fin: bool,
        opcode: u8,
        len: usize,
    };

    /// Read one raw WebSocket frame from `reader`, writing its (unmasked)
    /// payload into `dst`. Returns the FIN bit, opcode, and payload length.
    /// A payload that does not fit in `dst` is an error (treated as disconnect
    /// by callers). Generic over the reader type so it can be unit-tested
    /// against a fixed in-memory reader without a live connection.
    fn readRawFrame(reader: anytype, dst: []u8) !RawFrame {
        // First 2 bytes of the frame header.
        var header: [2]u8 = undefined;
        reader.readSliceAll(&header) catch return Error.RecvFailed;

        const fin = (header[0] & 0x80) != 0;
        const opcode = header[0] & 0x0F;
        const masked = (header[1] & 0x80) != 0;
        var payload_len: u64 = header[1] & 0x7F;

        // Extended payload length.
        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            reader.readSliceAll(&ext) catch return Error.RecvFailed;
            payload_len = std.mem.readInt(u16, &ext, .big);
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            reader.readSliceAll(&ext) catch return Error.RecvFailed;
            payload_len = std.mem.readInt(u64, &ext, .big);
        }

        // Masking key (servers shouldn't mask, but handle it defensively).
        var mask_key: [4]u8 = undefined;
        if (masked) {
            reader.readSliceAll(&mask_key) catch return Error.RecvFailed;
        }

        const plen: usize = std.math.cast(usize, payload_len) orelse return Error.RecvFailed;
        if (plen > dst.len) return Error.RecvFailed;

        if (plen > 0) {
            reader.readSliceAll(dst[0..plen]) catch return Error.RecvFailed;
            if (masked) {
                for (dst[0..plen], 0..) |*b, i| {
                    b.* ^= mask_key[i % 4];
                }
            }
        }

        return .{ .fin = fin, .opcode = opcode, .len = plen };
    }

    /// Assemble a complete (possibly fragmented) data message from `reader`
    /// into `recv_buf`, honoring the RFC 6455 FIN bit and continuation frames
    /// (opcode 0x0). Interleaved control frames (ping/pong/close) are handled
    /// inline: ping payloads are handed to `ctx.onPing`, pong frames ignored,
    /// and a close frame returns opcode 0x8. Returns the assembled data
    /// message with the opcode of its first frame (0x1 text / 0x2 binary).
    ///
    /// This is the fix for the dropped-continuation-frame bug: previously each
    /// raw frame was returned directly, so a fragmented message's continuation
    /// frames fell through `poll`'s `else => continue` and were silently lost.
    fn assembleFrame(reader: anytype, recv_buf: []u8, ctx: anytype) !FrameInfo {
        var total: usize = 0;
        var msg_opcode: u8 = 0; // 0 = no data frame started yet

        while (true) {
            // Control frames are <=125 bytes and never advance `total`, so it is
            // safe to stage them in the not-yet-assembled tail of recv_buf.
            const raw = try readRawFrame(reader, recv_buf[total..]);

            switch (raw.opcode) {
                0x0 => { // continuation
                    if (msg_opcode == 0) return Error.RecvFailed; // no message in progress
                },
                0x1, 0x2 => { // text / binary — start of a data message
                    if (msg_opcode != 0) return Error.RecvFailed; // new start mid-message
                    msg_opcode = raw.opcode;
                },
                0x8 => return .{ .opcode = 0x8, .payload_len = 0 }, // close
                0x9 => { // ping — reply, then keep reading (may be mid-fragment)
                    ctx.onPing(recv_buf[total..][0..raw.len]);
                    continue;
                },
                0xA => continue, // pong — ignore
                else => return Error.RecvFailed, // reserved opcode
            }

            total += raw.len;
            if (raw.fin) return .{ .opcode = msg_opcode, .payload_len = total };
            // else: more continuation frames follow; keep accumulating. Bounds
            // are enforced by readRawFrame against the shrinking recv_buf tail.
        }
    }

    /// Read a single (reassembled) WebSocket message. Payload is in
    /// recv_buf[0..payload_len].
    fn readFrame(self: *XPlaneClient) !FrameInfo {
        const conn = self.ws_connection orelse return Error.NotConnected;
        const reader = conn.reader();
        return assembleFrame(reader, &self.recv_buf, self);
    }

    /// Control-frame callback used by `assembleFrame` for interleaved pings.
    fn onPing(self: *XPlaneClient, payload: []const u8) void {
        self.sendPong(payload) catch {};
    }

    fn sendPong(self: *XPlaneClient, payload: []const u8) !void {
        const conn = self.ws_connection orelse return;
        // RFC 6455 caps control-frame payloads at 125 bytes; clamp so a
        // non-conforming oversized ping can't produce a malformed length byte.
        const plen: u8 = @truncate(@min(payload.len, 125));
        // Pong frame: FIN=1, opcode=0xA, MASK=1, zero mask key (XOR-identity).
        var header: [6]u8 = .{ 0x8A, 0x80, 0, 0, 0, 0 };
        header[1] |= plen;
        const writer = conn.writer();
        writer.writeAll(header[0..6]) catch return;
        if (plen > 0) writer.writeAll(payload[0..plen]) catch return;
        conn.flush() catch {};
    }

    /// Close the WebSocket connection gracefully.
    pub fn closeWebSocket(self: *XPlaneClient) void {
        if (self.ws_connection) |conn| {
            // Send close frame: FIN + close opcode, masked, code 1000
            const close_frame = [_]u8{ 0x88, 0x86, 0, 0, 0, 0, 0x03, 0xE8, 0, 0 };
            const writer = conn.writer();
            writer.writeAll(&close_frame) catch {};
            conn.flush() catch {};
            conn.destroy(self.io_threaded.io());
            self.ws_connection = null;
        }
        self.ws_state = .disconnected;
    }

    /// Attempt reconnect with exponential backoff.
    pub fn reconnect(self: *XPlaneClient) !void {
        // Sleep for backoff delay using C nanosleep
        const sec = self.reconnect_delay_ms / 1000;
        const nsec = (self.reconnect_delay_ms % 1000) * 1_000_000;
        const ts = std.c.timespec{ .sec = @intCast(sec), .nsec = @intCast(nsec) };
        _ = nanosleep(&ts, null);

        self.closeWebSocket();
        self.connectWebSocket() catch {
            self.reconnect_delay_ms = @min(self.reconnect_delay_ms * 2, 30000);
            return Error.ConnectionFailed;
        };
    }

    fn nextReqId(self: *XPlaneClient) u64 {
        const id = self.next_req_id;
        self.next_req_id += 1;
        return id;
    }

    pub fn isConnected(self: *const XPlaneClient) bool {
        return self.ws_state == .connected;
    }
};

// ============================================================================
// Tests — WebSocket frame decoding & reassembly
//
// These craft raw RFC 6455 frame bytes and drive the same decode path the
// live connection uses (readRawFrame / assembleFrame), so a regression in
// fragmentation handling fails a test rather than silently dropping wire data.
// ============================================================================

/// Ping sink that records interleaved ping payloads for assertions.
const TestPingSink = struct {
    ping_count: usize = 0,
    last: [128]u8 = undefined,
    last_len: usize = 0,

    fn onPing(self: *TestPingSink, payload: []const u8) void {
        self.ping_count += 1;
        @memcpy(self.last[0..payload.len], payload);
        self.last_len = payload.len;
    }
};

test "readRawFrame decodes an unmasked text frame" {
    var bytes = [_]u8{ 0x81, 0x02, 'h', 'i' };
    var reader = std.Io.Reader.fixed(&bytes);
    var dst: [64]u8 = undefined;

    const raw = try XPlaneClient.readRawFrame(&reader, &dst);
    try std.testing.expect(raw.fin);
    try std.testing.expectEqual(@as(u8, 0x1), raw.opcode);
    try std.testing.expectEqual(@as(usize, 2), raw.len);
    try std.testing.expectEqualStrings("hi", dst[0..raw.len]);
}

test "readRawFrame decodes a masked frame from the client direction" {
    // FIN|text, MASK|len=3, mask key, then masked "abc".
    const mask = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    var bytes = [_]u8{ 0x81, 0x83, mask[0], mask[1], mask[2], mask[3], 'a' ^ 0x01, 'b' ^ 0x02, 'c' ^ 0x03 };
    var reader = std.Io.Reader.fixed(&bytes);
    var dst: [64]u8 = undefined;

    const raw = try XPlaneClient.readRawFrame(&reader, &dst);
    try std.testing.expectEqual(@as(usize, 3), raw.len);
    try std.testing.expectEqualStrings("abc", dst[0..raw.len]);
}

test "readRawFrame decodes 16-bit extended length" {
    var bytes: [4 + 200]u8 = undefined;
    bytes[0] = 0x82; // FIN|binary
    bytes[1] = 0x7E; // len marker 126 -> next 2 bytes are u16 length
    std.mem.writeInt(u16, bytes[2..4], 200, .big);
    for (bytes[4..], 0..) |*b, i| b.* = @truncate(i);
    var reader = std.Io.Reader.fixed(&bytes);
    var dst: [512]u8 = undefined;

    const raw = try XPlaneClient.readRawFrame(&reader, &dst);
    try std.testing.expectEqual(@as(usize, 200), raw.len);
    try std.testing.expectEqual(@as(u8, 0x2), raw.opcode);
}

test "readRawFrame rejects a payload larger than the destination" {
    var bytes = [_]u8{ 0x81, 0x05, 'a', 'b', 'c', 'd', 'e' };
    var reader = std.Io.Reader.fixed(&bytes);
    var dst: [3]u8 = undefined; // too small for a 5-byte payload
    try std.testing.expectError(XPlaneClient.Error.RecvFailed, XPlaneClient.readRawFrame(&reader, &dst));
}

test "assembleFrame returns a single unfragmented text message" {
    var bytes = [_]u8{ 0x81, 0x05, 'h', 'e', 'l', 'l', 'o' };
    var reader = std.Io.Reader.fixed(&bytes);
    var recv_buf: [256]u8 = undefined;
    var sink = TestPingSink{};

    const info = try XPlaneClient.assembleFrame(&reader, &recv_buf, &sink);
    try std.testing.expectEqual(@as(u8, 0x1), info.opcode);
    try std.testing.expectEqualStrings("hello", recv_buf[0..info.payload_len]);
}

test "assembleFrame reassembles a fragmented message (the continuation-frame fix)" {
    // "hello world" split as text(FIN=0) "hello" + continuation(FIN=1) " world".
    var bytes = [_]u8{
        0x01, 0x05, 'h', 'e', 'l', 'l', 'o', // FIN=0, opcode=text
        0x80, 0x06, ' ', 'w', 'o', 'r', 'l', 'd', // FIN=1, opcode=continuation
    };
    var reader = std.Io.Reader.fixed(&bytes);
    var recv_buf: [256]u8 = undefined;
    var sink = TestPingSink{};

    const info = try XPlaneClient.assembleFrame(&reader, &recv_buf, &sink);
    try std.testing.expectEqual(@as(u8, 0x1), info.opcode);
    try std.testing.expectEqual(@as(usize, 11), info.payload_len);
    try std.testing.expectEqualStrings("hello world", recv_buf[0..info.payload_len]);
}

test "assembleFrame handles a ping interleaved between fragments" {
    var bytes = [_]u8{
        0x01, 0x03, 'a', 'b', 'c', // FIN=0, text
        0x89, 0x02, 'p', 'i', // FIN=1, ping "pi"
        0x80, 0x03, 'd', 'e', 'f', // FIN=1, continuation
    };
    var reader = std.Io.Reader.fixed(&bytes);
    var recv_buf: [256]u8 = undefined;
    var sink = TestPingSink{};

    const info = try XPlaneClient.assembleFrame(&reader, &recv_buf, &sink);
    try std.testing.expectEqual(@as(u8, 0x1), info.opcode);
    try std.testing.expectEqualStrings("abcdef", recv_buf[0..info.payload_len]);
    try std.testing.expectEqual(@as(usize, 1), sink.ping_count);
    try std.testing.expectEqualStrings("pi", sink.last[0..sink.last_len]);
}

test "assembleFrame surfaces a close frame as opcode 0x8" {
    var bytes = [_]u8{ 0x88, 0x00 }; // FIN|close, empty payload
    var reader = std.Io.Reader.fixed(&bytes);
    var recv_buf: [64]u8 = undefined;
    var sink = TestPingSink{};

    const info = try XPlaneClient.assembleFrame(&reader, &recv_buf, &sink);
    try std.testing.expectEqual(@as(u8, 0x8), info.opcode);
}

test "assembleFrame rejects a stray continuation with no message in progress" {
    var bytes = [_]u8{ 0x80, 0x02, 'x', 'y' }; // FIN=1, continuation, but no start
    var reader = std.Io.Reader.fixed(&bytes);
    var recv_buf: [64]u8 = undefined;
    var sink = TestPingSink{};
    try std.testing.expectError(
        XPlaneClient.Error.RecvFailed,
        XPlaneClient.assembleFrame(&reader, &recv_buf, &sink),
    );
}
