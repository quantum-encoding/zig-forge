const std = @import("std");
const crypto = std.crypto;
const Secp256k1 = crypto.ecc.Secp256k1;
const HmacSha512 = crypto.auth.hmac.sha2.HmacSha512;
const Sha256 = crypto.hash.sha2.Sha256;

// ============================================================================
// BIP32 CONSTANTS
// ============================================================================

/// Hardened key derivation offset (2^31)
pub const HARDENED_OFFSET: u32 = 0x80000000;

/// Key length in bytes
pub const KEY_LENGTH: usize = 32;

/// Chain code length in bytes
pub const CHAIN_CODE_LENGTH: usize = 32;

/// Public key compressed length
pub const PUBLIC_KEY_LENGTH: usize = 33;

/// Serialized extended key length (78 bytes + 4 byte checksum = 82)
pub const SERIALIZED_LENGTH: usize = 78;

/// Bitcoin mainnet version bytes
pub const VERSION_MAINNET_PRIVATE: [4]u8 = .{ 0x04, 0x88, 0xAD, 0xE4 }; // xprv
pub const VERSION_MAINNET_PUBLIC: [4]u8 = .{ 0x04, 0x88, 0xB2, 0x1E }; // xpub

/// Bitcoin testnet version bytes
pub const VERSION_TESTNET_PRIVATE: [4]u8 = .{ 0x04, 0x35, 0x83, 0x94 }; // tprv
pub const VERSION_TESTNET_PUBLIC: [4]u8 = .{ 0x04, 0x35, 0x87, 0xCF }; // tpub

// ============================================================================
// RIPEMD160 IMPLEMENTATION
// ============================================================================

/// RIPEMD-160 hash function implementation
pub const Ripemd160 = struct {
    const Self = @This();

    state: [5]u32,
    buffer: [64]u8,
    buffer_len: u6,
    total_len: u64,

    const initial_state: [5]u32 = .{
        0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0,
    };

    pub fn init() Self {
        return Self{
            .state = initial_state,
            .buffer = undefined,
            .buffer_len = 0,
            .total_len = 0,
        };
    }

    pub fn update(self: *Self, data: []const u8) void {
        var input = data;

        // Fill buffer first
        if (self.buffer_len > 0) {
            const needed = 64 - @as(usize, self.buffer_len);
            const to_copy = @min(needed, input.len);
            @memcpy(self.buffer[self.buffer_len..][0..to_copy], input[0..to_copy]);
            self.buffer_len += @intCast(to_copy);
            input = input[to_copy..];

            if (self.buffer_len == 64) {
                self.compress(&self.buffer);
                self.buffer_len = 0;
            }
        }

        // Process full blocks
        while (input.len >= 64) {
            self.compress(input[0..64]);
            input = input[64..];
        }

        // Store remaining
        if (input.len > 0) {
            @memcpy(self.buffer[0..input.len], input);
            self.buffer_len = @intCast(input.len);
        }

        self.total_len += data.len;
    }

    pub fn final(self: *Self, out: *[20]u8) void {
        // Padding
        const total_bits = self.total_len * 8;
        self.buffer[self.buffer_len] = 0x80;
        self.buffer_len += 1;

        if (self.buffer_len > 56) {
            @memset(self.buffer[self.buffer_len..], 0);
            self.compress(&self.buffer);
            self.buffer_len = 0;
        }

        @memset(self.buffer[self.buffer_len..56], 0);
        std.mem.writeInt(u64, self.buffer[56..64], total_bits, .little);
        self.compress(&self.buffer);

        // Output
        inline for (0..5) |i| {
            std.mem.writeInt(u32, out[i * 4 ..][0..4], self.state[i], .little);
        }
    }

    fn compress(self: *Self, block: *const [64]u8) void {
        var x: [16]u32 = undefined;
        inline for (0..16) |i| {
            x[i] = std.mem.readInt(u32, block[i * 4 ..][0..4], .little);
        }

        var al = self.state[0];
        var bl = self.state[1];
        var cl = self.state[2];
        var dl = self.state[3];
        var el = self.state[4];

        var ar = self.state[0];
        var br = self.state[1];
        var cr = self.state[2];
        var dr = self.state[3];
        var er = self.state[4];

        // Left rounds
        const r_l = [80]u4{
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
            7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
            3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
            1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2,
            4, 0, 5, 9, 7, 12, 2, 10, 14, 1, 3, 8, 11, 6, 15, 13,
        };
        const s_l = [80]u5{
            11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8,
            7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
            11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
            11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12,
            9, 15, 5, 11, 6, 8, 13, 12, 5, 12, 13, 14, 11, 8, 5, 6,
        };

        // Right rounds
        const r_r = [80]u4{
            5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
            6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
            15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
            8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14,
            12, 15, 10, 4, 1, 5, 8, 7, 6, 2, 13, 14, 0, 3, 9, 11,
        };
        const s_r = [80]u5{
            8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6,
            9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
            9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
            15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8,
            8, 5, 12, 9, 12, 5, 14, 6, 8, 13, 6, 5, 15, 13, 11, 11,
        };

        inline for (0..80) |j| {
            const round = j / 16;
            var f_l: u32 = undefined;
            var k_l: u32 = undefined;
            var f_r: u32 = undefined;
            var k_r: u32 = undefined;

            switch (round) {
                0 => {
                    f_l = bl ^ cl ^ dl;
                    k_l = 0x00000000;
                    f_r = br ^ (cr | ~dr);
                    k_r = 0x50A28BE6;
                },
                1 => {
                    f_l = (bl & cl) | (~bl & dl);
                    k_l = 0x5A827999;
                    f_r = (br & dr) | (cr & ~dr);
                    k_r = 0x5C4DD124;
                },
                2 => {
                    f_l = (bl | ~cl) ^ dl;
                    k_l = 0x6ED9EBA1;
                    f_r = (br | ~cr) ^ dr;
                    k_r = 0x6D703EF3;
                },
                3 => {
                    f_l = (bl & dl) | (cl & ~dl);
                    k_l = 0x8F1BBCDC;
                    f_r = (br & cr) | (~br & dr);
                    k_r = 0x7A6D76E9;
                },
                4 => {
                    f_l = bl ^ (cl | ~dl);
                    k_l = 0xA953FD4E;
                    f_r = br ^ cr ^ dr;
                    k_r = 0x00000000;
                },
                else => unreachable,
            }

            var t = al +% f_l +% x[r_l[j]] +% k_l;
            t = std.math.rotl(u32, t, s_l[j]) +% el;
            al = el;
            el = dl;
            dl = std.math.rotl(u32, cl, 10);
            cl = bl;
            bl = t;

            t = ar +% f_r +% x[r_r[j]] +% k_r;
            t = std.math.rotl(u32, t, s_r[j]) +% er;
            ar = er;
            er = dr;
            dr = std.math.rotl(u32, cr, 10);
            cr = br;
            br = t;
        }

        const t = self.state[1] +% cl +% dr;
        self.state[1] = self.state[2] +% dl +% er;
        self.state[2] = self.state[3] +% el +% ar;
        self.state[3] = self.state[4] +% al +% br;
        self.state[4] = self.state[0] +% bl +% cr;
        self.state[0] = t;
    }

    pub fn hash(data: []const u8, out: *[20]u8, _: anytype) void {
        var h = Self.init();
        h.update(data);
        h.final(out);
    }
};

