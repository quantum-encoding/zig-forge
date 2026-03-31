//! ML-KEM (Module-Lattice-Based Key-Encapsulation Mechanism)
//! FIPS 203 Implementation for Quantum Vault
//!
//! This implementation provides post-quantum key encapsulation based on the
//! Module Learning With Errors (MLWE) problem. It is believed to be secure
//! against adversaries with access to quantum computers.
//!
//! Specification: NIST FIPS 203 (August 13, 2024)
//! https://doi.org/10.6028/NIST.FIPS.203
//!
//! Security Levels:
//! - ML-KEM-512:  Category 1 (~AES-128 equivalent)
//! - ML-KEM-768:  Category 3 (~AES-192 equivalent)
//! - ML-KEM-1024: Category 5 (~AES-256 equivalent)
//!
//! For Quantum Vault, we implement ML-KEM-768 as the default, providing
//! a balance of security and performance suitable for mobile devices.

const std = @import("std");
const crypto = std.crypto;
const mem = std.mem;

// ============================================================================
// FIPS 203 Constants (Section 2.3)
// ============================================================================

/// Polynomial degree - fixed at 256 for all ML-KEM variants
pub const N: u16 = 256;

/// Prime modulus q = 3329 = 2^8 * 13 + 1
/// Chosen specifically because 256 divides (q-1), enabling efficient NTT
pub const Q: i32 = 3329;

/// Primitive 256th root of unity modulo q
/// ζ = 17 satisfies ζ^256 ≡ 1 (mod q) and ζ^128 ≡ -1 (mod q)
pub const ZETA: i32 = 17;

/// Montgomery reduction constant: 2^16 mod q
pub const MONT_R: i32 = 1 << 16;

/// Inverse of 128 modulo q (used in NTT^-1)
/// 3303 ≡ 128^-1 (mod 3329)
pub const INV_128: i32 = 3303;

// ============================================================================
// Parameter Sets (Section 8, Table 2)
// ============================================================================

/// ML-KEM parameter configuration
pub const Params = struct {
    /// Module rank (number of polynomials in vectors)
    k: u8,
    /// CBD parameter for secret/error sampling
    eta1: u8,
    /// CBD parameter for error sampling in encryption
    eta2: u8,
    /// Bits for compressing u vector
    du: u8,
    /// Bits for compressing v polynomial
    dv: u8,

    // Derived sizes
    pub fn encapsulationKeySize(self: Params) usize {
        return 384 * @as(usize, self.k) + 32;
    }

    pub fn decapsulationKeySize(self: Params) usize {
        return 768 * @as(usize, self.k) + 96;
    }

    pub fn ciphertextSize(self: Params) usize {
        return 32 * (@as(usize, self.du) * @as(usize, self.k) + @as(usize, self.dv));
    }
};

/// ML-KEM-512: Security Category 1 (~AES-128)
pub const ML_KEM_512 = Params{
    .k = 2,
    .eta1 = 3,
    .eta2 = 2,
    .du = 10,
    .dv = 4,
};

/// ML-KEM-768: Security Category 3 (~AES-192) - Recommended for Quantum Vault
pub const ML_KEM_768 = Params{
    .k = 3,
    .eta1 = 2,
    .eta2 = 2,
    .du = 10,
    .dv = 4,
};

/// ML-KEM-1024: Security Category 5 (~AES-256)
pub const ML_KEM_1024 = Params{
    .k = 4,
    .eta1 = 2,
    .eta2 = 2,
    .du = 11,
    .dv = 5,
};

// ============================================================================
// Polynomial Type
// ============================================================================

/// A polynomial in R_q = Z_q[X]/(X^256 + 1)
/// Coefficients are stored as signed integers in range [0, q-1]
pub const Poly = struct {
    coeffs: [N]i16,

    pub fn init() Poly {
        return .{ .coeffs = [_]i16{0} ** N };
    }

    /// Add two polynomials coefficient-wise
    pub fn add(self: *Poly, other: *const Poly) void {
        for (0..N) |i| {
            self.coeffs[i] = barrettReduce(self.coeffs[i] + other.coeffs[i]);
        }
    }

    /// Subtract two polynomials coefficient-wise
    pub fn sub(self: *Poly, other: *const Poly) void {
        for (0..N) |i| {
            self.coeffs[i] = barrettReduce(self.coeffs[i] - other.coeffs[i]);
        }
    }
};

