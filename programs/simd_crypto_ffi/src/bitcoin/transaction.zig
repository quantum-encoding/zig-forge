// =============================================================================
// Bitcoin Transaction Serialization
// =============================================================================
// This module provides high-performance parsing and serialization of Bitcoin
// transactions. It supports both legacy and SegWit (BIP141) transaction formats.
//
// Reference: https://en.bitcoin.it/wiki/Transaction
// SegWit: https://github.com/bitcoin/bips/blob/master/bip-0141.mediawiki
// =============================================================================

const std = @import("std");

// =============================================================================
// Constants
// =============================================================================

/// Maximum number of inputs/outputs we'll parse (prevent DoS)
pub const MAX_INPUTS: usize = 4096;
pub const MAX_OUTPUTS: usize = 4096;
pub const MAX_SCRIPT_SIZE: usize = 10000;
pub const MAX_WITNESS_ITEMS: usize = 500;

// SegWit marker and flag bytes
const SEGWIT_MARKER: u8 = 0x00;
const SEGWIT_FLAG: u8 = 0x01;

// =============================================================================
// Script Types
// =============================================================================

/// Standard Bitcoin script types
pub const ScriptType = enum(u8) {
    /// Pay to Public Key Hash (most common legacy format)
    /// OP_DUP OP_HASH160 <20-byte-hash> OP_EQUALVERIFY OP_CHECKSIG
    p2pkh = 0,

    /// Pay to Script Hash (legacy multisig, etc.)
    /// OP_HASH160 <20-byte-hash> OP_EQUAL
    p2sh = 1,

    /// Pay to Witness Public Key Hash (native SegWit)
    /// OP_0 <20-byte-hash>
    p2wpkh = 2,

    /// Pay to Witness Script Hash (native SegWit multisig)
    /// OP_0 <32-byte-hash>
    p2wsh = 3,

    /// Pay to Taproot (BIP341)
    /// OP_1 <32-byte-key>
    p2tr = 4,

    /// Pay to Public Key (old style, rarely used)
    /// <pubkey> OP_CHECKSIG
    p2pk = 5,

    /// OP_RETURN data carrier (unspendable)
    op_return = 6,

    /// Multisig (bare, not wrapped in P2SH)
    multisig = 7,

    /// Unknown or non-standard script
    unknown = 255,
};

// Bitcoin opcodes we need for script detection
const OP_0: u8 = 0x00;
const OP_PUSHDATA1: u8 = 0x4c;
const OP_PUSHDATA2: u8 = 0x4d;
const OP_PUSHDATA4: u8 = 0x4e;
const OP_1: u8 = 0x51;
const OP_16: u8 = 0x60;
const OP_RETURN: u8 = 0x6a;
const OP_DUP: u8 = 0x76;
const OP_EQUAL: u8 = 0x87;
const OP_EQUALVERIFY: u8 = 0x88;
const OP_HASH160: u8 = 0xa9;
const OP_CHECKSIG: u8 = 0xac;
const OP_CHECKMULTISIG: u8 = 0xae;

// =============================================================================
// Transaction Structures
// =============================================================================

/// Bitcoin OutPoint - reference to a previous transaction output
pub const OutPoint = struct {
    /// Previous transaction hash (32 bytes, little-endian)
    txid: [32]u8,
    /// Output index in the previous transaction
    vout: u32,
};

/// Bitcoin transaction input
pub const TxInput = struct {
    /// Reference to previous output being spent
    prevout: OutPoint,
    /// Unlocking script (scriptSig)
    script_sig: []const u8,
    /// Sequence number (used for RBF, locktime)
    sequence: u32,
    /// Witness data (SegWit only, empty for legacy)
    witness: []const []const u8,
};

/// Bitcoin transaction output
pub const TxOutput = struct {
    /// Value in satoshis
    value: u64,
    /// Locking script (scriptPubKey)
    script_pubkey: []const u8,
    /// Detected script type
    script_type: ScriptType,
    /// Extracted address hash (20 or 32 bytes depending on type)
    address_hash: ?[]const u8,
};

