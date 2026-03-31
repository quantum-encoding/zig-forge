//! Distributed KV Store Client Library
//!
//! High-level client API for interacting with the distributed KV store:
//! - Automatic leader discovery and redirection
//! - Connection pooling with retry logic
//! - Async operation support
//! - Watch/subscribe capabilities
//!
//! Usage:
//!   var client = try Client.init(allocator, &[_][]const u8{"127.0.0.1:8000", "127.0.0.1:8001"});
//!   defer client.deinit();
//!
//!   try client.set("key", "value", null);
//!   const value = try client.get("key");

const std = @import("std");
const rpc = @import("rpc.zig");
const raft = @import("raft.zig");
const linux = std.os.linux;

// Zig 0.16 compatible Mutex using pthreads
const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

// Socket I/O wrappers for Zig 0.16
fn sendAll(sock: std.posix.fd_t, data: []const u8) !void {
    var sent: usize = 0;
    while (sent < data.len) {
        const result = linux.sendto(@intCast(sock), data[sent..].ptr, data.len - sent, 0, null, 0);
        const n: isize = @bitCast(result);
        if (n <= 0) return error.SendFailed;
        sent += @intCast(result);
    }
}

fn recvAll(sock: std.posix.fd_t, buf: []u8) !usize {
    const result = linux.recvfrom(@intCast(sock), buf.ptr, buf.len, 0, null, null);
    const n: isize = @bitCast(result);
    if (n < 0) return error.RecvFailed;
    return @intCast(result);
}

fn nanosleepMs(ms: u64) void {
    var ts: linux.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = linux.nanosleep(&ts, null);
}

// =============================================================================
// Configuration
// =============================================================================

pub const ClientConfig = struct {
    /// Connection timeout in milliseconds
    connect_timeout_ms: u64 = 5000,
    /// Request timeout in milliseconds
    request_timeout_ms: u64 = 10000,
    /// Maximum retry attempts
    max_retries: u32 = 3,
    /// Retry backoff base (milliseconds)
    retry_backoff_ms: u64 = 100,
    /// Maximum connections per node
    max_connections_per_node: usize = 5,
};

// =============================================================================
// Response Types
// =============================================================================

pub const GetResponse = struct {
    value: []u8,
    version: u64,

    pub fn deinit(self: *const GetResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
    }
};

pub const SetResponse = struct {
    version: u64,
};

pub const DeleteResponse = struct {
    deleted: bool,
};

pub const CasResponse = struct {
    success: bool,
    new_version: u64,
};

// =============================================================================
// Client Errors
// =============================================================================

pub const ClientError = error{
    NotConnected,
    NoLeader,
    LeaderRedirect,
    Timeout,
    KeyNotFound,
    CasFailed,
    InternalError,
    InvalidResponse,
    AllNodesFailed,
    OutOfMemory,
    ConnectionFailed,
};

// =============================================================================
// Client
// =============================================================================

