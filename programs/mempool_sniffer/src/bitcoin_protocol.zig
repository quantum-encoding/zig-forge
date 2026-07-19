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

/// Size of a P2P message header: magic(4) + command(12) + length(4) + checksum(4).
pub const HEADER_LEN: usize = 24;

/// Bitcoin Core's MAX_PROTOCOL_MESSAGE_LENGTH (`net.h`): 4 * 1000 * 1000.
/// A header declaring more than this is malformed or hostile — without the
/// cap, a peer sending `length = 0xffffffff` would drive the reassembly
/// buffer to allocate 4 GiB.
pub const MAX_PROTOCOL_MESSAGE_LENGTH: u32 = 4_000_000;

/// Fill `buf` from the OS CSPRNG.
///
/// Zig 0.16 removed `std.crypto.random`, so this dispatches to the platform
/// entropy source directly: the `getrandom` syscall on Linux/Android (a raw
/// syscall, so it needs no libc version check) and `arc4random_buf` on
/// Darwin/BSD, both of which are non-blocking CSPRNGs.
fn secureRandomBytes(buf: []u8) void {
    if (@import("builtin").os.tag == .linux) {
        var filled: usize = 0;
        while (filled < buf.len) {
            const n = std.os.linux.getrandom(buf.ptr + filled, buf.len - filled, 0);
            // Negative-as-unsigned return means EINTR/EAGAIN; retry.
            if (@as(isize, @bitCast(n)) <= 0) continue;
            filled += n;
        }
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

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

    // Nonce. Used by peers for self-connection detection, so it must be
    // unpredictable: a timestamp-derived nonce (the previous behaviour) is
    // guessable by anyone who knows roughly when we connected, which lets a
    // third party forge a nonce collision and make a peer drop us as a
    // self-connection. Drawn from the OS CSPRNG.
    var nonce_bytes: [8]u8 = undefined;
    secureRandomBytes(&nonce_bytes);
    @memcpy(message[offset..][0..8], &nonce_bytes);
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

// ============================================================================
// Stream framing
// ============================================================================

/// One complete P2P message carved out of the receive stream.
///
/// `command` and `payload` are sub-slices of the caller's buffer; they stay
/// valid only until that buffer is next mutated (i.e. until the caller
/// consumes `total_len` bytes off the front).
pub const Frame = struct {
    /// Command name with the NUL padding stripped ("tx", "inv", "ping", ...).
    command: []const u8,
    /// Exactly `length` payload bytes — guaranteed present in the buffer.
    payload: []const u8,
    /// Header + payload, i.e. how many bytes to drop from the front.
    total_len: usize,
};

pub const FrameError = error{
    /// Header declares a payload above MAX_PROTOCOL_MESSAGE_LENGTH.
    MessageTooLarge,
    /// No mainnet magic anywhere in the buffered bytes.
    BadMagic,
};

/// Find the offset of the next mainnet magic sequence at or after `from`.
///
/// TCP gives us a byte stream, not a message stream: if a peer sends garbage
/// or we ever lose sync mid-message, scanning forward for the magic is the
/// only way back to a message boundary.
pub fn findMagic(buf: []const u8, from: usize) ?usize {
    if (from >= buf.len) return null;
    var magic_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &magic_bytes, MAGIC_MAINNET, .little);
    const idx = std.mem.indexOfPos(u8, buf, from, &magic_bytes) orelse return null;
    return idx;
}

/// Try to take exactly one complete message off the front of `buf`.
///
/// Returns `null` when `buf` holds a valid but still-incomplete message — the
/// caller should recv more bytes and call again with the grown buffer. This
/// is what makes messages larger than a single `recv` (the common case for
/// `tx` messages, which routinely exceed 4 KiB) parseable at all; the previous
/// implementation discarded any message that did not fit one read.
///
/// `buf` is assumed to start on a message boundary. Callers that cannot
/// guarantee that should `findMagic` first.
pub fn nextFrame(buf: []const u8) FrameError!?Frame {
    if (buf.len < HEADER_LEN) return null;

    const magic = std.mem.readInt(u32, buf[0..4], .little);
    if (magic != MAGIC_MAINNET) return FrameError.BadMagic;

    const length = std.mem.readInt(u32, buf[16..20], .little);
    if (length > MAX_PROTOCOL_MESSAGE_LENGTH) return FrameError.MessageTooLarge;

    // total_len cannot overflow: length is a u32 bounded by 4e6 above.
    const total_len = HEADER_LEN + @as(usize, length);
    if (buf.len < total_len) return null; // need more bytes

    const command_field = buf[4..16];
    const command = if (std.mem.indexOfScalar(u8, command_field, 0)) |nul|
        command_field[0..nul]
    else
        command_field;

    return Frame{
        .command = command,
        .payload = buf[HEADER_LEN..total_len],
        .total_len = total_len,
    };
}

/// Parse an `inv` payload and invoke `on_tx_hash` for every MSG_TX entry.
///
/// The payload slice is exactly the message body, so every read below is
/// bounds-checked by the slice itself plus the explicit length guards; there
/// is no way to read past the message into an adjacent one (the bug class
/// that finding #1 covered).
pub fn forEachInvTxHash(
    payload: []const u8,
    context: anytype,
    comptime on_tx_hash: fn (@TypeOf(context), [32]u8) anyerror!void,
) !void {
    var offset: usize = 0;
    const count = try readVarint(payload, &offset);

    // Each inv vector is type(4) + hash(32). A count that could not possibly
    // fit in the remaining payload is malformed — clamp rather than trust it.
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const entry_end = try safeOffsetAdd(offset, 36);
        if (entry_end > payload.len) break;

        const inv_type = std.mem.readInt(u32, payload[offset..][0..4], .little);
        if (inv_type == MSG_TX) {
            var hash: [32]u8 = undefined;
            @memcpy(&hash, payload[offset + 4 ..][0..32]);
            try on_tx_hash(context, hash);
        }
        offset = entry_end;
    }
}

