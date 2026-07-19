const std = @import("std");
const posix = std.posix;
const builtin = @import("builtin");

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

// Cross-platform modules
const socket = @import("socket.zig");
const io_backend = @import("io_backend.zig");
const bitcoin = @import("bitcoin_protocol.zig");

// Platform detection
const is_linux = builtin.os.tag == .linux;
const is_android = builtin.abi == .android;

// io_uring is only available on Linux (not Android)
const IoUring = if (is_linux and !is_android)
    std.os.linux.IoUring
else
    void;

// Bitcoin protocol constants
pub const MAGIC_MAINNET: u32 = 0xD9B4BEF9;
pub const MSG_TX: u32 = 1;
pub const DEFAULT_WHALE_THRESHOLD: i64 = 10_000_000; // 0.1 BTC in satoshis (lowered from 1 BTC)
pub const PROTOCOL_VERSION: i32 = 70015;

// Configurable threshold (can be set via FFI)
var whale_threshold: std.atomic.Value(i64) = std.atomic.Value(i64).init(DEFAULT_WHALE_THRESHOLD);

// C FFI types
pub const MS_TxHash = extern struct {
    bytes: [32]u8,
};

pub const MS_Transaction = extern struct {
    hash: MS_TxHash,
    value_satoshis: i64,
    input_count: u32,
    output_count: u32,
    is_whale: u8,
};

pub const MS_Status = enum(c_int) {
    disconnected = 0,
    connecting = 1,
    connected = 2,
    handshake_complete = 3,
};

pub const MS_Error = enum(c_int) {
    success = 0,
    out_of_memory = 1,
    connection_failed = 2,
    invalid_handle = 3,
    already_running = 4,
    not_running = 5,
    io_error = 6,
};

pub const MS_TxCallback = ?*const fn (*const MS_Transaction, ?*anyopaque) callconv(.c) void;
pub const MS_StatusCallback = ?*const fn (MS_Status, [*c]const u8, ?*anyopaque) callconv(.c) void;

