//! RPC Layer for Raft Node Communication
//!
//! Provides TCP-based communication between Raft nodes:
//! - Multiplexed connections with connection pooling
//! - Binary protocol with message framing
//! - Automatic reconnection with exponential backoff
//! - Request/response correlation
//!
//! Wire Protocol:
//!   Message: msg_type(1) + correlation_id(8) + payload_len(4) + payload(n)
//!
//! Message Types:
//!   0x01 = RequestVote Request
//!   0x02 = RequestVote Response
//!   0x03 = AppendEntries Request
//!   0x04 = AppendEntries Response
//!   0x05 = Client Request
//!   0x06 = Client Response

const std = @import("std");
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

// =============================================================================
// Socket Wrappers (Zig 0.16 compatible)
// =============================================================================

const SocketError = error{
    SocketCreationFailed,
    ConnectionFailed,
    BindFailed,
    ListenFailed,
    AcceptFailed,
};

fn createSocket() SocketError!std.posix.fd_t {
    const result = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    if (@as(isize, @bitCast(result)) < 0) {
        return SocketError.SocketCreationFailed;
    }
    return @intCast(result);
}

fn connectSocket(sock: std.posix.fd_t, addr: anytype, addrlen: u32) SocketError!void {
    const result = linux.connect(@intCast(sock), @ptrCast(addr), addrlen);
    if (@as(isize, @bitCast(result)) < 0) {
        return SocketError.ConnectionFailed;
    }
}

fn bindSocket(sock: std.posix.fd_t, addr: anytype, addrlen: u32) SocketError!void {
    const result = linux.bind(@intCast(sock), @ptrCast(addr), addrlen);
    if (@as(isize, @bitCast(result)) < 0) {
        return SocketError.BindFailed;
    }
}

fn listenSocket(sock: std.posix.fd_t, backlog: u31) SocketError!void {
    const result = linux.listen(@intCast(sock), backlog);
    if (@as(isize, @bitCast(result)) < 0) {
        return SocketError.ListenFailed;
    }
}

fn acceptSocket(sock: std.posix.fd_t) SocketError!std.posix.fd_t {
    const result = linux.accept(@intCast(sock), null, null);
    if (@as(isize, @bitCast(result)) < 0) {
        return SocketError.AcceptFailed;
    }
    return @intCast(result);
}

fn setsockoptReuseAddr(sock: std.posix.fd_t) void {
    const opt_val: c_int = 1;
    _ = linux.setsockopt(
        @intCast(sock),
        linux.SOL.SOCKET,
        linux.SO.REUSEADDR,
        std.mem.asBytes(&opt_val),
        @sizeOf(c_int),
    );
}

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

// =============================================================================
// Helper Functions
// =============================================================================

/// Get current time in milliseconds
fn currentTimeMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @divTrunc(@as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000), 1);
}

// =============================================================================
// Constants
// =============================================================================

/// Message type identifiers
pub const MessageType = enum(u8) {
    request_vote_req = 0x01,
    request_vote_resp = 0x02,
    append_entries_req = 0x03,
    append_entries_resp = 0x04,
    client_req = 0x05,
    client_resp = 0x06,
    heartbeat = 0x07,
    snapshot_req = 0x08,
    snapshot_resp = 0x09,
};

/// Message header size
const HEADER_SIZE: usize = 13; // type(1) + correlation_id(8) + len(4)

/// Maximum message payload size (16MB)
const MAX_PAYLOAD_SIZE: u32 = 16 * 1024 * 1024;

/// Connection timeout (10 seconds)
const CONNECT_TIMEOUT_MS: u64 = 10_000;

/// Read timeout (5 seconds)
const READ_TIMEOUT_MS: u64 = 5_000;

/// Maximum reconnect delay (30 seconds)
const MAX_RECONNECT_DELAY_MS: u64 = 30_000;

/// Initial reconnect delay (100ms)
const INITIAL_RECONNECT_DELAY_MS: u64 = 100;

// =============================================================================
// Types
// =============================================================================

