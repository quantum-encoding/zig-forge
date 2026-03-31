/// Market data pipeline stage.
///
/// Parses exchange feed messages directly from packet mbuf data (zero-copy).
/// Updates order books and produces MarketTick events for the trading engine.
///
/// Supported formats:
///   - Binance WebSocket depth updates
///   - Generic JSON orderbook updates
///
/// Full pipeline path:
///   NIC → Ethernet → IPv4 → UDP → this stage → OrderBook → MarketTick → HFT
///
/// This stage is designed to be used as a comptime Pipeline stage:
///   const TradingPipeline = Pipeline(&.{
///       EthernetFilter,
///       Ipv4Validate,
///       UdpPortFilter(9000),
///       MarketDataStage,
///   });

const std = @import("std");
const mbuf_mod = @import("../core/mbuf.zig");
const pipeline_mod = @import("../pipeline/pipeline.zig");
const ethernet = @import("../net/ethernet.zig");
const ipv4 = @import("../net/ipv4.zig");
const udp = @import("../net/udp.zig");
const json_kv = @import("json_kv.zig");
const order_book_mod = @import("order_book.zig");
const decimal_mod = @import("decimal.zig");

const MBuf = mbuf_mod.MBuf;
const OrderBook = order_book_mod.OrderBook;
const Decimal = decimal_mod.Decimal;

/// Market tick event — the output of parsing, input to trading strategy.
/// Compatible with financial_engine's MarketTick.
pub const MarketTick = struct {
    symbol: [16]u8 = [_]u8{0} ** 16,
    bid: Decimal = Decimal.ZERO,
    ask: Decimal = Decimal.ZERO,
    bid_size: Decimal = Decimal.ZERO,
    ask_size: Decimal = Decimal.ZERO,
    timestamp_ns: u64 = 0,
    sequence: u64 = 0,

    pub fn fromOrderBook(book: *const OrderBook) MarketTick {
        var tick = MarketTick{};
        tick.symbol = book.symbol;
        if (book.bestBid()) |bb| {
            tick.bid = bb.price;
            tick.bid_size = bb.quantity;
        }
        if (book.bestAsk()) |ba| {
            tick.ask = ba.price;
            tick.ask_size = ba.quantity;
        }
        tick.sequence = book.sequence;
        return tick;
    }
};

/// Market data processing statistics.
pub const MarketDataStats = struct {
    messages_parsed: u64 = 0,
    depth_updates: u64 = 0,
    trades: u64 = 0,
    parse_errors: u64 = 0,
    unknown_symbols: u64 = 0,
    unknown_events: u64 = 0,
};

/// Maximum number of tracked symbols.
pub const MAX_SYMBOLS: u8 = 64;

/// Market data processor state.
/// Holds order books and stats. Not a pipeline stage itself (has state),
/// but provides methods that pipeline stages call.
pub const MarketDataProcessor = struct {
    books: [MAX_SYMBOLS]OrderBook = undefined,
    book_count: u8 = 0,
    stats: MarketDataStats = .{},
    tick_callback: ?*const fn (MarketTick) void = null,

    pub fn init() MarketDataProcessor {
        var proc = MarketDataProcessor{};
        for (&proc.books) |*b| {
            b.* = OrderBook.init("");
        }
        return proc;
    }

    /// Register a symbol for tracking. Returns the book index.
    pub fn addSymbol(self: *MarketDataProcessor, symbol: []const u8) ?u8 {
        if (self.book_count >= MAX_SYMBOLS) return null;
        const idx = self.book_count;
        self.books[idx] = OrderBook.init(symbol);
        self.book_count += 1;
        return idx;
    }

    /// Find an order book by symbol name.
    pub fn findBook(self: *MarketDataProcessor, symbol: []const u8) ?*OrderBook {
        for (self.books[0..self.book_count]) |*book| {
            const sym_len = symbolLen(&book.symbol);
            if (sym_len == symbol.len and std.mem.eql(u8, book.symbol[0..sym_len], symbol)) {
                return book;
            }
        }
        return null;
    }

    /// Process a raw JSON market data message. Zero-copy from packet buffer.
    pub fn processMessage(self: *MarketDataProcessor, payload: []const u8) void {
        self.stats.messages_parsed += 1;

        // Extract event type
        const event = json_kv.findValue(payload, "e") orelse {
            self.stats.parse_errors += 1;
            return;
        };

        if (std.mem.eql(u8, event, "depthUpdate")) {
            self.processDepthUpdate(payload);
        } else if (std.mem.eql(u8, event, "trade")) {
            self.stats.trades += 1;
        } else {
            self.stats.unknown_events += 1;
        }
    }

    fn processDepthUpdate(self: *MarketDataProcessor, payload: []const u8) void {
        const symbol = json_kv.findValue(payload, "s") orelse {
            self.stats.parse_errors += 1;
            return;
        };

        const book = self.findBook(symbol) orelse {
            self.stats.unknown_symbols += 1;
            return;
        };

        // Parse bids: "b":[["price","qty"],...]
        if (json_kv.findValue(payload, "b")) |bids_arr| {
            const BidUpdater = struct {
                var target_book: *OrderBook = undefined;
                fn update(price: []const u8, qty: []const u8) void {
                    target_book.updateBidStr(price, qty);
                }
            };
            BidUpdater.target_book = book;
            json_kv.iteratePriceLevels(bids_arr, BidUpdater.update);
        }

        // Parse asks: "a":[["price","qty"],...]
        if (json_kv.findValue(payload, "a")) |asks_arr| {
            const AskUpdater = struct {
                var target_book: *OrderBook = undefined;
                fn update(price: []const u8, qty: []const u8) void {
                    target_book.updateAskStr(price, qty);
                }
            };
            AskUpdater.target_book = book;
            json_kv.iteratePriceLevels(asks_arr, AskUpdater.update);
        }

        book.sequence +%= 1;
        self.stats.depth_updates += 1;

        // Emit tick if callback registered
        if (self.tick_callback) |cb| {
            cb(MarketTick.fromOrderBook(book));
        }
    }

    /// Process a complete UDP payload from an mbuf.
    /// Strips protocol headers and calls processMessage on the payload.
    pub fn processPacket(self: *MarketDataProcessor, pkt_data: []const u8) void {
        // Parse Ethernet → IPv4 → UDP → payload
        // For raw mbuf data, we need mutable access for parsing but only read
        // We use @constCast since our parsers don't actually modify the data
        if (pkt_data.len < 42) return; // min: 14 eth + 20 ip + 8 udp

        // Check EtherType (bytes 12-13)
        if (pkt_data[12] != 0x08 or pkt_data[13] != 0x00) return; // not IPv4

        // Check protocol (byte 23)
        if (pkt_data[23] != 17) return; // not UDP

        // IPv4 header length
        const ihl: u16 = @as(u16, pkt_data[14] & 0x0F) * 4;
        const udp_offset = 14 + ihl;
        if (udp_offset + 8 > pkt_data.len) return;

        // UDP payload starts after UDP header
        const payload_offset = udp_offset + 8;
        if (payload_offset >= pkt_data.len) return;

        self.processMessage(pkt_data[payload_offset..]);
    }
};

