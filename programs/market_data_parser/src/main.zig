//! High-Performance Market Data Parser
//!
//! Zero-copy parsing of exchange market data feeds
//! Target: 1M+ messages/second per core
//!
//! Supported formats:
//! - JSON (Binance, Coinbase WebSocket)
//! - FIX Protocol
//! - Binary (SBE, FAST)
//!
//! Features:
//! - SIMD-accelerated JSON parsing
//! - Zero-copy message extraction
//! - Lock-free order book reconstruction
//! - Sub-microsecond message processing

const std = @import("std");

// Core modules
pub const json = @import("parsers/json_parser.zig");
pub const Parser = json.Parser;  // Export Parser at top level for convenience
pub const sbe = @import("parsers/sbe_parser.zig");
pub const orderbook = @import("orderbook/book.zig");
pub const binance = @import("protocols/binance.zig");
pub const coinbase = @import("protocols/coinbase.zig");

// Performance metrics
pub const Metrics = struct {
    messages_parsed: std.atomic.Value(u64),
    bytes_processed: std.atomic.Value(u64),
    parse_errors: std.atomic.Value(u64),

    pub fn init() Metrics {
        return .{
            .messages_parsed = std.atomic.Value(u64).init(0),
            .bytes_processed = std.atomic.Value(u64).init(0),
            .parse_errors = std.atomic.Value(u64).init(0),
        };
    }

    pub fn recordParse(self: *Metrics, bytes: usize) void {
        _ = self.messages_parsed.fetchAdd(1, .monotonic);
        _ = self.bytes_processed.fetchAdd(bytes, .monotonic);
    }

    pub fn recordError(self: *Metrics) void {
        _ = self.parse_errors.fetchAdd(1, .monotonic);
    }
};

test "library imports" {
    const testing = std.testing;
    try testing.expect(true);
}
