//! Miner Registry - Track connected miners and compute statistics
//!
//! Provides:
//! - Per-miner statistics (hashrate, shares, uptime)
//! - Fleet-wide aggregates
//! - Rolling averages and trend detection
//! - Alerting for hashrate drops, offline miners

const std = @import("std");
const server = @import("server.zig");
const compat = @import("../utils/compat.zig");

/// ASIC model specifications for hashrate estimation
pub const AsicModel = struct {
    name: []const u8,
    manufacturer: []const u8,
    expected_hashrate_th: f64, // TH/s
    power_watts: u32,
    efficiency: f64, // J/TH

    pub const UNKNOWN = AsicModel{
        .name = "Unknown",
        .manufacturer = "Unknown",
        .expected_hashrate_th = 0,
        .power_watts = 0,
        .efficiency = 0,
    };

    // Common ASIC models
    pub const ANTMINER_S21 = AsicModel{
        .name = "Antminer S21",
        .manufacturer = "Bitmain",
        .expected_hashrate_th = 200,
        .power_watts = 3500,
        .efficiency = 17.5,
    };

    pub const ANTMINER_S19_XP = AsicModel{
        .name = "Antminer S19 XP",
        .manufacturer = "Bitmain",
        .expected_hashrate_th = 140,
        .power_watts = 3010,
        .efficiency = 21.5,
    };

    pub const WHATSMINER_M50 = AsicModel{
        .name = "Whatsminer M50",
        .manufacturer = "MicroBT",
        .expected_hashrate_th = 126,
        .power_watts = 3276,
        .efficiency = 26,
    };

    pub const WHATSMINER_M60 = AsicModel{
        .name = "Whatsminer M60",
        .manufacturer = "MicroBT",
        .expected_hashrate_th = 186,
        .power_watts = 3422,
        .efficiency = 18.4,
    };
};

/// Extended miner information for dashboard
pub const MinerInfo = struct {
    /// Basic connection info
    id: u64,
    name: []const u8,
    ip_address: []const u8,
    status: MinerStatus,

    /// ASIC model (detected or manual)
    model: AsicModel,

    /// Performance stats
    current_hashrate_th: f64, // Estimated from shares
    hashrate_1h: f64, // Rolling 1-hour average
    hashrate_24h: f64, // Rolling 24-hour average

    /// Share stats
    shares_accepted: u64,
    shares_rejected: u64,
    shares_stale: u64,
    accept_rate: f64, // percentage

    /// Current pool assignment
    pool_name: []const u8,
    pool_difficulty: f64,

    /// Timing
    connected_at: i64,
    last_share_time: i64,
    uptime_seconds: i64,

    /// Power estimation (from model)
    estimated_power_watts: u32,

    pub const MinerStatus = enum {
        online,
        offline,
        error_state,
        low_hashrate,
    };

    pub fn getUptimeFormatted(self: *const MinerInfo) [16]u8 {
        var buf: [16]u8 = undefined;
        const days = @divFloor(self.uptime_seconds, 86400);
        const hours = @divFloor(@mod(self.uptime_seconds, 86400), 3600);
        const mins = @divFloor(@mod(self.uptime_seconds, 3600), 60);

        _ = std.fmt.bufPrint(&buf, "{}d {}h {}m", .{
            @as(u32, @intCast(days)),
            @as(u32, @intCast(hours)),
            @as(u32, @intCast(mins)),
        }) catch {};

        return buf;
    }
};

/// Fleet-wide statistics
pub const FleetStats = struct {
    /// Miner counts
    total_miners: u32,
    online_miners: u32,
    offline_miners: u32,
    error_miners: u32,

    /// Aggregate hashrate
    total_hashrate_th: f64,
    total_hashrate_1h: f64,
    total_hashrate_24h: f64,

    /// Share stats
    total_accepted: u64,
    total_rejected: u64,
    total_stale: u64,
    fleet_accept_rate: f64,

    /// Earnings (updated by profitability engine)
    btc_earned_24h: f64,
    btc_earned_total: f64,

    /// Power consumption
    total_power_watts: u64,

    /// Average latency
    avg_share_latency_ms: f64,

    /// Last update timestamp
    updated_at: i64,
};

/// Hashrate sample for rolling averages
const HashrateSample = struct {
    timestamp: i64,
    hashrate_th: f64,
};

/// Alert types for monitoring
pub const Alert = struct {
    timestamp: i64,
    severity: Severity,
    miner_id: ?u64,
    miner_name: ?[]const u8,
    message: []const u8,
    acknowledged: bool,

    pub const Severity = enum {
        info,
        warning,
        critical,
    };
};

