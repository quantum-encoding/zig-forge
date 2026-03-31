//! Backend Pool and Connection Management
//!
//! Manages connections to upstream servers with:
//! - Connection pooling with keep-alive
//! - Health checking
//! - Circuit breaker pattern
//! - Retry logic with backoff

const std = @import("std");
const posix = std.posix;
const c = std.c;
const http = @import("../http/parser.zig");

// Zig 0.16 compatible Mutex using pthread
const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

// =============================================================================
// Backend Configuration
// =============================================================================

pub const BackendConfig = struct {
    /// Unique identifier
    id: []const u8 = "default",
    /// Host address
    host: []const u8,
    /// Port number
    port: u16,
    /// Weight for load balancing (higher = more traffic)
    weight: u16 = 100,
    /// Max connections in pool
    max_connections: u16 = 100,
    /// Connection timeout (ms)
    connect_timeout_ms: u32 = 5000,
    /// Request timeout (ms)
    request_timeout_ms: u32 = 30000,
    /// Enable TLS to backend
    tls: bool = false,
    /// Health check path
    health_check_path: []const u8 = "/health",
    /// Health check interval (ms)
    health_check_interval_ms: u32 = 10000,
    /// Max consecutive failures before marking unhealthy
    max_failures: u16 = 3,
};

// =============================================================================
// Backend Health Status
// =============================================================================

pub const HealthStatus = enum {
    healthy,
    unhealthy,
    unknown,
};

// =============================================================================
// Pooled Connection
// =============================================================================

pub const PooledConnection = struct {
    socket: posix.socket_t,
    backend: *Backend,
    in_use: bool = false,
    last_used_ns: u64 = 0,
    requests_served: u64 = 0,

    pub fn close(self: *PooledConnection) void {
        _ = std.c.close(self.socket);
        self.socket = -1;
    }

    pub fn isAlive(self: *const PooledConnection) bool {
        return self.socket >= 0;
    }
};

// =============================================================================
// Backend Server
// =============================================================================

pub const Backend = struct {
    config: BackendConfig,
    allocator: std.mem.Allocator,

    // Connection pool
    connections: std.ArrayListUnmanaged(PooledConnection) = .empty,
    pool_mutex: Mutex = .{},

    // Health tracking
    health: HealthStatus = .unknown,
    consecutive_failures: u16 = 0,
    last_health_check: i64 = 0,
    total_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    failed_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    active_connections: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // Latency tracking (exponential moving average)
    avg_latency_us: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(allocator: std.mem.Allocator, config: BackendConfig) Backend {
        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Backend) void {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();

        for (self.connections.items) |*conn| {
            if (conn.isAlive()) {
                conn.close();
            }
        }
        self.connections.deinit(self.allocator);
    }

    /// Get a connection from the pool or create a new one
    pub fn getConnection(self: *Backend) !*PooledConnection {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();

        // Try to find an available pooled connection
        for (self.connections.items) |*conn| {
            if (!conn.in_use and conn.isAlive()) {
                conn.in_use = true;
                conn.last_used_ns = getTimeNs();
                _ = self.active_connections.fetchAdd(1, .monotonic);
                return conn;
            }
        }

        // Create new connection if under limit
        if (self.connections.items.len < self.config.max_connections) {
            const socket = try self.connect();

            try self.connections.append(self.allocator, PooledConnection{
                .socket = socket,
                .backend = self,
                .in_use = true,
                .last_used_ns = getTimeNs(),
            });

            _ = self.active_connections.fetchAdd(1, .monotonic);
            return &self.connections.items[self.connections.items.len - 1];
        }

        return error.PoolExhausted;
    }

    /// Return a connection to the pool
    pub fn releaseConnection(self: *Backend, conn: *PooledConnection, keep_alive: bool) void {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();

        conn.in_use = false;
        conn.requests_served += 1;
        _ = self.active_connections.fetchSub(1, .monotonic);

        if (!keep_alive) {
            conn.close();
        }
    }

    /// Mark a request as failed
    pub fn markFailure(self: *Backend) void {
        _ = self.failed_requests.fetchAdd(1, .monotonic);
        self.consecutive_failures += 1;

        if (self.consecutive_failures >= self.config.max_failures) {
            self.health = .unhealthy;
        }
    }

    /// Mark a request as successful
    pub fn markSuccess(self: *Backend, latency_us: u64) void {
        _ = self.total_requests.fetchAdd(1, .monotonic);
        self.consecutive_failures = 0;
        self.health = .healthy;

        // Update exponential moving average (alpha = 0.1)
        const current = self.avg_latency_us.load(.monotonic);
        const new_avg = if (current == 0)
            latency_us
        else
            (current * 9 + latency_us) / 10;
        self.avg_latency_us.store(new_avg, .monotonic);
    }

    /// Check if backend is available
    pub fn isAvailable(self: *const Backend) bool {
        return self.health != .unhealthy;
    }

    /// Create TCP connection to backend
    fn connect(self: *Backend) !posix.socket_t {
        const socket_ret = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
        if (socket_ret < 0) return error.SocketCreateFailed;
        const socket: posix.socket_t = @intCast(socket_ret);
        errdefer _ = std.c.close(socket);

        // Parse address
        const addr = try parseAddr(self.config.host, self.config.port);
        if (c.connect(socket, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) < 0) {
            return error.ConnectFailed;
        }

        return socket;
    }
};