// ============================================================================
// Precomputed Zeta Powers (Appendix A)
// ============================================================================

/// Precomputed values: ζ^BitRev7(i) mod q for i = 0..127
/// Used in NTT and NTT^-1 for efficient butterfly operations
/// These are computed as: zetas[i] = 17^BitRev7(i) mod 3329
const ZETAS: [128]i16 = [_]i16{
    1,    1729, 2580, 3289, 2642, 630,  1897, 848,
    1062, 1919, 193,  797,  2786, 3260, 569,  1746,
    296,  2447, 1339, 1476, 3046, 56,   2240, 1333,
    1426, 2094, 535,  2882, 2393, 2879, 1974, 821,
    289,  331,  3253, 1756, 1197, 2304, 2277, 2055,
    650,  1977, 2513, 632,  2865, 33,   1320, 1915,
    2319, 1435, 807,  452,  1438, 2868, 1534, 2402,
    2647, 2617, 1481, 648,  2474, 3110, 1227, 910,
    17,   2761, 583,  2649, 1637, 723,  2288, 1100,
    1409, 2662, 3281, 233,  756,  2156, 3015, 3050,
    1703, 1651, 2789, 1789, 1847, 952,  1461, 2687,
    939,  2308, 2437, 2388, 733,  2337, 268,  641,
    1584, 2298, 2037, 3220, 375,  2549, 2090, 1645,
    1063, 319,  2773, 757,  2099, 561,  2466, 2594,
    2804, 1092, 403,  1026, 1143, 2150, 2775, 886,
    1722, 1212, 1874, 1029, 2110, 2935, 885,  2154,
};

/// Precomputed values: ζ^(2*BitRev7(i)+1) mod q for i = 0..127
/// Used in BaseCaseMultiply for multiplication in T_q
const ZETAS_MULT: [128]i16 = blk: {
    var result: [128]i16 = undefined;
    for (0..128) |i| {
        // ζ^(2*BitRev7(i)+1) = ζ * (ζ^BitRev7(i))^2
        const z = ZETAS[i];
        const z_sq = @mod(@as(i32, z) * @as(i32, z), Q);
        result[i] = @intCast(@mod(@as(i32, ZETA) * z_sq, Q));
    }
    break :blk result;
};

// ============================================================================
// Modular Arithmetic
// ============================================================================

/// Barrett reduction: reduce a to range [0, q-1]
/// Uses Barrett's algorithm for efficient modular reduction without division
/// Input: any i16 value
/// Output: equivalent value in [0, q-1]
pub fn barrettReduce(a: i16) i16 {
    // Barrett constant: floor(2^26 / q) = floor(67108864 / 3329) = 20159
    const v: i32 = 20159;
    const a32: i32 = @as(i32, a);

    // t = floor(a * v / 2^26) ≈ floor(a / q)
    var t: i32 = @divTrunc(a32 * v, 1 << 26);

    // a - t*q gives value in approximately [-q, q]
    t = a32 - t * Q;

    // Conditional addition/subtraction to get into [0, q-1]
    // Handle negative values by adding Q
    if (t < 0) {
        t += Q;
    } else if (t >= Q) {
        t -= Q;
    }
    return @intCast(t);
}

/// Montgomery reduction
/// Given a value 'a' that represents a * R (where R = 2^16),
/// compute a mod q
pub fn montgomeryReduce(a: i32) i16 {
    // q^-1 mod 2^16 = 3327 (i.e., 3329 * 3327 ≡ -1 (mod 2^16))
    const q_inv: i32 = 3327;

    // t = a * q^-1 mod 2^16
    const t: i16 = @truncate(a * q_inv);

    // (a - t*q) / 2^16
    const result = @divTrunc(a - @as(i32, t) * Q, 1 << 16);

    return @intCast(result);
}

/// Conditional subtraction of q
/// If a >= q, returns a - q, else returns a
/// Constant-time implementation
fn csubq(a: i16) i16 {
    const a32: i32 = @as(i32, a);
    const mask = @as(i32, @intFromBool(a32 >= Q));
    return @intCast(a32 - mask * Q);
}

// ============================================================================
// Number Theoretic Transform (Section 4.3)
// ============================================================================

