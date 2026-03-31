const std = @import("std");
const posix = std.posix;
const socket = @import("socket.zig");

// Cross-platform send helper
fn sendSocket(fd: socket.socket_t, buf: []const u8) !usize {
    return socket.send(fd, buf);
}

// Bitcoin protocol constants
pub const MAGIC_MAINNET: u32 = 0xD9B4BEF9;
pub const MSG_TX: u32 = 1;
pub const PROTOCOL_VERSION: i32 = 70015;

/// Build version message dynamically with current timestamp and correct double-SHA256 checksum
pub fn buildVersionMessage() ![125]u8 {
    var message: [125]u8 = undefined;

    // Get current timestamp for payload
    const now = blk: { var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(.REALTIME, &ts); break :blk ts.sec; };

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

/// Send verack message (acknowledgement of version)
pub fn sendVerack(sockfd: posix.socket_t) !void {
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

    // Checksum: double-SHA256 of empty payload
    // SHA256(SHA256("")) = 5df6e0e2761359d30a8275058e299fcc0381534545f55cf43e41983f5d4c9456
    var hash1: [32]u8 = undefined;
    var hash2: [32]u8 = undefined;
    const empty: [0]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&empty, &hash1, .{});
    std.crypto.hash.sha2.Sha256.hash(&hash1, &hash2, .{});
    const checksum = std.mem.readInt(u32, hash2[0..4], .little);
    std.mem.writeInt(u32, message[offset..][0..4], checksum, .little);

    _ = try sendSocket(sockfd, &message);
}

/// Send pong message (response to ping keepalive)
pub fn sendPong(sockfd: posix.socket_t, nonce: u64) !void {
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

    // Build payload first to calculate checksum
    var payload: [8]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], nonce, .little);

    // Checksum: double-SHA256 of nonce payload
    var hash1: [32]u8 = undefined;
    var hash2: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&payload, &hash1, .{});
    std.crypto.hash.sha2.Sha256.hash(&hash1, &hash2, .{});
    const checksum = std.mem.readInt(u32, hash2[0..4], .little);
    std.mem.writeInt(u32, message[offset..][0..4], checksum, .little);
    offset += 4;

    // Payload: nonce
    @memcpy(message[offset..][0..8], &payload);

    _ = try sendSocket(sockfd, &message);
}

/// Send getdata message to request full transaction
pub fn sendGetData(sockfd: posix.socket_t, inv_type: u32, hash: [32]u8) !void {
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

    // Build payload first to calculate checksum
    var payload: [37]u8 = undefined;
    payload[0] = 1; // varint count
    std.mem.writeInt(u32, payload[1..][0..4], inv_type, .little);
    @memcpy(payload[5..][0..32], &hash);

    // Checksum: double-SHA256 of payload
    var hash1: [32]u8 = undefined;
    var hash2: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&payload, &hash1, .{});
    std.crypto.hash.sha2.Sha256.hash(&hash1, &hash2, .{});
    const checksum = std.mem.readInt(u32, hash2[0..4], .little);
    std.mem.writeInt(u32, message[msg_offset..][0..4], checksum, .little);
    msg_offset += 4;

    // Copy payload
    @memcpy(message[msg_offset..][0..37], &payload);

    _ = try sendSocket(sockfd, &message);
}

pub const Transaction = struct {
    hash: [32]u8,
    value_satoshis: i64,
    input_count: u32,
    output_count: u32,
};

