//! Coinbase FIX 5.0 C FFI Interface
//!
//! Provides C-compatible exports for the Coinbase FIX executor,
//! enabling integration with Rust/Tauri and other languages.

const std = @import("std");
const fix = @import("fix_protocol_v5.zig");
const CoinbaseFIXClient = @import("coinbase_fix_client.zig").CoinbaseFIXClient;
const CoinbaseExecutor = @import("coinbase_executor.zig").CoinbaseExecutor;
const execution = @import("execution.zig");
const Decimal = @import("decimal.zig").Decimal;

// =============================================================================
// Timestamp helper (Zig 0.16 compatible)
// =============================================================================

fn getCurrentTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

// =============================================================================
// C-Compatible Types
// =============================================================================

/// Opaque handle to a Coinbase FIX executor
pub const CoinbaseHandle = *CoinbaseExecutor;

/// Order side for C interface
pub const CSide = enum(u8) {
    Buy = 0,
    Sell = 1,
};

/// Order type for C interface
pub const COrderType = enum(u8) {
    Market = 0,
    Limit = 1,
};

/// Execution result returned to C
pub const CExecutionResult = extern struct {
    order_id: u64,
    success: bool,
    fill_price_value: i64,
    fill_price_scale: u8,
    fill_quantity_value: i64,
    fill_quantity_scale: u8,
    timestamp: i64,
    error_code: i32,
};

/// Executor status returned to C
pub const CExecutorStatus = extern struct {
    connected: bool,
    orders_sent: u64,
    orders_filled: u64,
    orders_rejected: u64,
};

/// Error codes for C interface
pub const CErrorCode = enum(i32) {
    Success = 0,
    NotConnected = -1,
    InvalidOrder = -2,
    SendFailed = -3,
    ConnectionFailed = -4,
    AuthenticationFailed = -5,
    Unknown = -99,
};

// =============================================================================
// Global Allocator for FFI
// =============================================================================

const allocator = std.heap.c_allocator;

// =============================================================================
// Decimal scale constant (Decimal uses 10^9 internally)
// =============================================================================

const DECIMAL_SCALE: u8 = 9;

// =============================================================================
// C FFI Exports
// =============================================================================

/// Create a new Coinbase FIX executor
/// Returns null on failure
export fn coinbase_fix_create(
    api_key: [*:0]const u8,
    api_secret: [*:0]const u8,
    passphrase: [*:0]const u8,
    use_sandbox: bool,
) ?CoinbaseHandle {
    const key_slice = std.mem.span(api_key);
    const secret_slice = std.mem.span(api_secret);
    const pass_slice = std.mem.span(passphrase);

    const executor = allocator.create(CoinbaseExecutor) catch return null;

    executor.* = CoinbaseExecutor.init(
        allocator,
        key_slice,
        secret_slice,
        pass_slice,
        use_sandbox,
    );

    return executor;
}

/// Destroy a Coinbase FIX executor
export fn coinbase_fix_destroy(handle: ?CoinbaseHandle) void {
    if (handle) |executor| {
        executor.deinit();
        allocator.destroy(executor);
    }
}

/// Connect to Coinbase FIX gateway
/// Returns 0 on success, negative error code on failure
export fn coinbase_fix_connect(handle: ?CoinbaseHandle) CErrorCode {
    const executor = handle orelse return .Unknown;

    executor.connect() catch |err| {
        return switch (err) {
            error.ConnectionFailed => .ConnectionFailed,
            error.AuthenticationFailed => .AuthenticationFailed,
            error.AlreadyConnected => .Unknown,
            else => .Unknown,
        };
    };

    return .Success;
}

/// Disconnect from Coinbase FIX gateway
export fn coinbase_fix_disconnect(handle: ?CoinbaseHandle) void {
    if (handle) |executor| {
        executor.disconnect();
    }
}

/// Check if connected
export fn coinbase_fix_is_connected(handle: ?CoinbaseHandle) bool {
    const executor = handle orelse return false;
    return executor.client.isConnected();
}

/// Send a new order
export fn coinbase_fix_send_order(
    handle: ?CoinbaseHandle,
    signal_id: u64,
    symbol: [*:0]const u8,
    side: CSide,
    order_type: COrderType,
    quantity_value: i64,
    quantity_scale: u8,
    price_value: i64,
    price_scale: u8,
    result: *CExecutionResult,
) CErrorCode {
    const executor = handle orelse return .Unknown;
    const symbol_slice = std.mem.span(symbol);

    // Convert fixed-point to Decimal (Decimal uses internal scale of 10^9)
    const qty_float = @as(f64, @floatFromInt(quantity_value)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(quantity_scale)));
    const price_float = @as(f64, @floatFromInt(price_value)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(price_scale)));

    const order = execution.Order{
        .signal_id = signal_id,
        .symbol = symbol_slice,
        .side = if (side == .Buy) .buy else .sell,
        .order_type = if (order_type == .Market) .market else .limit,
        .quantity = Decimal.fromFloat(qty_float),
        .price = Decimal.fromFloat(price_float),
        .timestamp = getCurrentTimestamp(),
    };

    const exec_result = executor.sendOrder(order) catch |err| {
        result.success = false;
        result.error_code = @intFromEnum(switch (err) {
            error.NotConnected => CErrorCode.NotConnected,
            error.InvalidOrder => CErrorCode.InvalidOrder,
            error.SendFailed => CErrorCode.SendFailed,
            else => CErrorCode.Unknown,
        });
        return @enumFromInt(result.error_code);
    };

    // Convert Decimal back to fixed-point for C interface
    result.* = .{
        .order_id = exec_result.order_id,
        .success = exec_result.success,
        .fill_price_value = @intCast(@divTrunc(exec_result.fill_price.value, 1)), // Already scaled internally
        .fill_price_scale = DECIMAL_SCALE,
        .fill_quantity_value = @intCast(@divTrunc(exec_result.fill_quantity.value, 1)),
        .fill_quantity_scale = DECIMAL_SCALE,
        .timestamp = exec_result.timestamp,
        .error_code = 0,
    };

    return .Success;
}

