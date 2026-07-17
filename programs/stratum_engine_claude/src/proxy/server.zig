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

/// Sanitize a miner-supplied `mining.authorize` worker name on ingress.
///
/// Defense-in-depth alongside the JSON-safe std.json.Stringify serialization
/// downstream (dashboard broadcaster, share events): drop control characters,
/// DEL, and non-ASCII bytes so a hostile worker name can't smuggle newlines
/// into log lines, NULs into any C-string sink, or raw control bytes into a
/// terminal, and cap the length so an unauthenticated peer can't force an
/// unbounded per-connection allocation. Any residual `"`/`\` in the surviving
/// printable-ASCII range is still escaped by std.json.Stringify at every
/// serialization site. Caller owns the returned slice.
fn sanitizeWorkerName(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const max_len = 128;
    const cap = @min(raw.len, max_len);
    var buf = try allocator.alloc(u8, cap);
    errdefer allocator.free(buf);

    var n: usize = 0;
    for (raw) |c| {
        if (n >= max_len) break;
        // Keep only printable ASCII (0x20 space .. 0x7E '~'); drop
        // C0 controls, DEL (0x7F), and any high/non-ASCII byte.
        if (c >= 0x20 and c < 0x7f) {
            buf[n] = c;
            n += 1;
        }
    }

    // Shrink the allocation to exactly the sanitized length.
    if (n != buf.len) buf = try allocator.realloc(buf, n);
    return buf;
}

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

        // Send subscribe response with extranonce1 and extranonce2_size.
        // The Stratum mining.subscribe response shape is a
        // heterogeneous array:
        //   "result": [
        //     [["mining.notify", "<en1>"], ["mining.set_difficulty", "<en1>"]],
        //     "<en1>",
        //     <en2_size>
        //   ]
        // Streaming std.json.Stringify is cleaner here than
        // valueAlloc on a struct — there's no clean Zig type for
        // an array-of-mixed-types.
        var en1_hex: [16]u8 = undefined;
        _ = try std.fmt.bufPrint(&en1_hex, "{x:0>16}", .{@as(u64, @bitCast(miner.extranonce1))});

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(id);
        try jw.objectField("result");
        try jw.beginArray();
        try jw.beginArray(); // subscriptions
        try jw.beginArray();
        try jw.write("mining.notify");
        try jw.write(@as([]const u8, &en1_hex));
        try jw.endArray();
        try jw.beginArray();
        try jw.write("mining.set_difficulty");
        try jw.write(@as([]const u8, &en1_hex));
        try jw.endArray();
        try jw.endArray();
        try jw.write(@as([]const u8, &en1_hex)); // extranonce1
        try jw.write(@as(u32, 4)); // extranonce2_size
        try jw.endArray();
        try jw.objectField("error");
        try jw.write(null);
        try jw.endObject();
        // Stratum is line-delimited.
        try aw.writer.writeByte('\n');

        const response = try aw.toOwnedSlice();
        defer self.allocator.free(response);

        try self.sendToMiner(miner, response);

        std.debug.print("📋 Miner #{} subscribed\n", .{miner.id});
    }

    fn handleAuthorize(self: *Self, miner: *MinerConnection, id: i64, root: std.json.Value) !void {
        // Extract worker name from params
        if (root.object.get("params")) |params| {
            if (params.array.items.len > 0) {
                const worker = params.array.items[0].string;
                miner.worker_name = try sanitizeWorkerName(self.allocator, worker);
            }
        }

        miner.state = .authorized;

        // Send authorize success. Audit (JSON-IN-FMT): straight
        // shape `{"id":N,"result":true,"error":null}` — through
        // std.json.Stringify on an anonymous struct, then append
        // the Stratum line terminator.
        const body = try std.json.Stringify.valueAlloc(self.allocator, .{
            .id = id,
            .result = true,
            .@"error" = null,
        }, .{});
        defer self.allocator.free(body);
        const response = try std.fmt.allocPrint(self.allocator, "{s}\n", .{body});
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

            // Send accept response.
            const body = try std.json.Stringify.valueAlloc(self.allocator, .{
                .id = id,
                .result = true,
                .@"error" = null,
            }, .{});
            defer self.allocator.free(body);
            const response = try std.fmt.allocPrint(self.allocator, "{s}\n", .{body});
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

            // Stratum protocol reject — error tuple is
            // [code, message, data]; we emit [21, "Job not found", null].
            const body = try std.json.Stringify.valueAlloc(self.allocator, .{
                .id = id,
                .result = null,
                .@"error" = .{ @as(u32, 21), "Job not found", null },
            }, .{});
            defer self.allocator.free(body);
            const response = try std.fmt.allocPrint(self.allocator, "{s}\n", .{body});
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

        // {"id":null,"method":"mining.set_difficulty","params":[<difficulty>]}
        const body = try std.json.Stringify.valueAlloc(self.allocator, .{
            .id = null,
            .method = "mining.set_difficulty",
            .params = .{difficulty},
        }, .{});
        defer self.allocator.free(body);
        const msg = try std.fmt.allocPrint(self.allocator, "{s}\n", .{body});
        defer self.allocator.free(msg);

        try self.sendToMiner(miner, msg);
    }

    fn sendJob(self: *Self, miner: *MinerConnection, job: types.Job) !void {
        // Stratum mining.notify body shape:
        //   "params": [
        //     "<job_id>", "<prevhash hex>", "<coinb1>", "<coinb2>",
        //     ["<merkle1>", "<merkle2>", ...],
        //     "<version hex>", "<nbits hex>", "<ntime hex>",
        //     <clean_jobs bool>
        //   ]
        //
        // Audit (JSON-IN-FMT): the previous implementation built
        // the merkle sub-array by hand (string-append "[", quoted
        // branches, "]") then interpolated it AS A STRING into the
        // outer params allocPrint. Pool-provided strings (coinb1,
        // coinb2, merkle branches) ended up unescaped in the wire
        // bytes. We now stream the full structure through
        // std.json.Stringify, with prevhash / version / nbits /
        // ntime pre-formatted into stack-allocated hex buffers
        // (the wire contract requires the specific hex widths;
        // Stringify's number formatter won't emit those).
        var prevhash_hex: [64]u8 = undefined;
        _ = try std.fmt.bufPrint(&prevhash_hex, "{x:0>64}", .{@as(u256, @bitCast(job.prevhash))});
        var version_hex: [8]u8 = undefined;
        _ = try std.fmt.bufPrint(&version_hex, "{x:0>8}", .{job.version});
        var nbits_hex: [8]u8 = undefined;
        _ = try std.fmt.bufPrint(&nbits_hex, "{x:0>8}", .{job.nbits});
        var ntime_hex: [8]u8 = undefined;
        _ = try std.fmt.bufPrint(&ntime_hex, "{x:0>8}", .{job.ntime});

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(null);
        try jw.objectField("method");
        try jw.write("mining.notify");
        try jw.objectField("params");
        try jw.beginArray();
        try jw.write(job.job_id);
        try jw.write(@as([]const u8, &prevhash_hex));
        try jw.write(job.coinb1);
        try jw.write(job.coinb2);
        try jw.beginArray();
        for (job.merkle_branch) |branch| try jw.write(branch);
        try jw.endArray();
        try jw.write(@as([]const u8, &version_hex));
        try jw.write(@as([]const u8, &nbits_hex));
        try jw.write(@as([]const u8, &ntime_hex));
        try jw.write(job.clean_jobs);
        try jw.endArray();
        try jw.endObject();
        try aw.writer.writeByte('\n');

        const msg = try aw.toOwnedSlice();
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
