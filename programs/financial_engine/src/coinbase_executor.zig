//! Coinbase FIX Trade Executor
//!
//! Implements the TradeExecutor trait for Coinbase Exchange FIX gateway.
//! Provides real-time order execution via FIX 5.0 SP2 protocol.

const std = @import("std");
const Decimal = @import("decimal.zig").Decimal;
const execution = @import("execution.zig");
const fix = @import("fix_protocol_v5.zig");
const CoinbaseFIXClient = @import("coinbase_fix_client.zig").CoinbaseFIXClient;

/// Get current Unix timestamp in seconds (Zig 0.16 compatible)
fn getCurrentTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

/// Get current timespec (Zig 0.16 compatible)
fn getClockTime() std.c.timespec {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts;
}

const Order = execution.Order;
const ExecutionResult = execution.ExecutionResult;
const TradeExecutor = execution.TradeExecutor;

// =============================================================================
// UUID Generation
// =============================================================================

/// Generate a UUIDv4 for Coinbase order IDs
fn generateUUID(buf: []u8) []const u8 {
    // Generate 16 random bytes from /dev/urandom
    var uuid_bytes: [16]u8 = undefined;
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, "/dev/urandom", .{ .ACCMODE = .RDONLY }, 0) catch {
        // Fallback: use timestamp-based pseudo-random
        const ts = getClockTime();
        const seed: u64 = @bitCast(ts.sec *% 1000000000 +% ts.nsec);
        for (0..16) |i| {
            uuid_bytes[i] = @truncate((seed *% (@as(u64, i) + 1)) >> @intCast((i % 8) * 8));
        }
        return formatUUID(buf, uuid_bytes);
    };
    defer _ = std.c.close(fd);
    _ = std.c.read(fd, &uuid_bytes, uuid_bytes.len);
    return formatUUID(buf, uuid_bytes);
}

fn formatUUID(buf: []u8, uuid_bytes_raw: [16]u8) []const u8 {
    var uuid_bytes = uuid_bytes_raw;

    // Set version (4) and variant bits
    uuid_bytes[6] = (uuid_bytes[6] & 0x0f) | 0x40; // Version 4
    uuid_bytes[8] = (uuid_bytes[8] & 0x3f) | 0x80; // Variant 1

    // Format as string: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    const result = std.fmt.bufPrint(buf, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        uuid_bytes[0],  uuid_bytes[1],  uuid_bytes[2],  uuid_bytes[3],
        uuid_bytes[4],  uuid_bytes[5],  uuid_bytes[6],  uuid_bytes[7],
        uuid_bytes[8],  uuid_bytes[9],  uuid_bytes[10], uuid_bytes[11],
        uuid_bytes[12], uuid_bytes[13], uuid_bytes[14], uuid_bytes[15],
    }) catch return buf[0..0];

    return result;
}

// =============================================================================
// Coinbase Executor
// =============================================================================