pub const Sniffer = struct {
    allocator: std.mem.Allocator,
    node_ip: []const u8,
    port: u16,

    // Callbacks
    tx_callback: MS_TxCallback,
    tx_user_data: ?*anyopaque,
    status_callback: MS_StatusCallback,
    status_user_data: ?*anyopaque,

    // Runtime state
    running: std.atomic.Value(bool),
    status: std.atomic.Value(MS_Status),
    thread: ?std.Thread,
    mutex: Mutex,

    pub fn init(allocator: std.mem.Allocator, node_ip: []const u8, port: u16) !*Sniffer {
        const sniffer = try allocator.create(Sniffer);
        errdefer allocator.destroy(sniffer);

        const ip_copy = try allocator.dupe(u8, node_ip);
        errdefer allocator.free(ip_copy);

        sniffer.* = Sniffer{
            .allocator = allocator,
            .node_ip = ip_copy,
            .port = port,
            .tx_callback = null,
            .tx_user_data = null,
            .status_callback = null,
            .status_user_data = null,
            .running = std.atomic.Value(bool).init(false),
            .status = std.atomic.Value(MS_Status).init(.disconnected),
            .thread = null,
            .mutex = Mutex{},
        };

        return sniffer;
    }

    pub fn deinit(self: *Sniffer) void {
        // Ensure stopped
        if (self.running.load(.acquire)) {
            self.stop();
        }

        self.allocator.free(self.node_ip);
        self.allocator.destroy(self);
    }

    pub fn start(self: *Sniffer) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.running.load(.acquire)) {
            return error.AlreadyRunning;
        }

        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, snifferThread, .{self});
    }

    pub fn stop(self: *Sniffer) void {
        self.running.store(false, .release);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        self.status.store(.disconnected, .release);
    }

    fn notifyStatus(self: *Sniffer, status: MS_Status, message: []const u8) void {
        self.status.store(status, .release);

        if (self.status_callback) |callback| {
            var msg_buf: [256]u8 = undefined;
            const msg_z = std.fmt.bufPrintZ(&msg_buf, "{s}", .{message}) catch "Status change";
            callback(status, msg_z.ptr, self.status_user_data);
        }
    }

    fn notifyTransaction(self: *Sniffer, tx: *const MS_Transaction) void {
        if (self.tx_callback) |callback| {
            callback(tx, self.tx_user_data);
        }
    }

    fn snifferThread(self: *Sniffer) void {
        self.runSniffer() catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Error: {}", .{err}) catch "Unknown error";
            self.notifyStatus(.disconnected, msg);
        };
    }

    fn runSniffer(self: *Sniffer) !void {
        self.notifyStatus(.connecting, "Connecting to Bitcoin node...");

        // Create socket using cross-platform API
        const sockfd = try socket.createTcpSocket();
        defer socket.close(sockfd);

        // Connect to node using cross-platform API
        try socket.connectFromString(sockfd, self.node_ip, self.port);
        self.notifyStatus(.connected, "Connected to Bitcoin node");

        // Build and send version message
        const version_msg = try bitcoin.buildVersionMessage();
        _ = try socket.send(sockfd, &version_msg);

        self.notifyStatus(.handshake_complete, "Handshake initiated");

        // Scratch buffer for a single recv.
        var buffer: [4096]u8 align(64) = undefined;

        // Reassembly buffer. TCP is a byte stream: a P2P message may span
        // several recvs (a `tx` message — the whole point of this tool — is
        // routinely larger than one 4 KiB read) and a single recv may carry
        // several messages plus a partial tail. Bytes accumulate here and are
        // consumed a whole message at a time, so nothing is dropped at a read
        // boundary. Capped at MAX_BUFFERED so a peer that dribbles a huge
        // declared length cannot grow it without bound.
        var stream: std.ArrayList(u8) = .empty;
        defer stream.deinit(self.allocator);

        // Platform-specific I/O setup
        // io_uring for Linux (high performance), blocking recv for others
        const use_io_uring = comptime (is_linux and !is_android);

        var ring: if (use_io_uring) IoUring else void = if (use_io_uring) try IoUring.init(64, 0) else {};
        defer if (use_io_uring) ring.deinit();

        while (self.running.load(.acquire)) {
            // Receive data - platform specific
            const bytes_read: usize = if (use_io_uring) blk: {
                // Linux: Use io_uring for high-performance async I/O
                const sqe = try ring.get_sqe();
                sqe.prep_recv(sockfd, &buffer, 0);
                sqe.user_data = 0;
                _ = try ring.submit_and_wait(1);
                var cqe = try ring.copy_cqe();
                defer ring.cqe_seen(&cqe);
                if (cqe.res <= 0) break :blk 0;
                break :blk @as(usize, @intCast(cqe.res));
            } else blk: {
                // macOS/BSD/Android/other: Use blocking recv with timeout
                socket.setRecvTimeout(sockfd, 5000) catch {}; // 5 second timeout
                const result = socket.recv(sockfd, &buffer) catch |err| {
                    if (err == socket.SocketError.WouldBlock or err == socket.SocketError.ConnectionReset) break :blk 0;
                    return err;
                };
                break :blk result;
            };

            if (bytes_read == 0) break;

            if (stream.items.len + bytes_read > MAX_BUFFERED) return error.PeerFlooded;
            try stream.appendSlice(self.allocator, buffer[0..bytes_read]);

            // Drain every complete message currently buffered. `nextFrame`
            // returns null when the head message is still incomplete, at which
            // point we go back for another recv and retry with more bytes.
            //
            // `consumed` advances instead of shifting the buffer per message;
            // the leftover partial message is memmoved to the front exactly
            // once per recv, below.
            var consumed: usize = 0;
            drain: while (true) {
                const maybe_frame = bitcoin.nextFrame(stream.items[consumed..]) catch |err| switch (err) {
                    // Lost the message boundary (or the peer sent junk). Scan
                    // forward for the next magic rather than dropping the
                    // connection; if there is none, discard everything except a
                    // trailing window that could still hold a split magic.
                    error.BadMagic, error.MessageTooLarge => {
                        if (bitcoin.findMagic(stream.items, consumed + 1)) |idx| {
                            consumed = idx;
                            continue :drain;
                        }
                        const keep = @min(stream.items.len - consumed, 3);
                        consumed = stream.items.len - keep;
                        break :drain;
                    },
                };
                const frame = maybe_frame orelse break :drain; // need more bytes

                try self.handleFrame(sockfd, frame);
                consumed += frame.total_len;
            }

            if (consumed > 0) {
                try stream.replaceRange(self.allocator, 0, consumed, &.{});
            }
        }
    }

    /// Dispatch one fully-reassembled P2P message.
    ///
    /// `frame.payload` is exactly the declared payload length and is fully
    /// present, so payload reads need only guard against a payload that is
    /// too SHORT for the message type — never against running off the end of
    /// the receive buffer into an adjacent message.
    fn handleFrame(self: *Sniffer, sockfd: socket.socket_t, frame: bitcoin.Frame) !void {
        if (std.mem.eql(u8, frame.command, "version")) {
            try bitcoin.sendVerack(sockfd);
        } else if (std.mem.eql(u8, frame.command, "verack")) {
            self.notifyStatus(.handshake_complete, "Handshake complete - listening for transactions");
        } else if (std.mem.eql(u8, frame.command, "ping")) {
            if (frame.payload.len >= 8) {
                const nonce = std.mem.readInt(u64, frame.payload[0..8], .little);
                try bitcoin.sendPong(sockfd, nonce);
            }
        } else if (std.mem.eql(u8, frame.command, "tx")) {
            // A malformed tx from a hostile peer is not fatal to the session:
            // skip it and keep reading.
            const tx = bitcoin.parseTransaction(frame.payload) catch return;

            const c_tx = MS_Transaction{
                .hash = MS_TxHash{ .bytes = tx.hash },
                .value_satoshis = tx.value_satoshis,
                .input_count = tx.input_count,
                .output_count = tx.output_count,
                .is_whale = if (tx.value_satoshis >= whale_threshold.load(.acquire)) 1 else 0,
            };
            self.notifyTransaction(&c_tx);
        } else if (std.mem.eql(u8, frame.command, "inv")) {
            const ctx = GetDataCtx{ .sockfd = sockfd };
            // A truncated/garbage inv payload aborts only this message.
            bitcoin.forEachInvTxHash(frame.payload, ctx, GetDataCtx.request) catch return;
        }
    }
};

