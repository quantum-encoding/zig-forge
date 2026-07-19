const std = @import("std");
const crypto = std.crypto;

// JSON-RPC envelopes go through std.json.Stringify on anonymous structs
// — never via hand-rolled escape + concatenation. The standard library
// owns string safety and tuple-to-array serialisation. Batch 9.
//
// This module is pure protocol logic with NO networking: scripthash
// computation, JSON-RPC framing, response parsing. Sockets and TLS live in
// the consuming Rust layer. (The former in-Zig networking client's imports,
// constants, and connection-flavored error variants were removed as dead
// code — they were never reachable from any exported path.)

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

/// Build a JSON-RPC request envelope. Method, params, and id all go
/// through `std.json.Stringify.valueAlloc` on an anonymous struct;
/// string escaping, tuple-to-array serialization, optional handling
/// and integer formatting are all delegated to the standard library.
///
/// The pre-audit version concatenated raw bytes inside quotes, which
/// meant a method name or string-typed param containing `"` could
/// inject sibling JSON-RPC keys. With this implementation the only way
/// to corrupt the envelope is to corrupt std.json itself.
pub fn buildRequest(
    allocator: std.mem.Allocator,
    method: []const u8,
    params: anytype,
    id: u32,
) ![]u8 {
    const T = @TypeOf(params);
    const body = if (T == void)
        // F1: an empty `[_]u8{}` array coerces to `[]const u8` and
        // std.json.Stringify emits any UTF-8-valid u8 slice as a JSON
        // *string* — so void params serialized as `"params":""`, which
        // JSON-RPC 2.0 §4 forbids and ElectrumX/aiorpcX rejects (this
        // broke quantum_vault's block-height lookup). An empty array of a
        // non-u8 element type serializes unambiguously as `"params":[]`.
        try std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .method = method,
            .params = [_]u32{},
            .id = id,
        }, .{})
    else
        try std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .method = method,
            .params = params,
            .id = id,
        }, .{});
    defer allocator.free(body);

    // Electrum servers expect newline-delimited JSON-RPC frames.
    const out = try allocator.alloc(u8, body.len + 1);
    @memcpy(out[0..body.len], body);
    out[body.len] = '\n';
    return out;
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
    // ELE-2: previously this function searched for `"confirmed":` and
    // `"unconfirmed":` as substrings across the entire JSON document. That
    // pattern is brittle in three ways:
    //   1. Substring inside a string value (e.g. a server-info field
    //      reading `"version":"\"confirmed\":42 in 2024"`) was indexed
    //      as a real claim.
    //   2. JSON escape sequences were not interpreted.
    //   3. No structural validation — a top-level `null` or a `"result"`
    //      that's a string instead of an object passed silently.
    //
    // Now we parse the document and validate structure: must be an
    // object, must have an object-typed `result`, that result must have
    // integer `confirmed` and `unconfirmed` fields.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch
        return error.ParseError;
    defer parsed.deinit();

    if (parsed.value != .object) return error.ParseError;
    const result_val = parsed.value.object.get("result") orelse return error.ParseError;
    if (result_val != .object) return error.ParseError;
    const result = result_val.object;

    const conf_val = result.get("confirmed") orelse return error.ParseError;
    if (conf_val != .integer) return error.ParseError;
    const conf_signed = conf_val.integer;
    if (conf_signed < 0) return error.ParseError;

    const unconf_val = result.get("unconfirmed") orelse return error.ParseError;
    if (unconf_val != .integer) return error.ParseError;

    return .{
        .confirmed = @intCast(conf_signed),
        .unconfirmed = unconf_val.integer,
    };
}

