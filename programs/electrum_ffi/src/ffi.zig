const std = @import("std");
const electrum = @import("electrum.zig");

// =============================================================================
// ELECTRUM FFI - C-Compatible Electrum Protocol Interface
// =============================================================================
// This FFI provides protocol-level operations (scripthash computation,
// JSON-RPC message building, response parsing). Networking is handled
// by the Rust layer for better async I/O and TLS support.
// =============================================================================

// =============================================================================
// Error Codes
// =============================================================================

pub const ElectrumResult = enum(c_int) {
    success = 0,
    parse_error = -1,
    invalid_scripthash = -2,
    buffer_too_small = -3,
    null_pointer = -4,
    invalid_response = -5,
    server_error = -6,
};

// =============================================================================
// Thread-Local Error Storage
// =============================================================================

threadlocal var last_error_msg: [512]u8 = undefined;
threadlocal var last_error_len: usize = 0;

fn setLastError(msg: []const u8) void {
    const copy_len = @min(msg.len, last_error_msg.len - 1);
    @memcpy(last_error_msg[0..copy_len], msg[0..copy_len]);
    last_error_msg[copy_len] = 0;
    last_error_len = copy_len;
}

/// Get the last error message for this thread
export fn electrum_get_error(buf: [*c]u8, buf_size: usize) usize {
    if (buf_size == 0) return last_error_len;
    const copy_len = @min(last_error_len, buf_size - 1);
    @memcpy(buf[0..copy_len], last_error_msg[0..copy_len]);
    buf[copy_len] = 0;
    return copy_len;
}

// =============================================================================
// C-Compatible Structures
// =============================================================================

/// UTXO structure for FFI
pub const CUtxo = extern struct {
    txid: [32]u8,
    vout: u32,
    value: u64,
    height: u32,
};

/// Balance response
pub const CBalance = extern struct {
    confirmed: u64,
    unconfirmed: i64,
};

/// Transaction history entry
pub const CTxHistoryEntry = extern struct {
    txid: [32]u8,
    height: i32,
    fee: u64,
};

// =============================================================================
// Scripthash Computation Functions
// =============================================================================

/// Compute scripthash for P2WPKH from pubkey hash (20 bytes)
/// Output is 64-byte hex string
export fn electrum_scripthash_p2wpkh(
    pubkey_hash: [*c]const u8,
    out_scripthash_hex: [*c]u8, // 64 bytes for hex output
) c_int {
    if (@intFromPtr(pubkey_hash) == 0 or @intFromPtr(out_scripthash_hex) == 0) {
        return @intFromEnum(ElectrumResult.null_pointer);
    }

    var pk_hash: [20]u8 = undefined;
    @memcpy(&pk_hash, pubkey_hash[0..20]);

    const scripthash = electrum.computeP2wpkhScripthash(&pk_hash);
    const hex = electrum.scripthashToHex(&scripthash);
    @memcpy(out_scripthash_hex[0..64], &hex);

    return @intFromEnum(ElectrumResult.success);
}

/// Compute scripthash for P2PKH from pubkey hash (20 bytes)
/// Output is 64-byte hex string
export fn electrum_scripthash_p2pkh(
    pubkey_hash: [*c]const u8,
    out_scripthash_hex: [*c]u8, // 64 bytes for hex output
) c_int {
    if (@intFromPtr(pubkey_hash) == 0 or @intFromPtr(out_scripthash_hex) == 0) {
        return @intFromEnum(ElectrumResult.null_pointer);
    }

    var pk_hash: [20]u8 = undefined;
    @memcpy(&pk_hash, pubkey_hash[0..20]);

    const scripthash = electrum.computeP2pkhScripthash(&pk_hash);
    const hex = electrum.scripthashToHex(&scripthash);
    @memcpy(out_scripthash_hex[0..64], &hex);

    return @intFromEnum(ElectrumResult.success);
}