/// Coinbase FIX Trade Executor
pub const CoinbaseExecutor = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    client: CoinbaseFIXClient,

    // Statistics
    orders_sent: u64,
    orders_filled: u64,
    orders_rejected: u64,

    // Order tracking
    pending_orders: std.StringHashMap(PendingOrder),

    const PendingOrder = struct {
        signal_id: u64,
        symbol: []const u8,
        side: Order.Side,
        quantity: Decimal,
        price: Decimal,
        timestamp: i64,
    };

    /// Initialize the executor
    pub fn init(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        api_secret: []const u8,
        passphrase: []const u8,
        use_sandbox: bool,
    ) Self {
        const credentials = fix.CoinbaseCredentials{
            .api_key = api_key,
            .api_secret = api_secret,
            .passphrase = passphrase,
        };

        var executor = Self{
            .allocator = allocator,
            .client = CoinbaseFIXClient.init(allocator, credentials, use_sandbox),
            .orders_sent = 0,
            .orders_filled = 0,
            .orders_rejected = 0,
            .pending_orders = std.StringHashMap(PendingOrder).init(allocator),
        };

        // Set message callback for execution reports
        executor.client.setCallback(messageCallback, @ptrCast(&executor));

        return executor;
    }

    /// Deinitialize the executor
    pub fn deinit(self: *Self) void {
        self.disconnect();
        self.pending_orders.deinit();
    }

    /// Connect to Coinbase FIX gateway
    pub fn connect(self: *Self) !void {
        try self.client.connect();
        try self.client.login();
    }

    /// Disconnect from Coinbase
    pub fn disconnect(self: *Self) void {
        self.client.disconnect();
    }

    /// Send an order to Coinbase
    pub fn sendOrder(self: *Self, order: Order) TradeExecutor.ExecutorError!ExecutionResult {
        if (!self.client.isConnected()) {
            return error.NotConnected;
        }

        // Generate UUID for ClOrdID
        var uuid_buf: [36]u8 = undefined;
        const cl_ord_id = generateUUID(&uuid_buf);

        // Convert order parameters
        const side: fix.Side = switch (order.side) {
            .buy => .Buy,
            .sell => .Sell,
        };

        const order_type: fix.OrdType = switch (order.order_type) {
            .market => .Market,
            .limit => .Limit,
        };

        const quantity = order.quantity.toFloat();

        const price: ?f64 = if (order.order_type == .limit)
            order.price.toFloat()
        else
            null;

        // Send to Coinbase
        self.client.sendOrder(
            cl_ord_id,
            order.symbol,
            side,
            order_type,
            quantity,
            price,
            .GoodTillCancel,
        ) catch {
            self.orders_rejected += 1;
            return error.SendFailed;
        };

        self.orders_sent += 1;

        // Track pending order
        const cl_ord_id_copy = self.allocator.dupe(u8, cl_ord_id) catch {
            return error.Unknown;
        };

        self.pending_orders.put(cl_ord_id_copy, .{
            .signal_id = order.signal_id,
            .symbol = order.symbol,
            .side = order.side,
            .quantity = order.quantity,
            .price = order.price,
            .timestamp = order.timestamp,
        }) catch {};

        // Return pending result (actual fill comes via callback)
        return ExecutionResult{
            .order_id = order.signal_id,
            .success = true,
            .message = "Order sent to Coinbase",
            .fill_price = Decimal.fromInt(0),
            .fill_quantity = Decimal.fromInt(0),
            .timestamp = getCurrentTimestamp(),
        };
    }

    /// Cancel an order
    pub fn cancelOrder(self: *Self, order_id: u64) TradeExecutor.ExecutorError!void {
        if (!self.client.isConnected()) {
            return error.NotConnected;
        }

        // Find the pending order
        var iter = self.pending_orders.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.signal_id == order_id) {
                // Generate new UUID for cancel request
                var uuid_buf: [36]u8 = undefined;
                const cancel_id = generateUUID(&uuid_buf);

                self.client.cancelOrder(
                    cancel_id,
                    entry.key_ptr.*,
                    "", // OrderID from exchange (would need to track this)
                    entry.value_ptr.symbol,
                ) catch {
                    return error.SendFailed;
                };

                return;
            }
        }

        return error.InvalidOrder;
    }

    /// Get executor status
    pub fn getStatus(self: *Self) TradeExecutor.ExecutorStatus {
        return .{
            .connected = self.client.isConnected(),
            .orders_sent = self.orders_sent,
            .orders_filled = self.orders_filled,
            .orders_rejected = self.orders_rejected,
            .name = "Coinbase FIX",
        };
    }

    /// Poll for incoming messages (call this regularly)
    pub fn poll(self: *Self) !void {
        _ = try self.client.poll();
    }

    /// Message callback for execution reports
    fn messageCallback(msg_type: fix.MsgType, msg: fix.ParsedMessage, user_data: ?*anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(user_data));

        if (msg_type == .ExecutionReport) {
            // Get exec type
            if (msg.getField(fix.Tag.ExecType)) |exec_type_str| {
                const exec_type = fix.ExecType.fromChar(exec_type_str[0]) orelse return;

                switch (exec_type) {
                    .Trade => {
                        self.orders_filled += 1;
                        // Could emit signal for strategy feedback here
                    },
                    .Rejected => {
                        self.orders_rejected += 1;
                    },
                    else => {},
                }
            }

            // Remove from pending if filled or rejected
            if (msg.getField(fix.Tag.ClOrdID)) |cl_ord_id| {
                if (msg.getField(fix.Tag.OrdStatus)) |ord_status_str| {
                    const ord_status = fix.OrdStatus.fromChar(ord_status_str[0]) orelse return;
                    if (ord_status == .Filled or ord_status == .Rejected or ord_status == .Canceled) {
                        _ = self.pending_orders.remove(cl_ord_id);
                    }
                }
            }
        }
    }

    // =========================================================================
    // TradeExecutor Trait Implementation
    // =========================================================================

    /// Create a TradeExecutor interface from this executor
    pub fn asTradeExecutor(self: *Self) TradeExecutor {
        return .{
            .ptr = self,
            .vtable = &.{
                .sendOrder = sendOrderVTable,
                .cancelOrder = cancelOrderVTable,
                .getStatus = getStatusVTable,
                .deinit = deinitVTable,
            },
        };
    }

    fn sendOrderVTable(ptr: *anyopaque, order: Order) TradeExecutor.ExecutorError!ExecutionResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.sendOrder(order);
    }

    fn cancelOrderVTable(ptr: *anyopaque, order_id: u64) TradeExecutor.ExecutorError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.cancelOrder(order_id);
    }

    fn getStatusVTable(ptr: *anyopaque) TradeExecutor.ExecutorStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.getStatus();
    }

    fn deinitVTable(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};