/// Hard cap on buffered-but-unparsed stream bytes: one maximum-size protocol
/// message plus a header. Beyond this a peer is flooding us rather than
/// sending anything the protocol permits.
const MAX_BUFFERED: usize = bitcoin.MAX_PROTOCOL_MESSAGE_LENGTH + bitcoin.HEADER_LEN;

/// Callback context for `forEachInvTxHash` — issues a `getdata` per MSG_TX
/// entry so the peer sends us the full transaction.
const GetDataCtx = struct {
    sockfd: socket.socket_t,

    fn request(self: GetDataCtx, hash: [32]u8) anyerror!void {
        try bitcoin.sendGetData(self.sockfd, MSG_TX, hash);
    }
};

// C FFI exports
export fn ms_sniffer_create(node_ip: [*c]const u8, port: u16) callconv(.c) ?*Sniffer {
    const ip_slice = std.mem.span(node_ip);
    return Sniffer.init(std.heap.c_allocator, ip_slice, port) catch null;
}

export fn ms_sniffer_destroy(sniffer: ?*Sniffer) callconv(.c) void {
    if (sniffer) |s| {
        s.deinit();
    }
}

export fn ms_sniffer_set_tx_callback(
    sniffer: ?*Sniffer,
    callback: MS_TxCallback,
    user_data: ?*anyopaque,
) callconv(.c) MS_Error {
    const s = sniffer orelse return .invalid_handle;
    s.tx_callback = callback;
    s.tx_user_data = user_data;
    return .success;
}

export fn ms_sniffer_set_status_callback(
    sniffer: ?*Sniffer,
    callback: MS_StatusCallback,
    user_data: ?*anyopaque,
) callconv(.c) MS_Error {
    const s = sniffer orelse return .invalid_handle;
    s.status_callback = callback;
    s.status_user_data = user_data;
    return .success;
}