/// Compute scripthash from arbitrary script
/// Output is 64-byte hex string
export fn electrum_scripthash_from_script(
    script: [*c]const u8,
    script_len: usize,
    out_scripthash_hex: [*c]u8,
) c_int {
    if (@intFromPtr(script) == 0 or @intFromPtr(out_scripthash_hex) == 0) {
        return @intFromEnum(ElectrumResult.null_pointer);
    }

    const scripthash = electrum.computeScripthash(script[0..script_len]);
    const hex = electrum.scripthashToHex(&scripthash);
    @memcpy(out_scripthash_hex[0..64], &hex);

    return @intFromEnum(ElectrumResult.success);
}

// =============================================================================
// JSON-RPC Request Building
// =============================================================================

/// Build a get_balance request
/// Returns length of request, or negative error code
export fn electrum_build_get_balance_request(
    scripthash_hex: [*c]const u8, // 64-byte hex scripthash
    request_id: u32,
    out_request: [*c]u8,
    out_request_size: usize,
) c_int {
    if (@intFromPtr(scripthash_hex) == 0 or @intFromPtr(out_request) == 0) {
        return @intFromEnum(ElectrumResult.null_pointer);
    }

    const allocator = std.heap.page_allocator;

    const request = electrum.buildRequest(
        allocator,
        "blockchain.scripthash.get_balance",
        .{scripthash_hex[0..64]},
        request_id,
    ) catch {
        setLastError("Failed to build request");
        return @intFromEnum(ElectrumResult.parse_error);
    };
    defer allocator.free(request);

    if (request.len > out_request_size) {
        setLastError("Buffer too small");
        return @intFromEnum(ElectrumResult.buffer_too_small);
    }

    @memcpy(out_request[0..request.len], request);
    return @intCast(request.len);
}

/// Build a listunspent request
export fn electrum_build_listunspent_request(
    scripthash_hex: [*c]const u8,
    request_id: u32,
    out_request: [*c]u8,
    out_request_size: usize,
) c_int {
    if (@intFromPtr(scripthash_hex) == 0 or @intFromPtr(out_request) == 0) {
        return @intFromEnum(ElectrumResult.null_pointer);
    }

    const allocator = std.heap.page_allocator;

    const request = electrum.buildRequest(
        allocator,
        "blockchain.scripthash.listunspent",
        .{scripthash_hex[0..64]},
        request_id,
    ) catch {
        setLastError("Failed to build request");
        return @intFromEnum(ElectrumResult.parse_error);
    };
    defer allocator.free(request);

    if (request.len > out_request_size) {
        setLastError("Buffer too small");
        return @intFromEnum(ElectrumResult.buffer_too_small);
    }

    @memcpy(out_request[0..request.len], request);
    return @intCast(request.len);
}

/// Build a get_history request
export fn electrum_build_get_history_request(
    scripthash_hex: [*c]const u8, // 64-byte hex scripthash
    request_id: u32,
    out_request: [*c]u8,
    out_request_size: usize,
) c_int {
    if (@intFromPtr(scripthash_hex) == 0 or @intFromPtr(out_request) == 0) {
        return @intFromEnum(ElectrumResult.null_pointer);
    }

    const allocator = std.heap.page_allocator;

    const request = electrum.buildRequest(
        allocator,
        "blockchain.scripthash.get_history",
        .{scripthash_hex[0..64]},
        request_id,
    ) catch {
        setLastError("Failed to build request");
        return @intFromEnum(ElectrumResult.parse_error);
    };
    defer allocator.free(request);

    if (request.len > out_request_size) {
        setLastError("Buffer too small");
        return @intFromEnum(ElectrumResult.buffer_too_small);
    }

    @memcpy(out_request[0..request.len], request);
    return @intCast(request.len);
}

/// Build a broadcast transaction request
export fn electrum_build_broadcast_request(
    raw_tx_hex: [*c]const u8,
    raw_tx_hex_len: usize,
    request_id: u32,
    out_request: [*c]u8,
    out_request_size: usize,
) c_int {
    if (@intFromPtr(raw_tx_hex) == 0 or @intFromPtr(out_request) == 0) {
        return @intFromEnum(ElectrumResult.null_pointer);
    }

    const allocator = std.heap.page_allocator;

    const request = electrum.buildRequest(
        allocator,
        "blockchain.transaction.broadcast",
        .{raw_tx_hex[0..raw_tx_hex_len]},
        request_id,
    ) catch {
        setLastError("Failed to build request");
        return @intFromEnum(ElectrumResult.parse_error);
    };
    defer allocator.free(request);

    if (request.len > out_request_size) {
        setLastError("Buffer too small");
        return @intFromEnum(ElectrumResult.buffer_too_small);
    }

    @memcpy(out_request[0..request.len], request);
    return @intCast(request.len);
}