/// Distributed KV store client
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: ClientConfig,
    nodes: std.ArrayListUnmanaged(NodeInfo),
    current_leader: ?usize,
    correlation_counter: u64,
    mutex: Mutex,

    const NodeInfo = struct {
        address: rpc.NodeAddress,
        address_str: []u8,
        pool: ?*rpc.ConnectionPool,
        healthy: bool,
        last_check: i64,
    };

    pub fn init(allocator: std.mem.Allocator, node_addresses: []const []const u8) !Client {
        return initWithConfig(allocator, node_addresses, .{});
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, node_addresses: []const []const u8, config: ClientConfig) !Client {
        var client = Client{
            .allocator = allocator,
            .config = config,
            .nodes = .empty,
            .current_leader = null,
            .correlation_counter = 0,
            .mutex = .{},
        };

        // Parse and add nodes
        for (node_addresses) |addr_str| {
            const address = rpc.NodeAddress.parse(addr_str) catch continue;
            const owned_str = try allocator.dupe(u8, addr_str);
            errdefer allocator.free(owned_str);

            try client.nodes.append(allocator, NodeInfo{
                .address = address,
                .address_str = owned_str,
                .pool = null,
                .healthy = true,
                .last_check = 0,
            });
        }

        if (client.nodes.items.len == 0) {
            return ClientError.NotConnected;
        }

        return client;
    }

    pub fn deinit(self: *Client) void {
        for (self.nodes.items) |*node| {
            self.allocator.free(node.address_str);
            if (node.pool) |pool| {
                pool.deinit();
                self.allocator.destroy(pool);
            }
        }
        self.nodes.deinit(self.allocator);
    }

    // -------------------------------------------------------------------------
    // Public API
    // -------------------------------------------------------------------------

    /// Get a value by key
    pub fn get(self: *Client, key: []const u8) !GetResponse {
        const request = try self.encodeGetRequest(key);
        defer self.allocator.free(request);

        const response = try self.sendRequest(.client_req, request);
        defer self.allocator.free(response);

        return self.decodeGetResponse(response);
    }

    /// Set a key-value pair
    pub fn set(self: *Client, key: []const u8, value: []const u8, ttl_ms: ?u64) !SetResponse {
        const request = try self.encodeSetRequest(key, value, ttl_ms);
        defer self.allocator.free(request);

        const response = try self.sendRequest(.client_req, request);
        defer self.allocator.free(response);

        return self.decodeSetResponse(response);
    }

    /// Delete a key
    pub fn delete(self: *Client, key: []const u8) !DeleteResponse {
        const request = try self.encodeDeleteRequest(key);
        defer self.allocator.free(request);

        const response = try self.sendRequest(.client_req, request);
        defer self.allocator.free(response);

        return self.decodeDeleteResponse(response);
    }

    /// Compare-and-swap operation
    pub fn cas(self: *Client, key: []const u8, expected_version: u64, new_value: []const u8, ttl_ms: ?u64) !CasResponse {
        const request = try self.encodeCasRequest(key, expected_version, new_value, ttl_ms);
        defer self.allocator.free(request);

        const response = try self.sendRequest(.client_req, request);
        defer self.allocator.free(response);

        return self.decodeCasResponse(response);
    }

    /// List keys with optional prefix
    pub fn listKeys(self: *Client, prefix: []const u8, limit: u32) ![][]u8 {
        const request = try self.encodeListRequest(prefix, limit);
        defer self.allocator.free(request);

        const response = try self.sendRequest(.client_req, request);
        defer self.allocator.free(response);

        return self.decodeListResponse(response);
    }

    /// Check if a key exists
    pub fn exists(self: *Client, key: []const u8) !bool {
        const result = self.get(key) catch |err| {
            if (err == ClientError.KeyNotFound) return false;
            return err;
        };
        result.deinit(self.allocator);
        return true;
    }

    // -------------------------------------------------------------------------
    // Request Encoding
    // -------------------------------------------------------------------------

    fn encodeGetRequest(self: *Client, key: []const u8) ![]u8 {
        // Format: op(1) + key_len(4) + key
        var buf = try self.allocator.alloc(u8, 5 + key.len);
        buf[0] = @intFromEnum(rpc.ClientOp.get);
        std.mem.writeInt(u32, buf[1..5], @intCast(key.len), .little);
        @memcpy(buf[5..], key);
        return buf;
    }

    fn encodeSetRequest(self: *Client, key: []const u8, value: []const u8, ttl_ms: ?u64) ![]u8 {
        // Format: op(1) + key_len(4) + key + value_len(4) + value + has_ttl(1) + ttl(8)
        const total = 1 + 4 + key.len + 4 + value.len + 1 + 8;
        var buf = try self.allocator.alloc(u8, total);

        var offset: usize = 0;
        buf[offset] = @intFromEnum(rpc.ClientOp.set);
        offset += 1;

        std.mem.writeInt(u32, buf[offset..][0..4], @intCast(key.len), .little);
        offset += 4;
        @memcpy(buf[offset .. offset + key.len], key);
        offset += key.len;

        std.mem.writeInt(u32, buf[offset..][0..4], @intCast(value.len), .little);
        offset += 4;
        @memcpy(buf[offset .. offset + value.len], value);
        offset += value.len;

        buf[offset] = if (ttl_ms != null) 1 else 0;
        offset += 1;
        std.mem.writeInt(u64, buf[offset..][0..8], ttl_ms orelse 0, .little);

        return buf;
    }

    fn encodeDeleteRequest(self: *Client, key: []const u8) ![]u8 {
        var buf = try self.allocator.alloc(u8, 5 + key.len);
        buf[0] = @intFromEnum(rpc.ClientOp.delete);
        std.mem.writeInt(u32, buf[1..5], @intCast(key.len), .little);
        @memcpy(buf[5..], key);
        return buf;
    }

    fn encodeCasRequest(self: *Client, key: []const u8, expected_version: u64, new_value: []const u8, ttl_ms: ?u64) ![]u8 {
        const total = 1 + 4 + key.len + 8 + 4 + new_value.len + 1 + 8;
        var buf = try self.allocator.alloc(u8, total);

        var offset: usize = 0;
        buf[offset] = @intFromEnum(rpc.ClientOp.cas);
        offset += 1;

        std.mem.writeInt(u32, buf[offset..][0..4], @intCast(key.len), .little);
        offset += 4;
        @memcpy(buf[offset .. offset + key.len], key);
        offset += key.len;

        std.mem.writeInt(u64, buf[offset..][0..8], expected_version, .little);
        offset += 8;

        std.mem.writeInt(u32, buf[offset..][0..4], @intCast(new_value.len), .little);
        offset += 4;
        @memcpy(buf[offset .. offset + new_value.len], new_value);
        offset += new_value.len;

        buf[offset] = if (ttl_ms != null) 1 else 0;
        offset += 1;
        std.mem.writeInt(u64, buf[offset..][0..8], ttl_ms orelse 0, .little);

        return buf;
    }

    fn encodeListRequest(self: *Client, prefix: []const u8, limit: u32) ![]u8 {
        var buf = try self.allocator.alloc(u8, 9 + prefix.len);
        buf[0] = @intFromEnum(rpc.ClientOp.list);
        std.mem.writeInt(u32, buf[1..5], @intCast(prefix.len), .little);
        @memcpy(buf[5 .. 5 + prefix.len], prefix);
        std.mem.writeInt(u32, buf[5 + prefix.len ..][0..4], limit, .little);
        return buf;
    }

    // -------------------------------------------------------------------------
    // Response Decoding
    // -------------------------------------------------------------------------

    fn decodeGetResponse(self: *Client, response: []const u8) !GetResponse {
        if (response.len < 1) return ClientError.InvalidResponse;

        const status: rpc.ClientStatus = @enumFromInt(response[0]);
        switch (status) {
            .ok => {
                if (response.len < 13) return ClientError.InvalidResponse;
                const value_len = std.mem.readInt(u32, response[1..5], .little);
                const version = std.mem.readInt(u64, response[5..13], .little);

                if (response.len < 13 + value_len) return ClientError.InvalidResponse;
                const value = try self.allocator.dupe(u8, response[13 .. 13 + value_len]);

                return GetResponse{ .value = value, .version = version };
            },
            .key_not_found => return ClientError.KeyNotFound,
            .not_leader => return ClientError.NoLeader,
            else => return ClientError.InternalError,
        }
    }

    fn decodeSetResponse(_: *Client, response: []const u8) !SetResponse {
        if (response.len < 9) return ClientError.InvalidResponse;

        const status: rpc.ClientStatus = @enumFromInt(response[0]);
        switch (status) {
            .ok => {
                const version = std.mem.readInt(u64, response[1..9], .little);
                return SetResponse{ .version = version };
            },
            .not_leader => return ClientError.NoLeader,
            else => return ClientError.InternalError,
        }
    }

    fn decodeDeleteResponse(_: *Client, response: []const u8) !DeleteResponse {
        if (response.len < 2) return ClientError.InvalidResponse;

        const status: rpc.ClientStatus = @enumFromInt(response[0]);
        switch (status) {
            .ok => {
                return DeleteResponse{ .deleted = response[1] != 0 };
            },
            .not_leader => return ClientError.NoLeader,
            else => return ClientError.InternalError,
        }
    }

    fn decodeCasResponse(_: *Client, response: []const u8) !CasResponse {
        if (response.len < 10) return ClientError.InvalidResponse;

        const status: rpc.ClientStatus = @enumFromInt(response[0]);
        switch (status) {
            .ok => {
                const success = response[1] != 0;
                const new_version = std.mem.readInt(u64, response[2..10], .little);
                return CasResponse{ .success = success, .new_version = new_version };
            },
            .cas_failed => return CasResponse{ .success = false, .new_version = 0 },
            .not_leader => return ClientError.NoLeader,
            else => return ClientError.InternalError,
        }
    }

    fn decodeListResponse(self: *Client, response: []const u8) ![][]u8 {
        if (response.len < 1) return ClientError.InvalidResponse;

        const status: rpc.ClientStatus = @enumFromInt(response[0]);
        if (status != .ok) {
            if (status == .not_leader) return ClientError.NoLeader;
            return ClientError.InternalError;
        }

        if (response.len < 5) return ClientError.InvalidResponse;

        const count = std.mem.readInt(u32, response[1..5], .little);
        var result = try self.allocator.alloc([]u8, count);
        errdefer {
            for (result) |item| self.allocator.free(item);
            self.allocator.free(result);
        }

        var offset: usize = 5;
        for (0..count) |i| {
            if (offset + 4 > response.len) {
                for (result[0..i]) |item| self.allocator.free(item);
                self.allocator.free(result);
                return ClientError.InvalidResponse;
            }
            const key_len = std.mem.readInt(u32, response[offset..][0..4], .little);
            offset += 4;

            if (offset + key_len > response.len) {
                for (result[0..i]) |item| self.allocator.free(item);
                self.allocator.free(result);
                return ClientError.InvalidResponse;
            }
            result[i] = try self.allocator.dupe(u8, response[offset .. offset + key_len]);
            offset += key_len;
        }

        return result;
    }

    // -------------------------------------------------------------------------
    // Network Communication
    // -------------------------------------------------------------------------

    fn sendRequest(self: *Client, msg_type: rpc.MessageType, payload: []const u8) ![]u8 {
        var retries: u32 = 0;
        var last_error: ?anyerror = null;

        while (retries < self.config.max_retries) : (retries += 1) {
            // Try leader first if known
            const node_idx = self.selectNode();

            if (self.sendToNode(node_idx, msg_type, payload)) |response| {
                return response;
            } else |err| {
                last_error = err;

                // Mark node as unhealthy if connection failed
                if (err == ClientError.ConnectionFailed) {
                    self.mutex.lock();
                    if (node_idx < self.nodes.items.len) {
                        self.nodes.items[node_idx].healthy = false;
                    }
                    self.mutex.unlock();
                }

                // Try other nodes
                for (self.nodes.items, 0..) |_, i| {
                    if (i == node_idx) continue;
                    if (self.sendToNode(i, msg_type, payload)) |response| {
                        // Update leader hint
                        self.mutex.lock();
                        self.current_leader = i;
                        self.mutex.unlock();
                        return response;
                    } else |_| {}
                }
            }

            // Backoff before retry
            const backoff = self.config.retry_backoff_ms * (@as(u64, 1) << @intCast(retries));
            nanosleepMs(backoff);
        }

        return last_error orelse ClientError.AllNodesFailed;
    }

    fn sendToNode(self: *Client, node_idx: usize, msg_type: rpc.MessageType, payload: []const u8) ![]u8 {
        self.mutex.lock();
        const node = &self.nodes.items[node_idx];

        // Create pool if needed
        if (node.pool == null) {
            const pool = self.allocator.create(rpc.ConnectionPool) catch {
                self.mutex.unlock();
                return ClientError.OutOfMemory;
            };
            pool.* = rpc.ConnectionPool.init(self.allocator, node.address, self.config.max_connections_per_node);
            node.pool = pool;
        }

        const pool = node.pool.?;
        self.mutex.unlock();

        // Acquire connection
        const stream = pool.acquire() catch return ClientError.ConnectionFailed;
        defer pool.release(stream);

        // Build and send message
        const correlation_id = self.nextCorrelationId();
        const msg = rpc.Message{
            .msg_type = msg_type,
            .correlation_id = correlation_id,
            .payload = @constCast(payload),
        };

        const encoded = msg.encode(self.allocator) catch return ClientError.OutOfMemory;
        defer self.allocator.free(encoded);

        sendAll(stream, encoded) catch return ClientError.ConnectionFailed;

        // Read response
        var header_buf: [13]u8 = undefined; // HEADER_SIZE = 13
        const read = recvAll(stream, &header_buf) catch return ClientError.ConnectionFailed;
        if (read < 13) return ClientError.InvalidResponse;

        const header = rpc.Message.decodeHeader(&header_buf) catch return ClientError.InvalidResponse;

        var response_payload: []u8 = &[_]u8{};
        if (header.payload_len > 0) {
            response_payload = self.allocator.alloc(u8, header.payload_len) catch return ClientError.OutOfMemory;
            errdefer self.allocator.free(response_payload);

            var total_read: usize = 0;
            while (total_read < header.payload_len) {
                const n = recvAll(stream, response_payload[total_read..]) catch {
                    self.allocator.free(response_payload);
                    return ClientError.ConnectionFailed;
                };
                if (n == 0) {
                    self.allocator.free(response_payload);
                    return ClientError.ConnectionFailed;
                }
                total_read += n;
            }
        }

        return response_payload;
    }

    fn selectNode(self: *Client) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Prefer known leader
        if (self.current_leader) |leader| {
            if (leader < self.nodes.items.len and self.nodes.items[leader].healthy) {
                return leader;
            }
        }

        // Find first healthy node
        for (self.nodes.items, 0..) |node, i| {
            if (node.healthy) return i;
        }

        // All nodes unhealthy, try first one
        return 0;
    }

    fn nextCorrelationId(self: *Client) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.correlation_counter += 1;
        return self.correlation_counter;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "client initialization" {
    const allocator = std.testing.allocator;

    const addresses = [_][]const u8{ "127.0.0.1:8000", "127.0.0.1:8001" };
    var client = try Client.init(allocator, &addresses);
    defer client.deinit();

    try std.testing.expectEqual(@as(usize, 2), client.nodes.items.len);
}

test "request encoding" {
    const allocator = std.testing.allocator;

    const addresses = [_][]const u8{"127.0.0.1:8000"};
    var client = try Client.init(allocator, &addresses);
    defer client.deinit();

    const get_req = try client.encodeGetRequest("test-key");
    defer allocator.free(get_req);

    try std.testing.expectEqual(@intFromEnum(rpc.ClientOp.get), get_req[0]);
    try std.testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, get_req[1..5], .little));
}