/// Parse a listunspent response into a UTXO array.
///
/// ELE-3: the pre-audit implementation found UTXO objects by walking a
/// brace-depth counter that DID NOT account for `{` / `}` inside JSON
/// string values — a UTXO whose `tx_hash` contained the literal byte `}`
/// (e.g. a base64-encoded extension field) would corrupt the depth and
/// produce truncated or doubled entries. The fix is `std.json` plus
/// per-field type validation.
///
/// Caller owns the returned slice (`allocator.free` after use).
pub fn parseUtxoResponse(
    allocator: std.mem.Allocator,
    json: []const u8,
) ![]Utxo {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch
        return error.ParseError;
    defer parsed.deinit();

    if (parsed.value != .object) return error.ParseError;
    const result_val = parsed.value.object.get("result") orelse {
        // No "result" key — return an empty array, matching the old
        // forgiving behavior for malformed-but-shaped responses.
        return try allocator.alloc(Utxo, 0);
    };
    if (result_val != .array) return error.ParseError;
    const items = result_val.array.items;

    var utxos: std.ArrayListUnmanaged(Utxo) = .empty;
    errdefer utxos.deinit(allocator);

    for (items) |entry_val| {
        if (entry_val != .object) continue; // skip malformed entry
        if (utxoFromValue(entry_val.object)) |utxo| {
            try utxos.append(allocator, utxo);
        }
    }

    return utxos.toOwnedSlice(allocator);
}

/// Parse a get_history response into a TxHistoryEntry array.
///
/// ELE-3: same rationale as parseUtxoResponse.
/// Caller owns the returned slice.
pub fn parseHistoryResponse(
    allocator: std.mem.Allocator,
    json: []const u8,
) ![]TxHistoryEntry {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch
        return error.ParseError;
    defer parsed.deinit();

    if (parsed.value != .object) return error.ParseError;
    const result_val = parsed.value.object.get("result") orelse {
        return try allocator.alloc(TxHistoryEntry, 0);
    };
    if (result_val != .array) return error.ParseError;
    const items = result_val.array.items;

    var entries: std.ArrayListUnmanaged(TxHistoryEntry) = .empty;
    errdefer entries.deinit(allocator);

    for (items) |entry_val| {
        if (entry_val != .object) continue;
        if (historyEntryFromValue(entry_val.object)) |entry| {
            try entries.append(allocator, entry);
        }
    }

    return entries.toOwnedSlice(allocator);
}

/// Build a Utxo from a parsed JSON object. Returns null if required
/// fields (tx_hash) are missing or malformed.
fn utxoFromValue(obj: std.json.ObjectMap) ?Utxo {
    var utxo = Utxo{
        .txid = undefined,
        .vout = 0,
        .value = 0,
        .height = 0,
    };

    // tx_hash — required, 64 hex chars, reversed into Bitcoin-internal byte order
    const tx_hash_val = obj.get("tx_hash") orelse return null;
    if (tx_hash_val != .string) return null;
    const hex = tx_hash_val.string;
    if (hex.len != 64) return null;
    for (0..32) |i| {
        const high = hexCharToNibble(hex[i * 2]) orelse return null;
        const low = hexCharToNibble(hex[i * 2 + 1]) orelse return null;
        utxo.txid[31 - i] = (@as(u8, high) << 4) | @as(u8, low);
    }

    // tx_pos (vout) — required, non-negative integer
    if (obj.get("tx_pos")) |v| {
        if (v == .integer and v.integer >= 0 and v.integer <= std.math.maxInt(u32)) {
            utxo.vout = @intCast(v.integer);
        }
    }

    // value (satoshis) — required, non-negative integer
    if (obj.get("value")) |v| {
        if (v == .integer and v.integer >= 0) {
            utxo.value = @intCast(v.integer);
        }
    }

    // height — required, non-negative integer (UTXO entries are confirmed)
    if (obj.get("height")) |v| {
        if (v == .integer and v.integer >= 0 and v.integer <= std.math.maxInt(u32)) {
            utxo.height = @intCast(v.integer);
        }
    }

    return utxo;
}

/// Build a TxHistoryEntry from a parsed JSON object. Returns null if
/// required fields are missing or malformed.
fn historyEntryFromValue(obj: std.json.ObjectMap) ?TxHistoryEntry {
    var entry = TxHistoryEntry{
        .txid = undefined,
        .height = 0,
        .fee = 0,
    };

    // tx_hash — required, 64 hex chars
    const tx_hash_val = obj.get("tx_hash") orelse return null;
    if (tx_hash_val != .string) return null;
    const hex = tx_hash_val.string;
    if (hex.len != 64) return null;
    for (0..32) |i| {
        const high = hexCharToNibble(hex[i * 2]) orelse return null;
        const low = hexCharToNibble(hex[i * 2 + 1]) orelse return null;
        entry.txid[31 - i] = (@as(u8, high) << 4) | @as(u8, low);
    }

    // height — required, signed integer (can be 0 unconfirmed or negative
    // for unconfirmed-with-unconfirmed-parents)
    if (obj.get("height")) |v| {
        if (v == .integer and v.integer >= std.math.minInt(i32) and v.integer <= std.math.maxInt(i32)) {
            entry.height = @intCast(v.integer);
        }
    }

    // fee — optional, non-negative integer
    if (obj.get("fee")) |v| {
        if (v == .integer and v.integer >= 0) {
            entry.fee = @intCast(v.integer);
        }
    }

    return entry;
}

