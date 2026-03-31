//! Load Balancing Strategies
//!
//! Provides various algorithms for distributing requests across backends:
//! - Round-robin: Simple rotation through backends
//! - Weighted: Proportional distribution by weight
//! - Least connections: Route to least busy backend
//! - Random: Random selection
//! - IP hash: Consistent routing by client IP
//! - Least latency: Route to fastest responding backend

const std = @import("std");
const Backend = @import("backend.zig").Backend;
const BackendPool = @import("backend.zig").BackendPool;

// =============================================================================
// Load Balancing Strategy
// =============================================================================

pub const Strategy = enum {
    round_robin,
    weighted_round_robin,
    least_connections,
    random,
    ip_hash,
    least_latency,
};

// =============================================================================
// Load Balancer Interface
// =============================================================================

pub const LoadBalancer = struct {
    strategy: Strategy,
    pool: *BackendPool,

    // Round-robin state
    rr_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    // Weighted state
    weighted_index: usize = 0,
    weighted_current: u16 = 0,

    // Random state
    prng: std.Random.Xoshiro256,

    pub fn init(pool: *BackendPool, strategy: Strategy) LoadBalancer {
        return .{
            .strategy = strategy,
            .pool = pool,
            .prng = std.Random.Xoshiro256.init(getSeed()),
        };
    }

    /// Select a backend using the configured strategy
    pub fn select(self: *LoadBalancer, client_ip: ?[4]u8) ?*Backend {
        return switch (self.strategy) {
            .round_robin => self.roundRobin(),
            .weighted_round_robin => self.weightedRoundRobin(),
            .least_connections => self.leastConnections(),
            .random => self.randomSelect(),
            .ip_hash => self.ipHash(client_ip orelse .{ 0, 0, 0, 0 }),
            .least_latency => self.leastLatency(),
        };
    }

    // =========================================================================
    // Round-Robin
    // =========================================================================

    fn roundRobin(self: *LoadBalancer) ?*Backend {
        const backends = self.pool.backends.items;
        if (backends.len == 0) return null;

        const start = self.rr_index.fetchAdd(1, .monotonic) % backends.len;
        var i: usize = 0;

        while (i < backends.len) : (i += 1) {
            const idx = (start + i) % backends.len;
            const be = &backends[idx];
            if (be.isAvailable()) {
                return be;
            }
        }

        // No healthy backend, return any
        return &backends[start % backends.len];
    }

    // =========================================================================
    // Weighted Round-Robin
    // =========================================================================

    fn weightedRoundRobin(self: *LoadBalancer) ?*Backend {
        const backends = self.pool.backends.items;
        if (backends.len == 0) return null;

        // Find max weight
        var max_weight: u16 = 0;
        var gcd: u16 = 0;
        for (backends) |be| {
            if (be.config.weight > max_weight) {
                max_weight = be.config.weight;
            }
            gcd = if (gcd == 0) be.config.weight else computeGcd(gcd, be.config.weight);
        }

        if (max_weight == 0 or gcd == 0) {
            return self.roundRobin();
        }

        // Weighted selection
        var attempts: usize = 0;
        while (attempts < backends.len * 2) : (attempts += 1) {
            self.weighted_index = (self.weighted_index + 1) % backends.len;

            if (self.weighted_index == 0) {
                if (self.weighted_current <= gcd) {
                    self.weighted_current = max_weight;
                } else {
                    self.weighted_current -= gcd;
                }
            }

            const be = &backends[self.weighted_index];
            if (be.config.weight >= self.weighted_current and be.isAvailable()) {
                return be;
            }
        }

        return self.roundRobin();
    }

    // =========================================================================
    // Least Connections
    // =========================================================================

    fn leastConnections(self: *LoadBalancer) ?*Backend {
        const backends = self.pool.backends.items;
        if (backends.len == 0) return null;

        var selected: ?*Backend = null;
        var min_conns: u32 = std.math.maxInt(u32);

        for (backends) |*be| {
            if (!be.isAvailable()) continue;

            const conns = be.active_connections.load(.monotonic);
            if (conns < min_conns) {
                min_conns = conns;
                selected = be;
            }
        }

        return selected orelse self.roundRobin();
    }

    // =========================================================================
    // Random
    // =========================================================================

    fn randomSelect(self: *LoadBalancer) ?*Backend {
        const backends = self.pool.backends.items;
        if (backends.len == 0) return null;

        // Collect available backends
        var available: [64]*Backend = undefined;
        var count: usize = 0;

        for (backends) |*be| {
            if (be.isAvailable() and count < 64) {
                available[count] = be;
                count += 1;
            }
        }

        if (count == 0) {
            return &backends[self.prng.random().uintLessThan(usize, backends.len)];
        }

        const idx = self.prng.random().uintLessThan(usize, count);
        return available[idx];
    }

    // =========================================================================
    // IP Hash (Consistent Hashing)
    // =========================================================================

    fn ipHash(self: *LoadBalancer, ip: [4]u8) ?*Backend {
        const backends = self.pool.backends.items;
        if (backends.len == 0) return null;

        // Simple hash of IP address
        const hash = hashIp(ip);
        const start = hash % backends.len;

        // Find available backend starting from hash position
        var i: usize = 0;
        while (i < backends.len) : (i += 1) {
            const idx = (start + i) % backends.len;
            const be = &backends[idx];
            if (be.isAvailable()) {
                return be;
            }
        }

        return &backends[start];
    }

    // =========================================================================
    // Least Latency
    // =========================================================================

    fn leastLatency(self: *LoadBalancer) ?*Backend {
        const backends = self.pool.backends.items;
        if (backends.len == 0) return null;

        var selected: ?*Backend = null;
        var min_latency: u64 = std.math.maxInt(u64);

        for (backends) |*be| {
            if (!be.isAvailable()) continue;

            const latency = be.avg_latency_us.load(.monotonic);
            // Prefer backends with some data (latency > 0)
            if (latency > 0 and latency < min_latency) {
                min_latency = latency;
                selected = be;
            }
        }

        // Fallback to round-robin if no latency data
        return selected orelse self.roundRobin();
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

fn computeGcd(a: u16, b: u16) u16 {
    var x = a;
    var y = b;
    while (y != 0) {
        const t = y;
        y = x % y;
        x = t;
    }
    return x;
}

fn hashIp(ip: [4]u8) usize {
    // Simple FNV-1a hash
    var hash: u32 = 2166136261;
    for (ip) |byte| {
        hash ^= byte;
        hash *%= 16777619;
    }
    return @intCast(hash);
}

fn getSeed() u64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch return 12345;
    return @as(u64, @intCast(ts.nsec));
}

// =============================================================================
// Tests
// =============================================================================

test "round robin selection" {
    const allocator = std.testing.allocator;

    var pool = @import("backend.zig").BackendPool.init(allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .host = "127.0.0.1", .port = 8001 });
    try pool.addBackend(.{ .host = "127.0.0.1", .port = 8002 });
    try pool.addBackend(.{ .host = "127.0.0.1", .port = 8003 });

    // Mark all healthy
    for (pool.backends.items) |*b| {
        b.health = .healthy;
    }

    var lb = LoadBalancer.init(&pool, .round_robin);

    // Should cycle through backends
    const b1 = lb.select(null).?;
    const b2 = lb.select(null).?;
    const b3 = lb.select(null).?;
    const b4 = lb.select(null).?;

    try std.testing.expect(b1 != b2);
    try std.testing.expect(b2 != b3);
    try std.testing.expect(b1 == b4); // Wrapped around
}

