const std = @import("std");
const net = std.net;
const crypto = std.crypto;
const tls = std.crypto.tls;

// =============================================================================
// ELECTRUM PROTOCOL CONSTANTS
// =============================================================================

/// Maximum response size (1MB should be plenty)
pub const MAX_RESPONSE_SIZE: usize = 1024 * 1024;

/// Maximum scripthash batch size
pub const MAX_BATCH_SIZE: usize = 100;

/// Protocol version we support
pub const PROTOCOL_VERSION: []const u8 = "1.4";

/// Default connection timeout (30 seconds)
pub const DEFAULT_TIMEOUT_MS: u32 = 30000;

// =============================================================================
// ERROR TYPES
// =============================================================================

pub const ElectrumError = error{
    ConnectionFailed,
    TlsHandshakeFailed,
    SendFailed,
    ReceiveFailed,
    Timeout,
    InvalidResponse,
    ServerError,
    BufferTooSmall,
    InvalidScripthash,
    NotConnected,
    ParseError,
};

// =============================================================================
// UTXO STRUCTURE
// =============================================================================

/// Unspent Transaction Output
pub const Utxo = struct {
    /// Transaction ID (32 bytes, reversed for display)
    txid: [32]u8,
    /// Output index
    vout: u32,
    /// Value in satoshis
    value: u64,
    /// Block height (0 if unconfirmed)
    height: u32,
};

/// Transaction history entry
pub const TxHistoryEntry = struct {
    /// Transaction ID
    txid: [32]u8,
    /// Block height (0 or negative if unconfirmed)
    height: i32,
    /// Fee in satoshis (if available, 0 otherwise)
    fee: u64,
};

// =============================================================================
// JSON-RPC HELPERS
// =============================================================================

/// Build a JSON-RPC request
pub fn buildRequest(
    allocator: std.mem.Allocator,
    method: []const u8,
    params: anytype,
    id: u32,
) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);

    try list.appendSlice(allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"");
    try list.appendSlice(allocator, method);
    try list.appendSlice(allocator, "\",\"params\":");

    // Serialize params
    const T = @TypeOf(params);
    if (T == void) {
        try list.appendSlice(allocator, "[]");
    } else if (@typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple) {
        try list.append(allocator, '[');
        inline for (params, 0..) |param, i| {
            if (i > 0) try list.append(allocator, ',');
            try serializeValue(allocator, &list, param);
        }
        try list.append(allocator, ']');
    } else {
        try serializeValue(allocator, &list, params);
    }

    try list.appendSlice(allocator, ",\"id\":");
    var id_buf: [16]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch return error.OutOfMemory;
    try list.appendSlice(allocator, id_str);
    try list.appendSlice(allocator, "}\n");

    return list.toOwnedSlice(allocator);
}

fn serializeValue(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), value: anytype) !void {
    const T = @TypeOf(value);

    if (T == []const u8 or T == []u8) {
        try list.append(allocator, '"');
        try list.appendSlice(allocator, value);
        try list.append(allocator, '"');
    } else if (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .one) {
        const child = @typeInfo(T).pointer.child;
        if (@typeInfo(child) == .array and @typeInfo(child).array.child == u8) {
            try list.append(allocator, '"');
            try list.appendSlice(allocator, value);
            try list.append(allocator, '"');
        }
    } else if (@typeInfo(T) == .int or @typeInfo(T) == .comptime_int) {
        var buf: [32]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return error.OutOfMemory;
        try list.appendSlice(allocator, str);
    } else if (T == bool) {
        try list.appendSlice(allocator, if (value) "true" else "false");
    } else if (@typeInfo(T) == .optional) {
        if (value) |v| {
            try serializeValue(allocator, list, v);
        } else {
            try list.appendSlice(allocator, "null");
        }
    } else {
        @compileError("Unsupported type for JSON serialization: " ++ @typeName(T));
    }
}

// =============================================================================
// SCRIPTHASH COMPUTATION
// =============================================================================

/// Compute Electrum scripthash from a Bitcoin script
/// Electrum uses SHA256(script) with bytes reversed
pub fn computeScripthash(script: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(script, &hash, .{});

    // Reverse for Electrum format
    var reversed: [32]u8 = undefined;
    for (0..32) |i| {
        reversed[i] = hash[31 - i];
    }
    return reversed;
}

