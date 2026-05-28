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
    @cInclude("mbedtls/x509_crt.h");
});

// Mirror the system CA bundle probe in tls_mbedtls.zig. Kept inline here
// because this file uses its own @cImport (Zig 0.16 module-import bug
// per the file header) and can't share the helper.
const system_ca_bundle_candidates = [_][]const u8{
    "/etc/ssl/cert.pem",
    "/etc/ssl/certs/ca-certificates.crt",
    "/etc/pki/tls/certs/ca-bundle.crt",
    "/etc/ssl/certs/ca-bundle.crt",
};

fn loadSystemCaChain(cacert: *c.mbedtls_x509_crt) ![]const u8 {
    for (system_ca_bundle_candidates) |path| {
        const path_z = std.posix.toPosixPath(path) catch continue;
        const ret = c.mbedtls_x509_crt_parse_file(cacert, &path_z);
        if (ret == 0) return path;
        c.mbedtls_x509_crt_free(cacert);
        c.mbedtls_x509_crt_init(cacert);
    }
    return error.NoSystemCaBundle;
}

/// TLS client wrapper for mbedTLS — VERIFY_REQUIRED, no insecure mode.
const TlsClient = struct {
    server_fd: c.mbedtls_net_context,
    ssl: c.mbedtls_ssl_context,
    conf: c.mbedtls_ssl_config,
    entropy: c.mbedtls_entropy_context,
    ctr_drbg: c.mbedtls_ctr_drbg_context,
    cacert: c.mbedtls_x509_crt,
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
            .cacert = undefined,
            .connected = false,
            .handshake_done = false,
        };

        c.mbedtls_net_init(&self.server_fd);
        c.mbedtls_ssl_init(&self.ssl);
        c.mbedtls_ssl_config_init(&self.conf);
        c.mbedtls_ctr_drbg_init(&self.ctr_drbg);
        c.mbedtls_entropy_init(&self.entropy);
        c.mbedtls_x509_crt_init(&self.cacert);

        const pers = "hft_ssl_client";
        const ret = c.mbedtls_ctr_drbg_seed(
            &self.ctr_drbg,
            c.mbedtls_entropy_func,
            &self.entropy,
            pers.ptr,
            pers.len,
        );
        if (ret != 0) return error.RngSeedFailed;

        // Required for VERIFY_REQUIRED — without trust anchors the
        // handshake would reject every server.
        _ = loadSystemCaChain(&self.cacert) catch |err| {
            c.mbedtls_x509_crt_free(&self.cacert);
            c.mbedtls_entropy_free(&self.entropy);
            c.mbedtls_ctr_drbg_free(&self.ctr_drbg);
            c.mbedtls_ssl_config_free(&self.conf);
            c.mbedtls_ssl_free(&self.ssl);
            c.mbedtls_net_free(&self.server_fd);
            return err;
        };

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

        // Full chain verification. Combined with mbedtls_ssl_set_hostname
        // below this rejects any cert not signed by a trusted root OR
        // not issued for the expected hostname.
        c.mbedtls_ssl_conf_authmode(&self.conf, c.MBEDTLS_SSL_VERIFY_REQUIRED);
        c.mbedtls_ssl_conf_ca_chain(&self.conf, &self.cacert, null);
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
            c.mbedtls_x509_crt_free(&self.cacert);
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
    /// Microseconds taken by the most recent executeBuy / executeSell.
    /// Replaces the prior `std.debug.print("🚀 BUY executed in {}µs", ...)`
    /// which leaked the order JSON alongside the timing.
    last_execution_us: u64,

    pub fn init() LatencyMetrics {
        return .{
            .ping_sent_ns = 0,
            .pong_received_ns = 0,
            .min_rtt_us = std.math.maxInt(u64),
            .max_rtt_us = 0,
            .avg_rtt_us = 0,
            .sample_count = 0,
            .last_execution_us = 0,
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

/// Quantity tick: 1e-8 of the base asset (the satoshi convention every
/// major crypto exchange uses for BTC/ETH/etc.). 1 BTC = 100_000_000.
pub const QUANTITY_TICKS_PER_UNIT: i64 = 100_000_000;
/// Price tick: 1e-2 of the quote asset (cents for USD-denominated pairs).
/// Mirrors Binance's `{d:.2}` wire-format precision for spot prices.
pub const PRICE_TICKS_PER_UNIT: i64 = 100;

/// Pre-built order template (for optimistic signing).
///
/// Quantity and price are integer ticks — never f64 — because crypto
/// exchanges reject prices with f64's round-trip-shortest formatting
/// (Binance specifically wants `0.00012345`, not `0.000123450000001`)
/// and because 0.1 is not exactly representable in f64. The historical
/// shape of this bug is the matching engine seeing `0.000099999…` where
/// the trader meant `0.0001`, which moves the order outside its limit
/// price by a tick and creates an arbitrage window against the engine.
/// Cures FLOAT-OBSESSION on this exchange's order path.
pub const OrderTemplate = struct {
    symbol: [16]u8, // "BTCUSDT" padded
    side: Side,
    order_type: OrderType,
    /// Order quantity in 1e-8 base-asset ticks (satoshis for BTC).
    quantity_ticks: i64,
    /// Limit price in 1e-2 quote-asset ticks (cents for USD pairs).
    /// Null for market orders.
    price_ticks: ?i64 = null,

    // Pre-allocated buffers
    json_buffer: [512]u8,
    signature_buffer: [64]u8,
    json_len: usize,

    pub fn init(symbol: []const u8, side: Side, order_type: OrderType, quantity_ticks: i64) !OrderTemplate {
        var template: OrderTemplate = undefined;

        // Pad symbol
        @memset(&template.symbol, 0);
        @memcpy(template.symbol[0..symbol.len], symbol);

        template.side = side;
        template.order_type = order_type;
        template.quantity_ticks = quantity_ticks;
        template.price_ticks = null;
        template.json_len = 0;

        return template;
    }

    /// Build JSON payload (optimized for minimal allocations).
    ///
    /// Audit (JSON-IN-FMT): the previous implementation
    /// hand-formatted the body via std.fmt.bufPrint with a
    /// JSON-shaped format string. `symbol` is operator-set
    /// (config) and the toString() enums are library-controlled —
    /// safe in practice — but a `,"x":1` smuggled into any of
    /// them would have forged sibling fields in the order body
    /// (the exchange would honour them as part of the request).
    ///
    /// The hot-path contract is preserved: we write into the
    /// pre-allocated `json_buffer` via `std.Io.Writer.fixed` and
    /// emit through std.json.Stringify — zero heap allocations.
    /// The float precision (`{d:.8}` quantity, `{d:.2}` price)
    /// goes through `Stringify.print` so the exchange API still
    /// sees the precision it expects (Stringify's default float
    /// formatter uses round-trip-shortest, which crypto exchanges
    /// reject).
    pub fn buildJson(self: *OrderTemplate, timestamp: u64) ![]const u8 {
        var symbol_len: usize = 0;
        while (symbol_len < 16 and self.symbol[symbol_len] != 0) : (symbol_len += 1) {}
        const symbol_str = self.symbol[0..symbol_len];

        var w = std.Io.Writer.fixed(&self.json_buffer);
        var jw: std.json.Stringify = .{ .writer = &w, .options = .{} };

        try jw.beginObject();
        try jw.objectField("symbol");
        try jw.write(symbol_str);
        try jw.objectField("side");
        try jw.write(self.side.toString());
        try jw.objectField("type");
        try jw.write(self.order_type.toString());

        // Quantity: integer satoshi-ticks → "X.YYYYYYYY" ASCII. Pure
        // digit math — no float round-trip. The exchange's matcher
        // parses this as a base-10 decimal, identical to what `{d:.8}`
        // would have emitted for the integer-equivalent value.
        try jw.objectField("quantity");
        var qty_buf: [32]u8 = undefined;
        const qty_str = formatTicks(&qty_buf, self.quantity_ticks, 8, QUANTITY_TICKS_PER_UNIT);
        try jw.print("{s}", .{qty_str});

        if (self.price_ticks) |price_ticks| {
            try jw.objectField("price");
            var price_buf: [32]u8 = undefined;
            const price_str = formatTicks(&price_buf, price_ticks, 2, PRICE_TICKS_PER_UNIT);
            try jw.print("{s}", .{price_str});
        }
        try jw.objectField("timestamp");
        try jw.write(timestamp);
        try jw.endObject();

        self.json_len = w.buffered().len;
        return self.json_buffer[0..self.json_len];
    }
};

/// Format integer `ticks` (scaled by `scale` = 10^decimals) into a
/// `X.YYY…Y` decimal string with exactly `decimals` fractional digits.
/// Pure integer math — never goes through f64 — so the exchange wire
/// shape is bit-stable across rebuilds and immune to "0.1 is not
/// representable" precision drift.
fn formatTicks(buf: []u8, ticks: i64, comptime decimals: u8, scale: i64) []const u8 {
    const integer_part = @divTrunc(ticks, scale);
    const frac_part = @mod(ticks, scale);
    return switch (decimals) {
        2 => std.fmt.bufPrint(buf, "{d}.{d:0>2}", .{ integer_part, frac_part }),
        8 => std.fmt.bufPrint(buf, "{d}.{d:0>8}", .{ integer_part, frac_part }),
        else => std.fmt.bufPrint(buf, "{d}", .{integer_part}),
    } catch buf[0..0];
}

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

    /// Pre-load order templates for instant execution.
    /// Quantities are in 1e-8 base-asset ticks (satoshis for BTC) — see
    /// `QUANTITY_TICKS_PER_UNIT`. Pass `0.001 BTC` as `100_000`.
    pub fn preloadOrders(
        self: *Self,
        symbol: []const u8,
        buy_quantity_ticks: i64,
        sell_quantity_ticks: i64,
    ) !void {
        std.debug.print("📝 Pre-loading order templates for {s}\n", .{symbol});

        self.buy_template = try OrderTemplate.init(symbol, .buy, .market, buy_quantity_ticks);
        self.sell_template = try OrderTemplate.init(symbol, .sell, .market, sell_quantity_ticks);

        var buy_buf: [32]u8 = undefined;
        var sell_buf: [32]u8 = undefined;
        std.debug.print("✅ Order templates ready:\n", .{});
        std.debug.print("   BUY:  {s} {s}\n", .{ formatTicks(&buy_buf, buy_quantity_ticks, 8, QUANTITY_TICKS_PER_UNIT), symbol });
        std.debug.print("   SELL: {s} {s}\n", .{ formatTicks(&sell_buf, sell_quantity_ticks, 8, QUANTITY_TICKS_PER_UNIT), symbol });
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
        // Authentication path — no debug prints. The exchange name is
        // safe to log, but signing material isn't, and historically the
        // "Authenticating with X..." line drifted into logging the auth
        // JSON or the HMAC hex. Keep this path silent and require
        // observability via metrics, not stdout.
        const hmac = @import("../crypto/hmac.zig");
        const timestamp_ms = getRealtimeMs();

        // Audit (JSON-IN-FMT): every auth payload used to be
        // built via std.fmt.bufPrint with a JSON-shaped format
        // string interpolating `api_key`, `sig_hex`, and
        // `passphrase` — every one of which is
        // operator/secret-controlled. A `"` smuggled into any
        // would have closed the string mid-field and let the rest
        // of the credential bytes land as sibling JSON, which the
        // exchange would have honoured. The auth path is also
        // zero-alloc by design (we never want a per-session
        // GC-pause-equivalent at signing time), so we keep the
        // stack-buffer pattern and route through
        // std.Io.Writer.fixed + std.json.Stringify.
        var auth_json: [512]u8 = undefined;
        var w = std.Io.Writer.fixed(&auth_json);
        var jw: std.json.Stringify = .{ .writer = &w, .options = .{} };

        switch (self.exchange) {
            .binance => {
                // Binance: HMAC-SHA256(secret, "timestamp=<ms>")
                var msg_buf: [128]u8 = undefined;
                const auth_msg = std.fmt.bufPrint(&msg_buf, "timestamp={d}", .{timestamp_ms}) catch return error.AuthFailed;
                var signature: [32]u8 = undefined;
                hmac.signBinance(self.credentials.api_secret, auth_msg, &signature);
                const sig_hex = std.fmt.bytesToHex(signature, .lower);

                // {"method":"SUBSCRIBE","params":["<api_key>@account"],"id":1,
                //  "apiKey":"<api_key>","signature":"<sig>","timestamp":<ms>}
                var params_buf: [256]u8 = undefined;
                const params_str = std.fmt.bufPrint(&params_buf, "{s}@account", .{self.credentials.api_key}) catch return error.AuthFailed;
                jw.beginObject() catch return error.AuthFailed;
                jw.objectField("method") catch return error.AuthFailed;
                jw.write("SUBSCRIBE") catch return error.AuthFailed;
                jw.objectField("params") catch return error.AuthFailed;
                jw.beginArray() catch return error.AuthFailed;
                jw.write(params_str) catch return error.AuthFailed;
                jw.endArray() catch return error.AuthFailed;
                jw.objectField("id") catch return error.AuthFailed;
                jw.write(@as(u32, 1)) catch return error.AuthFailed;
                jw.objectField("apiKey") catch return error.AuthFailed;
                jw.write(self.credentials.api_key) catch return error.AuthFailed;
                jw.objectField("signature") catch return error.AuthFailed;
                jw.write(@as([]const u8, &sig_hex)) catch return error.AuthFailed;
                jw.objectField("timestamp") catch return error.AuthFailed;
                jw.write(timestamp_ms) catch return error.AuthFailed;
                jw.endObject() catch return error.AuthFailed;
                try self.sendWebSocketFrame(.text, w.buffered());
            },
            .coinbase => {
                // Coinbase: HMAC-SHA256(secret, timestamp + "GET" + "/users/self/verify")
                var ts_buf: [32]u8 = undefined;
                const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{timestamp_ms / 1000}) catch return error.AuthFailed;
                var signature: [32]u8 = undefined;
                hmac.signCoinbase(self.credentials.api_secret, ts_str, "GET", "/users/self/verify", "", &signature);
                const sig_hex = std.fmt.bytesToHex(signature, .lower);

                const passphrase = self.credentials.passphrase orelse "";
                jw.beginObject() catch return error.AuthFailed;
                jw.objectField("type") catch return error.AuthFailed;
                jw.write("subscribe") catch return error.AuthFailed;
                jw.objectField("channels") catch return error.AuthFailed;
                jw.beginArray() catch return error.AuthFailed;
                jw.write("user") catch return error.AuthFailed;
                jw.endArray() catch return error.AuthFailed;
                jw.objectField("key") catch return error.AuthFailed;
                jw.write(self.credentials.api_key) catch return error.AuthFailed;
                jw.objectField("signature") catch return error.AuthFailed;
                jw.write(@as([]const u8, &sig_hex)) catch return error.AuthFailed;
                jw.objectField("timestamp") catch return error.AuthFailed;
                jw.write(ts_str) catch return error.AuthFailed;
                jw.objectField("passphrase") catch return error.AuthFailed;
                jw.write(passphrase) catch return error.AuthFailed;
                jw.endObject() catch return error.AuthFailed;
                try self.sendWebSocketFrame(.text, w.buffered());
            },
            .kraken, .bybit => {
                // Kraken/Bybit: HMAC-SHA256(secret, timestamp)
                var ts_buf: [32]u8 = undefined;
                const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{timestamp_ms}) catch return error.AuthFailed;
                var signature: [32]u8 = undefined;
                hmac.hmacSha256(self.credentials.api_secret, ts_str, &signature);
                const sig_hex = std.fmt.bytesToHex(signature, .lower);

                // {"op":"auth","args":["<api_key>",<ts_ms>,"<sig>"]}
                jw.beginObject() catch return error.AuthFailed;
                jw.objectField("op") catch return error.AuthFailed;
                jw.write("auth") catch return error.AuthFailed;
                jw.objectField("args") catch return error.AuthFailed;
                jw.beginArray() catch return error.AuthFailed;
                jw.write(self.credentials.api_key) catch return error.AuthFailed;
                jw.write(timestamp_ms) catch return error.AuthFailed;
                jw.write(@as([]const u8, &sig_hex)) catch return error.AuthFailed;
                jw.endArray() catch return error.AuthFailed;
                jw.endObject() catch return error.AuthFailed;
                try self.sendWebSocketFrame(.text, w.buffered());
            },
        }

        self.authenticated.store(true, .release);
        // Intentionally silent on success — see comment at top of fn.
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
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        self.metrics.ping_sent_ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 +
                                    @as(u64, @intCast(ts.nsec));

        try self.sendWebSocketFrame(.ping, &.{});
        std.debug.print("📤 PING sent\n", .{});
    }

    /// Handle pong response
    pub fn handlePong(self: *Self) !void {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
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
        self.metrics.last_execution_us = (end_ns - start_ns) / 1000;
        // The order JSON and HMAC signature are NEVER written to stdout
        // or stderr. Order payloads contain account / API-key references
        // and the signature line was effectively logging the HMAC tag
        // alongside its plaintext — observe via metrics or a structured
        // sink, not via std.debug.print.
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
        self.metrics.last_execution_us = (end_ns - start_ns) / 1000;
        // Same scrubbing rule as executeBuy — no stdout for order JSON
        // or HMAC. See comment above.
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
    // 0.001 BTC = 100_000 satoshi-ticks at QUANTITY_TICKS_PER_UNIT = 1e8.
    const template = try OrderTemplate.init("BTCUSDT", .buy, .market, 100_000);
    try std.testing.expect(template.side == .buy);
    try std.testing.expect(template.order_type == .market);
    try std.testing.expectEqual(@as(i64, 100_000), template.quantity_ticks);
}

test "order JSON generation" {
    // 0.5 BTC = 50_000_000 satoshi-ticks.
    var template = try OrderTemplate.init("BTCUSDT", .sell, .market, 50_000_000);
    const json = try template.buildJson(1700000000000);

    // Verify JSON contains key fields
    try std.testing.expect(std.mem.indexOf(u8, json, "BTCUSDT") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "SELL") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "MARKET") != null);
}
