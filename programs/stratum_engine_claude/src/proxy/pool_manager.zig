//! Pool Manager - Multi-pool support with failover
//!
//! Features:
//! - Connect to multiple upstream pools
//! - Automatic failover on disconnect
//! - Priority-based pool selection
//! - Latency monitoring
//! - Share submission routing

const std = @import("std");
const types = @import("../stratum/types.zig");
const client = @import("../stratum/client.zig");
const compat = @import("../utils/compat.zig");
const linux = std.os.linux;
const posix = std.posix;
const IoUring = linux.IoUring;

pub const PoolError = error{
    NoPoolsAvailable,
    AllPoolsDown,
    ConnectionFailed,
    AuthenticationFailed,
    ShareSubmitFailed,
    PoolNotFound,
};

/// Pool configuration
pub const PoolConfig = struct {
    /// Unique pool ID
    id: []const u8,

    /// Display name (e.g., "Braiins Pool", "F2Pool")
    name: []const u8,

    /// Stratum URL (e.g., "stratum+tcp://stratum.braiins.com:3333")
    url: []const u8,

    /// Worker username
    username: []const u8,

    /// Worker password
    password: []const u8,

    /// Priority (lower = higher priority, 0 = highest)
    priority: u8,

    /// Is this pool enabled?
    enabled: bool,

    /// Reconnect delay on failure (seconds)
    reconnect_delay_s: u32,

    /// Maximum reconnect attempts before giving up
    max_reconnect_attempts: u32,
};

/// Pool connection state
pub const PoolState = enum {
    disconnected,
    connecting,
    connected,
    subscribing,
    authorizing,
    ready,
    error_state,
    disabled,
};

/// Per-pool statistics
pub const PoolStats = struct {
    /// Shares submitted to this pool
    shares_submitted: u64,
    shares_accepted: u64,
    shares_rejected: u64,

    /// Latency tracking
    last_latency_ms: u32,
    avg_latency_ms: f64,
    latency_samples: u32,

    /// Connection stats
    connected_at: i64,
    disconnected_at: i64,
    uptime_seconds: i64,
    disconnect_count: u32,
    last_job_time: i64,

    /// Difficulty
    current_difficulty: f64,
};

/// Active pool connection
pub const PoolConnection = struct {
    config: PoolConfig,
    state: PoolState,
    stats: PoolStats,

    /// Underlying stratum client
    client: ?client.StratumClient,

    /// Extranonce from pool
    extranonce1: ?[]u8,
    extranonce2_size: u32,

    /// Current job from this pool
    current_job: ?types.Job,

    /// Reconnect tracking
    reconnect_attempts: u32,
    last_reconnect_time: i64,

    /// Error message if in error state
    last_error: ?[]const u8,

    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: PoolConfig) Self {
        return .{
            .config = config,
            .state = if (config.enabled) .disconnected else .disabled,
            .stats = std.mem.zeroes(PoolStats),
            .client = null,
            .extranonce1 = null,
            .extranonce2_size = 4,
            .current_job = null,
            .reconnect_attempts = 0,
            .last_reconnect_time = 0,
            .last_error = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.client) |*c| {
            c.deinit();
        }
        if (self.extranonce1) |ext| {
            self.allocator.free(ext);
        }
        if (self.current_job) |*job| {
            job.deinit();
        }
        if (self.last_error) |err| {
            self.allocator.free(err);
        }
    }

    /// Get accept rate percentage
    pub fn getAcceptRate(self: *const Self) f64 {
        const total = self.stats.shares_submitted;
        if (total == 0) return 100.0;
        return @as(f64, @floatFromInt(self.stats.shares_accepted)) /
            @as(f64, @floatFromInt(total)) * 100.0;
    }

    /// Get uptime in seconds
    pub fn getUptime(self: *const Self) i64 {
        if (self.state != .ready) return 0;
        return compat.timestamp() - self.stats.connected_at;
    }

    /// How many miners are currently using this pool
    pub fn getMinerCount(self: *const Self) u32 {
        _ = self;
        // This would be set by the proxy server
        return 0;
    }
};

/// Job notification from pool
pub const JobNotification = struct {
    pool_id: []const u8,
    job: types.Job,
    clean_jobs: bool,
};

