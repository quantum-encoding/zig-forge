const std = @import("std");
const linux = std.os.linux;
const json = std.json;

// =============================================================================
// Sentient Network - ZMQ Signal Broadcast
// =============================================================================
// High-performance PUB/SUB signal distribution for the trading intelligence network
// Server publishes signals, clients subscribe with topic filtering
// =============================================================================

// ZeroMQ C bindings
const c = @cImport({
    @cInclude("zmq.h");
});

// =============================================================================
// Time Utilities (Zig 0.16 compatible)
// =============================================================================

/// Get current nanosecond timestamp (compatible with Zig 0.16 dev)
fn getNanoTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1_000_000_000 + ts.nsec;
}

// =============================================================================
// Signal Types
// =============================================================================

/// Trading signal action
pub const SignalAction = enum(u8) {
    buy = 0,
    sell = 1,
    hold = 2,
    close_long = 3,
    close_short = 4,
    scale_in = 5,
    scale_out = 6,
};

/// Asset class
pub const AssetClass = enum(u8) {
    crypto = 0,
    stocks = 1,
    forex = 2,
    futures = 3,
    options = 4,
};

/// Time horizon for the trade
pub const TimeHorizon = enum(u8) {
    scalp = 0,      // seconds to minutes
    intraday = 1,   // minutes to hours
    swing = 2,      // hours to days
    position = 3,   // days to weeks
    long_term = 4,  // weeks to months
};

/// Trading signal structure (fixed size for zero-copy)
pub const TradingSignal = extern struct {
    // 32-byte header
    signal_id: u64,           // Unique monotonic ID
    timestamp_ns: i64,        // Nanosecond timestamp
    sequence: u64,            // Sequence number for ordering
    flags: u32,               // Reserved flags
    _pad: u32,                // Alignment padding

    // Symbol (16 bytes, null-terminated)
    symbol: [16]u8,

    // Signal data (32 bytes)
    action: SignalAction,
    asset_class: AssetClass,
    time_horizon: TimeHorizon,
    confidence: u8,           // 0-100 percentage
    current_price: f64,       // Current price
    target_price: f64,        // Target price (0 if not set)
    stop_loss: f64,           // Stop loss (0 if not set)

    // Risk parameters (16 bytes)
    suggested_size_pct: f32,  // Position size as % (0.0-1.0)
    max_leverage: f32,        // Max leverage (1.0 = no leverage)
    risk_score: f32,          // 0.0-1.0 risk score
    expires_in_ms: u32,       // Expiration in ms from now (0 = no expiry)

    // Total: 96 bytes (cache-line aligned)

    pub fn init() TradingSignal {
        return std.mem.zeroes(TradingSignal);
    }

    pub fn setSymbol(self: *TradingSignal, sym: []const u8) void {
        @memset(&self.symbol, 0);
        const len = @min(sym.len, 15);
        @memcpy(self.symbol[0..len], sym[0..len]);
    }

    pub fn getSymbol(self: *const TradingSignal) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.symbol, 0) orelse 16;
        return self.symbol[0..end];
    }

    /// Get timestamp in milliseconds
    pub fn timestampMs(self: *const TradingSignal) i64 {
        return @divFloor(self.timestamp_ns, 1_000_000);
    }

    /// Get signal age in milliseconds
    pub fn ageMs(self: *const TradingSignal) u64 {
        const now = getNanoTimestamp();
        const age_ns = now - self.timestamp_ns;
        if (age_ns < 0) return 0;
        return @intCast(@divFloor(age_ns, 1_000_000));
    }

    /// Check if signal has expired
    pub fn isExpired(self: *const TradingSignal) bool {
        if (self.expires_in_ms == 0) return false;
        return self.ageMs() > self.expires_in_ms;
    }
};

// Compile-time size check
comptime {
    if (@sizeOf(TradingSignal) != 96) {
        @compileError("TradingSignal must be exactly 96 bytes");
    }
}

// =============================================================================
// Signal Publisher (Server)
// =============================================================================

