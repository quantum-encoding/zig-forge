//! WebSocket Broadcaster for Dashboard
//!
//! Pushes real-time mining events to connected dashboard clients:
//! - Share submissions (accepted/rejected/stale)
//! - Miner status changes (online/offline/hashrate)
//! - Fleet statistics (every 10s)
//! - Alerts (hashrate drops, offline miners)
//!
//! Uses lock-free queue for event collection from multiple threads.

const std = @import("std");
const server = @import("server.zig");
const miner_registry = @import("miner_registry.zig");
const compat = @import("../utils/compat.zig");
const linux = std.os.linux;
const posix = std.posix;
const IoUring = linux.IoUring;

pub const BroadcasterError = error{
    BindFailed,
    AcceptFailed,
    SendFailed,
    HandshakeFailed,
    QueueFull,
    ClientDisconnected,
};

/// WebSocket event types
pub const EventType = enum {
    share,
    miner_status,
    stats,
    alert,
    pool_status,
};

/// Event payload for the queue
pub const Event = struct {
    event_type: EventType,
    timestamp: i64,
    payload: Payload,

    pub const Payload = union(EventType) {
        share: SharePayload,
        miner_status: MinerStatusPayload,
        stats: StatsPayload,
        alert: AlertPayload,
        pool_status: PoolStatusPayload,
    };

    pub const SharePayload = struct {
        miner_id: u64,
        miner_name: [64]u8,
        miner_name_len: u8,
        status: server.ShareEvent.ShareStatus,
        difficulty: f64,
        latency_ms: u32,
        job_id: [32]u8,
        job_id_len: u8,
    };

    pub const MinerStatusPayload = struct {
        miner_id: u64,
        miner_name: [64]u8,
        miner_name_len: u8,
        status: miner_registry.MinerInfo.MinerStatus,
        hashrate_th: f64,
        temperature: i16, // -1 if unavailable
        power_watts: u32,
    };

    pub const StatsPayload = struct {
        total_hashrate_th: f64,
        total_miners: u32,
        online_miners: u32,
        accepted_24h: u64,
        rejected_24h: u64,
        btc_earned_24h: f64,
        avg_latency_ms: f64,
        accept_rate: f64,
    };

    pub const AlertPayload = struct {
        severity: miner_registry.Alert.Severity,
        miner_id: ?u64,
        message: [256]u8,
        message_len: u16,
    };

    pub const PoolStatusPayload = struct {
        pool_id: [32]u8,
        pool_id_len: u8,
        pool_name: [64]u8,
        pool_name_len: u8,
        connected: bool,
        latency_ms: u32,
        miners_count: u32,
    };
};

/// Lock-free event queue slot
const EventSlot = struct {
    turn: std.atomic.Value(usize) align(64),
    data: Event,

    fn init(initial_turn: usize) EventSlot {
        return .{
            .turn = std.atomic.Value(usize).init(initial_turn),
            .data = undefined,
        };
    }
};

/// Lock-free MPMC event queue (based on Vyukov's algorithm)
pub const EventQueue = struct {
    slots: []EventSlot,
    capacity: usize,
    mask: usize,
    head: std.atomic.Value(usize) align(64),
    _pad1: [56]u8 = undefined,
    tail: std.atomic.Value(usize) align(64),
    _pad2: [56]u8 = undefined,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
        if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
            return error.CapacityMustBePowerOfTwo;
        }

        const slots = try allocator.alloc(EventSlot, capacity);
        for (slots, 0..) |*slot, i| {
            slot.* = EventSlot.init(i);
        }

        return Self{
            .slots = slots,
            .capacity = capacity,
            .mask = capacity - 1,
            .head = std.atomic.Value(usize).init(0),
            .tail = std.atomic.Value(usize).init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.slots);
    }

    pub fn push(self: *Self, event: Event) !void {
        var backoff: usize = 1;

        while (true) {
            const tail = self.tail.load(.monotonic);
            const slot = &self.slots[tail & self.mask];
            const turn = slot.turn.load(.acquire);

            if (turn == tail) {
                if (self.tail.cmpxchgWeak(tail, tail + 1, .monotonic, .monotonic) == null) {
                    slot.data = event;
                    slot.turn.store(tail + 1, .release);
                    return;
                }
            } else if (turn < tail) {
                return BroadcasterError.QueueFull;
            }

            if (backoff < 64) {
                var i: usize = 0;
                while (i < backoff) : (i += 1) {
                    std.atomic.spinLoopHint();
                }
                backoff *= 2;
            }
        }
    }

    pub fn pop(self: *Self) ?Event {
        var backoff: usize = 1;

        while (true) {
            const head = self.head.load(.monotonic);
            const slot = &self.slots[head & self.mask];
            const turn = slot.turn.load(.acquire);

            if (turn == head + 1) {
                if (self.head.cmpxchgWeak(head, head + 1, .monotonic, .monotonic) == null) {
                    const data = slot.data;
                    slot.turn.store(head + self.capacity, .release);
                    return data;
                }
            } else if (turn < head + 1) {
                return null; // Empty
            }

            if (backoff < 64) {
                var i: usize = 0;
                while (i < backoff) : (i += 1) {
                    std.atomic.spinLoopHint();
                }
                backoff *= 2;
            }
        }
    }
};