/// True iff every byte of `s` is a lowercase hex digit (`0`-`9`, `a`-`f`).
/// Bitcoin txids and raw transactions are canonical lowercase hex; an
/// uppercase or non-hex byte means the string is not the value we expect.
fn isLowerHex(s: []const u8) bool {
    for (s) |c| {
        switch (c) {
            '0'...'9', 'a'...'f' => {},
            else => return false,
        }
    }
    return true;
}

/// Parse a `blockchain.transaction.broadcast` response and return the 64-char
/// lowercase-hex txid.
///
/// Replaces the ffi.zig substring scanner (F2) that copied a fixed 64 bytes
/// after the literal `"result":"` with no closing-quote check, no hex
/// validation, and the `"error"` check running only *after* the result match
/// — so a short `"result":"ok"` copied trailing JSON as a txid, and a server
/// that returned error text as a string `result` was reported as a successful
/// broadcast with a garbage txid. Now: parse structurally, reject error
/// responses first, require a `result` that is exactly 64 lowercase-hex chars.
pub fn parseBroadcastResponse(json: []const u8) ![64]u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch
        return error.ParseError;
    defer parsed.deinit();

    if (parsed.value != .object) return error.ParseError;
    const obj = parsed.value.object;

    // Reject error responses BEFORE looking at `result` — a string-typed
    // `result` carrying error text must never be mistaken for a txid.
    if (obj.get("error")) |err_val| {
        if (err_val != .null) return error.ServerError;
    }

    const result_val = obj.get("result") orelse return error.ParseError;
    if (result_val != .string) return error.ParseError;
    const s = result_val.string;
    if (s.len != 64) return error.ParseError;
    if (!isLowerHex(s)) return error.ParseError;

    var out: [64]u8 = undefined;
    @memcpy(&out, s);
    return out;
}

/// Parse a `blockchain.transaction.get` (verbose=false) response and return
/// the raw-transaction hex. Caller owns the returned slice (`allocator.free`).
///
/// Replaces the ffi.zig substring scanner (F2): reject error responses first,
/// require a string `result` that is non-empty, even-length, lowercase hex.
pub fn parseTxResponse(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch
        return error.ParseError;
    defer parsed.deinit();

    if (parsed.value != .object) return error.ParseError;
    const obj = parsed.value.object;
    if (obj.get("error")) |err_val| {
        if (err_val != .null) return error.ServerError;
    }

    const result_val = obj.get("result") orelse return error.ParseError;
    if (result_val != .string) return error.ParseError;
    const s = result_val.string;
    if (s.len == 0 or s.len % 2 != 0) return error.ParseError;
    if (!isLowerHex(s)) return error.ParseError;

    return allocator.dupe(u8, s) catch return error.ParseError;
}

/// Parse a `blockchain.headers.subscribe` response and return the tip height.
///
/// Replaces the ffi.zig substring scanner (F2) that matched `"height":`
/// anywhere in the document (so an error message containing that substring
/// parsed as a height) and `@intCast`ed a u32 to c_int (an abort path on
/// values ≥ 2³¹). Now: reject error responses first, require an object
/// `result` with a non-negative integer `height` that fits in c_int.
pub fn parseHeadersResponse(json: []const u8) !u32 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, json, .{}) catch
        return error.ParseError;
    defer parsed.deinit();

    if (parsed.value != .object) return error.ParseError;
    const obj = parsed.value.object;
    if (obj.get("error")) |err_val| {
        if (err_val != .null) return error.ServerError;
    }

    const result_val = obj.get("result") orelse return error.ParseError;
    if (result_val != .object) return error.ParseError;

    const height_val = result_val.object.get("height") orelse return error.ParseError;
    if (height_val != .integer) return error.ParseError;
    const h = height_val.integer;
    // Must be non-negative and fit in c_int — the FFI returns height as a
    // c_int, so anything larger cannot be represented and is treated as
    // malformed rather than aborting on the cast.
    if (h < 0 or h > std.math.maxInt(c_int)) return error.ParseError;

    return @intCast(h);
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

