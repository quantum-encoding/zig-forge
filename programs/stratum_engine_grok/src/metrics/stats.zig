const std = @import("std");

pub const Stats = struct {
    allocator: std.mem.Allocator,
    start_time: i64,
    shares_submitted: std.atomic.Value(u64),
    shares_accepted: std.atomic.Value(u64),
    hashrate: std.atomic.Value(f64),
    latency_sum: std.atomic.Value(u64),
    latency_count: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator) Stats {
        return .{
            .allocator = allocator,
            .start_time = 0,
            .shares_submitted = std.atomic.Value(u64).init(0),
            .shares_accepted = std.atomic.Value(u64).init(0),
            .hashrate = std.atomic.Value(f64).init(0.0),
            .latency_sum = std.atomic.Value(u64).init(0),
            .latency_count = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *Stats) void {
        _ = self;
    }

    pub fn recordShareSubmitted(self: *Stats) void {
        _ = self.shares_submitted.fetchAdd(1, .monotonic);
    }

    pub fn recordShareAccepted(self: *Stats) void {
        _ = self.shares_accepted.fetchAdd(1, .monotonic);
    }

    pub fn recordLatency(self: *Stats, latency_ms: u64) void {
        _ = self.latency_sum.fetchAdd(latency_ms, .monotonic);
        _ = self.latency_count.fetchAdd(1, .monotonic);
    }

    pub fn updateHashrate(self: *Stats, new_hashrate: f64) void {
        self.hashrate.store(new_hashrate, .monotonic);
    }

    pub fn getUptime(self: *Stats) f64 {
        _ = self;
        return 0.0;
    }

    pub fn getAverageLatency(self: *Stats) f64 {
        const sum = self.latency_sum.load(.monotonic);
        const count = self.latency_count.load(.monotonic);
        if (count == 0) return 0.0;
        return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(count));
    }

    pub fn printStats(self: *Stats) void {
        const submitted = self.shares_submitted.load(.monotonic);
        const accepted = self.shares_accepted.load(.monotonic);
        const hashrate = self.hashrate.load(.monotonic);
        const uptime = self.getUptime();
        const avg_latency = self.getAverageLatency();

        std.debug.print("Uptime: {d:.1}s, Hashrate: {d:.2} MH/s, Shares: {}/{}, Avg Latency: {d:.1}ms\n",
            .{uptime, hashrate / 1e6, accepted, submitted, avg_latency});
    }
};