export fn ms_sniffer_start(sniffer: ?*Sniffer) callconv(.c) MS_Error {
    const s = sniffer orelse return .invalid_handle;
    s.start() catch |err| {
        return switch (err) {
            error.AlreadyRunning => .already_running,
            error.OutOfMemory => .out_of_memory,
            else => .io_error,
        };
    };
    return .success;
}

export fn ms_sniffer_stop(sniffer: ?*Sniffer) callconv(.c) MS_Error {
    const s = sniffer orelse return .invalid_handle;
    s.stop();
    return .success;
}

export fn ms_sniffer_is_running(sniffer: ?*const Sniffer) callconv(.c) c_int {
    const s = sniffer orelse return 0;
    return if (s.running.load(.acquire)) 1 else 0;
}

export fn ms_sniffer_get_status(sniffer: ?*const Sniffer) callconv(.c) MS_Status {
    const s = sniffer orelse return .disconnected;
    return s.status.load(.acquire);
}

export fn ms_error_string(error_code: MS_Error) callconv(.c) [*c]const u8 {
    return switch (error_code) {
        .success => "Success",
        .out_of_memory => "Out of memory",
        .connection_failed => "Connection failed",
        .invalid_handle => "Invalid handle",
        .already_running => "Already running",
        .not_running => "Not running",
        .io_error => "I/O error",
    };
}

export fn ms_version() callconv(.c) [*c]const u8 {
    return "2.0.0-cross-platform";
}

export fn ms_performance_info() callconv(.c) [*c]const u8 {
    return switch (io_backend.backend) {
        .io_uring => "Bitcoin mempool sniffer | <1µs latency | io_uring | SIMD hash",
        .kqueue => "Bitcoin mempool sniffer | low latency | kqueue | SIMD hash",
        .poll => "Bitcoin mempool sniffer | poll fallback | SIMD hash",
    };
}

/// Get the I/O backend being used
export fn ms_get_io_backend() callconv(.c) [*c]const u8 {
    return switch (io_backend.backend) {
        .io_uring => "io_uring",
        .kqueue => "kqueue",
        .poll => "poll",
    };
}

/// Set the whale transaction threshold in satoshis
/// Default is 10,000,000 (0.1 BTC)
export fn ms_set_whale_threshold(threshold_satoshis: i64) callconv(.c) void {
    whale_threshold.store(threshold_satoshis, .release);
}

/// Get current whale threshold in satoshis
export fn ms_get_whale_threshold() callconv(.c) i64 {
    return whale_threshold.load(.acquire);
}

// ============================================================================
// Tests
// ============================================================================

test "Bitcoin magic constant" {
    try std.testing.expectEqual(@as(u32, 0xD9B4BEF9), MAGIC_MAINNET);
}

test "MSG_TX constant" {
    try std.testing.expectEqual(@as(u32, 1), MSG_TX);
}

test "Protocol version constant" {
    try std.testing.expectEqual(@as(i32, 70015), PROTOCOL_VERSION);
}

test "Default whale threshold constant" {
    try std.testing.expectEqual(@as(i64, 10_000_000), DEFAULT_WHALE_THRESHOLD);
}

test "Sniffer initialization" {
    const allocator = std.testing.allocator;
    const sniffer = try Sniffer.init(allocator, "127.0.0.1", 8333);
    defer sniffer.deinit();

    try std.testing.expect(!sniffer.running.load(.acquire));
    try std.testing.expectEqual(MS_Status.disconnected, sniffer.status.load(.acquire));
    try std.testing.expectEqual(@as(?std.Thread, null), sniffer.thread);
}

test "MS_Transaction structure" {
    const hash = MS_TxHash{ .bytes = [_]u8{0} ** 32 };
    const tx = MS_Transaction{
        .hash = hash,
        .value_satoshis = 100000,
        .input_count = 1,
        .output_count = 2,
        .is_whale = 0,
    };

    try std.testing.expectEqual(@as(i64, 100000), tx.value_satoshis);
    try std.testing.expectEqual(@as(u32, 1), tx.input_count);
    try std.testing.expectEqual(@as(u32, 2), tx.output_count);
    try std.testing.expectEqual(@as(u8, 0), tx.is_whale);
}