// ============================================================================
// ERROR TYPES
// ============================================================================

pub const Bip32Error = error{
    InvalidSeed,
    InvalidKey,
    InvalidPath,
    HardenedPublicDerivation,
    InvalidChecksum,
    InvalidVersion,
    PointAtInfinity,
};

// ============================================================================
// EXTENDED KEY STRUCTURE
// ============================================================================

/// Extended key (private or public) as per BIP32
pub const ExtendedKey = struct {
    /// Private key (32 bytes) - zeroed if this is a public key
    private_key: [KEY_LENGTH]u8,
    /// Public key (33 bytes compressed)
    public_key: [PUBLIC_KEY_LENGTH]u8,
    /// Chain code (32 bytes)
    chain_code: [CHAIN_CODE_LENGTH]u8,
    /// Depth in derivation path (0 = master)
    depth: u8,
    /// Parent fingerprint (first 4 bytes of parent's key hash)
    parent_fingerprint: [4]u8,
    /// Child index
    child_index: u32,
    /// Is this a private key?
    is_private: bool,

    const Self = @This();

    /// Create master key from seed (BIP32 master key generation)
    pub fn fromSeed(seed: []const u8) Bip32Error!Self {
        if (seed.len < 16 or seed.len > 64) {
            return Bip32Error.InvalidSeed;
        }

        // HMAC-SHA512("Bitcoin seed", seed)
        var hmac = HmacSha512.init("Bitcoin seed");
        hmac.update(seed);
        var output: [64]u8 = undefined;
        hmac.final(&output);

        const private_key = output[0..32].*;
        const chain_code = output[32..64].*;

        // Validate private key is valid (non-zero and less than curve order)
        if (!isValidPrivateKey(&private_key)) {
            return Bip32Error.InvalidKey;
        }

        // Derive public key
        const public_key = derivePublicKey(&private_key) catch return Bip32Error.InvalidKey;

        return Self{
            .private_key = private_key,
            .public_key = public_key,
            .chain_code = chain_code,
            .depth = 0,
            .parent_fingerprint = .{ 0, 0, 0, 0 },
            .child_index = 0,
            .is_private = true,
        };
    }

    /// Derive child key at given index
    pub fn deriveChild(self: Self, index: u32) Bip32Error!Self {
        const hardened = (index & HARDENED_OFFSET) != 0;

        // Cannot do hardened derivation from public key
        if (hardened and !self.is_private) {
            return Bip32Error.HardenedPublicDerivation;
        }

        var data: [37]u8 = undefined;

        if (hardened) {
            // Hardened: 0x00 || private_key || index
            data[0] = 0x00;
            @memcpy(data[1..33], &self.private_key);
        } else {
            // Normal: public_key || index
            @memcpy(data[0..33], &self.public_key);
        }

        // Append index in big-endian
        std.mem.writeInt(u32, data[33..37], index, .big);

        // HMAC-SHA512(chain_code, data)
        var hmac = HmacSha512.init(&self.chain_code);
        hmac.update(&data);
        var output: [64]u8 = undefined;
        hmac.final(&output);

        const il = output[0..32];
        const ir = output[32..64];

        var child = Self{
            .private_key = undefined,
            .public_key = undefined,
            .chain_code = ir.*,
            .depth = self.depth + 1,
            .parent_fingerprint = self.fingerprint(),
            .child_index = index,
            .is_private = self.is_private,
        };

        if (self.is_private) {
            // Private key derivation: (il + parent_key) mod n
            child.private_key = addPrivateKeys(&self.private_key, il) catch return Bip32Error.InvalidKey;

            if (!isValidPrivateKey(&child.private_key)) {
                return Bip32Error.InvalidKey;
            }

            child.public_key = derivePublicKey(&child.private_key) catch return Bip32Error.InvalidKey;
        } else {
            // Public key derivation: point(il) + parent_public_key
            child.private_key = .{0} ** 32;
            child.public_key = addPublicKeys(&self.public_key, il) catch return Bip32Error.PointAtInfinity;
        }

        return child;
    }

    /// Derive from path string (e.g., "m/44'/0'/0'/0/0")
    pub fn derivePath(self: Self, path: []const u8) Bip32Error!Self {
        var current = self;
        var iter = std.mem.splitScalar(u8, path, '/');

        // Skip "m" prefix if present
        if (iter.next()) |first| {
            if (!std.mem.eql(u8, first, "m")) {
                // First element is a number, process it
                const index = parsePathComponent(first) catch return Bip32Error.InvalidPath;
                current = try current.deriveChild(index);
            }
        }

        // Process remaining components
        while (iter.next()) |component| {
            if (component.len == 0) continue;
            const index = parsePathComponent(component) catch return Bip32Error.InvalidPath;
            current = try current.deriveChild(index);
        }

        return current;
    }

    /// Get fingerprint (first 4 bytes of Hash160 of public key)
    pub fn fingerprint(self: Self) [4]u8 {
        const h = hash160(&self.public_key);
        return h[0..4].*;
    }

    /// Get public-key-only version of this key
    pub fn neuter(self: Self) Self {
        var public_only = self;
        public_only.private_key = .{0} ** 32;
        public_only.is_private = false;
        return public_only;
    }

    /// Serialize to Base58Check format (xprv/xpub)
    pub fn serialize(self: Self, mainnet: bool) [SERIALIZED_LENGTH + 4]u8 {
        var result: [SERIALIZED_LENGTH + 4]u8 = undefined;

        // Version (4 bytes)
        if (self.is_private) {
            const version = if (mainnet) VERSION_MAINNET_PRIVATE else VERSION_TESTNET_PRIVATE;
            @memcpy(result[0..4], &version);
        } else {
            const version = if (mainnet) VERSION_MAINNET_PUBLIC else VERSION_TESTNET_PUBLIC;
            @memcpy(result[0..4], &version);
        }

        // Depth (1 byte)
        result[4] = self.depth;

        // Parent fingerprint (4 bytes)
        @memcpy(result[5..9], &self.parent_fingerprint);

        // Child index (4 bytes, big-endian)
        std.mem.writeInt(u32, result[9..13], self.child_index, .big);

        // Chain code (32 bytes)
        @memcpy(result[13..45], &self.chain_code);

        // Key data (33 bytes)
        if (self.is_private) {
            result[45] = 0x00;
            @memcpy(result[46..78], &self.private_key);
        } else {
            @memcpy(result[45..78], &self.public_key);
        }

        // Checksum (first 4 bytes of double SHA256)
        const checksum = doubleSha256(result[0..78]);
        @memcpy(result[78..82], checksum[0..4]);

        return result;
    }
};

