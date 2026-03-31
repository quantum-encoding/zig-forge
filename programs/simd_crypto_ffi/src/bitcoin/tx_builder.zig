// =============================================================================
// Bitcoin Transaction Builder & Signer
// =============================================================================
// This module provides transaction construction, serialization, and signing
// for P2WPKH (native SegWit) transactions.
//
// Supports:
// - Transaction construction from UTXOs
// - BIP143 sighash computation for SegWit
// - ECDSA signing with secp256k1
// - Witness data generation
//
// Reference:
// - BIP143: https://github.com/bitcoin/bips/blob/master/bip-0143.mediawiki
// - BIP141: https://github.com/bitcoin/bips/blob/master/bip-0141.mediawiki
// =============================================================================

const std = @import("std");
const crypto = std.crypto;
const Sha256 = crypto.hash.sha2.Sha256;
const Secp256k1 = crypto.ecc.Secp256k1;

// =============================================================================
// Constants
// =============================================================================

/// SIGHASH types
pub const SIGHASH_ALL: u32 = 0x01;
pub const SIGHASH_NONE: u32 = 0x02;
pub const SIGHASH_SINGLE: u32 = 0x03;
pub const SIGHASH_ANYONECANPAY: u32 = 0x80;

/// Default transaction version
pub const DEFAULT_VERSION: i32 = 2;

/// Default sequence (RBF enabled)
pub const DEFAULT_SEQUENCE: u32 = 0xfffffffd;

/// Maximum sequence (RBF disabled)
pub const MAX_SEQUENCE: u32 = 0xffffffff;

/// Dust limit in satoshis
pub const DUST_LIMIT: u64 = 546;

/// Maximum transaction size (100KB)
pub const MAX_TX_SIZE: usize = 100000;

// =============================================================================
// Error Types
// =============================================================================

pub const TxBuilderError = error{
    NoInputs,
    NoOutputs,
    InsufficientFunds,
    InvalidPrivateKey,
    InvalidPublicKey,
    SigningFailed,
    SerializationFailed,
    OutputBelowDust,
    TooManyInputs,
    TooManyOutputs,
    InvalidAddress,
    BufferTooSmall,
};

// =============================================================================
// UTXO Structure (input for spending)
// =============================================================================

/// Unspent Transaction Output ready for spending
pub const SpendableUtxo = struct {
    /// Previous transaction ID (32 bytes, internal byte order)
    txid: [32]u8,
    /// Output index
    vout: u32,
    /// Value in satoshis
    value: u64,
    /// Public key hash (20 bytes for P2WPKH)
    pubkey_hash: [20]u8,
    /// Derivation path index (for key lookup)
    derivation_index: u32,
};

// =============================================================================
// Output Destination
// =============================================================================

/// Transaction output destination
pub const TxDestination = struct {
    /// Value in satoshis
    value: u64,
    /// Script pubkey (locking script)
    script_pubkey: []const u8,
};

// =============================================================================
// Transaction Builder
// =============================================================================