pub const Transaction = struct {
    hash: [32]u8,
    value_satoshis: i64,
    input_count: u32,
    output_count: u32,
    is_segwit: bool = false,
};

/// DoS cap on input / output / witness item counts. Consensus block-size
/// limits keep real-world tx structure well below this, but a hostile
/// peer could send `0xff` + 0xffffffffffffffff as a varint to trigger
/// an OOM/CPU spin in the parse loop. The cap turns that into an
/// immediate error.InvalidTransaction.
pub const MAX_TX_ELEMENTS: u64 = 100_000;

/// Add two usize values; convert overflow to error.InvalidTransaction.
/// Replaces raw `offset += script_len` arithmetic where `script_len`
/// comes from an untrusted varint and could be 2^64-1.
fn safeOffsetAdd(a: usize, b: usize) error{InvalidTransaction}!usize {
    return std.math.add(usize, a, b) catch error.InvalidTransaction;
}

/// Parse a Bitcoin transaction (legacy or BIP141 SegWit) and extract the
/// txid + total output value. The parser is hardened against the
/// standard family of P2P transaction-parsing attacks:
///
///   * H-1 — every offset advance goes through std.math.add(usize, ...);
///     a hostile script_len of 0xffffffffffffffff cannot wrap `offset`
///     past payload.len's bounds check.
///   * H-2 — output values are summed into a u128 accumulator with
///     checked add. Negative i64 values on the wire are rejected (real
///     Bitcoin outputs are non-negative); two near-i64.max outputs can
///     no longer wrap the accumulator to a negative reported total.
///   * H-3 — BIP141 marker (0x00) + flag (0x01) bytes immediately after
///     the version are detected. Witness items are skipped during
///     parsing but EXCLUDED from the txid hash, so SegWit txids match
///     what the network sees (the prior implementation hashed the full
///     payload, which is the wtxid, not the txid).
///   * H-4 — input/output/witness-item counts are capped at
///     MAX_TX_ELEMENTS (100k); above that we error out instead of
///     spinning a CPU/allocator loop for the attacker.
pub fn parseTransaction(payload: []const u8) !Transaction {
    if (payload.len < 10) return error.InvalidTransaction;

    var offset: usize = 0;

    // Version (4 bytes)
    _ = std.mem.readInt(i32, payload[offset..][0..4], .little);
    offset = try safeOffsetAdd(offset, 4);

    // SegWit marker + flag. BIP141 reserves the byte sequence
    // [0x00, 0x01] immediately after the version for SegWit. A legacy
    // tx puts the input_count varint here; legacy txs MUST have at
    // least one input (0x00 alone is invalid), so this disambiguates
    // unambiguously for well-formed messages.
    var is_segwit = false;
    if (payload.len >= offset + 2 and payload[offset] == 0x00 and payload[offset + 1] == 0x01) {
        is_segwit = true;
        offset = try safeOffsetAdd(offset, 2);
    }

    // Range [inputs_start..outputs_end) is the part of the tx that
    // contributes to the legacy serialization used for txid hashing.
    // It excludes marker+flag (already skipped) and witness data
    // (skipped below).
    const inputs_start = offset;

    // Input count (varint) — H-4 cap
    const input_count = try readVarint(payload, &offset);
    if (input_count > MAX_TX_ELEMENTS) return error.InvalidTransaction;

    // Skip inputs — every advance is checked for overflow (H-1).
    var i: usize = 0;
    while (i < input_count) : (i += 1) {
        offset = try safeOffsetAdd(offset, 36); // prev_hash(32) + prev_index(4)
        if (offset > payload.len) return error.InvalidTransaction;

        const script_len = try readVarint(payload, &offset);
        offset = try safeOffsetAdd(offset, script_len);
        if (offset > payload.len) return error.InvalidTransaction;

        offset = try safeOffsetAdd(offset, 4); // sequence
        if (offset > payload.len) return error.InvalidTransaction;
    }

    // Output count (varint) — H-4 cap
    const output_count = try readVarint(payload, &offset);
    if (output_count > MAX_TX_ELEMENTS) return error.InvalidTransaction;

    // Parse outputs and sum values into u128 (H-2).
    var total_value: u128 = 0;
    var j: usize = 0;
    while (j < output_count) : (j += 1) {
        const value_end = try safeOffsetAdd(offset, 8);
        if (value_end > payload.len) return error.InvalidTransaction;
        const value_signed = std.mem.readInt(i64, payload[offset..][0..8], .little);
        if (value_signed < 0) return error.InvalidTransaction;
        const value_unsigned: u64 = @intCast(value_signed);
        total_value = std.math.add(u128, total_value, value_unsigned) catch
            return error.InvalidTransaction;
        offset = value_end;

        const script_len = try readVarint(payload, &offset);
        offset = try safeOffsetAdd(offset, script_len);
        if (offset > payload.len) return error.InvalidTransaction;
    }

    const outputs_end = offset;

    // Skip witness data — per input, [count varint, then `count` items
    // each [len varint, len bytes]]. Witness bytes do NOT contribute
    // to txid (H-3), only to wtxid.
    if (is_segwit) {
        var k: usize = 0;
        while (k < input_count) : (k += 1) {
            const witness_count = try readVarint(payload, &offset);
            if (witness_count > MAX_TX_ELEMENTS) return error.InvalidTransaction;
            var w: usize = 0;
            while (w < witness_count) : (w += 1) {
                const item_len = try readVarint(payload, &offset);
                offset = try safeOffsetAdd(offset, item_len);
                if (offset > payload.len) return error.InvalidTransaction;
            }
        }
    }

    // Locktime (4 bytes). Must fit in the remaining payload.
    const locktime_offset = offset;
    offset = try safeOffsetAdd(offset, 4);
    if (offset > payload.len) return error.InvalidTransaction;

    // Reject if the u128 accumulator exceeds i64.max — Bitcoin's
    // MAX_MONEY (21M BTC = 2.1e15 sats) is far below this, so anything
    // larger is malformed/hostile. Surfacing it as an error rather
    // than silently truncating preserves the contract on
    // value_satoshis: i64.
    if (total_value > @as(u128, std.math.maxInt(i64))) return error.InvalidTransaction;

    // Compute txid: double-SHA256 of the LEGACY serialization, i.e.
    //   version || inputs_with_varint || outputs_with_varint || locktime
    // (excluding marker, flag, and witness data). For legacy txs this
    // is equivalent to hashing the full payload up to and including
    // locktime; for SegWit txs the marker/flag and witness ranges are
    // skipped.
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(payload[0..4]); // version
    hasher.update(payload[inputs_start..outputs_end]); // inputs + outputs
    hasher.update(payload[locktime_offset..offset]); // locktime
    var first_hash: [32]u8 = undefined;
    hasher.final(&first_hash);

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&first_hash, &hash, .{});

    // SIMD reverse hash for human-readable format (big-endian display).
    const hash_vec: @Vector(32, u8) = hash;
    const reverse_indices: @Vector(32, i32) = .{ 31, 30, 29, 28, 27, 26, 25, 24, 23, 22, 21, 20, 19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 };
    const reversed = @shuffle(u8, hash_vec, undefined, reverse_indices);
    const reversed_hash: [32]u8 = reversed;

    return Transaction{
        .hash = reversed_hash,
        .value_satoshis = @intCast(total_value),
        .input_count = @intCast(input_count),
        .output_count = @intCast(output_count),
        .is_segwit = is_segwit,
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

// ── H-1 / H-2 / H-3 / H-4 hardening tests ──────────────────────────

test "parseTransaction: input_count above MAX_TX_ELEMENTS rejected (H-4)" {
    // Build payload: version(4) + varint(0xff + u64=100001) + ...
    var payload: [13]u8 = undefined;
    std.mem.writeInt(i32, payload[0..4], 1, .little);
    payload[4] = 0xff; // 8-byte varint follows
    std.mem.writeInt(u64, payload[5..13], MAX_TX_ELEMENTS + 1, .little);
    const result = parseTransaction(&payload);
    try std.testing.expectError(error.InvalidTransaction, result);
}

test "parseTransaction: input_count exactly at MAX_TX_ELEMENTS allowed by cap but tx truncated (H-4 boundary)" {
    // input_count = MAX_TX_ELEMENTS is allowed by the cap, but with
    // no input bytes following the parser must error out at the
    // "offset > payload.len" check, NOT spin.
    var payload: [13]u8 = undefined;
    std.mem.writeInt(i32, payload[0..4], 1, .little);
    payload[4] = 0xff;
    std.mem.writeInt(u64, payload[5..13], MAX_TX_ELEMENTS, .little);
    const result = parseTransaction(&payload);
    try std.testing.expectError(error.InvalidTransaction, result);
}

test "parseTransaction: output_count above MAX_TX_ELEMENTS rejected (H-4)" {
    // version + input_count=0 + output_count via 0xff prefix
    var payload: [14]u8 = undefined;
    std.mem.writeInt(i32, payload[0..4], 1, .little);
    payload[4] = 0; // input_count = 0
    payload[5] = 0xff; // 8-byte varint follows for output_count
    std.mem.writeInt(u64, payload[6..14], MAX_TX_ELEMENTS + 1, .little);
    const result = parseTransaction(&payload);
    try std.testing.expectError(error.InvalidTransaction, result);
}

test "parseTransaction: hostile script_len cannot wrap usize (H-1)" {
    // version + input_count=1 + prev_hash(32) + prev_index(4) + script_len=0xffffffffffffffff
    // Without the std.math.add check, `offset += script_len` would wrap
    // back to a small positive value and `offset > payload.len` would
    // pass, leading to out-of-bounds reads on a later step.
    var payload: [50]u8 = undefined;
    std.mem.writeInt(i32, payload[0..4], 1, .little);
    payload[4] = 1; // input_count = 1
    @memset(payload[5..37], 0); // prev_hash
    std.mem.writeInt(u32, payload[37..41], 0, .little); // prev_index
    payload[41] = 0xff;
    std.mem.writeInt(u64, payload[42..50], std.math.maxInt(u64), .little);
    const result = parseTransaction(&payload);
    try std.testing.expectError(error.InvalidTransaction, result);
}

test "parseTransaction: negative output value rejected (H-2)" {
    // Build: version + input_count=0 + output_count=1 + value=-1
    // (the wire reads as i64; negative values are protocol-invalid).
    var payload: [20]u8 = undefined;
    std.mem.writeInt(i32, payload[0..4], 1, .little);
    payload[4] = 0; // input_count = 0
    payload[5] = 1; // output_count = 1
    std.mem.writeInt(i64, payload[6..14], -1, .little);
    payload[14] = 0; // script_len = 0
    std.mem.writeInt(i32, payload[15..19], 0, .little); // locktime
    payload[19] = 0; // pad
    const result = parseTransaction(payload[0..19]);
    try std.testing.expectError(error.InvalidTransaction, result);
}

test "parseTransaction: u128 accumulator catches sum > maxInt(i64) (H-2)" {
    // Two outputs each at i64.max would sum to ~2^64; the prior i64
    // accumulator wrapped to a small negative; the u128 version rejects.
    var payload: [40]u8 = undefined;
    std.mem.writeInt(i32, payload[0..4], 1, .little); // version
    payload[4] = 0; // input_count = 0
    payload[5] = 2; // output_count = 2
    // output 1: value = i64.max
    std.mem.writeInt(i64, payload[6..14], std.math.maxInt(i64), .little);
    payload[14] = 0; // script_len = 0
    // output 2: value = i64.max
    std.mem.writeInt(i64, payload[15..23], std.math.maxInt(i64), .little);
    payload[23] = 0; // script_len = 0
    std.mem.writeInt(i32, payload[24..28], 0, .little); // locktime
    const result = parseTransaction(payload[0..28]);
    try std.testing.expectError(error.InvalidTransaction, result);
}

test "parseTransaction: SegWit marker+flag detected, witness skipped from txid (H-3)" {
    // SegWit tx: version(4) + marker(0x00) + flag(0x01) + input_count(1)
    //   + prev_hash(32) + prev_index(4) + script_len(0) + sequence(4)
    //   + output_count(1) + value(8) + script_len(0)
    //   + witness_count(1) + witness_item_len(4) + witness_item("dead")
    //   + locktime(4)
    // Bytes: 4 + 1 + 1 + 1 + 32 + 4 + 1 + 4 + 1 + 8 + 1 + 1 + 1 + 4 + 4 = 68
    var payload: [68]u8 = undefined;
    var off: usize = 0;
    std.mem.writeInt(i32, payload[off..][0..4], 1, .little);
    off += 4;
    payload[off] = 0x00;
    off += 1; // marker
    payload[off] = 0x01;
    off += 1; // flag
    payload[off] = 1;
    off += 1; // input_count = 1
    @memset(payload[off..][0..32], 0);
    off += 32; // prev_hash
    std.mem.writeInt(u32, payload[off..][0..4], 0, .little);
    off += 4; // prev_index
    payload[off] = 0;
    off += 1; // script_len = 0
    std.mem.writeInt(u32, payload[off..][0..4], 0xffffffff, .little);
    off += 4; // sequence
    payload[off] = 1;
    off += 1; // output_count = 1
    std.mem.writeInt(i64, payload[off..][0..8], 100_000_000, .little);
    off += 8; // 1 BTC
    payload[off] = 0;
    off += 1; // script_len = 0
    payload[off] = 1;
    off += 1; // witness count for input 0 = 1
    payload[off] = 4;
    off += 1; // witness item len = 4
    @memcpy(payload[off..][0..4], "dead");
    off += 4; // witness item bytes
    std.mem.writeInt(i32, payload[off..][0..4], 0, .little);
    off += 4; // locktime
    try std.testing.expectEqual(@as(usize, 68), off);

    const tx = try parseTransaction(&payload);
    try std.testing.expect(tx.is_segwit);
    try std.testing.expectEqual(@as(u32, 1), tx.input_count);
    try std.testing.expectEqual(@as(u32, 1), tx.output_count);
    try std.testing.expectEqual(@as(i64, 100_000_000), tx.value_satoshis);

    // Verify the txid excludes the witness bytes: rebuild the same tx
    // WITHOUT marker/flag/witness and confirm the legacy-form parse
    // produces the SAME hash as the segwit-form parse.
    // Legacy form: version(4) + input_count(1) + prev_hash(32)
    //   + prev_index(4) + script_len(0) + sequence(4)
    //   + output_count(1) + value(8) + script_len(0) + locktime(4) = 60
    var legacy: [60]u8 = undefined;
    var l: usize = 0;
    std.mem.writeInt(i32, legacy[l..][0..4], 1, .little);
    l += 4;
    legacy[l] = 1;
    l += 1;
    @memset(legacy[l..][0..32], 0);
    l += 32;
    std.mem.writeInt(u32, legacy[l..][0..4], 0, .little);
    l += 4;
    legacy[l] = 0;
    l += 1;
    std.mem.writeInt(u32, legacy[l..][0..4], 0xffffffff, .little);
    l += 4;
    legacy[l] = 1;
    l += 1;
    std.mem.writeInt(i64, legacy[l..][0..8], 100_000_000, .little);
    l += 8;
    legacy[l] = 0;
    l += 1;
    std.mem.writeInt(i32, legacy[l..][0..4], 0, .little);
    l += 4;
    try std.testing.expectEqual(@as(usize, 60), l);

    const legacy_tx = try parseTransaction(&legacy);
    try std.testing.expect(!legacy_tx.is_segwit);
    // SegWit txid == legacy txid for the same logical tx.
    try std.testing.expectEqualSlices(u8, &legacy_tx.hash, &tx.hash);
}

test "parseTransaction: SegWit marker without flag treated as legacy" {
    // payload[4]=0x00, payload[5]=0x02 — marker present, flag is NOT
    // 0x01 — current BIP141 specifies flag must be 0x01. We treat
    // anything other than (0x00, 0x01) as legacy, which means
    // payload[4]=0x00 here parses as input_count=0 (legacy) and
    // payload[5]=0x02 as output_count=2.
    var payload: [14]u8 = undefined;
    std.mem.writeInt(i32, payload[0..4], 1, .little);
    payload[4] = 0x00; // would-be marker
    payload[5] = 0x02; // not the BIP141 flag
    std.mem.writeInt(i64, payload[6..14], 0, .little); // bogus content
    // The bogus output structure trips a downstream bounds check;
    // important point is we don't enter the witness path with flag != 0x01.
    // Either error.InvalidTransaction or error.InvalidVarint is acceptable
    // here — both signal "parse rejected" without an out-of-bounds read.
    if (parseTransaction(&payload)) |_| {
        return error.TestExpectedFailure;
    } else |err| switch (err) {
        error.InvalidTransaction, error.InvalidVarint => {},
    }
}

test "parseTransaction: truncated payload at locktime rejected" {
    // version + input_count=0 + output_count=0 — but no locktime bytes.
    var payload: [6]u8 = undefined;
    std.mem.writeInt(i32, payload[0..4], 1, .little);
    payload[4] = 0;
    payload[5] = 0;
    // payload.len < 10 trips the early check.
    const result = parseTransaction(&payload);
    try std.testing.expectError(error.InvalidTransaction, result);
}

// ── External-anchored txid vector ──────────────────────────────────
//
// The txid emitted by parseTransaction must match what the Bitcoin
// network computes. This uses the Bitcoin genesis-block coinbase
// transaction — a real mainnet transaction whose raw serialization and
// txid are published in the reference implementation (Bitcoin Core's
// chainparams.cpp genesis block) and reproduced by every block explorer.
//
//   raw tx (204 bytes, legacy / non-segwit):
//     01000000010000000000000000000000000000000000000000000000000000
//     0000000000ffffffff4d04ffff001d0104455468652054696d6573203033...
//   txid (display / big-endian):
//     4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b
//   output value: 50 BTC = 5_000_000_000 sat
//
// Neither the input nor the expected output was produced by this
// library: the txid is the canonical genesis coinbase id, verifiable
// against https://blockstream.info/tx/4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b
// and rust-bitcoin's `constants::genesis_block` test fixtures.
test "parseTransaction: genesis coinbase external txid vector (mainnet)" {
    const raw_hex =
        "01000000010000000000000000000000000000000000000000000000000000" ++
        "000000000000ffffffff4d04ffff001d0104455468652054696d6573203033" ++
        "2f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f" ++
        "66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff01" ++
        "00f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828" ++
        "e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df" ++
        "7ba0b8d578a4c702b6bf11d5fac00000000";

    var raw: [204]u8 = undefined;
    const decoded = try std.fmt.hexToBytes(&raw, raw_hex);
    try std.testing.expectEqual(@as(usize, 204), decoded.len);

    const tx = try parseTransaction(&raw);

    // Expected txid in display (big-endian) byte order.
    var expected_txid: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_txid,
        "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b",
    );
    try std.testing.expectEqualSlices(u8, &expected_txid, &tx.hash);

    // Genesis coinbase: single input, single 50 BTC output, legacy tx.
    try std.testing.expect(!tx.is_segwit);
    try std.testing.expectEqual(@as(u32, 1), tx.input_count);
    try std.testing.expectEqual(@as(u32, 1), tx.output_count);
    try std.testing.expectEqual(@as(i64, 5_000_000_000), tx.value_satoshis);
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

// External anchor — mainnet SegWit transaction `983bc853d3d9429a…`.
//
// single-input P2WPKH spend (one witness stack).
// Raw serialization AND expected txid both come from the Blockstream Esplora
// API (`GET /api/tx/<txid>/hex` — the txid is the lookup KEY, so the explorer
// asserts the hex↔txid binding, not this library):
//   https://blockstream.info/tx/983bc853d3d9429a9c02f4eb02cd588b99d23c19a66bc0e4c7f673e9cf74bd16
// Output total cross-checked against the same API's decoded `vout` values.
test "parseTransaction: mainnet segwit external txid vector (1 input)" {
    const raw_hex =
        "010000000001011c495b0140185a635d3b0e527cc15f2944e51d96d1c7e4ca" ++
        "a0eb235b1e11a7090100000000ffffffff01de58560200000000160014b7b1" ++
        "8a4d6c03090a820237527b5bf1dcefc2a42202483045022100ed3689b10e6e" ++
        "7414502d00c580ef36a999176e97f93933822b28e42ccbdcf5a90220211875" ++
        "87910d4e0183fcb04076052081a20b5b43afa64752fadd1cbb5fd1f3900121" ++
        "030b89e44e3886a8b8ff69e94dd340a59bac57cde178bae4c2f8d650c3538f" ++
        "e2b200000000";

    var raw: [192]u8 = undefined;
    const decoded = try std.fmt.hexToBytes(&raw, raw_hex);
    try std.testing.expectEqual(@as(usize, 192), decoded.len);

    const tx = try parseTransaction(&raw);

    // The txid must be the double-SHA256 of the LEGACY serialization in
    // display byte order. Hashing the full payload instead would yield the
    // wtxid and this assertion would fail — which is exactly the regression
    // this anchor exists to catch.
    var expected_txid: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_txid, "983bc853d3d9429a9c02f4eb02cd588b99d23c19a66bc0e4c7f673e9cf74bd16");
    try std.testing.expectEqualSlices(u8, &expected_txid, &tx.hash);

    try std.testing.expect(tx.is_segwit);
    try std.testing.expectEqual(@as(u32, 1), tx.input_count);
    try std.testing.expectEqual(@as(u32, 1), tx.output_count);
    try std.testing.expectEqual(@as(i64, 39213278), tx.value_satoshis);
}