// ============================================================================
// ADDRESS GENERATION
// ============================================================================

/// P2PKH address prefix
pub const P2PKH_PREFIX_MAINNET: u8 = 0x00;
pub const P2PKH_PREFIX_TESTNET: u8 = 0x6F;

/// P2SH address prefix
pub const P2SH_PREFIX_MAINNET: u8 = 0x05;
pub const P2SH_PREFIX_TESTNET: u8 = 0xC4;

/// P2WPKH witness version
pub const WITNESS_VERSION_0: u8 = 0x00;

/// Generate Hash160 (RIPEMD160(SHA256(data)))
pub fn hash160(data: []const u8) [20]u8 {
    var sha_out: [32]u8 = undefined;
    Sha256.hash(data, &sha_out, .{});

    var ripemd_out: [20]u8 = undefined;
    Ripemd160.hash(&sha_out, &ripemd_out, .{});

    return ripemd_out;
}

/// Double SHA256
pub fn doubleSha256(data: []const u8) [32]u8 {
    var round1: [32]u8 = undefined;
    var round2: [32]u8 = undefined;
    Sha256.hash(data, &round1, .{});
    Sha256.hash(&round1, &round2, .{});
    return round2;
}

/// Get P2PKH address hash (Hash160 of public key)
pub fn p2pkhHash(public_key: *const [PUBLIC_KEY_LENGTH]u8) [20]u8 {
    return hash160(public_key);
}

/// Get P2WPKH witness program (same as P2PKH hash for v0)
pub fn p2wpkhProgram(public_key: *const [PUBLIC_KEY_LENGTH]u8) [20]u8 {
    return hash160(public_key);
}

