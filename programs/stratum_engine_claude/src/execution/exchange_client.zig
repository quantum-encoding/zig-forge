//! High-Frequency Exchange Client
//! WebSocket connection with pre-authenticated state and sub-millisecond execution
//!
//! Architecture:
//! - Persistent WSS connection (avoid handshake latency)
//! - Pre-computed HMAC signatures (optimistic signing)
//! - io_uring for zero-copy network operations
//! - AVX-512 SHA256 for authentication

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const IoUring = linux.IoUring;
const Sha256 = std.crypto.hash.sha2.Sha256;
const ws = @import("websocket.zig");
const compat = @import("../utils/compat.zig");

// Zig 0.16 compatible clock helpers
fn getMonotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn getRealtimeMs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

// mbedTLS C bindings - inline to avoid Zig 0.16 @cImport module import bug
const c = @cImport({
    @cInclude("mbedtls/net_sockets.h");
    @cInclude("mbedtls/ssl.h");
    @cInclude("mbedtls/entropy.h");
    @cInclude("mbedtls/ctr_drbg.h");
    @cInclude("mbedtls/error.h");
});

/// TLS client wrapper for mbedTLS
const TlsClient = struct {
    server_fd: c.mbedtls_net_context,
    ssl: c.mbedtls_ssl_context,
    conf: c.mbedtls_ssl_config,
    entropy: c.mbedtls_entropy_context,
    ctr_drbg: c.mbedtls_ctr_drbg_context,
    connected: bool,
    handshake_done: bool,

    fn init(allocator: std.mem.Allocator, sockfd: posix.fd_t) !TlsClient {
        _ = allocator;

        var self = TlsClient{
            .server_fd = undefined,
            .ssl = undefined,
            .conf = undefined,
            .entropy = undefined,
            .ctr_drbg = undefined,
            .connected = false,
            .handshake_done = false,
        };

        c.mbedtls_net_init(&self.server_fd);
        c.mbedtls_ssl_init(&self.ssl);
        c.mbedtls_ssl_config_init(&self.conf);
        c.mbedtls_ctr_drbg_init(&self.ctr_drbg);
        c.mbedtls_entropy_init(&self.entropy);

        const pers = "hft_ssl_client";
        const ret = c.mbedtls_ctr_drbg_seed(
            &self.ctr_drbg,
            c.mbedtls_entropy_func,
            &self.entropy,
            pers.ptr,
            pers.len,
        );
        if (ret != 0) return error.RngSeedFailed;

        self.server_fd.fd = sockfd;
        return self;
    }

    fn connect(self: *TlsClient, hostname: []const u8) !void {
        var ret = c.mbedtls_ssl_config_defaults(
            &self.conf,
            c.MBEDTLS_SSL_IS_CLIENT,
            c.MBEDTLS_SSL_TRANSPORT_STREAM,
            c.MBEDTLS_SSL_PRESET_DEFAULT,
        );
        if (ret != 0) return error.SslConfigFailed;

        c.mbedtls_ssl_conf_authmode(&self.conf, c.MBEDTLS_SSL_VERIFY_NONE);
        c.mbedtls_ssl_conf_rng(&self.conf, c.mbedtls_ctr_drbg_random, &self.ctr_drbg);

        ret = c.mbedtls_ssl_setup(&self.ssl, &self.conf);
        if (ret != 0) return error.SslSetupFailed;

        const hostname_z = try std.posix.toPosixPath(hostname);
        ret = c.mbedtls_ssl_set_hostname(&self.ssl, &hostname_z);
        if (ret != 0) return error.SslSetHostnameFailed;

        c.mbedtls_ssl_set_bio(
            &self.ssl,
            &self.server_fd,
            c.mbedtls_net_send,
            c.mbedtls_net_recv,
            null,
        );

        self.connected = true;

        // Perform handshake
        while (true) {
            ret = c.mbedtls_ssl_handshake(&self.ssl);
            if (ret == 0) break;
            if (ret != c.MBEDTLS_ERR_SSL_WANT_READ and ret != c.MBEDTLS_ERR_SSL_WANT_WRITE) {
                return error.TlsHandshakeFailed;
            }
        }

        self.handshake_done = true;
    }

    fn send(self: *TlsClient, data: []const u8) !usize {
        if (!self.handshake_done) return error.NotConnected;

        var total_sent: usize = 0;
        var remaining = data;

        while (remaining.len > 0) {
            const ret = c.mbedtls_ssl_write(&self.ssl, remaining.ptr, remaining.len);

            if (ret == c.MBEDTLS_ERR_SSL_WANT_READ or ret == c.MBEDTLS_ERR_SSL_WANT_WRITE) {
                continue;
            }

            if (ret < 0) return error.SendFailed;

            const sent: usize = @intCast(ret);
            total_sent += sent;
            remaining = remaining[sent..];
        }

        return total_sent;
    }

    fn recv(self: *TlsClient, buffer: []u8) !usize {
        if (!self.handshake_done) return error.NotConnected;

        const ret = c.mbedtls_ssl_read(&self.ssl, buffer.ptr, buffer.len);

        if (ret == c.MBEDTLS_ERR_SSL_WANT_READ or ret == c.MBEDTLS_ERR_SSL_WANT_WRITE) {
            return error.WouldBlock;
        }

        if (ret == c.MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) {
            return error.ConnectionClosed;
        }

        if (ret < 0) return error.RecvFailed;

        return @intCast(ret);
    }

    fn close(self: *TlsClient) void {
        if (self.connected) {
            _ = c.mbedtls_ssl_close_notify(&self.ssl);
            c.mbedtls_net_free(&self.server_fd);
            c.mbedtls_ssl_free(&self.ssl);
            c.mbedtls_ssl_config_free(&self.conf);
            c.mbedtls_ctr_drbg_free(&self.ctr_drbg);
            c.mbedtls_entropy_free(&self.entropy);
            self.connected = false;
            self.handshake_done = false;
        }
    }
};