/// Parsed Bitcoin transaction
pub const Transaction = struct {
    /// Transaction version (usually 1 or 2)
    version: i32,
    /// Transaction inputs
    inputs: []const TxInput,
    /// Transaction outputs
    outputs: []const TxOutput,
    /// Lock time (block height or timestamp)
    locktime: u32,
    /// Whether this is a SegWit transaction
    is_segwit: bool,
    /// Raw transaction size in bytes
    raw_size: usize,
    /// Virtual size (for fee calculation, SegWit discount)
    vsize: usize,
    /// Weight units (SegWit)
    weight: usize,
};

// =============================================================================
// Parsing Errors
// =============================================================================

pub const ParseError = error{
    /// Input buffer too short
    UnexpectedEof,
    /// Too many inputs
    TooManyInputs,
    /// Too many outputs
    TooManyOutputs,
    /// Script exceeds maximum size
    ScriptTooLarge,
    /// Invalid varint encoding
    InvalidVarint,
    /// Invalid SegWit marker
    InvalidSegwitMarker,
    /// Out of memory
    OutOfMemory,
    /// Witness data for non-segwit transaction
    UnexpectedWitness,
    /// Too many witness items
    TooManyWitnessItems,
};

// =============================================================================
// Varint Parsing (Bitcoin's CompactSize)
// =============================================================================

/// Read a Bitcoin varint (CompactSize) from the buffer
/// Returns the value and advances the offset
pub fn readVarint(data: []const u8, offset: *usize) ParseError!u64 {
    if (offset.* >= data.len) return ParseError.UnexpectedEof;

    const first = data[offset.*];
    offset.* += 1;

    if (first < 0xfd) {
        return first;
    } else if (first == 0xfd) {
        if (offset.* + 2 > data.len) return ParseError.UnexpectedEof;
        const value = std.mem.readInt(u16, data[offset.*..][0..2], .little);
        offset.* += 2;
        return value;
    } else if (first == 0xfe) {
        if (offset.* + 4 > data.len) return ParseError.UnexpectedEof;
        const value = std.mem.readInt(u32, data[offset.*..][0..4], .little);
        offset.* += 4;
        return value;
    } else {
        if (offset.* + 8 > data.len) return ParseError.UnexpectedEof;
        const value = std.mem.readInt(u64, data[offset.*..][0..8], .little);
        offset.* += 8;
        return value;
    }
}

/// Read fixed number of bytes from buffer
fn readBytes(data: []const u8, offset: *usize, len: usize) ParseError![]const u8 {
    if (offset.* + len > data.len) return ParseError.UnexpectedEof;
    const result = data[offset.* .. offset.* + len];
    offset.* += len;
    return result;
}

/// Read a 32-bit little-endian integer
fn readU32(data: []const u8, offset: *usize) ParseError!u32 {
    if (offset.* + 4 > data.len) return ParseError.UnexpectedEof;
    const value = std.mem.readInt(u32, data[offset.*..][0..4], .little);
    offset.* += 4;
    return value;
}

/// Read a 64-bit little-endian integer
fn readU64(data: []const u8, offset: *usize) ParseError!u64 {
    if (offset.* + 8 > data.len) return ParseError.UnexpectedEof;
    const value = std.mem.readInt(u64, data[offset.*..][0..8], .little);
    offset.* += 8;
    return value;
}

/// Read a 32-bit signed little-endian integer
fn readI32(data: []const u8, offset: *usize) ParseError!i32 {
    if (offset.* + 4 > data.len) return ParseError.UnexpectedEof;
    const value = std.mem.readInt(i32, data[offset.*..][0..4], .little);
    offset.* += 4;
    return value;
}

// =============================================================================
// Script Analysis
// =============================================================================