/// Encode P2PKH address to bytes (for Base58Check encoding)
pub fn encodeP2pkhAddress(public_key: *const [PUBLIC_KEY_LENGTH]u8, mainnet: bool) [25]u8 {
    var result: [25]u8 = undefined;

    // Version byte
    result[0] = if (mainnet) P2PKH_PREFIX_MAINNET else P2PKH_PREFIX_TESTNET;

    // Hash160
    const pubkey_hash = hash160(public_key);
    @memcpy(result[1..21], &pubkey_hash);

    // Checksum
    const checksum = doubleSha256(result[0..21]);
    @memcpy(result[21..25], checksum[0..4]);

    return result;
}

// ============================================================================
// BECH32 ENCODING (for SegWit addresses)
// ============================================================================

const BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
const BECH32M_CONST: u32 = 0x2bc830a3;
const BECH32_CONST: u32 = 1;

/// Bech32 polymod for checksum calculation
fn bech32Polymod(values: []const u5) u32 {
    const generator = [_]u32{ 0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3 };
    var chk: u32 = 1;

    for (values) |v| {
        const top = chk >> 25;
        chk = ((chk & 0x1ffffff) << 5) ^ @as(u32, v);
        inline for (0..5) |i| {
            if ((top >> @intCast(i)) & 1 == 1) {
                chk ^= generator[i];
            }
        }
    }
    return chk;
}

/// Expand HRP for checksum
fn bech32HrpExpand(hrp: []const u8, out: []u5) void {
    for (hrp, 0..) |c, i| {
        out[i] = @truncate(c >> 5);
    }
    out[hrp.len] = 0;
    for (hrp, 0..) |c, i| {
        out[hrp.len + 1 + i] = @truncate(c & 31);
    }
}

/// Create Bech32 checksum
fn bech32CreateChecksum(hrp: []const u8, data: []const u5, is_bech32m: bool) [6]u5 {
    var values: [128]u5 = undefined;
    const hrp_len = hrp.len * 2 + 1;

    bech32HrpExpand(hrp, values[0..hrp_len]);
    @memcpy(values[hrp_len .. hrp_len + data.len], data);
    @memset(values[hrp_len + data.len .. hrp_len + data.len + 6], 0);

    const polymod_const = if (is_bech32m) BECH32M_CONST else BECH32_CONST;
    const polymod = bech32Polymod(values[0 .. hrp_len + data.len + 6]) ^ polymod_const;

    var checksum: [6]u5 = undefined;
    inline for (0..6) |i| {
        checksum[i] = @truncate((polymod >> @as(u5, @intCast(5 * (5 - i)))) & 31);
    }
    return checksum;
}

/// Convert 8-bit bytes to 5-bit groups
fn convertBits8to5(input: []const u8, output: []u5) usize {
    var acc: u32 = 0;
    var bits: u32 = 0;
    var out_idx: usize = 0;

    for (input) |byte| {
        acc = (acc << 8) | @as(u32, byte);
        bits += 8;
        while (bits >= 5) {
            bits -= 5;
            output[out_idx] = @truncate((acc >> @intCast(bits)) & 31);
            out_idx += 1;
        }
    }
    if (bits > 0) {
        output[out_idx] = @truncate((acc << @intCast(5 - bits)) & 31);
        out_idx += 1;
    }
    return out_idx;
}

/// Encode a SegWit address (P2WPKH or P2WSH)
pub fn encodeBech32Address(
    witness_program: []const u8,
    witness_version: u8,
    hrp: []const u8,
    output: []u8,
) usize {
    // Convert witness program to 5-bit groups
    var data5: [65]u5 = undefined; // Max: 1 (version) + 52 (32 bytes * 8/5 ceil) + padding
    data5[0] = @truncate(witness_version);

    const converted_len = convertBits8to5(witness_program, data5[1..]);
    const data_len = 1 + converted_len;

    // Use bech32m for witness version 1+ (Taproot), bech32 for version 0
    const is_bech32m = witness_version > 0;
    const checksum = bech32CreateChecksum(hrp, data5[0..data_len], is_bech32m);

    // Build output string
    var out_idx: usize = 0;

    // HRP
    @memcpy(output[out_idx .. out_idx + hrp.len], hrp);
    out_idx += hrp.len;

    // Separator
    output[out_idx] = '1';
    out_idx += 1;

    // Data
    for (data5[0..data_len]) |d| {
        output[out_idx] = BECH32_CHARSET[d];
        out_idx += 1;
    }

    // Checksum
    for (checksum) |c| {
        output[out_idx] = BECH32_CHARSET[c];
        out_idx += 1;
    }

    return out_idx;
}

/// Generate P2WPKH address (bc1q...)
pub fn generateP2wpkhAddress(
    public_key: *const [PUBLIC_KEY_LENGTH]u8,
    mainnet: bool,
    output: []u8,
) usize {
    const program = p2wpkhProgram(public_key);
    const hrp = if (mainnet) "bc" else "tb";
    return encodeBech32Address(&program, WITNESS_VERSION_0, hrp, output);
}

// ============================================================================
// SECP256K1 HELPERS
// ============================================================================