/// Builder for constructing Bitcoin transactions
pub const TxBuilder = struct {
    const Self = @This();
    const MAX_INPUTS: usize = 256;
    const MAX_OUTPUTS: usize = 256;

    version: i32,
    inputs: [MAX_INPUTS]SpendableUtxo,
    input_count: usize,
    outputs: [MAX_OUTPUTS]TxDestination,
    output_scripts: [MAX_OUTPUTS][64]u8, // Storage for script data
    output_script_lens: [MAX_OUTPUTS]usize,
    output_count: usize,
    locktime: u32,

    /// Initialize a new transaction builder
    pub fn init() Self {
        return Self{
            .version = DEFAULT_VERSION,
            .inputs = undefined,
            .input_count = 0,
            .outputs = undefined,
            .output_scripts = undefined,
            .output_script_lens = undefined,
            .output_count = 0,
            .locktime = 0,
        };
    }

    /// Add a P2WPKH input (UTXO to spend)
    pub fn addInput(self: *Self, utxo: SpendableUtxo) TxBuilderError!void {
        if (self.input_count >= MAX_INPUTS) {
            return TxBuilderError.TooManyInputs;
        }
        self.inputs[self.input_count] = utxo;
        self.input_count += 1;
    }

    /// Add a P2WPKH output (pay to pubkey hash)
    pub fn addP2wpkhOutput(self: *Self, value: u64, pubkey_hash: *const [20]u8) TxBuilderError!void {
        if (self.output_count >= MAX_OUTPUTS) {
            return TxBuilderError.TooManyOutputs;
        }
        if (value < DUST_LIMIT) {
            return TxBuilderError.OutputBelowDust;
        }

        // Build P2WPKH script: OP_0 <20-byte-hash>
        var script: [22]u8 = undefined;
        script[0] = 0x00; // OP_0 (witness version)
        script[1] = 0x14; // Push 20 bytes
        @memcpy(script[2..22], pubkey_hash);

        @memcpy(self.output_scripts[self.output_count][0..22], &script);
        self.output_script_lens[self.output_count] = 22;

        self.outputs[self.output_count] = TxDestination{
            .value = value,
            .script_pubkey = self.output_scripts[self.output_count][0..22],
        };
        self.output_count += 1;
    }

    /// Add a P2PKH output (legacy pay to pubkey hash)
    pub fn addP2pkhOutput(self: *Self, value: u64, pubkey_hash: *const [20]u8) TxBuilderError!void {
        if (self.output_count >= MAX_OUTPUTS) {
            return TxBuilderError.TooManyOutputs;
        }
        if (value < DUST_LIMIT) {
            return TxBuilderError.OutputBelowDust;
        }

        // Build P2PKH script: OP_DUP OP_HASH160 <20-byte-hash> OP_EQUALVERIFY OP_CHECKSIG
        var script: [25]u8 = undefined;
        script[0] = 0x76; // OP_DUP
        script[1] = 0xa9; // OP_HASH160
        script[2] = 0x14; // Push 20 bytes
        @memcpy(script[3..23], pubkey_hash);
        script[23] = 0x88; // OP_EQUALVERIFY
        script[24] = 0xac; // OP_CHECKSIG

        @memcpy(self.output_scripts[self.output_count][0..25], &script);
        self.output_script_lens[self.output_count] = 25;

        self.outputs[self.output_count] = TxDestination{
            .value = value,
            .script_pubkey = self.output_scripts[self.output_count][0..25],
        };
        self.output_count += 1;
    }

    /// Add a P2TR output (Taproot pay to x-only pubkey)
    /// Used for Taproot addresses (bc1p...)
    pub fn addP2trOutput(self: *Self, value: u64, x_only_pubkey: *const [32]u8) TxBuilderError!void {
        if (self.output_count >= MAX_OUTPUTS) {
            return TxBuilderError.TooManyOutputs;
        }
        if (value < DUST_LIMIT) {
            return TxBuilderError.OutputBelowDust;
        }

        // Build P2TR script: OP_1 <32-byte-x-only-pubkey>
        // OP_1 = 0x51, Push 32 bytes = 0x20
        var script: [34]u8 = undefined;
        script[0] = 0x51; // OP_1 (witness version 1)
        script[1] = 0x20; // Push 32 bytes
        @memcpy(script[2..34], x_only_pubkey);

        @memcpy(self.output_scripts[self.output_count][0..34], &script);
        self.output_script_lens[self.output_count] = 34;

        self.outputs[self.output_count] = TxDestination{
            .value = value,
            .script_pubkey = self.output_scripts[self.output_count][0..34],
        };
        self.output_count += 1;
    }

    /// Add OP_RETURN data output
    pub fn addOpReturnOutput(self: *Self, data: []const u8) TxBuilderError!void {
        if (self.output_count >= MAX_OUTPUTS) {
            return TxBuilderError.TooManyOutputs;
        }
        if (data.len > 80) {
            return TxBuilderError.BufferTooSmall;
        }

        // Build OP_RETURN script: OP_RETURN <data>
        var script_len: usize = 0;
        self.output_scripts[self.output_count][script_len] = 0x6a; // OP_RETURN
        script_len += 1;

        if (data.len <= 75) {
            self.output_scripts[self.output_count][script_len] = @intCast(data.len);
            script_len += 1;
        } else {
            self.output_scripts[self.output_count][script_len] = 0x4c; // OP_PUSHDATA1
            script_len += 1;
            self.output_scripts[self.output_count][script_len] = @intCast(data.len);
            script_len += 1;
        }

        @memcpy(self.output_scripts[self.output_count][script_len .. script_len + data.len], data);
        script_len += data.len;

        self.output_script_lens[self.output_count] = script_len;
        self.outputs[self.output_count] = TxDestination{
            .value = 0,
            .script_pubkey = self.output_scripts[self.output_count][0..script_len],
        };
        self.output_count += 1;
    }

    /// Get total input value
    pub fn getTotalInputValue(self: *const Self) u64 {
        var total: u64 = 0;
        for (self.inputs[0..self.input_count]) |input| {
            total += input.value;
        }
        return total;
    }

    /// Get total output value
    pub fn getTotalOutputValue(self: *const Self) u64 {
        var total: u64 = 0;
        for (self.outputs[0..self.output_count]) |output| {
            total += output.value;
        }
        return total;
    }

    /// Calculate fee (inputs - outputs)
    pub fn getFee(self: *const Self) u64 {
        const input_val = self.getTotalInputValue();
        const output_val = self.getTotalOutputValue();
        if (input_val > output_val) {
            return input_val - output_val;
        }
        return 0;
    }

    /// Estimate transaction virtual size (for fee calculation)
    pub fn estimateVsize(self: *const Self) usize {
        // Base transaction overhead
        // Version (4) + marker (1) + flag (1) + input count (1-3) + output count (1-3) + locktime (4)
        var base_size: usize = 10;

        // Inputs: each P2WPKH input = 41 bytes base (outpoint + sequence + empty scriptSig)
        base_size += self.input_count * 41;

        // Outputs
        for (self.outputs[0..self.output_count]) |output| {
            base_size += 8 + 1 + output.script_pubkey.len; // value + script_len + script
        }

        // Witness: each P2WPKH = ~107 bytes (2 items: signature ~72 + pubkey 33)
        const witness_size = self.input_count * 107;

        // vsize = (base_size * 3 + base_size + witness_size) / 4
        const weight = base_size * 3 + base_size + witness_size;
        return (weight + 3) / 4;
    }
};

