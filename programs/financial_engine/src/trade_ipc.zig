const std = @import("std");
const json = std.json;

// ZeroMQ C bindings
const c = @cImport({
    @cInclude("zmq.h");
});

/// Order signal to send to Trade Executor
pub const OrderSignal = struct {
    action: []const u8,      // "BUY" or "SELL"
    symbol: []const u8,      // e.g., "AAPL"
    quantity: f64,           // Number of shares
    type: []const u8,        // "MARKET" or "LIMIT"
    price: f64,              // Limit price (0 for market)
    timestamp: i64,          // Unix timestamp
    signal_id: []const u8,   // Unique ID
};

/// Response from Trade Executor
pub const OrderResponse = struct {
    signal_id: []const u8,
    order_id: []const u8,
    status: []const u8,
    filled_qty: f64,
    filled_avg: f64,
    @"error": ?[]const u8 = null,
};

/// IPC client for sending orders to Go Trade Executor
pub const TradeIPC = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    context: ?*anyopaque,
    send_socket: ?*anyopaque,
    recv_socket: ?*anyopaque,
    signal_counter: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator) !Self {
        // Create ZeroMQ context
        const context = c.zmq_ctx_new();
        if (context == null) {
            return error.ZMQContextFailed;
        }

        // Create PUSH socket for sending orders
        const send_socket = c.zmq_socket(context, c.ZMQ_PUSH);
        if (send_socket == null) {
            _ = c.zmq_ctx_destroy(context);
            return error.ZMQSocketFailed;
        }

        // Connect to Trade Executor
        const send_endpoint = "ipc:///tmp/hft_orders.ipc";
        if (c.zmq_connect(send_socket, send_endpoint) != 0) {
            _ = c.zmq_close(send_socket);
            _ = c.zmq_ctx_destroy(context);
            return error.ZMQConnectFailed;
        }

        // Create PULL socket for receiving responses
        const recv_socket = c.zmq_socket(context, c.ZMQ_PULL);
        if (recv_socket == null) {
            _ = c.zmq_close(send_socket);
            _ = c.zmq_ctx_destroy(context);
            return error.ZMQSocketFailed;
        }

        // Connect to response endpoint
        const recv_endpoint = "ipc:///tmp/hft_responses.ipc";
        if (c.zmq_connect(recv_socket, recv_endpoint) != 0) {
            _ = c.zmq_close(recv_socket);
            _ = c.zmq_close(send_socket);
            _ = c.zmq_ctx_destroy(context);
            return error.ZMQConnectFailed;
        }

        std.debug.print("✅ Trade IPC connected to executor\n", .{});

        return .{
            .allocator = allocator,
            .context = context,
            .send_socket = send_socket,
            .recv_socket = recv_socket,
            .signal_counter = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.send_socket) |socket| {
            _ = c.zmq_close(socket);
        }
        if (self.recv_socket) |socket| {
            _ = c.zmq_close(socket);
        }
        if (self.context) |ctx| {
            _ = c.zmq_ctx_destroy(ctx);
        }
    }

    /// Send an order signal to the Trade Executor
    pub fn sendOrder(
        self: *Self,
        action: []const u8,
        symbol: []const u8,
        quantity: f64,
        order_type: []const u8,
        price: f64,
    ) !void {
        // Generate unique signal ID
        const signal_id = self.signal_counter.fetchAdd(1, .monotonic);
        var id_buf: [32]u8 = undefined;
        const id_str = try std.fmt.bufPrint(&id_buf, "zig_{d}", .{signal_id});

        // Create order signal
        const signal = OrderSignal{
            .action = action,
            .symbol = symbol,
            .quantity = quantity,
            .type = order_type,
            .price = price,
            .timestamp = std.time.timestamp(),
            .signal_id = id_str,
        };

        // Serialize to JSON
        const json_data = try json.stringifyAlloc(self.allocator, signal, .{});
        defer self.allocator.free(json_data);

        // Send via ZeroMQ
        const result = c.zmq_send(
            self.send_socket,
            json_data.ptr,
            json_data.len,
            0,
        );

        if (result < 0) {
            std.debug.print("❌ Failed to send order signal\n", .{});
            return error.SendFailed;
        }

        std.debug.print("📤 Sent order: {s} {s} {d} @ {d}\n", .{
            action, symbol, quantity, price
        });
    }

    /// Check for order responses (non-blocking)
    pub fn checkResponse(self: *Self) ?OrderResponse {
        var buffer: [1024]u8 = undefined;

        // Try to receive with non-blocking flag
        const result = c.zmq_recv(
            self.recv_socket,
            &buffer,
            buffer.len - 1,
            c.ZMQ_DONTWAIT,
        );

        if (result < 0) {
            // No message available (EAGAIN) or error
            return null;
        }

        // Null-terminate the received data
        buffer[@intCast(result)] = 0;
        const json_data = buffer[0..@intCast(result)];

        // Parse response
        const parsed = json.parseFromSlice(
            OrderResponse,
            self.allocator,
            json_data,
            .{ .ignore_unknown_fields = true },
        ) catch {
            std.debug.print("⚠️ Failed to parse response\n", .{});
            return null;
        };
        defer parsed.deinit();

        // Copy response data
        const response = parsed.value;
        std.debug.print("📥 Order response: {s} - {s}\n", .{
            response.order_id,
            response.status,
        });

        return response;
    }

    /// Send a market buy order
    pub fn marketBuy(self: *Self, symbol: []const u8, quantity: f64) !void {
        try self.sendOrder("BUY", symbol, quantity, "MARKET", 0);
    }

    /// Send a market sell order
    pub fn marketSell(self: *Self, symbol: []const u8, quantity: f64) !void {
        try self.sendOrder("SELL", symbol, quantity, "MARKET", 0);
    }

    /// Send a limit buy order
    pub fn limitBuy(self: *Self, symbol: []const u8, quantity: f64, price: f64) !void {
        try self.sendOrder("BUY", symbol, quantity, "LIMIT", price);
    }

    /// Send a limit sell order
    pub fn limitSell(self: *Self, symbol: []const u8, quantity: f64, price: f64) !void {
        try self.sendOrder("SELL", symbol, quantity, "LIMIT", price);
    }
};

/// Test the IPC connection
pub fn main() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("🔧 Testing Trade IPC...\n", .{});

    var ipc = try TradeIPC.init(allocator);
    defer ipc.deinit();

    // Send a test order
    try ipc.marketBuy("AAPL", 1);

    // Wait a bit for response
    std.Thread.sleep(100 * std.time.ns_per_ms);

    // Check for response
    if (ipc.checkResponse()) |response| {
        std.debug.print("✅ Got response: {s}\n", .{response.status});
    }

    std.debug.print("✅ Trade IPC test complete\n", .{});
}