/// Pool Manager
pub const PoolManager = struct {
    allocator: std.mem.Allocator,

    /// All configured pools
    pools: std.StringHashMap(*PoolConnection),

    /// Pool priority order (pool IDs sorted by priority)
    priority_order: std.ArrayList([]const u8),

    /// Currently active pool
    active_pool_id: ?[]const u8,

    /// Callback for new jobs
    on_job: ?*const fn (JobNotification) void,

    /// Callback for pool status changes
    on_pool_change: ?*const fn (PoolConnection) void,

    /// Manager state
    running: std.atomic.Value(bool),

    /// Configuration
    config: Config,

    const Self = @This();

    pub const Config = struct {
        /// Time between pool health checks (seconds)
        health_check_interval_s: u32 = 30,

        /// Time to wait before reconnecting (seconds)
        reconnect_delay_s: u32 = 5,

        /// Maximum reconnect attempts per pool
        max_reconnect_attempts: u32 = 10,

        /// Failover delay (seconds) - wait before switching pools
        failover_delay_s: u32 = 3,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
        return .{
            .allocator = allocator,
            .pools = std.StringHashMap(*PoolConnection).init(allocator),
            .priority_order = try std.ArrayList([]const u8).initCapacity(allocator, 8),
            .active_pool_id = null,
            .on_job = null,
            .on_pool_change = null,
            .running = std.atomic.Value(bool).init(false),
            .config = config,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        var it = self.pools.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.pools.deinit();
        self.priority_order.deinit(self.allocator);
    }

    /// Add a pool configuration
    pub fn addPool(self: *Self, config: PoolConfig) !void {
        const pool = try self.allocator.create(PoolConnection);
        pool.* = PoolConnection.init(self.allocator, config);

        try self.pools.put(config.id, pool);

        // Insert into priority order
        try self.insertByPriority(config.id, config.priority);

        std.debug.print("📌 Added pool: {s} (priority: {})\n", .{ config.name, config.priority });
    }

    /// Remove a pool
    pub fn removePool(self: *Self, pool_id: []const u8) void {
        if (self.pools.fetchRemove(pool_id)) |kv| {
            kv.value.deinit();
            self.allocator.destroy(kv.value);

            // Remove from priority order
            for (self.priority_order.items, 0..) |id, i| {
                if (std.mem.eql(u8, id, pool_id)) {
                    _ = self.priority_order.orderedRemove(i);
                    break;
                }
            }
        }
    }

    /// Enable/disable a pool
    pub fn setPoolEnabled(self: *Self, pool_id: []const u8, enabled: bool) void {
        if (self.pools.get(pool_id)) |pool| {
            if (enabled) {
                pool.state = .disconnected;
            } else {
                pool.state = .disabled;
                if (pool.client) |*c| {
                    c.deinit();
                    pool.client = null;
                }
            }
        }
    }

    /// Get pool info
    pub fn getPool(self: *const Self, pool_id: []const u8) ?*const PoolConnection {
        return self.pools.get(pool_id);
    }

    /// Get all pools
    pub fn getAllPools(self: *Self) ![]*PoolConnection {
        var list = try self.allocator.alloc(*PoolConnection, self.pools.count());
        var i: usize = 0;

        // Return in priority order
        for (self.priority_order.items) |pool_id| {
            if (self.pools.get(pool_id)) |pool| {
                list[i] = pool;
                i += 1;
            }
        }

        return list;
    }

    /// Get currently active pool
    pub fn getActivePool(self: *Self) ?*PoolConnection {
        if (self.active_pool_id) |id| {
            return self.pools.get(id);
        }
        return null;
    }

    /// Start the pool manager
    pub fn start(self: *Self) !void {
        self.running.store(true, .release);

        std.debug.print("🚀 Pool manager starting...\n", .{});

        // Connect to highest priority pool
        try self.connectToNextPool();

        // Start health check loop in separate thread (in production)
        // For now, health checks are manual via checkHealth()
    }

    /// Stop the pool manager
    pub fn stop(self: *Self) void {
        self.running.store(false, .release);

        // Disconnect all pools
        var it = self.pools.iterator();
        while (it.next()) |entry| {
            const pool = entry.value_ptr.*;
            if (pool.client) |*c| {
                c.deinit();
                pool.client = null;
            }
            pool.state = .disconnected;
        }

        self.active_pool_id = null;
    }

    /// Submit a share to the active pool
    pub fn submitShare(self: *Self, share: types.Share) !void {
        if (self.getActivePool()) |pool| {
            if (pool.client) |*c| {
                const start_time = std.time.milliTimestamp();

                try c.submitShare(share);

                const latency = @as(u32, @intCast(std.time.milliTimestamp() - start_time));
                pool.stats.shares_submitted += 1;
                self.updateLatency(pool, latency);
            } else {
                return PoolError.NoPoolsAvailable;
            }
        } else {
            return PoolError.NoPoolsAvailable;
        }
    }

    /// Record share result (called when pool responds)
    pub fn recordShareResult(self: *Self, pool_id: []const u8, accepted: bool) void {
        if (self.pools.get(pool_id)) |pool| {
            if (accepted) {
                pool.stats.shares_accepted += 1;
            } else {
                pool.stats.shares_rejected += 1;
            }
        }
    }

    /// Check pool health and failover if needed
    pub fn checkHealth(self: *Self) !void {
        const active = self.getActivePool();

        if (active) |pool| {
            // Check if pool is still responsive
            const now = compat.timestamp();
            const job_age = now - pool.stats.last_job_time;

            // If no job for 5 minutes, consider pool dead
            if (job_age > 300 and pool.stats.last_job_time > 0) {
                std.debug.print("⚠️ Pool {s} unresponsive (no job for {}s)\n", .{
                    pool.config.name,
                    job_age,
                });
                try self.failover();
            }
        } else {
            // No active pool, try to connect
            try self.connectToNextPool();
        }

        // Try to reconnect disconnected pools in background
        try self.reconnectDisconnectedPools();
    }

    /// Force failover to next pool
    pub fn failover(self: *Self) !void {
        if (self.active_pool_id) |current_id| {
            if (self.pools.get(current_id)) |pool| {
                std.debug.print("🔄 Failing over from {s}...\n", .{pool.config.name});

                pool.state = .disconnected;
                pool.stats.disconnected_at = compat.timestamp();
                pool.stats.disconnect_count += 1;

                if (pool.client) |*c| {
                    c.deinit();
                    pool.client = null;
                }
            }

            self.active_pool_id = null;
        }

        try self.connectToNextPool();
    }

    // ==================== Internal Methods ====================

    fn insertByPriority(self: *Self, pool_id: []const u8, priority: u8) !void {
        // Find insertion point
        var insert_idx: usize = self.priority_order.items.len;

        for (self.priority_order.items, 0..) |id, i| {
            if (self.pools.get(id)) |pool| {
                if (priority < pool.config.priority) {
                    insert_idx = i;
                    break;
                }
            }
        }

        try self.priority_order.insert(self.allocator, insert_idx, pool_id);
    }

    fn connectToNextPool(self: *Self) !void {
        // Find highest priority enabled pool that's not in error state
        for (self.priority_order.items) |pool_id| {
            if (self.pools.get(pool_id)) |pool| {
                if (pool.state == .disabled or pool.state == .error_state) {
                    continue;
                }

                // Skip if we just tried and failed
                if (pool.reconnect_attempts >= pool.config.max_reconnect_attempts) {
                    continue;
                }

                try self.connectToPool(pool);

                if (pool.state == .ready) {
                    self.active_pool_id = pool_id;
                    std.debug.print("✅ Active pool: {s}\n", .{pool.config.name});
                    return;
                }
            }
        }

        std.debug.print("❌ No pools available!\n", .{});
        return PoolError.AllPoolsDown;
    }

    fn connectToPool(self: *Self, pool: *PoolConnection) !void {
        pool.state = .connecting;
        pool.last_reconnect_time = compat.timestamp();
        pool.reconnect_attempts += 1;

        std.debug.print("🔌 Connecting to {s}...\n", .{pool.config.name});

        // Create stratum client
        const creds = types.Credentials{
            .url = pool.config.url,
            .username = pool.config.username,
            .password = pool.config.password,
        };

        pool.client = client.StratumClient.init(pool.allocator, creds) catch |err| {
            pool.state = .error_state;
            std.debug.print("❌ Connection failed: {}\n", .{err});
            return;
        };

        pool.state = .subscribing;

        // Subscribe
        if (pool.client) |*c| {
            c.subscribe() catch |err| {
                pool.state = .error_state;
                std.debug.print("❌ Subscribe failed: {}\n", .{err});
                return;
            };

            pool.state = .authorizing;

            // Authorize
            c.authorize() catch |err| {
                pool.state = .error_state;
                std.debug.print("❌ Authorize failed: {}\n", .{err});
                return;
            };
        }

        pool.state = .ready;
        pool.stats.connected_at = compat.timestamp();
        pool.reconnect_attempts = 0;

        std.debug.print("✅ Connected to {s}\n", .{pool.config.name});

        // Notify callback
        if (self.on_pool_change) |callback| {
            callback(pool.*);
        }
    }

    fn reconnectDisconnectedPools(self: *Self) !void {
        const now = compat.timestamp();

        var it = self.pools.iterator();
        while (it.next()) |entry| {
            const pool = entry.value_ptr.*;

            // Skip active pool, disabled, or recently tried
            if (self.active_pool_id != null and
                std.mem.eql(u8, entry.key_ptr.*, self.active_pool_id.?))
            {
                continue;
            }

            if (pool.state == .disabled or pool.state == .ready) {
                continue;
            }

            // Check reconnect delay
            const delay: i64 = @intCast(pool.config.reconnect_delay_s);
            if (now - pool.last_reconnect_time < delay) {
                continue;
            }

            // Reset error state if we've waited long enough
            if (pool.state == .error_state and
                pool.reconnect_attempts >= pool.config.max_reconnect_attempts)
            {
                const backoff = delay * @as(i64, @intCast(pool.reconnect_attempts));
                if (now - pool.last_reconnect_time >= backoff) {
                    pool.reconnect_attempts = 0;
                    pool.state = .disconnected;
                }
            }

            // Try to reconnect
            if (pool.state == .disconnected) {
                try self.connectToPool(pool);
            }
        }
    }

    fn updateLatency(self: *Self, pool: *PoolConnection, latency_ms: u32) void {
        _ = self;
        pool.stats.last_latency_ms = latency_ms;
        pool.stats.latency_samples += 1;

        // Rolling average
        const n = @as(f64, @floatFromInt(pool.stats.latency_samples));
        pool.stats.avg_latency_ms = pool.stats.avg_latency_ms * (n - 1) / n +
            @as(f64, @floatFromInt(latency_ms)) / n;
    }

    /// Process messages from all connected pools
    pub fn pollPools(self: *Self) !void {
        var it = self.pools.iterator();
        while (it.next()) |entry| {
            const pool = entry.value_ptr.*;

            if (pool.state != .ready) continue;

            if (pool.client) |*c| {
                // Try to receive a message
                const job = c.receiveJob() catch |err| {
                    std.debug.print("⚠️ Pool {s} recv error: {}\n", .{ pool.config.name, err });
                    pool.state = .error_state;
                    continue;
                };

                if (job) |j| {
                    pool.current_job = j;
                    pool.stats.last_job_time = compat.timestamp();

                    // Notify callback
                    if (self.on_job) |callback| {
                        callback(.{
                            .pool_id = pool.config.id,
                            .job = j,
                            .clean_jobs = j.clean_jobs,
                        });
                    }
                }
            }
        }
    }
};

// ==================== Tests ====================

test "pool manager init" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var manager = try PoolManager.init(allocator, .{});
    defer manager.deinit();

    try manager.addPool(.{
        .id = "pool1",
        .name = "Test Pool",
        .url = "stratum+tcp://127.0.0.1:3333",
        .username = "test.worker",
        .password = "x",
        .priority = 0,
        .enabled = true,
        .reconnect_delay_s = 5,
        .max_reconnect_attempts = 3,
    });

    try testing.expectEqual(@as(usize, 1), manager.pools.count());
}