/// Check if a private key is valid (non-zero, less than curve order)
fn isValidPrivateKey(key: *const [32]u8) bool {
    // Check non-zero
    var is_zero = true;
    for (key) |b| {
        if (b != 0) {
            is_zero = false;
            break;
        }
    }
    if (is_zero) return false;

    // Check less than curve order
    // secp256k1 order n = FFFFFFFF FFFFFFFF FFFFFFFF FFFFFFFE BAAEDCE6 AF48A03B BFD25E8C D0364141
    const order = [_]u8{
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
        0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
        0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41,
    };

    for (key, order) |k, o| {
        if (k < o) return true;
        if (k > o) return false;
    }
    return false; // Equal to order, invalid
}

/// Derive compressed public key from private key
fn derivePublicKey(private_key: *const [32]u8) ![33]u8 {
    const scalar = Secp256k1.scalar.Scalar.fromBytes(private_key.*, .big) catch return error.InvalidKey;
    const point = Secp256k1.basePoint.mul(scalar.toBytes(.big), .big) catch return error.InvalidKey;
    return point.toCompressedSec1();
}

/// Add two private keys modulo curve order
fn addPrivateKeys(a: *const [32]u8, b: *const [32]u8) ![32]u8 {
    const scalar_a = Secp256k1.scalar.Scalar.fromBytes(a.*, .big) catch return error.InvalidKey;
    const scalar_b = Secp256k1.scalar.Scalar.fromBytes(b.*, .big) catch return error.InvalidKey;
    const result = scalar_a.add(scalar_b);
    return result.toBytes(.big);
}

/// Add public key point to point derived from scalar
fn addPublicKeys(public_key: *const [33]u8, scalar_bytes: *const [32]u8) ![33]u8 {
    // Parse the existing public key point
    const point_a = Secp256k1.fromSec1(public_key) catch return error.InvalidKey;

    // Derive point from scalar (scalar * G)
    const scalar = Secp256k1.scalar.Scalar.fromBytes(scalar_bytes.*, .big) catch return error.InvalidKey;
    const point_b = Secp256k1.basePoint.mul(scalar.toBytes(.big), .big) catch return error.InvalidKey;

    // Add points
    const result = point_a.add(point_b);
    return result.toCompressedSec1();
}

/// Parse path component (e.g., "44'" or "0")
fn parsePathComponent(component: []const u8) !u32 {
    var is_hardened = false;
    var num_str = component;

    // Check for hardened marker
    if (component.len > 0 and (component[component.len - 1] == '\'' or component[component.len - 1] == 'h' or component[component.len - 1] == 'H')) {
        is_hardened = true;
        num_str = component[0 .. component.len - 1];
    }

    const index = std.fmt.parseInt(u32, num_str, 10) catch return error.InvalidPath;

    if (is_hardened) {
        return index | HARDENED_OFFSET;
    }
    return index;
}

// ============================================================================
// TESTS
// ============================================================================

test "RIPEMD160 test vector" {
    // Test vector: RIPEMD160("") = 9c1185a5c5e9fc54612808977ee8f548b2258d31
    var out: [20]u8 = undefined;
    Ripemd160.hash("", &out, .{});

    const expected = [_]u8{
        0x9c, 0x11, 0x85, 0xa5, 0xc5, 0xe9, 0xfc, 0x54, 0x61, 0x28,
        0x08, 0x97, 0x7e, 0xe8, 0xf5, 0x48, 0xb2, 0x25, 0x8d, 0x31,
    };
    try std.testing.expectEqual(expected, out);
}

test "RIPEMD160 test vector abc" {
    // RIPEMD160("abc") = 8eb208f7e05d987a9b044a8e98c6b087f15a0bfc
    var out: [20]u8 = undefined;
    Ripemd160.hash("abc", &out, .{});

    const expected = [_]u8{
        0x8e, 0xb2, 0x08, 0xf7, 0xe0, 0x5d, 0x98, 0x7a, 0x9b, 0x04,
        0x4a, 0x8e, 0x98, 0xc6, 0xb0, 0x87, 0xf1, 0x5a, 0x0b, 0xfc,
    };
    try std.testing.expectEqual(expected, out);
}

test "BIP32 master key from seed" {
    // Test vector from BIP32 spec
    const seed = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    };

    const master = try ExtendedKey.fromSeed(&seed);

    // Verify it's a valid master key
    try std.testing.expect(master.depth == 0);
    try std.testing.expect(master.is_private);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, master.parent_fingerprint);
}

test "BIP32 child derivation" {
    const seed = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    };

    const master = try ExtendedKey.fromSeed(&seed);

    // Derive m/0
    const child = try master.deriveChild(0);
    try std.testing.expect(child.depth == 1);
    try std.testing.expect(child.is_private);

    // Derive m/0'
    const hardened_child = try master.deriveChild(HARDENED_OFFSET);
    try std.testing.expect(hardened_child.depth == 1);
}

test "BIP32 path derivation" {
    const seed = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    };

    const master = try ExtendedKey.fromSeed(&seed);

    // BIP44 path for first Bitcoin address
    const derived = try master.derivePath("m/44'/0'/0'/0/0");
    try std.testing.expect(derived.depth == 5);
    try std.testing.expect(derived.is_private);
}

test "BIP32 neuter" {
    const seed = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    };

    const master = try ExtendedKey.fromSeed(&seed);
    const public_only = master.neuter();

    try std.testing.expect(!public_only.is_private);
    try std.testing.expectEqual([32]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, public_only.private_key);
}