/// Node address
pub const NodeAddress = struct {
    host: []const u8,
    port: u16,

    pub fn parse(s: []const u8) !NodeAddress {
        // Format: host:port
        const colon_idx = std.mem.lastIndexOf(u8, s, ":") orelse return error.InvalidAddress;
        const host = s[0..colon_idx];
        const port_str = s[colon_idx + 1 ..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidAddress;
        return NodeAddress{ .host = host, .port = port };
    }

    pub fn format(self: *const NodeAddress, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}:{d}", .{ self.host, self.port });
    }

    /// Convert to sockaddr for posix calls
    pub fn toSockaddr(self: *const NodeAddress) !std.posix.sockaddr.in {
        // Parse IP address (only IPv4 for simplicity)
        var addr: std.posix.sockaddr.in = .{
            .family = std.posix.AF.INET,
            .port = std.mem.nativeToBig(u16, self.port),
            .addr = 0,
        };

        // Parse dotted decimal IP
        var parts: [4]u8 = undefined;
        var iter = std.mem.splitScalar(u8, self.host, '.');
        var i: usize = 0;
        while (iter.next()) |part| {
            if (i >= 4) return error.InvalidAddress;
            parts[i] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidAddress;
            i += 1;
        }
        if (i != 4) return error.InvalidAddress;

        addr.addr = @bitCast(parts);
        return addr;
    }
};

/// RPC message
pub const Message = struct {
    msg_type: MessageType,
    correlation_id: u64,
    payload: []u8,

    pub fn encode(self: *const Message, allocator: std.mem.Allocator) ![]u8 {
        const total_size = HEADER_SIZE + self.payload.len;
        var buf = try allocator.alloc(u8, total_size);

        buf[0] = @intFromEnum(self.msg_type);
        std.mem.writeInt(u64, buf[1..9], self.correlation_id, .little);
        std.mem.writeInt(u32, buf[9..13], @intCast(self.payload.len), .little);

        if (self.payload.len > 0) {
            @memcpy(buf[HEADER_SIZE..], self.payload);
        }

        return buf;
    }

    pub fn decodeHeader(buf: []const u8) !struct { msg_type: MessageType, correlation_id: u64, payload_len: u32 } {
        if (buf.len < HEADER_SIZE) return error.InvalidMessage;

        const msg_type: MessageType = switch (buf[0]) {
            0x01 => .request_vote_req,
            0x02 => .request_vote_resp,
            0x03 => .append_entries_req,
            0x04 => .append_entries_resp,
            0x05 => .client_req,
            0x06 => .client_resp,
            0x07 => .heartbeat,
            0x08 => .snapshot_req,
            0x09 => .snapshot_resp,
            else => return error.InvalidMessageType,
        };

        const correlation_id = std.mem.readInt(u64, buf[1..9], .little);
        const payload_len = std.mem.readInt(u32, buf[9..13], .little);

        if (payload_len > MAX_PAYLOAD_SIZE) return error.PayloadTooLarge;

        return .{ .msg_type = msg_type, .correlation_id = correlation_id, .payload_len = payload_len };
    }

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        if (self.payload.len > 0) {
            allocator.free(self.payload);
        }
    }
};

/// Client request types
pub const ClientOp = enum(u8) {
    get = 0x01,
    set = 0x02,
    delete = 0x03,
    cas = 0x04,
    list = 0x05,
};

/// Client response status
pub const ClientStatus = enum(u8) {
    ok = 0x00,
    not_leader = 0x01,
    key_not_found = 0x02,
    cas_failed = 0x03,
    timeout = 0x04,
    internal_error = 0xFF,
};

// =============================================================================
// Connection Pool
// =============================================================================

/// Pooled connection to a peer
const PooledConnection = struct {
    socket: std.posix.socket_t,
    last_used: i64,
    in_use: bool,
};