/// Build a get_transaction request
export fn electrum_build_get_tx_request(
    txid_hex: [*c]const u8, // 64-byte hex txid
    request_id: u32,
    out_request: [*c]u8,
    out_request_size: usize,
) c_int {
    if (@intFromPtr(txid_hex) == 0 or @intFromPtr(out_request) == 0) {
        return @intFromEnum(ElectrumResult.null_pointer);
    }

    const allocator = std.heap.page_allocator;

    const request = electrum.buildRequest(
        allocator,
        "blockchain.transaction.get",
        .{txid_hex[0..64]},
        request_id,
    ) catch {
        setLastError("Failed to build request");
        return @intFromEnum(ElectrumResult.parse_error);
    };
    defer allocator.free(request);

    if (request.len > out_request_size) {
        setLastError("Buffer too small");
        return @intFromEnum(ElectrumResult.buffer_too_small);
    }

    @memcpy(out_request[0..request.len], request);
    return @intCast(request.len);
}

/// Build a headers.subscribe request (to get current tip)
export fn electrum_build_subscribe_headers_request(
    request_id: u32,
    out_request: [*c]u8,
    out_request_size: usize,
) c_int {
    if (@intFromPtr(out_request) == 0) {
        return @intFromEnum(ElectrumResult.null_pointer);
    }

    const allocator = std.heap.page_allocator;

    const request = electrum.buildRequest(
        allocator,
        "blockchain.headers.subscribe",
        {},
        request_id,
    ) catch {
        setLastError("Failed to build request");
        return @intFromEnum(ElectrumResult.parse_error);
    };
    defer allocator.free(request);

    if (request.len > out_request_size) {
        setLastError("Buffer too small");
        return @intFromEnum(ElectrumResult.buffer_too_small);
    }

    @memcpy(out_request[0..request.len], request);
    return @intCast(request.len);
}

/// Build a server.version request (for protocol negotiation)
export fn electrum_build_version_request(
    client_name: [*c]const u8,
    client_name_len: usize,
    protocol_version: [*c]const u8,
    protocol_version_len: usize,
    request_id: u32,
    out_request: [*c]u8,
    out_request_size: usize,
) c_int {
    if (@intFromPtr(client_name) == 0 or @intFromPtr(protocol_version) == 0 or @intFromPtr(out_request) == 0) {
        return @intFromEnum(ElectrumResult.null_pointer);
    }

    const allocator = std.heap.page_allocator;

    const request = electrum.buildRequest(
        allocator,
        "server.version",
        .{ client_name[0..client_name_len], protocol_version[0..protocol_version_len] },
        request_id,
    ) catch {
        setLastError("Failed to build request");
        return @intFromEnum(ElectrumResult.parse_error);
    };
    defer allocator.free(request);

    if (request.len > out_request_size) {
        setLastError("Buffer too small");
        return @intFromEnum(ElectrumResult.buffer_too_small);
    }

    @memcpy(out_request[0..request.len], request);
    return @intCast(request.len);
}

// =============================================================================
// Response Parsing Functions
// =============================================================================

/// Parse a balance response
export fn electrum_parse_balance_response(
    response: [*c]const u8,
    response_len: usize,
    out_balance: *CBalance,
) c_int {
    if (@intFromPtr(response) == 0 or @intFromPtr(out_balance) == 0) {
        return @intFromEnum(ElectrumResult.null_pointer);
    }

    const balance = electrum.parseBalanceResponse(response[0..response_len]) catch {
        setLastError("Failed to parse balance response");
        return @intFromEnum(ElectrumResult.parse_error);
    };

    out_balance.confirmed = balance.confirmed;
    out_balance.unconfirmed = balance.unconfirmed;

    return @intFromEnum(ElectrumResult.success);
}