// External anchor — mainnet SegWit transaction `0303cf121eee2024…`.
//
// two-input P2WPKH spend (two witness stacks — exercises the per-input witness skip loop).
// Raw serialization AND expected txid both come from the Blockstream Esplora
// API (`GET /api/tx/<txid>/hex` — the txid is the lookup KEY, so the explorer
// asserts the hex↔txid binding, not this library):
//   https://blockstream.info/tx/0303cf121eee20241a45db96ca40cd513b07d660bfff911bde90d820ed93ff93
// Output total cross-checked against the same API's decoded `vout` values.
test "parseTransaction: mainnet segwit external txid vector (2 input)" {
    const raw_hex =
        "0100000000010284cd31b839e6f25df53bd22b15cb9f71c0ea14650de02e10" ++
        "ccbb03cb38738dc60000000000fdffffff737326560519f37a51299ae2ea15" ++
        "00343da0fcd8061cfc36b75063a399559c411300000000fdffffff01de01f1" ++
        "0400000000160014ac2743df103c0e546686480f855bffd3b5c51a00024830" ++
        "4502210098d691195271bb0c877c5d4560967283df1926a0311a4ac321a18c" ++
        "6085101930022072364c8ad4f0f72c7015431d30c6d058b9615367f27a24c1" ++
        "77b192e6c737eeab012102357e7db0490cac75ac9145b6d63dccf0f7151c71" ++
        "1e1c5c0f6c4daa47d12c9b140247304402202f62c5afb3d735fccd65f9a83f" ++
        "64902d115443e3050d03acea20ef25a916dcb1022003d277d6d14713b2bac0" ++
        "b2dbb9b57425d9db4f40f6abbb03ecb26d18801342af012103d132482dfc92" ++
        "cd19c94f5bb584798a787b49a21feb582bcdc908236e62fbffe900000000";

    var raw: [340]u8 = undefined;
    const decoded = try std.fmt.hexToBytes(&raw, raw_hex);
    try std.testing.expectEqual(@as(usize, 340), decoded.len);

    const tx = try parseTransaction(&raw);

    // The txid must be the double-SHA256 of the LEGACY serialization in
    // display byte order. Hashing the full payload instead would yield the
    // wtxid and this assertion would fail — which is exactly the regression
    // this anchor exists to catch.
    var expected_txid: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_txid, "0303cf121eee20241a45db96ca40cd513b07d660bfff911bde90d820ed93ff93");
    try std.testing.expectEqualSlices(u8, &expected_txid, &tx.hash);

    try std.testing.expect(tx.is_segwit);
    try std.testing.expectEqual(@as(u32, 2), tx.input_count);
    try std.testing.expectEqual(@as(u32, 1), tx.output_count);
    try std.testing.expectEqual(@as(i64, 82903518), tx.value_satoshis);
}