fn symbolLen(sym: *const [16]u8) usize {
    for (sym, 0..) |c, i| {
        if (c == 0) return i;
    }
    return 16;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "market_data: process depth update" {
    var proc = MarketDataProcessor.init();
    _ = proc.addSymbol("BTCUSDT");

    const msg =
        \\{"e":"depthUpdate","s":"BTCUSDT","b":[["50000.00","1.5"],["49999.00","2.0"]],"a":[["50001.00","0.5"]]}
    ;
    proc.processMessage(msg);

    try testing.expectEqual(@as(u64, 1), proc.stats.depth_updates);

    const book = proc.findBook("BTCUSDT").?;
    try testing.expectEqual(@as(u32, 2), book.bid_count);
    try testing.expectEqual(@as(u32, 1), book.ask_count);
    try testing.expect(@abs(book.bestBid().?.price.toFloat() - 50000.0) < 0.01);
    try testing.expect(@abs(book.bestAsk().?.price.toFloat() - 50001.0) < 0.01);
}

test "market_data: multiple updates accumulate" {
    var proc = MarketDataProcessor.init();
    _ = proc.addSymbol("ETHUSDT");

    proc.processMessage("{\"e\":\"depthUpdate\",\"s\":\"ETHUSDT\",\"b\":[[\"3000.00\",\"5.0\"]],\"a\":[[\"3001.00\",\"3.0\"]]}");
    proc.processMessage("{\"e\":\"depthUpdate\",\"s\":\"ETHUSDT\",\"b\":[[\"2999.00\",\"8.0\"]],\"a\":[[\"3002.00\",\"1.0\"]]}");

    const book = proc.findBook("ETHUSDT").?;
    try testing.expectEqual(@as(u32, 2), book.bid_count);
    try testing.expectEqual(@as(u32, 2), book.ask_count);
    try testing.expectEqual(@as(u64, 2), book.sequence);
}

test "market_data: unknown symbol tracked" {
    var proc = MarketDataProcessor.init();
    _ = proc.addSymbol("BTCUSDT");

    proc.processMessage("{\"e\":\"depthUpdate\",\"s\":\"UNKNOWN\",\"b\":[],\"a\":[]}");
    try testing.expectEqual(@as(u64, 1), proc.stats.unknown_symbols);
}

test "market_data: MarketTick from order book" {
    var book = OrderBook.init("BTCUSDT");
    book.updateBid(Decimal.fromFloat(50000.0), Decimal.fromFloat(1.5));
    book.updateAsk(Decimal.fromFloat(50001.0), Decimal.fromFloat(0.5));
    book.sequence = 42;

    const tick = MarketTick.fromOrderBook(&book);
    try testing.expect(@abs(tick.bid.toFloat() - 50000.0) < 0.01);
    try testing.expect(@abs(tick.ask.toFloat() - 50001.0) < 0.01);
    try testing.expectEqual(@as(u64, 42), tick.sequence);
}

test "market_data: trade event counted" {
    var proc = MarketDataProcessor.init();
    proc.processMessage("{\"e\":\"trade\",\"s\":\"BTCUSDT\",\"p\":\"50000\",\"q\":\"0.1\"}");
    try testing.expectEqual(@as(u64, 1), proc.stats.trades);
}

test "market_data: stats tracking" {
    var proc = MarketDataProcessor.init();
    _ = proc.addSymbol("BTCUSDT");

    proc.processMessage("{\"e\":\"depthUpdate\",\"s\":\"BTCUSDT\",\"b\":[],\"a\":[]}");
    proc.processMessage("{\"e\":\"trade\",\"s\":\"BTCUSDT\"}");
    proc.processMessage("{\"e\":\"unknown_event\"}");
    proc.processMessage("invalid json");

    try testing.expectEqual(@as(u64, 4), proc.stats.messages_parsed);
    try testing.expectEqual(@as(u64, 1), proc.stats.depth_updates);
    try testing.expectEqual(@as(u64, 1), proc.stats.trades);
    try testing.expectEqual(@as(u64, 1), proc.stats.unknown_events);
    try testing.expectEqual(@as(u64, 1), proc.stats.parse_errors);
}