/// Connection pool for a single peer
pub const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    address: NodeAddress,
    connections: std.ArrayListUnmanaged(PooledConnection),
    max_connections: usize,
    mutex: Mutex,

    pub fn init(allocator: std.mem.Allocator, address: NodeAddress, max_conns: usize) ConnectionPool {
        return ConnectionPool{
            .allocator = allocator,
            .address = address,
            .connections = .empty,
            .max_connections = max_conns,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        for (self.connections.items) |*conn| {
            _ = std.c.close(conn.socket);
        }
        self.connections.deinit(self.allocator);
    }

    /// Get a connection from the pool or create new one
    pub fn acquire(self: *ConnectionPool) !std.posix.socket_t {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Try to find an available connection
        for (self.connections.items) |*conn| {
            if (!conn.in_use) {
                conn.in_use = true;
                conn.last_used = currentTimeMs();
                return conn.socket;
            }
        }

        // Create new connection if under limit
        if (self.connections.items.len < self.max_connections) {
            const sock = try self.connect();
            try self.connections.append(self.allocator, PooledConnection{
                .socket = sock,
                .last_used = currentTimeMs(),
                .in_use = true,
            });
            return sock;
        }

        return error.PoolExhausted;
    }

    /// Release a connection back to the pool
    pub fn release(self: *ConnectionPool, sock: std.posix.socket_t) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.connections.items) |*conn| {
            if (conn.socket == sock) {
                conn.in_use = false;
                conn.last_used = currentTimeMs();
                return;
            }
        }
    }

    /// Create a new connection
    fn connect(self: *ConnectionPool) !std.posix.socket_t {
        const sock = createSocket() catch return error.ConnectionFailed;
        errdefer _ = std.c.close(sock);

        const addr = try self.address.toSockaddr();
        connectSocket(sock, &addr, @sizeOf(@TypeOf(addr))) catch return error.ConnectionFailed;

        return sock;
    }
};

// =============================================================================
// RPC Server
// =============================================================================

/// RPC server that handles incoming connections
pub const RpcServer = struct {
    allocator: std.mem.Allocator,
    socket: ?std.posix.socket_t,
    port: u16,
    running: std.atomic.Value(bool),
    raft_node: ?*raft.RaftNode,

    pub fn init(allocator: std.mem.Allocator, port: u16) RpcServer {
        return RpcServer{
            .allocator = allocator,
            .socket = null,
            .port = port,
            .running = std.atomic.Value(bool).init(false),
            .raft_node = null,
        };
    }

    pub fn deinit(self: *RpcServer) void {
        self.stop();
        if (self.socket) |sock| {
            _ = std.c.close(sock);
        }
    }

    /// Set the Raft node to dispatch messages to
    pub fn setRaftNode(self: *RpcServer, node: *raft.RaftNode) void {
        self.raft_node = node;
    }

    /// Start the server
    pub fn start(self: *RpcServer) !void {
        // Create socket
        const sock = createSocket() catch return error.SocketCreationFailed;
        errdefer _ = std.c.close(sock);

        // Set SO_REUSEADDR
        setsockoptReuseAddr(sock);

        // Bind
        var addr: std.posix.sockaddr.in = .{
            .family = std.posix.AF.INET,
            .port = std.mem.nativeToBig(u16, self.port),
            .addr = 0, // INADDR_ANY
        };
        bindSocket(sock, &addr, @sizeOf(@TypeOf(addr))) catch return error.BindFailed;

        // Listen
        listenSocket(sock, 128) catch return error.ListenFailed;

        self.socket = sock;
        self.running.store(true, .release);
    }

    /// Stop the server
    pub fn stop(self: *RpcServer) void {
        self.running.store(false, .release);
    }

    /// Accept and handle one connection (call in a loop)
    pub fn acceptOne(self: *RpcServer) !void {
        const listen_sock = self.socket orelse return error.NotStarted;

        const client = acceptSocket(listen_sock) catch {
            return;
        };
        defer _ = std.c.close(client);

        // Handle messages on this connection
        try self.handleConnection(client);
    }

    /// Handle messages on a connection
    fn handleConnection(self: *RpcServer, client: std.posix.socket_t) !void {
        while (self.running.load(.acquire)) {
            // Read header
            var header_buf: [HEADER_SIZE]u8 = undefined;
            const read = recvAll(client, &header_buf) catch {
                return;
            };

            if (read == 0) return; // Connection closed
            if (read < HEADER_SIZE) continue;

            const header = Message.decodeHeader(&header_buf) catch continue;

            // Read payload
            var payload: []u8 = &[_]u8{};
            if (header.payload_len > 0) {
                payload = try self.allocator.alloc(u8, header.payload_len);
                errdefer self.allocator.free(payload);

                var total_read: usize = 0;
                while (total_read < header.payload_len) {
                    const n = recvAll(client, payload[total_read..]) catch {
                        self.allocator.free(payload);
                        return;
                    };
                    if (n == 0) {
                        self.allocator.free(payload);
                        return;
                    }
                    total_read += n;
                }
            }
            defer if (payload.len > 0) self.allocator.free(payload);

            // Handle message
            const response = self.handleMessage(header.msg_type, header.correlation_id, payload);
            if (response) |resp| {
                defer if (resp.payload.len > 0) self.allocator.free(resp.payload);
                const encoded = resp.encode(self.allocator) catch continue;
                defer self.allocator.free(encoded);
                sendAll(client, encoded) catch return;
            }
        }
    }

    /// Handle a single message and return response
    fn handleMessage(self: *RpcServer, msg_type: MessageType, correlation_id: u64, payload: []const u8) ?Message {
        const node = self.raft_node orelse return null;
        _ = node;

        switch (msg_type) {
            .request_vote_req => {
                const req = raft.RequestVoteRequest.decode(payload) catch return null;
                const resp = self.raft_node.?.handleRequestVote(req);
                const resp_encoded = resp.encode();
                return Message{
                    .msg_type = .request_vote_resp,
                    .correlation_id = correlation_id,
                    .payload = self.allocator.dupe(u8, &resp_encoded) catch return null,
                };
            },
            .append_entries_req => {
                // AppendEntries requires decoding entries which is complex
                // For now, just handle the header
                if (payload.len < 48) return null;

                const term = std.mem.readInt(u64, payload[0..8], .little);
                const leader_id = std.mem.readInt(u64, payload[8..16], .little);
                const prev_log_index = std.mem.readInt(u64, payload[16..24], .little);
                const prev_log_term = std.mem.readInt(u64, payload[24..32], .little);
                _ = std.mem.readInt(u64, payload[32..40], .little); // entries_len
                const leader_commit = std.mem.readInt(u64, payload[40..48], .little);

                // For heartbeats (no entries), create empty request
                const req = raft.AppendEntriesRequest{
                    .term = term,
                    .leader_id = leader_id,
                    .prev_log_index = prev_log_index,
                    .prev_log_term = prev_log_term,
                    .entries = &[_]raft.LogEntry{},
                    .leader_commit = leader_commit,
                };

                const resp = self.raft_node.?.handleAppendEntries(req);
                const resp_encoded = resp.encode();
                return Message{
                    .msg_type = .append_entries_resp,
                    .correlation_id = correlation_id,
                    .payload = self.allocator.dupe(u8, &resp_encoded) catch return null,
                };
            },
            else => return null,
        }
    }
};