test "scripthash P2WPKH known answer (BIP-173 canonical hash160)" {
    // Electrum protocol: scripthash = hex(reverse(sha256(scriptPubKey)))
    // (https://electrumx.readthedocs.io/en/latest/protocol-basics.html#script-hashes)
    // scriptPubKey = 0014751e76e8199196d454941c45d1b3a323f1433bd6 (P2WPKH,
    // OP_0 PUSH20 <hash160>), using the canonical BIP-173 example program.
    // Expected value derived from the spec'd construction with:
    //   python3 -c "import hashlib;s=bytes.fromhex('0014751e76e8199196d454941c45d1b3a323f1433bd6');print(hashlib.sha256(s).digest()[::-1].hex())"
    const pubkey_hash = [_]u8{
        0x75, 0x1e, 0x76, 0xe8, 0x19, 0x91, 0x96, 0xd4,
        0x54, 0x94, 0x1c, 0x45, 0xd1, 0xb3, 0xa3, 0x23,
        0xf1, 0x43, 0x3b, 0xd6,
    };

    const scripthash = computeP2wpkhScripthash(&pubkey_hash);
    const hex = scripthashToHex(&scripthash);
    try std.testing.expectEqualSlices(
        u8,
        "9623df75239b5daa7f5f03042d325b51498c4bb7059c7748b17049bf96f73888",
        &hex,
    );
}

test "scripthash P2PKH known answer (same hash160)" {
    // scriptPubKey = 76a914751e76e8199196d454941c45d1b3a323f1433bd688ac
    // (P2PKH: OP_DUP OP_HASH160 PUSH20 <hash160> OP_EQUALVERIFY OP_CHECKSIG).
    // Expected value derived from the spec'd construction with:
    //   python3 -c "import hashlib;s=bytes.fromhex('76a914751e76e8199196d454941c45d1b3a323f1433bd688ac');print(hashlib.sha256(s).digest()[::-1].hex())"
    const pubkey_hash = [_]u8{
        0x75, 0x1e, 0x76, 0xe8, 0x19, 0x91, 0x96, 0xd4,
        0x54, 0x94, 0x1c, 0x45, 0xd1, 0xb3, 0xa3, 0x23,
        0xf1, 0x43, 0x3b, 0xd6,
    };

    const scripthash = computeP2pkhScripthash(&pubkey_hash);
    const hex = scripthashToHex(&scripthash);
    try std.testing.expectEqualSlices(
        u8,
        "8bd2c4f79944cd6a3cb1730cf92c513ae259eb271d81918457f3753eebe14a3f",
        &hex,
    );
}

test "computeScripthash SHA-256 core matches NIST KAT (byte-reversed)" {
    // computeScripthash(x) = reverse(SHA-256(x)). For x = "abc" the inner
    // digest is the NIST FIPS 180-4 KAT
    //   ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
    // so the scripthash must be its byte reversal. This pins the SHA-256
    // core AND the Electrum reversal step to authoritative values.
    const scripthash = computeScripthash("abc");

    var nist_kat: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&nist_kat, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    var expected: [32]u8 = undefined;
    for (0..32) |i| {
        expected[i] = nist_kat[31 - i];
    }
    try std.testing.expectEqual(expected, scripthash);
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

// ============================================================================
// Audit-driven tests — ELE-1, ELE-2, ELE-3
// ============================================================================

// ----- ELE-1: JSON-injection in buildRequest -----

test "ELE-1: malicious method name cannot inject sibling JSON-RPC keys" {
    const allocator = std.testing.allocator;

    // Pre-audit: a method name containing `"` broke out of the method
    // string and let the attacker append arbitrary JSON-RPC keys
    // (potentially changing the id so responses get routed wrong, or
    // injecting `"params":[...]` to override).
    const attack_method = "evil\",\"id\":999,\"x\":\"";
    const request = try buildRequest(allocator, attack_method, .{}, 1);
    defer allocator.free(request);

    // Parse the constructed request — must round-trip as a single-method
    // request with id=1, NOT as a multi-key object with id=999.
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, request, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqualSlices(u8, attack_method, parsed.value.object.get("method").?.string);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("id").?.integer);
    // Verify NO injected `x` key.
    try std.testing.expect(parsed.value.object.get("x") == null);
}

