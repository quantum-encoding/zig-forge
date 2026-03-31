//! Coinbase FIX 5.0 Client
//!
//! TCP+TLS client for connecting to Coinbase Exchange FIX gateway.
//! Handles connection management, message framing, and session lifecycle.
//!
//! Endpoints:
//! - Production: tcp+ssl://fix-ord.exchange.coinbase.com:6121
//! - Sandbox: tcp+ssl://fix-ord.sandbox.exchange.coinbase.com:6121
//!
//! TLS Support:
//! - Uses mbedTLS for cross-platform TLS (Linux, macOS, Windows)
//! - For Android without mbedTLS, TLS is stubbed out (use plain TCP)
//! - use_tls=false falls back to plain TCP (for testing only)

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const builtin = @import("builtin");
const fix = @import("fix_protocol_v5.zig");

// Use real TLS on desktop, stub on Android (unless mbedTLS is cross-compiled)
const TlsClient = if (builtin.abi == .android)
    @import("tls_stub.zig").TlsClient
else
    @import("tls_client.zig").TlsClient;

// libc imports for DNS resolution (not available on Android cross-compile without NDK sysroot)
const c = if (builtin.abi != .android) @cImport({
    @cInclude("netdb.h");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
}) else struct {
    // Stub types for Android - DNS not supported without NDK sysroot
    pub const struct_addrinfo = extern struct {
        ai_family: c_int = 0,
        ai_socktype: c_int = 0,
        ai_protocol: c_int = 0,
        ai_addrlen: c_uint = 0,
        ai_addr: ?*anyopaque = null,
        ai_canonname: ?[*:0]u8 = null,
        ai_next: ?*struct_addrinfo = null,
    };
    pub const AF_INET: c_int = 2;
    pub const SOCK_STREAM: c_int = 1;
    pub const IPPROTO_TCP: c_int = 6;
    pub fn getaddrinfo(_: ?[*:0]const u8, _: ?[*:0]const u8, _: ?*const struct_addrinfo, _: ?*?*struct_addrinfo) c_int {
        return -1; // Always fail on Android stub
    }
    pub fn freeaddrinfo(_: ?*struct_addrinfo) void {}
};

/// Flag indicating if full networking is available
const full_networking_available = builtin.abi != .android;

// =============================================================================
// Constants
// =============================================================================

/// Production FIX gateway
pub const PRODUCTION_HOST = "fix-ord.exchange.coinbase.com";
pub const PRODUCTION_PORT: u16 = 6121;

/// Sandbox FIX gateway
pub const SANDBOX_HOST = "fix-ord.sandbox.exchange.coinbase.com";
pub const SANDBOX_PORT: u16 = 6121;

/// Connection timeout in milliseconds
const CONNECT_TIMEOUT_MS: u32 = 10000;

/// Read timeout in milliseconds
const READ_TIMEOUT_MS: u32 = 5000;

/// Maximum message size (1MB)
const MAX_MESSAGE_SIZE: usize = 1024 * 1024;

// =============================================================================
// Connection State
// =============================================================================

/// Connection state
pub const ConnectionState = enum {
    Disconnected,
    Connecting,
    Connected,
    LoggingIn,
    LoggedIn,
    LoggingOut,
    Error,
};

/// Connection error
pub const ConnectionError = error{
    ConnectionFailed,
    ConnectionTimeout,
    TlsHandshakeFailed,
    AuthenticationFailed,
    SequenceGap,
    HeartbeatTimeout,
    InvalidMessage,
    Disconnected,
    SendFailed,
    ReceiveFailed,
    AlreadyConnected,
    NotConnected,
    DnsResolutionFailed,
};

// =============================================================================
// Execution Report
// =============================================================================