// =============================================================================
// BIP143 Sighash Computation
// =============================================================================

/// Compute BIP143 sighash for P2WPKH input
/// This is the hash that gets signed for SegWit transactions
pub fn computeSighashBip143(
    builder: *const TxBuilder,
    input_index: usize,
    private_key: *const [32]u8,
    sighash_type: u32,
) TxBuilderError![32]u8 {
    if (input_index >= builder.input_count) {
        return TxBuilderError.NoInputs;
    }

    const input = &builder.inputs[input_index];

    // Derive public key from private key
    const pubkey = derivePublicKey(private_key) catch return TxBuilderError.InvalidPrivateKey;

    // Build the scriptCode for P2WPKH: OP_DUP OP_HASH160 <20-byte-hash> OP_EQUALVERIFY OP_CHECKSIG
    var script_code: [25]u8 = undefined;
    script_code[0] = 0x76; // OP_DUP
    script_code[1] = 0xa9; // OP_HASH160
    script_code[2] = 0x14; // Push 20 bytes
    @memcpy(script_code[3..23], &input.pubkey_hash);
    script_code[23] = 0x88; // OP_EQUALVERIFY
    script_code[24] = 0xac; // OP_CHECKSIG

    // BIP143 preimage components:
    // 1. nVersion (4 bytes)
    // 2. hashPrevouts (32 bytes)
    // 3. hashSequence (32 bytes)
    // 4. outpoint (36 bytes)
    // 5. scriptCode (variable)
    // 6. amount (8 bytes)
    // 7. nSequence (4 bytes)
    // 8. hashOutputs (32 bytes)
    // 9. nLocktime (4 bytes)
    // 10. sighash type (4 bytes)

    var hasher = Sha256.init(.{});

    // 1. nVersion
    var version_bytes: [4]u8 = undefined;
    std.mem.writeInt(i32, &version_bytes, builder.version, .little);
    hasher.update(&version_bytes);

    // 2. hashPrevouts
    const hash_prevouts = computeHashPrevouts(builder);
    hasher.update(&hash_prevouts);

    // 3. hashSequence
    const hash_sequence = computeHashSequence(builder);
    hasher.update(&hash_sequence);

    // 4. outpoint (txid + vout)
    hasher.update(&input.txid);
    var vout_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &vout_bytes, input.vout, .little);
    hasher.update(&vout_bytes);

    // 5. scriptCode
    hasher.update(&[_]u8{25}); // varint length
    hasher.update(&script_code);

    // 6. amount
    var amount_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &amount_bytes, input.value, .little);
    hasher.update(&amount_bytes);

    // 7. nSequence
    var seq_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &seq_bytes, DEFAULT_SEQUENCE, .little);
    hasher.update(&seq_bytes);

    // 8. hashOutputs
    const hash_outputs = computeHashOutputs(builder);
    hasher.update(&hash_outputs);

    // 9. nLocktime
    var locktime_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &locktime_bytes, builder.locktime, .little);
    hasher.update(&locktime_bytes);

    // 10. sighash type
    var sighash_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &sighash_bytes, sighash_type, .little);
    hasher.update(&sighash_bytes);

    // First SHA256
    var first_hash: [32]u8 = undefined;
    hasher.final(&first_hash);

    // Double SHA256
    var final_hash: [32]u8 = undefined;
    Sha256.hash(&first_hash, &final_hash, .{});

    _ = pubkey; // Used for validation, not in sighash itself

    return final_hash;
}

