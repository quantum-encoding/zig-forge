//! Distributed Key-Value Store Library
//!
//! A production-ready distributed KV store built on Raft consensus:
//!
//! Features:
//! - Raft-based consensus for strong consistency
//! - Persistent WAL with crash recovery
//! - TTL support for key expiration
//! - Compare-and-swap operations
//! - Watch/subscribe for key changes
//! - Connection pooling and automatic failover
//!
//! Architecture:
//!   ┌─────────┐     ┌─────────┐     ┌─────────┐
//!   │ Client  │────▶│  Leader │────▶│ Follower│
//!   └─────────┘     └────┬────┘     └─────────┘
//!                        │
//!                        ▼
//!                   ┌─────────┐
//!                   │Follower │
//!                   └─────────┘
//!
//! Each node contains:
//!   - Raft consensus module (leader election, log replication)
//!   - WAL for durability
//!   - KV state machine
//!   - RPC server/client for cluster communication

const std = @import("std");
const linux = std.os.linux;

// Re-export modules
pub const raft = @import("raft.zig");
pub const wal = @import("wal.zig");
pub const kv = @import("kv.zig");
pub const rpc = @import("rpc.zig");
pub const client = @import("client.zig");

// Re-export key types for convenience
pub const RaftNode = raft.RaftNode;
pub const ClusterConfig = raft.ClusterConfig;
pub const NodeId = raft.NodeId;
pub const Term = raft.Term;
pub const LogIndex = raft.LogIndex;
pub const State = raft.State;
pub const CommandType = raft.CommandType;
pub const LogEntry = raft.LogEntry;

pub const WalWriter = wal.WalWriter;
pub const WalReader = wal.WalReader;
pub const RecoveredState = wal.RecoveredState;

pub const KVStore = kv.KVStore;
pub const SetCommand = kv.SetCommand;
pub const DeleteCommand = kv.DeleteCommand;
pub const CasCommand = kv.CasCommand;

pub const RpcServer = rpc.RpcServer;
pub const RpcClient = rpc.RpcClient;
pub const RpcTransport = rpc.RpcTransport;
pub const NodeAddress = rpc.NodeAddress;

pub const Client = client.Client;
pub const ClientConfig = client.ClientConfig;
pub const ClientError = client.ClientError;

// =============================================================================
// Node Configuration
// =============================================================================

/// Complete node configuration
pub const NodeConfig = struct {
    /// Unique node ID
    node_id: NodeId,
    /// RPC listen port
    port: u16,
    /// Data directory for WAL
    data_dir: []const u8,
    /// Peer addresses (node_id -> host:port)
    peers: []const PeerConfig,
    /// Cluster node IDs
    cluster_nodes: []const NodeId,

    pub const PeerConfig = struct {
        node_id: NodeId,
        address: []const u8,
    };
};

// =============================================================================
// Distributed Node
// =============================================================================

