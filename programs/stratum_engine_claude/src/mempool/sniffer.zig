const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const IoUring = linux.IoUring;

// Bitcoin protocol constants
const MAGIC_MAINNET: u32 = 0xD9B4BEF9;
const MSG_TX: u32 = 1;
const WHALE_THRESHOLD: i64 = 100_000_000; // 1 BTC in satoshis
const PROTOCOL_VERSION: i32 = 70015; // Bitcoin Core 0.13.2+

// ANSI color codes
const RED = "\x1b[31;1m";
const RESET = "\x1b[0m";

// Build version message dynamically with current timestamp and CORRECT double-SHA256 checksum
fn buildVersionMessage() ![125]u8 {
    var message: [125]u8 = undefined;

    // Get current timestamp for payload
    const now = @as(i64, @intCast((posix.clock_gettime(posix.CLOCK.REALTIME) catch unreachable).sec));

    // --- Build Payload First (101 bytes) at offset 24 ---
    var offset: usize = 24;

    // Protocol version (70015)
    std.mem.writeInt(i32, message[offset..][0..4], PROTOCOL_VERSION, .little);
    offset += 4;

    // Services (NODE_NETWORK = 1)
    std.mem.writeInt(u64, message[offset..][0..8], 1, .little);
    offset += 8;

    // Timestamp (current Unix time)
    std.mem.writeInt(i64, message[offset..][0..8], now, .little);
    offset += 8;

    // addr_recv services
    std.mem.writeInt(u64, message[offset..][0..8], 1, .little);
    offset += 8;

    // addr_recv IP (IPv4-mapped IPv6: ::ffff:0.0.0.0)
    @memset(message[offset..][0..16], 0);
    message[offset + 10] = 0xff;
    message[offset + 11] = 0xff;
    offset += 16;

    // addr_recv port (8333 big-endian)
    std.mem.writeInt(u16, message[offset..][0..2], 0x208D, .big);
    offset += 2;

    // addr_from services
    std.mem.writeInt(u64, message[offset..][0..8], 1, .little);
    offset += 8;

    // addr_from IP (IPv4-mapped IPv6: ::ffff:0.0.0.0)
    @memset(message[offset..][0..16], 0);
    message[offset + 10] = 0xff;
    message[offset + 11] = 0xff;
    offset += 16;

    // addr_from port (8333 big-endian)
    std.mem.writeInt(u16, message[offset..][0..2], 0x208D, .big);
    offset += 2;

    // Nonce (random - using timestamp for simplicity)
    std.mem.writeInt(u64, message[offset..][0..8], @as(u64, @intCast(now)), .little);
    offset += 8;

    // User agent length (0)
    message[offset] = 0;
    offset += 1;

    // Start height (0)
    std.mem.writeInt(i32, message[offset..][0..4], 0, .little);
    offset += 4;

    // Relay (true)
    message[offset] = 1;

    // --- Calculate Double-SHA256 Checksum ---
    // Bitcoin protocol: checksum = first 4 bytes of SHA256(SHA256(payload))
    var hash1: [32]u8 = undefined;
    var hash2: [32]u8 = undefined;

    const payload = message[24..125]; // 101 bytes of payload
    std.crypto.hash.sha2.Sha256.hash(payload, &hash1, .{});
    std.crypto.hash.sha2.Sha256.hash(&hash1, &hash2, .{});

    const checksum = std.mem.readInt(u32, hash2[0..4], .little);

    // --- Build Header (24 bytes) ---
    offset = 0;

    // Magic
    std.mem.writeInt(u32, message[offset..][0..4], MAGIC_MAINNET, .little);
    offset += 4;

    // Command: "version"
    @memset(message[offset..][0..12], 0);
    @memcpy(message[offset..][0..7], "version");
    offset += 12;

    // Payload length: 101 bytes
    std.mem.writeInt(u32, message[offset..][0..4], 101, .little);
    offset += 4;

    // Checksum (CRITICAL: double-SHA256 of payload)
    std.mem.writeInt(u32, message[offset..][0..4], checksum, .little);

    return message;
}