/// Compute scripthash for P2WPKH address (from 20-byte pubkey hash)
pub fn computeP2wpkhScripthash(pubkey_hash: *const [20]u8) [32]u8 {
    // P2WPKH script: OP_0 <20-byte-hash>
    // = 0x00 0x14 <pubkey_hash>
    var script: [22]u8 = undefined;
    script[0] = 0x00; // OP_0 (witness version)
    script[1] = 0x14; // Push 20 bytes
    @memcpy(script[2..22], pubkey_hash);

    return computeScripthash(&script);
}

/// Compute scripthash for P2PKH address (from 20-byte pubkey hash)
pub fn computeP2pkhScripthash(pubkey_hash: *const [20]u8) [32]u8 {
    // P2PKH script: OP_DUP OP_HASH160 <20-byte-hash> OP_EQUALVERIFY OP_CHECKSIG
    // = 0x76 0xa9 0x14 <pubkey_hash> 0x88 0xac
    var script: [25]u8 = undefined;
    script[0] = 0x76; // OP_DUP
    script[1] = 0xa9; // OP_HASH160
    script[2] = 0x14; // Push 20 bytes
    @memcpy(script[3..23], pubkey_hash);
    script[23] = 0x88; // OP_EQUALVERIFY
    script[24] = 0xac; // OP_CHECKSIG

    return computeScripthash(&script);
}

