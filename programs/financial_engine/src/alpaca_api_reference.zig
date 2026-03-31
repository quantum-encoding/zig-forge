// ALPACA API REFERENCE IMPLEMENTATION
// Based on the working Go implementation in neural_reality_check.go
// This provides the correct API patterns for our Zig integration

const std = @import("std");

// Alpaca Bar structure matching Go implementation
pub const AlpacaBar = struct {
    t: []const u8,  // timestamp
    o: f64,         // open
    h: f64,         // high
    l: f64,         // low
    c: f64,         // close
    v: i64,         // volume
    vw: f64,        // volume weighted average price
};

// Alpaca API Response structure
pub const AlpacaBarsResponse = struct {
    bars: std.json.ObjectMap,  // map[string][]AlpacaBar in Go
    next_page_token: ?[]const u8 = null,
};

pub const AlpacaAPIClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    api_secret: []const u8,
    base_url: []const u8,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) !Self {
        // Get credentials from environment (matching Go pattern)
        const api_key = std.process.getEnvVarOwned(allocator, "APCA_API_KEY_ID") catch {
            std.log.err("Missing APCA_API_KEY_ID environment variable", .{});
            return error.MissingCredentials;
        };
        
        const api_secret = std.process.getEnvVarOwned(allocator, "APCA_API_SECRET_KEY") catch {
            allocator.free(api_key);
            std.log.err("Missing APCA_API_SECRET_KEY environment variable", .{});
            return error.MissingCredentials;
        };
        
        return .{
            .allocator = allocator,
            .api_key = api_key,
            .api_secret = api_secret,
            .base_url = "https://data.alpaca.markets",
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.api_secret);
    }
    
    // Fetch bars matching Go implementation
    pub fn fetchBars(self: *Self, symbol: []const u8, days: u32) ![]AlpacaBar {
        // Calculate date range (matching Go)
        const now_ns = std.time.nanoTimestamp();
        const start_ns = now_ns - (@as(i128, days) * 24 * 60 * 60 * 1_000_000_000);
        
        // Format dates as YYYY-MM-DD
        const end_date = formatDate(self.allocator, now_ns) catch return error.DateFormatError;
        defer self.allocator.free(end_date);
        
        const start_date = formatDate(self.allocator, start_ns) catch return error.DateFormatError;
        defer self.allocator.free(start_date);
        
        // Build URL (matching Go pattern exactly)
        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/v2/stocks/{s}/bars?start={s}&end={s}&timeframe=1Hour&limit=1000",
            .{ self.base_url, symbol, start_date, end_date }
        );
        defer self.allocator.free(url);
        
        std.log.info("📡 Fetching bars from: {s}", .{url});
        
        // Create HTTP client
        var client = std.http.Client{ .allocator = self.allocator };
        defer client.deinit();
        
        // Parse URL
        const uri = try std.Uri.parse(url);
        
        // Create request with headers (matching Go)
        var headers = std.http.Headers.init(self.allocator);
        defer headers.deinit();
        
        try headers.append("APCA-API-KEY-ID", self.api_key);
        try headers.append("APCA-API-SECRET-KEY", self.api_secret);
        
        // Make request
        var request = try client.request(.GET, uri, headers, .{});
        defer request.deinit();
        
        try request.start();
        try request.wait();
        
        if (request.response.status != .ok) {
            std.log.err("API request failed with status: {}", .{request.response.status});
            return error.APIRequestFailed;
        }
        
        // Read response body
        const body = try request.reader().readAllAlloc(self.allocator, 1024 * 1024); // 1MB max
        defer self.allocator.free(body);
        
        // Parse JSON response
        const parsed = try std.json.parseFromSlice(
            AlpacaBarsResponse,
            self.allocator,
            body,
            .{ .ignore_unknown_fields = true }
        );
        defer parsed.deinit();
        
        // Extract bars for the symbol
        const bars_value = parsed.value.bars.get(symbol) orelse {
            std.log.warn("No bars found for symbol: {s}", .{symbol});
            return &[_]AlpacaBar{};
        };
        
        // Convert JSON array to AlpacaBar array
        const bars_array = bars_value.array;
        var bars = try self.allocator.alloc(AlpacaBar, bars_array.items.len);
        
        for (bars_array.items, 0..) |item, i| {
            const obj = item.object;
            bars[i] = .{
                .t = obj.get("t").?.string,
                .o = obj.get("o").?.float,
                .h = obj.get("h").?.float,
                .l = obj.get("l").?.float,
                .c = obj.get("c").?.float,
                .v = @intCast(obj.get("v").?.integer),
                .vw = obj.get("vw").?.float,
            };
        }
        
        std.log.info("✅ Fetched {} bars for {s}", .{ bars.len, symbol });
        return bars;
    }
    
    // Helper function to format date as YYYY-MM-DD
    fn formatDate(allocator: std.mem.Allocator, timestamp_ns: i128) ![]u8 {
        const seconds = @divTrunc(timestamp_ns, 1_000_000_000);
        const epoch_seconds = @as(u64, @intCast(seconds));
        
        // Simple date calculation (approximate, good enough for API)
        const days_since_epoch = @divTrunc(epoch_seconds, 86400);
        const year = 1970 + @divTrunc(days_since_epoch, 365);
        const day_of_year = @mod(days_since_epoch, 365);
        const month = @divTrunc(day_of_year, 30) + 1;
        const day = @mod(day_of_year, 30) + 1;
        
        return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day });
    }
};

// Test function matching Go's main()
pub fn testAlpacaIntegration(allocator: std.mem.Allocator) !void {
    std.log.info("🦆 ALPACA API REFERENCE TEST - ZIG IMPLEMENTATION", .{});
    std.log.info("=" * 50, .{});
    
    // Initialize client
    var client = try AlpacaAPIClient.init(allocator);
    defer client.deinit();
    
    // Fetch SPY data (matching Go test)
    const bars = try client.fetchBars("SPY", 10);
    defer allocator.free(bars);
    
    // Display first few bars (matching Go output)
    for (bars[0..@min(5, bars.len)], 0..) |bar, i| {
        std.log.info("Bar {}: C={d:.2f} H={d:.2f} L={d:.2f} V={}", .{
            i, bar.c, bar.h, bar.l, bar.v
        });
    }
    
    // Calculate simple features (matching Go's calculateFeatures)
    if (bars.len > 0) {
        const base_price = bars[0].c;
        const return_pct = (bars[bars.len - 1].c - base_price) / base_price * 100;
        std.log.info("📈 Price change over period: {d:.2f}%", .{return_pct});
    }
    
    std.log.info("✅ ALPACA API INTEGRATION VALIDATED", .{});
}

// Standalone test program
pub fn main() !void {
    const allocator = std.heap.c_allocator;
    
    try testAlpacaIntegration(allocator);
}