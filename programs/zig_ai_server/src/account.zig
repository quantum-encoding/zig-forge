// Account endpoint — GET /qai/v1/account/balance
// Tracks in-memory usage from API calls

const std = @import("std");
const http = std.http;
const router = @import("router.zig");
const Response = router.Response;

const TICKS_PER_USD: f64 = 10_000_000_000.0;

/// Global usage tracker (atomic for thread safety)
var total_cost_ticks: std.atomic.Value(i64) = .init(0);

/// Record cost from a chat completion
pub fn recordCost(cost_usd: f64) void {
    const ticks: i64 = @intFromFloat(cost_usd * TICKS_PER_USD);
    _ = total_cost_ticks.fetchAdd(ticks, .monotonic);
}

/// GET /qai/v1/account/balance
pub fn handleBalance(_: *http.Server.Request, allocator: std.mem.Allocator) Response {
    const spent_ticks = total_cost_ticks.load(.acquire);
    const spent_usd = @as(f64, @floatFromInt(spent_ticks)) / TICKS_PER_USD;

    const json = std.fmt.allocPrint(allocator,
        \\{{"balance_ticks":{d},"balance_usd":{d:.6},"spent_ticks":{d},"spent_usd":{d:.6}}}
    , .{ -spent_ticks, -spent_usd, spent_ticks, spent_usd }) catch {
        return .{ .status = .internal_server_error, .body =
            \\{"error":"internal","message":"Failed to build balance response"}
        };
    };
    return .{ .body = json };
}