pub const SignalPublisher = struct {
    const Self = @This();

    context: ?*anyopaque,
    socket: ?*anyopaque,
    sequence: std.atomic.Value(u64),
    signals_sent: std.atomic.Value(u64),
    bytes_sent: std.atomic.Value(u64),

    pub fn init(endpoint: [*:0]const u8) !Self {
        // Create ZeroMQ context
        const context = c.zmq_ctx_new();
        if (context == null) {
            return error.ZMQContextFailed;
        }
        errdefer _ = c.zmq_ctx_destroy(context);

        // Create PUB socket
        const socket = c.zmq_socket(context, c.ZMQ_PUB);
        if (socket == null) {
            return error.ZMQSocketFailed;
        }
        errdefer _ = c.zmq_close(socket);

        // Set socket options for high throughput
        var sndhwm: c_int = 100000; // High water mark
        _ = c.zmq_setsockopt(socket, c.ZMQ_SNDHWM, &sndhwm, @sizeOf(c_int));

        var linger: c_int = 0; // Don't block on close
        _ = c.zmq_setsockopt(socket, c.ZMQ_LINGER, &linger, @sizeOf(c_int));

        // Bind to endpoint
        if (c.zmq_bind(socket, endpoint) != 0) {
            return error.ZMQBindFailed;
        }

        std.debug.print("📡 Signal publisher bound to: {s}\n", .{endpoint});

        return .{
            .context = context,
            .socket = socket,
            .sequence = std.atomic.Value(u64).init(0),
            .signals_sent = std.atomic.Value(u64).init(0),
            .bytes_sent = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.socket) |socket| {
            _ = c.zmq_close(socket);
        }
        if (self.context) |ctx| {
            _ = c.zmq_ctx_destroy(ctx);
        }
        std.debug.print("📡 Signal publisher closed\n", .{});
    }

    /// Publish a trading signal
    /// Topic format: "SIGNAL:<SYMBOL>" e.g., "SIGNAL:BTCUSD"
    pub fn publish(self: *Self, signal: *TradingSignal) !void {
        // Set sequence and timestamp
        signal.sequence = self.sequence.fetchAdd(1, .monotonic);
        signal.timestamp_ns = getNanoTimestamp();

        // Create topic from symbol
        var topic_buf: [32]u8 = undefined;
        const sym = signal.getSymbol();
        const topic_len = std.fmt.bufPrint(&topic_buf, "SIGNAL:{s}", .{sym}) catch return error.TopicFormatFailed;

        // Send multipart: [topic][signal_data]
        // Part 1: Topic (with SNDMORE flag)
        var rc = c.zmq_send(self.socket, topic_buf[0..topic_len.len].ptr, topic_len.len, c.ZMQ_SNDMORE);
        if (rc < 0) {
            return error.SendFailed;
        }

        // Part 2: Signal data (binary)
        rc = c.zmq_send(self.socket, signal, @sizeOf(TradingSignal), 0);
        if (rc < 0) {
            return error.SendFailed;
        }

        _ = self.signals_sent.fetchAdd(1, .monotonic);
        _ = self.bytes_sent.fetchAdd(@sizeOf(TradingSignal) + topic_len.len, .monotonic);
    }

    /// Publish a heartbeat message
    pub fn publishHeartbeat(self: *Self) !void {
        const topic = "HEARTBEAT";
        const timestamp = getNanoTimestamp();

        // Send multipart: [topic][timestamp]
        var rc = c.zmq_send(self.socket, topic, topic.len, c.ZMQ_SNDMORE);
        if (rc < 0) return error.SendFailed;

        rc = c.zmq_send(self.socket, &timestamp, @sizeOf(i64), 0);
        if (rc < 0) return error.SendFailed;
    }

    /// Get statistics
    pub fn getStats(self: *const Self) struct { signals: u64, bytes: u64 } {
        return .{
            .signals = self.signals_sent.load(.acquire),
            .bytes = self.bytes_sent.load(.acquire),
        };
    }
};

// =============================================================================
// Signal Subscriber (Client)
// =============================================================================