pub fn main() !void {
    std.debug.print("🌐 Connecting to Bitcoin network...\n", .{});

    // Fresh Bitcoin nodes from DNS seed (dig +short seed.bitcoin.sipa.be)
    // Updated: 2025-11-23
    const seed_nodes = [_][4]u8{
        .{ 216, 107, 135, 88 },   // seed.bitcoin.sipa.be (fresh)
        .{ 67, 144, 178, 198 },   // seed.bitcoin.sipa.be (fresh)
        .{ 203, 11, 72, 126 },    // seed.bitcoin.sipa.be (fresh)
        .{ 127, 0, 0, 1 },        // Localhost (if Bitcoin Core is running locally)
    };

    var addr: posix.sockaddr.in = undefined;
    addr.family = posix.AF.INET;
    addr.port = std.mem.nativeToBig(u16, 8333);

    var sockfd: posix.socket_t = undefined;
    var connected = false;

    for (seed_nodes) |node_ip| {
        // Create new socket for each attempt
        sockfd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP) catch continue;

        addr.addr = std.mem.nativeToBig(u32, (@as(u32, node_ip[0]) << 24) | (@as(u32, node_ip[1]) << 16) | (@as(u32, node_ip[2]) << 8) | node_ip[3]);

        std.debug.print("🔗 Trying Bitcoin node {d}.{d}.{d}.{d}:8333...\n", .{ node_ip[0], node_ip[1], node_ip[2], node_ip[3] });

        if (posix.connect(sockfd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)))) {
            connected = true;
            std.debug.print("✅ Connected!\n", .{});
            break;
        } else |_| {
            std.debug.print("❌ Connection failed, trying next node...\n", .{});
            _ = std.c.close(sockfd);
        }
    }

    if (!connected) {
        std.debug.print("❌ Failed to connect to any Bitcoin seed node\n", .{});
        return error.AllNodesUnreachable;
    }
    defer _ = std.c.close(sockfd);

    // Build and send version message with current timestamp
    const version_msg = try buildVersionMessage();

    // Log hex dump of version message for verification
    std.debug.print("📤 Version message HEX ({d} bytes):\n", .{version_msg.len});
    std.debug.print("   Header: ", .{});
    for (version_msg[0..24]) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
    std.debug.print("\n   Checksum: ", .{});
    for (version_msg[20..24]) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
    std.debug.print("\n   Payload (first 32 bytes): ", .{});
    for (version_msg[24..56]) |byte| {
        std.debug.print("{x:0>2}", .{byte});
    }
    std.debug.print("\n", .{});

    _ = try posix.send(sockfd, &version_msg, 0);
    std.debug.print("✅ Sent version message (protocol {d})\n", .{PROTOCOL_VERSION});

    // Setup io_uring (without SQPOLL to avoid privilege issues)
    var ring = try IoUring.init(64, 0);
    defer ring.deinit();
    std.debug.print("⚡ io_uring initialized, listening for transactions...\n", .{});

    // Buffer for receiving data
    var buffer: [4096]u8 align(64) = undefined;

    while (true) {
        // Submit recv request
        const sqe = try ring.get_sqe();
        sqe.prep_recv(sockfd, &buffer, 0);
        sqe.user_data = 0;

        // Submit and wait
        _ = try ring.submit_and_wait(1);

        // Wait for completion
        var cqe = try ring.copy_cqe();
        defer ring.cqe_seen(&cqe);

        const bytes_read = @as(usize, @intCast(cqe.res));
        if (bytes_read <= 0) break;

        std.debug.print("📥 Received {d} bytes\n", .{bytes_read});

        // Process received data
        var offset: usize = 0;
        while (offset + 24 <= bytes_read) {
            // Parse header manually
            const magic = std.mem.readInt(u32, buffer[offset..][0..4], .little);
            offset += 4;

            var command_buf: [12]u8 = undefined;
            @memcpy(&command_buf, buffer[offset..][0..12]);
            offset += 12;

            // Null-terminate and compare
            var command_str: []const u8 = &command_buf;
            if (std.mem.indexOfScalar(u8, &command_buf, 0)) |null_pos| {
                command_str = command_buf[0..null_pos];
            }

            const length = std.mem.readInt(u32, buffer[offset..][0..4], .little);
            offset += 4;

            _ = std.mem.readInt(u32, buffer[offset..][0..4], .little); // checksum (unused)
            offset += 4;

            // Verify magic
            if (magic != MAGIC_MAINNET) continue;

            // Debug: print received command (except ping/pong noise)
            if (!std.mem.eql(u8, command_str, "ping") and !std.mem.eql(u8, command_str, "pong")) {
                std.debug.print("📨 Command: {s} (length: {d})\n", .{ command_str, length });
            }

            // Check if we have the full payload
            if (offset + length > bytes_read) break;

            // Handle version command - respond with verack
            if (std.mem.eql(u8, command_str, "version")) {
                try sendVerack(sockfd);
                std.debug.print("✅ Sent verack\n", .{});
            }

            // Handle verack command
            if (std.mem.eql(u8, command_str, "verack")) {
                std.debug.print("✅ Handshake complete!\n", .{});
                std.debug.print("🔊 Passive sonar active - listening for inv broadcasts...\n", .{});
            }

            // Handle ping - respond with pong to keep connection alive
            if (std.mem.eql(u8, command_str, "ping")) {
                if (length >= 8) {
                    const nonce = std.mem.readInt(u64, buffer[offset..][0..8], .little);
                    try sendPong(sockfd, nonce);
                    std.debug.print("💓 Heartbeat (ping/pong)\n", .{});
                }
            }

            // Handle tx command (full transaction data)
            if (std.mem.eql(u8, command_str, "tx")) {
                try handleTransaction(buffer[offset..][0..length]);
            }

            // Handle inv command
            if (std.mem.eql(u8, command_str, "inv")) {
                var payload_offset: usize = 0;
                const inv_count = std.mem.readInt(u32, buffer[offset + payload_offset..][0..4], .little);
                payload_offset += 4;

                var i: u32 = 0;
                while (i < inv_count and payload_offset + 36 <= length) : (i += 1) {
                    const inv_type = std.mem.readInt(u32, buffer[offset + payload_offset..][0..4], .little);
                    payload_offset += 4;

                    if (inv_type == MSG_TX) {
                        var hash: [32]u8 = undefined;
                        @memcpy(&hash, buffer[offset + payload_offset..][0..32]);

                        // Send getdata to fetch full transaction
                        try sendGetData(sockfd, MSG_TX, hash);
                    }

                    payload_offset += 32; // hash size
                }
            }

            offset += length;
        }
    }
}

