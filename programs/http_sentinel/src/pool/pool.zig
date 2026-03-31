// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
// 
// Licensed under the MIT License. See LICENSE file for details.

const std = @import("std");
const http = std.http;

/// Enterprise-grade connection pool for high-performance HTTP operations
/// Implements connection reuse, keep-alive, and load balancing for maximum throughput

pub const PoolConfig = struct {
    max_connections_per_host: u32 = 20,
    max_idle_connections: u32 = 10,
    idle_timeout_ms: u64 = 30000,
    connection_timeout_ms: u64 = 5000,
    keep_alive_timeout_ms: u64 = 60000,
    max_requests_per_connection: u32 = 1000,
    enable_tcp_no_delay: bool = true,
    enable_keep_alive: bool = true,
};

pub const ConnectionStats = struct {
    total_connections: u32 = 0,
    active_connections: u32 = 0,
    idle_connections: u32 = 0,
    requests_served: u64 = 0,
    connections_created: u64 = 0,
    connections_reused: u64 = 0,
    timeouts: u64 = 0,
    errors: u64 = 0,
};

const PooledConnection = struct {
    connection: http.Client.Connection,
    host: []const u8,
    port: u16,
    is_secure: bool,
    created_at: i64,
    last_used: i64,
    requests_served: u32,
    is_idle: bool,
    
    pub fn isExpired(self: *const PooledConnection, config: PoolConfig) bool {
        const now = std.time.milliTimestamp();
        
        // Check idle timeout
        if (self.is_idle and (now - self.last_used) > config.idle_timeout_ms) {
            return true;
        }
        
        // Check keep-alive timeout
        if ((now - self.created_at) > config.keep_alive_timeout_ms) {
            return true;
        }
        
        // Check max requests per connection
        if (self.requests_served >= config.max_requests_per_connection) {
            return true;
        }
        
        return false;
    }
    
    pub fn deinit(self: *PooledConnection, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        // Connection cleanup is handled by the HTTP client
    }
};

