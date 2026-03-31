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

    /// Read a single WebSocket frame (blocking). Payload is in recv_buf[0..len].
    fn readFrame(self: *XPlaneClient) !FrameInfo {
        const conn = self.ws_connection orelse return Error.NotConnected;
        var reader = conn.reader();

        // Read first 2 bytes of header
        var header: [2]u8 = undefined;
        reader.readSliceAll(&header) catch return Error.RecvFailed;

        const opcode = header[0] & 0x0F;
        const masked = (header[1] & 0x80) != 0;
        var payload_len: u64 = header[1] & 0x7F;

        // Extended payload length
        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            reader.readSliceAll(&ext) catch return Error.RecvFailed;
            payload_len = std.mem.readInt(u16, &ext, .big);
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            reader.readSliceAll(&ext) catch return Error.RecvFailed;
            payload_len = std.mem.readInt(u64, &ext, .big);
        }

        // Masking key (servers shouldn't mask, but handle it)
        var mask_key: [4]u8 = undefined;
        if (masked) {
            reader.readSliceAll(&mask_key) catch return Error.RecvFailed;
        }

        // Read payload into recv_buf
        const plen: usize = @intCast(payload_len);
        if (plen > self.recv_buf.len) return Error.RecvFailed;

        if (plen > 0) {
            reader.readSliceAll(self.recv_buf[0..plen]) catch return Error.RecvFailed;

            // Unmask if needed
            if (masked) {
                for (self.recv_buf[0..plen], 0..) |*b, i| {
                    b.* ^= mask_key[i % 4];
                }
            }
        }

        return .{ .opcode = opcode, .payload_len = plen };
    }

    fn sendPong(self: *XPlaneClient, payload: []const u8) !void {
        const conn = self.ws_connection orelse return;
        // Pong frame: FIN=1, opcode=0xA, MASK=1, zero mask key
        var header: [6]u8 = .{ 0x8A, 0x80, 0, 0, 0, 0 };
        header[1] |= @as(u8, @truncate(payload.len));
        const writer = conn.writer();
        writer.writeAll(header[0..6]) catch return;
        if (payload.len > 0) writer.writeAll(payload) catch return;
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