/// Detect the script type and extract address hash if applicable
pub fn analyzeScript(script: []const u8) struct { script_type: ScriptType, address_hash: ?[]const u8 } {
    const len = script.len;

    // P2PKH: OP_DUP OP_HASH160 <20 bytes> OP_EQUALVERIFY OP_CHECKSIG (25 bytes)
    if (len == 25 and
        script[0] == OP_DUP and
        script[1] == OP_HASH160 and
        script[2] == 20 and
        script[23] == OP_EQUALVERIFY and
        script[24] == OP_CHECKSIG)
    {
        return .{ .script_type = .p2pkh, .address_hash = script[3..23] };
    }

    // P2SH: OP_HASH160 <20 bytes> OP_EQUAL (23 bytes)
    if (len == 23 and
        script[0] == OP_HASH160 and
        script[1] == 20 and
        script[22] == OP_EQUAL)
    {
        return .{ .script_type = .p2sh, .address_hash = script[2..22] };
    }

    // P2WPKH: OP_0 <20 bytes> (22 bytes)
    if (len == 22 and script[0] == OP_0 and script[1] == 20) {
        return .{ .script_type = .p2wpkh, .address_hash = script[2..22] };
    }

    // P2WSH: OP_0 <32 bytes> (34 bytes)
    if (len == 34 and script[0] == OP_0 and script[1] == 32) {
        return .{ .script_type = .p2wsh, .address_hash = script[2..34] };
    }

    // P2TR: OP_1 <32 bytes> (34 bytes)
    if (len == 34 and script[0] == OP_1 and script[1] == 32) {
        return .{ .script_type = .p2tr, .address_hash = script[2..34] };
    }

    // P2PK: <33 or 65 byte pubkey> OP_CHECKSIG
    if ((len == 35 or len == 67) and script[len - 1] == OP_CHECKSIG) {
        const pubkey_len = script[0];
        if ((pubkey_len == 33 or pubkey_len == 65) and pubkey_len + 2 == len) {
            return .{ .script_type = .p2pk, .address_hash = null };
        }
    }

    // OP_RETURN: OP_RETURN <data>
    if (len >= 1 and script[0] == OP_RETURN) {
        return .{ .script_type = .op_return, .address_hash = null };
    }

    // Bare multisig: OP_M <pubkeys...> OP_N OP_CHECKMULTISIG
    if (len >= 3 and script[len - 1] == OP_CHECKMULTISIG) {
        const first = script[0];
        if (first >= OP_1 and first <= OP_16) {
            return .{ .script_type = .multisig, .address_hash = null };
        }
    }

    return .{ .script_type = .unknown, .address_hash = null };
}

// =============================================================================
// Transaction Parsing
// =============================================================================

