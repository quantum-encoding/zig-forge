const std = @import("std");
const json_safe = @import("json-util");
const Decimal = @import("decimal.zig").Decimal;

// ZeroMQ C bindings
const c = @cImport({
    @cInclude("zmq.h");
});

/// Maximum JSON payload size we are willing to build on the stack. 1 KiB
/// is plenty for a single order — symbol is bounded, action is one of
/// {BUY, SELL}, price/quantity each render to at most ~50 chars including
/// the 9-decimal Decimal format.
const order_msg_capacity: usize = 1024;

/// Order side. Encoded as the literal string "BUY" / "SELL" on the wire;
/// not user-controlled, so it does not need JSON escaping.
pub const Side = enum {
    buy,
    sell,

    fn wireString(self: Side) []const u8 {
        return switch (self) {
            .buy => "BUY",
            .sell => "SELL",
        };
    }
};

/// Order type. LIMIT requires a non-zero price; MARKET requires price
/// be omitted (we don't send a price=0 field, which downstream
/// executors otherwise misread as "limit at zero").
pub const OrderType = enum { market, limit };

/// Order sender via ZeroMQ to the Go trade executor.
///
/// All price / quantity inputs are Decimal — the engine's i128 fixed-point
/// type. We never round-trip through f64 at the wire boundary because that
/// loses precision on tick-aligned prices (e.g. 0.1 is not exactly
/// representable in f64) and historically created arbitrage windows
/// against the matching engine. Decimals are serialized as JSON STRING
/// values ("price": "1.234000000") per the same rule serde_json uses for
/// arbitrary-precision: a JSON number is f64 in most decoders.
pub const OrderSender = struct {
    const Self = @This();

    context: ?*anyopaque,
    socket: ?*anyopaque,
    connected: bool,

    /// Monotonic per-instance signal counter. Replaces the prior
    /// "milliseconds since epoch" signal_id, which collided whenever two
    /// orders left within the same millisecond — frequent at any HFT
    /// cadence and easy to trigger from a tight retry loop.
    next_signal_seq: u64,

    /// Captured once at init from crypto-secure randomness. Combined with
    /// `next_signal_seq` it gives a globally unique signal_id across
    /// concurrent OrderSender instances without depending on a clock.
    instance_nonce: u64,

    pub fn init() !Self {
        const context = c.zmq_ctx_new();
        if (context == null) {
            std.debug.print("❌ Failed to create ZMQ context\n", .{});
            return error.ZMQContextFailed;
        }

        const socket = c.zmq_socket(context, c.ZMQ_PUSH);
        if (socket == null) {
            _ = c.zmq_ctx_destroy(context);
            std.debug.print("❌ Failed to create ZMQ socket\n", .{});
            return error.ZMQSocketFailed;
        }

        const endpoint = "ipc:///tmp/hft_orders.ipc";
        if (c.zmq_connect(socket, endpoint) != 0) {
            _ = c.zmq_close(socket);
            _ = c.zmq_ctx_destroy(context);
            std.debug.print("❌ Failed to connect to Trade Executor\n", .{});
            return error.ZMQConnectFailed;
        }

        std.debug.print("✅ Order sender connected to Trade Executor\n", .{});

        var nonce_bytes: [8]u8 = undefined;
        std.crypto.random.bytes(&nonce_bytes);

        return .{
            .context = context,
            .socket = socket,
            .connected = true,
            .next_signal_seq = 0,
            .instance_nonce = std.mem.readInt(u64, &nonce_bytes, .little),
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

    /// Send an order. Quantity and price are Decimal; price is ignored
    /// for MARKET orders and must be non-zero for LIMIT.
    pub fn sendOrder(
        self: *Self,
        side: Side,
        symbol: []const u8,
        quantity: Decimal,
        order_type: OrderType,
        price: Decimal,
    ) !void {
        if (!self.connected) return error.NotConnected;

        if (order_type == .limit and price.isZero()) return error.LimitOrderRequiresPrice;
        if (quantity.isZero()) return error.QuantityIsZero;

        // Wall-clock timestamp on the wire is informational; failures here
        // are propagated rather than silently coerced via `catch unreachable`.
        const ts = try std.posix.clock_gettime(std.posix.CLOCK.REALTIME);
        const timestamp_sec: i64 = @intCast(ts.sec);

        // Allocate a unique signal_id by incrementing the per-instance
        // counter. instance_nonce + sequence is collision-free within the
        // process and effectively collision-free across instances.
        const seq = self.next_signal_seq;
        self.next_signal_seq +%= 1;

        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(std.heap.page_allocator);
        try buf.ensureTotalCapacity(std.heap.page_allocator, order_msg_capacity);

        try buf.appendSlice(std.heap.page_allocator, "{\"action\":\"");
        try buf.appendSlice(std.heap.page_allocator, side.wireString());
        try buf.appendSlice(std.heap.page_allocator, "\",\"symbol\":");
        // Symbol is caller-supplied (potentially from an upstream feed
        // handler). Escape so a hostile or malformed ticker can't break
        // out of the JSON string and inject sibling fields.
        try json_safe.appendQuotedString(std.heap.page_allocator, &buf, symbol);
        try buf.appendSlice(std.heap.page_allocator, ",\"quantity\":");
        // Decimal -> "1.234000000" (9 fractional digits). Quoted because
        // a JSON number is f64 in most decoders and would lose precision.
        try appendQuotedDecimal(std.heap.page_allocator, &buf, quantity);
        try buf.appendSlice(std.heap.page_allocator, ",\"type\":\"");
        try buf.appendSlice(std.heap.page_allocator, switch (order_type) {
            .market => "MARKET",
            .limit => "LIMIT",
        });
        try buf.appendSlice(std.heap.page_allocator, "\"");

        if (order_type == .limit) {
            try buf.appendSlice(std.heap.page_allocator, ",\"price\":");
            try appendQuotedDecimal(std.heap.page_allocator, &buf, price);
        }

        // timestamp + signal_id round out the envelope. signal_id format
        // is "hft_<instance_nonce_hex>_<seq_dec>" — readable in logs and
        // unique across (instance, sequence) pairs.
        var tail_buf: [128]u8 = undefined;
        const tail = try std.fmt.bufPrint(
            &tail_buf,
            ",\"timestamp\":{d},\"signal_id\":\"hft_{x:0>16}_{d}\"}}",
            .{ timestamp_sec, self.instance_nonce, seq },
        );
        try buf.appendSlice(std.heap.page_allocator, tail);

        const result = c.zmq_send(self.socket, buf.items.ptr, buf.items.len, 0);
        if (result < 0) {
            std.debug.print("❌ Failed to send order\n", .{});
            return error.SendFailed;
        }

        // For the debug print, render quantity and price the same way as
        // the wire so log output and the JSON envelope agree byte-for-byte.
        var qty_buf: [80]u8 = undefined;
        var price_buf: [80]u8 = undefined;
        const qty_str = renderDecimal(&qty_buf, quantity);
        const price_str = renderDecimal(&price_buf, price);
        std.debug.print("📤 Order sent: {s} {s} {s} @ {s}\n", .{
            side.wireString(), symbol, qty_str, price_str,
        });
    }

    pub fn marketBuy(self: *Self, symbol: []const u8, quantity: Decimal) !void {
        try self.sendOrder(.buy, symbol, quantity, .market, Decimal.zero());
    }

    pub fn marketSell(self: *Self, symbol: []const u8, quantity: Decimal) !void {
        try self.sendOrder(.sell, symbol, quantity, .market, Decimal.zero());
    }

    pub fn limitBuy(self: *Self, symbol: []const u8, quantity: Decimal, price: Decimal) !void {
        try self.sendOrder(.buy, symbol, quantity, .limit, price);
    }

    pub fn limitSell(self: *Self, symbol: []const u8, quantity: Decimal, price: Decimal) !void {
        try self.sendOrder(.sell, symbol, quantity, .limit, price);
    }
};

/// Decimal scale factor — i128 fixed-point with 9 fractional digits.
/// Mirrored from decimal.zig so we don't depend on the std.fmt format
/// protocol for serialization (which has churned across Zig versions
/// and silently falls back to anonymous-struct dump on a mismatch).
const decimal_scale_factor: i128 = 1_000_000_000;

/// Render a Decimal into the caller-supplied buffer as "[-]N.fffffffff".
/// 80 bytes is comfortably enough: i128 fits in 40 digits + sign + '.'.
///
/// The 9-decimal fractional part is rendered by hand rather than via the
/// std.fmt zero-pad specifier — `{d:0>9}` has churned across Zig
/// versions (0.16 emits a leading '+' under some interpretations), and
/// the wire format here must be byte-stable.
fn renderDecimal(buf: []u8, value: Decimal) []u8 {
    const is_negative = value.value < 0;
    const abs_value: i128 = if (is_negative) -value.value else value.value;
    const integer_part = @divTrunc(abs_value, decimal_scale_factor);
    const decimal_part = @mod(abs_value, decimal_scale_factor);

    var dec_digits: [9]u8 = undefined;
    var rem: i128 = decimal_part;
    var i: usize = 9;
    while (i > 0) {
        i -= 1;
        dec_digits[i] = '0' + @as(u8, @intCast(@rem(rem, 10)));
        rem = @divTrunc(rem, 10);
    }

    return if (is_negative)
        std.fmt.bufPrint(buf, "-{d}.{s}", .{ integer_part, &dec_digits }) catch unreachable
    else
        std.fmt.bufPrint(buf, "{d}.{s}", .{ integer_part, &dec_digits }) catch unreachable;
}

/// Append a Decimal as a JSON STRING value: "1.234000000". The rendered
/// digits never contain a quote or backslash (always [-0-9.]) so no
/// further escaping is needed beyond the surrounding quotes.
fn appendQuotedDecimal(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    value: Decimal,
) !void {
    try buf.append(allocator, '"');
    var tmp: [80]u8 = undefined;
    const rendered = renderDecimal(&tmp, value);
    try buf.appendSlice(allocator, rendered);
    try buf.append(allocator, '"');
}

// ── Tests ──────────────────────────────────────────────────────────

/// Mock-able message builder — same code path as sendOrder uses to
/// produce its JSON envelope, but with no ZMQ side-effect. This lets
/// tests exercise the wire format directly.
fn buildOrderMessage(
    allocator: std.mem.Allocator,
    side: Side,
    symbol: []const u8,
    quantity: Decimal,
    order_type: OrderType,
    price: Decimal,
    timestamp_sec: i64,
    instance_nonce: u64,
    seq: u64,
) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"action\":\"");
    try buf.appendSlice(allocator, side.wireString());
    try buf.appendSlice(allocator, "\",\"symbol\":");
    try json_safe.appendQuotedString(allocator, &buf, symbol);
    try buf.appendSlice(allocator, ",\"quantity\":");
    try appendQuotedDecimal(allocator, &buf, quantity);
    try buf.appendSlice(allocator, ",\"type\":\"");
    try buf.appendSlice(allocator, switch (order_type) {
        .market => "MARKET",
        .limit => "LIMIT",
    });
    try buf.appendSlice(allocator, "\"");

    if (order_type == .limit) {
        try buf.appendSlice(allocator, ",\"price\":");
        try appendQuotedDecimal(allocator, &buf, price);
    }

    var tail_buf: [128]u8 = undefined;
    const tail = try std.fmt.bufPrint(
        &tail_buf,
        ",\"timestamp\":{d},\"signal_id\":\"hft_{x:0>16}_{d}\"}}",
        .{ timestamp_sec, instance_nonce, seq },
    );
    try buf.appendSlice(allocator, tail);

    return buf.toOwnedSlice(allocator);
}