// =============================================================================
// Backend Pool
// =============================================================================

pub const BackendPool = struct {
    allocator: std.mem.Allocator,
    backends: std.ArrayListUnmanaged(Backend) = .empty,
    next_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn init(allocator: std.mem.Allocator) BackendPool {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BackendPool) void {
        for (self.backends.items) |*backend| {
            backend.deinit();
        }
        self.backends.deinit(self.allocator);
    }

    /// Add a backend to the pool
    pub fn addBackend(self: *BackendPool, config: BackendConfig) !void {
        const backend = Backend.init(self.allocator, config);
        try self.backends.append(self.allocator, backend);
    }

    /// Get next available backend (round-robin)
    pub fn nextBackend(self: *BackendPool) ?*Backend {
        if (self.backends.items.len == 0) return null;

        // Round-robin with availability check
        const start = self.next_index.fetchAdd(1, .monotonic) % self.backends.items.len;
        var i: usize = 0;

        while (i < self.backends.items.len) : (i += 1) {
            const idx = (start + i) % self.backends.items.len;
            const backend = &self.backends.items[idx];

            if (backend.isAvailable()) {
                return backend;
            }
        }

        // No healthy backends, return any
        return &self.backends.items[start % self.backends.items.len];
    }

    /// Get backend by host match
    pub fn getBackendForHost(self: *BackendPool, host: []const u8) ?*Backend {
        for (self.backends.items) |*backend| {
            if (std.mem.eql(u8, backend.config.host, host) and backend.isAvailable()) {
                return backend;
            }
        }
        return null;
    }

    /// Get statistics
    pub fn getStats(self: *const BackendPool) PoolStats {
        var stats = PoolStats{};

        for (self.backends.items) |backend| {
            stats.total_backends += 1;
            if (backend.health == .healthy) stats.healthy_backends += 1;
            stats.total_connections += backend.active_connections.load(.monotonic);
            stats.total_requests += backend.total_requests.load(.monotonic);
        }

        return stats;
    }
};

pub const PoolStats = struct {
    total_backends: u32 = 0,
    healthy_backends: u32 = 0,
    total_connections: u32 = 0,
    total_requests: u64 = 0,
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Get current time in nanoseconds using clock_gettime
fn getTimeNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn parseAddr(addr_str: []const u8, port: u16) !c.sockaddr.in {
    var ip: [4]u8 = undefined;
    var iter = std.mem.splitScalar(u8, addr_str, '.');
    var i: usize = 0;

    while (iter.next()) |part| : (i += 1) {
        if (i >= 4) return error.InvalidAddress;
        ip[i] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidAddress;
    }
    if (i != 4) return error.InvalidAddress;

    return c.sockaddr.in{
        .family = c.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, @as(u32, ip[0]) << 24 | @as(u32, ip[1]) << 16 | @as(u32, ip[2]) << 8 | @as(u32, ip[3])),
    };
}

// =============================================================================
// Tests
// =============================================================================

test "backend pool round-robin" {
    const allocator = std.testing.allocator;

    var pool = BackendPool.init(allocator);
    defer pool.deinit();

    try pool.addBackend(.{ .host = "127.0.0.1", .port = 8001 });
    try pool.addBackend(.{ .host = "127.0.0.1", .port = 8002 });
    try pool.addBackend(.{ .host = "127.0.0.1", .port = 8003 });

    // Mark all as healthy
    for (pool.backends.items) |*b| {
        b.health = .healthy;
    }

    // Should round-robin through backends
    const b1 = pool.nextBackend().?;
    const b2 = pool.nextBackend().?;
    const b3 = pool.nextBackend().?;
    const b4 = pool.nextBackend().?;

    try std.testing.expect(b1 != b2);
    try std.testing.expect(b2 != b3);
    try std.testing.expect(b1 == b4); // Wrapped around
}

test "backend health tracking" {
    const allocator = std.testing.allocator;

    var backend = Backend.init(allocator, .{ .host = "127.0.0.1", .port = 8080, .max_failures = 3 });
    defer backend.deinit();

    try std.testing.expectEqual(HealthStatus.unknown, backend.health);

    // Success marks healthy
    backend.markSuccess(1000);
    try std.testing.expectEqual(HealthStatus.healthy, backend.health);

    // Multiple failures mark unhealthy
    backend.markFailure();
    backend.markFailure();
    try std.testing.expectEqual(HealthStatus.healthy, backend.health); // Still healthy

    backend.markFailure();
    try std.testing.expectEqual(HealthStatus.unhealthy, backend.health); // Now unhealthy

    // Success recovers
    backend.markSuccess(1000);
    try std.testing.expectEqual(HealthStatus.healthy, backend.health);
}