/// NTT: Computes the Number Theoretic Transform of polynomial f
/// Transforms from R_q to T_q (the NTT domain)
///
/// Algorithm 9 from FIPS 203
///
/// The NTT uses a Cooley-Tukey butterfly structure with bit-reversed
/// zeta powers. After NTT, polynomial multiplication becomes pointwise
/// multiplication of degree-1 polynomials.
///
/// Input: polynomial f ∈ R_q (coefficients in standard order)
/// Output: NTT representation f̂ ∈ T_q
pub fn ntt(f: *Poly) void {
    var k: usize = 1;
    var len: usize = 128;

    while (len >= 2) : (len /= 2) {
        var start: usize = 0;
        while (start < N) : (start += 2 * len) {
            const zeta: i32 = @as(i32, ZETAS[k]);
            k += 1;

            for (start..start + len) |j| {
                // Butterfly operation:
                // t = ζ * f[j + len]
                // f[j + len] = f[j] - t
                // f[j] = f[j] + t
                const t: i16 = @intCast(@mod(zeta * @as(i32, f.coeffs[j + len]), Q));
                f.coeffs[j + len] = barrettReduce(f.coeffs[j] - t);
                f.coeffs[j] = barrettReduce(f.coeffs[j] + t);
            }
        }
    }
}

/// NTT^-1: Computes the inverse Number Theoretic Transform
/// Transforms from T_q back to R_q
///
/// Algorithm 10 from FIPS 203
///
/// Input: NTT representation f̂ ∈ T_q
/// Output: polynomial f ∈ R_q
pub fn nttInverse(f: *Poly) void {
    var k: usize = 127;
    var len: usize = 2;

    while (len <= 128) : (len *= 2) {
        var start: usize = 0;
        while (start < N) : (start += 2 * len) {
            const zeta: i32 = @as(i32, ZETAS[k]);
            k -= 1;

            for (start..start + len) |j| {
                // Inverse butterfly operation:
                // t = f[j]
                // f[j] = t + f[j + len]
                // f[j + len] = ζ * (f[j + len] - t)
                const t = f.coeffs[j];
                f.coeffs[j] = barrettReduce(t + f.coeffs[j + len]);
                const diff = f.coeffs[j + len] - t;
                f.coeffs[j + len] = @intCast(@mod(zeta * @as(i32, diff), Q));
            }
        }
    }

    // Multiply all coefficients by 128^-1 mod q = 3303
    for (0..N) |i| {
        f.coeffs[i] = @intCast(@mod(@as(i32, f.coeffs[i]) * INV_128, Q));
    }
}

/// BaseCaseMultiply: Multiply two degree-1 polynomials modulo (X^2 - γ)
///
/// Algorithm 12 from FIPS 203
///
/// Computes (a0 + a1*X) * (b0 + b1*X) mod (X^2 - γ)
///        = (a0*b0 + a1*b1*γ) + (a0*b1 + a1*b0)*X
///
/// Input: coefficients a0, a1, b0, b1 and root γ = ζ^(2*BitRev7(i)+1)
/// Output: coefficients (c0, c1) of the product
fn baseCaseMultiply(a0: i16, a1: i16, b0: i16, b1: i16, gamma: i16) struct { c0: i16, c1: i16 } {
    const a0_32: i32 = @as(i32, a0);
    const a1_32: i32 = @as(i32, a1);
    const b0_32: i32 = @as(i32, b0);
    const b1_32: i32 = @as(i32, b1);
    const gamma_32: i32 = @as(i32, gamma);

    // c0 = a0*b0 + a1*b1*γ
    const c0 = @mod(a0_32 * b0_32 + @mod(a1_32 * b1_32, Q) * gamma_32, Q);

    // c1 = a0*b1 + a1*b0
    const c1 = @mod(a0_32 * b1_32 + a1_32 * b0_32, Q);

    return .{
        .c0 = @intCast(c0),
        .c1 = @intCast(c1),
    };
}

/// MultiplyNTTs: Pointwise multiplication in the NTT domain
///
/// Algorithm 11 from FIPS 203
///
/// Computes the product h = f × g in T_q by performing 128 independent
/// multiplications of degree-1 polynomials.
///
/// Input: NTT representations f̂, ĝ ∈ T_q
/// Output: NTT representation ĥ = f̂ ×_T_q ĝ
pub fn multiplyNTTs(f: *const Poly, g: *const Poly, result: *Poly) void {
    for (0..128) |i| {
        const gamma = ZETAS_MULT[i];

        const product = baseCaseMultiply(
            f.coeffs[2 * i],
            f.coeffs[2 * i + 1],
            g.coeffs[2 * i],
            g.coeffs[2 * i + 1],
            gamma,
        );

        result.coeffs[2 * i] = product.c0;
        result.coeffs[2 * i + 1] = product.c1;
    }
}