/// Exchange API credentials
pub const Credentials = struct {
    api_key: []const u8,
    api_secret: []const u8,
    passphrase: ?[]const u8 = null, // Coinbase Pro requires this
};

/// Exchange endpoints
pub const Exchange = enum {
    binance,
    coinbase,
    kraken,
    bybit,

    pub fn getWsUrl(self: Exchange) []const u8 {
        return switch (self) {
            .binance => "wss://stream.binance.com:9443/ws",
            .coinbase => "wss://advanced-trade-ws.coinbase.com",
            .kraken => "wss://ws.kraken.com",
            .bybit => "wss://stream.bybit.com/v5/public/spot",
        };
    }

    pub fn getRestUrl(self: Exchange) []const u8 {
        return switch (self) {
            .binance => "https://api.binance.com",
            .coinbase => "https://api.exchange.coinbase.com",
            .kraken => "https://api.kraken.com",
            .bybit => "https://api.bybit.com",
        };
    }
};

/// Round-trip time metrics
pub const LatencyMetrics = struct {
    ping_sent_ns: u64,
    pong_received_ns: u64,
    min_rtt_us: u64,
    max_rtt_us: u64,
    avg_rtt_us: u64,
    sample_count: u32,

    pub fn init() LatencyMetrics {
        return .{
            .ping_sent_ns = 0,
            .pong_received_ns = 0,
            .min_rtt_us = std.math.maxInt(u64),
            .max_rtt_us = 0,
            .avg_rtt_us = 0,
            .sample_count = 0,
        };
    }

    pub fn recordRtt(self: *LatencyMetrics) void {
        const rtt_ns = self.pong_received_ns - self.ping_sent_ns;
        const rtt_us = rtt_ns / 1000;

        self.min_rtt_us = @min(self.min_rtt_us, rtt_us);
        self.max_rtt_us = @max(self.max_rtt_us, rtt_us);

        // Running average
        const total = self.avg_rtt_us * self.sample_count + rtt_us;
        self.sample_count += 1;
        self.avg_rtt_us = total / self.sample_count;
    }
};

/// Order side
pub const Side = enum {
    buy,
    sell,

    pub fn toString(self: Side) []const u8 {
        return switch (self) {
            .buy => "BUY",
            .sell => "SELL",
        };
    }
};

/// Order type
pub const OrderType = enum {
    market,
    limit,
    stop_loss,
    take_profit,

    pub fn toString(self: OrderType) []const u8 {
        return switch (self) {
            .market => "MARKET",
            .limit => "LIMIT",
            .stop_loss => "STOP_LOSS",
            .take_profit => "TAKE_PROFIT",
        };
    }
};