/// Parse a Bitcoin transaction from raw bytes
/// Allocator is used for dynamic arrays (inputs, outputs, witness data)
pub fn parseTransaction(allocator: std.mem.Allocator, data: []const u8) ParseError!Transaction {
    var offset: usize = 0;
    const start_offset: usize = 0;

    // Version (4 bytes)
    const version = try readI32(data, &offset);

    // Check for SegWit marker
    var is_segwit = false;
    if (offset + 2 <= data.len and data[offset] == SEGWIT_MARKER and data[offset + 1] == SEGWIT_FLAG) {
        is_segwit = true;
        offset += 2;
    }

    // Input count
    const input_count = try readVarint(data, &offset);
    if (input_count > MAX_INPUTS) return ParseError.TooManyInputs;

    // Parse inputs
    const inputs = allocator.alloc(TxInput, @intCast(input_count)) catch return ParseError.OutOfMemory;
    errdefer allocator.free(inputs);

    for (inputs) |*input| {
        // Previous output hash (32 bytes)
        const txid_bytes = try readBytes(data, &offset, 32);
        var txid: [32]u8 = undefined;
        @memcpy(&txid, txid_bytes);

        // Previous output index
        const vout = try readU32(data, &offset);

        // Script length and data
        const script_len = try readVarint(data, &offset);
        if (script_len > MAX_SCRIPT_SIZE) return ParseError.ScriptTooLarge;
        const script_sig = try readBytes(data, &offset, @intCast(script_len));

        // Sequence
        const sequence = try readU32(data, &offset);

        input.* = TxInput{
            .prevout = OutPoint{ .txid = txid, .vout = vout },
            .script_sig = script_sig,
            .sequence = sequence,
            .witness = &[_][]const u8{},
        };
    }

    // Free any per-input witness arrays allocated below if parsing fails after
    // this point. Each input starts with an empty witness (len 0), so inputs
    // whose witness array was never allocated are skipped. Registered before the
    // outputs `errdefer` so it runs first (LIFO) on the error path.
    errdefer for (inputs) |inp| {
        if (inp.witness.len > 0) allocator.free(inp.witness);
    };

    // Output count
    const output_count = try readVarint(data, &offset);
    if (output_count > MAX_OUTPUTS) return ParseError.TooManyOutputs;

    // Parse outputs
    const outputs = allocator.alloc(TxOutput, @intCast(output_count)) catch return ParseError.OutOfMemory;
    errdefer allocator.free(outputs);

    for (outputs) |*output| {
        // Value (8 bytes, satoshis)
        const value = try readU64(data, &offset);

        // Script length and data
        const script_len = try readVarint(data, &offset);
        if (script_len > MAX_SCRIPT_SIZE) return ParseError.ScriptTooLarge;
        const script_pubkey = try readBytes(data, &offset, @intCast(script_len));

        // Analyze script type
        const analysis = analyzeScript(script_pubkey);

        output.* = TxOutput{
            .value = value,
            .script_pubkey = script_pubkey,
            .script_type = analysis.script_type,
            .address_hash = analysis.address_hash,
        };
    }

    // Parse witness data if SegWit
    const witness_start = offset;
    if (is_segwit) {
        for (inputs) |*input| {
            const witness_count = try readVarint(data, &offset);
            if (witness_count > MAX_WITNESS_ITEMS) return ParseError.TooManyWitnessItems;

            const witness_items = allocator.alloc([]const u8, @intCast(witness_count)) catch return ParseError.OutOfMemory;
            // Assign immediately so the errdefer above frees this array even if
            // an item-length read below fails part-way through the loop.
            input.witness = witness_items;

            for (witness_items) |*item| {
                const item_len = try readVarint(data, &offset);
                if (item_len > MAX_SCRIPT_SIZE) return ParseError.ScriptTooLarge;
                item.* = try readBytes(data, &offset, @intCast(item_len));
            }
        }
    }
    const witness_end = offset;

    // Locktime (4 bytes)
    const locktime = try readU32(data, &offset);

    // Calculate sizes
    const raw_size = offset - start_offset;

    // Weight and vsize calculation (BIP141)
    // weight = base_size * 3 + total_size
    // vsize = ceil(weight / 4)
    const witness_size = witness_end - witness_start;
    const base_size = raw_size - witness_size - (if (is_segwit) @as(usize, 2) else @as(usize, 0)); // Subtract marker/flag
    const weight = base_size * 3 + raw_size;
    const vsize = (weight + 3) / 4;

    return Transaction{
        .version = version,
        .inputs = inputs,
        .outputs = outputs,
        .locktime = locktime,
        .is_segwit = is_segwit,
        .raw_size = raw_size,
        .vsize = vsize,
        .weight = weight,
    };
}

/// Free transaction memory
pub fn freeTransaction(allocator: std.mem.Allocator, tx: *const Transaction) void {
    // Free witness data
    for (tx.inputs) |input| {
        if (input.witness.len > 0) {
            allocator.free(input.witness);
        }
    }
    allocator.free(tx.inputs);
    allocator.free(tx.outputs);
}

// =============================================================================
// Utility Functions
// =============================================================================