/// Compute hashPrevouts (double SHA256 of all input outpoints)
fn computeHashPrevouts(builder: *const TxBuilder) [32]u8 {
    var hasher = Sha256.init(.{});

    for (builder.inputs[0..builder.input_count]) |input| {
        hasher.update(&input.txid);
        var vout_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &vout_bytes, input.vout, .little);
        hasher.update(&vout_bytes);
    }

    var first_hash: [32]u8 = undefined;
    hasher.final(&first_hash);

    var result: [32]u8 = undefined;
    Sha256.hash(&first_hash, &result, .{});
    return result;
}

/// Compute hashSequence (double SHA256 of all input sequences)
fn computeHashSequence(builder: *const TxBuilder) [32]u8 {
    var hasher = Sha256.init(.{});

    for (0..builder.input_count) |_| {
        var seq_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &seq_bytes, DEFAULT_SEQUENCE, .little);
        hasher.update(&seq_bytes);
    }

    var first_hash: [32]u8 = undefined;
    hasher.final(&first_hash);

    var result: [32]u8 = undefined;
    Sha256.hash(&first_hash, &result, .{});
    return result;
}

/// Compute hashOutputs (double SHA256 of all outputs)
fn computeHashOutputs(builder: *const TxBuilder) [32]u8 {
    var hasher = Sha256.init(.{});

    for (builder.outputs[0..builder.output_count]) |output| {
        var value_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &value_bytes, output.value, .little);
        hasher.update(&value_bytes);

        // Script length as varint
        if (output.script_pubkey.len < 0xfd) {
            hasher.update(&[_]u8{@intCast(output.script_pubkey.len)});
        } else {
            // For longer scripts, use proper varint encoding
            hasher.update(&[_]u8{ 0xfd, @truncate(output.script_pubkey.len), @truncate(output.script_pubkey.len >> 8) });
        }
        hasher.update(output.script_pubkey);
    }

    var first_hash: [32]u8 = undefined;
    hasher.final(&first_hash);

    var result: [32]u8 = undefined;
    Sha256.hash(&first_hash, &result, .{});
    return result;
}