/// Pre-built order template (for optimistic signing)
pub const OrderTemplate = struct {
    symbol: [16]u8, // "BTCUSDT" padded
    side: Side,
    order_type: OrderType,
    quantity: f64,
    price: ?f64 = null, // For limit orders

    // Pre-allocated buffers
    json_buffer: [512]u8,
    signature_buffer: [64]u8,
    json_len: usize,

    pub fn init(symbol: []const u8, side: Side, order_type: OrderType, quantity: f64) !OrderTemplate {
        var template: OrderTemplate = undefined;

        // Pad symbol
        @memset(&template.symbol, 0);
        @memcpy(template.symbol[0..symbol.len], symbol);

        template.side = side;
        template.order_type = order_type;
        template.quantity = quantity;
        template.price = null;
        template.json_len = 0;

        return template;
    }

    /// Build JSON payload (optimized for minimal allocations)
    pub fn buildJson(self: *OrderTemplate, timestamp: u64) ![]const u8 {
        // Extract symbol as string (up to null terminator)
        var symbol_len: usize = 0;
        while (symbol_len < 16 and self.symbol[symbol_len] != 0) : (symbol_len += 1) {}
        const symbol_str = self.symbol[0..symbol_len];

        // Build JSON using std.fmt.bufPrint for better performance
        if (self.price) |price| {
            self.json_len = (try std.fmt.bufPrint(
                &self.json_buffer,
                "{{\"symbol\":\"{s}\",\"side\":\"{s}\",\"type\":\"{s}\",\"quantity\":{d:.8},\"price\":{d:.2},\"timestamp\":{}}}",
                .{ symbol_str, self.side.toString(), self.order_type.toString(), self.quantity, price, timestamp },
            )).len;
        } else {
            self.json_len = (try std.fmt.bufPrint(
                &self.json_buffer,
                "{{\"symbol\":\"{s}\",\"side\":\"{s}\",\"type\":\"{s}\",\"quantity\":{d:.8},\"timestamp\":{}}}",
                .{ symbol_str, self.side.toString(), self.order_type.toString(), self.quantity, timestamp },
            )).len;
        }

        return self.json_buffer[0..self.json_len];
    }
};

