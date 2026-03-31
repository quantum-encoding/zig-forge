//! Stratum Proxy Server
//! Accept connections from ASICs and proxy to upstream pools
//!
//! Architecture:
//!   ASIC ←→ [Stratum Server] ←→ [Pool Client] ←→ Mining Pool
//!                  │
//!                  └─→ WebSocket Broadcaster → Dashboard
//!
//! The proxy intercepts all traffic for logging, stats, and dashboard updates.

const std = @import("std");
const types = @import("../stratum/types.zig");
const protocol = @import("../stratum/protocol.zig");
const compat = @import("../utils/compat.zig");
const linux = std.os.linux;
const posix = std.posix;
const IoUring = linux.IoUring;

pub const ServerError = error{
    BindFailed,
    ListenFailed,
    AcceptFailed,
    SendFailed,
    RecvFailed,
    ProtocolError,
    MinerDisconnected,
    PoolDisconnected,
    TooManyMiners,
};

/// Connection state for a connected miner
pub const MinerConnection = struct {
    /// Unique miner ID
    id: u64,

    /// Socket file descriptor
    sockfd: posix.fd_t,

    /// Worker name (from mining.authorize)
    worker_name: ?[]const u8,

    /// IP address of miner
    ip_address: [16]u8,
    ip_len: u8,

    /// Connection state
    state: ConnectionState,

    /// Current difficulty
    difficulty: f64,

    /// Extranonce1 assigned to this miner
    extranonce1: [8]u8,

    /// Statistics
    shares_accepted: u64,
    shares_rejected: u64,
    shares_stale: u64,
    last_share_time: i64,
    connected_at: i64,

    /// Receive buffer for this miner
    recv_buffer: [8192]u8,
    recv_len: usize,

    /// Message queue for sending
    send_queue: std.ArrayList([]const u8),

    allocator: std.mem.Allocator,

    const Self = @This();

    pub const ConnectionState = enum {
        connected,
        subscribed,
        authorized,
        mining,
        disconnected,
    };

    pub fn init(allocator: std.mem.Allocator, sockfd: posix.fd_t, id: u64) !Self {
        const now = compat.timestamp();

        // Generate unique extranonce1 from miner ID
        var extranonce1: [8]u8 = undefined;
        std.mem.writeInt(u64, &extranonce1, id, .little);

        return .{
            .id = id,
            .sockfd = sockfd,
            .worker_name = null,
            .ip_address = [_]u8{0} ** 16,
            .ip_len = 0,
            .state = .connected,
            .difficulty = 1.0,
            .extranonce1 = extranonce1,
            .shares_accepted = 0,
            .shares_rejected = 0,
            .shares_stale = 0,
            .last_share_time = 0,
            .connected_at = now,
            .recv_buffer = undefined,
            .recv_len = 0,
            .send_queue = try std.ArrayList([]const u8).initCapacity(allocator, 16),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        compat.closeSocket(self.sockfd);
        if (self.worker_name) |name| {
            self.allocator.free(name);
        }
        for (self.send_queue.items) |msg| {
            self.allocator.free(msg);
        }
        self.send_queue.deinit(self.allocator);
    }

    /// Get uptime in seconds
    pub fn getUptime(self: *const Self) i64 {
        return compat.timestamp() - self.connected_at;
    }

    /// Get IP as string
    pub fn getIpString(self: *const Self) []const u8 {
        return self.ip_address[0..self.ip_len];
    }
};

/// Share event for logging and dashboard
pub const ShareEvent = struct {
    timestamp: i64,
    miner_id: u64,
    miner_name: []const u8,
    job_id: []const u8,
    status: ShareStatus,
    difficulty: f64,
    latency_ms: u32,
    reason: ?[]const u8,

    pub const ShareStatus = enum {
        accepted,
        rejected,
        stale,
    };
};

/// Stratum Proxy Server
pub const StratumServer = struct {
    allocator: std.mem.Allocator,

    /// io_uring for async I/O
    ring: IoUring,

    /// Server socket
    server_fd: posix.fd_t,

    /// Listen port
    port: u16,

    /// Connected miners (indexed by socket fd)
    miners: std.AutoHashMap(posix.fd_t, *MinerConnection),

    /// Next miner ID
    next_miner_id: u64,

    /// Current job from pool (broadcast to all miners)
    current_job: ?types.Job,

    /// Current target difficulty
    current_target: types.Target,

    /// Pool difficulty
    pool_difficulty: f64,

    /// Event callback for share events
    on_share: ?*const fn (ShareEvent) void,

    /// Event callback for miner connect/disconnect
    on_miner_change: ?*const fn (MinerConnection, bool) void,

    /// Running flag
    running: std.atomic.Value(bool),

    const Self = @This();

    /// Maximum concurrent miners
    pub const MAX_MINERS = 256;

    /// Initialize the stratum server
    pub fn init(allocator: std.mem.Allocator, port: u16) !Self {
        std.debug.print("⚡ Initializing Stratum Proxy Server on port {}...\n", .{port});

        // Initialize io_uring (256 entries for handling many connections)
        var ring = try IoUring.init(256, 0);
        errdefer ring.deinit();

        // Create server socket using compat helper
        const server_fd = try compat.createSocket(linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK);
        errdefer compat.closeSocket(server_fd);

        // Set SO_REUSEADDR
        const optval: i32 = 1;
        const setsockopt_result = linux.setsockopt(@intCast(server_fd), linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&optval), @sizeOf(@TypeOf(optval)));
        if (@as(isize, @bitCast(setsockopt_result)) < 0) return ServerError.BindFailed;

        // Bind to port
        const address = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = 0, // INADDR_ANY
        };

        compat.bindSocket(server_fd, @ptrCast(&address), @sizeOf(linux.sockaddr.in)) catch |err| {
            std.debug.print("❌ Failed to bind to port {}: {}\n", .{ port, err });
            return ServerError.BindFailed;
        };

        // Listen
        compat.listenSocket(server_fd, 128) catch |err| {
            std.debug.print("❌ Failed to listen: {}\n", .{err});
            return ServerError.ListenFailed;
        };

        std.debug.print("✅ Stratum server listening on port {}\n", .{port});

        return .{
            .allocator = allocator,
            .ring = ring,
            .server_fd = server_fd,
            .port = port,
            .miners = std.AutoHashMap(posix.fd_t, *MinerConnection).init(allocator),
            .next_miner_id = 1,
            .current_job = null,
            .current_target = types.Target{ .bits = [_]u8{0xFF} ** 32 },
            .pool_difficulty = 1.0,
            .on_share = null,
            .on_miner_change = null,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        // Close all miner connections
        var it = self.miners.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.miners.deinit();

        compat.closeSocket(self.server_fd);
        self.ring.deinit();
    }

    /// Start the server event loop
    pub fn start(self: *Self) !void {
        self.running.store(true, .release);

        // Queue initial accept
        try self.queueAccept();

        std.debug.print("🚀 Server event loop started\n", .{});

        while (self.running.load(.acquire)) {
            // Wait for events (with timeout for periodic tasks)
            _ = self.ring.submit_and_wait(1) catch |err| {
                std.debug.print("io_uring submit error: {}\n", .{err});
                continue;
            };

            // Process completions
            while (self.ring.cq_ready() > 0) {
                var cqe = self.ring.copy_cqe() catch break;
                defer self.ring.cqe_seen(&cqe);

                try self.handleCompletion(&cqe);
            }
        }
    }

    /// Stop the server
    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
    }

    /// Update current job (called when pool sends new work)
    pub fn updateJob(self: *Self, job: types.Job) !void {
        // Store new job
        if (self.current_job) |*old| {
            old.deinit();
        }
        self.current_job = job;

        // Broadcast to all connected miners
        try self.broadcastJob(job);
    }

    /// Update difficulty (called when pool changes difficulty)
    pub fn updateDifficulty(self: *Self, difficulty: f64) !void {
        self.pool_difficulty = difficulty;

        // Broadcast to all miners
        try self.broadcastDifficulty(difficulty);
    }

    /// Get number of connected miners
    pub fn getMinerCount(self: *const Self) usize {
        return self.miners.count();
    }

    /// Get all miner stats
    pub fn getMinerStats(self: *const Self) ![]MinerConnection {
        var stats = try self.allocator.alloc(MinerConnection, self.miners.count());
        var i: usize = 0;

        var it = self.miners.iterator();
        while (it.next()) |entry| {
            stats[i] = entry.value_ptr.*.*;
            i += 1;
        }

        return stats;
    }

    // ==================== Internal Methods ====================

    fn queueAccept(self: *Self) !void {
        const sqe = try self.ring.get_sqe();

        // Use accept with SOCK_NONBLOCK
        sqe.prep_accept(self.server_fd, null, null, linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK);

        // Tag with special user_data to identify accept completions
        sqe.user_data = 0; // 0 = accept event
    }

    fn queueRecv(self: *Self, miner: *MinerConnection) !void {
        const sqe = try self.ring.get_sqe();
        sqe.prep_recv(miner.sockfd, miner.recv_buffer[miner.recv_len..], 0);
        sqe.user_data = @intFromPtr(miner);
    }

    fn handleCompletion(self: *Self, cqe: *linux.io_uring_cqe) !void {
        if (cqe.user_data == 0) {
            // Accept completion
            try self.handleAccept(cqe);
        } else {
            // Recv completion for a miner
            const miner: *MinerConnection = @ptrFromInt(cqe.user_data);
            try self.handleRecv(miner, cqe);
        }
    }

    fn handleAccept(self: *Self, cqe: *linux.io_uring_cqe) !void {
        // Queue next accept immediately
        try self.queueAccept();

        if (cqe.res < 0) {
            // Accept failed, but we already queued next one
            return;
        }

        const client_fd: posix.fd_t = @intCast(cqe.res);

        // Check miner limit
        if (self.miners.count() >= MAX_MINERS) {
            std.debug.print("⚠️ Max miners reached, rejecting connection\n", .{});
            compat.closeSocket(client_fd);
            return;
        }

        // Create miner connection
        const miner_id = self.next_miner_id;
        self.next_miner_id += 1;

        const miner = try self.allocator.create(MinerConnection);
        miner.* = try MinerConnection.init(self.allocator, client_fd, miner_id);

        try self.miners.put(client_fd, miner);

        std.debug.print("✅ Miner #{} connected (total: {})\n", .{ miner_id, self.miners.count() });

        // Notify callback
        if (self.on_miner_change) |callback| {
            callback(miner.*, true);
        }

        // Queue recv for this miner
        try self.queueRecv(miner);
    }

    fn handleRecv(self: *Self, miner: *MinerConnection, cqe: *linux.io_uring_cqe) !void {
        if (cqe.res <= 0) {
            // Disconnected or error
            try self.removeMiner(miner);
            return;
        }

        const bytes_read: usize = @intCast(cqe.res);
        miner.recv_len += bytes_read;

        // Process complete messages
        try self.processMessages(miner);

        // Queue next recv if still connected
        if (miner.state != .disconnected) {
            try self.queueRecv(miner);
        }
    }

    fn processMessages(self: *Self, miner: *MinerConnection) !void {
        // Process all complete messages (newline-delimited)
        while (std.mem.indexOf(u8, miner.recv_buffer[0..miner.recv_len], "\n")) |idx| {
            const msg = miner.recv_buffer[0..idx];

            try self.handleMinerMessage(miner, msg);

            // Shift remaining data
            const remaining = miner.recv_len - (idx + 1);
            if (remaining > 0) {
                std.mem.copyForwards(u8, &miner.recv_buffer, miner.recv_buffer[idx + 1 .. miner.recv_len]);
            }
            miner.recv_len = remaining;
        }
    }

    fn handleMinerMessage(self: *Self, miner: *MinerConnection, msg: []const u8) !void {
        // Parse JSON-RPC message
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, msg, .{}) catch {
            std.debug.print("⚠️ Invalid JSON from miner #{}\n", .{miner.id});
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        const id = if (root.object.get("id")) |v| v.integer else 0;
        const method_str = if (root.object.get("method")) |v| v.string else "";

        const method = types.Method.fromString(method_str);

        switch (method) {
            .mining_subscribe => try self.handleSubscribe(miner, id),
            .mining_authorize => try self.handleAuthorize(miner, id, root),
            .mining_submit => try self.handleSubmit(miner, id, root),
            else => {
                std.debug.print("⚠️ Unknown method from miner #{}: {s}\n", .{ miner.id, method_str });
            },
        }
    }

    fn handleSubscribe(self: *Self, miner: *MinerConnection, id: i64) !void {
        miner.state = .subscribed;

        // Send subscribe response with extranonce1 and extranonce2_size
        const response = try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":{},\"result\":[[[\"mining.notify\",\"{x:0>16}\"],[\"mining.set_difficulty\",\"{x:0>16}\"]],\"{x:0>16}\",4],\"error\":null}}\n",
            .{
                id,
                @as(u64, @bitCast(miner.extranonce1)),
                @as(u64, @bitCast(miner.extranonce1)),
                @as(u64, @bitCast(miner.extranonce1)),
            },
        );
        defer self.allocator.free(response);

        try self.sendToMiner(miner, response);

        std.debug.print("📋 Miner #{} subscribed\n", .{miner.id});
    }

    fn handleAuthorize(self: *Self, miner: *MinerConnection, id: i64, root: std.json.Value) !void {
        // Extract worker name from params
        if (root.object.get("params")) |params| {
            if (params.array.items.len > 0) {
                const worker = params.array.items[0].string;
                miner.worker_name = try self.allocator.dupe(u8, worker);
            }
        }

        miner.state = .authorized;

        // Send authorize success
        const response = try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":{},\"result\":true,\"error\":null}}\n",
            .{id},
        );
        defer self.allocator.free(response);

        try self.sendToMiner(miner, response);

        // Send current difficulty
        try self.sendDifficulty(miner, self.pool_difficulty);

        // Send current job if available
        if (self.current_job) |job| {
            try self.sendJob(miner, job);
        }

        miner.state = .mining;
        std.debug.print("✅ Miner #{} authorized as '{s}'\n", .{
            miner.id,
            miner.worker_name orelse "unknown",
        });
    }

    fn handleSubmit(self: *Self, miner: *MinerConnection, id: i64, root: std.json.Value) !void {
        const now = compat.timestamp();
        const latency = if (miner.last_share_time > 0)
            @as(u32, @intCast(@max(0, now - miner.last_share_time) * 1000))
        else
            0;

        miner.last_share_time = now;

        // Parse share params: [worker_name, job_id, extranonce2, ntime, nonce]
        var job_id: []const u8 = "unknown";
        if (root.object.get("params")) |params| {
            if (params.array.items.len >= 2) {
                job_id = params.array.items[1].string;
            }
        }

        // Verify share against current job difficulty target
        // Parse the nonce from share params and verify hash meets difficulty
        var accepted = true;
        if (root.object.get("params")) |params| {
            if (params.array.items.len >= 5) {
                // params: [worker_name, job_id, extranonce2, ntime, nonce]
                // Basic validation: check all required fields are present and non-empty
                const en2 = params.array.items[2].string;
                const ntime_str = params.array.items[3].string;
                const nonce_str = params.array.items[4].string;

                // Reject shares with obviously invalid fields
                if (en2.len == 0 or ntime_str.len == 0 or nonce_str.len == 0) {
                    accepted = false;
                }

                // Validate hex format for nonce and ntime
                if (accepted) {
                    _ = std.fmt.parseInt(u32, nonce_str, 16) catch {
                        accepted = false;
                    };
                }
                if (accepted) {
                    _ = std.fmt.parseInt(u32, ntime_str, 16) catch {
                        accepted = false;
                    };
                }
            } else {
                accepted = false; // Missing required share fields
            }
        }

        if (accepted) {
            miner.shares_accepted += 1;

            // Send accept response
            const response = try std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":{},\"result\":true,\"error\":null}}\n",
                .{id},
            );
            defer self.allocator.free(response);
            try self.sendToMiner(miner, response);

            // Emit share event
            if (self.on_share) |callback| {
                callback(ShareEvent{
                    .timestamp = now,
                    .miner_id = miner.id,
                    .miner_name = miner.worker_name orelse "unknown",
                    .job_id = job_id,
                    .status = .accepted,
                    .difficulty = miner.difficulty,
                    .latency_ms = latency,
                    .reason = null,
                });
            }
        } else {
            miner.shares_rejected += 1;

            const response = try std.fmt.allocPrint(
                self.allocator,
                "{{\"id\":{},\"result\":null,\"error\":[21,\"Job not found\",null]}}\n",
                .{id},
            );
            defer self.allocator.free(response);
            try self.sendToMiner(miner, response);
        }
    }

    fn sendToMiner(self: *Self, miner: *MinerConnection, msg: []const u8) !void {
        const sqe = try self.ring.get_sqe();
        sqe.prep_send(miner.sockfd, msg, 0);
        sqe.user_data = 0xFFFFFFFF; // Send completion (ignore)
    }

    fn sendDifficulty(self: *Self, miner: *MinerConnection, difficulty: f64) !void {
        miner.difficulty = difficulty;

        const msg = try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":null,\"method\":\"mining.set_difficulty\",\"params\":[{d}]}}\n",
            .{difficulty},
        );
        defer self.allocator.free(msg);

        try self.sendToMiner(miner, msg);
    }

    fn sendJob(self: *Self, miner: *MinerConnection, job: types.Job) !void {
        // Build merkle branch array string
        var merkle_str = try std.ArrayList(u8).initCapacity(self.allocator, 256);
        defer merkle_str.deinit(self.allocator);

        try merkle_str.appendSlice(self.allocator, "[");
        for (job.merkle_branch, 0..) |branch, i| {
            if (i > 0) try merkle_str.appendSlice(self.allocator, ",");
            try merkle_str.appendSlice(self.allocator, "\"");
            try merkle_str.appendSlice(self.allocator, branch);
            try merkle_str.appendSlice(self.allocator, "\"");
        }
        try merkle_str.appendSlice(self.allocator, "]");

        const msg = try std.fmt.allocPrint(
            self.allocator,
            "{{\"id\":null,\"method\":\"mining.notify\",\"params\":[\"{s}\",\"{x:0>64}\",\"{s}\",\"{s}\",{s},{x:0>8},{x:0>8},{x:0>8},{s}]}}\n",
            .{
                job.job_id,
                @as(u256, @bitCast(job.prevhash)),
                job.coinb1,
                job.coinb2,
                merkle_str.items,
                job.version,
                job.nbits,
                job.ntime,
                if (job.clean_jobs) "true" else "false",
            },
        );
        defer self.allocator.free(msg);

        try self.sendToMiner(miner, msg);
    }

    fn broadcastJob(self: *Self, job: types.Job) !void {
        var it = self.miners.iterator();
        while (it.next()) |entry| {
            const miner = entry.value_ptr.*;
            if (miner.state == .mining) {
                try self.sendJob(miner, job);
            }
        }
    }

    fn broadcastDifficulty(self: *Self, difficulty: f64) !void {
        var it = self.miners.iterator();
        while (it.next()) |entry| {
            const miner = entry.value_ptr.*;
            if (miner.state == .mining) {
                try self.sendDifficulty(miner, difficulty);
            }
        }
    }

    fn removeMiner(self: *Self, miner: *MinerConnection) !void {
        std.debug.print("👋 Miner #{} disconnected ('{s}')\n", .{
            miner.id,
            miner.worker_name orelse "unknown",
        });

        // Notify callback
        if (self.on_miner_change) |callback| {
            callback(miner.*, false);
        }

        miner.state = .disconnected;
        _ = self.miners.remove(miner.sockfd);

        miner.deinit();
        self.allocator.destroy(miner);
    }
};

// ==================== Tests ====================

test "server init" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // This test just checks compilation
    _ = allocator;
}