pub const SignalSubscriber = struct {
    const Self = @This();

    context: ?*anyopaque,
    socket: ?*anyopaque,
    signals_received: std.atomic.Value(u64),
    last_sequence: std.atomic.Value(u64),

    pub fn init(endpoint: [*:0]const u8) !Self {
        // Create ZeroMQ context
        const context = c.zmq_ctx_new();
        if (context == null) {
            return error.ZMQContextFailed;
        }
        errdefer _ = c.zmq_ctx_destroy(context);

        // Create SUB socket
        const socket = c.zmq_socket(context, c.ZMQ_SUB);
        if (socket == null) {
            return error.ZMQSocketFailed;
        }
        errdefer _ = c.zmq_close(socket);

        // Set socket options
        var rcvhwm: c_int = 100000;
        _ = c.zmq_setsockopt(socket, c.ZMQ_RCVHWM, &rcvhwm, @sizeOf(c_int));

        // Connect to publisher
        if (c.zmq_connect(socket, endpoint) != 0) {
            return error.ZMQConnectFailed;
        }

        std.debug.print("📡 Signal subscriber connected to: {s}\n", .{endpoint});

        return .{
            .context = context,
            .socket = socket,
            .signals_received = std.atomic.Value(u64).init(0),
            .last_sequence = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.socket) |socket| {
            _ = c.zmq_close(socket);
        }
        if (self.context) |ctx| {
            _ = c.zmq_ctx_destroy(ctx);
        }
        std.debug.print("📡 Signal subscriber closed\n", .{});
    }

    /// Subscribe to signals for a specific symbol
    /// Pass empty string to subscribe to all signals
    pub fn subscribe(self: *Self, symbol: []const u8) !void {
        var filter_buf: [32]u8 = undefined;
        const filter = if (symbol.len > 0)
            std.fmt.bufPrint(&filter_buf, "SIGNAL:{s}", .{symbol}) catch return error.FilterFormatFailed
        else
            "SIGNAL:";

        if (c.zmq_setsockopt(self.socket, c.ZMQ_SUBSCRIBE, filter.ptr, filter.len) != 0) {
            return error.SubscribeFailed;
        }

        std.debug.print("📡 Subscribed to: {s}\n", .{filter});
    }

    /// Subscribe to heartbeat messages
    pub fn subscribeHeartbeat(self: *Self) !void {
        if (c.zmq_setsockopt(self.socket, c.ZMQ_SUBSCRIBE, "HEARTBEAT", 9) != 0) {
            return error.SubscribeFailed;
        }
    }

    /// Receive a signal (blocking)
    pub fn receive(self: *Self, signal: *TradingSignal) !void {
        // Receive topic (discard)
        var topic_buf: [64]u8 = undefined;
        var rc = c.zmq_recv(self.socket, &topic_buf, topic_buf.len, 0);
        if (rc < 0) {
            return error.ReceiveFailed;
        }

        // Receive signal data
        rc = c.zmq_recv(self.socket, signal, @sizeOf(TradingSignal), 0);
        if (rc < 0) {
            return error.ReceiveFailed;
        }
        if (rc != @sizeOf(TradingSignal)) {
            return error.InvalidSignalSize;
        }

        _ = self.signals_received.fetchAdd(1, .monotonic);
        self.last_sequence.store(signal.sequence, .release);
    }

    /// Try to receive a signal (non-blocking)
    /// Returns false if no signal available
    pub fn tryReceive(self: *Self, signal: *TradingSignal) bool {
        // Receive topic (discard)
        var topic_buf: [64]u8 = undefined;
        var rc = c.zmq_recv(self.socket, &topic_buf, topic_buf.len, c.ZMQ_DONTWAIT);
        if (rc < 0) {
            return false;
        }

        // Receive signal data
        rc = c.zmq_recv(self.socket, signal, @sizeOf(TradingSignal), c.ZMQ_DONTWAIT);
        if (rc != @sizeOf(TradingSignal)) {
            return false;
        }

        _ = self.signals_received.fetchAdd(1, .monotonic);
        self.last_sequence.store(signal.sequence, .release);
        return true;
    }

    /// Get statistics
    pub fn getStats(self: *const Self) struct { received: u64, last_seq: u64 } {
        return .{
            .received = self.signals_received.load(.acquire),
            .last_seq = self.last_sequence.load(.acquire),
        };
    }
};