/// Connected WebSocket client
pub const WsClient = struct {
    fd: posix.fd_t,
    connected: bool,
    handshake_complete: bool,
    recv_buffer: [4096]u8,
    recv_len: usize,
    subscriptions: Subscriptions,

    pub const Subscriptions = struct {
        shares: bool = true,
        miner_status: bool = true,
        stats: bool = true,
        alerts: bool = true,
    };
};

/// WebSocket Broadcaster
pub const WebSocketBroadcaster = struct {
    allocator: std.mem.Allocator,

    /// io_uring for async I/O
    ring: IoUring,

    /// Server socket
    server_fd: posix.fd_t,

    /// Listen port
    port: u16,

    /// Connected clients
    clients: std.AutoHashMap(posix.fd_t, *WsClient),

    /// Event queue (producers: mining threads, consumer: broadcast thread)
    event_queue: EventQueue,

    /// Stats update interval
    stats_interval_ms: u32,
    last_stats_time: i64,

    /// Running flag
    running: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, port: u16) !Self {
        std.debug.print("🌐 Initializing WebSocket broadcaster on port {}...\n", .{port});

        var ring = try IoUring.init(64, 0);
        errdefer ring.deinit();

        const server_fd = try compat.createSocket(linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK);
        errdefer compat.closeSocket(server_fd);

        const optval: i32 = 1;
        const setsockopt_result = linux.setsockopt(@intCast(server_fd), linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&optval), @sizeOf(@TypeOf(optval)));
        if (@as(isize, @bitCast(setsockopt_result)) < 0) return BroadcasterError.BindFailed;

        const address = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = 0,
        };

        compat.bindSocket(server_fd, @ptrCast(&address), @sizeOf(linux.sockaddr.in)) catch {
            return BroadcasterError.BindFailed;
        };

        compat.listenSocket(server_fd, 32) catch {
            return BroadcasterError.BindFailed;
        };

        std.debug.print("✅ WebSocket server listening on ws://localhost:{}\n", .{port});

        return Self{
            .allocator = allocator,
            .ring = ring,
            .server_fd = server_fd,
            .port = port,
            .clients = std.AutoHashMap(posix.fd_t, *WsClient).init(allocator),
            .event_queue = try EventQueue.init(allocator, 1024),
            .stats_interval_ms = 10000,
            .last_stats_time = 0,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        var it = self.clients.iterator();
        while (it.next()) |entry| {
            compat.closeSocket(entry.value_ptr.*.fd);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.clients.deinit();

        self.event_queue.deinit();
        compat.closeSocket(self.server_fd);
        self.ring.deinit();
    }

    /// Queue a share event for broadcast
    pub fn sendShareEvent(self: *Self, share_event: server.ShareEvent) void {
        var payload = Event.SharePayload{
            .miner_id = share_event.miner_id,
            .miner_name = [_]u8{0} ** 64,
            .miner_name_len = 0,
            .status = share_event.status,
            .difficulty = share_event.difficulty,
            .latency_ms = share_event.latency_ms,
            .job_id = [_]u8{0} ** 32,
            .job_id_len = 0,
        };

        // Copy miner name
        const name_len = @min(share_event.miner_name.len, 64);
        @memcpy(payload.miner_name[0..name_len], share_event.miner_name[0..name_len]);
        payload.miner_name_len = @intCast(name_len);

        // Copy job ID
        const job_len = @min(share_event.job_id.len, 32);
        @memcpy(payload.job_id[0..job_len], share_event.job_id[0..job_len]);
        payload.job_id_len = @intCast(job_len);

        self.event_queue.push(.{
            .event_type = .share,
            .timestamp = share_event.timestamp,
            .payload = .{ .share = payload },
        }) catch {
            // Queue full, drop event
        };
    }

    /// Queue a miner status event
    pub fn sendMinerStatus(self: *Self, miner: miner_registry.MinerInfo) void {
        var payload = Event.MinerStatusPayload{
            .miner_id = miner.id,
            .miner_name = [_]u8{0} ** 64,
            .miner_name_len = 0,
            .status = miner.status,
            .hashrate_th = miner.current_hashrate_th,
            .temperature = -1,
            .power_watts = miner.estimated_power_watts,
        };

        const name_len = @min(miner.name.len, 64);
        @memcpy(payload.miner_name[0..name_len], miner.name[0..name_len]);
        payload.miner_name_len = @intCast(name_len);

        self.event_queue.push(.{
            .event_type = .miner_status,
            .timestamp = compat.timestamp(),
            .payload = .{ .miner_status = payload },
        }) catch {};
    }

    /// Queue fleet stats update
    pub fn sendStats(self: *Self, stats: miner_registry.FleetStats) void {
        self.event_queue.push(.{
            .event_type = .stats,
            .timestamp = compat.timestamp(),
            .payload = .{
                .stats = .{
                    .total_hashrate_th = stats.total_hashrate_th,
                    .total_miners = stats.total_miners,
                    .online_miners = stats.online_miners,
                    .accepted_24h = stats.total_accepted,
                    .rejected_24h = stats.total_rejected,
                    .btc_earned_24h = stats.btc_earned_24h,
                    .avg_latency_ms = stats.avg_share_latency_ms,
                    .accept_rate = stats.fleet_accept_rate,
                },
            },
        }) catch {};
    }

    /// Queue an alert
    pub fn sendAlert(self: *Self, alert: miner_registry.Alert) void {
        var payload = Event.AlertPayload{
            .severity = alert.severity,
            .miner_id = alert.miner_id,
            .message = [_]u8{0} ** 256,
            .message_len = 0,
        };

        const msg_len = @min(alert.message.len, 256);
        @memcpy(payload.message[0..msg_len], alert.message[0..msg_len]);
        payload.message_len = @intCast(msg_len);

        self.event_queue.push(.{
            .event_type = .alert,
            .timestamp = alert.timestamp,
            .payload = .{ .alert = payload },
        }) catch {};
    }

    /// Start the broadcaster (run in separate thread)
    pub fn start(self: *Self) !void {
        self.running.store(true, .release);

        // Queue initial accept
        try self.queueAccept();

        while (self.running.load(.acquire)) {
            // Process events from queue and broadcast
            self.processEventQueue();

            // Handle WebSocket I/O
            _ = self.ring.submit_and_wait(1) catch continue;

            while (self.ring.cq_ready() > 0) {
                var cqe = self.ring.copy_cqe() catch break;
                defer self.ring.cqe_seen(&cqe);
                self.handleCompletion(&cqe) catch continue;
            }
        }
    }

    pub fn stop(self: *Self) void {
        self.running.store(false, .release);
    }

    /// Get number of connected clients
    pub fn getClientCount(self: *const Self) usize {
        return self.clients.count();
    }

    // ==================== Internal Methods ====================

    fn queueAccept(self: *Self) !void {
        const sqe = try self.ring.get_sqe();
        sqe.prep_accept(self.server_fd, null, null, linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK);
        sqe.user_data = 0;
    }

    fn handleCompletion(self: *Self, cqe: *linux.io_uring_cqe) !void {
        if (cqe.user_data == 0) {
            try self.handleAccept(cqe);
        }
        // Other completions handled here
    }

    fn handleAccept(self: *Self, cqe: *linux.io_uring_cqe) !void {
        try self.queueAccept();

        if (cqe.res < 0) return;

        const client_fd: posix.fd_t = @intCast(cqe.res);

        const client = try self.allocator.create(WsClient);
        client.* = .{
            .fd = client_fd,
            .connected = true,
            .handshake_complete = false,
            .recv_buffer = undefined,
            .recv_len = 0,
            .subscriptions = .{},
        };

        try self.clients.put(client_fd, client);
        std.debug.print("🔗 WebSocket client connected (total: {})\n", .{self.clients.count()});
    }

    fn processEventQueue(self: *Self) void {
        // Process up to 100 events per iteration
        var count: usize = 0;
        while (count < 100) : (count += 1) {
            const event = self.event_queue.pop() orelse break;
            self.broadcastEvent(event);
        }
    }

    fn broadcastEvent(self: *Self, event: Event) void {
        // Serialize event to JSON
        var json_buf: [2048]u8 = undefined;
        const json = self.serializeEvent(event, &json_buf) catch return;

        // Send to all connected clients
        var it = self.clients.iterator();
        while (it.next()) |entry| {
            const client = entry.value_ptr.*;
            if (client.connected and client.handshake_complete) {
                // Check subscription
                const subscribed = switch (event.event_type) {
                    .share => client.subscriptions.shares,
                    .miner_status => client.subscriptions.miner_status,
                    .stats => client.subscriptions.stats,
                    .alert => client.subscriptions.alerts,
                    .pool_status => true,
                };

                if (subscribed) {
                    self.sendWebSocketFrame(client, json) catch {
                        client.connected = false;
                    };
                }
            }
        }
    }

    fn serializeEvent(self: *Self, event: Event, buf: []u8) ![]const u8 {
        _ = self;

        const data_json = switch (event.payload) {
            .share => |s| try std.fmt.bufPrint(buf,
                \\{{"type":"{s}","timestamp":{},"data":{{"miner_id":{},"miner_name":"{s}","status":"{s}","difficulty":{d},"latency_ms":{}}}}}
            , .{
                @tagName(event.event_type),
                event.timestamp,
                s.miner_id,
                s.miner_name[0..s.miner_name_len],
                @tagName(s.status),
                s.difficulty,
                s.latency_ms,
            }),
            .miner_status => |m| try std.fmt.bufPrint(buf,
                \\{{"type":"{s}","timestamp":{},"data":{{"miner_id":{},"miner_name":"{s}","status":"{s}","hashrate":{d},"power":{}}}}}
            , .{
                @tagName(event.event_type),
                event.timestamp,
                m.miner_id,
                m.miner_name[0..m.miner_name_len],
                @tagName(m.status),
                m.hashrate_th,
                m.power_watts,
            }),
            .stats => |st| try std.fmt.bufPrint(buf,
                \\{{"type":"{s}","timestamp":{},"data":{{"total_hashrate":{d},"total_miners":{},"online_miners":{},"accepted_24h":{},"rejected_24h":{},"btc_earned_24h":{d},"accept_rate":{d}}}}}
            , .{
                @tagName(event.event_type),
                event.timestamp,
                st.total_hashrate_th,
                st.total_miners,
                st.online_miners,
                st.accepted_24h,
                st.rejected_24h,
                st.btc_earned_24h,
                st.accept_rate,
            }),
            .alert => |a| try std.fmt.bufPrint(buf,
                \\{{"type":"{s}","timestamp":{},"data":{{"severity":"{s}","miner_id":{?},"message":"{s}"}}}}
            , .{
                @tagName(event.event_type),
                event.timestamp,
                @tagName(a.severity),
                a.miner_id,
                a.message[0..a.message_len],
            }),
            .pool_status => |p| try std.fmt.bufPrint(buf,
                \\{{"type":"{s}","timestamp":{},"data":{{"pool_id":"{s}","pool_name":"{s}","connected":{},"latency_ms":{},"miners":{}}}}}
            , .{
                @tagName(event.event_type),
                event.timestamp,
                p.pool_id[0..p.pool_id_len],
                p.pool_name[0..p.pool_name_len],
                p.connected,
                p.latency_ms,
                p.miners_count,
            }),
        };

        return data_json;
    }

    fn sendWebSocketFrame(self: *Self, client: *WsClient, payload: []const u8) !void {
        // WebSocket frame format:
        // 1 byte: FIN + opcode (0x81 for text)
        // 1-9 bytes: payload length
        // N bytes: payload

        var frame_buf: [2058]u8 = undefined;
        var pos: usize = 0;

        // FIN bit set, text opcode
        frame_buf[0] = 0x81;
        pos = 1;

        // Payload length
        if (payload.len < 126) {
            frame_buf[pos] = @intCast(payload.len);
            pos += 1;
        } else if (payload.len < 65536) {
            frame_buf[pos] = 126;
            std.mem.writeInt(u16, frame_buf[pos + 1 ..][0..2], @intCast(payload.len), .big);
            pos += 3;
        } else {
            frame_buf[pos] = 127;
            std.mem.writeInt(u64, frame_buf[pos + 1 ..][0..8], payload.len, .big);
            pos += 9;
        }

        // Copy payload
        @memcpy(frame_buf[pos .. pos + payload.len], payload);
        pos += payload.len;

        // Send via io_uring
        const sqe = try self.ring.get_sqe();
        sqe.prep_send(client.fd, frame_buf[0..pos], 0);
        sqe.user_data = 0xFFFFFFFF; // Ignore completion
    }
};

// ==================== Tests ====================

test "event queue basic" {
    const allocator = std.testing.allocator;

    var queue = try EventQueue.init(allocator, 16);
    defer queue.deinit();

    try queue.push(.{
        .event_type = .share,
        .timestamp = 12345,
        .payload = undefined,
    });

    const event = queue.pop();
    try std.testing.expect(event != null);
    try std.testing.expectEqual(EventType.share, event.?.event_type);
}