/// A complete distributed KV node
pub const DistributedNode = struct {
    allocator: std.mem.Allocator,
    config: NodeConfig,

    // Core components
    raft_node: RaftNode,
    kv_store: KVStore,
    wal_writer: ?WalWriter,
    rpc_server: RpcServer,
    rpc_client: RpcClient,
    rpc_transport: RpcTransport,

    // Runtime state
    running: std.atomic.Value(bool),
    tick_thread: ?std.Thread,
    server_thread: ?std.Thread,

    pub fn init(allocator: std.mem.Allocator, config: NodeConfig) !*DistributedNode {
        var node = try allocator.create(DistributedNode);
        errdefer allocator.destroy(node);

        // Initialize cluster config
        const cluster_config = ClusterConfig{
            .nodes = config.cluster_nodes,
        };

        // Initialize components
        node.allocator = allocator;
        node.config = config;
        node.raft_node = RaftNode.init(allocator, config.node_id, cluster_config);
        node.kv_store = KVStore.init(allocator);
        node.wal_writer = null;
        node.rpc_server = RpcServer.init(allocator, config.port);
        node.rpc_client = RpcClient.init(allocator);
        node.rpc_transport = RpcTransport.init(&node.rpc_client);
        node.running = std.atomic.Value(bool).init(false);
        node.tick_thread = null;
        node.server_thread = null;

        // Setup WAL
        if (config.data_dir.len > 0) {
            node.wal_writer = WalWriter.init(allocator, config.data_dir, config.node_id) catch null;
            if (node.wal_writer) |*w| {
                node.raft_node.setWal(w);
            }
        }

        // Setup state machine
        var sm = node.kv_store.getStateMachine();
        node.raft_node.setStateMachine(&sm);

        // Setup transport
        var transport = node.rpc_transport.getTransport();
        node.raft_node.setTransport(&transport);

        // Register peers
        for (config.peers) |peer| {
            const addr = NodeAddress.parse(peer.address) catch continue;
            node.rpc_client.addPeer(peer.node_id, addr) catch {};
        }

        // Setup RPC server
        node.rpc_server.setRaftNode(&node.raft_node);

        return node;
    }

    pub fn deinit(self: *DistributedNode) void {
        self.stop();

        self.raft_node.deinit();
        self.kv_store.deinit();
        if (self.wal_writer) |*w| {
            w.deinit();
        }
        self.rpc_server.deinit();
        self.rpc_client.deinit();

        self.allocator.destroy(self);
    }

    /// Start the node
    pub fn start(self: *DistributedNode) !void {
        if (self.running.load(.acquire)) return;

        // Recover from WAL
        if (self.config.data_dir.len > 0) {
            var recovered = wal.recover(self.allocator, self.config.data_dir) catch |err| {
                std.log.warn("WAL recovery failed: {}", .{err});
                return;
            };
            defer recovered.deinit(self.allocator);

            // Apply recovered state
            self.raft_node.current_term = recovered.current_term;
            self.raft_node.voted_for = recovered.voted_for;

            for (recovered.log_entries.items) |entry| {
                self.raft_node.log.append(self.allocator, entry) catch {};
            }
        }

        self.running.store(true, .release);

        // Start RPC server
        try self.rpc_server.start();

        // Start tick thread
        self.tick_thread = try std.Thread.spawn(.{}, tickLoop, .{self});

        // Start server accept thread
        self.server_thread = try std.Thread.spawn(.{}, serverLoop, .{self});
    }

    /// Stop the node
    pub fn stop(self: *DistributedNode) void {
        self.running.store(false, .release);
        self.rpc_server.stop();

        if (self.tick_thread) |t| {
            t.join();
            self.tick_thread = null;
        }
        if (self.server_thread) |t| {
            t.join();
            self.server_thread = null;
        }
    }

    /// Check if this node is the leader
    pub fn isLeader(self: *DistributedNode) bool {
        return self.raft_node.isLeader();
    }

    /// Get current state
    pub fn getState(self: *DistributedNode) State {
        return self.raft_node.getState();
    }

    /// Execute a get operation (can be served by any node)
    pub fn get(self: *DistributedNode, key: []const u8) ?[]const u8 {
        return self.kv_store.get(key);
    }

    /// Execute a set operation (leader only)
    pub fn set(self: *DistributedNode, key: []const u8, value: []const u8, ttl_ms: ?u64) !void {
        if (!self.isLeader()) return error.NotLeader;

        const cmd = SetCommand{
            .key = key,
            .value = value,
            .ttl_ms = ttl_ms,
        };

        const encoded = try cmd.encode(self.allocator);
        defer self.allocator.free(encoded);

        _ = try self.raft_node.submit(.set, encoded);
    }

    /// Execute a delete operation (leader only)
    pub fn delete(self: *DistributedNode, key: []const u8) !void {
        if (!self.isLeader()) return error.NotLeader;

        const cmd = DeleteCommand{ .key = key };
        const encoded = try cmd.encode(self.allocator);
        defer self.allocator.free(encoded);

        _ = try self.raft_node.submit(.delete, encoded);
    }

    fn tickLoop(self: *DistributedNode) void {
        while (self.running.load(.acquire)) {
            self.raft_node.tick() catch {};
            var ts: linux.timespec = .{ .sec = 0, .nsec = 10_000_000 }; // 10ms tick interval
            _ = linux.nanosleep(&ts, null);
        }
    }

    fn serverLoop(self: *DistributedNode) void {
        while (self.running.load(.acquire)) {
            self.rpc_server.acceptOne() catch {};
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "library imports" {
    // Verify all modules can be imported
    _ = raft;
    _ = wal;
    _ = kv;
    _ = rpc;
    _ = client;
}

test "raft node basic" {
    const allocator = std.testing.allocator;

    const nodes = [_]NodeId{ 1, 2, 3 };
    const config = ClusterConfig{ .nodes = &nodes };

    var node = RaftNode.init(allocator, 1, config);
    defer node.deinit();

    try std.testing.expectEqual(State.follower, node.state);
}

test "kv store basic" {
    const allocator = std.testing.allocator;

    var store = KVStore.init(allocator);
    defer store.deinit();

    try store.applySet("key1", "value1", null);
    try std.testing.expectEqualStrings("value1", store.get("key1").?);
}