/// Parse a listunspent response
/// Returns number of UTXOs parsed, or negative error code
export fn electrum_parse_listunspent_response(
    response: [*c]const u8,
    response_len: usize,
    out_utxos: [*c]CUtxo,
    max_utxos: usize,
) c_int {
    if (@intFromPtr(response) == 0 or @intFromPtr(out_utxos) == 0) {
        return @intFromEnum(ElectrumResult.null_pointer);
    }

    const allocator = std.heap.page_allocator;

    const utxos = electrum.parseUtxoResponse(allocator, response[0..response_len]) catch {
        setLastError("Failed to parse UTXO response");
        return @intFromEnum(ElectrumResult.parse_error);
    };
    defer allocator.free(utxos);

    const copy_count = @min(utxos.len, max_utxos);
    for (utxos[0..copy_count], 0..) |utxo, i| {
        out_utxos[i] = CUtxo{
            .txid = utxo.txid,
            .vout = utxo.vout,
            .value = utxo.value,
            .height = utxo.height,
        };
    }

    return @intCast(copy_count);
}

/// Parse a get_history response
/// Returns number of history entries parsed, or negative error code
export fn electrum_parse_history_response(
    response: [*c]const u8,
    response_len: usize,
    out_entries: [*c]CTxHistoryEntry,
    max_entries: usize,
) c_int {
    if (@intFromPtr(response) == 0 or @intFromPtr(out_entries) == 0) {
        return @intFromEnum(ElectrumResult.null_pointer);
    }

    const allocator = std.heap.page_allocator;

    const entries = electrum.parseHistoryResponse(allocator, response[0..response_len]) catch {
        setLastError("Failed to parse history response");
        return @intFromEnum(ElectrumResult.parse_error);
    };
    defer allocator.free(entries);

    const copy_count = @min(entries.len, max_entries);
    for (entries[0..copy_count], 0..) |entry, i| {
        out_entries[i] = CTxHistoryEntry{
            .txid = entry.txid,
            .height = entry.height,
            .fee = entry.fee,
        };
    }

    return @intCast(copy_count);
}

/// Parse a broadcast response to extract txid
/// Returns 0 on success (txid written to out_txid), negative on error
export fn electrum_parse_broadcast_response(
    response: [*c]const u8,
    response_len: usize,
    out_txid_hex: [*c]u8, // 64 bytes
) c_int {
    if (@intFromPtr(response) == 0 or @intFromPtr(out_txid_hex) == 0) {
        return @intFromEnum(ElectrumResult.null_pointer);
    }

    const resp = response[0..response_len];

    // Look for "result":"<txid>"
    if (std.mem.indexOf(u8, resp, "\"result\":\"")) |pos| {
        const txid_start = pos + 10;
        if (txid_start + 64 <= resp.len) {
            @memcpy(out_txid_hex[0..64], resp[txid_start .. txid_start + 64]);
            return @intFromEnum(ElectrumResult.success);
        }
    }

    // Check for error
    if (std.mem.indexOf(u8, resp, "\"error\":")) |_| {
        setLastError("Server returned error");
        return @intFromEnum(ElectrumResult.server_error);
    }

    setLastError("Invalid response format");
    return @intFromEnum(ElectrumResult.invalid_response);
}

/// Parse a get_transaction response to extract raw tx hex
/// Returns length of raw tx hex, or negative error code
export fn electrum_parse_get_tx_response(
    response: [*c]const u8,
    response_len: usize,
    out_raw_tx_hex: [*c]u8,
    out_raw_tx_size: usize,
) c_int {
    if (@intFromPtr(response) == 0 or @intFromPtr(out_raw_tx_hex) == 0) {
        return @intFromEnum(ElectrumResult.null_pointer);
    }

    const resp = response[0..response_len];

    // Look for "result":"<raw_tx_hex>"
    if (std.mem.indexOf(u8, resp, "\"result\":\"")) |pos| {
        const tx_start = pos + 10;
        // Find closing quote
        if (std.mem.indexOfScalarPos(u8, resp, tx_start, '"')) |tx_end| {
            const tx_len = tx_end - tx_start;
            if (tx_len > out_raw_tx_size) {
                setLastError("Buffer too small for transaction");
                return @intFromEnum(ElectrumResult.buffer_too_small);
            }
            @memcpy(out_raw_tx_hex[0..tx_len], resp[tx_start..tx_end]);
            return @intCast(tx_len);
        }
    }

    // Check for error
    if (std.mem.indexOf(u8, resp, "\"error\":")) |_| {
        setLastError("Server returned error");
        return @intFromEnum(ElectrumResult.server_error);
    }

    setLastError("Invalid response format");
    return @intFromEnum(ElectrumResult.invalid_response);
}