test "ELE-1: malicious string param cannot break out of the array" {
    const allocator = std.testing.allocator;

    // Address strings flow into this code path. A user-controlled address
    // containing `"` previously injected past the closing quote.
    const attack_param = "\"],\"extra_param\":\"injected";
    const request = try buildRequest(allocator, "blockchain.scripthash.get_balance", .{attack_param}, 7);
    defer allocator.free(request);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, request, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const params = obj.get("params").?;
    try std.testing.expect(params == .array);
    try std.testing.expectEqual(@as(usize, 1), params.array.items.len);
    try std.testing.expectEqualSlices(u8, attack_param, params.array.items[0].string);
    try std.testing.expect(obj.get("extra_param") == null);
}

// ----- ELE-2: parseBalanceResponse robustness -----

test "ELE-2: parseBalanceResponse parses canonical response" {
    const json =
        \\{"jsonrpc":"2.0","result":{"confirmed":123456,"unconfirmed":-1000},"id":1}
    ;
    const balance = try parseBalanceResponse(json);
    try std.testing.expectEqual(@as(u64, 123456), balance.confirmed);
    try std.testing.expectEqual(@as(i64, -1000), balance.unconfirmed);
}

test "ELE-2: substring `\"confirmed\":` inside an unrelated string field doesn't confuse the parser" {
    // Pre-audit: this entire JSON was scanned for the literal substring
    // `"confirmed":`. The decoy inside `note` would have matched first
    // (depending on key order), and `parseBalanceResponse` returned 999
    // instead of 100.
    const json =
        \\{"jsonrpc":"2.0","result":{"note":"contains \"confirmed\":999","confirmed":100,"unconfirmed":0},"id":1}
    ;
    const balance = try parseBalanceResponse(json);
    try std.testing.expectEqual(@as(u64, 100), balance.confirmed);
    try std.testing.expectEqual(@as(i64, 0), balance.unconfirmed);
}

test "ELE-2: response with missing `result` errors instead of silently returning zero" {
    const json =
        \\{"jsonrpc":"2.0","error":{"code":-1,"message":"oops"},"id":1}
    ;
    try std.testing.expectError(error.ParseError, parseBalanceResponse(json));
}

test "ELE-2: response with non-object `result` errors" {
    const json =
        \\{"jsonrpc":"2.0","result":null,"id":1}
    ;
    try std.testing.expectError(error.ParseError, parseBalanceResponse(json));
}

test "ELE-2: response with non-integer `confirmed` errors" {
    const json =
        \\{"jsonrpc":"2.0","result":{"confirmed":"123456","unconfirmed":0},"id":1}
    ;
    try std.testing.expectError(error.ParseError, parseBalanceResponse(json));
}

test "ELE-2: negative `confirmed` is rejected" {
    // Per Electrum spec, confirmed is u64 (non-negative). A negative value
    // is malformed and must error rather than wrap into a huge unsigned.
    const json =
        \\{"jsonrpc":"2.0","result":{"confirmed":-1,"unconfirmed":0},"id":1}
    ;
    try std.testing.expectError(error.ParseError, parseBalanceResponse(json));
}

// ----- ELE-3: parseUtxoResponse / parseHistoryResponse robustness -----