test "ip hash consistency" {
    const allocator = std.testing.allocator;

    var pool = @import("backend.zig").BackendPool.init(allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .host = "127.0.0.1", .port = 8001 });
    try pool.addBackend(.{ .host = "127.0.0.1", .port = 8002 });
    try pool.addBackend(.{ .host = "127.0.0.1", .port = 8003 });

    // Mark all healthy
    for (pool.backends.items) |*b| {
        b.health = .healthy;
    }

    var lb = LoadBalancer.init(&pool, .ip_hash);

    const client_ip = [4]u8{ 192, 168, 1, 100 };

    // Same IP should always get same backend
    const b1 = lb.select(client_ip).?;
    const b2 = lb.select(client_ip).?;
    const b3 = lb.select(client_ip).?;

    try std.testing.expect(b1 == b2);
    try std.testing.expect(b2 == b3);
}

test "least connections" {
    const allocator = std.testing.allocator;

    var pool = @import("backend.zig").BackendPool.init(allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .host = "127.0.0.1", .port = 8001 });
    try pool.addBackend(.{ .host = "127.0.0.1", .port = 8002 });

    // Mark healthy and set different connection counts
    pool.backends.items[0].health = .healthy;
    pool.backends.items[0].active_connections.store(10, .monotonic);

    pool.backends.items[1].health = .healthy;
    pool.backends.items[1].active_connections.store(2, .monotonic);

    var lb = LoadBalancer.init(&pool, .least_connections);

    // Should select backend with fewer connections
    const selected = lb.select(null).?;
    try std.testing.expectEqual(@as(u16, 8002), selected.config.port);
}