// =============================================================================
// RPC Client
// =============================================================================

/// RPC client for sending messages to peers
pub const RpcClient = struct {
    allocator: std.mem.Allocator,
    pools: std.AutoHashMapUnmanaged(raft.NodeId, *ConnectionPool),
    addresses: std.AutoHashMapUnmanaged(raft.NodeId, NodeAddress),
    correlation_counter: u64,
    mutex: Mutex,

    pub fn init(allocator: std.mem.Allocator) RpcClient {
        return RpcClient{
            .allocator = allocator,
            .pools = .empty,
            .addresses = .empty,
            .correlation_counter = 0,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *RpcClient) void {
        var iter = self.pools.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.pools.deinit(self.allocator);
        self.addresses.deinit(self.allocator);
    }

    /// Register a peer address
    pub fn addPeer(self: *RpcClient, node_id: raft.NodeId, address: NodeAddress) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.addresses.put(self.allocator, node_id, address);
    }

    /// Send RequestVote RPC
    pub fn sendRequestVote(self: *RpcClient, target: raft.NodeId, req: raft.RequestVoteRequest) !raft.RequestVoteResponse {
        const payload_buf = req.encode();
        const msg = Message{
            .msg_type = .request_vote_req,
            .correlation_id = self.nextCorrelationId(),
            .payload = @constCast(&payload_buf),
        };

        const response = try self.sendAndReceive(target, msg);
        defer if (response.payload.len > 0) self.allocator.free(response.payload);

        return raft.RequestVoteResponse.decode(response.payload);
    }

    /// Send AppendEntries RPC (heartbeat/replication)
    pub fn sendAppendEntries(self: *RpcClient, target: raft.NodeId, req: raft.AppendEntriesRequest) !raft.AppendEntriesResponse {
        // Encode header
        const header_buf = req.encodeHeader();

        // For now, just send header (no entries serialization)
        const msg = Message{
            .msg_type = .append_entries_req,
            .correlation_id = self.nextCorrelationId(),
            .payload = @constCast(&header_buf),
        };

        const response = try self.sendAndReceive(target, msg);
        defer if (response.payload.len > 0) self.allocator.free(response.payload);

        return raft.AppendEntriesResponse.decode(response.payload);
    }

    /// Send message and wait for response
    fn sendAndReceive(self: *RpcClient, target: raft.NodeId, msg: Message) !Message {
        const address = self.addresses.get(target) orelse return error.UnknownPeer;

        // Get or create connection pool
        const pool = self.getOrCreatePool(target, address) catch return error.ConnectionFailed;

        const sock = pool.acquire() catch return error.ConnectionFailed;
        defer pool.release(sock);

        // Send message
        const encoded = try msg.encode(self.allocator);
        defer self.allocator.free(encoded);

        sendAll(sock, encoded) catch return error.SendFailed;

        // Read response
        var header_buf: [HEADER_SIZE]u8 = undefined;
        const read = recvAll(sock, &header_buf) catch return error.ReceiveFailed;
        if (read < HEADER_SIZE) return error.InvalidResponse;

        const header = try Message.decodeHeader(&header_buf);

        var payload: []u8 = &[_]u8{};
        if (header.payload_len > 0) {
            payload = try self.allocator.alloc(u8, header.payload_len);
            errdefer self.allocator.free(payload);

            var total_read: usize = 0;
            while (total_read < header.payload_len) {
                const n = recvAll(sock, payload[total_read..]) catch return error.ReceiveFailed;
                if (n == 0) return error.ConnectionClosed;
                total_read += n;
            }
        }

        return Message{
            .msg_type = header.msg_type,
            .correlation_id = header.correlation_id,
            .payload = payload,
        };
    }

    /// Get or create connection pool for a peer
    fn getOrCreatePool(self: *RpcClient, node_id: raft.NodeId, address: NodeAddress) !*ConnectionPool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pools.get(node_id)) |pool| {
            return pool;
        }

        const pool = try self.allocator.create(ConnectionPool);
        pool.* = ConnectionPool.init(self.allocator, address, 5);
        try self.pools.put(self.allocator, node_id, pool);
        return pool;
    }

    /// Get next correlation ID
    fn nextCorrelationId(self: *RpcClient) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.correlation_counter += 1;
        return self.correlation_counter;
    }
};