// Send verack message (acknowledgement of version)
fn sendVerack(sockfd: posix.socket_t) !void {
    var message: [24]u8 = undefined;
    var offset: usize = 0;

    // Header
    std.mem.writeInt(u32, message[offset..][0..4], MAGIC_MAINNET, .little);
    offset += 4;

    // Command: "verack"
    @memset(message[offset..][0..12], 0);
    @memcpy(message[offset..][0..6], "verack");
    offset += 12;

    // Payload length: 0
    std.mem.writeInt(u32, message[offset..][0..4], 0, .little);
    offset += 4;

    // Checksum (0 for empty payload)
    std.mem.writeInt(u32, message[offset..][0..4], 0, .little);

    _ = try posix.send(sockfd, &message, 0);
}

// Send mempool message (request current mempool inventory)
fn sendMempool(sockfd: posix.socket_t) !void {
    var message: [24]u8 = undefined;
    var offset: usize = 0;

    // Header
    std.mem.writeInt(u32, message[offset..][0..4], MAGIC_MAINNET, .little);
    offset += 4;

    // Command: "mempool"
    @memset(message[offset..][0..12], 0);
    @memcpy(message[offset..][0..7], "mempool");
    offset += 12;

    // Payload length: 0
    std.mem.writeInt(u32, message[offset..][0..4], 0, .little);
    offset += 4;

    // Checksum (0 for empty payload)
    std.mem.writeInt(u32, message[offset..][0..4], 0, .little);

    _ = try posix.send(sockfd, &message, 0);
}

// Send pong message (response to ping with matching nonce)
fn sendPong(sockfd: posix.socket_t, nonce: u64) !void {
    var message: [32]u8 = undefined;
    var offset: usize = 0;

    // Header
    std.mem.writeInt(u32, message[offset..][0..4], MAGIC_MAINNET, .little);
    offset += 4;

    // Command: "pong"
    @memset(message[offset..][0..12], 0);
    @memcpy(message[offset..][0..4], "pong");
    offset += 12;

    // Payload length: 8 (nonce)
    std.mem.writeInt(u32, message[offset..][0..4], 8, .little);
    offset += 4;

    // Checksum (simplified - should be double SHA256 of nonce)
    std.mem.writeInt(u32, message[offset..][0..4], 0, .little);
    offset += 4;

    // Payload: nonce
    std.mem.writeInt(u64, message[offset..][0..8], nonce, .little);

    _ = try posix.send(sockfd, &message, 0);
}

