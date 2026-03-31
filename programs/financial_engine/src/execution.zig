//! Trade Execution Layer
//!
//! Provides a trait-based interface for order execution, enabling
//! pluggable execution venues (ZMQ, paper trading, brokers, etc.)
//!
//! Design Pattern: Inversion of Control
//! - HFTSystem depends on abstract TradeExecutor, not concrete implementations
//! - Enables testing without live connections
//! - Allows runtime selection of execution venue

const std = @import("std");
const Decimal = @import("decimal.zig").Decimal;

/// Get current Unix timestamp in seconds (Zig 0.16 compatible)
fn getCurrentTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

/// Get current time in milliseconds (Zig 0.16 compatible)
fn getCurrentMillis() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
}

/// Order structure for execution
pub const Order = struct {
    symbol: []const u8,
    side: Side,
    order_type: OrderType,
    quantity: Decimal,
    price: Decimal, // 0 for market orders
    timestamp: i64,
    signal_id: u64,

    pub const Side = enum {
        buy,
        sell,
    };

    pub const OrderType = enum {
        market,
        limit,
    };

    pub fn init(
        symbol: []const u8,
        side: Side,
        order_type: OrderType,
        quantity: Decimal,
        price: Decimal,
    ) Order {
        return Order{
            .symbol = symbol,
            .side = side,
            .order_type = order_type,
            .quantity = quantity,
            .price = price,
            .timestamp = getCurrentTimestamp(),
            .signal_id = getCurrentMillis(),
        };
    }
};

/// Execution result
pub const ExecutionResult = struct {
    order_id: u64,
    success: bool,
    message: []const u8,
    fill_price: Decimal,
    fill_quantity: Decimal,
    timestamp: i64,
};

/// TradeExecutor trait - interface for all execution venues
/// Zig doesn't have traits, so we use a vtable pattern
pub const TradeExecutor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        sendOrder: *const fn (ptr: *anyopaque, order: Order) ExecutorError!ExecutionResult,
        cancelOrder: *const fn (ptr: *anyopaque, order_id: u64) ExecutorError!void,
        getStatus: *const fn (ptr: *anyopaque) ExecutorStatus,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub const ExecutorError = error{
        NotConnected,
        SendFailed,
        InvalidOrder,
        RejectedByRisk,
        Timeout,
        Unknown,
    };

    pub const ExecutorStatus = struct {
        connected: bool,
        orders_sent: u64,
        orders_filled: u64,
        orders_rejected: u64,
        name: []const u8,
    };

    /// Send an order to the execution venue
    pub fn sendOrder(self: TradeExecutor, order: Order) ExecutorError!ExecutionResult {
        return self.vtable.sendOrder(self.ptr, order);
    }

    /// Cancel an existing order
    pub fn cancelOrder(self: TradeExecutor, order_id: u64) ExecutorError!void {
        return self.vtable.cancelOrder(self.ptr, order_id);
    }

    /// Get executor status
    pub fn getStatus(self: TradeExecutor) ExecutorStatus {
        return self.vtable.getStatus(self.ptr);
    }

    /// Cleanup resources
    pub fn deinit(self: TradeExecutor) void {
        self.vtable.deinit(self.ptr);
    }
};

// ============================================================================
// Paper Trading Executor (for testing/backtesting)
// ============================================================================

pub const PaperTradingExecutor = struct {
    const Self = @This();

    orders_sent: u64,
    orders_filled: u64,
    verbose: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, verbose: bool) Self {
        return Self{
            .orders_sent = 0,
            .orders_filled = 0,
            .verbose = verbose,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // No resources to clean up
    }

    pub fn executor(self: *Self) TradeExecutor {
        return TradeExecutor{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn sendOrderImpl(ptr: *anyopaque, order: Order) TradeExecutor.ExecutorError!ExecutionResult {
        const self: *Self = @ptrCast(@alignCast(ptr));

        self.orders_sent += 1;
        self.orders_filled += 1;

        const side_str = if (order.side == .buy) "BUY" else "SELL";
        const type_str = if (order.order_type == .market) "MARKET" else "LIMIT";

        if (self.verbose) {
            std.debug.print("[PAPER] {s} {s} {s} qty={d} @ {d}\n", .{
                side_str,
                type_str,
                order.symbol,
                @as(f64, @floatFromInt(order.quantity.value)) / 1_000_000_000.0,
                @as(f64, @floatFromInt(order.price.value)) / 1_000_000_000.0,
            });
        }

        return ExecutionResult{
            .order_id = order.signal_id,
            .success = true,
            .message = "Paper trade executed",
            .fill_price = order.price,
            .fill_quantity = order.quantity,
            .timestamp = getCurrentTimestamp(),
        };
    }

    fn cancelOrderImpl(ptr: *anyopaque, order_id: u64) TradeExecutor.ExecutorError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.verbose) {
            std.debug.print("[PAPER] Cancel order {d}\n", .{order_id});
        }
    }

    fn getStatusImpl(ptr: *anyopaque) TradeExecutor.ExecutorStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return TradeExecutor.ExecutorStatus{
            .connected = true,
            .orders_sent = self.orders_sent,
            .orders_filled = self.orders_filled,
            .orders_rejected = 0,
            .name = "PaperTrading",
        };
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    const vtable = TradeExecutor.VTable{
        .sendOrder = sendOrderImpl,
        .cancelOrder = cancelOrderImpl,
        .getStatus = getStatusImpl,
        .deinit = deinitImpl,
    };
};