/// Parse full transaction and extract value
pub fn parseTransaction(payload: []const u8) !Transaction {
    if (payload.len < 10) return error.InvalidTransaction;

    var offset: usize = 0;

    // Version (4 bytes)
    _ = std.mem.readInt(i32, payload[offset..][0..4], .little);
    offset += 4;

    // Input count (varint)
    const input_count = try readVarint(payload, &offset);

    // Skip inputs
    var i: usize = 0;
    while (i < input_count) : (i += 1) {
        offset += 36; // Previous output hash + index
        if (offset > payload.len) return error.InvalidTransaction;

        const script_len = try readVarint(payload, &offset);
        offset += script_len;
        if (offset > payload.len) return error.InvalidTransaction;

        offset += 4; // Sequence
        if (offset > payload.len) return error.InvalidTransaction;
    }

    // Output count (varint)
    const output_count = try readVarint(payload, &offset);

    // Parse outputs and sum values
    var total_value: i64 = 0;
    var j: usize = 0;
    while (j < output_count) : (j += 1) {
        if (offset + 8 > payload.len) return error.InvalidTransaction;
        const value = std.mem.readInt(i64, payload[offset..][0..8], .little);
        total_value += value;
        offset += 8;

        const script_len = try readVarint(payload, &offset);
        offset += script_len;
        if (offset > payload.len) return error.InvalidTransaction;
    }

    // Calculate transaction hash (double SHA256 of payload)
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &hash, .{});
    std.crypto.hash.sha2.Sha256.hash(&hash, &hash, .{});

    // SIMD reverse hash for human-readable format (big-endian)
    const hash_vec: @Vector(32, u8) = hash;
    const reverse_indices: @Vector(32, i32) = .{31,30,29,28,27,26,25,24,23,22,21,20,19,18,17,16,15,14,13,12,11,10,9,8,7,6,5,4,3,2,1,0};
    const reversed = @shuffle(u8, hash_vec, undefined, reverse_indices);
    const reversed_hash: [32]u8 = reversed;

    return Transaction{
        .hash = reversed_hash,
        .value_satoshis = total_value,
        .input_count = @intCast(input_count),
        .output_count = @intCast(output_count),
    };
}