/// Parsed execution report from Coinbase
pub const ExecutionReport = struct {
    order_id: []const u8,
    cl_ord_id: []const u8,
    exec_id: []const u8,
    exec_type: fix.ExecType,
    ord_status: fix.OrdStatus,
    symbol: []const u8,
    side: fix.Side,
    leaves_qty: f64,
    cum_qty: f64,
    avg_px: f64,
    last_qty: ?f64,
    last_px: ?f64,
    text: ?[]const u8,

    pub fn fromMessage(allocator: std.mem.Allocator, msg: fix.ParsedMessage) !ExecutionReport {
        const order_id = msg.getField(fix.Tag.OrderID) orelse return error.MissingField;
        const cl_ord_id = msg.getField(fix.Tag.ClOrdID) orelse return error.MissingField;
        const exec_id = msg.getField(fix.Tag.ExecID) orelse return error.MissingField;
        const symbol = msg.getField(fix.Tag.Symbol) orelse return error.MissingField;

        const exec_type_char = msg.getField(fix.Tag.ExecType) orelse return error.MissingField;
        const exec_type = fix.ExecType.fromChar(exec_type_char[0]) orelse return error.InvalidField;

        const ord_status_char = msg.getField(fix.Tag.OrdStatus) orelse return error.MissingField;
        const ord_status = fix.OrdStatus.fromChar(ord_status_char[0]) orelse return error.InvalidField;

        const side_char = msg.getField(fix.Tag.Side) orelse return error.MissingField;
        const side: fix.Side = if (side_char[0] == '1') .Buy else .Sell;

        return ExecutionReport{
            .order_id = try allocator.dupe(u8, order_id),
            .cl_ord_id = try allocator.dupe(u8, cl_ord_id),
            .exec_id = try allocator.dupe(u8, exec_id),
            .exec_type = exec_type,
            .ord_status = ord_status,
            .symbol = try allocator.dupe(u8, symbol),
            .side = side,
            .leaves_qty = msg.getFloatField(fix.Tag.LeavesQty) orelse 0,
            .cum_qty = msg.getFloatField(fix.Tag.CumQty) orelse 0,
            .avg_px = msg.getFloatField(fix.Tag.AvgPx) orelse 0,
            .last_qty = msg.getFloatField(fix.Tag.LastQty),
            .last_px = msg.getFloatField(fix.Tag.LastPx),
            .text = if (msg.getField(fix.Tag.Text)) |t| try allocator.dupe(u8, t) else null,
        };
    }
};

// =============================================================================
// Message Callback
// =============================================================================

/// Callback for received messages
pub const MessageCallback = *const fn (msg_type: fix.MsgType, msg: fix.ParsedMessage, user_data: ?*anyopaque) void;

// =============================================================================
// Coinbase FIX Client
// =============================================================================

