// Thread-Safe Alpaca Trading API
// Each instance gets its own HTTP client - safe for concurrent use

const std = @import("std");
const Decimal = @import("decimal.zig").Decimal;
const ThreadSafeHttpClient = @import("thread_safe_http_client.zig").ThreadSafeHttpClient;

/// Render Decimal as `X.YY` for Alpaca's order JSON via integer math
/// — mirrors `alpaca_trading_api.formatDecimal2dp`. Batch 32
/// FLOAT-OBSESSION.
fn formatDecimal2dp(buf: []u8, value: Decimal) []const u8 {
    const internal_scale: i128 = 1_000_000_000;
    const integer_part = @divTrunc(value.value, internal_scale);
    const raw_frac = @mod(value.value, internal_scale);
    const abs_frac = if (raw_frac < 0) -raw_frac else raw_frac;
    const frac_2dp = @divTrunc(abs_frac, 10_000_000);
    return std.fmt.bufPrint(buf, "{d}.{d:0>2}", .{ integer_part, frac_2dp }) catch buf[0..0];
}

pub const ThreadSafeAlpacaAPI = struct {
    const Self = @This();

    // Constants
    const ALPACA_PAPER_API_URL = "https://paper-api.alpaca.markets";
    const MAX_RESPONSE_SIZE = 1024 * 1024;

    // Core configuration
    allocator: std.mem.Allocator,
    api_key: []const u8,
    api_secret: []const u8,
    base_url: []const u8,
    tenant_id: []const u8,

    // Thread-local HTTP client - SAFE for this thread
    http_client: ThreadSafeHttpClient,

    // Order tracking (atomic for stats)
    orders_placed: std.atomic.Value(u64),
    orders_filled: std.atomic.Value(u64),
    orders_canceled: std.atomic.Value(u64),

    pub const OrderSide = enum {
        buy,
        sell,

        pub fn toString(self: OrderSide) []const u8 {
            return switch (self) {
                .buy => "buy",
                .sell => "sell",
            };
        }
    };

    pub const OrderType = enum {
        market,
        limit,
        stop,
        stop_limit,

        pub fn toString(self: OrderType) []const u8 {
            return switch (self) {
                .market => "market",
                .limit => "limit",
                .stop => "stop",
                .stop_limit => "stop_limit",
            };
        }
    };

    pub const TimeInForce = enum {
        day,
        gtc,
        ioc,
        fok,

        pub fn toString(self: TimeInForce) []const u8 {
            return switch (self) {
                .day => "day",
                .gtc => "gtc",
                .ioc => "ioc",
                .fok => "fok",
            };
        }
    };

    pub const OrderRequest = struct {
        symbol: []const u8,
        qty: u32,
        side: OrderSide,
        type: OrderType,
        time_in_force: TimeInForce = .day,
        /// Limit / stop prices as Decimal — see alpaca_trading_api's
        /// OrderRequest for the integer-wire rationale (Batch 32
        /// FLOAT-OBSESSION).
        limit_price: ?Decimal = null,
        stop_price: ?Decimal = null,
        client_order_id: ?[]const u8 = null,
        extended_hours: bool = false,
    };

    pub const OrderResponse = struct {
        id: []const u8,
        client_order_id: []const u8,
        symbol: []const u8,
        qty: []const u8,
        side: []const u8,
        type: []const u8,
        time_in_force: []const u8,
        limit_price: ?[]const u8,
        status: []const u8,
        created_at: []const u8,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        api_secret: []const u8,
        tenant_id: []const u8,
    ) !Self {
        const key_copy = try allocator.dupe(u8, api_key);
        errdefer allocator.free(key_copy);

        const secret_copy = try allocator.dupe(u8, api_secret);
        errdefer allocator.free(secret_copy);

        const tenant_copy = try allocator.dupe(u8, tenant_id);
        errdefer allocator.free(tenant_copy);

        // Each API instance gets its own HTTP client
        const http_client = try ThreadSafeHttpClient.init(allocator, tenant_id);

        return .{
            .allocator = allocator,
            .api_key = key_copy,
            .api_secret = secret_copy,
            .base_url = ALPACA_PAPER_API_URL,
            .tenant_id = tenant_copy,
            .http_client = http_client,
            .orders_placed = std.atomic.Value(u64).init(0),
            .orders_filled = std.atomic.Value(u64).init(0),
            .orders_canceled = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *Self) void {
        self.http_client.deinit();
        self.allocator.free(self.api_key);
        self.allocator.free(self.api_secret);
        self.allocator.free(self.tenant_id);
    }

    pub fn placeOrder(self: *Self, order: OrderRequest) !OrderResponse {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/v2/orders",
            .{self.base_url}
        );
        defer self.allocator.free(url);

        // Build JSON body via structured serialization.
        var body_alloc: std.Io.Writer.Allocating = .init(self.allocator);
        defer body_alloc.deinit();
        var jw: std.json.Stringify = .{ .writer = &body_alloc.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField("symbol");
        try jw.write(order.symbol);
        try jw.objectField("qty");
        try jw.write(order.qty);
        try jw.objectField("side");
        try jw.write(order.side.toString());
        try jw.objectField("type");
        try jw.write(order.type.toString());
        try jw.objectField("time_in_force");
        try jw.write(order.time_in_force.toString());
        if (order.limit_price) |price| {
            try jw.objectField("limit_price");
            var px_buf: [32]u8 = undefined;
            try jw.print("{s}", .{formatDecimal2dp(&px_buf, price)});
        }
        if (order.stop_price) |price| {
            try jw.objectField("stop_price");
            var px_buf: [32]u8 = undefined;
            try jw.print("{s}", .{formatDecimal2dp(&px_buf, price)});
        }
        if (order.client_order_id) |id| {
            try jw.objectField("client_order_id");
            try jw.write(id);
        }
        try jw.objectField("extended_hours");
        try jw.write(order.extended_hours);
        try jw.endObject();

        const json_body = body_alloc.written();

        // Prepare headers
        const headers = [_]std.http.Header{
            .{ .name = "APCA-API-KEY-ID", .value = self.api_key },
            .{ .name = "APCA-API-SECRET-KEY", .value = self.api_secret },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "application/json" },
        };

        // Make thread-safe request
        std.log.info("[{s}] Placing order for {s}", .{ self.tenant_id, order.symbol });

        var response = try self.http_client.post(url, &headers, json_body);
        defer response.deinit();

        if (response.status != .ok) {
            std.log.err("[{s}] Order failed with status: {}", .{
                self.tenant_id,
                response.status,
            });
            return error.OrderFailed;
        }

        _ = self.orders_placed.fetchAdd(1, .monotonic);

        // Parse response
        const parsed = try std.json.parseFromSlice(
            struct {
                id: []const u8,
                client_order_id: []const u8,
                symbol: []const u8,
                qty: []const u8,
                side: []const u8,
                @"type": []const u8,
                time_in_force: []const u8,
                limit_price: ?[]const u8 = null,
                status: []const u8,
                created_at: []const u8,
            },
            self.allocator,
            response.body,
            .{ .ignore_unknown_fields = true }
        );
        defer parsed.deinit();

        return OrderResponse{
            .id = try self.allocator.dupe(u8, parsed.value.id),
            .client_order_id = try self.allocator.dupe(u8, parsed.value.client_order_id),
            .symbol = try self.allocator.dupe(u8, parsed.value.symbol),
            .qty = try self.allocator.dupe(u8, parsed.value.qty),
            .side = try self.allocator.dupe(u8, parsed.value.side),
            .type = try self.allocator.dupe(u8, parsed.value.@"type"),
            .time_in_force = try self.allocator.dupe(u8, parsed.value.time_in_force),
            .limit_price = if (parsed.value.limit_price) |p|
                try self.allocator.dupe(u8, p)
            else
                null,
            .status = try self.allocator.dupe(u8, parsed.value.status),
            .created_at = try self.allocator.dupe(u8, parsed.value.created_at),
        };
    }

    pub fn cancelOrder(self: *Self, order_id: []const u8) !void {
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/v2/orders/{s}",
            .{ self.base_url, order_id }
        );
        defer self.allocator.free(url);

        const headers = [_]std.http.Header{
            .{ .name = "APCA-API-KEY-ID", .value = self.api_key },
            .{ .name = "APCA-API-SECRET-KEY", .value = self.api_secret },
        };

        var response = try self.http_client.delete(url, &headers);
        defer response.deinit();

        if (response.status == .ok or response.status == .no_content) {
            _ = self.orders_canceled.fetchAdd(1, .monotonic);
            std.log.info("[{s}] Order {s} canceled", .{ self.tenant_id, order_id });
        } else {
            std.log.err("[{s}] Failed to cancel order {s}: {}", .{
                self.tenant_id,
                order_id,
                response.status,
            });
            return error.CancelFailed;
        }
    }
};