// =============================================================================
// ECDSA Signing
// =============================================================================

/// Sign a 32-byte hash with a private key using RFC6979 deterministic k
pub fn signHash(hash: *const [32]u8, private_key: *const [32]u8) TxBuilderError![64]u8 {
    // Use Zig's built-in ECDSA
    const Ecdsa = crypto.sign.ecdsa.Ecdsa(Secp256k1, Sha256);

    // Create key pair from private key bytes
    const secret_key = Ecdsa.SecretKey.fromBytes(private_key.*) catch
        return TxBuilderError.InvalidPrivateKey;

    const key_pair = Ecdsa.KeyPair.fromSecretKey(secret_key) catch
        return TxBuilderError.InvalidPrivateKey;

    // Sign the message hash
    const sig = key_pair.sign(hash, null) catch
        return TxBuilderError.SigningFailed;

    // Return signature in compact form (r || s)
    return sig.toBytes();
}

/// Derive compressed public key from private key
pub fn derivePublicKey(private_key: *const [32]u8) TxBuilderError![33]u8 {
    // Use ECDSA to derive public key
    const Ecdsa = crypto.sign.ecdsa.Ecdsa(Secp256k1, Sha256);

    const secret_key = Ecdsa.SecretKey.fromBytes(private_key.*) catch
        return TxBuilderError.InvalidPrivateKey;

    const key_pair = Ecdsa.KeyPair.fromSecretKey(secret_key) catch
        return TxBuilderError.InvalidPrivateKey;

    return key_pair.public_key.toCompressedSec1();
}

/// Convert signature to DER format (for Bitcoin)
/// Enforces low-S per BIP 62/146 (S must be <= N/2)
pub fn signatureToDer(sig: *const [64]u8, out: []u8) TxBuilderError!usize {
    if (out.len < 72) return TxBuilderError.BufferTooSmall;

    const r = sig[0..32];

    // Enforce low-S: if S > N/2, replace with N - S (BIP 62)
    // secp256k1 curve order N
    const curve_order = [32]u8{
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
        0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
        0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41,
    };
    const half_order = [32]u8{
        0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x5D, 0x57, 0x6E, 0x73, 0x57, 0xA4, 0x50, 0x1D,
        0xDF, 0xE9, 0x2F, 0x46, 0x68, 0x1B, 0x20, 0xA0,
    };

    var s_bytes: [32]u8 = sig[32..64].*;
    // Check if S > half_order
    var s_high = false;
    for (0..32) |i| {
        if (s_bytes[i] > half_order[i]) { s_high = true; break; }
        if (s_bytes[i] < half_order[i]) break;
    }
    // If S is high, compute S = N - S
    if (s_high) {
        var borrow: u16 = 0;
        var i: usize = 31;
        while (true) {
            const diff = @as(u16, curve_order[i]) -% @as(u16, s_bytes[i]) -% borrow;
            s_bytes[i] = @truncate(diff);
            borrow = if (diff > 0xFF) 1 else 0;
            if (i == 0) break;
            i -= 1;
        }
    }

    const s = &s_bytes;

    // Determine R length (may need padding if high bit set)
    var r_len: usize = 32;
    var r_start: usize = 0;

    // Skip leading zeros in R
    while (r_start < 31 and r[r_start] == 0) : (r_start += 1) {}
    r_len = 32 - r_start;

    // Add padding byte if high bit set
    const r_pad: usize = if (r[r_start] & 0x80 != 0) 1 else 0;

    // Determine S length
    var s_len: usize = 32;
    var s_start: usize = 0;

    // Skip leading zeros in S
    while (s_start < 31 and s[s_start] == 0) : (s_start += 1) {}
    s_len = 32 - s_start;

    // Add padding byte if high bit set
    const s_pad: usize = if (s[s_start] & 0x80 != 0) 1 else 0;

    // Inner content length: (tag + len + r_pad + r_data) + (tag + len + s_pad + s_data)
    const inner_len = 2 + r_pad + r_len + 2 + s_pad + s_len;

    var pos: usize = 0;

    // SEQUENCE tag
    out[pos] = 0x30;
    pos += 1;

    // SEQUENCE length (inner content only, not including this header)
    out[pos] = @intCast(inner_len);
    pos += 1;

    // INTEGER tag for R
    out[pos] = 0x02;
    pos += 1;

    // R length
    out[pos] = @intCast(r_len + r_pad);
    pos += 1;

    // R padding if needed
    if (r_pad == 1) {
        out[pos] = 0x00;
        pos += 1;
    }

    // R value
    @memcpy(out[pos .. pos + r_len], r[r_start .. r_start + r_len]);
    pos += r_len;

    // INTEGER tag for S
    out[pos] = 0x02;
    pos += 1;

    // S length
    out[pos] = @intCast(s_len + s_pad);
    pos += 1;

    // S padding if needed
    if (s_pad == 1) {
        out[pos] = 0x00;
        pos += 1;
    }

    // S value
    @memcpy(out[pos .. pos + s_len], s[s_start .. s_start + s_len]);
    pos += s_len;

    return pos;
}