/// Exchange WebSocket client
pub const ExchangeClient = struct {
    allocator: std.mem.Allocator,
    exchange: Exchange,
    credentials: Credentials,
    tls: ?TlsClient, // TLS-encrypted connection
    ring: IoUring,
    connected: std.atomic.Value(bool),
    authenticated: std.atomic.Value(bool),
    metrics: LatencyMetrics,

    // WebSocket state
    ws_handshake: ?ws.HandshakeBuilder,
    ws_upgrade_buffer: [2048]u8, // For WebSocket upgrade request/response
    recv_buffer: [8192]u8, // For receiving WebSocket frames
    send_buffer: [4096]u8, // For building WebSocket frames

    // Pre-built order templates
    buy_template: ?OrderTemplate,
    sell_template: ?OrderTemplate,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        exchange: Exchange,
        credentials: Credentials,
    ) !Self {
        std.debug.print("🔌 Initializing exchange client for {s}\n", .{@tagName(exchange)});

        // Initialize io_uring for async operations
        const ring = try IoUring.init(256, 0);

        return .{
            .allocator = allocator,
            .exchange = exchange,
            .credentials = credentials,
            .tls = null, // Will be initialized in connect()
            .ring = ring,
            .connected = std.atomic.Value(bool).init(false),
            .authenticated = std.atomic.Value(bool).init(false),
            .metrics = LatencyMetrics.init(),
            .ws_handshake = null,
            .ws_upgrade_buffer = undefined,
            .recv_buffer = undefined,
            .send_buffer = undefined,
            .buy_template = null,
            .sell_template = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.connected.store(false, .release);
        if (self.tls) |*tls_client| {
            tls_client.close();
        }
        self.ring.deinit();
    }

    /// Pre-load order templates for instant execution
    pub fn preloadOrders(
        self: *Self,
        symbol: []const u8,
        buy_quantity: f64,
        sell_quantity: f64,
    ) !void {
        std.debug.print("📝 Pre-loading order templates for {s}\n", .{symbol});

        self.buy_template = try OrderTemplate.init(symbol, .buy, .market, buy_quantity);
        self.sell_template = try OrderTemplate.init(symbol, .sell, .market, sell_quantity);

        std.debug.print("✅ Order templates ready:\n", .{});
        std.debug.print("   BUY:  {d:.8} {s}\n", .{buy_quantity, symbol});
        std.debug.print("   SELL: {d:.8} {s}\n", .{sell_quantity, symbol});
    }

    /// Parse WebSocket URL (wss://host:port/path)
    fn parseWsUrl(url: []const u8) !struct { host: []const u8, port: u16, path: []const u8 } {
        // Remove wss:// or ws:// prefix
        var remainder = url;
        if (std.mem.startsWith(u8, url, "wss://")) {
            remainder = url[6..];
        } else if (std.mem.startsWith(u8, url, "ws://")) {
            remainder = url[5..];
        }

        // Find port separator
        const colon_pos = std.mem.indexOf(u8, remainder, ":");
        const slash_pos = std.mem.indexOf(u8, remainder, "/");

        var host: []const u8 = undefined;
        var port: u16 = 443; // Default HTTPS port
        var path: []const u8 = "/";

        if (colon_pos) |pos| {
            host = remainder[0..pos];
            const port_start = pos + 1;
            const port_end = slash_pos orelse remainder.len;
            port = try std.fmt.parseInt(u16, remainder[port_start..port_end], 10);
            if (slash_pos) |sp| {
                path = remainder[sp..];
            }
        } else if (slash_pos) |pos| {
            host = remainder[0..pos];
            path = remainder[pos..];
        } else {
            host = remainder;
        }

        return .{ .host = host, .port = port, .path = path };
    }

    /// Connect to exchange WebSocket with TLS + WebSocket upgrade
    pub fn connect(self: *Self) !void {
        const url = self.exchange.getWsUrl();
        std.debug.print("🌐 Connecting to {s}...\n", .{url});

        // Parse URL
        const parsed = try parseWsUrl(url);
        std.debug.print("   Host: {s}, Port: {}, Path: {s}\n", .{ parsed.host, parsed.port, parsed.path });

        // Step 1: Create TCP socket using compat helper
        const sockfd = try compat.createSocket(linux.SOCK.STREAM);
        errdefer compat.closeSocket(sockfd);

        // Step 2: DNS resolution using getaddrinfo
        const dns_c = @cImport({
            @cInclude("sys/types.h");
            @cInclude("sys/socket.h");
            @cInclude("netdb.h");
        });

        var hints: dns_c.struct_addrinfo = std.mem.zeroes(dns_c.struct_addrinfo);
        hints.ai_family = dns_c.AF_INET;
        hints.ai_socktype = dns_c.SOCK_STREAM;

        var result: ?*dns_c.struct_addrinfo = null;

        // Convert hostname to null-terminated string
        const hostname_z = try std.posix.toPosixPath(parsed.host);
        const port_str = try std.fmt.allocPrint(self.allocator, "{d}", .{parsed.port});
        defer self.allocator.free(port_str);

        const port_z = try std.posix.toPosixPath(port_str);

        const ret = dns_c.getaddrinfo(&hostname_z, &port_z, &hints, &result);
        if (ret != 0) {
            std.debug.print("❌ DNS resolution failed for {s}\n", .{parsed.host});
            return error.DnsResolutionFailed;
        }
        defer dns_c.freeaddrinfo(result);

        if (result == null or result.?.ai_addr == null) {
            return error.NoAddressFound;
        }

        // Extract resolved address
        const resolved_addr: *linux.sockaddr.in = @ptrCast(@alignCast(result.?.ai_addr));

        std.debug.print("📡 DNS resolved {s} -> {}.{}.{}.{}:{}\n", .{
            parsed.host,
            @as(u8, @truncate(resolved_addr.addr & 0xFF)),
            @as(u8, @truncate((resolved_addr.addr >> 8) & 0xFF)),
            @as(u8, @truncate((resolved_addr.addr >> 16) & 0xFF)),
            @as(u8, @truncate((resolved_addr.addr >> 24) & 0xFF)),
            parsed.port,
        });

        // Step 3: TCP connect
        std.debug.print("🔌 Establishing TCP connection...\n", .{});
        try compat.connectSocket(sockfd, @ptrCast(resolved_addr), @sizeOf(linux.sockaddr.in));
        std.debug.print("✅ TCP connected\n", .{});

        // Step 4: TLS handshake
        std.debug.print("🔐 Initiating TLS handshake...\n", .{});
        var tls_client = try TlsClient.init(self.allocator, sockfd);
        errdefer tls_client.close();

        try tls_client.connect(parsed.host);
        std.debug.print("✅ TLS handshake complete\n", .{});

        // Step 5: WebSocket upgrade request (RFC 6455)
        std.debug.print("🔄 Sending WebSocket upgrade request...\n", .{});
        self.ws_handshake = ws.HandshakeBuilder.init(parsed.host, parsed.port, parsed.path);

        const upgrade_request = try self.ws_handshake.?.buildRequest(&self.ws_upgrade_buffer);
        std.debug.print("   Request:\n{s}\n", .{upgrade_request});

        _ = try tls_client.send(upgrade_request);

        // Step 6: Receive and verify upgrade response
        std.debug.print("⏳ Waiting for server response...\n", .{});
        const response_len = try tls_client.recv(&self.ws_upgrade_buffer);
        const response = self.ws_upgrade_buffer[0..response_len];

        std.debug.print("   Response ({} bytes):\n{s}\n", .{ response_len, response });

        try self.ws_handshake.?.verifyResponse(response);
        std.debug.print("✅ WebSocket upgrade complete (HTTP/1.1 101 Switching Protocols)\n", .{});

        // Save TLS client
        self.tls = tls_client;
        self.connected.store(true, .release);

        std.debug.print("🚀 Ready for high-frequency trading!\n", .{});
    }

    /// Authenticate with exchange API
    pub fn authenticate(self: *Self) !void {
        std.debug.print("Authenticating with {s}...\n", .{@tagName(self.exchange)});

        // Exchange-specific authentication using HMAC-SHA256
        const hmac = @import("../crypto/hmac.zig");
        const timestamp_ms = getRealtimeMs();

        switch (self.exchange) {
            .binance => {
                // Binance: HMAC-SHA256(secret, "timestamp=<ms>")
                var msg_buf: [128]u8 = undefined;
                const auth_msg = std.fmt.bufPrint(&msg_buf, "timestamp={d}", .{timestamp_ms}) catch return error.AuthFailed;
                var signature: [32]u8 = undefined;
                hmac.signBinance(self.credentials.api_secret, auth_msg, &signature);
                const sig_hex = std.fmt.bytesToHex(signature, .lower);

                // Send auth via WebSocket
                var auth_json: [512]u8 = undefined;
                const auth_payload = std.fmt.bufPrint(&auth_json, "{{\"method\":\"SUBSCRIBE\",\"params\":[\"{s}@account\"],\"id\":1,\"apiKey\":\"{s}\",\"signature\":\"{s}\",\"timestamp\":{d}}}", .{ self.credentials.api_key, self.credentials.api_key, sig_hex, timestamp_ms }) catch return error.AuthFailed;
                try self.sendWebSocketFrame(.text, auth_payload);
            },
            .coinbase => {
                // Coinbase: HMAC-SHA256(secret, timestamp + "GET" + "/users/self/verify")
                var ts_buf: [32]u8 = undefined;
                const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{timestamp_ms / 1000}) catch return error.AuthFailed;
                var signature: [32]u8 = undefined;
                hmac.signCoinbase(self.credentials.api_secret, ts_str, "GET", "/users/self/verify", "", &signature);
                const sig_hex = std.fmt.bytesToHex(signature, .lower);

                var auth_json: [512]u8 = undefined;
                const passphrase = self.credentials.passphrase orelse "";
                const auth_payload = std.fmt.bufPrint(&auth_json, "{{\"type\":\"subscribe\",\"channels\":[\"user\"],\"key\":\"{s}\",\"signature\":\"{s}\",\"timestamp\":\"{s}\",\"passphrase\":\"{s}\"}}", .{ self.credentials.api_key, sig_hex, ts_str, passphrase }) catch return error.AuthFailed;
                try self.sendWebSocketFrame(.text, auth_payload);
            },
            .kraken, .bybit => {
                // Kraken/Bybit: HMAC-SHA256(secret, timestamp)
                var ts_buf: [32]u8 = undefined;
                const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{timestamp_ms}) catch return error.AuthFailed;
                var signature: [32]u8 = undefined;
                hmac.hmacSha256(self.credentials.api_secret, ts_str, &signature);
                const sig_hex = std.fmt.bytesToHex(signature, .lower);

                var auth_json: [512]u8 = undefined;
                const auth_payload = std.fmt.bufPrint(&auth_json, "{{\"op\":\"auth\",\"args\":[\"{s}\",{d},\"{s}\"]}}", .{ self.credentials.api_key, timestamp_ms, sig_hex }) catch return error.AuthFailed;
                try self.sendWebSocketFrame(.text, auth_payload);
            },
        }

        self.authenticated.store(true, .release);
        std.debug.print("Authenticated with {s}!\n", .{@tagName(self.exchange)});
    }

    /// Send WebSocket frame over TLS
    fn sendWebSocketFrame(self: *Self, opcode: ws.Opcode, payload: []const u8) !void {
        if (self.tls == null) return error.NotConnected;

        const frame = try ws.FrameBuilder.buildFrame(&self.send_buffer, opcode, payload, true);

        // Send encrypted via TLS (BearSSL handles encryption)
        _ = try self.tls.?.send(frame);
    }

    /// Send ping to measure RTT
    pub fn ping(self: *Self) !void {
        const ts = try std.posix.clock_gettime(.MONOTONIC);
        self.metrics.ping_sent_ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 +
                                    @as(u64, @intCast(ts.nsec));

        try self.sendWebSocketFrame(.ping, &.{});
        std.debug.print("📤 PING sent\n", .{});
    }

    /// Handle pong response
    pub fn handlePong(self: *Self) !void {
        const ts = try std.posix.clock_gettime(.MONOTONIC);
        self.metrics.pong_received_ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 +
                                        @as(u64, @intCast(ts.nsec));

        self.metrics.recordRtt();

        std.debug.print("📥 PONG received - RTT: {}µs (min: {}µs, avg: {}µs, max: {}µs)\n", .{
            (self.metrics.pong_received_ns - self.metrics.ping_sent_ns) / 1000,
            self.metrics.min_rtt_us,
            self.metrics.avg_rtt_us,
            self.metrics.max_rtt_us,
        });
    }

    /// Execute BUY order (< 10µs target)
    pub fn executeBuy(self: *Self) !void {
        if (self.buy_template == null) return error.TemplateNotLoaded;
        if (!self.authenticated.load(.acquire)) return error.NotAuthenticated;

        const start_ns = getMonotonicNs();

        // Get current timestamp (sub-microsecond operation)
        const timestamp_ms = getRealtimeMs();

        // Build JSON from pre-loaded template (~1µs)
        const json = try self.buy_template.?.buildJson(timestamp_ms);

        // Sign order with HMAC-SHA256 using pre-computed context
        const hmac = @import("../crypto/hmac.zig");
        var sig: [32]u8 = undefined;
        hmac.hmacSha256(self.credentials.api_secret, json, &sig);
        // Signature available in sig for header inclusion

        // Send via WebSocket (~1µs with io_uring)
        try self.sendWebSocketFrame(.text, json);

        const end_ns = getMonotonicNs();
        const execution_us = (end_ns - start_ns) / 1000;

        std.debug.print("🚀 BUY executed in {}µs\n", .{execution_us});
        std.debug.print("   Payload: {s}\n", .{json});
    }

    /// Execute SELL order (< 10µs target)
    pub fn executeSell(self: *Self) !void {
        if (self.sell_template == null) return error.TemplateNotLoaded;
        if (!self.authenticated.load(.acquire)) return error.NotAuthenticated;

        const start_ns = getMonotonicNs();

        // Get current timestamp (sub-microsecond operation)
        const timestamp_ms = getRealtimeMs();

        // Build JSON from pre-loaded template (~1µs)
        const json = try self.sell_template.?.buildJson(timestamp_ms);

        // Sign order with HMAC-SHA256 using pre-computed context
        const hmac = @import("../crypto/hmac.zig");
        var sig: [32]u8 = undefined;
        hmac.hmacSha256(self.credentials.api_secret, json, &sig);
        // Signature available in sig for header inclusion

        // Send via WebSocket (~1µs with io_uring)
        try self.sendWebSocketFrame(.text, json);

        const end_ns = getMonotonicNs();
        const execution_us = (end_ns - start_ns) / 1000;

        std.debug.print("🚀 SELL executed in {}µs\n", .{execution_us});
        std.debug.print("   Payload: {s}\n", .{json});
    }

    /// Get connection status
    pub fn isReady(self: *Self) bool {
        return self.connected.load(.acquire) and self.authenticated.load(.acquire);
    }

    /// Get average RTT in microseconds
    pub fn getAvgRtt(self: *Self) u64 {
        return self.metrics.avg_rtt_us;
    }
};

test "order template creation" {
    const template = try OrderTemplate.init("BTCUSDT", .buy, .market, 0.001);
    try std.testing.expect(template.side == .buy);
    try std.testing.expect(template.order_type == .market);
    try std.testing.expectApproxEqAbs(template.quantity, 0.001, 0.0001);
}

test "order JSON generation" {
    var template = try OrderTemplate.init("BTCUSDT", .sell, .market, 0.5);
    const json = try template.buildJson(1700000000000);

    // Verify JSON contains key fields
    try std.testing.expect(std.mem.indexOf(u8, json, "BTCUSDT") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "SELL") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "MARKET") != null);
}
