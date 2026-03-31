//! Mining Statistics and Metrics
//! Real-time performance tracking

const std = @import("std");

pub const MiningStats = struct {
    start_time: i64,
    hashes_total: std.atomic.Value(u64),
    shares_found: std.atomic.Value(u32),
    shares_accepted: std.atomic.Value(u32),
    shares_rejected: std.atomic.Value(u32),
    blocks_found: std.atomic.Value(u32),

    const Self = @This();

    pub fn init() Self {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);

        return .{
            .start_time = ts.sec,
            .hashes_total = std.atomic.Value(u64).init(0),
            .shares_found = std.atomic.Value(u32).init(0),
            .shares_accepted = std.atomic.Value(u32).init(0),
            .shares_rejected = std.atomic.Value(u32).init(0),
            .blocks_found = std.atomic.Value(u32).init(0),
        };
    }

    /// Get current hashrate (hashes/second)
    pub fn getHashrate(self: *const Self) f64 {
        const ts = std.posix.clock_gettime(.REALTIME) catch return 0.0;
        const elapsed = @as(f64, @floatFromInt(ts.sec - self.start_time));

        if (elapsed <= 0) return 0.0;

        const hashes = self.hashes_total.load(.monotonic);
        return @as(f64, @floatFromInt(hashes)) / elapsed;
    }

    /// Get uptime in seconds
    pub fn getUptime(self: *const Self) i64 {
        const ts = std.posix.clock_gettime(.REALTIME) catch return 0;
        return ts.sec - self.start_time;
    }

    /// Get acceptance rate (0.0 to 1.0)
    pub fn getAcceptanceRate(self: *const Self) f64 {
        const found = self.shares_found.load(.monotonic);
        const accepted = self.shares_accepted.load(.monotonic);

        if (found == 0) return 0.0;
        return @as(f64, @floatFromInt(accepted)) / @as(f64, @floatFromInt(found));
    }

    /// Format stats for display
    pub fn format(
        self: *const Self,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        const hashrate = self.getHashrate();
        const uptime = self.getUptime();
        const acceptance = self.getAcceptanceRate() * 100.0;

        const found = self.shares_found.load(.monotonic);
        const accepted = self.shares_accepted.load(.monotonic);
        const rejected = self.shares_rejected.load(.monotonic);
        const blocks = self.blocks_found.load(.monotonic);

        try writer.print(
            \\Uptime: {}s | Hashrate: {d:.2} MH/s
            \\Shares: {} found, {} accepted, {} rejected ({d:.1}%)
            \\Blocks: {}
        , .{
            uptime,
            hashrate / 1_000_000.0,
            found,
            accepted,
            rejected,
            acceptance,
            blocks,
        });
    }
};

/// Format duration in human-readable form
pub fn formatDuration(seconds: i64) ![]const u8 {
    const hours = @divFloor(seconds, 3600);
    const mins = @divFloor(@rem(seconds, 3600), 60);
    const secs = @rem(seconds, 60);

    var buf: [32]u8 = undefined;
    return try std.fmt.bufPrint(&buf, "{d}h {d}m {d}s", .{ hours, mins, secs });
}

test "stats init" {
    var stats = MiningStats.init();
    try std.testing.expect(stats.start_time > 0);
    try std.testing.expectEqual(@as(u64, 0), stats.hashes_total.load(.monotonic));
}