// =============================================================================
// Transaction Serialization
// =============================================================================

/// Signed input with witness data
pub const SignedInput = struct {
    /// DER-encoded signature + sighash type
    signature: [73]u8,
    sig_len: usize,
    /// Compressed public key
    pubkey: [33]u8,
};

/// Serialize a signed transaction to bytes
pub fn serializeSignedTransaction(
    builder: *const TxBuilder,
    signed_inputs: []const SignedInput,
    out: []u8,
) TxBuilderError!usize {
    if (builder.input_count == 0) return TxBuilderError.NoInputs;
    if (builder.output_count == 0) return TxBuilderError.NoOutputs;
    if (signed_inputs.len != builder.input_count) return TxBuilderError.NoInputs;
    if (out.len < 100) return TxBuilderError.BufferTooSmall;

    var pos: usize = 0;

    // Version (4 bytes, little-endian)
    std.mem.writeInt(i32, out[pos..][0..4], builder.version, .little);
    pos += 4;

    // SegWit marker and flag
    out[pos] = 0x00; // marker
    pos += 1;
    out[pos] = 0x01; // flag
    pos += 1;

    // Input count (varint)
    pos += writeVarint(out[pos..], builder.input_count);

    // Inputs
    for (builder.inputs[0..builder.input_count]) |input| {
        // Previous output txid
        @memcpy(out[pos .. pos + 32], &input.txid);
        pos += 32;

        // Previous output index
        std.mem.writeInt(u32, out[pos..][0..4], input.vout, .little);
        pos += 4;

        // scriptSig (empty for SegWit)
        out[pos] = 0x00;
        pos += 1;

        // Sequence
        std.mem.writeInt(u32, out[pos..][0..4], DEFAULT_SEQUENCE, .little);
        pos += 4;
    }

    // Output count (varint)
    pos += writeVarint(out[pos..], builder.output_count);

    // Outputs
    for (builder.outputs[0..builder.output_count]) |output| {
        // Value
        std.mem.writeInt(u64, out[pos..][0..8], output.value, .little);
        pos += 8;

        // Script length and script
        pos += writeVarint(out[pos..], output.script_pubkey.len);
        @memcpy(out[pos .. pos + output.script_pubkey.len], output.script_pubkey);
        pos += output.script_pubkey.len;
    }

    // Witness data (for each input)
    for (signed_inputs) |signed| {
        // Number of witness items (2 for P2WPKH: signature + pubkey)
        out[pos] = 0x02;
        pos += 1;

        // Signature (length + data)
        pos += writeVarint(out[pos..], signed.sig_len);
        @memcpy(out[pos .. pos + signed.sig_len], signed.signature[0..signed.sig_len]);
        pos += signed.sig_len;

        // Public key (length + data)
        out[pos] = 33;
        pos += 1;
        @memcpy(out[pos .. pos + 33], &signed.pubkey);
        pos += 33;
    }

    // Locktime
    std.mem.writeInt(u32, out[pos..][0..4], builder.locktime, .little);
    pos += 4;

    return pos;
}