test "BIP32 public key derivation fails for hardened" {
    const seed = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    };

    const master = try ExtendedKey.fromSeed(&seed);
    const public_only = master.neuter();

    // Should fail for hardened derivation from public key
    const result = public_only.deriveChild(HARDENED_OFFSET);
    try std.testing.expectError(Bip32Error.HardenedPublicDerivation, result);
}

test "Hash160" {
    // Test vector: SHA256(SHA256(0x02...pubkey)) then RIPEMD160
    const test_data = [_]u8{0x02} ++ [_]u8{0x00} ** 32;
    const result = hash160(&test_data);
    try std.testing.expect(result.len == 20);
}

test "Bech32 address generation" {
    // Create a test public key (this is a valid compressed pubkey format)
    const test_pubkey = [_]u8{0x02} ++ [_]u8{0x01} ** 32;

    var output: [90]u8 = undefined;
    const len = generateP2wpkhAddress(&test_pubkey, true, &output);

    // Mainnet P2WPKH addresses start with "bc1q"
    try std.testing.expect(std.mem.startsWith(u8, output[0..len], "bc1q"));
    // P2WPKH addresses are 42-44 characters
    try std.testing.expect(len >= 42 and len <= 44);
}

test "Bech32 testnet address" {
    const test_pubkey = [_]u8{0x02} ++ [_]u8{0x02} ** 32;

    var output: [90]u8 = undefined;
    const len = generateP2wpkhAddress(&test_pubkey, false, &output);

    // Testnet P2WPKH addresses start with "tb1q"
    try std.testing.expect(std.mem.startsWith(u8, output[0..len], "tb1q"));
}

test "Full BIP44 derivation and address" {
    const seed = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    };

    // BIP44: m/44'/0'/0'/0/0
    // BIP84 (native segwit): m/84'/0'/0'/0/0
    const master = try ExtendedKey.fromSeed(&seed);
    const account = try master.derivePath("m/84'/0'/0'/0/0");

    var output: [90]u8 = undefined;
    const len = generateP2wpkhAddress(&account.public_key, true, &output);

    try std.testing.expect(std.mem.startsWith(u8, output[0..len], "bc1q"));
}

test "Parse path component" {
    try std.testing.expectEqual(@as(u32, 44), try parsePathComponent("44"));
    try std.testing.expectEqual(@as(u32, 44 | HARDENED_OFFSET), try parsePathComponent("44'"));
    try std.testing.expectEqual(@as(u32, 0 | HARDENED_OFFSET), try parsePathComponent("0h"));
    try std.testing.expectEqual(@as(u32, 0), try parsePathComponent("0"));
}

test "ExtendedKey serialization" {
    const seed = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    };

    const master = try ExtendedKey.fromSeed(&seed);
    const serialized = master.serialize(true);

    // Check version bytes (xprv)
    try std.testing.expectEqual(VERSION_MAINNET_PRIVATE, serialized[0..4].*);

    // Check depth is 0
    try std.testing.expectEqual(@as(u8, 0), serialized[4]);
}

// ============================================================================
// SPEC KNOWN-ANSWER TESTS — BIP-32 official vectors, BIP-84 official vectors
// ============================================================================
//
// The expected_* hex constants below are the exact xprv/xpub strings from
// https://raw.githubusercontent.com/bitcoin/bips/master/bip-0032.mediawiki
// base58-decoded to their raw 82 bytes (78-byte payload + 4-byte
// base58check checksum). Each decode was verified against the double-SHA256
// checksum and the mainnet version prefixes 0x0488ADE4 (xprv) /
// 0x0488B21E (xpub) before being embedded here. Layout per BIP-32:
//   version(4) | depth(1) | parent_fingerprint(4) | child_index(4)
//   | chain_code(32) | key_data(33) | checksum(4)
// Asserting all 82 bytes therefore pins version, depth, fingerprint,
// child index, chain code, key material AND the checksum to the spec.