test "ELE-3: parseUtxoResponse parses canonical response" {
    const allocator = std.testing.allocator;
    const json =
        \\{"jsonrpc":"2.0","result":[
        \\  {"tx_hash":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","tx_pos":0,"value":50000,"height":800000},
        \\  {"tx_hash":"fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210","tx_pos":1,"value":25000,"height":800001}
        \\],"id":2}
    ;
    const utxos = try parseUtxoResponse(allocator, json);
    defer allocator.free(utxos);

    try std.testing.expectEqual(@as(usize, 2), utxos.len);
    try std.testing.expectEqual(@as(u32, 0), utxos[0].vout);
    try std.testing.expectEqual(@as(u64, 50000), utxos[0].value);
    try std.testing.expectEqual(@as(u32, 800000), utxos[0].height);
    try std.testing.expectEqual(@as(u32, 1), utxos[1].vout);
    try std.testing.expectEqual(@as(u64, 25000), utxos[1].value);
}

test "ELE-3: UTXO with `}` inside a string value parses correctly (brace-depth fix)" {
    // Pre-audit: the parser walked `{` and `}` to find object boundaries
    // WITHOUT considering quoted strings. A future server-added field
    // containing `}` (e.g. base64, or a JSON-encoded inner field) would
    // make depth go to 0 mid-object, splitting it across two iterations.
    const allocator = std.testing.allocator;
    const json =
        \\{"jsonrpc":"2.0","result":[
        \\  {"tx_hash":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","note":"has } brace","tx_pos":0,"value":42,"height":1}
        \\],"id":2}
    ;
    const utxos = try parseUtxoResponse(allocator, json);
    defer allocator.free(utxos);

    try std.testing.expectEqual(@as(usize, 1), utxos.len);
    try std.testing.expectEqual(@as(u64, 42), utxos[0].value);
    try std.testing.expectEqual(@as(u32, 1), utxos[0].height);
}

test "ELE-3: parseUtxoResponse missing `result` yields empty slice (back-compat)" {
    const allocator = std.testing.allocator;
    const json = "{\"jsonrpc\":\"2.0\",\"id\":1}";
    const utxos = try parseUtxoResponse(allocator, json);
    defer allocator.free(utxos);
    try std.testing.expectEqual(@as(usize, 0), utxos.len);
}

test "ELE-3: parseUtxoResponse non-array `result` errors" {
    const allocator = std.testing.allocator;
    const json = "{\"jsonrpc\":\"2.0\",\"result\":\"oops\",\"id\":1}";
    try std.testing.expectError(error.ParseError, parseUtxoResponse(allocator, json));
}

test "ELE-3: UTXO entry with wrong-length tx_hash is skipped, not parsed as garbage" {
    const allocator = std.testing.allocator;
    const json =
        \\{"jsonrpc":"2.0","result":[
        \\  {"tx_hash":"too_short","tx_pos":0,"value":42,"height":1},
        \\  {"tx_hash":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","tx_pos":0,"value":42,"height":1}
        \\],"id":2}
    ;
    const utxos = try parseUtxoResponse(allocator, json);
    defer allocator.free(utxos);

    // First entry skipped (bad tx_hash); only the second is returned.
    try std.testing.expectEqual(@as(usize, 1), utxos.len);
}

test "ELE-3: parseHistoryResponse handles negative height (unconfirmed-with-unconfirmed-parents)" {
    const allocator = std.testing.allocator;
    const json =
        \\{"jsonrpc":"2.0","result":[
        \\  {"tx_hash":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","height":-1,"fee":1500}
        \\],"id":3}
    ;
    const entries = try parseHistoryResponse(allocator, json);
    defer allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(i32, -1), entries[0].height);
    try std.testing.expectEqual(@as(u64, 1500), entries[0].fee);
}

test "ELE-3: parseHistoryResponse handles missing optional fee field" {
    const allocator = std.testing.allocator;
    const json =
        \\{"jsonrpc":"2.0","result":[
        \\  {"tx_hash":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","height":42}
        \\],"id":3}
    ;
    const entries = try parseHistoryResponse(allocator, json);
    defer allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(i32, 42), entries[0].height);
    try std.testing.expectEqual(@as(u64, 0), entries[0].fee);
}

// ============================================================================
// F1 — void-params wire shape
// ============================================================================

test "F1: void params serialize as an empty JSON array, not a string" {
    // Regression guard for the wire bug that broke quantum_vault's
    // block-height lookup: a void-params request (headers.subscribe) must
    // emit `"params":[]`, never `"params":""`. JSON-RPC 2.0 §4 requires
    // params to be an array or object; ElectrumX rejects a string.
    const allocator = std.testing.allocator;
    const request = try buildRequest(allocator, "blockchain.headers.subscribe", {}, 1);
    defer allocator.free(request);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, request, .{});
    defer parsed.deinit();
    const params = parsed.value.object.get("params").?;
    try std.testing.expect(params == .array);
    try std.testing.expectEqual(@as(usize, 0), params.array.items.len);
}

// ============================================================================
// F2 — ffi-parser rewrites, anchored to external Bitcoin/ElectrumX vectors
// ============================================================================

test "external anchor: broadcast response yields the real first-ever Bitcoin txid" {
    // The result string is the txid of the first Bitcoin peer-to-peer
    // transaction (Satoshi Nakamoto -> Hal Finney, mainnet block 170,
    // 2009-01-12). It is a fixed value publicly recorded on the Bitcoin
    // blockchain and reproducible on any block explorer (e.g.
    // blockstream.info / mempool.space):
    //   f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e8b
    const json =
        \\{"jsonrpc":"2.0","result":"f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e8b","id":1}
    ;
    const txid = try parseBroadcastResponse(json);
    try std.testing.expectEqualSlices(
        u8,
        "f4184fc596403b9d638783cf57adfe4c75c605f6356fbc91338530e9831e9e8b",
        &txid,
    );
}

test "F2: broadcast error response is rejected, not reported as a successful txid" {
    // Older Electrum servers return broadcast failures as an error object.
    // The pre-fix substring parser checked `"error"` only AFTER matching
    // `"result":"` — this must now surface as a server error.
    const json =
        \\{"jsonrpc":"2.0","error":{"code":1,"message":"transaction already in block chain"},"id":1}
    ;
    try std.testing.expectError(error.ServerError, parseBroadcastResponse(json));
}

test "F2: short string broadcast result is not accepted as a txid" {
    // Pre-fix, `"result":"ok"` copied 64 bytes starting at the `o`, dragging
    // in trailing JSON as a fake txid. Now it is rejected.
    const json =
        \\{"jsonrpc":"2.0","result":"ok","id":1}
    ;
    try std.testing.expectError(error.ParseError, parseBroadcastResponse(json));
}

test "external anchor: get_tx yields the Bitcoin genesis coinbase raw transaction" {
    // The result is the raw hex of the coinbase transaction embedded in
    // Bitcoin's genesis block (block 0). It is an immutable, publicly
    // documented constant (Bitcoin Core `chainparams.cpp`, and quoted in
    // the whitepaper-era genesis: the "Chancellor on brink..." message).
    const allocator = std.testing.allocator;
    const genesis_tx = "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000";
    const json = "{\"jsonrpc\":\"2.0\",\"result\":\"" ++ genesis_tx ++ "\",\"id\":1}";
    const raw = try parseTxResponse(allocator, json);
    defer allocator.free(raw);
    try std.testing.expectEqualSlices(u8, genesis_tx, raw);
}

test "F2: get_tx error response is rejected" {
    const json =
        \\{"jsonrpc":"2.0","error":{"code":-32603,"message":"daemon error"},"id":1}
    ;
    try std.testing.expectError(error.ServerError, parseTxResponse(std.testing.allocator, json));
}

test "external anchor: headers.subscribe yields the ElectrumX-documented block height" {
    // Example response from the ElectrumX protocol documentation
    // (electrumx.readthedocs.io, protocol-methods, blockchain.headers.subscribe):
    // an 80-byte serialized mainnet block header at height 520481.
    const json =
        \\{"jsonrpc":"2.0","result":{"height":520481,"hex":"00000020890208a0ae3a3892aa047c5468725846577cfcd9b512b50000000000000000005dc2b02f2d297a9064ee103036c14d678f9afc7e3d9409cf53fd58b82e938e8ecbeca05a2d2103188ce804c4"},"id":1}
    ;
    const height = try parseHeadersResponse(json);
    try std.testing.expectEqual(@as(u32, 520481), height);
}

test "F2: headers response substring `\"height\":` inside an error message is not parsed" {
    // Pre-fix, this matched `"height":` anywhere in the document. Now an
    // error response (no object `result`) is rejected.
    const json =
        \\{"jsonrpc":"2.0","error":{"code":-32601,"message":"no such height: 999"},"id":1}
    ;
    try std.testing.expectError(error.ServerError, parseHeadersResponse(json));
}