/// Cancel an order
export fn coinbase_fix_cancel_order(handle: ?CoinbaseHandle, order_id: u64) CErrorCode {
    const executor = handle orelse return .Unknown;

    executor.cancelOrder(order_id) catch |err| {
        return switch (err) {
            error.NotConnected => .NotConnected,
            error.InvalidOrder => .InvalidOrder,
            error.SendFailed => .SendFailed,
            else => .Unknown,
        };
    };

    return .Success;
}

/// Get executor status
export fn coinbase_fix_get_status(handle: ?CoinbaseHandle, status: *CExecutorStatus) CErrorCode {
    const executor = handle orelse return .Unknown;

    const s = executor.getStatus();
    status.* = .{
        .connected = s.connected,
        .orders_sent = s.orders_sent,
        .orders_filled = s.orders_filled,
        .orders_rejected = s.orders_rejected,
    };

    return .Success;
}

/// Poll for incoming messages (non-blocking)
/// Returns 0 on success, negative error code on failure
export fn coinbase_fix_poll(handle: ?CoinbaseHandle) CErrorCode {
    const executor = handle orelse return .Unknown;

    executor.poll() catch {
        return .Unknown;
    };

    return .Success;
}

// =============================================================================
// Batch Operations
// =============================================================================

/// Batch order structure for C
pub const CBatchOrder = extern struct {
    signal_id: u64,
    symbol: [*:0]const u8,
    side: CSide,
    order_type: COrderType,
    quantity_value: i64,
    quantity_scale: u8,
    price_value: i64,
    price_scale: u8,
};

/// Send multiple orders in a batch
/// Returns number of successfully sent orders
export fn coinbase_fix_send_batch(
    handle: ?CoinbaseHandle,
    orders: [*]const CBatchOrder,
    count: usize,
    results: [*]CExecutionResult,
) usize {
    const executor = handle orelse return 0;
    var success_count: usize = 0;

    for (0..count) |i| {
        const batch_order = orders[i];
        const symbol_slice = std.mem.span(batch_order.symbol);

        const qty_float = @as(f64, @floatFromInt(batch_order.quantity_value)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(batch_order.quantity_scale)));
        const price_float = @as(f64, @floatFromInt(batch_order.price_value)) / std.math.pow(f64, 10, @as(f64, @floatFromInt(batch_order.price_scale)));

        const order = execution.Order{
            .signal_id = batch_order.signal_id,
            .symbol = symbol_slice,
            .side = if (batch_order.side == .Buy) .buy else .sell,
            .order_type = if (batch_order.order_type == .Market) .market else .limit,
            .quantity = Decimal.fromFloat(qty_float),
            .price = Decimal.fromFloat(price_float),
            .timestamp = getCurrentTimestamp(),
        };

        if (executor.sendOrder(order)) |exec_result| {
            results[i] = .{
                .order_id = exec_result.order_id,
                .success = exec_result.success,
                .fill_price_value = @intCast(@divTrunc(exec_result.fill_price.value, 1)),
                .fill_price_scale = DECIMAL_SCALE,
                .fill_quantity_value = @intCast(@divTrunc(exec_result.fill_quantity.value, 1)),
                .fill_quantity_scale = DECIMAL_SCALE,
                .timestamp = exec_result.timestamp,
                .error_code = 0,
            };
            success_count += 1;
        } else |_| {
            results[i] = .{
                .order_id = 0,
                .success = false,
                .fill_price_value = 0,
                .fill_price_scale = 0,
                .fill_quantity_value = 0,
                .fill_quantity_scale = 0,
                .timestamp = 0,
                .error_code = @intFromEnum(CErrorCode.SendFailed),
            };
        }
    }

    return success_count;
}

// =============================================================================
// Utility Functions
// =============================================================================

/// Get version string
export fn coinbase_fix_version() [*:0]const u8 {
    return "1.0.0-fix50sp2";
}

/// Get FIX session version
export fn coinbase_fix_session_version() [*:0]const u8 {
    return fix.FIX_SESSION_VERSION;
}

/// Get FIX application version ID
export fn coinbase_fix_app_version_id() [*:0]const u8 {
    return fix.FIX_APP_VERSION_ID;
}

// =============================================================================
// Callback Registration
// =============================================================================

/// Callback function type for execution reports
pub const ExecutionCallback = *const fn (result: *const CExecutionResult, user_data: ?*anyopaque) callconv(.c) void;

var registered_callback: ?ExecutionCallback = null;
var callback_user_data: ?*anyopaque = null;

/// Register a callback for execution reports
export fn coinbase_fix_set_callback(
    callback: ?ExecutionCallback,
    user_data: ?*anyopaque,
) void {
    registered_callback = callback;
    callback_user_data = user_data;
}

// =============================================================================
// Tests
// =============================================================================

test "ffi create and destroy" {
    const handle = coinbase_fix_create("test-key", "dGVzdA==", "test-pass", true);
    try std.testing.expect(handle != null);

    if (handle) |h| {
        const status_result = coinbase_fix_is_connected(h);
        try std.testing.expect(!status_result);

        coinbase_fix_destroy(h);
    }
}

test "ffi version" {
    const version = coinbase_fix_version();
    const version_str = std.mem.span(version);
    try std.testing.expect(version_str.len > 0);
}