/// Miner Registry - Central tracker for all connected miners
pub const MinerRegistry = struct {
    allocator: std.mem.Allocator,

    /// Miner data indexed by ID
    miners: std.AutoHashMap(u64, *MinerData),

    /// Hashrate history per miner (for rolling averages)
    hashrate_history: std.AutoHashMap(u64, std.ArrayList(HashrateSample)),

    /// Alert queue
    alerts: std.ArrayList(Alert),

    /// Cached fleet stats
    fleet_stats: FleetStats,
    fleet_stats_dirty: bool,

    /// Configuration
    config: Config,

    const Self = @This();

    pub const Config = struct {
        /// How often to sample hashrate (seconds)
        sample_interval_s: u32 = 60,

        /// Hashrate drop threshold for alerts (percentage)
        hashrate_drop_alert_pct: f64 = 50.0,

        /// Offline timeout (seconds without share)
        offline_timeout_s: u32 = 300,

        /// Max hashrate samples to keep per miner
        max_hashrate_samples: u32 = 1440, // 24 hours at 1-minute intervals
    };

    /// Internal miner data with extended tracking
    const MinerData = struct {
        info: MinerInfo,
        last_sample_time: i64,
        share_count_since_sample: u32,
        pool_difficulty: f64,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
        return .{
            .allocator = allocator,
            .miners = std.AutoHashMap(u64, *MinerData).init(allocator),
            .hashrate_history = std.AutoHashMap(u64, std.ArrayList(HashrateSample)).init(allocator),
            .alerts = try std.ArrayList(Alert).initCapacity(allocator, 100),
            .fleet_stats = std.mem.zeroes(FleetStats),
            .fleet_stats_dirty = true,
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.miners.iterator();
        while (it.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.miners.deinit();

        var hist_it = self.hashrate_history.iterator();
        while (hist_it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.hashrate_history.deinit();

        self.alerts.deinit(self.allocator);
    }

    /// Register a new miner connection
    pub fn registerMiner(self: *Self, conn: server.MinerConnection) !void {
        const data = try self.allocator.create(MinerData);
        data.* = .{
            .info = .{
                .id = conn.id,
                .name = conn.worker_name orelse "unknown",
                .ip_address = conn.getIpString(),
                .status = .online,
                .model = AsicModel.UNKNOWN,
                .current_hashrate_th = 0,
                .hashrate_1h = 0,
                .hashrate_24h = 0,
                .shares_accepted = 0,
                .shares_rejected = 0,
                .shares_stale = 0,
                .accept_rate = 100.0,
                .pool_name = "default",
                .pool_difficulty = conn.difficulty,
                .connected_at = conn.connected_at,
                .last_share_time = 0,
                .uptime_seconds = 0,
                .estimated_power_watts = 0,
            },
            .last_sample_time = compat.timestamp(),
            .share_count_since_sample = 0,
            .pool_difficulty = conn.difficulty,
        };

        try self.miners.put(conn.id, data);

        // Initialize hashrate history
        const history = std.ArrayList(HashrateSample).init(self.allocator);
        try self.hashrate_history.put(conn.id, history);

        self.fleet_stats_dirty = true;
    }

    /// Unregister a miner (disconnected)
    pub fn unregisterMiner(self: *Self, miner_id: u64) void {
        if (self.miners.fetchRemove(miner_id)) |kv| {
            self.allocator.destroy(kv.value);
        }

        if (self.hashrate_history.fetchRemove(miner_id)) |kv| {
            kv.value.deinit();
        }

        self.fleet_stats_dirty = true;
    }

    /// Record a share submission
    pub fn recordShare(self: *Self, event: server.ShareEvent) void {
        if (self.miners.get(event.miner_id)) |data| {
            const now = compat.timestamp();

            switch (event.status) {
                .accepted => {
                    data.info.shares_accepted += 1;
                    data.share_count_since_sample += 1;
                },
                .rejected => data.info.shares_rejected += 1,
                .stale => data.info.shares_stale += 1,
            }

            data.info.last_share_time = now;
            data.info.uptime_seconds = now - data.info.connected_at;
            data.pool_difficulty = event.difficulty;

            // Update accept rate
            const total = data.info.shares_accepted + data.info.shares_rejected + data.info.shares_stale;
            if (total > 0) {
                data.info.accept_rate = @as(f64, @floatFromInt(data.info.shares_accepted)) /
                    @as(f64, @floatFromInt(total)) * 100.0;
            }

            // Sample hashrate periodically
            const sample_interval: i64 = @intCast(self.config.sample_interval_s);
            if (now - data.last_sample_time >= sample_interval) {
                self.sampleHashrate(data);
            }

            self.fleet_stats_dirty = true;
        }
    }

    /// Update miner status
    pub fn updateMinerStatus(self: *Self, miner_id: u64, status: MinerInfo.MinerStatus) void {
        if (self.miners.get(miner_id)) |data| {
            const old_status = data.info.status;
            data.info.status = status;

            // Generate alert on status change
            if (old_status != status) {
                self.generateStatusAlert(data, old_status, status);
            }

            self.fleet_stats_dirty = true;
        }
    }

    /// Set miner's ASIC model
    pub fn setMinerModel(self: *Self, miner_id: u64, model: AsicModel) void {
        if (self.miners.get(miner_id)) |data| {
            data.info.model = model;
            data.info.estimated_power_watts = model.power_watts;
            self.fleet_stats_dirty = true;
        }
    }

    /// Get miner info by ID
    pub fn getMinerInfo(self: *const Self, miner_id: u64) ?MinerInfo {
        if (self.miners.get(miner_id)) |data| {
            return data.info;
        }
        return null;
    }

    /// Get all miner infos
    pub fn getAllMiners(self: *Self) ![]MinerInfo {
        var list = try self.allocator.alloc(MinerInfo, self.miners.count());
        var i: usize = 0;

        var it = self.miners.iterator();
        while (it.next()) |entry| {
            list[i] = entry.value_ptr.*.info;
            i += 1;
        }

        return list;
    }

    /// Get fleet statistics (cached)
    pub fn getFleetStats(self: *Self) FleetStats {
        if (self.fleet_stats_dirty) {
            self.recalculateFleetStats();
        }
        return self.fleet_stats;
    }

    /// Get recent alerts
    pub fn getAlerts(self: *const Self, limit: usize) []const Alert {
        const count = @min(limit, self.alerts.items.len);
        const start = self.alerts.items.len - count;
        return self.alerts.items[start..];
    }

    /// Check all miners for timeout/offline
    pub fn checkMinerTimeouts(self: *Self) void {
        const now = compat.timestamp();
        const timeout: i64 = @intCast(self.config.offline_timeout_s);

        var it = self.miners.iterator();
        while (it.next()) |entry| {
            const data = entry.value_ptr.*;
            if (data.info.status == .online and
                data.info.last_share_time > 0 and
                now - data.info.last_share_time > timeout)
            {
                self.updateMinerStatus(entry.key_ptr.*, .offline);
            }
        }
    }

    // ==================== Internal Methods ====================

    fn sampleHashrate(self: *Self, data: *MinerData) void {
        const now = compat.timestamp();
        const elapsed = now - data.last_sample_time;

        if (elapsed <= 0) return;

        // Estimate hashrate from share count and difficulty
        // hashrate = shares * difficulty * 2^32 / time
        const shares = @as(f64, @floatFromInt(data.share_count_since_sample));
        const difficulty = data.pool_difficulty;
        const time_s = @as(f64, @floatFromInt(elapsed));

        const hashrate_h = shares * difficulty * 4294967296.0 / time_s; // H/s
        const hashrate_th = hashrate_h / 1e12; // TH/s

        data.info.current_hashrate_th = hashrate_th;
        data.last_sample_time = now;
        data.share_count_since_sample = 0;

        // Add to history
        if (self.hashrate_history.getPtr(data.info.id)) |history| {
            history.append(.{
                .timestamp = now,
                .hashrate_th = hashrate_th,
            }) catch {};

            // Trim old samples
            while (history.items.len > self.config.max_hashrate_samples) {
                _ = history.orderedRemove(0);
            }

            // Calculate rolling averages
            data.info.hashrate_1h = self.calculateRollingAverage(history.items, 3600);
            data.info.hashrate_24h = self.calculateRollingAverage(history.items, 86400);

            // Check for hashrate drop
            self.checkHashrateDrop(data);
        }
    }

    fn calculateRollingAverage(self: *const Self, samples: []const HashrateSample, window_s: i64) f64 {
        _ = self;
        if (samples.len == 0) return 0;

        const now = compat.timestamp();
        const cutoff = now - window_s;

        var sum: f64 = 0;
        var count: u32 = 0;

        for (samples) |sample| {
            if (sample.timestamp >= cutoff) {
                sum += sample.hashrate_th;
                count += 1;
            }
        }

        return if (count > 0) sum / @as(f64, @floatFromInt(count)) else 0;
    }

    fn checkHashrateDrop(self: *Self, data: *MinerData) void {
        // Compare current to 1h average
        if (data.info.hashrate_1h > 0 and data.info.current_hashrate_th > 0) {
            const drop_pct = (1.0 - data.info.current_hashrate_th / data.info.hashrate_1h) * 100.0;

            if (drop_pct >= self.config.hashrate_drop_alert_pct) {
                data.info.status = .low_hashrate;

                // Generate alert
                const alert_msg = std.fmt.allocPrint(
                    self.allocator,
                    "Hashrate dropped {d:.1}% (current: {d:.2} TH/s, avg: {d:.2} TH/s)",
                    .{ drop_pct, data.info.current_hashrate_th, data.info.hashrate_1h },
                ) catch return;

                self.addAlert(.{
                    .timestamp = compat.timestamp(),
                    .severity = .warning,
                    .miner_id = data.info.id,
                    .miner_name = data.info.name,
                    .message = alert_msg,
                    .acknowledged = false,
                });
            }
        }
    }

    fn generateStatusAlert(self: *Self, data: *MinerData, old: MinerInfo.MinerStatus, new: MinerInfo.MinerStatus) void {
        const severity: Alert.Severity = switch (new) {
            .offline, .error_state => .critical,
            .low_hashrate => .warning,
            .online => .info,
        };

        const msg = std.fmt.allocPrint(
            self.allocator,
            "Status changed: {s} → {s}",
            .{ @tagName(old), @tagName(new) },
        ) catch return;

        self.addAlert(.{
            .timestamp = compat.timestamp(),
            .severity = severity,
            .miner_id = data.info.id,
            .miner_name = data.info.name,
            .message = msg,
            .acknowledged = false,
        });
    }

    fn addAlert(self: *Self, alert: Alert) void {
        self.alerts.append(alert) catch {};

        // Keep only last 1000 alerts
        while (self.alerts.items.len > 1000) {
            _ = self.alerts.orderedRemove(0);
        }
    }

    fn recalculateFleetStats(self: *Self) void {
        var stats = std.mem.zeroes(FleetStats);

        var it = self.miners.iterator();
        while (it.next()) |entry| {
            const info = entry.value_ptr.*.info;

            stats.total_miners += 1;

            switch (info.status) {
                .online => stats.online_miners += 1,
                .offline => stats.offline_miners += 1,
                .error_state, .low_hashrate => stats.error_miners += 1,
            }

            stats.total_hashrate_th += info.current_hashrate_th;
            stats.total_hashrate_1h += info.hashrate_1h;
            stats.total_hashrate_24h += info.hashrate_24h;

            stats.total_accepted += info.shares_accepted;
            stats.total_rejected += info.shares_rejected;
            stats.total_stale += info.shares_stale;

            stats.total_power_watts += info.estimated_power_watts;
        }

        // Calculate fleet accept rate
        const total_shares = stats.total_accepted + stats.total_rejected + stats.total_stale;
        if (total_shares > 0) {
            stats.fleet_accept_rate = @as(f64, @floatFromInt(stats.total_accepted)) /
                @as(f64, @floatFromInt(total_shares)) * 100.0;
        }

        stats.updated_at = compat.timestamp();
        self.fleet_stats = stats;
        self.fleet_stats_dirty = false;
    }
};

// ==================== Tests ====================

test "registry basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var registry = try MinerRegistry.init(allocator, .{});
    defer registry.deinit();

    // Create mock connection
    const conn = server.MinerConnection{
        .id = 1,
        .sockfd = 0,
        .worker_name = "test.worker",
        .ip_address = [_]u8{0} ** 16,
        .ip_len = 0,
        .state = .mining,
        .difficulty = 65536,
        .extranonce1 = [_]u8{0} ** 8,
        .shares_accepted = 0,
        .shares_rejected = 0,
        .shares_stale = 0,
        .last_share_time = 0,
        .connected_at = 0,
        .recv_buffer = undefined,
        .recv_len = 0,
        .send_queue = undefined,
        .allocator = allocator,
    };

    try registry.registerMiner(conn);
    try testing.expectEqual(@as(usize, 1), registry.miners.count());

    registry.unregisterMiner(1);
    try testing.expectEqual(@as(usize, 0), registry.miners.count());
}