/// Compute a transaction's txid: SHA256d over the legacy (witness-stripped)
/// serialization — version ‖ inputs ‖ outputs ‖ locktime, excluding the SegWit
/// marker/flag and all witness stacks (BIP141).
///
/// The result is in Bitcoin's INTERNAL byte order (little-endian). To display
/// the txid as the familiar big-endian hex string, reverse the 32 bytes.
///
/// Unlike a naive `SHA256d(raw)`, this is correct for SegWit transactions: the
/// witness data is not committed to by the txid (it lives in the wtxid instead),
/// so it must be stripped before hashing or every modern tx yields a wrong id.
///
/// Returns a parse error if the buffer is not a structurally valid transaction.
pub fn computeTxid(data: []const u8) ParseError![32]u8 {
    var offset: usize = 0;

    // Version (4 bytes)
    if (data.len < 4) return ParseError.UnexpectedEof;
    offset = 4;

    // SegWit marker (0x00) + flag (0x01) come between version and input count.
    var is_segwit = false;
    if (offset + 2 <= data.len and data[offset] == SEGWIT_MARKER and data[offset + 1] == SEGWIT_FLAG) {
        is_segwit = true;
        offset += 2;
    }

    // Start of the legacy body (input count varint). For a legacy tx this is
    // offset 4; for SegWit it is offset 6 (marker/flag skipped).
    const body_start = offset;

    // Inputs
    const input_count = try readVarint(data, &offset);
    if (input_count > MAX_INPUTS) return ParseError.TooManyInputs;
    var i: usize = 0;
    while (i < input_count) : (i += 1) {
        _ = try readBytes(data, &offset, 32); // prevout txid
        _ = try readU32(data, &offset); // prevout vout
        const script_len = try readVarint(data, &offset);
        if (script_len > MAX_SCRIPT_SIZE) return ParseError.ScriptTooLarge;
        _ = try readBytes(data, &offset, @intCast(script_len)); // scriptSig
        _ = try readU32(data, &offset); // sequence
    }

    // Outputs
    const output_count = try readVarint(data, &offset);
    if (output_count > MAX_OUTPUTS) return ParseError.TooManyOutputs;
    var j: usize = 0;
    while (j < output_count) : (j += 1) {
        _ = try readU64(data, &offset); // value
        const script_len = try readVarint(data, &offset);
        if (script_len > MAX_SCRIPT_SIZE) return ParseError.ScriptTooLarge;
        _ = try readBytes(data, &offset, @intCast(script_len)); // scriptPubKey
    }

    // End of the legacy body (= witness_start for a SegWit tx).
    const body_end = offset;

    // Skip witness stacks (one per input) if present — they are NOT hashed.
    if (is_segwit) {
        var w_in: usize = 0;
        while (w_in < input_count) : (w_in += 1) {
            const witness_count = try readVarint(data, &offset);
            if (witness_count > MAX_WITNESS_ITEMS) return ParseError.TooManyWitnessItems;
            var w: usize = 0;
            while (w < witness_count) : (w += 1) {
                const item_len = try readVarint(data, &offset);
                if (item_len > MAX_SCRIPT_SIZE) return ParseError.ScriptTooLarge;
                _ = try readBytes(data, &offset, @intCast(item_len));
            }
        }
    }

    // Locktime (4 bytes)
    if (offset + 4 > data.len) return ParseError.UnexpectedEof;
    const locktime_start = offset;

    // Hash the reconstructed legacy serialization in three contiguous pieces,
    // without allocating: version ‖ body(inputs+outputs) ‖ locktime.
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var hasher = Sha256.init(.{});
    hasher.update(data[0..4]);
    hasher.update(data[body_start..body_end]);
    hasher.update(data[locktime_start .. locktime_start + 4]);
    var first_hash: [32]u8 = undefined;
    hasher.final(&first_hash);

    var txid: [32]u8 = undefined;
    Sha256.hash(&first_hash, &txid, .{});
    return txid;
}

/// Get total input value (requires looking up previous outputs - returns 0 here)
/// Note: Actual value requires UTXO lookup, this is a placeholder
pub fn getTotalOutputValue(tx: *const Transaction) u64 {
    var total: u64 = 0;
    for (tx.outputs) |output| {
        total += output.value;
    }
    return total;
}

// =============================================================================
// Tests
// =============================================================================