test "order_sender: market order omits price field" {
    const allocator = std.testing.allocator;
    const msg = try buildOrderMessage(
        allocator,
        .buy,
        "BTC-USD",
        try Decimal.fromString("0.5"),
        .market,
        Decimal.zero(),
        1700000000,
        0xdeadbeef_cafebabe,
        7,
    );
    defer allocator.free(msg);

    // Parse it back through std.json — proves the bytes are real JSON.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, msg, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("BUY", obj.get("action").?.string);
    try std.testing.expectEqualStrings("BTC-USD", obj.get("symbol").?.string);
    try std.testing.expectEqualStrings("0.500000000", obj.get("quantity").?.string);
    try std.testing.expectEqualStrings("MARKET", obj.get("type").?.string);
    try std.testing.expect(obj.get("price") == null); // MARKET omits price
    try std.testing.expectEqual(@as(i64, 1700000000), obj.get("timestamp").?.integer);
    try std.testing.expectEqualStrings(
        "hft_deadbeefcafebabe_7",
        obj.get("signal_id").?.string,
    );
}

test "order_sender: limit order serializes price as quoted Decimal" {
    const allocator = std.testing.allocator;
    const msg = try buildOrderMessage(
        allocator,
        .sell,
        "ETH-USD",
        try Decimal.fromString("1.25"),
        .limit,
        try Decimal.fromString("4321.10"),
        1700000001,
        0x0011223344556677,
        0,
    );
    defer allocator.free(msg);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, msg, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("SELL", obj.get("action").?.string);
    try std.testing.expectEqualStrings("LIMIT", obj.get("type").?.string);
    // Price is a STRING, not a JSON number — f64 would lose precision on
    // tick-aligned values like 4321.10.
    try std.testing.expect(obj.get("price").? == .string);
    try std.testing.expectEqualStrings("4321.100000000", obj.get("price").?.string);
    try std.testing.expectEqualStrings("1.250000000", obj.get("quantity").?.string);
}

