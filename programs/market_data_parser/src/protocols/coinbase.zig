//! Coinbase Advanced Trade WebSocket Protocol Parser

const std = @import("std");

pub const MessageType = enum {
    snapshot,
    l2_update,
    ticker,
    heartbeat,
    unknown,
};

/// Coinbase L2 snapshot
pub const L2Snapshot = struct {
    product_id: []const u8,
    bids: []const [2][]const u8,  // [price, size]
    asks: []const [2][]const u8,

    pub fn parse(msg: []const u8) !L2Snapshot {
        _ = msg;
        return error.NotImplemented;
    }
};

/// Coinbase L2 update
pub const L2Update = struct {
    product_id: []const u8,
    changes: []const [3][]const u8,  // [side, price, size]
    time: []const u8,

    pub fn parse(msg: []const u8) !L2Update {
        _ = msg;
        return error.NotImplemented;
    }
};

test "coinbase message types" {
    try std.testing.expect(true);
}
