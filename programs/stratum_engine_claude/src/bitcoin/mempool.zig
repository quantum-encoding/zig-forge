//! Bitcoin P2P Mempool Monitor
//! Real-time transaction sniping using io_uring + SIMD
//! Based on Grok's implementation

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const IoUring = linux.IoUring;
const Sha256 = std.crypto.hash.sha2.Sha256;
const compat = @import("../utils/compat.zig");

// Bitcoin protocol constants
const MAGIC_MAINNET: u32 = 0xD9B4BEF9;
const MSG_TX: u32 = 1;
const MSG_BLOCK: u32 = 2;
const PROTOCOL_VERSION: u32 = 70015; // Modern protocol version

// Fresh seed nodes from seed.bitcoin.sipa.be (updated 2025-11-23)
const SEED_NODES = [_][]const u8{
    "167.224.189.201",
    "103.47.56.20",
    "103.246.186.121",
    "62.238.237.242",
    "203.11.72.115",
};

pub const MempoolStats = struct {
    tx_seen: std.atomic.Value(u64),
    blocks_seen: std.atomic.Value(u64),
    bytes_received: std.atomic.Value(u64),

    pub fn init() MempoolStats {
        return .{
            .tx_seen = std.atomic.Value(u64).init(0),
            .blocks_seen = std.atomic.Value(u64).init(0),
            .bytes_received = std.atomic.Value(u64).init(0),
        };
    }

    pub fn recordTx(self: *MempoolStats) void {
        _ = self.tx_seen.fetchAdd(1, .monotonic);
    }

    pub fn recordBlock(self: *MempoolStats) void {
        _ = self.blocks_seen.fetchAdd(1, .monotonic);
    }

    pub fn recordBytes(self: *MempoolStats, count: u64) void {
        _ = self.bytes_received.fetchAdd(count, .monotonic);
    }
};

/// Calculate Bitcoin-style checksum: first 4 bytes of SHA256(SHA256(data))
fn calculateChecksum(data: []const u8) [4]u8 {
    var hash1: [32]u8 = undefined;
    var hash2: [32]u8 = undefined;

    // First SHA-256
    Sha256.hash(data, &hash1, .{});

    // Second SHA-256
    Sha256.hash(&hash1, &hash2, .{});

    // Return first 4 bytes
    var checksum: [4]u8 = undefined;
    @memcpy(&checksum, hash2[0..4]);
    return checksum;
}