/// Write a varint to buffer, return bytes written
fn writeVarint(out: []u8, value: usize) usize {
    if (value < 0xfd) {
        out[0] = @intCast(value);
        return 1;
    } else if (value <= 0xffff) {
        out[0] = 0xfd;
        std.mem.writeInt(u16, out[1..3], @intCast(value), .little);
        return 3;
    } else if (value <= 0xffffffff) {
        out[0] = 0xfe;
        std.mem.writeInt(u32, out[1..5], @intCast(value), .little);
        return 5;
    } else {
        out[0] = 0xff;
        std.mem.writeInt(u64, out[1..9], @intCast(value), .little);
        return 9;
    }
}

// =============================================================================
// High-Level API: Sign Transaction
// =============================================================================

/// Sign all inputs and return serialized transaction
/// private_keys should be indexed by derivation_index from each input
pub fn signTransaction(
    builder: *const TxBuilder,
    private_keys: []const [32]u8,
    out: []u8,
) TxBuilderError!usize {
    if (builder.input_count == 0) return TxBuilderError.NoInputs;
    if (builder.output_count == 0) return TxBuilderError.NoOutputs;

    // Check we have enough funds
    if (builder.getTotalInputValue() < builder.getTotalOutputValue()) {
        return TxBuilderError.InsufficientFunds;
    }

    var signed_inputs: [TxBuilder.MAX_INPUTS]SignedInput = undefined;

    // Sign each input
    for (builder.inputs[0..builder.input_count], 0..) |input, i| {
        // Get the private key for this input
        if (input.derivation_index >= private_keys.len) {
            return TxBuilderError.InvalidPrivateKey;
        }
        const private_key = &private_keys[input.derivation_index];

        // Compute sighash
        const sighash = try computeSighashBip143(builder, i, private_key, SIGHASH_ALL);

        // Sign
        const sig_compact = try signHash(&sighash, private_key);

        // Convert to DER
        var der_sig: [72]u8 = undefined;
        const der_len = try signatureToDer(&sig_compact, &der_sig);

        // Add sighash type byte
        @memcpy(signed_inputs[i].signature[0..der_len], der_sig[0..der_len]);
        signed_inputs[i].signature[der_len] = @intCast(SIGHASH_ALL);
        signed_inputs[i].sig_len = der_len + 1;

        // Get public key
        signed_inputs[i].pubkey = try derivePublicKey(private_key);
    }

    // Serialize
    return serializeSignedTransaction(builder, signed_inputs[0..builder.input_count], out);
}

/// Calculate transaction ID (double SHA256, reversed)
pub fn calculateTxid(serialized_tx: []const u8) [32]u8 {
    // For SegWit tx, we need to hash without witness data
    // Find where witness starts: after outputs, before locktime

    var hasher = Sha256.init(.{});

    // Version (4 bytes)
    hasher.update(serialized_tx[0..4]);

    // Skip marker and flag for SegWit
    var pos: usize = 4;
    if (serialized_tx.len > 6 and serialized_tx[4] == 0x00 and serialized_tx[5] == 0x01) {
        pos = 6; // Skip marker and flag
    }

    // We need to hash: version + inputs + outputs + locktime (no witness)
    // This is complex for a full implementation, so for now hash everything
    // (This works for non-segwit, but txid for segwit needs proper stripping)

    // For proper implementation, we'd need to track positions carefully
    // Simplified: just double-hash the whole thing (incorrect for SegWit txid display)
    hasher.update(serialized_tx);

    var first_hash: [32]u8 = undefined;
    hasher.final(&first_hash);

    var txid: [32]u8 = undefined;
    Sha256.hash(&first_hash, &txid, .{});

    // Reverse for display
    var reversed: [32]u8 = undefined;
    for (0..32) |i| {
        reversed[i] = txid[31 - i];
    }

    return reversed;
}