test "varint parsing" {
    // Single byte
    {
        var offset: usize = 0;
        const data = [_]u8{0x42};
        const value = try readVarint(&data, &offset);
        try std.testing.expectEqual(@as(u64, 0x42), value);
        try std.testing.expectEqual(@as(usize, 1), offset);
    }

    // Two bytes (0xfd prefix)
    {
        var offset: usize = 0;
        const data = [_]u8{ 0xfd, 0x34, 0x12 };
        const value = try readVarint(&data, &offset);
        try std.testing.expectEqual(@as(u64, 0x1234), value);
        try std.testing.expectEqual(@as(usize, 3), offset);
    }

    // Four bytes (0xfe prefix)
    {
        var offset: usize = 0;
        const data = [_]u8{ 0xfe, 0x78, 0x56, 0x34, 0x12 };
        const value = try readVarint(&data, &offset);
        try std.testing.expectEqual(@as(u64, 0x12345678), value);
        try std.testing.expectEqual(@as(usize, 5), offset);
    }
}

test "script type detection - P2PKH" {
    // Standard P2PKH script: OP_DUP OP_HASH160 <20 bytes> OP_EQUALVERIFY OP_CHECKSIG
    const script = [_]u8{
        0x76, 0xa9, 0x14, // OP_DUP OP_HASH160 PUSH(20)
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a,
        0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, // 20-byte hash
        0x88, 0xac, // OP_EQUALVERIFY OP_CHECKSIG
    };

    const result = analyzeScript(&script);
    try std.testing.expectEqual(ScriptType.p2pkh, result.script_type);
    try std.testing.expect(result.address_hash != null);
    try std.testing.expectEqual(@as(usize, 20), result.address_hash.?.len);
}

test "script type detection - P2WPKH" {
    // Native SegWit P2WPKH: OP_0 <20 bytes>
    const script = [_]u8{
        0x00, 0x14, // OP_0 PUSH(20)
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a,
        0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, // 20-byte hash
    };

    const result = analyzeScript(&script);
    try std.testing.expectEqual(ScriptType.p2wpkh, result.script_type);
    try std.testing.expect(result.address_hash != null);
}

test "script type detection - P2TR" {
    // Taproot P2TR: OP_1 <32 bytes>
    var script: [34]u8 = undefined;
    script[0] = 0x51; // OP_1
    script[1] = 0x20; // PUSH(32)
    for (2..34) |i| {
        script[i] = @intCast(i);
    }

    const result = analyzeScript(&script);
    try std.testing.expectEqual(ScriptType.p2tr, result.script_type);
    try std.testing.expect(result.address_hash != null);
    try std.testing.expectEqual(@as(usize, 32), result.address_hash.?.len);
}

test "script type detection - OP_RETURN" {
    const script = [_]u8{
        0x6a, // OP_RETURN
        0x04, 0x74, 0x65, 0x73, 0x74, // "test"
    };

    const result = analyzeScript(&script);
    try std.testing.expectEqual(ScriptType.op_return, result.script_type);
    try std.testing.expect(result.address_hash == null);
}