// =============================================================================
// C FFI Exports (for Rust integration)
// =============================================================================

// Publisher functions
export fn sentient_publisher_create(endpoint: [*:0]const u8) ?*SignalPublisher {
    const allocator = std.heap.c_allocator;
    const pub_ptr = allocator.create(SignalPublisher) catch return null;
    pub_ptr.* = SignalPublisher.init(endpoint) catch {
        allocator.destroy(pub_ptr);
        return null;
    };
    return pub_ptr;
}

export fn sentient_publisher_destroy(publisher: *SignalPublisher) void {
    publisher.deinit();
    std.heap.c_allocator.destroy(publisher);
}

export fn sentient_publisher_send(publisher: *SignalPublisher, signal: *TradingSignal) c_int {
    publisher.publish(signal) catch return -1;
    return 0;
}

export fn sentient_publisher_heartbeat(publisher: *SignalPublisher) c_int {
    publisher.publishHeartbeat() catch return -1;
    return 0;
}

export fn sentient_publisher_stats(publisher: *const SignalPublisher, signals: *u64, bytes: *u64) void {
    const stats = publisher.getStats();
    signals.* = stats.signals;
    bytes.* = stats.bytes;
}

// Subscriber functions
export fn sentient_subscriber_create(endpoint: [*:0]const u8) ?*SignalSubscriber {
    const allocator = std.heap.c_allocator;
    const sub_ptr = allocator.create(SignalSubscriber) catch return null;
    sub_ptr.* = SignalSubscriber.init(endpoint) catch {
        allocator.destroy(sub_ptr);
        return null;
    };
    return sub_ptr;
}

export fn sentient_subscriber_destroy(subscriber: *SignalSubscriber) void {
    subscriber.deinit();
    std.heap.c_allocator.destroy(subscriber);
}

export fn sentient_subscriber_subscribe(subscriber: *SignalSubscriber, symbol: [*:0]const u8) c_int {
    const sym_len = std.mem.len(symbol);
    subscriber.subscribe(symbol[0..sym_len]) catch return -1;
    return 0;
}

export fn sentient_subscriber_subscribe_all(subscriber: *SignalSubscriber) c_int {
    subscriber.subscribe("") catch return -1;
    return 0;
}

export fn sentient_subscriber_subscribe_heartbeat(subscriber: *SignalSubscriber) c_int {
    subscriber.subscribeHeartbeat() catch return -1;
    return 0;
}

export fn sentient_subscriber_recv(subscriber: *SignalSubscriber, signal: *TradingSignal) c_int {
    subscriber.receive(signal) catch return -1;
    return 0;
}

export fn sentient_subscriber_try_recv(subscriber: *SignalSubscriber, signal: *TradingSignal) c_int {
    return if (subscriber.tryReceive(signal)) 0 else -1;
}

export fn sentient_subscriber_stats(subscriber: *const SignalSubscriber, received: *u64, last_seq: *u64) void {
    const stats = subscriber.getStats();
    received.* = stats.received;
    last_seq.* = stats.last_seq;
}

// Signal creation helper
export fn sentient_signal_create() TradingSignal {
    return TradingSignal.init();
}

export fn sentient_signal_set_symbol(signal: *TradingSignal, symbol: [*:0]const u8) void {
    const len = std.mem.len(symbol);
    signal.setSymbol(symbol[0..len]);
}

// =============================================================================
// Test / Demo
// =============================================================================