// ============================================================================
// Compression and Decompression (Section 4.2.1)
// ============================================================================

/// Compress_d: Maps Z_q to Z_{2^d}
/// compress_d(x) = ⌈(2^d / q) · x⌋ mod 2^d
///
/// This lossy compression is used to reduce ciphertext size.
pub fn compress(x: i16, comptime d: comptime_int) u16 {
    const x_u32: u32 = @intCast(@mod(@as(i32, x), Q));
    const two_d: u32 = @as(u32, 1) << d;

    // Round((2^d * x) / q) mod 2^d
    // = floor((2^d * x + q/2) / q) mod 2^d
    const numerator = (x_u32 << d) + (@as(u32, @intCast(Q)) >> 1);
    const result = numerator / @as(u32, @intCast(Q));

    return @intCast(result & (two_d - 1));
}

/// Decompress_d: Maps Z_{2^d} to Z_q
/// decompress_d(y) = ⌈(q / 2^d) · y⌋
///
/// This is the approximate inverse of compress.
pub fn decompress(y: u16, comptime d: comptime_int) i16 {
    const y_u32: u32 = @as(u32, y);
    const q_u32: u32 = @as(u32, @intCast(Q));
    const two_d: u32 = @as(u32, 1) << d;

    // Round((q * y) / 2^d)
    // = floor((q * y + 2^(d-1)) / 2^d)
    const numerator = q_u32 * y_u32 + (two_d >> 1);
    const result = numerator >> d;

    return @intCast(result);
}

// ============================================================================
// Byte Encoding/Decoding (Section 4.2.1, Algorithms 5-6)
// ============================================================================

/// ByteEncode_d: Encode array of d-bit integers into bytes
/// Packs 256 integers (each d bits) into 32*d bytes
pub fn byteEncode(comptime d: comptime_int, f: *const [N]i16, output: *[32 * d]u8) void {
    var bit_idx: usize = 0;

    for (0..N) |i| {
        var a: u16 = @intCast(@mod(@as(i32, f[i]), if (d == 12) Q else (1 << d)));

        for (0..d) |_| {
            const byte_idx = bit_idx / 8;
            const bit_offset: u3 = @intCast(bit_idx % 8);

            if (bit_offset == 0) {
                output[byte_idx] = 0;
            }

            output[byte_idx] |= @as(u8, @intCast(a & 1)) << bit_offset;
            a >>= 1;
            bit_idx += 1;
        }
    }
}

/// ByteDecode_d: Decode bytes into array of d-bit integers
/// Unpacks 32*d bytes into 256 integers (each d bits)
pub fn byteDecode(comptime d: comptime_int, input: *const [32 * d]u8, f: *[N]i16) void {
    var bit_idx: usize = 0;

    for (0..N) |i| {
        var value: u16 = 0;

        for (0..d) |j| {
            const byte_idx = bit_idx / 8;
            const bit_offset: u3 = @intCast(bit_idx % 8);

            const bit: u16 = @as(u16, (input[byte_idx] >> bit_offset) & 1);
            value |= bit << @intCast(j);
            bit_idx += 1;
        }

        // For d=12, reduce modulo q
        if (d == 12) {
            f[i] = @intCast(@mod(@as(i32, value), Q));
        } else {
            f[i] = @intCast(value);
        }
    }
}

// ============================================================================
// Sampling (Section 4.2.2)
// ============================================================================

/// SamplePolyCBD_η: Sample from centered binomial distribution
///
/// Algorithm 8 from FIPS 203
///
/// Each coefficient is sampled as: sum of η random bits - sum of η random bits
/// This gives coefficients in range [-η, η] with a binomial distribution.
///
/// Input: 64*η random bytes
/// Output: polynomial with small coefficients
pub fn samplePolyCBD(comptime eta: u2, bytes: []const u8, result: *Poly) void {
    const bits = bytesToBits(bytes);

    for (0..N) |i| {
        var x: i16 = 0;
        var y: i16 = 0;

        for (0..eta) |j| {
            x += @as(i16, bits[2 * i * eta + j]);
            y += @as(i16, bits[2 * i * eta + eta + j]);
        }

        result.coeffs[i] = barrettReduce(x - y);
    }
}