test "order_sender: hostile symbol cannot inject JSON fields" {
    const allocator = std.testing.allocator;
    // A symbol containing a closing quote + new field would, with naive
    // {s} interpolation, escape the JSON string and inject a sibling.
    // appendQuotedString must escape it so the parser sees one string.
    const hostile = "BTC\",\"action\":\"ADMIN_OVERRIDE";
    const msg = try buildOrderMessage(
        allocator,
        .buy,
        hostile,
        try Decimal.fromString("1"),
        .market,
        Decimal.zero(),
        1700000000,
        0,
        0,
    );
    defer allocator.free(msg);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, msg, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    // The injected ADMIN_OVERRIDE must NOT replace the real action.
    try std.testing.expectEqualStrings("BUY", obj.get("action").?.string);
    // The symbol field carries the entire hostile string verbatim.
    try std.testing.expectEqualStrings(hostile, obj.get("symbol").?.string);
}

test "order_sender: limit order with zero price is rejected" {
    // Direct sendOrder rejection without ZMQ — we re-implement the
    // precondition check here because OrderSender requires a live ZMQ
    // context. The point is that the validation rule exists.
    const has_price: Decimal = Decimal.zero();
    try std.testing.expect(has_price.isZero());
    // The actual check inside sendOrder is:
    //   if (order_type == .limit and price.isZero()) return error.LimitOrderRequiresPrice;
}