pub fn main(init: std.process.Init) !void {
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);

    // Skip program name
    _ = args_iter.next();

    const mode = args_iter.next() orelse {
        std.debug.print("Usage: signal_broadcast <server|client> [endpoint]\n", .{});
        std.debug.print("  server: Run as signal publisher\n", .{});
        std.debug.print("  client: Run as signal subscriber\n", .{});
        return;
    };

    const endpoint_arg = args_iter.next();
    const endpoint = endpoint_arg orelse "tcp://127.0.0.1:5555";
    const endpoint_z: [:0]const u8 = @ptrCast(endpoint);

    if (std.mem.eql(u8, mode, "server")) {
        try runServer(endpoint_z);
    } else if (std.mem.eql(u8, mode, "client")) {
        try runClient(endpoint_z);
    } else {
        std.debug.print("Unknown mode: {s}\n", .{mode});
    }
}

fn runServer(endpoint: [:0]const u8) !void {
    std.debug.print("\n=== Sentient Network Signal Server ===\n\n", .{});

    var publisher = try SignalPublisher.init(endpoint);
    defer publisher.deinit();

    // Give subscribers time to connect
    std.debug.print("Waiting for subscribers...\n", .{});
    var ts = linux.timespec{ .sec = 1, .nsec = 0 };
    _ = linux.nanosleep(&ts, null);

    // Publish test signals
    const symbols = [_][]const u8{ "BTCUSD", "ETHUSD", "AAPL", "SPY" };
    var signal_count: u64 = 0;

    std.debug.print("Publishing signals (Ctrl+C to stop)...\n\n", .{});

    while (true) {
        for (symbols) |sym| {
            var signal = TradingSignal.init();
            signal.setSymbol(sym);
            signal.signal_id = signal_count;
            signal.action = .buy;
            signal.asset_class = if (std.mem.startsWith(u8, sym, "BTC") or std.mem.startsWith(u8, sym, "ETH"))
                .crypto
            else
                .stocks;
            signal.confidence = 85;
            signal.current_price = 95000.0;
            signal.target_price = 100000.0;
            signal.suggested_size_pct = 0.05;
            signal.max_leverage = 1.0;

            try publisher.publish(&signal);
            signal_count += 1;

            std.debug.print("📤 Published: {s} seq={d} action=BUY conf={d}%\n", .{
                signal.getSymbol(),
                signal.sequence,
                signal.confidence,
            });
        }

        // Heartbeat every second
        try publisher.publishHeartbeat();

        const stats = publisher.getStats();
        std.debug.print("   Stats: {d} signals, {d} bytes\n\n", .{ stats.signals, stats.bytes });

        var ts2 = linux.timespec{ .sec = 1, .nsec = 0 };
        _ = linux.nanosleep(&ts2, null);
    }
}

fn runClient(endpoint: [:0]const u8) !void {
    std.debug.print("\n=== Sentient Network Signal Client ===\n\n", .{});

    var subscriber = try SignalSubscriber.init(endpoint);
    defer subscriber.deinit();

    // Subscribe to all signals (but not heartbeats - receive() expects TradingSignal size)
    try subscriber.subscribe("");

    std.debug.print("Waiting for signals (Ctrl+C to stop)...\n\n", .{});

    var signal: TradingSignal = undefined;
    while (true) {
        try subscriber.receive(&signal);

        const latency_us = @divFloor(signal.ageMs() * 1000, 1);
        std.debug.print("📥 Received: {s} seq={d} action={s} conf={d}% latency={d}µs\n", .{
            signal.getSymbol(),
            signal.sequence,
            @tagName(signal.action),
            signal.confidence,
            latency_us,
        });
    }
}

// =============================================================================
// Tests
// =============================================================================

test "TradingSignal size" {
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(TradingSignal));
}

test "TradingSignal symbol" {
    const signal = TradingSignal.init();
    signal.setSymbol("BTCUSD");
    try std.testing.expectEqualStrings("BTCUSD", signal.getSymbol());
}

test "TradingSignal init" {
    const signal = TradingSignal.init();
    try std.testing.expectEqual(signal.signal_id, 0);
    try std.testing.expectEqual(signal.confidence, 0);
    try std.testing.expectEqual(signal.action, .buy);
}
