const std = @import("std");

// ZeroMQ C bindings
const c = @cImport({
    @cInclude("zmq.h");
});

/// Simple order sender via ZeroMQ to Go Trade Executor
pub const OrderSender = struct {
    const Self = @This();

    context: ?*anyopaque,
    socket: ?*anyopaque,
    connected: bool,

    pub fn init() !Self {
        // Create ZeroMQ context
        const context = c.zmq_ctx_new();
        if (context == null) {
            std.debug.print("❌ Failed to create ZMQ context\n", .{});
            return error.ZMQContextFailed;
        }

        // Create PUSH socket
        const socket = c.zmq_socket(context, c.ZMQ_PUSH);
        if (socket == null) {
            _ = c.zmq_ctx_destroy(context);
            std.debug.print("❌ Failed to create ZMQ socket\n", .{});
            return error.ZMQSocketFailed;
        }

        // Connect to Trade Executor
        const endpoint = "ipc:///tmp/hft_orders.ipc";
        if (c.zmq_connect(socket, endpoint) != 0) {
            _ = c.zmq_close(socket);
            _ = c.zmq_ctx_destroy(context);
            std.debug.print("❌ Failed to connect to Trade Executor\n", .{});
            return error.ZMQConnectFailed;
        }

        std.debug.print("✅ Order sender connected to Trade Executor\n", .{});

        return .{
            .context = context,
            .socket = socket,
            .connected = true,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.socket) |s| {
            _ = c.zmq_close(s);
        }
        if (self.context) |ctx| {
            _ = c.zmq_ctx_destroy(ctx);
        }
        self.connected = false;
    }

    /// Send a simple order signal
    pub fn sendOrder(
        self: *Self,
        action: []const u8,  // "BUY" or "SELL"
        symbol: []const u8,
        quantity: f64,
        price: f64,          // 0 for market orders
    ) !void {
        if (!self.connected) {
            return error.NotConnected;
        }

        // Create simple JSON message manually
        var buffer: [512]u8 = undefined;
        const order_type = if (price > 0) "LIMIT" else "MARKET";

        const msg = try std.fmt.bufPrint(&buffer,
            \\{{
            \\  "action": "{s}",
            \\  "symbol": "{s}",
            \\  "quantity": {d},
            \\  "type": "{s}",
            \\  "price": {d},
            \\  "timestamp": {d},
            \\  "signal_id": "hft_{d}"
            \\}}
        , .{
            action,
            symbol,
            quantity,
            order_type,
            price,
            @as(i64, @intCast((std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable).sec)),
            blk: {const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable; break :blk @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1_000_000);},
        });

        // Send via ZeroMQ
        const result = c.zmq_send(self.socket, msg.ptr, msg.len, 0);
        if (result < 0) {
            std.debug.print("❌ Failed to send order\n", .{});
            return error.SendFailed;
        }

        std.debug.print("📤 Order sent: {s} {s} {d:.2} @ {d:.2}\n", .{
            action, symbol, quantity, price
        });
    }

    /// Send a market buy order
    pub fn marketBuy(self: *Self, symbol: []const u8, quantity: f64) !void {
        try self.sendOrder("BUY", symbol, quantity, 0);
    }

    /// Send a market sell order
    pub fn marketSell(self: *Self, symbol: []const u8, quantity: f64) !void {
        try self.sendOrder("SELL", symbol, quantity, 0);
    }

    /// Send a limit buy order
    pub fn limitBuy(self: *Self, symbol: []const u8, quantity: f64, price: f64) !void {
        try self.sendOrder("BUY", symbol, quantity, price);
    }

    /// Send a limit sell order
    pub fn limitSell(self: *Self, symbol: []const u8, quantity: f64, price: f64) !void {
        try self.sendOrder("SELL", symbol, quantity, price);
    }
};