// =============================================================================
// Factory Function
// =============================================================================

/// Create a Coinbase executor from environment variables or config
pub fn createFromEnv(allocator: std.mem.Allocator, use_sandbox: bool) !CoinbaseExecutor {
    // In production, these would come from environment or secure config
    const api_key = std.process.getEnvVarOwned(allocator, "COINBASE_FIX_API_KEY") catch {
        return error.MissingApiKey;
    };
    defer allocator.free(api_key);

    const api_secret = std.process.getEnvVarOwned(allocator, "COINBASE_FIX_API_SECRET") catch {
        return error.MissingApiSecret;
    };
    defer allocator.free(api_secret);

    const passphrase = std.process.getEnvVarOwned(allocator, "COINBASE_FIX_PASSPHRASE") catch {
        return error.MissingPassphrase;
    };
    defer allocator.free(passphrase);

    return CoinbaseExecutor.init(allocator, api_key, api_secret, passphrase, use_sandbox);
}

// =============================================================================
// Demo
// =============================================================================

pub fn demo() !void {
    const allocator = std.heap.c_allocator;

    std.debug.print("\n=== Coinbase FIX Executor Demo ===\n\n", .{});

    // Create executor (sandbox mode)
    var executor = CoinbaseExecutor.init(
        allocator,
        "demo-api-key",
        "ZGVtby1zZWNyZXQ=", // Base64 "demo-secret"
        "demo-passphrase",
        true, // Use sandbox
    );
    defer executor.deinit();

    // Get as TradeExecutor interface
    const trade_executor = executor.asTradeExecutor();

    // Check status
    const status = trade_executor.getStatus();
    std.debug.print("Executor: {s}\n", .{status.name});
    std.debug.print("Connected: {}\n", .{status.connected});

    // In production:
    // try executor.connect();
    // const result = try trade_executor.sendOrder(order);
    // executor.poll() in event loop

    std.debug.print("\n=== Coinbase Executor Capabilities ===\n", .{});
    std.debug.print("✓ TradeExecutor trait implementation\n", .{});
    std.debug.print("✓ FIX 5.0 SP2 order submission\n", .{});
    std.debug.print("✓ Order cancellation\n", .{});
    std.debug.print("✓ Execution report handling\n", .{});
    std.debug.print("✓ Pending order tracking\n", .{});
    std.debug.print("✓ UUID generation for ClOrdID\n", .{});
    std.debug.print("✓ Pluggable into HFT system\n", .{});
}

test "coinbase executor init" {
    const allocator = std.testing.allocator;

    var executor = CoinbaseExecutor.init(
        allocator,
        "test-key",
        "dGVzdC1zZWNyZXQ=",
        "test-pass",
        true,
    );
    defer executor.deinit();

    const status = executor.getStatus();
    try std.testing.expectEqualStrings("Coinbase FIX", status.name);
    try std.testing.expect(!status.connected);
}

test "uuid generation" {
    var buf: [36]u8 = undefined;
    const uuid = generateUUID(&buf);

    // Check format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    try std.testing.expect(uuid.len == 36);
    try std.testing.expect(uuid[8] == '-');
    try std.testing.expect(uuid[13] == '-');
    try std.testing.expect(uuid[18] == '-');
    try std.testing.expect(uuid[23] == '-');
}

// =============================================================================
// Main Entry Point (for test executable)
// =============================================================================

pub fn main() !void {
    try demo();
}