test "MS_Status enum values" {
    const disconnected = MS_Status.disconnected;
    const connecting = MS_Status.connecting;
    const connected = MS_Status.connected;
    const handshake = MS_Status.handshake_complete;

    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(disconnected));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(connecting));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(connected));
    try std.testing.expectEqual(@as(c_int, 3), @intFromEnum(handshake));
}

test "MS_Error enum values" {
    const success = MS_Error.success;
    const oom = MS_Error.out_of_memory;
    const conn_fail = MS_Error.connection_failed;
    const invalid = MS_Error.invalid_handle;

    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(success));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(oom));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(conn_fail));
    try std.testing.expectEqual(@as(c_int, 3), @intFromEnum(invalid));
}

test "whale_threshold atomic operations" {
    const initial = whale_threshold.load(.acquire);
    try std.testing.expectEqual(DEFAULT_WHALE_THRESHOLD, initial);

    whale_threshold.store(50_000_000, .release);
    const updated = whale_threshold.load(.acquire);
    try std.testing.expectEqual(@as(i64, 50_000_000), updated);

    // Restore
    whale_threshold.store(DEFAULT_WHALE_THRESHOLD, .release);
}

test "Mutex lock/unlock" {
    var mutex = Mutex{};

    // Lock and unlock shouldn't crash
    mutex.lock();
    mutex.unlock();

    mutex.lock();
    mutex.unlock();
}

test "Sniffer initialization with allocator" {
    const allocator = std.testing.allocator;
    const sniffer = try Sniffer.init(allocator, "192.168.1.1", 8333);
    defer sniffer.deinit();

    try std.testing.expect(sniffer.node_ip.len > 0);
    try std.testing.expectEqual(@as(u16, 8333), sniffer.port);
}

test "Sniffer state transitions" {
    const allocator = std.testing.allocator;
    const sniffer = try Sniffer.init(allocator, "127.0.0.1", 8333);
    defer sniffer.deinit();

    // Initial state
    try std.testing.expectEqual(MS_Status.disconnected, sniffer.status.load(.acquire));
    try std.testing.expect(!sniffer.running.load(.acquire));

    // Simulate status update
    sniffer.status.store(MS_Status.connecting, .release);
    try std.testing.expectEqual(MS_Status.connecting, sniffer.status.load(.acquire));

    sniffer.status.store(MS_Status.connected, .release);
    try std.testing.expectEqual(MS_Status.connected, sniffer.status.load(.acquire));

    sniffer.status.store(MS_Status.handshake_complete, .release);
    try std.testing.expectEqual(MS_Status.handshake_complete, sniffer.status.load(.acquire));
}

test "MS_Transaction whale detection" {
    const small_hash = MS_TxHash{ .bytes = [_]u8{0} ** 32 };

    // Non-whale transaction
    const small_tx = MS_Transaction{
        .hash = small_hash,
        .value_satoshis = 1_000_000,
        .input_count = 1,
        .output_count = 1,
        .is_whale = 0,
    };
    try std.testing.expectEqual(@as(u8, 0), small_tx.is_whale);

    // Whale transaction (over 0.1 BTC)
    const whale_tx = MS_Transaction{
        .hash = small_hash,
        .value_satoshis = 100_000_000,
        .input_count = 1,
        .output_count = 1,
        .is_whale = 1,
    };
    try std.testing.expectEqual(@as(u8, 1), whale_tx.is_whale);
}

test "Sniffer multiple instances" {
    const allocator = std.testing.allocator;
    const sniffer1 = try Sniffer.init(allocator, "127.0.0.1", 8333);
    const sniffer2 = try Sniffer.init(allocator, "192.168.1.1", 8334);
    defer {
        sniffer1.deinit();
        sniffer2.deinit();
    }

    try std.testing.expectEqual(@as(u16, 8333), sniffer1.port);
    try std.testing.expectEqual(@as(u16, 8334), sniffer2.port);
    try std.testing.expect(sniffer1 != sniffer2);
}
