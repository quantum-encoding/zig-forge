const std = @import("std");
const crypto_receipt = @import("crypto_receipt.zig");

pub const CryptoPaymentBlock = struct {
    network: []const u8 = "",
    to_address: []const u8 = "",
    from_address: []const u8 = "",
    amount: []const u8 = "",
    currency: []const u8 = "",

    pub fn deinit(self: *CryptoPaymentBlock, allocator: std.mem.Allocator) void {
        if (self.network.len > 0) allocator.free(self.network);
        if (self.to_address.len > 0) allocator.free(self.to_address);
        if (self.from_address.len > 0) allocator.free(self.from_address);
        if (self.amount.len > 0) allocator.free(self.amount);
        if (self.currency.len > 0) allocator.free(self.currency);
        self.* = .{};
    }

    pub fn getNetwork(self: CryptoPaymentBlock) crypto_receipt.Network {
        if (self.network.len == 0) return .custom;
        var buf: [128]u8 = undefined;
        if (self.network.len > buf.len) return .custom;
        const lower = std.ascii.lowerString(&buf, self.network);
        if (std.mem.indexOf(u8, lower, "bitcoin") != null or std.mem.indexOf(u8, lower, "btc") != null) {
            if (std.mem.indexOf(u8, lower, "cash") != null or std.mem.indexOf(u8, lower, "bch") != null) {
                return .bitcoin_cash;
            }
            return .bitcoin;
        }
        if (std.mem.indexOf(u8, lower, "ethereum") != null or std.mem.indexOf(u8, lower, "eth") != null) return .ethereum;
        if (std.mem.indexOf(u8, lower, "polygon") != null or std.mem.indexOf(u8, lower, "matic") != null) return .polygon;
        if (std.mem.indexOf(u8, lower, "litecoin") != null or std.mem.indexOf(u8, lower, "ltc") != null) return .litecoin;
        if (std.mem.indexOf(u8, lower, "solana") != null or std.mem.indexOf(u8, lower, "sol") != null) return .solana;
        if (std.mem.indexOf(u8, lower, "tron") != null or std.mem.indexOf(u8, lower, "trx") != null) return .tron;
        if (std.mem.indexOf(u8, lower, "dogecoin") != null or std.mem.indexOf(u8, lower, "doge") != null) return .dogecoin;
        if (std.mem.indexOf(u8, lower, "cardano") != null or std.mem.indexOf(u8, lower, "ada") != null) return .cardano;
        if (std.mem.indexOf(u8, lower, "ripple") != null or std.mem.indexOf(u8, lower, "xrp") != null) return .xrp;
        if (std.mem.indexOf(u8, lower, "binance") != null or std.mem.indexOf(u8, lower, "bnb") != null) return .bnb;
        if (std.mem.indexOf(u8, lower, "tether") != null or std.mem.indexOf(u8, lower, "usdt") != null) return .usdt;
        if (std.mem.indexOf(u8, lower, "usdc") != null) return .usdc;
        if (std.mem.indexOf(u8, lower, "lightning") != null) return .lightning;
        return crypto_receipt.Network.fromString(lower);
    }
};