pub const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    config: PoolConfig,
    connections: std.HashMap([]const u8, std.ArrayList(*PooledConnection), std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    stats: ConnectionStats,
    mutex: std.Thread.RwLock,
    cleanup_thread: ?std.Thread,
    should_stop: std.atomic.Value(bool),
    
    pub fn init(allocator: std.mem.Allocator, config: PoolConfig) !*ConnectionPool {
        var self = try allocator.create(ConnectionPool);
        self.* = ConnectionPool{
            .allocator = allocator,
            .config = config,
            .connections = std.HashMap([]const u8, std.ArrayList(*PooledConnection), std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .stats = ConnectionStats{},
            .mutex = std.Thread.RwLock{},
            .cleanup_thread = null,
            .should_stop = std.atomic.Value(bool).init(false),
        };
        
        // Start cleanup thread
        self.cleanup_thread = try std.Thread.spawn(.{}, cleanupWorker, .{self});
        
        return self;
    }
    
    pub fn deinit(self: *ConnectionPool) void {
        // Signal cleanup thread to stop
        self.should_stop.store(true, .release);
        
        if (self.cleanup_thread) |thread| {
            thread.join();
        }
        
        // Clean up all connections
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var iterator = self.connections.iterator();
        while (iterator.next()) |entry| {
            for (entry.value_ptr.items) |conn| {
                conn.deinit(self.allocator);
                self.allocator.destroy(conn);
            }
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.connections.deinit();
        self.allocator.destroy(self);
    }
    
    /// Get or create a connection for the specified host
    pub fn acquireConnection(
        self: *ConnectionPool,
        host: []const u8,
        port: u16,
        is_secure: bool,
    ) !*PooledConnection {
        const host_key = try self.createHostKey(host, port, is_secure);
        defer self.allocator.free(host_key);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Try to find an idle connection
        if (self.connections.get(host_key)) |conn_list| {
            for (conn_list.items) |conn| {
                if (conn.is_idle and !conn.isExpired(self.config)) {
                    // Reuse existing connection
                    conn.is_idle = false;
                    conn.last_used = std.time.milliTimestamp();
                    self.stats.connections_reused += 1;
                    self.stats.active_connections += 1;
                    self.stats.idle_connections -= 1;
                    return conn;
                }
            }
        }
        
        // Check connection limits
        const current_connections = if (self.connections.get(host_key)) |list| list.items.len else 0;
        if (current_connections >= self.config.max_connections_per_host) {
            return error.TooManyConnections;
        }
        
        // Create new connection
        const new_conn = try self.createConnection(host, port, is_secure);
        
        // Add to pool
        const owned_key = try self.allocator.dupe(u8, host_key);
        var result = try self.connections.getOrPut(owned_key);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(*PooledConnection).init(self.allocator);
        }
        try result.value_ptr.append(new_conn);
        
        self.stats.connections_created += 1;
        self.stats.active_connections += 1;
        self.stats.total_connections += 1;
        
        return new_conn;
    }
    
    /// Return a connection to the pool
    pub fn releaseConnection(self: *ConnectionPool, connection: *PooledConnection) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        connection.is_idle = true;
        connection.last_used = std.time.milliTimestamp();
        self.stats.requests_served += 1;
        self.stats.active_connections -= 1;
        self.stats.idle_connections += 1;
        
        // Check if we have too many idle connections
        if (self.stats.idle_connections > self.config.max_idle_connections) {
            self.cleanupOldestIdleConnection();
        }
    }
    
    /// Remove and destroy a connection from the pool
    pub fn removeConnection(self: *ConnectionPool, connection: *PooledConnection) void {
        const host_key = self.createHostKey(connection.host, connection.port, connection.is_secure) catch return;
        defer self.allocator.free(host_key);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.connections.getPtr(host_key)) |conn_list| {
            for (conn_list.items, 0..) |conn, i| {
                if (conn == connection) {
                    _ = conn_list.swapRemove(i);
                    conn.deinit(self.allocator);
                    self.allocator.destroy(conn);
                    
                    if (connection.is_idle) {
                        self.stats.idle_connections -= 1;
                    } else {
                        self.stats.active_connections -= 1;
                    }
                    self.stats.total_connections -= 1;
                    break;
                }
            }
        }
    }
    
    /// Get current pool statistics
    pub fn getStats(self: *ConnectionPool) ConnectionStats {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();
        return self.stats;
    }
    
    fn createConnection(
        self: *ConnectionPool,
        host: []const u8,
        port: u16,
        is_secure: bool,
    ) !*PooledConnection {
        const conn = try self.allocator.create(PooledConnection);
        
        // Create HTTP connection - try DNS resolution first
        const addresses = try std.net.getAddressList(self.allocator, host, port);
        defer addresses.deinit();
        if (addresses.addrs.len == 0) return error.HostNotFound;
        const address = addresses.addrs[0];
        
        const stream = std.net.tcpConnectToAddress(address) catch |err| {
            self.allocator.destroy(conn);
            return err;
        };
        
        // Configure TCP options
        if (self.config.enable_tcp_no_delay) {
            _ = std.posix.setsockopt(
                stream.handle,
                std.posix.IPPROTO.TCP,
                std.posix.TCP.NODELAY,
                &std.mem.toBytes(@as(c_int, 1)),
            ) catch {};
        }
        
        if (self.config.enable_keep_alive) {
            _ = std.posix.setsockopt(
                stream.handle,
                std.posix.SOL.SOCKET,
                std.posix.SO.KEEPALIVE,
                &std.mem.toBytes(@as(c_int, 1)),
            ) catch {};
        }
        
        conn.* = PooledConnection{
            .connection = http.Client.Connection{ .stream = stream },
            .host = try self.allocator.dupe(u8, host),
            .port = port,
            .is_secure = is_secure,
            .created_at = std.time.milliTimestamp(),
            .last_used = std.time.milliTimestamp(),
            .requests_served = 0,
            .is_idle = false,
        };
        
        return conn;
    }
    
    fn createHostKey(self: *ConnectionPool, host: []const u8, port: u16, is_secure: bool) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}:{d}:{s}", .{ 
            host, 
            port, 
            if (is_secure) "https" else "http" 
        });
    }
    
    fn cleanupOldestIdleConnection(self: *ConnectionPool) void {
        var oldest_time: i64 = std.math.maxInt(i64);
        var oldest_conn: ?*PooledConnection = null;
        
        var iterator = self.connections.iterator();
        while (iterator.next()) |entry| {
            for (entry.value_ptr.items) |conn| {
                if (conn.is_idle and conn.last_used < oldest_time) {
                    oldest_time = conn.last_used;
                    oldest_conn = conn;
                }
            }
        }
        
        if (oldest_conn) |conn| {
            self.removeConnection(conn);
        }
    }
    
    fn cleanupWorker(self: *ConnectionPool) void {
        while (!self.should_stop.load(.acquire)) {
            std.Thread.sleep(5 * std.time.ns_per_s); // Check every 5 seconds
            
            self.mutex.lock();
            defer self.mutex.unlock();
            
            var iterator = self.connections.iterator();
            while (iterator.next()) |entry| {
                var i: usize = 0;
                while (i < entry.value_ptr.items.len) {
                    const conn = entry.value_ptr.items[i];
                    if (conn.isExpired(self.config)) {
                        _ = entry.value_ptr.swapRemove(i);
                        
                        if (conn.is_idle) {
                            self.stats.idle_connections -= 1;
                        } else {
                            self.stats.active_connections -= 1;
                        }
                        self.stats.total_connections -= 1;
                        
                        conn.deinit(self.allocator);
                        self.allocator.destroy(conn);
                    } else {
                        i += 1;
                    }
                }
            }
        }
    }
};