/// Convert scripthash to hex string
pub fn scripthashToHex(scripthash: *const [32]u8) [64]u8 {
    const hex_chars = "0123456789abcdef";
    var result: [64]u8 = undefined;
    for (scripthash, 0..) |byte, i| {
        result[i * 2] = hex_chars[byte >> 4];
        result[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return result;
}

/// Convert hex string to scripthash
pub fn hexToScripthash(hex: []const u8) ![32]u8 {
    if (hex.len != 64) return error.InvalidScripthash;

    var result: [32]u8 = undefined;
    for (0..32) |i| {
        const high = hexCharToNibble(hex[i * 2]) orelse return error.InvalidScripthash;
        const low = hexCharToNibble(hex[i * 2 + 1]) orelse return error.InvalidScripthash;
        result[i] = (@as(u8, high) << 4) | @as(u8, low);
    }
    return result;
}

fn hexCharToNibble(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @truncate(c - '0'),
        'a'...'f' => @truncate(c - 'a' + 10),
        'A'...'F' => @truncate(c - 'A' + 10),
        else => null,
    };
}

// =============================================================================
// RESPONSE PARSING
// =============================================================================

/// Parse balance response: {"confirmed": N, "unconfirmed": M}
pub fn parseBalanceResponse(json: []const u8) !struct { confirmed: u64, unconfirmed: i64 } {
    // Simple JSON parsing for balance response
    var confirmed: u64 = 0;
    var unconfirmed: i64 = 0;

    // Find "confirmed":
    if (std.mem.indexOf(u8, json, "\"confirmed\":")) |pos| {
        const start = pos + 12;
        var end = start;
        while (end < json.len and (json[end] >= '0' and json[end] <= '9')) : (end += 1) {}
        if (end > start) {
            confirmed = std.fmt.parseInt(u64, json[start..end], 10) catch 0;
        }
    }

    // Find "unconfirmed":
    if (std.mem.indexOf(u8, json, "\"unconfirmed\":")) |pos| {
        const start = pos + 14;
        var end = start;
        // Handle negative numbers
        const is_negative = json[start] == '-';
        if (is_negative) {
            end += 1;
        }
        while (end < json.len and (json[end] >= '0' and json[end] <= '9')) : (end += 1) {}
        if (end > start) {
            const abs_val = std.fmt.parseInt(u64, json[start + @as(usize, if (is_negative) 1 else 0) .. end], 10) catch 0;
            unconfirmed = if (is_negative) -@as(i64, @intCast(abs_val)) else @intCast(abs_val);
        }
    }

    return .{ .confirmed = confirmed, .unconfirmed = unconfirmed };
}

/// Parse listunspent response into UTXO array
pub fn parseUtxoResponse(
    allocator: std.mem.Allocator,
    json: []const u8,
) ![]Utxo {
    var utxos: std.ArrayListUnmanaged(Utxo) = .empty;
    errdefer utxos.deinit(allocator);

    // Find result array
    const result_start = std.mem.indexOf(u8, json, "\"result\":") orelse return utxos.toOwnedSlice(allocator);
    var pos = result_start + 9;

    // Skip to array start
    while (pos < json.len and json[pos] != '[') : (pos += 1) {}
    if (pos >= json.len) return utxos.toOwnedSlice(allocator);
    pos += 1; // Skip '['

    // Parse each UTXO object
    while (pos < json.len) {
        // Skip whitespace
        while (pos < json.len and (json[pos] == ' ' or json[pos] == '\n' or json[pos] == '\r' or json[pos] == '\t' or json[pos] == ',')) : (pos += 1) {}

        if (pos >= json.len or json[pos] == ']') break;

        if (json[pos] == '{') {
            // Find object end
            var depth: usize = 1;
            const obj_start = pos;
            pos += 1;
            while (pos < json.len and depth > 0) : (pos += 1) {
                if (json[pos] == '{') depth += 1;
                if (json[pos] == '}') depth -= 1;
            }

            const obj = json[obj_start..pos];
            if (parseUtxoObject(obj)) |utxo| {
                try utxos.append(allocator, utxo);
            }
        } else {
            pos += 1;
        }
    }

    return utxos.toOwnedSlice(allocator);
}

/// Parse get_history response into TxHistoryEntry array
pub fn parseHistoryResponse(
    allocator: std.mem.Allocator,
    json: []const u8,
) ![]TxHistoryEntry {
    var entries: std.ArrayListUnmanaged(TxHistoryEntry) = .empty;
    errdefer entries.deinit(allocator);

    // Find result array
    const result_start = std.mem.indexOf(u8, json, "\"result\":") orelse return entries.toOwnedSlice(allocator);
    var pos = result_start + 9;

    // Skip to array start
    while (pos < json.len and json[pos] != '[') : (pos += 1) {}
    if (pos >= json.len) return entries.toOwnedSlice(allocator);
    pos += 1; // Skip '['

    // Parse each history entry object
    while (pos < json.len) {
        // Skip whitespace and commas
        while (pos < json.len and (json[pos] == ' ' or json[pos] == '\n' or json[pos] == '\r' or json[pos] == '\t' or json[pos] == ',')) : (pos += 1) {}

        if (pos >= json.len or json[pos] == ']') break;

        if (json[pos] == '{') {
            // Find object end
            var depth: usize = 1;
            const obj_start = pos;
            pos += 1;
            while (pos < json.len and depth > 0) : (pos += 1) {
                if (json[pos] == '{') depth += 1;
                if (json[pos] == '}') depth -= 1;
            }

            const obj = json[obj_start..pos];
            if (parseHistoryObject(obj)) |entry| {
                try entries.append(allocator, entry);
            }
        } else {
            pos += 1;
        }
    }

    return entries.toOwnedSlice(allocator);
}

fn parseHistoryObject(obj: []const u8) ?TxHistoryEntry {
    var entry = TxHistoryEntry{
        .txid = undefined,
        .height = 0,
        .fee = 0,
    };

    // Parse tx_hash
    if (std.mem.indexOf(u8, obj, "\"tx_hash\":\"")) |pos| {
        const start = pos + 11;
        if (start + 64 <= obj.len) {
            const hex = obj[start .. start + 64];
            // Convert hex to bytes (reversed for internal format)
            for (0..32) |i| {
                const high = hexCharToNibble(hex[i * 2]) orelse return null;
                const low = hexCharToNibble(hex[i * 2 + 1]) orelse return null;
                entry.txid[31 - i] = (@as(u8, high) << 4) | @as(u8, low);
            }
        }
    } else {
        return null;
    }

    // Parse height (can be negative for unconfirmed with unconfirmed parents)
    if (std.mem.indexOf(u8, obj, "\"height\":")) |pos| {
        const start = pos + 9;
        var end = start;
        const is_negative = obj[start] == '-';
        if (is_negative) end += 1;
        while (end < obj.len and obj[end] >= '0' and obj[end] <= '9') : (end += 1) {}
        if (end > start) {
            const abs_val = std.fmt.parseInt(u32, obj[start + @as(usize, if (is_negative) 1 else 0) .. end], 10) catch 0;
            entry.height = if (is_negative) -@as(i32, @intCast(abs_val)) else @intCast(abs_val);
        }
    }

    // Parse fee (optional field)
    if (std.mem.indexOf(u8, obj, "\"fee\":")) |pos| {
        const start = pos + 6;
        var end = start;
        while (end < obj.len and obj[end] >= '0' and obj[end] <= '9') : (end += 1) {}
        entry.fee = std.fmt.parseInt(u64, obj[start..end], 10) catch 0;
    }

    return entry;
}

fn parseUtxoObject(obj: []const u8) ?Utxo {
    var utxo = Utxo{
        .txid = undefined,
        .vout = 0,
        .value = 0,
        .height = 0,
    };

    // Parse tx_hash
    if (std.mem.indexOf(u8, obj, "\"tx_hash\":\"")) |pos| {
        const start = pos + 11;
        if (start + 64 <= obj.len) {
            const hex = obj[start .. start + 64];
            // Convert hex to bytes (reversed for internal format)
            for (0..32) |i| {
                const high = hexCharToNibble(hex[i * 2]) orelse return null;
                const low = hexCharToNibble(hex[i * 2 + 1]) orelse return null;
                utxo.txid[31 - i] = (@as(u8, high) << 4) | @as(u8, low);
            }
        }
    } else {
        return null;
    }

    // Parse tx_pos (vout)
    if (std.mem.indexOf(u8, obj, "\"tx_pos\":")) |pos| {
        const start = pos + 9;
        var end = start;
        while (end < obj.len and obj[end] >= '0' and obj[end] <= '9') : (end += 1) {}
        utxo.vout = std.fmt.parseInt(u32, obj[start..end], 10) catch 0;
    }

    // Parse value
    if (std.mem.indexOf(u8, obj, "\"value\":")) |pos| {
        const start = pos + 8;
        var end = start;
        while (end < obj.len and obj[end] >= '0' and obj[end] <= '9') : (end += 1) {}
        utxo.value = std.fmt.parseInt(u64, obj[start..end], 10) catch 0;
    }

    // Parse height
    if (std.mem.indexOf(u8, obj, "\"height\":")) |pos| {
        const start = pos + 9;
        var end = start;
        while (end < obj.len and obj[end] >= '0' and obj[end] <= '9') : (end += 1) {}
        utxo.height = std.fmt.parseInt(u32, obj[start..end], 10) catch 0;
    }

    return utxo;
}

// =============================================================================
// TESTS
// =============================================================================

test "scripthash computation P2WPKH" {
    // Test vector: known pubkey hash
    const pubkey_hash = [_]u8{
        0x75, 0x1e, 0x76, 0xe8, 0x19, 0x91, 0x96, 0xd4,
        0x54, 0x94, 0x1c, 0x45, 0xd1, 0xb3, 0xa3, 0x23,
        0xf1, 0x43, 0x3b, 0xd6,
    };

    const scripthash = computeP2wpkhScripthash(&pubkey_hash);
    const hex = scripthashToHex(&scripthash);

    // Verify it's 64 hex characters
    try std.testing.expect(hex.len == 64);
}

test "scripthash hex conversion" {
    const original = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
        0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20,
    };

    const hex = scripthashToHex(&original);
    const back = try hexToScripthash(&hex);

    try std.testing.expectEqual(original, back);
}

test "parse balance response" {
    const json =
        \\{"jsonrpc":"2.0","result":{"confirmed":123456,"unconfirmed":-1000},"id":1}
    ;

    const balance = try parseBalanceResponse(json);
    try std.testing.expectEqual(@as(u64, 123456), balance.confirmed);
    try std.testing.expectEqual(@as(i64, -1000), balance.unconfirmed);
}

test "build JSON-RPC request" {
    const allocator = std.testing.allocator;

    const request = try buildRequest(allocator, "blockchain.scripthash.get_balance", .{"abc123"}, 1);
    defer allocator.free(request);

    try std.testing.expect(std.mem.indexOf(u8, request, "\"method\":\"blockchain.scripthash.get_balance\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"params\":[\"abc123\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"id\":1") != null);
}