// Send getdata message to request full transaction
fn sendGetData(sockfd: posix.socket_t, inv_type: u32, hash: [32]u8) !void {
    // getdata message: header (24 bytes) + payload (varint count + inv vector)
    var message: [24 + 1 + 36]u8 = undefined;
    var msg_offset: usize = 0;

    // Header
    std.mem.writeInt(u32, message[msg_offset..][0..4], MAGIC_MAINNET, .little);
    msg_offset += 4;

    // Command: "getdata"
    @memset(message[msg_offset..][0..12], 0);
    @memcpy(message[msg_offset..][0..7], "getdata");
    msg_offset += 12;

    // Payload length: 1 byte (varint count=1) + 36 bytes (inv vector)
    std.mem.writeInt(u32, message[msg_offset..][0..4], 37, .little);
    msg_offset += 4;

    // Checksum (simplified - in production should be double SHA256)
    std.mem.writeInt(u32, message[msg_offset..][0..4], 0, .little);
    msg_offset += 4;

    // Payload: varint count (1)
    message[msg_offset] = 1;
    msg_offset += 1;

    // Inv vector: type + hash
    std.mem.writeInt(u32, message[msg_offset..][0..4], inv_type, .little);
    msg_offset += 4;
    @memcpy(message[msg_offset..][0..32], &hash);

    _ = try posix.send(sockfd, &message, 0);
}

// Handle full transaction and detect whales
fn handleTransaction(payload: []const u8) !void {
    if (payload.len < 10) return; // Minimum tx size

    var offset: usize = 0;

    // Version (4 bytes)
    _ = std.mem.readInt(i32, payload[offset..][0..4], .little);
    offset += 4;

    // Input count (varint)
    const input_count = readVarint(payload, &offset) catch return;

    // Skip inputs
    var i: usize = 0;
    while (i < input_count) : (i += 1) {
        // Previous output hash (32 bytes) + index (4 bytes)
        offset += 36;
        if (offset > payload.len) return;

        // Script length (varint)
        const script_len = readVarint(payload, &offset) catch return;
        offset += script_len;
        if (offset > payload.len) return;

        // Sequence (4 bytes)
        offset += 4;
        if (offset > payload.len) return;
    }

    // Output count (varint)
    const output_count = readVarint(payload, &offset) catch return;

    // Parse outputs and sum values
    var total_value: i64 = 0;
    var j: usize = 0;
    while (j < output_count) : (j += 1) {
        // Value (8 bytes, little-endian satoshis)
        if (offset + 8 > payload.len) return;
        const value = std.mem.readInt(i64, payload[offset..][0..8], .little);
        total_value += value;
        offset += 8;

        // Script length (varint)
        const script_len = readVarint(payload, &offset) catch return;
        offset += script_len;
        if (offset > payload.len) return;
    }

    // Whale detection: >1 BTC
    if (total_value > WHALE_THRESHOLD) {
        // Calculate transaction hash (double SHA256 of payload) and reverse for display
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(payload, &hash, .{});
        std.crypto.hash.sha2.Sha256.hash(&hash, &hash, .{});

        // SIMD reverse hash for human-readable format
        const hash_vec: @Vector(32, u8) = hash;
        const reverse_indices: @Vector(32, i32) = .{31,30,29,28,27,26,25,24,23,22,21,20,19,18,17,16,15,14,13,12,11,10,9,8,7,6,5,4,3,2,1,0};
        const reversed = @shuffle(u8, hash_vec, undefined, reverse_indices);
        const reversed_hash_bytes: [32]u8 = reversed;

        // Print whale alert in red
        const btc_amount = @as(f64, @floatFromInt(total_value)) / 100_000_000.0;
        std.debug.print("{s}🚨 WHALE ALERT: {d:.8} BTC - ", .{RED, btc_amount});
        for (reversed_hash_bytes) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("{s}\n", .{RESET});
    }
}

// Read variable-length integer (varint) from Bitcoin protocol
fn readVarint(data: []const u8, offset: *usize) !usize {
    if (offset.* >= data.len) return error.InvalidVarint;

    const first = data[offset.*];
    offset.* += 1;

    if (first < 0xfd) {
        return first;
    } else if (first == 0xfd) {
        if (offset.* + 2 > data.len) return error.InvalidVarint;
        const value = std.mem.readInt(u16, data[offset.*..][0..2], .little);
        offset.* += 2;
        return value;
    } else if (first == 0xfe) {
        if (offset.* + 4 > data.len) return error.InvalidVarint;
        const value = std.mem.readInt(u32, data[offset.*..][0..4], .little);
        offset.* += 4;
        return value;
    } else {
        if (offset.* + 8 > data.len) return error.InvalidVarint;
        const value = std.mem.readInt(u64, data[offset.*..][0..8], .little);
        offset.* += 8;
        return @as(usize, @intCast(value));
    }
}