/// Coinbase FIX 5.0 Client
pub const CoinbaseFIXClient = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    session: fix.CoinbaseSession,
    state: ConnectionState,

    // Network (TLS or plain TCP)
    tls_client: ?TlsClient,
    socket: ?linux.fd_t,
    use_sandbox: bool,
    use_tls: bool,

    // Callbacks
    on_message: ?MessageCallback,
    callback_user_data: ?*anyopaque,

    // Statistics
    messages_sent: u64,
    messages_received: u64,
    orders_placed: u64,
    orders_filled: u64,
    orders_canceled: u64,
    last_error: ?[]const u8,

    // Read buffer
    read_buffer: [MAX_MESSAGE_SIZE]u8,
    read_buffer_pos: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        credentials: fix.CoinbaseCredentials,
        use_sandbox: bool,
    ) Self {
        return initWithTls(allocator, credentials, use_sandbox, true);
    }

    /// Initialize with explicit TLS option
    pub fn initWithTls(
        allocator: std.mem.Allocator,
        credentials: fix.CoinbaseCredentials,
        use_sandbox: bool,
        use_tls: bool,
    ) Self {
        return .{
            .allocator = allocator,
            .session = fix.CoinbaseSession.init(allocator, credentials),
            .state = .Disconnected,
            .tls_client = null,
            .socket = null,
            .use_sandbox = use_sandbox,
            .use_tls = use_tls,
            .on_message = null,
            .callback_user_data = null,
            .messages_sent = 0,
            .messages_received = 0,
            .orders_placed = 0,
            .orders_filled = 0,
            .orders_canceled = 0,
            .last_error = null,
            .read_buffer = undefined,
            .read_buffer_pos = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.disconnect();
        if (self.tls_client) |*tls| {
            tls.deinit();
            self.tls_client = null;
        }
        if (self.last_error) |err| {
            self.allocator.free(err);
        }
    }

    /// Set message callback
    pub fn setCallback(self: *Self, callback: MessageCallback, user_data: ?*anyopaque) void {
        self.on_message = callback;
        self.callback_user_data = user_data;
    }

    /// Connect to Coinbase FIX gateway
    pub fn connect(self: *Self) !void {
        if (self.state != .Disconnected) {
            return error.AlreadyConnected;
        }

        self.state = .Connecting;

        const host = if (self.use_sandbox) SANDBOX_HOST else PRODUCTION_HOST;
        const port = if (self.use_sandbox) SANDBOX_PORT else PRODUCTION_PORT;

        // On Android without full networking support, connections are not available
        if (!full_networking_available) {
            self.state = .Error;
            std.debug.print("FIX Client: Networking not available on this platform\n", .{});
            return error.ConnectionFailed;
        }

        if (self.use_tls) {
            // Use TLS connection via mbedTLS
            self.tls_client = TlsClient.init();

            self.tls_client.?.configure() catch {
                self.state = .Error;
                std.debug.print("FIX Client: TLS configuration failed\n", .{});
                return error.TlsHandshakeFailed;
            };

            self.tls_client.?.connect(host, port) catch |err| {
                self.state = .Error;
                std.debug.print("FIX Client: TLS connect failed to {s}:{d}: {}\n", .{ host, port, err });
                return error.TlsHandshakeFailed;
            };

            self.state = .Connected;
            std.debug.print("FIX Client: Connected to {s}:{d} (TLS)\n", .{ host, port });
        } else if (comptime full_networking_available) {
            // Plain TCP connection (for testing only) - only on platforms with full networking
            const sock_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
            if (@as(isize, @bitCast(sock_rc)) < 0) {
                self.state = .Error;
                return error.ConnectionFailed;
            }
            const sock: linux.fd_t = @intCast(sock_rc);
            errdefer _ = linux.close(sock);

            // DNS resolution using libc getaddrinfo
            var hints: c.struct_addrinfo = std.mem.zeroes(c.struct_addrinfo);
            hints.ai_family = c.AF_INET; // IPv4
            hints.ai_socktype = c.SOCK_STREAM;
            hints.ai_protocol = c.IPPROTO_TCP;

            // Convert port to string
            var port_str: [8]u8 = undefined;
            const port_slice = std.fmt.bufPrint(&port_str, "{d}", .{port}) catch {
                self.state = .Error;
                return error.ConnectionFailed;
            };

            // Null-terminate strings for C
            var host_buf: [256]u8 = undefined;
            if (host.len >= host_buf.len) {
                self.state = .Error;
                return error.ConnectionFailed;
            }
            @memcpy(host_buf[0..host.len], host);
            host_buf[host.len] = 0;

            var port_buf: [8]u8 = undefined;
            @memcpy(port_buf[0..port_slice.len], port_slice);
            port_buf[port_slice.len] = 0;

            var result: ?*c.struct_addrinfo = null;
            const gai_ret = c.getaddrinfo(&host_buf, &port_buf, &hints, &result);

            if (gai_ret != 0) {
                self.state = .Error;
                std.debug.print("FIX Client: DNS resolution failed for {s}: {d}\n", .{ host, gai_ret });
                return error.ConnectionFailed;
            }
            defer c.freeaddrinfo(result);

            if (result == null) {
                self.state = .Error;
                return error.ConnectionFailed;
            }

            // Connect to the resolved address
            const addr_ptr: *const linux.sockaddr = @ptrCast(result.?.ai_addr);
            const addr_len: linux.socklen_t = @intCast(result.?.ai_addrlen);

            const conn_rc = linux.connect(sock, addr_ptr, addr_len);
            if (@as(isize, @bitCast(conn_rc)) < 0) {
                self.state = .Error;
                std.debug.print("FIX Client: TCP connect failed to {s}:{d}\n", .{ host, port });
                return error.ConnectionFailed;
            }

            self.socket = sock;

            // Set socket options for better performance
            const enable: c_int = 1;
            // Use IPPROTO_TCP (6) and TCP_NODELAY (1) directly
            const enable_bytes = std.mem.asBytes(&enable);
            _ = linux.setsockopt(sock, linux.IPPROTO.TCP, linux.TCP.NODELAY, enable_bytes.ptr, @intCast(enable_bytes.len));

            self.state = .Connected;
            std.debug.print("FIX Client: Connected to {s}:{d} (TCP, TLS disabled)\n", .{ host, port });
        }
    }

    /// Login to Coinbase
    pub fn login(self: *Self) !void {
        if (self.state != .Connected) {
            return error.NotConnected;
        }

        self.state = .LoggingIn;

        // Create and send Logon message
        const logon_msg = try self.session.createLogon();
        defer self.allocator.free(logon_msg);

        try self.sendRaw(logon_msg);

        std.debug.print("FIX Client: Sent Logon message\n", .{});

        // Wait for Logon response
        var response = try self.receiveMessage();
        defer response.deinit();

        if (response.msg_type == .Logon) {
            self.state = .LoggedIn;
            self.session.is_connected = true;
            std.debug.print("FIX Client: Logged in successfully\n", .{});
        } else if (response.msg_type == .Logout) {
            const text = response.getField(fix.Tag.Text) orelse "Unknown error";
            self.setError(text);
            self.state = .Error;
            return error.AuthenticationFailed;
        } else {
            self.state = .Error;
            return error.InvalidMessage;
        }
    }

    /// Disconnect from Coinbase
    pub fn disconnect(self: *Self) void {
        // Send Logout if connected
        if (self.state == .LoggedIn) {
            self.state = .LoggingOut;
            if (self.session.createLogout(null)) |logout_msg| {
                self.sendRaw(logout_msg) catch {};
                self.allocator.free(logout_msg);
            } else |_| {}
        }

        // Close TLS connection
        if (self.tls_client) |*tls| {
            tls.close();
        }

        // Close plain socket
        if (self.socket) |sock| {
            _ = linux.close(sock);
            self.socket = null;
        }

        self.state = .Disconnected;
        self.session.is_connected = false;
        std.debug.print("FIX Client: Disconnected\n", .{});
    }

    /// Send a new order
    pub fn sendOrder(
        self: *Self,
        cl_ord_id: []const u8,
        symbol: []const u8,
        side: fix.Side,
        order_type: fix.OrdType,
        quantity: f64,
        price: ?f64,
        time_in_force: fix.TimeInForce,
    ) !void {
        if (self.state != .LoggedIn) {
            return error.NotConnected;
        }

        const msg = try self.session.createNewOrder(
            cl_ord_id,
            symbol,
            side,
            order_type,
            quantity,
            price,
            time_in_force,
        );
        defer self.allocator.free(msg);

        try self.sendRaw(msg);
        self.orders_placed += 1;

        std.debug.print("FIX Client: Sent order {s}\n", .{cl_ord_id});
    }

    /// Cancel an order
    pub fn cancelOrder(
        self: *Self,
        cl_ord_id: []const u8,
        orig_cl_ord_id: []const u8,
        order_id: []const u8,
        symbol: []const u8,
    ) !void {
        if (self.state != .LoggedIn) {
            return error.NotConnected;
        }

        const msg = try self.session.createCancelOrder(
            cl_ord_id,
            orig_cl_ord_id,
            order_id,
            symbol,
        );
        defer self.allocator.free(msg);

        try self.sendRaw(msg);
        self.orders_canceled += 1;

        std.debug.print("FIX Client: Sent cancel for {s}\n", .{orig_cl_ord_id});
    }

    /// Send heartbeat
    pub fn sendHeartbeat(self: *Self, test_req_id: ?[]const u8) !void {
        if (self.state != .LoggedIn) {
            return error.NotConnected;
        }

        const msg = try self.session.createHeartbeat(test_req_id);
        defer self.allocator.free(msg);

        try self.sendRaw(msg);
    }

    /// Process incoming messages (non-blocking poll)
    pub fn poll(self: *Self) !?fix.ParsedMessage {
        if (self.state != .LoggedIn) {
            return null;
        }

        // Check if we need to send heartbeat
        if (self.session.needsHeartbeat()) {
            try self.sendHeartbeat(null);
        }

        // Try to receive a message (non-blocking)
        return self.receiveMessageNonBlocking();
    }

    /// Run event loop (blocking)
    pub fn run(self: *Self) !void {
        while (self.state == .LoggedIn) {
            // Check heartbeat
            if (self.session.needsHeartbeat()) {
                try self.sendHeartbeat(null);
            }

            // Receive and process messages
            if (try self.receiveMessageNonBlocking()) |msg| {
                defer msg.deinit();
                try self.handleMessage(msg);
            }

            // Small sleep to prevent busy-waiting
            std.time.sleep(1_000_000); // 1ms
        }
    }

    // =========================================================================
    // Private Methods
    // =========================================================================

    fn sendRaw(self: *Self, data: []const u8) !void {
        if (self.use_tls) {
            // TLS send
            if (self.tls_client) |*tls| {
                _ = tls.write(data) catch return error.SendFailed;
            } else {
                return error.NotConnected;
            }
        } else {
            // Plain TCP send
            const sock = self.socket orelse return error.NotConnected;

            var total_written: usize = 0;
            while (total_written < data.len) {
                const remaining = data[total_written..];
                const send_rc = linux.sendto(sock, remaining.ptr, remaining.len, 0, null, 0);
                const written: isize = @bitCast(send_rc);
                if (written <= 0) return error.SendFailed;
                total_written += @intCast(written);
            }
        }

        self.messages_sent += 1;
    }

    fn receiveMessage(self: *Self) !fix.ParsedMessage {
        // Read until we have a complete message (ends with 10=XXX\x01)
        while (true) {
            var bytes_read: usize = 0;

            if (self.use_tls) {
                // TLS receive
                if (self.tls_client) |*tls| {
                    bytes_read = tls.read(self.read_buffer[self.read_buffer_pos..]) catch |err| {
                        if (err == error.ConnectionClosed) return error.Disconnected;
                        return error.ReceiveFailed;
                    };
                } else {
                    return error.NotConnected;
                }
            } else {
                // Plain TCP receive
                const sock = self.socket orelse return error.NotConnected;
                const buf = self.read_buffer[self.read_buffer_pos..];
                const recv_rc = linux.recvfrom(sock, buf.ptr, buf.len, 0, null, null);
                const recv_result: isize = @bitCast(recv_rc);
                if (recv_result < 0) return error.ReceiveFailed;
                bytes_read = @intCast(recv_result);
            }

            if (bytes_read == 0) {
                return error.Disconnected;
            }

            self.read_buffer_pos += bytes_read;

            // Check if we have a complete message
            if (self.findMessageEnd()) |end_pos| {
                const msg_data = self.read_buffer[0..end_pos];
                const msg = try fix.parseMessage(self.allocator, msg_data);

                // Move remaining data to start of buffer
                const remaining = self.read_buffer_pos - end_pos;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, self.read_buffer[0..remaining], self.read_buffer[end_pos..self.read_buffer_pos]);
                }
                self.read_buffer_pos = remaining;

                self.messages_received += 1;
                return msg;
            }
        }
    }

    fn receiveMessageNonBlocking(self: *Self) !?fix.ParsedMessage {
        if (self.use_tls) {
            // For TLS, get the underlying socket for polling
            if (self.tls_client) |*tls| {
                const tls_sock = tls.getSocket() orelse return null;

                // Use poll to check if data is available
                var poll_fds = [_]posix.pollfd{.{
                    .fd = tls_sock,
                    .events = posix.POLL.IN,
                    .revents = 0,
                }};

                const ready = posix.poll(&poll_fds, 0) catch return null;
                if (ready == 0) return null;

                if (poll_fds[0].revents & posix.POLL.IN != 0) {
                    return try self.receiveMessage();
                }
            }
            return null;
        } else {
            // Plain TCP
            const sock = self.socket orelse return null;

            // Use poll to check if data is available
            var poll_fds = [_]posix.pollfd{.{
                .fd = sock,
                .events = posix.POLL.IN,
                .revents = 0,
            }};

            const ready = posix.poll(&poll_fds, 0) catch return null;
            if (ready == 0) return null;

            if (poll_fds[0].revents & posix.POLL.IN != 0) {
                return try self.receiveMessage();
            }

            return null;
        }
    }

    fn findMessageEnd(self: Self) ?usize {
        // Look for checksum field: "10=XXX\x01"
        const data = self.read_buffer[0..self.read_buffer_pos];

        var i: usize = 0;
        while (i + 6 < data.len) : (i += 1) {
            if (data[i] == '1' and data[i + 1] == '0' and data[i + 2] == '=') {
                // Find the SOH after checksum
                var j = i + 3;
                while (j < data.len) : (j += 1) {
                    if (data[j] == fix.SOH) {
                        return j + 1;
                    }
                }
            }
        }

        return null;
    }

    fn handleMessage(self: *Self, msg: fix.ParsedMessage) !void {
        switch (msg.msg_type) {
            .Heartbeat => {
                // Heartbeat received, nothing to do
            },
            .TestRequest => {
                // Respond with heartbeat containing TestReqID
                const test_req_id = msg.getField(fix.Tag.TestReqID);
                try self.sendHeartbeat(test_req_id);
            },
            .ExecutionReport => {
                // Parse execution report
                if (ExecutionReport.fromMessage(self.allocator, msg)) |exec_report| {
                    _ = exec_report;
                    if (msg.getField(fix.Tag.ExecType)) |exec_type| {
                        if (exec_type[0] == 'F') { // Trade
                            self.orders_filled += 1;
                        }
                    }
                } else |_| {}
            },
            .Reject, .OrderCancelReject, .BusinessMessageReject => {
                // Handle rejection
                if (msg.getField(fix.Tag.Text)) |text| {
                    self.setError(text);
                }
            },
            .Logout => {
                // Server initiated logout
                self.state = .Disconnected;
                self.session.is_connected = false;
            },
            else => {},
        }

        // Call user callback
        if (self.on_message) |callback| {
            callback(msg.msg_type, msg, self.callback_user_data);
        }
    }

    fn setError(self: *Self, err: []const u8) void {
        if (self.last_error) |e| {
            self.allocator.free(e);
        }
        self.last_error = self.allocator.dupe(u8, err) catch null;
    }

    // =========================================================================
    // Public Getters
    // =========================================================================

    pub fn isConnected(self: Self) bool {
        return self.state == .LoggedIn;
    }

    pub fn getState(self: Self) ConnectionState {
        return self.state;
    }

    pub fn getStats(self: Self) struct {
        messages_sent: u64,
        messages_received: u64,
        orders_placed: u64,
        orders_filled: u64,
        orders_canceled: u64,
    } {
        return .{
            .messages_sent = self.messages_sent,
            .messages_received = self.messages_received,
            .orders_placed = self.orders_placed,
            .orders_filled = self.orders_filled,
            .orders_canceled = self.orders_canceled,
        };
    }

    pub fn getLastError(self: Self) ?[]const u8 {
        return self.last_error;
    }
};