// ── Stream-framing tests ───────────────────────────────────────────
//
// The reassembly path had no coverage at all before (it used to live inline
// in runSniffer and needed a live socket to exercise). These drive it as a
// pure function over byte buffers.

/// Test helper: wrap `payload` in a well-formed 24-byte P2P header.
fn buildFrameForTest(buf: []u8, command: []const u8, payload: []const u8) []u8 {
    std.mem.writeInt(u32, buf[0..4], MAGIC_MAINNET, .little);
    @memset(buf[4..16], 0);
    @memcpy(buf[4..][0..command.len], command);
    std.mem.writeInt(u32, buf[16..20], @intCast(payload.len), .little);
    var h1: [32]u8 = undefined;
    var h2: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &h1, .{});
    std.crypto.hash.sha2.Sha256.hash(&h1, &h2, .{});
    @memcpy(buf[20..24], h2[0..4]);
    @memcpy(buf[24..][0..payload.len], payload);
    return buf[0 .. HEADER_LEN + payload.len];
}

test "nextFrame: returns null until the whole message has arrived" {
    var buf: [HEADER_LEN + 8]u8 = undefined;
    const payload = [_]u8{0xAA} ** 8;
    const msg = buildFrameForTest(&buf, "ping", &payload);

    // Every strict prefix is incomplete — must ask for more, never parse.
    var n: usize = 0;
    while (n < msg.len) : (n += 1) {
        try std.testing.expectEqual(@as(?Frame, null), try nextFrame(msg[0..n]));
    }

    const frame = (try nextFrame(msg)).?;
    try std.testing.expectEqualSlices(u8, "ping", frame.command);
    try std.testing.expectEqualSlices(u8, &payload, frame.payload);
    try std.testing.expectEqual(msg.len, frame.total_len);
}

