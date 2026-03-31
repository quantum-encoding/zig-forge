const std = @import("std");
const c = @cImport({
    @cInclude("libwebsockets.h");
});

// Workaround for LWS_PRE macro issue in Zig 0.16
const LWS_PRE = 16;

/// Production-grade WebSocket client using libwebsockets
pub const WebSocketClient = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    context: ?*c.lws_context,
    wsi: ?*c.lws,
    protocols: [2]c.lws_protocols,

    // Connection state
    connected: std.atomic.Value(bool),
    ready: std.atomic.Value(bool),

    // Callbacks
    on_message: ?*const fn (user: ?*anyopaque, data: []const u8) void,
    on_connect: ?*const fn (user: ?*anyopaque) void,
    on_disconnect: ?*const fn (user: ?*anyopaque) void,
    on_error: ?*const fn (user: ?*anyopaque, err: []const u8) void,

    // User data pointer
    user: ?*anyopaque,

    // Message buffer
    rx_buffer: [65536]u8,
    tx_buffer: [65536]u8,
    pending_writes: std.ArrayList([]const u8),

    // Connection info
    host: []const u8,
    port: u16,
    path: []const u8,
    use_ssl: bool,

    // Stats
    messages_sent: std.atomic.Value(u64),
    messages_received: std.atomic.Value(u64),
    bytes_sent: std.atomic.Value(u64),
    bytes_received: std.atomic.Value(u64),

    const ClientData = struct {
        client: *WebSocketClient,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .context = null,
            .wsi = null,
            .protocols = undefined,
            .connected = std.atomic.Value(bool).init(false),
            .ready = std.atomic.Value(bool).init(false),
            .on_message = null,
            .on_connect = null,
            .on_disconnect = null,
            .on_error = null,
            .user = null,
            .rx_buffer = undefined,
            .tx_buffer = undefined,
            .pending_writes = std.ArrayList([]const u8).empty,
            .host = "",
            .port = 443,
            .path = "/",
            .use_ssl = true,
            .messages_sent = std.atomic.Value(u64).init(0),
            .messages_received = std.atomic.Value(u64).init(0),
            .bytes_sent = std.atomic.Value(u64).init(0),
            .bytes_received = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *Self) void {
        self.disconnect();
        self.pending_writes.deinit(self.allocator);
    }

    /// Configure connection parameters
    pub fn configure(
        self: *Self,
        host: []const u8,
        port: u16,
        path: []const u8,
        use_ssl: bool,
    ) void {
        self.host = host;
        self.port = port;
        self.path = path;
        self.use_ssl = use_ssl;
    }

    /// Set callback functions
    pub fn setCallbacks(
        self: *Self,
        on_message: ?*const fn (user: ?*anyopaque, data: []const u8) void,
        on_connect: ?*const fn (user: ?*anyopaque) void,
        on_disconnect: ?*const fn (user: ?*anyopaque) void,
        on_error: ?*const fn (user: ?*anyopaque, err: []const u8) void,
    ) void {
        self.on_message = on_message;
        self.on_connect = on_connect;
        self.on_disconnect = on_disconnect;
        self.on_error = on_error;
    }

    /// Connect to WebSocket server
    pub fn connect(self: *Self) !void {
        if (self.connected.load(.acquire)) {
            return error.AlreadyConnected;
        }

        // Setup protocols
        self.protocols[0] = c.lws_protocols{
            .name = "alpaca-stream",
            .callback = websocketCallback,
            .per_session_data_size = @sizeOf(ClientData),
            .rx_buffer_size = 65536,
            .id = 0,
            .user = self,
            .tx_packet_size = 0,
        };
        self.protocols[1] = c.lws_protocols{
            .name = null,
            .callback = null,
            .per_session_data_size = 0,
            .rx_buffer_size = 0,
            .id = 0,
            .user = null,
            .tx_packet_size = 0,
        };

        // Create context
        var info: c.lws_context_creation_info = std.mem.zeroes(c.lws_context_creation_info);
        info.port = c.CONTEXT_PORT_NO_LISTEN;
        info.protocols = &self.protocols[0];
        info.options = c.LWS_SERVER_OPTION_DO_SSL_GLOBAL_INIT;
        info.user = self;

        self.context = c.lws_create_context(&info);
        if (self.context == null) {
            return error.ContextCreationFailed;
        }

        // Connect to server
        var ccinfo: c.lws_client_connect_info = std.mem.zeroes(c.lws_client_connect_info);
        ccinfo.context = self.context;
        ccinfo.address = self.host.ptr;
        ccinfo.port = @intCast(self.port);
        ccinfo.path = self.path.ptr;
        ccinfo.host = ccinfo.address;
        ccinfo.origin = ccinfo.address;
        ccinfo.protocol = self.protocols[0].name;
        ccinfo.ssl_connection = if (self.use_ssl) c.LCCSCF_USE_SSL else 0;
        ccinfo.userdata = self;

        self.wsi = c.lws_client_connect_via_info(&ccinfo);
        if (self.wsi == null) {
            c.lws_context_destroy(self.context);
            self.context = null;
            return error.ConnectionFailed;
        }

        self.connected.store(true, .release);

        // Start service loop in separate thread
        const thread = try std.Thread.spawn(.{}, serviceLoop, .{self});
        thread.detach();
    }

    /// Disconnect from WebSocket server
    pub fn disconnect(self: *Self) void {
        if (!self.connected.load(.acquire)) return;

        self.connected.store(false, .release);
        self.ready.store(false, .release);

        if (self.context) |ctx| {
            c.lws_context_destroy(ctx);
            self.context = null;
            self.wsi = null;
        }

        if (self.on_disconnect) |callback| {
            callback(self.user);
        }
    }

    /// Send message through WebSocket
    pub fn send(self: *Self, message: []const u8) !void {
        if (!self.ready.load(.acquire)) {
            return error.NotConnected;
        }

        // Queue message for sending
        const msg_copy = try self.allocator.dupe(u8, message);
        try self.pending_writes.append(self.allocator, msg_copy);

        // Request write callback
        if (self.wsi) |wsi| {
            _ = c.lws_callback_on_writable(wsi);
        }
    }

    /// Service loop for handling WebSocket events
    fn serviceLoop(self: *Self) void {
        while (self.connected.load(.acquire)) {
            if (self.context) |ctx| {
                _ = c.lws_service(ctx, 50);
            } else {
                break;
            }
        }
    }

    /// WebSocket callback function
    fn websocketCallback(
        wsi: ?*c.lws,
        reason: c.enum_lws_callback_reasons,
        user: ?*anyopaque,
        in: ?*anyopaque,
        len: usize,
    ) callconv(.c) c_int {
        _ = user;

        const protocol = c.lws_get_protocol(wsi);
        if (protocol == null) return 0;

        const self = @as(*WebSocketClient, @ptrCast(@alignCast(protocol.*.user orelse return 0)));

        switch (reason) {
            c.LWS_CALLBACK_CLIENT_ESTABLISHED => {
                std.debug.print("✅ WebSocket connection established\n", .{});
                self.ready.store(true, .release);
                if (self.on_connect) |callback| {
                    callback(self.user);
                }
            },

            c.LWS_CALLBACK_CLIENT_RECEIVE => {
                if (in != null and len > 0) {
                    const data = @as([*]u8, @ptrCast(in))[0..len];
                    _ = self.messages_received.fetchAdd(1, .monotonic);
                    _ = self.bytes_received.fetchAdd(len, .monotonic);

                    if (self.on_message) |callback| {
                        callback(self.user, data);
                    }
                }
            },

            c.LWS_CALLBACK_CLIENT_WRITEABLE => {
                if (self.pending_writes.items.len > 0) {
                    const message = self.pending_writes.orderedRemove(0);
                    defer self.allocator.free(message);

                    // Prepare buffer with LWS_PRE space
                    var buf: [65536]u8 = undefined;
                    const pre = LWS_PRE;
                    @memcpy(buf[pre..pre + message.len], message);

                    const written = c.lws_write(
                        wsi,
                        &buf[pre],
                        message.len,
                        c.LWS_WRITE_TEXT,
                    );

                    if (written > 0) {
                        _ = self.messages_sent.fetchAdd(1, .monotonic);
                        _ = self.bytes_sent.fetchAdd(@intCast(written), .monotonic);
                    }

                    // Request next write if more pending
                    if (self.pending_writes.items.len > 0) {
                        _ = c.lws_callback_on_writable(wsi);
                    }
                }
            },

            c.LWS_CALLBACK_CLIENT_CONNECTION_ERROR => {
                std.debug.print("❌ WebSocket connection error\n", .{});
                self.ready.store(false, .release);
                if (self.on_error) |callback| {
                    callback(self.user, "Connection error");
                }
            },

            c.LWS_CALLBACK_CLIENT_CLOSED => {
                std.debug.print("🔌 WebSocket connection closed\n", .{});
                self.ready.store(false, .release);
                if (self.on_disconnect) |callback| {
                    callback(self.user);
                }
            },

            else => {},
        }

        return 0;
    }

    /// Get connection statistics
    pub fn getStats(self: *const Self) ConnectionStats {
        return .{
            .connected = self.connected.load(.acquire),
            .ready = self.ready.load(.acquire),
            .messages_sent = self.messages_sent.load(.acquire),
            .messages_received = self.messages_received.load(.acquire),
            .bytes_sent = self.bytes_sent.load(.acquire),
            .bytes_received = self.bytes_received.load(.acquire),
        };
    }

    pub const ConnectionStats = struct {
        connected: bool,
        ready: bool,
        messages_sent: u64,
        messages_received: u64,
        bytes_sent: u64,
        bytes_received: u64,
    };
};