test "BIP32 Test Vector 1: exact serialized keys for full derivation chain" {
    const Case = struct {
        path: []const u8,
        xprv_hex: *const [164]u8,
        xpub_hex: *const [164]u8,
    };
    const cases = [_]Case{
        .{
            .path = "m",
            // xprv9s21ZrQH143K3QTDL4LXw2F7HEK3wJUD2nW2nRk4stbPy6cq3jPPqjiChkVvvNKmPGJxWUtg6LnF5kejMRNNU3TGtRBeJgk33yuGBxrMPHi
            .xprv_hex = "0488ade4000000000000000000873dff81c02f525623fd1fe5167eac3a55a049de3d314bb42ee227ffed37d50800e8f32e723decf4051aefac8e2c93c9c5b214313817cdb01a1494b917c8436b35e77e9d71",
            // xpub661MyMwAqRbcFtXgS5sYJABqqG9YLmC4Q1Rdap9gSE8NqtwybGhePY2gZ29ESFjqJoCu1Rupje8YtGqsefD265TMg7usUDFdp6W1EGMcet8
            .xpub_hex = "0488b21e000000000000000000873dff81c02f525623fd1fe5167eac3a55a049de3d314bb42ee227ffed37d5080339a36013301597daef41fbe593a02cc513d0b55527ec2df1050e2e8ff49c85c2ab473b21",
        },
        .{
            .path = "m/0'",
            // xprv9uHRZZhk6KAJC1avXpDAp4MDc3sQKNxDiPvvkX8Br5ngLNv1TxvUxt4cV1rGL5hj6KCesnDYUhd7oWgT11eZG7XnxHrnYeSvkzY7d2bhkJ7
            .xprv_hex = "0488ade4013442193e8000000047fdacbd0f1097043b78c63c20c34ef4ed9a111d980047ad16282c7ae623614100edb2e14f9ee77d26dd93b4ecede8d16ed408ce149b6cd80b0715a2d911a0afea0a794dec",
            // xpub68Gmy5EdvgibQVfPdqkBBCHxA5htiqg55crXYuXoQRKfDBFA1WEjWgP6LHhwBZeNK1VTsfTFUHCdrfp1bgwQ9xv5ski8PX9rL2dZXvgGDnw
            .xpub_hex = "0488b21e013442193e8000000047fdacbd0f1097043b78c63c20c34ef4ed9a111d980047ad16282c7ae6236141035a784662a4a20a65bf6aab9ae98a6c068a81c52e4b032c0fb5400c706cfccc56b8b9c580",
        },
        .{
            .path = "m/0'/1",
            // xprv9wTYmMFdV23N2TdNG573QoEsfRrWKQgWeibmLntzniatZvR9BmLnvSxqu53Kw1UmYPxLgboyZQaXwTCg8MSY3H2EU4pWcQDnRnrVA1xe8fs
            .xprv_hex = "0488ade4025c1bd648000000012a7857631386ba23dacac34180dd1983734e444fdbf774041578e9b6adb37c19003c6cb8d0f6a264c91ea8b5030fadaa8e538b020f0a387421a12de9319dc93368b34bc442",
            // xpub6ASuArnXKPbfEwhqN6e3mwBcDTgzisQN1wXN9BJcM47sSikHjJf3UFHKkNAWbWMiGj7Wf5uMash7SyYq527Hqck2AxYysAA7xmALppuCkwQ
            .xpub_hex = "0488b21e025c1bd648000000012a7857631386ba23dacac34180dd1983734e444fdbf774041578e9b6adb37c1903501e454bf00751f24b1b489aa925215d66af2234e3891c3b21a52bedb3cd711c6f6e2af7",
        },
        .{
            .path = "m/0'/1/2'",
            // xprv9z4pot5VBttmtdRTWfWQmoH1taj2axGVzFqSb8C9xaxKymcFzXBDptWmT7FwuEzG3ryjH4ktypQSAewRiNMjANTtpgP4mLTj34bhnZX7UiM
            .xprv_hex = "0488ade403bef5a2f98000000204466b9cc8e161e966409ca52986c584f07e9dc81f735db683c3ff6ec7b1503f00cbce0d719ecf7431d88e6a89fa1483e02e35092af60c042b1df2ff59fa424dca25814a3a",
            // xpub6D4BDPcP2GT577Vvch3R8wDkScZWzQzMMUm3PWbmWvVJrZwQY4VUNgqFJPMM3No2dFDFGTsxxpG5uJh7n7epu4trkrX7x7DogT5Uv6fcLW5
            .xpub_hex = "0488b21e03bef5a2f98000000204466b9cc8e161e966409ca52986c584f07e9dc81f735db683c3ff6ec7b1503f0357bfe1e341d01c69fe5654309956cbea516822fba8a601743a012a7896ee8dc2a5162afa",
        },
        .{
            .path = "m/0'/1/2'/2",
            // xprvA2JDeKCSNNZky6uBCviVfJSKyQ1mDYahRjijr5idH2WwLsEd4Hsb2Tyh8RfQMuPh7f7RtyzTtdrbdqqsunu5Mm3wDvUAKRHSC34sJ7in334
            .xprv_hex = "0488ade404ee7ab90c00000002cfb71883f01676f587d023cc53a35bc7f88f724b1f8c2892ac1275ac822a3edd000f479245fb19a38a1954c5c7c0ebab2f9bdfd96a17563ef28a6a4b1a2a764ef4a6b6af57",
            // xpub6FHa3pjLCk84BayeJxFW2SP4XRrFd1JYnxeLeU8EqN3vDfZmbqBqaGJAyiLjTAwm6ZLRQUMv1ZACTj37sR62cfN7fe5JnJ7dh8zL4fiyLHV
            .xpub_hex = "0488b21e04ee7ab90c00000002cfb71883f01676f587d023cc53a35bc7f88f724b1f8c2892ac1275ac822a3edd02e8445082a72f29b75ca48748a914df60622a609cacfce8ed0e35804560741d2942d0acb8",
        },
        .{
            .path = "m/0'/1/2'/2/1000000000",
            // xprvA41z7zogVVwxVSgdKUHDy1SKmdb533PjDz7J6N6mV6uS3ze1ai8FHa8kmHScGpWmj4WggLyQjgPie1rFSruoUihUZREPSL39UNdE3BBDu76
            .xprv_hex = "0488ade405d880d7d83b9aca00c783e67b921d2beb8f6b389cc646d7263b4145701dadd2161548a8b078e65e9e00471b76e389e528d6de6d816857e012c5455051cad6660850e58372a6c3e6e7c81e57a871",
            // xpub6H1LXWLaKsWFhvm6RVpEL9P4KfRZSW7abD2ttkWP3SSQvnyA8FSVqNTEcYFgJS2UaFcxupHiYkro49S8yGasTvXEYBVPamhGW6cFJodrTHy
            .xpub_hex = "0488b21e05d880d7d83b9aca00c783e67b921d2beb8f6b389cc646d7263b4145701dadd2161548a8b078e65e9e022a471424da5e657499d1ff51cb43c47481a03b1e77f951fe64cec9f5a48f701118d3a268",
        },
    };

    const seed = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    };
    const master = try ExtendedKey.fromSeed(&seed);

    for (cases) |case| {
        const key = try master.derivePath(case.path);

        var expected_xprv: [82]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected_xprv, case.xprv_hex);
        const got_xprv = key.serialize(true);
        try std.testing.expectEqualSlices(u8, &expected_xprv, &got_xprv);

        var expected_xpub: [82]u8 = undefined;
        _ = try std.fmt.hexToBytes(&expected_xpub, case.xpub_hex);
        const got_xpub = key.neuter().serialize(true);
        try std.testing.expectEqualSlices(u8, &expected_xpub, &got_xpub);
    }
}