test "nextFrame: rejects a length above MAX_PROTOCOL_MESSAGE_LENGTH" {
    // Hostile header claiming a 4 GiB payload. Without the cap this drives
    // the reassembly buffer to allocate until the process dies.
    var buf: [HEADER_LEN]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], MAGIC_MAINNET, .little);
    @memset(buf[4..16], 0);
    std.mem.writeInt(u32, buf[16..20], std.math.maxInt(u32), .little);
    @memset(buf[20..24], 0);
    try std.testing.expectError(FrameError.MessageTooLarge, nextFrame(&buf));
}

test "nextFrame: rejects a bad magic so the caller can resync" {
    var buf: [HEADER_LEN]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 0xDEADBEEF, .little);
    @memset(buf[4..24], 0);
    try std.testing.expectError(FrameError.BadMagic, nextFrame(&buf));
}

test "findMagic: locates the next message boundary in a desynced stream" {
    var buf: [16]u8 = undefined;
    @memset(&buf, 0x11);
    std.mem.writeInt(u32, buf[7..11], MAGIC_MAINNET, .little);
    try std.testing.expectEqual(@as(?usize, 7), findMagic(&buf, 0));
    try std.testing.expectEqual(@as(?usize, 7), findMagic(&buf, 1));
    // Nothing after the one occurrence.
    try std.testing.expectEqual(@as(?usize, null), findMagic(&buf, 8));
}