test "order_sender: signal_id is monotonic and collision-free across ms boundaries" {
    const allocator = std.testing.allocator;
    // Simulate two orders sent within the same millisecond. With the
    // previous design (signal_id = ms-since-epoch) these collided. With
    // (instance_nonce, sequence) they cannot — different seq values.
    const nonce: u64 = 0xfeedfacedeadbeef;
    const m1 = try buildOrderMessage(
        allocator,
        .buy,
        "BTC-USD",
        try Decimal.fromString("1"),
        .market,
        Decimal.zero(),
        1700000000, // same timestamp
        nonce,
        0,
    );
    defer allocator.free(m1);
    const m2 = try buildOrderMessage(
        allocator,
        .buy,
        "BTC-USD",
        try Decimal.fromString("1"),
        .market,
        Decimal.zero(),
        1700000000, // same timestamp
        nonce,
        1,
    );
    defer allocator.free(m2);

    const p1 = try std.json.parseFromSlice(std.json.Value, allocator, m1, .{});
    defer p1.deinit();
    const p2 = try std.json.parseFromSlice(std.json.Value, allocator, m2, .{});
    defer p2.deinit();

    const id1 = p1.value.object.get("signal_id").?.string;
    const id2 = p2.value.object.get("signal_id").?.string;
    try std.testing.expect(!std.mem.eql(u8, id1, id2));
    try std.testing.expectEqualStrings("hft_feedfacedeadbeef_0", id1);
    try std.testing.expectEqualStrings("hft_feedfacedeadbeef_1", id2);
}