// =============================================================================
// Demo
// =============================================================================

pub fn demo() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("\n=== Coinbase FIX 5.0 Client Demo ===\n\n", .{});

    // Create credentials (replace with real values)
    const credentials = fix.CoinbaseCredentials{
        .api_key = "your-api-key",
        .api_secret = "your-base64-secret",
        .passphrase = "your-passphrase",
    };

    // Create client (using sandbox)
    var client = CoinbaseFIXClient.init(allocator, credentials, true);
    defer client.deinit();

    std.debug.print("Created FIX client for sandbox environment\n", .{});
    std.debug.print("Host: {s}:{d}\n", .{ SANDBOX_HOST, SANDBOX_PORT });

    // In a real scenario, you would:
    // 1. client.connect()
    // 2. client.login()
    // 3. client.sendOrder(...)
    // 4. client.poll() or client.run()
    // 5. client.disconnect()

    std.debug.print("\n=== FIX 5.0 Client Capabilities ===\n", .{});
    std.debug.print("✓ FIX 5.0 SP2 protocol (FIXT.1.1 session)\n", .{});
    std.debug.print("✓ HMAC-SHA256 authentication\n", .{});
    std.debug.print("✓ TCP connection management\n", .{});
    std.debug.print("✓ Session sequence numbers\n", .{});
    std.debug.print("✓ Heartbeat mechanism\n", .{});
    std.debug.print("✓ Order placement (NewOrderSingle)\n", .{});
    std.debug.print("✓ Order cancellation (OrderCancelRequest)\n", .{});
    std.debug.print("✓ Execution report parsing\n", .{});
    std.debug.print("✓ Message callbacks\n", .{});
    std.debug.print("\nNote: TLS support requires additional library integration\n", .{});
}

test "client initialization" {
    const allocator = std.testing.allocator;

    const credentials = fix.CoinbaseCredentials{
        .api_key = "test-key",
        .api_secret = "dGVzdC1zZWNyZXQ=", // "test-secret" in base64
        .passphrase = "test-pass",
    };

    var client = CoinbaseFIXClient.init(allocator, credentials, true);
    defer client.deinit();

    try std.testing.expect(client.state == .Disconnected);
    try std.testing.expect(!client.isConnected());
}