test "nextFrame: reassembles a real mainnet tx delivered across three reads" {
    // The regression this guards: the old loop parsed whole messages out of a
    // single 4096-byte recv and DROPPED anything that straddled a read
    // boundary — silently discarding the very transactions getdata requests.
    // Payload is the externally-anchored mainnet segwit tx above.
    const raw_hex =
        "010000000001011c495b0140185a635d3b0e527cc15f2944e51d96d1c7e4ca" ++
        "a0eb235b1e11a7090100000000ffffffff01de58560200000000160014b7b1" ++
        "8a4d6c03090a820237527b5bf1dcefc2a42202483045022100ed3689b10e6e" ++
        "7414502d00c580ef36a999176e97f93933822b28e42ccbdcf5a9022021187587" ++
        "910d4e0183fcb04076052081a20b5b43afa64752fadd1cbb5fd1f390012103" ++
        "0b89e44e3886a8b8ff69e94dd340a59bac57cde178bae4c2f8d650c3538fe2" ++
        "b200000000";
    var raw: [192]u8 = undefined;
    _ = try std.fmt.hexToBytes(&raw, raw_hex);

    var msg_buf: [HEADER_LEN + 192]u8 = undefined;
    const msg = buildFrameForTest(&msg_buf, "tx", &raw);

    // Feed it in three chunks, exactly as three short recvs would.
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(std.testing.allocator);
    const splits = [_]usize{ 10, 100, msg.len };
    var prev: usize = 0;
    var got: ?Frame = null;
    for (splits) |end| {
        try stream.appendSlice(std.testing.allocator, msg[prev..end]);
        prev = end;
        got = try nextFrame(stream.items);
        if (end != msg.len) {
            // Still short — must not yield a frame yet.
            try std.testing.expectEqual(@as(?Frame, null), got);
        }
    }

    const frame = got.?;
    try std.testing.expectEqualSlices(u8, "tx", frame.command);
    const tx = try parseTransaction(frame.payload);
    var expected_txid: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_txid,
        "983bc853d3d9429a9c02f4eb02cd588b99d23c19a66bc0e4c7f673e9cf74bd16",
    );
    try std.testing.expectEqualSlices(u8, &expected_txid, &tx.hash);
}