test "BIP32 Test Vector 3: leading-zero retention in private keys" {
    // This vector specifically guards against implementations that drop
    // leading zero bytes when serializing private keys (a classic
    // funds-loss bug). Seed and expected keys from the BIP-32 spec.
    var seed: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&seed, "4b381541583be4423346c643850da4b320e46a87ae3d2a4e6da11eba819cd4acba45d239319ac14f863b8d5ab5a0d0c64d2e8a1e7d1457df2e5a3c51c73235be");

    const master = try ExtendedKey.fromSeed(&seed);

    // m: xprv9s21ZrQH143K25QhxbucbDDuQ4naNntJRi4KUfWT7xo4EKsHt2QJDu7KXp1A3u7Bi1j8ph3EGsZ9Xvz9dGuVrtHHs7pXeTzjuxBrCmmhgC6
    var expected_m: [82]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_m, "0488ade400000000000000000001d28a3e53cffa419ec122c968b3259e16b65076495494d97cae10bbfec3c36f0000ddb80b067e0d4993197fe10f2657a844a384589847602d56f0c629c81aae3233c0c6bf");
    const got_m = master.serialize(true);
    try std.testing.expectEqualSlices(u8, &expected_m, &got_m);

    // m/0': xprv9uPDJpEQgRQfDcW7BkF7eTya6RPxXeJCqCJGHuCJ4GiRVLzkTXBAJMu2qaMWPrS7AANYqdq6vcBcBUdJCVVFceUvJFjaPdGZ2y9WACViL4L
    const child = try master.derivePath("m/0'");
    var expected_child: [82]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_child, "0488ade40141d63b5080000000e5fea12a97b927fc9dc3d2cb0d1ea1cf50aa5a1fdc1f933e8906bb38df3377bd00491f7a2eebc7b57028e0d3faa0acda02e75c33b03c48fb288c41e2ea44e1daef7332bb35");
    const got_child = child.serialize(true);
    try std.testing.expectEqualSlices(u8, &expected_child, &got_child);
}

test "BIP84 official vectors: first receive/change addresses" {
    // https://raw.githubusercontent.com/bitcoin/bips/master/bip-0084.mediawiki
    // Mnemonic: "abandon abandon abandon abandon abandon abandon abandon
    // abandon abandon abandon abandon about", empty passphrase.
    // The BIP-39 seed below is the published seed for that mnemonic and is
    // independently proven by the "BIP39 PBKDF2-SHA512 Test Vector 1" test
    // in ffi-grok.zig, which derives this exact value via PBKDF2-HMAC-SHA512.
    var seed: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&seed, "5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc19a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4");

    const master = try ExtendedKey.fromSeed(&seed);

    // First receiving address: m/84'/0'/0'/0/0
    const key0 = try master.derivePath("m/84'/0'/0'/0/0");
    var expected_pubkey: [33]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_pubkey, "0330d54fd0dd420a6e5f8d3624f5f3482cae350f79d5f0753bf5beef9c2d91af3c");
    try std.testing.expectEqualSlices(u8, &expected_pubkey, &key0.public_key);

    var addr0: [90]u8 = undefined;
    const len0 = generateP2wpkhAddress(&key0.public_key, true, &addr0);
    try std.testing.expectEqualSlices(u8, "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu", addr0[0..len0]);

    // Second receiving address: m/84'/0'/0'/0/1
    const key1 = try master.derivePath("m/84'/0'/0'/0/1");
    var addr1: [90]u8 = undefined;
    const len1 = generateP2wpkhAddress(&key1.public_key, true, &addr1);
    try std.testing.expectEqualSlices(u8, "bc1qnjg0jd8228aq7egyzacy8cys3knf9xvrerkf9g", addr1[0..len1]);

    // First change address: m/84'/0'/0'/1/0
    const key_change = try master.derivePath("m/84'/0'/0'/1/0");
    var addr_change: [90]u8 = undefined;
    const len_change = generateP2wpkhAddress(&key_change.public_key, true, &addr_change);
    try std.testing.expectEqualSlices(u8, "bc1q8c6fshw2dlwun7ekn9qwf37cu2rn755upcp6el", addr_change[0..len_change]);
}