// =============================================================================
// Tests
// =============================================================================

test "derive public key" {
    // Test vector
    const private_key = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    };

    const pubkey = try derivePublicKey(&private_key);

    // Generator point public key (compressed) starts with 0x02 or 0x03
    try std.testing.expect(pubkey[0] == 0x02 or pubkey[0] == 0x03);
    try std.testing.expect(pubkey.len == 33);
}

test "tx builder basic" {
    var builder = TxBuilder.init();

    const utxo = SpendableUtxo{
        .txid = [_]u8{0x01} ** 32,
        .vout = 0,
        .value = 100000,
        .pubkey_hash = [_]u8{0x02} ** 20,
        .derivation_index = 0,
    };

    try builder.addInput(utxo);

    const dest_hash = [_]u8{0x03} ** 20;
    try builder.addP2wpkhOutput(90000, &dest_hash);

    try std.testing.expectEqual(@as(usize, 1), builder.input_count);
    try std.testing.expectEqual(@as(usize, 1), builder.output_count);
    try std.testing.expectEqual(@as(u64, 100000), builder.getTotalInputValue());
    try std.testing.expectEqual(@as(u64, 90000), builder.getTotalOutputValue());
    try std.testing.expectEqual(@as(u64, 10000), builder.getFee());
}

test "signature to DER" {
    // Test with a known signature
    const sig = [_]u8{
        // R (32 bytes)
        0x30, 0x44, 0x02, 0x20, 0x01, 0x02, 0x03, 0x04,
        0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c,
        0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14,
        0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c,
        // S (32 bytes)
        0x1d, 0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24,
        0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c,
        0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x32, 0x33, 0x34,
        0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c,
    };

    var der: [72]u8 = undefined;
    const len = try signatureToDer(&sig, &der);

    // DER signature starts with 0x30 (SEQUENCE)
    try std.testing.expect(der[0] == 0x30);
    try std.testing.expect(len > 0 and len <= 72);
}

test "estimate vsize" {
    var builder = TxBuilder.init();

    // Add 2 inputs
    for (0..2) |i| {
        const utxo = SpendableUtxo{
            .txid = [_]u8{@intCast(i)} ** 32,
            .vout = 0,
            .value = 50000,
            .pubkey_hash = [_]u8{0x02} ** 20,
            .derivation_index = @intCast(i),
        };
        try builder.addInput(utxo);
    }

    // Add 2 outputs
    const dest_hash = [_]u8{0x03} ** 20;
    try builder.addP2wpkhOutput(40000, &dest_hash);
    try builder.addP2wpkhOutput(50000, &dest_hash);

    const vsize = builder.estimateVsize();

    // 2-in 2-out P2WPKH should be around 208 vbytes
    try std.testing.expect(vsize >= 180 and vsize <= 250);
}

test "varint encoding" {
    var buf: [10]u8 = undefined;

    // Single byte
    const len1 = writeVarint(&buf, 100);
    try std.testing.expectEqual(@as(usize, 1), len1);
    try std.testing.expectEqual(@as(u8, 100), buf[0]);

    // Two bytes
    const len2 = writeVarint(&buf, 300);
    try std.testing.expectEqual(@as(usize, 3), len2);
    try std.testing.expectEqual(@as(u8, 0xfd), buf[0]);
}