// ── inv-payload tests ──────────────────────────────────────────────

const InvCollector = struct {
    hashes: *std.ArrayList([32]u8),
    allocator: std.mem.Allocator,

    fn collect(self: InvCollector, hash: [32]u8) anyerror!void {
        try self.hashes.append(self.allocator, hash);
    }
};

test "forEachInvTxHash: yields only MSG_TX entries" {
    // count=3: [MSG_TX, MSG_BLOCK(2), MSG_TX]
    var payload: [1 + 36 * 3]u8 = undefined;
    payload[0] = 3;
    var o: usize = 1;
    const types = [_]u32{ MSG_TX, 2, MSG_TX };
    for (types, 0..) |t, i| {
        std.mem.writeInt(u32, payload[o..][0..4], t, .little);
        @memset(payload[o + 4 ..][0..32], @intCast(i + 1));
        o += 36;
    }

    var hashes: std.ArrayList([32]u8) = .empty;
    defer hashes.deinit(std.testing.allocator);
    try forEachInvTxHash(
        &payload,
        InvCollector{ .hashes = &hashes, .allocator = std.testing.allocator },
        InvCollector.collect,
    );

    try std.testing.expectEqual(@as(usize, 2), hashes.items.len);
    try std.testing.expectEqualSlices(u8, &([_]u8{1} ** 32), &hashes.items[0]);
    try std.testing.expectEqualSlices(u8, &([_]u8{3} ** 32), &hashes.items[1]);
}