/// Build Bitcoin P2P version message with current timestamp
fn buildVersionMessage(remote_addr: posix.sockaddr.in, allocator: std.mem.Allocator) ![]u8 {
    // Get current timestamp
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const timestamp: i64 = ts.sec;

    var payload = try std.ArrayList(u8).initCapacity(allocator, 100);
    errdefer payload.deinit(allocator);

    // Protocol version (70015)
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], PROTOCOL_VERSION, .little);
    try payload.appendSlice(allocator, buf[0..4]);

    // Services (NODE_NETWORK = 1)
    std.mem.writeInt(u64, &buf, 1, .little);
    try payload.appendSlice(allocator, &buf);

    // Timestamp
    std.mem.writeInt(i64, &buf, timestamp, .little);
    try payload.appendSlice(allocator, &buf);

    // addr_recv (remote peer)
    std.mem.writeInt(u64, &buf, 1, .little); // services
    try payload.appendSlice(allocator, &buf);
    try payload.appendSlice(allocator, &[_]u8{0} ** 10 ++ [_]u8{ 0xFF, 0xFF }); // IPv4-mapped IPv6
    std.mem.writeInt(u32, buf[0..4], remote_addr.addr, .big);
    try payload.appendSlice(allocator, buf[0..4]);
    std.mem.writeInt(u16, buf[0..2], remote_addr.port, .big);
    try payload.appendSlice(allocator, buf[0..2]);

    // addr_from (our address - zeros)
    std.mem.writeInt(u64, &buf, 0, .little); // services
    try payload.appendSlice(allocator, &buf);
    try payload.appendSlice(allocator, &[_]u8{0} ** 10 ++ [_]u8{ 0xFF, 0xFF }); // IPv4-mapped IPv6
    std.mem.writeInt(u32, buf[0..4], 0, .little);
    try payload.appendSlice(allocator, buf[0..4]);
    std.mem.writeInt(u16, buf[0..2], 0, .little);
    try payload.appendSlice(allocator, buf[0..2]);

    // Nonce (random)
    const nonce: u64 = @intCast(@as(u128, @bitCast(ts)) & 0xFFFFFFFFFFFFFFFF);
    std.mem.writeInt(u64, &buf, nonce, .little);
    try payload.appendSlice(allocator, &buf);

    // User agent (empty for speed)
    try payload.append(allocator, 0);

    // Start height (0 = we don't have the blockchain)
    std.mem.writeInt(i32, buf[0..4], 0, .little);
    try payload.appendSlice(allocator, buf[0..4]);

    // Build full message with header
    var message = try std.ArrayList(u8).initCapacity(allocator, 24 + payload.items.len);

    // Magic
    std.mem.writeInt(u32, buf[0..4], MAGIC_MAINNET, .little);
    try message.appendSlice(allocator, buf[0..4]);

    // Command ("version" padded to 12 bytes)
    try message.appendSlice(allocator, "version\x00\x00\x00\x00\x00");

    // Payload length
    std.mem.writeInt(u32, buf[0..4], @intCast(payload.items.len), .little);
    try message.appendSlice(allocator, buf[0..4]);

    // Checksum (first 4 bytes of double SHA-256)
    const checksum = calculateChecksum(payload.items);
    try message.appendSlice(allocator, &checksum);

    // Payload
    try message.appendSlice(allocator, payload.items);

    payload.deinit(allocator);

    const final_message = try message.toOwnedSlice(allocator);

    // Debug: Print hex dump of message
    std.debug.print("📝 Version message ({} bytes):\n", .{final_message.len});
    std.debug.print("   Header: ", .{});
    for (final_message[0..24]) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
    std.debug.print("\n   Checksum: {x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{ checksum[0], checksum[1], checksum[2], checksum[3] });

    return final_message;
}