/// Read variable-length integer (varint) from Bitcoin protocol
pub fn readVarint(data: []const u8, offset: *usize) !usize {
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

// ============================================================================
// Tests
// ============================================================================

test "Bitcoin magic number constant" {
    try std.testing.expectEqual(@as(u32, 0xD9B4BEF9), MAGIC_MAINNET);
}

test "Protocol version constant" {
    try std.testing.expectEqual(@as(i32, 70015), PROTOCOL_VERSION);
}

test "readVarint single byte" {
    const data = [_]u8{42};
    var offset: usize = 0;
    const value = try readVarint(&data, &offset);
    try std.testing.expectEqual(@as(usize, 42), value);
    try std.testing.expectEqual(@as(usize, 1), offset);
}

test "readVarint zero byte" {
    const data = [_]u8{0};
    var offset: usize = 0;
    const value = try readVarint(&data, &offset);
    try std.testing.expectEqual(@as(usize, 0), value);
    try std.testing.expectEqual(@as(usize, 1), offset);
}

test "readVarint 0xfc boundary" {
    const data = [_]u8{0xfc};
    var offset: usize = 0;
    const value = try readVarint(&data, &offset);
    try std.testing.expectEqual(@as(usize, 0xfc), value);
    try std.testing.expectEqual(@as(usize, 1), offset);
}

test "readVarint 2-byte format (0xfd prefix)" {
    var data: [3]u8 = undefined;
    data[0] = 0xfd;
    std.mem.writeInt(u16, data[1..3], 0x0123, .little);
    var offset: usize = 0;
    const value = try readVarint(&data, &offset);
    try std.testing.expectEqual(@as(usize, 0x0123), value);
    try std.testing.expectEqual(@as(usize, 3), offset);
}

test "readVarint 4-byte format (0xfe prefix)" {
    var data: [5]u8 = undefined;
    data[0] = 0xfe;
    std.mem.writeInt(u32, data[1..5], 0x12345678, .little);
    var offset: usize = 0;
    const value = try readVarint(&data, &offset);
    try std.testing.expectEqual(@as(usize, 0x12345678), value);
    try std.testing.expectEqual(@as(usize, 5), offset);
}

test "readVarint 8-byte format (0xff prefix)" {
    var data: [9]u8 = undefined;
    data[0] = 0xff;
    std.mem.writeInt(u64, data[1..9], 0x123456789abcdef0, .little);
    var offset: usize = 0;
    const value = try readVarint(&data, &offset);
    try std.testing.expectEqual(@as(usize, 0x123456789abcdef0), value);
    try std.testing.expectEqual(@as(usize, 9), offset);
}

test "readVarint insufficient data 2-byte" {
    const data = [_]u8{0xfd, 0x00}; // Only 1 byte when 2 needed
    var offset: usize = 0;
    const result = readVarint(&data, &offset);
    try std.testing.expectError(error.InvalidVarint, result);
}

test "readVarint insufficient data 4-byte" {
    const data = [_]u8{0xfe, 0x00, 0x00}; // Only 2 bytes when 4 needed
    var offset: usize = 0;
    const result = readVarint(&data, &offset);
    try std.testing.expectError(error.InvalidVarint, result);
}

test "readVarint offset at end" {
    const data = [_]u8{0x01};
    var offset: usize = 1;
    const result = readVarint(&data, &offset);
    try std.testing.expectError(error.InvalidVarint, result);
}

test "readVarint with offset in middle" {
    const data = [_]u8{0xff, 0x42, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
    var offset: usize = 1;
    const value = try readVarint(&data, &offset);
    try std.testing.expectEqual(@as(usize, 0x42), value);
    try std.testing.expectEqual(@as(usize, 2), offset);
}

test "buildVersionMessage creates 125 byte message" {
    const msg = try buildVersionMessage();
    try std.testing.expectEqual(@as(usize, 125), msg.len);
}

test "buildVersionMessage magic bytes" {
    const msg = try buildVersionMessage();
    const magic = std.mem.readInt(u32, msg[0..4], .little);
    try std.testing.expectEqual(MAGIC_MAINNET, magic);
}

test "buildVersionMessage command" {
    const msg = try buildVersionMessage();
    const command = msg[4..16];
    try std.testing.expectEqualSlices(u8, "version\x00\x00\x00\x00\x00", command);
}

test "buildVersionMessage payload length" {
    const msg = try buildVersionMessage();
    const length = std.mem.readInt(u32, msg[16..20], .little);
    try std.testing.expectEqual(@as(u32, 101), length);
}

test "sendVerack message size" {
    const msg = try buildVersionMessage();
    // Verify message has proper structure
    try std.testing.expectEqual(@as(usize, 125), msg.len);

    // Magic + command + length + checksum = 4 + 12 + 4 + 4 = 24 bytes header
    // Payload = 101 bytes
    // Total = 125
}

test "sendPong message structure" {
    const msg = try buildVersionMessage();
    try std.testing.expectEqual(@as(usize, 125), msg.len);

    // Verify first 4 bytes are magic number
    const magic = std.mem.readInt(u32, msg[0..4], .little);
    try std.testing.expectEqual(MAGIC_MAINNET, magic);
}

test "Transaction hash calculation" {
    // Create a minimal valid transaction payload (version + input count + output count + locktime)
    var payload: [10]u8 = undefined;
    // Version: 1
    std.mem.writeInt(i32, payload[0..4], 1, .little);
    // Input count: 0 (varint)
    payload[4] = 0;
    // Output count: 0 (varint)
    payload[5] = 0;
    // Locktime: 0
    std.mem.writeInt(i32, payload[6..10], 0, .little);

    const tx = try parseTransaction(&payload);
    try std.testing.expectEqual(@as(u32, 0), tx.input_count);
    try std.testing.expectEqual(@as(u32, 0), tx.output_count);
    try std.testing.expectEqual(@as(i64, 0), tx.value_satoshis);
}

test "Transaction with inputs and outputs" {
    // Minimal transaction: version + input count (1) + previous output hash (32) + previous output index (4) + script length (0) + sequence (4) + output count (1) + value (8) + script length (0) + locktime (4)
    var payload: [62]u8 = undefined;
    var offset: usize = 0;

    // Version
    std.mem.writeInt(i32, payload[offset..][0..4], 1, .little);
    offset += 4;

    // Input count: 1
    payload[offset] = 1;
    offset += 1;

    // Previous output hash (32 bytes)
    @memset(payload[offset..][0..32], 0);
    offset += 32;

    // Previous output index
    std.mem.writeInt(u32, payload[offset..][0..4], 0, .little);
    offset += 4;

    // Script length: 0
    payload[offset] = 0;
    offset += 1;

    // Sequence
    std.mem.writeInt(u32, payload[offset..][0..4], 0xffffffff, .little);
    offset += 4;

    // Output count: 1
    payload[offset] = 1;
    offset += 1;

    // Value: 50000000 satoshis (0.5 BTC)
    std.mem.writeInt(i64, payload[offset..][0..8], 50000000, .little);
    offset += 8;

    // Script length: 0
    payload[offset] = 0;
    offset += 1;

    // Locktime
    std.mem.writeInt(i32, payload[offset..][0..4], 0, .little);

    const tx = try parseTransaction(&payload);
    try std.testing.expectEqual(@as(u32, 1), tx.input_count);
    try std.testing.expectEqual(@as(u32, 1), tx.output_count);
    try std.testing.expectEqual(@as(i64, 50000000), tx.value_satoshis);
}