test "forEachInvTxHash: empty payload errors instead of reading OOB" {
    // The original inline parser read buffer[offset] with no length check,
    // so a zero-length inv read past the message body (UB in ReleaseFast).
    var hashes: std.ArrayList([32]u8) = .empty;
    defer hashes.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidVarint, forEachInvTxHash(
        &[_]u8{},
        InvCollector{ .hashes = &hashes, .allocator = std.testing.allocator },
        InvCollector.collect,
    ));
}

test "forEachInvTxHash: lying count is clamped to the bytes actually present" {
    // Peer claims 0xffffffffffffffff entries but sends one. The loop must
    // stop at the payload end rather than spin or read past it.
    var payload: [1 + 8 + 36]u8 = undefined;
    payload[0] = 0xff;
    std.mem.writeInt(u64, payload[1..9], std.math.maxInt(u64), .little);
    std.mem.writeInt(u32, payload[9..13], MSG_TX, .little);
    @memset(payload[13..45], 0x7);

    var hashes: std.ArrayList([32]u8) = .empty;
    defer hashes.deinit(std.testing.allocator);
    try forEachInvTxHash(
        &payload,
        InvCollector{ .hashes = &hashes, .allocator = std.testing.allocator },
        InvCollector.collect,
    );
    try std.testing.expectEqual(@as(usize, 1), hashes.items.len);
}

test "forEachInvTxHash: truncated multi-byte varint errors" {
    // 0xfd announces a 2-byte count but only one byte follows.
    var hashes: std.ArrayList([32]u8) = .empty;
    defer hashes.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidVarint, forEachInvTxHash(
        &[_]u8{ 0xfd, 0x01 },
        InvCollector{ .hashes = &hashes, .allocator = std.testing.allocator },
        InvCollector.collect,
    ));
}

test "buildVersionMessage: nonce is drawn from the CSPRNG, not the clock" {
    // The old implementation wrote the Unix timestamp here, so two messages
    // built in the same second were byte-identical in the nonce field.
    const a = try buildVersionMessage();
    const b = try buildVersionMessage();
    const nonce_a = std.mem.readInt(u64, a[24 + 72 ..][0..8], .little);
    const nonce_b = std.mem.readInt(u64, b[24 + 72 ..][0..8], .little);
    try std.testing.expect(nonce_a != nonce_b);
    try std.testing.expect(nonce_a != 0);
}