pub const MempoolMonitor = struct {
    allocator: std.mem.Allocator,
    sockfd: posix.fd_t,
    ring: IoUring,
    stats: MempoolStats,
    running: std.atomic.Value(bool),
    callback: ?*const fn (tx_hash: [32]u8) void,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, bitcoin_node_host: []const u8, bitcoin_node_port: u16) !Self {
        return initWithFallback(allocator, bitcoin_node_host, bitcoin_node_port) catch |err| {
            std.debug.print("⚠️  Failed to connect to {s}:{}: {}\n", .{ bitcoin_node_host, bitcoin_node_port, err });
            std.debug.print("🔄 Trying seed nodes...\n", .{});

            // Try seed nodes as fallback
            for (SEED_NODES) |seed_host| {
                std.debug.print("🌱 Attempting {s}:8333...\n", .{seed_host});
                const result = initWithFallback(allocator, seed_host, 8333) catch |seed_err| {
                    std.debug.print("   ❌ Failed: {}\n", .{seed_err});
                    continue;
                };
                std.debug.print("   ✅ Connected!\n", .{});
                return result;
            }

            return error.NoNodesAvailable;
        };
    }

    fn initWithFallback(allocator: std.mem.Allocator, bitcoin_node_host: []const u8, bitcoin_node_port: u16) !Self {
        // Create socket using compat helper
        const sockfd = try compat.createSocket(linux.SOCK.STREAM);
        errdefer compat.closeSocket(sockfd);

        // Parse host (IP only for now)
        var addr = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = std.mem.nativeToBig(u16, bitcoin_node_port),
            .addr = undefined,
        };

        if (std.mem.eql(u8, bitcoin_node_host, "localhost") or std.mem.eql(u8, bitcoin_node_host, "127.0.0.1")) {
            addr.addr = 0x0100007F; // 127.0.0.1 in network byte order
        } else {
            // Parse IP string
            var octets: [4]u8 = undefined;
            var it = std.mem.splitScalar(u8, bitcoin_node_host, '.');
            var i: usize = 0;
            while (it.next()) |octet| : (i += 1) {
                if (i >= 4) return error.InvalidAddress;
                octets[i] = try std.fmt.parseInt(u8, octet, 10);
            }
            if (i != 4) return error.InvalidAddress;
            addr.addr = @bitCast(octets);
        }

        // Connect to Bitcoin node
        try compat.connectSocket(sockfd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));

        // Build and send version message with current timestamp
        const version_msg = try buildVersionMessage(addr, allocator);
        defer allocator.free(version_msg);

        _ = try compat.sendSocket(sockfd, version_msg);

        std.debug.print("📡 Sent version message ({} bytes) to {s}:{}\n", .{ version_msg.len, bitcoin_node_host, bitcoin_node_port });

        // Setup io_uring with SQPOLL (requires elevated privileges, fallback to regular)
        const ring = IoUring.init(64, linux.IORING_SETUP_SQPOLL) catch blk: {
            std.debug.print("⚠️  SQPOLL failed (need root), using regular io_uring\n", .{});
            break :blk try IoUring.init(64, 0);
        };

        return .{
            .allocator = allocator,
            .sockfd = sockfd,
            .ring = ring,
            .stats = MempoolStats.init(),
            .running = std.atomic.Value(bool).init(false),
            .callback = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.running.store(false, .release);
        compat.closeSocket(self.sockfd);
        self.ring.deinit();
    }

    pub fn setCallback(self: *Self, callback: *const fn (tx_hash: [32]u8) void) void {
        self.callback = callback;
    }

    /// Main monitoring loop - runs in dedicated thread
    pub fn run(self: *Self) !void {
        self.running.store(true, .release);

        // Buffer for receiving data (64-byte aligned for DMA)
        var buffer: [4096]u8 align(64) = undefined;
        var handshake_complete = false;

        while (self.running.load(.acquire)) {
            // Submit recv request
            const sqe = try self.ring.get_sqe();
            sqe.prep_recv(self.sockfd, &buffer, 0);
            sqe.user_data = 0;

            // Submit and wait
            _ = try self.ring.submit_and_wait(1);

            // Wait for completion
            var cqe = try self.ring.copy_cqe();
            defer self.ring.cqe_seen(&cqe);

            const bytes_read_signed = cqe.res;
            if (bytes_read_signed < 0) {
                const err_code = -bytes_read_signed;
                std.debug.print("⚠️  Socket error: {}\n", .{err_code});
                break;
            }

            const bytes_read = @as(usize, @intCast(bytes_read_signed));
            if (bytes_read == 0) {
                std.debug.print("⚠️  Connection closed by peer\n", .{});
                break;
            }

            self.stats.recordBytes(bytes_read);

            // Process received data
            try self.processBuffer(buffer[0..bytes_read], &handshake_complete);
        }
    }

    fn processBuffer(self: *Self, data: []const u8, handshake_complete: *bool) !void {
        var offset: usize = 0;

        while (offset + 24 <= data.len) {
            // Parse Bitcoin P2P message header (24 bytes)
            const magic = std.mem.readInt(u32, data[offset..][0..4], .little);
            offset += 4;

            var command_buf: [12]u8 = undefined;
            @memcpy(&command_buf, data[offset..][0..12]);
            offset += 12;

            // Null-terminate command string
            var command_str: []const u8 = &command_buf;
            if (std.mem.indexOfScalar(u8, &command_buf, 0)) |null_pos| {
                command_str = command_buf[0..null_pos];
            }

            const length = std.mem.readInt(u32, data[offset..][0..4], .little);
            offset += 4;

            _ = std.mem.readInt(u32, data[offset..][0..4], .little); // checksum (unused)
            offset += 4;

            // Verify magic
            if (magic != MAGIC_MAINNET) {
                std.debug.print("❌ Invalid magic: 0x{x:0>8} (expected 0x{x:0>8})\n", .{ magic, MAGIC_MAINNET });
                continue;
            }

            // Check if we have the full payload
            if (offset + length > data.len) break;

            // Handle protocol messages
            if (std.mem.eql(u8, command_str, "version")) {
                std.debug.print("✅ Received version from peer\n", .{});
                // Send verack response
                try self.sendVerack();
            } else if (std.mem.eql(u8, command_str, "verack")) {
                std.debug.print("✅ Received verack! Handshake complete!\n", .{});
                handshake_complete.* = true;
                // Send protocol messages to appear as a real node
                try self.sendHeaders();
                std.debug.print("🎧 Passive listening mode - waiting for inv messages...\n", .{});
            } else if (std.mem.eql(u8, command_str, "inv")) {
                try self.processInv(data[offset .. offset + length]);
            } else if (std.mem.eql(u8, command_str, "ping")) {
                std.debug.print("🏓 Received ping, sending pong\n", .{});
                try self.sendPong(data[offset .. offset + length]);
            } else if (std.mem.eql(u8, command_str, "sendcmpct") or
                std.mem.eql(u8, command_str, "feefilter") or
                std.mem.eql(u8, command_str, "addr") or
                std.mem.eql(u8, command_str, "sendheaders") or
                std.mem.eql(u8, command_str, "getheaders"))
            {
                // Silently ignore common protocol messages
            } else if (handshake_complete.*) {
                // Only log unknown messages after handshake
                std.debug.print("❓ Unknown command: '{s}' ({} bytes)\n", .{ command_str, length });
            }

            offset += length;
        }
    }

    fn sendVerack(self: *Self) !void {
        var buf: [24]u8 = undefined;
        var offset: usize = 0;

        // Magic
        std.mem.writeInt(u32, buf[offset..][0..4], MAGIC_MAINNET, .little);
        offset += 4;

        // Command ("verack" padded to 12 bytes)
        @memcpy(buf[offset..][0..12], "verack\x00\x00\x00\x00\x00\x00");
        offset += 12;

        // Payload length (0)
        std.mem.writeInt(u32, buf[offset..][0..4], 0, .little);
        offset += 4;

        // Checksum (for empty payload: SHA256(SHA256("")) = 5df6e0e2...)
        const empty_checksum = [_]u8{ 0x5d, 0xf6, 0xe0, 0xe2 };
        @memcpy(buf[offset..][0..4], &empty_checksum);

        _ = try compat.sendSocket(self.sockfd, &buf);
        std.debug.print("📤 Sent verack\n", .{});
    }

    fn sendPong(self: *Self, ping_payload: []const u8) !void {
        // Pong message echoes back the ping's nonce
        var buf: [32]u8 = undefined; // 24 header + 8 nonce
        var offset: usize = 0;

        // Magic
        std.mem.writeInt(u32, buf[offset..][0..4], MAGIC_MAINNET, .little);
        offset += 4;

        // Command ("pong" padded to 12 bytes)
        @memcpy(buf[offset..][0..12], "pong\x00\x00\x00\x00\x00\x00\x00\x00");
        offset += 12;

        // Payload length (8 bytes for nonce)
        std.mem.writeInt(u32, buf[offset..][0..4], 8, .little);
        offset += 4;

        // Checksum
        if (ping_payload.len >= 8) {
            const checksum = calculateChecksum(ping_payload[0..8]);
            @memcpy(buf[offset..][0..4], &checksum);
        } else {
            @memset(buf[offset..][0..4], 0);
        }
        offset += 4;

        // Nonce (from ping)
        if (ping_payload.len >= 8) {
            @memcpy(buf[offset..][0..8], ping_payload[0..8]);
        } else {
            @memset(buf[offset..][0..8], 0);
        }

        _ = try compat.sendSocket(self.sockfd, &buf);
        std.debug.print("📤 Sent pong\n", .{});
    }

    fn sendHeaders(self: *Self) !void {
        // Send "sendheaders" message to indicate we want headers
        var buf: [24]u8 = undefined;
        var offset: usize = 0;

        // Magic
        std.mem.writeInt(u32, buf[offset..][0..4], MAGIC_MAINNET, .little);
        offset += 4;

        // Command ("sendheaders" padded to 12 bytes)
        @memcpy(buf[offset..][0..12], "sendheaders\x00");
        offset += 12;

        // Payload length (0)
        std.mem.writeInt(u32, buf[offset..][0..4], 0, .little);
        offset += 4;

        // Checksum (empty payload)
        const empty_checksum = [_]u8{ 0x5d, 0xf6, 0xe0, 0xe2 };
        @memcpy(buf[offset..][0..4], &empty_checksum);

        _ = try compat.sendSocket(self.sockfd, &buf);
        std.debug.print("📤 Sent sendheaders\n", .{});
    }

    fn processInv(self: *Self, payload: []const u8) !void {
        var payload_offset: usize = 0;
        const inv_count = std.mem.readInt(u32, payload[payload_offset..][0..4], .little);
        payload_offset += 4;

        var i: u32 = 0;
        while (i < inv_count and payload_offset + 36 <= payload.len) : (i += 1) {
            const inv_type = std.mem.readInt(u32, payload[payload_offset..][0..4], .little);
            payload_offset += 4;

            if (inv_type == MSG_TX) {
                var hash: [32]u8 = undefined;
                @memcpy(&hash, payload[payload_offset..][0..32]);

                // Reverse endianness using SIMD (Bitcoin wire format is little-endian)
                const reversed_hash = reverseHashSIMD(hash);

                self.stats.recordTx();

                // Call user callback if set
                if (self.callback) |cb| {
                    cb(reversed_hash);
                }
            } else if (inv_type == MSG_BLOCK) {
                self.stats.recordBlock();
            }

            payload_offset += 32; // hash size
        }
    }

    /// Reverse hash bytes using SIMD for display (little-endian → big-endian)
    fn reverseHashSIMD(hash: [32]u8) [32]u8 {
        const hash_vec = @Vector(32, u8){
            hash[0],  hash[1],  hash[2],  hash[3],  hash[4],  hash[5],  hash[6],  hash[7],
            hash[8],  hash[9],  hash[10], hash[11], hash[12], hash[13], hash[14], hash[15],
            hash[16], hash[17], hash[18], hash[19], hash[20], hash[21], hash[22], hash[23],
            hash[24], hash[25], hash[26], hash[27], hash[28], hash[29], hash[30], hash[31],
        };

        const reverse_indices = @Vector(32, i32){
            31, 30, 29, 28, 27, 26, 25, 24, 23, 22, 21, 20, 19, 18, 17, 16,
            15, 14, 13, 12, 11, 10, 9,  8,  7,  6,  5,  4,  3,  2,  1,  0,
        };

        const reversed_hash_vec = @shuffle(u8, hash_vec, undefined, reverse_indices);
        return reversed_hash_vec;
    }
};

/// Helper to format hash as hex string
pub fn formatHash(hash: [32]u8, buffer: []u8) ![]u8 {
    if (buffer.len < 64) return error.BufferTooSmall;

    var i: usize = 0;
    while (i < 32) : (i += 1) {
        _ = try std.fmt.bufPrint(buffer[i * 2 ..], "{x:0>2}", .{hash[i]});
    }

    return buffer[0..64];
}

test "hash reversal" {
    const hash = [_]u8{0} ** 32;
    const reversed = MempoolMonitor.reverseHashSIMD(hash);
    try std.testing.expectEqual(hash, reversed); // All zeros should stay the same
}
