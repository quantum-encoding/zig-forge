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