// Regression: a SegWit tx that allocates a per-input witness array and then
// fails mid-parse (truncated witness item) must NOT leak that array. The bug
// (fixed 3c9d392) assigned `input.witness = witness_items` only AFTER the
// item-read loop, so a failure inside the loop left the allocation unowned and
// unfreed. `std.testing.allocator` fails the test on any leak, so this guards
// the errdefer + early-assign fix directly.
// External anchor: SegWit txid witness-stripping.
//
// Vector is the coinbase transaction of Bitcoin mainnet block 500,000, fetched
// as raw hex from the Blockstream Esplora block explorer
//   https://blockstream.info/api/tx/2157b554dcfda405233906e461ee593875ae4b1b97615872db6a25130ecc1dd6/hex
// The explorer (a third party this repo did not author) asserts that this exact
// byte string has display-order txid
//   2157b554dcfda405233906e461ee593875ae4b1b97615872db6a25130ecc1dd6
// This is a SegWit tx (marker/flag 0x0001, coinbase witness reserved value), so
// a naive SHA256d(raw) gives the WRONG answer — the test only passes if the
// marker/flag and witness stack are stripped before hashing.
test "computeTxid — SegWit coinbase (block 500000, Blockstream-anchored)" {
    const raw_hex = "010000000001010000000000000000000000000000000000000000000000000000000000000000ffffffff4b0320a107046f0a385a632f4254432e434f4d2ffabe6d6dbdd0ee86f9a1badfd0aa1b3c9dac8d90840cf973f7b2590d6c9adde1a6e0974a010000000000000001283da9a172020000000000ffffffff02c994bb5e0000000017a914228f554bbf766d6f9cc828de1126e3d35d15e5fe870000000000000000266a24aa21a9ed10109f4b82aa3ed7ec9d02a2a90246478b3308c8b85daf62fe501d58d05727a40120000000000000000000000000000000000000000000000000000000000000000000000000";
    var raw: [raw_hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&raw, raw_hex);

    const txid_internal = try computeTxid(&raw);

    // computeTxid returns internal (little-endian) order; reverse for display.
    var display: [32]u8 = undefined;
    for (0..32) |k| display[k] = txid_internal[31 - k];

    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "2157b554dcfda405233906e461ee593875ae4b1b97615872db6a25130ecc1dd6");
    try std.testing.expectEqualSlices(u8, &expected, &display);
}

// External anchor: legacy (non-SegWit) txid.
//
// Vector is the Bitcoin genesis-block coinbase, whose txid
//   4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b
// is one of the most widely published constants in Bitcoin; raw hex fetched from
//   https://blockstream.info/api/tx/4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b/hex
// Confirms the legacy path (no marker/flag, no witness) is unchanged.
test "computeTxid — legacy genesis coinbase (Blockstream-anchored)" {
    const raw_hex = "01000000010000000000000000000000000000000000000000000000000000000000000000ffffffff4d04ffff001d0104455468652054696d65732030332f4a616e2f32303039204368616e63656c6c6f72206f6e206272696e6b206f66207365636f6e64206261696c6f757420666f722062616e6b73ffffffff0100f2052a01000000434104678afdb0fe5548271967f1a67130b7105cd6a828e03909a67962e0ea1f61deb649f6bc3f4cef38c4f35504e51ec112de5c384df7ba0b8d578a4c702b6bf11d5fac00000000";
    var raw: [raw_hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&raw, raw_hex);

    const txid_internal = try computeTxid(&raw);

    var display: [32]u8 = undefined;
    for (0..32) |k| display[k] = txid_internal[31 - k];

    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b");
    try std.testing.expectEqualSlices(u8, &expected, &display);
}

test "parseTransaction frees witness array when a witness item read fails (no leak)" {
    // Minimal SegWit tx, well-formed up to the witness item bytes:
    //   version | marker+flag | 1 input | 1 output | witness_count=1 | item_len=5
    // then the 5 item bytes are missing -> readBytes returns UnexpectedEof
    // AFTER the 1-element witness array has been allocated.
    const raw = [_]u8{
        0x02, 0x00, 0x00, 0x00, // version 2
        0x00, 0x01, // SegWit marker + flag
        0x01, // input count = 1
    } ++ [_]u8{0x11} ** 32 // prev txid
    ++ [_]u8{
        0x00, 0x00, 0x00, 0x00, // vout 0
        0x00, // scriptSig len 0
        0xff, 0xff, 0xff, 0xff, // sequence
        0x01, // output count = 1
        0x00, 0xe1, 0xf5, 0x05, 0x00, 0x00, 0x00, 0x00, // value 100_000_000
        0x00, // scriptPubKey len 0
        0x01, // input 0 witness stack count = 1  -> allocates witness_items[1]
        0x05, // item 0 length = 5  -> readBytes needs 5 more bytes, none remain
    };

    const result = parseTransaction(std.testing.allocator, &raw);
    try std.testing.expectError(ParseError.UnexpectedEof, result);
    // If the test reaches here without std.testing.allocator reporting a leak,
    // the witness array was freed on the error path.
}