/// Parse headers.subscribe response to get current height
/// Returns height, or negative error code
export fn electrum_parse_headers_response(
    response: [*c]const u8,
    response_len: usize,
) c_int {
    if (@intFromPtr(response) == 0) {
        return @intFromEnum(ElectrumResult.null_pointer);
    }

    const resp = response[0..response_len];

    // Parse height from response
    if (std.mem.indexOf(u8, resp, "\"height\":")) |pos| {
        const start = pos + 9;
        var end = start;
        while (end < resp.len and resp[end] >= '0' and resp[end] <= '9') : (end += 1) {}
        const height = std.fmt.parseInt(u32, resp[start..end], 10) catch {
            setLastError("Failed to parse height");
            return @intFromEnum(ElectrumResult.parse_error);
        };
        return @intCast(height);
    }

    setLastError("Height not found in response");
    return @intFromEnum(ElectrumResult.invalid_response);
}

// =============================================================================
// Utility Functions
// =============================================================================

/// Get size of CUtxo struct
export fn electrum_utxo_size() usize {
    return @sizeOf(CUtxo);
}

/// Get size of CBalance struct
export fn electrum_balance_size() usize {
    return @sizeOf(CBalance);
}

/// Convert scripthash hex to bytes
export fn electrum_hex_to_scripthash(
    hex: [*c]const u8,
    out_scripthash: [*c]u8, // 32 bytes
) c_int {
    if (@intFromPtr(hex) == 0 or @intFromPtr(out_scripthash) == 0) {
        return @intFromEnum(ElectrumResult.null_pointer);
    }

    const scripthash = electrum.hexToScripthash(hex[0..64]) catch {
        setLastError("Invalid hex string");
        return @intFromEnum(ElectrumResult.invalid_scripthash);
    };

    @memcpy(out_scripthash[0..32], &scripthash);
    return @intFromEnum(ElectrumResult.success);
}

// =============================================================================
// Tests
// =============================================================================

test "scripthash computation" {
    var out: [64]u8 = undefined;
    const pubkey_hash = [_]u8{
        0x75, 0x1e, 0x76, 0xe8, 0x19, 0x91, 0x96, 0xd4,
        0x54, 0x94, 0x1c, 0x45, 0xd1, 0xb3, 0xa3, 0x23,
        0xf1, 0x43, 0x3b, 0xd6,
    };

    const result = electrum_scripthash_p2wpkh(&pubkey_hash, &out);
    try std.testing.expect(result == 0);
    try std.testing.expect(out.len == 64);
}

test "build balance request" {
    var request: [256]u8 = undefined;
    const scripthash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    const len = electrum_build_get_balance_request(scripthash, 1, &request, 256);
    try std.testing.expect(len > 0);

    const req_str = request[0..@intCast(len)];
    try std.testing.expect(std.mem.indexOf(u8, req_str, "blockchain.scripthash.get_balance") != null);
}

test "parse balance response" {
    const response = "{\"jsonrpc\":\"2.0\",\"result\":{\"confirmed\":123456,\"unconfirmed\":-1000},\"id\":1}";
    var balance: CBalance = undefined;

    const result = electrum_parse_balance_response(response, response.len, &balance);
    try std.testing.expect(result == 0);
    try std.testing.expectEqual(@as(u64, 123456), balance.confirmed);
    try std.testing.expectEqual(@as(i64, -1000), balance.unconfirmed);
}
