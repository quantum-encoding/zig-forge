// Account endpoint — GET /qai/v1/account/balance
// Tracks in-memory usage from API calls using integer ticks (no floats in billing)

const std = @import("std");
const http = std.http;
const router = @import("router.zig");
const Response = router.Response;

// 1 USD = 10,000,000,000 ticks (10B). All billing in integer ticks.
pub const TICKS_PER_USD: i64 = 10_000_000_000;

/// Global usage tracker (atomic for thread safety)
var total_spent_ticks: std.atomic.Value(i64) = .init(0);

/// Record cost in integer ticks (no floating point in billing path)
pub fn recordTicks(ticks: i64) void {
    _ = total_spent_ticks.fetchAdd(ticks, .monotonic);
}

/// GET /qai/v1/account/balance
pub fn handleBalance(_: *http.Server.Request, allocator: std.mem.Allocator) Response {
    const spent = total_spent_ticks.load(.acquire);
    // Integer division for USD: spent_ticks / TICKS_PER_USD
    // We report microdollars for precision without floats
    const spent_microdollars = @divFloor(spent * 1_000_000, TICKS_PER_USD);

    const json = std.fmt.allocPrint(allocator,
        \\{{"spent_ticks":{d},"spent_microdollars":{d},"ticks_per_usd":{d}}}
    , .{ spent, spent_microdollars, TICKS_PER_USD }) catch {
        return .{ .status = .internal_server_error, .body =
            \\{"error":"internal","message":"Failed to build balance response"}
        };
    };
    return .{ .body = json };
}