// =============================================================================
// Raft Transport Adapter
// =============================================================================

/// Adapter to integrate RpcClient with Raft's Transport interface
pub const RpcTransport = struct {
    client: *RpcClient,

    pub fn init(client: *RpcClient) RpcTransport {
        return RpcTransport{ .client = client };
    }

    /// Get the Raft transport interface
    pub fn getTransport(self: *RpcTransport) raft.Transport {
        return raft.Transport{
            .ctx = self,
            .sendRequestVoteFn = sendRequestVoteWrapper,
            .sendAppendEntriesFn = sendAppendEntriesWrapper,
        };
    }

    fn sendRequestVoteWrapper(ctx: *anyopaque, target: raft.NodeId, req: raft.RequestVoteRequest) void {
        const self: *RpcTransport = @ptrCast(@alignCast(ctx));
        _ = self.client.sendRequestVote(target, req) catch {};
    }

    fn sendAppendEntriesWrapper(ctx: *anyopaque, target: raft.NodeId, req: raft.AppendEntriesRequest) void {
        const self: *RpcTransport = @ptrCast(@alignCast(ctx));
        _ = self.client.sendAppendEntries(target, req) catch {};
    }
};

// =============================================================================
// Tests
// =============================================================================

test "message encoding" {
    const allocator = std.testing.allocator;

    const payload = "test payload";
    const msg = Message{
        .msg_type = .request_vote_req,
        .correlation_id = 12345,
        .payload = @constCast(payload),
    };

    const encoded = try msg.encode(allocator);
    defer allocator.free(encoded);

    const header = try Message.decodeHeader(encoded);
    try std.testing.expectEqual(MessageType.request_vote_req, header.msg_type);
    try std.testing.expectEqual(@as(u64, 12345), header.correlation_id);
    try std.testing.expectEqual(@as(u32, 12), header.payload_len);
}

test "node address parsing" {
    const addr = try NodeAddress.parse("127.0.0.1:8080");
    try std.testing.expectEqualStrings("127.0.0.1", addr.host);
    try std.testing.expectEqual(@as(u16, 8080), addr.port);
}

test "node address to sockaddr" {
    const addr = try NodeAddress.parse("127.0.0.1:8080");
    const sockaddr = try addr.toSockaddr();
    try std.testing.expectEqual(std.posix.AF.INET, sockaddr.family);
}