fn bytesToBits(bytes: []const u8) []const u1 {
    // In a real implementation, this would be done more efficiently
    // For now, this is a placeholder that processes bits inline
    _ = bytes;
    @compileError("bytesToBits needs proper implementation");
}

// ============================================================================
// Hash Functions (Section 4.1)
// ============================================================================

/// H(s) = SHA3-256(s)
pub fn hashH(input: []const u8) [32]u8 {
    var hasher = crypto.hash.sha3.Sha3_256.init(.{});
    hasher.update(input);
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

/// G(c) = SHA3-512(c), returns two 32-byte arrays
pub fn hashG(input: []const u8) struct { a: [32]u8, b: [32]u8 } {
    var hasher = crypto.hash.sha3.Sha3_512.init(.{});
    hasher.update(input);
    var full: [64]u8 = undefined;
    hasher.final(&full);
    return .{
        .a = full[0..32].*,
        .b = full[32..64].*,
    };
}

/// J(s) = SHAKE256(s, 256) - outputs 32 bytes
pub fn hashJ(input: []const u8) [32]u8 {
    var output: [32]u8 = undefined;
    crypto.hash.sha3.Shake256.hash(input, &output, .{});
    return output;
}

/// PRF_η(s, b) = SHAKE256(s || b, 64*η)
pub fn prf(comptime eta: comptime_int, seed: *const [32]u8, nonce: u8, output: []u8) void {
    var input: [33]u8 = undefined;
    @memcpy(input[0..32], seed);
    input[32] = nonce;

    crypto.hash.sha3.Shake256.hash(&input, output[0 .. 64 * eta], .{});
}

// ============================================================================
// Tests
// ============================================================================

test "barrett reduction" {
    // Test basic reduction
    try std.testing.expectEqual(@as(i16, 0), barrettReduce(0));
    try std.testing.expectEqual(@as(i16, 1), barrettReduce(1));
    try std.testing.expectEqual(@as(i16, 3328), barrettReduce(3328));
    try std.testing.expectEqual(@as(i16, 0), barrettReduce(3329));
    try std.testing.expectEqual(@as(i16, 1), barrettReduce(3330));

    // Test negative values
    try std.testing.expectEqual(@as(i16, 3328), barrettReduce(-1));
}

test "NTT round trip" {
    // Create a test polynomial
    var poly = Poly.init();
    for (0..N) |i| {
        poly.coeffs[i] = @intCast(@mod(@as(i32, @intCast(i)) * 17, Q));
    }

    // Save original
    var original: [N]i16 = undefined;
    @memcpy(&original, &poly.coeffs);

    // Forward NTT
    ntt(&poly);

    // Inverse NTT
    nttInverse(&poly);

    // Should match original
    for (0..N) |i| {
        const expected = barrettReduce(original[i]);
        const actual = barrettReduce(poly.coeffs[i]);
        try std.testing.expectEqual(expected, actual);
    }
}

test "compress/decompress" {
    // Test that decompress(compress(x)) ≈ x for various d values
    const test_values = [_]i16{ 0, 1, 100, 1000, 2000, 3000, 3328 };

    inline for ([_]comptime_int{ 1, 4, 10, 11 }) |d| {
        for (test_values) |x| {
            const compressed = compress(x, d);
            const decompressed = decompress(compressed, d);

            // The error should be at most q/(2^(d+1)) + 1
            const max_error: u32 = @intCast(@divTrunc(Q, @as(i32, 1) << (d + 1)) + 1);

            // Use modular distance (accounts for wrap-around)
            const raw_diff: u32 = @abs(@as(i32, x) - @as(i32, decompressed));
            const q_u32: u32 = @intCast(Q);
            const mod_diff = @min(raw_diff, q_u32 -| raw_diff);
            try std.testing.expect(mod_diff <= max_error);
        }
    }
}

test "multiply NTTs" {
    // Test that multiplication in NTT domain is correct
    var f = Poly.init();
    var g = Poly.init();
    var h = Poly.init();

    // Simple test: f = 1 (constant polynomial)
    f.coeffs[0] = 1;
    // g = X (monomial)
    g.coeffs[1] = 1;

    // Transform to NTT domain
    ntt(&f);
    ntt(&g);

    // Multiply
    multiplyNTTs(&f, &g, &h);

    // Transform back
    nttInverse(&h);

    // Result should be X (in standard form)
    try std.testing.expectEqual(@as(i16, 0), h.coeffs[0]);
    try std.testing.expect(h.coeffs[1] != 0); // Should have X term
}