// ============================================================================
// ZMQ Executor (for live trading via Go Trade Executor)
// Note: ZMQ is desktop-only; Android gets a stub that returns errors
// ============================================================================

const builtin = @import("builtin");

// ZMQ is only available on desktop (not Android)
const has_zmq = builtin.abi != .android;

const c = if (has_zmq) @cImport({
    @cInclude("zmq.h");
}) else struct {
    // Stub constants for Android compilation
    const ZMQ_PUSH: c_int = 8;
    const ZMQ_LINGER: c_int = 17;
    const ZMQ_DONTWAIT: c_int = 1;
};

pub const ZmqExecutor = struct {
    const Self = @This();

    context: ?*anyopaque,
    socket: ?*anyopaque,
    connected: bool,
    orders_sent: u64,
    orders_filled: u64,
    endpoint: []const u8,

    pub fn init(endpoint: []const u8) !Self {
        if (!has_zmq) {
            // Android: ZMQ not available
            std.debug.print("[ZMQ] Not available on Android - use Paper or None executor\n", .{});
            return error.ZMQNotAvailable;
        }

        // Create ZeroMQ context
        const context = c.zmq_ctx_new();
        if (context == null) {
            std.debug.print("[ZMQ] Failed to create context\n", .{});
            return error.ZMQContextFailed;
        }

        // Create PUSH socket
        const socket = c.zmq_socket(context, c.ZMQ_PUSH);
        if (socket == null) {
            _ = c.zmq_ctx_destroy(context);
            std.debug.print("[ZMQ] Failed to create socket\n", .{});
            return error.ZMQSocketFailed;
        }

        // Set socket options for non-blocking behavior
        var linger: c_int = 0;
        _ = c.zmq_setsockopt(socket, c.ZMQ_LINGER, &linger, @sizeOf(c_int));

        // Connect to Trade Executor
        if (c.zmq_connect(socket, endpoint.ptr) != 0) {
            _ = c.zmq_close(socket);
            _ = c.zmq_ctx_destroy(context);
            std.debug.print("[ZMQ] Failed to connect to {s}\n", .{endpoint});
            return error.ZMQConnectFailed;
        }

        std.debug.print("[ZMQ] Connected to Trade Executor at {s}\n", .{endpoint});

        return Self{
            .context = context,
            .socket = socket,
            .connected = true,
            .orders_sent = 0,
            .orders_filled = 0,
            .endpoint = endpoint,
        };
    }

    pub fn deinit(self: *Self) void {
        if (!has_zmq) return;
        if (self.socket) |s| {
            _ = c.zmq_close(s);
        }
        if (self.context) |ctx| {
            _ = c.zmq_ctx_destroy(ctx);
        }
        self.connected = false;
        std.debug.print("[ZMQ] Disconnected from Trade Executor\n", .{});
    }

    pub fn executor(self: *Self) TradeExecutor {
        return TradeExecutor{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn sendOrderImpl(ptr: *anyopaque, order: Order) TradeExecutor.ExecutorError!ExecutionResult {
        if (!has_zmq) return TradeExecutor.ExecutorError.NotConnected;

        const self: *Self = @ptrCast(@alignCast(ptr));

        if (!self.connected) {
            return TradeExecutor.ExecutorError.NotConnected;
        }

        // Build JSON message
        var buffer: [512]u8 = undefined;
        const side_str = if (order.side == .buy) "BUY" else "SELL";
        const type_str = if (order.order_type == .market) "MARKET" else "LIMIT";
        const qty_f64 = @as(f64, @floatFromInt(order.quantity.value)) / 1_000_000_000.0;
        const price_f64 = @as(f64, @floatFromInt(order.price.value)) / 1_000_000_000.0;

        const msg = std.fmt.bufPrint(&buffer,
            \\{{"action":"{s}","symbol":"{s}","quantity":{d},"type":"{s}","price":{d},"timestamp":{d},"signal_id":"hft_{d}"}}
        , .{
            side_str,
            order.symbol,
            qty_f64,
            type_str,
            price_f64,
            order.timestamp,
            order.signal_id,
        }) catch return TradeExecutor.ExecutorError.InvalidOrder;

        // Send via ZeroMQ (non-blocking)
        const result = c.zmq_send(self.socket, msg.ptr, msg.len, c.ZMQ_DONTWAIT);
        if (result < 0) {
            return TradeExecutor.ExecutorError.SendFailed;
        }

        self.orders_sent += 1;

        std.debug.print("[ZMQ] {s} {s} {s} qty={d:.2} @ {d:.2}\n", .{
            side_str, type_str, order.symbol, qty_f64, price_f64,
        });

        return ExecutionResult{
            .order_id = order.signal_id,
            .success = true,
            .message = "Order sent to Trade Executor",
            .fill_price = order.price,
            .fill_quantity = order.quantity,
            .timestamp = getCurrentTimestamp(),
        };
    }

    fn cancelOrderImpl(ptr: *anyopaque, order_id: u64) TradeExecutor.ExecutorError!void {
        if (!has_zmq) return TradeExecutor.ExecutorError.NotConnected;

        const self: *Self = @ptrCast(@alignCast(ptr));
        if (!self.connected) {
            return TradeExecutor.ExecutorError.NotConnected;
        }

        var buffer: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buffer,
            \\{{"action":"CANCEL","order_id":"hft_{d}"}}
        , .{order_id}) catch return TradeExecutor.ExecutorError.InvalidOrder;

        const result = c.zmq_send(self.socket, msg.ptr, msg.len, c.ZMQ_DONTWAIT);
        if (result < 0) {
            return TradeExecutor.ExecutorError.SendFailed;
        }
    }

    fn getStatusImpl(ptr: *anyopaque) TradeExecutor.ExecutorStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return TradeExecutor.ExecutorStatus{
            .connected = self.connected,
            .orders_sent = self.orders_sent,
            .orders_filled = self.orders_filled,
            .orders_rejected = 0,
            .name = "ZmqGoExecutor",
        };
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    const vtable = TradeExecutor.VTable{
        .sendOrder = sendOrderImpl,
        .cancelOrder = cancelOrderImpl,
        .getStatus = getStatusImpl,
        .deinit = deinitImpl,
    };
};

// ============================================================================
// Null Executor (no-op, for pure signal generation without execution)
// ============================================================================

pub const NullExecutor = struct {
    const Self = @This();

    orders_received: u64,

    pub fn init() Self {
        return Self{
            .orders_received = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn executor(self: *Self) TradeExecutor {
        return TradeExecutor{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn sendOrderImpl(ptr: *anyopaque, order: Order) TradeExecutor.ExecutorError!ExecutionResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = order;
        self.orders_received += 1;

        return ExecutionResult{
            .order_id = 0,
            .success = true,
            .message = "Order discarded (NullExecutor)",
            .fill_price = Decimal.zero(),
            .fill_quantity = Decimal.zero(),
            .timestamp = 0,
        };
    }

    fn cancelOrderImpl(ptr: *anyopaque, order_id: u64) TradeExecutor.ExecutorError!void {
        _ = ptr;
        _ = order_id;
    }

    fn getStatusImpl(ptr: *anyopaque) TradeExecutor.ExecutorStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return TradeExecutor.ExecutorStatus{
            .connected = true,
            .orders_sent = self.orders_received,
            .orders_filled = 0,
            .orders_rejected = 0,
            .name = "NullExecutor",
        };
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    const vtable = TradeExecutor.VTable{
        .sendOrder = sendOrderImpl,
        .cancelOrder = cancelOrderImpl,
        .getStatus = getStatusImpl,
        .deinit = deinitImpl,
    };
};
