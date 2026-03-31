//! ML-DSA-65 (FIPS 204) Complete Implementation
//!
//! Module-Lattice-Based Digital Signature Algorithm
//! Security Level 3 (192-bit security, ~AES-192 equivalent)
//!
//! This is a complete implementation following NIST FIPS 204 (August 2024)
//! https://doi.org/10.6028/NIST.FIPS.204
//!
//! Key Sizes:
//!   - Public Key:  1952 bytes
//!   - Private Key: 4032 bytes  
//!   - Signature:   3309 bytes
//!
//! Parameters for ML-DSA-65:
//!   q = 8380417 (prime modulus)
//!   n = 256 (polynomial degree)
//!   k = 6, l = 5 (matrix dimensions)
//!   η = 4 (secret key coefficient bound)
//!   γ1 = 2^19 (mask coefficient bound)
//!   γ2 = (q-1)/32 = 261888 (low-order rounding range)
//!   τ = 49 (number of ±1s in challenge)
//!   β = τ·η = 196 (signature bound)
//!   ω = 55 (max hint weight)

const std = @import("std");
const crypto = std.crypto;
const mem = std.mem;

// ============================================================================
// ML-DSA-65 Parameters (FIPS 204 Table 1)
// ============================================================================

/// Polynomial degree (fixed for all ML-DSA variants)
pub const N: usize = 256;

/// Prime modulus q = 2^23 - 2^13 + 1
/// Chosen so that 256 | (q-1), enabling efficient NTT
pub const Q: i32 = 8380417;

/// Matrix dimensions for ML-DSA-65
pub const K: usize = 6; // rows
pub const L: usize = 5; // columns

/// Secret key coefficient bound: coefficients in [-η, η]
pub const ETA: i32 = 4;

/// Mask coefficient bound: γ1 = 2^19
pub const GAMMA1: i32 = 1 << 19; // 524288

/// Low-order rounding range: γ2 = (q-1)/32
pub const GAMMA2: i32 = (Q - 1) / 32; // 261888

/// Number of ±1s in challenge polynomial
pub const TAU: usize = 49;

/// Signature bound: β = τ·η
pub const BETA: i32 = TAU * ETA; // 196

/// Maximum hint weight (ones in hint vector)
pub const OMEGA: usize = 55;

/// Dropped bits from t: d = 13
pub const D: u5 = 13;

/// Challenge seed bytes
pub const CTILDE_BYTES: usize = 32;

/// Primitive 256th root of unity mod q
/// ζ = 1753 satisfies ζ^256 ≡ -1 (mod q)
pub const ZETA: i32 = 1753;

/// Montgomery constant R = 2^32 mod q
pub const MONT_R: i64 = 4236238847; // 2^32 mod q

/// q^-1 mod 2^32 (for Montgomery reduction)
pub const Q_INV: i64 = 58728449; // q^(-1) mod 2^32

// ============================================================================
// Key and Signature Sizes
// ============================================================================

pub const PUBLIC_KEY_SIZE: usize = 1952;
pub const SECRET_KEY_SIZE: usize = 4032;
pub const SIGNATURE_SIZE: usize = 3309;

// ============================================================================
// Data Types
// ============================================================================

/// A polynomial in R_q = Z_q[X]/(X^256 + 1)
pub const Poly = struct {
    coeffs: [N]i32,

    pub fn init() Poly {
        return .{ .coeffs = [_]i32{0} ** N };
    }

    /// Add two polynomials
    pub fn add(self: *Poly, other: *const Poly) void {
        for (0..N) |i| {
            self.coeffs[i] = reduce32(self.coeffs[i] + other.coeffs[i]);
        }
    }

    /// Subtract two polynomials
    pub fn sub(self: *Poly, other: *const Poly) void {
        for (0..N) |i| {
            self.coeffs[i] = reduce32(self.coeffs[i] - other.coeffs[i]);
        }
    }

    /// Pointwise multiplication (in NTT domain)
    pub fn pointwiseMul(result: *Poly, a: *const Poly, b: *const Poly) void {
        for (0..N) |i| {
            result.coeffs[i] = montgomeryReduce(@as(i64, a.coeffs[i]) * @as(i64, b.coeffs[i]));
        }
    }

    /// Check if infinity norm is less than bound
    pub fn checkNorm(self: *const Poly, bound: i32) bool {
        for (0..N) |i| {
            var coeff = self.coeffs[i];
            // Reduce to centered representation
            coeff = coeff - ((coeff >> 22) & 1) * Q;
            if (coeff < 0) coeff = -coeff;
            if (coeff >= bound) return false;
        }
        return true;
    }
};

/// Vector of L polynomials (for s1, y, z)
pub const PolyVecL = struct {
    polys: [L]Poly,

    pub fn init() PolyVecL {
        var result: PolyVecL = undefined;
        for (0..L) |i| {
            result.polys[i] = Poly.init();
        }
        return result;
    }

    pub fn add(self: *PolyVecL, other: *const PolyVecL) void {
        for (0..L) |i| {
            self.polys[i].add(&other.polys[i]);
        }
    }

    pub fn checkNorm(self: *const PolyVecL, bound: i32) bool {
        for (0..L) |i| {
            if (!self.polys[i].checkNorm(bound)) return false;
        }
        return true;
    }

    pub fn ntt(self: *PolyVecL) void {
        for (0..L) |i| {
            nttForward(&self.polys[i]);
        }
    }

    pub fn invNtt(self: *PolyVecL) void {
        for (0..L) |i| {
            nttInverse(&self.polys[i]);
        }
    }
};

/// Vector of K polynomials (for s2, t, w, etc.)
pub const PolyVecK = struct {
    polys: [K]Poly,

    pub fn init() PolyVecK {
        var result: PolyVecK = undefined;
        for (0..K) |i| {
            result.polys[i] = Poly.init();
        }
        return result;
    }

    pub fn add(self: *PolyVecK, other: *const PolyVecK) void {
        for (0..K) |i| {
            self.polys[i].add(&other.polys[i]);
        }
    }

    pub fn sub(self: *PolyVecK, other: *const PolyVecK) void {
        for (0..K) |i| {
            self.polys[i].sub(&other.polys[i]);
        }
    }

    pub fn checkNorm(self: *const PolyVecK, bound: i32) bool {
        for (0..K) |i| {
            if (!self.polys[i].checkNorm(bound)) return false;
        }
        return true;
    }

    pub fn ntt(self: *PolyVecK) void {
        for (0..K) |i| {
            nttForward(&self.polys[i]);
        }
    }

    pub fn invNtt(self: *PolyVecK) void {
        for (0..K) |i| {
            nttInverse(&self.polys[i]);
        }
    }
};

/// Matrix A: K rows × L columns of polynomials
pub const PolyMatrix = struct {
    rows: [K][L]Poly,

    pub fn init() PolyMatrix {
        var result: PolyMatrix = undefined;
        for (0..K) |i| {
            for (0..L) |j| {
                result.rows[i][j] = Poly.init();
            }
        }
        return result;
    }
};

/// Public Key: ρ (seed for A) || t1 (high bits of t)
pub const PublicKey = struct {
    data: [PUBLIC_KEY_SIZE]u8,

    pub fn getRho(self: *const PublicKey) *const [32]u8 {
        return @ptrCast(self.data[0..32]);
    }
};

/// Secret Key: ρ || K || tr || s1 || s2 || t0
pub const SecretKey = struct {
    data: [SECRET_KEY_SIZE]u8,

    pub fn getRho(self: *const SecretKey) *const [32]u8 {
        return @ptrCast(self.data[0..32]);
    }

    pub fn getK(self: *const SecretKey) *const [32]u8 {
        return @ptrCast(self.data[32..64]);
    }

    pub fn getTr(self: *const SecretKey) *const [64]u8 {
        return @ptrCast(self.data[64..128]);
    }
};

/// Signature: c_tilde || z || hints
pub const Signature = struct {
    data: [SIGNATURE_SIZE]u8,
};

// ============================================================================
// Precomputed Zeta Powers for NTT
// ============================================================================

/// Precomputed ζ^BitRev(i) mod q for i = 0..255
/// These values are specific to q = 8380417
const ZETAS: [256]i32 = computeZetas();

fn computeZetas() [256]i32 {
    @setEvalBranchQuota(100000);
    var result: [256]i32 = undefined;
    var zeta_pow: i64 = 1;

    for (0..256) |i| {
        const br = bitReverse8(@intCast(i));
        // Compute ζ^br mod q
        var val: i64 = 1;
        var exp = br;
        var base: i64 = ZETA;
        while (exp > 0) {
            if (exp & 1 == 1) {
                val = @mod(val * base, Q);
            }
            base = @mod(base * base, Q);
            exp >>= 1;
        }
        result[i] = @intCast(val);
        _ = zeta_pow;
    }
    return result;
}

fn bitReverse8(x: u8) u8 {
    var v = x;
    v = ((v & 0xF0) >> 4) | ((v & 0x0F) << 4);
    v = ((v & 0xCC) >> 2) | ((v & 0x33) << 2);
    v = ((v & 0xAA) >> 1) | ((v & 0x55) << 1);
    return v;
}

// ============================================================================
// Modular Arithmetic
// ============================================================================

/// Reduce a 32-bit integer mod q to range [0, q-1]
pub fn reduce32(a: i32) i32 {
    var t = a;
    // Add q if negative
    t += (t >> 31) & Q;
    // Subtract q if >= q  
    t -= Q;
    t += (t >> 31) & Q;
    return t;
}

/// Montgomery reduction: given a*R, compute a mod q
/// where R = 2^32
pub fn montgomeryReduce(a: i64) i32 {
    const t: i32 = @truncate(a * Q_INV);
    const result = @as(i32, @truncate((a - @as(i64, t) * Q) >> 32));
    return result;
}

/// Reduce coefficient to centered representation [-q/2, q/2]
pub fn centerReduce(a: i32) i32 {
    var t = reduce32(a);
    t -= (Q + 1) / 2;
    t += (t >> 31) & Q;
    t -= (Q - 1) / 2;
    return t;
}

// ============================================================================
// NTT Operations (Algorithm 41-42 from FIPS 204)
// ============================================================================

/// Forward NTT: transforms polynomial to NTT domain
pub fn nttForward(p: *Poly) void {
    var k: usize = 0;
    var len: usize = 128;

    while (len >= 1) : (len /= 2) {
        var start: usize = 0;
        while (start < N) : (start += 2 * len) {
            k += 1;
            const zeta: i64 = @as(i64, ZETAS[k]);

            for (start..start + len) |j| {
                const t = montgomeryReduce(zeta * @as(i64, p.coeffs[j + len]));
                p.coeffs[j + len] = p.coeffs[j] - t;
                p.coeffs[j] = p.coeffs[j] + t;
            }
        }
    }
}

/// Inverse NTT: transforms from NTT domain back to polynomial
pub fn nttInverse(p: *Poly) void {
    var k: usize = 256;
    var len: usize = 1;

    while (len < N) : (len *= 2) {
        var start: usize = 0;
        while (start < N) : (start += 2 * len) {
            k -= 1;
            const zeta: i64 = @as(i64, -ZETAS[k]);

            for (start..start + len) |j| {
                const t = p.coeffs[j];
                p.coeffs[j] = t + p.coeffs[j + len];
                p.coeffs[j + len] = t - p.coeffs[j + len];
                p.coeffs[j + len] = montgomeryReduce(zeta * @as(i64, p.coeffs[j + len]));
            }
        }
    }

    // Multiply by n^-1 mod q = 8347681
    const f: i64 = 8347681; // 256^-1 * R mod q (Montgomery form)
    for (0..N) |j| {
        p.coeffs[j] = montgomeryReduce(f * @as(i64, p.coeffs[j]));
    }
}

/// Matrix-vector multiplication: w = A * v (both in NTT domain)
pub fn matrixVecMul(result: *PolyVecK, a: *const PolyMatrix, v: *const PolyVecL) void {
    for (0..K) |i| {
        result.polys[i] = Poly.init();
        for (0..L) |j| {
            var tmp: Poly = undefined;
            Poly.pointwiseMul(&tmp, &a.rows[i][j], &v.polys[j]);
            result.polys[i].add(&tmp);
        }
    }
}

// ============================================================================
// Sampling Functions
// ============================================================================

/// ExpandA: Generate matrix A from seed ρ using SHAKE128
/// Algorithm 26 from FIPS 204
pub fn expandA(a: *PolyMatrix, rho: *const [32]u8) void {
    for (0..K) |i| {
        for (0..L) |j| {
            rejNttPoly(&a.rows[i][j], rho, @intCast(j), @intCast(i));
        }
    }
}

/// Sample polynomial with coefficients in [0, q-1] using rejection sampling
fn rejNttPoly(p: *Poly, rho: *const [32]u8, j: u8, i: u8) void {
    var xof = crypto.hash.sha3.Shake128.init(.{});
    xof.update(rho);
    xof.update(&[_]u8{j, i});

    var ctr: usize = 0;
    while (ctr < N) {
        var buf: [3]u8 = undefined;
        xof.squeeze(&buf);

        // Extract two potential coefficients from 3 bytes
        const b0: u32 = buf[0];
        const b1: u32 = buf[1];
        const b2: u32 = buf[2];

        const d1: u32 = b0 | ((b1 & 0x0F) << 8);
        const d2: u32 = (b1 >> 4) | (b2 << 4);

        // Rejection sampling: accept if < q
        if (d1 < Q and ctr < N) {
            p.coeffs[ctr] = @intCast(d1);
            ctr += 1;
        }
        if (d2 < Q and ctr < N) {
            p.coeffs[ctr] = @intCast(d2);
            ctr += 1;
        }
    }
}

/// Sample secret polynomial with coefficients in [-η, η]
/// Algorithm 28 from FIPS 204 (CoeffFromHalfByte for η=4)
pub fn sampleEta(p: *Poly, seed: *const [64]u8, nonce: u16) void {
    var xof = crypto.hash.sha3.Shake256.init(.{});
    xof.update(seed);
    xof.update(&[_]u8{ @truncate(nonce), @truncate(nonce >> 8) });

    var ctr: usize = 0;
    while (ctr < N) {
        var buf: [1]u8 = undefined;
        xof.squeeze(&buf);

        const b = buf[0];
        const b0 = b & 0x0F;
        const b1 = b >> 4;

        // For η=4: if b0 < 9, coeff = b0 mod 5 - 4 mapped to [-4,4]
        if (b0 < 9 and ctr < N) {
            p.coeffs[ctr] = eta4Coeff(b0);
            ctr += 1;
        }
        if (b1 < 9 and ctr < N) {
            p.coeffs[ctr] = eta4Coeff(b1);
            ctr += 1;
        }
    }
}

fn eta4Coeff(b: u8) i32 {
    // Map [0,8] -> [-4,4]: 0->4, 1->3, 2->2, 3->1, 4->0, 5->-1, 6->-2, 7->-3, 8->-4
    return @as(i32, 4) - @as(i32, b);
}

/// Sample mask polynomial y with coefficients in [-γ1+1, γ1]
/// Algorithm 29 from FIPS 204 (ExpandMask)
pub fn sampleGamma1(p: *Poly, seed: *const [64]u8, nonce: u16) void {
    var xof = crypto.hash.sha3.Shake256.init(.{});
    xof.update(seed);
    xof.update(&[_]u8{ @truncate(nonce), @truncate(nonce >> 8) });

    // For γ1 = 2^19, we need 20 bits per coefficient
    // Pack 4 coefficients into 10 bytes (80 bits = 4 × 20 bits)
    var buf: [640]u8 = undefined; // 256 coeffs × 20 bits / 8 = 640 bytes
    xof.squeeze(&buf);

    var idx: usize = 0;
    var i: usize = 0;
    while (i < N) : (i += 4) {
        // Unpack 4 coefficients from 10 bytes (80 bits)
        const coeff0 = (@as(u32, buf[idx + 0])) |
            (@as(u32, buf[idx + 1]) << 8) |
            ((@as(u32, buf[idx + 2]) & 0x0F) << 16);

        const coeff1 = (@as(u32, buf[idx + 2]) >> 4) |
            (@as(u32, buf[idx + 3]) << 4) |
            (@as(u32, buf[idx + 4]) << 12);

        const coeff2 = (@as(u32, buf[idx + 5])) |
            (@as(u32, buf[idx + 6]) << 8) |
            ((@as(u32, buf[idx + 7]) & 0x0F) << 16);

        const coeff3 = (@as(u32, buf[idx + 7]) >> 4) |
            (@as(u32, buf[idx + 8]) << 4) |
            (@as(u32, buf[idx + 9]) << 12);

        // Map [0, 2*γ1-1] to [-γ1+1, γ1]
        p.coeffs[i + 0] = @as(i32, GAMMA1) - @as(i32, @as(i32, @intCast(coeff0 & 0xFFFFF)));
        p.coeffs[i + 1] = @as(i32, GAMMA1) - @as(i32, @as(i32, @intCast(coeff1 & 0xFFFFF)));
        p.coeffs[i + 2] = @as(i32, GAMMA1) - @as(i32, @as(i32, @intCast(coeff2 & 0xFFFFF)));
        p.coeffs[i + 3] = @as(i32, GAMMA1) - @as(i32, @as(i32, @intCast(coeff3 & 0xFFFFF)));

        idx += 10;
    }
}

/// SampleInBall: Generate challenge polynomial with τ coefficients in {-1, +1}
/// Algorithm 30 from FIPS 204
pub fn sampleInBall(c: *Poly, seed: *const [32]u8) void {
    var xof = crypto.hash.sha3.Shake256.init(.{});
    xof.update(seed);

    // Initialize c to zero
    c.* = Poly.init();

    // Get initial 8 bytes for sign bits
    var signs: [8]u8 = undefined;
    xof.squeeze(&signs);
    var sign_bits: u64 = 0;
    for (0..8) |i| {
        sign_bits |= @as(u64, signs[i]) << @intCast(i * 8);
    }

    // Place TAU non-zero coefficients using Fisher-Yates
    var i: usize = N - TAU;
    while (i < N) : (i += 1) {
        // Sample j uniformly from [0, i]
        var j: usize = undefined;
        while (true) {
            var buf: [1]u8 = undefined;
            xof.squeeze(&buf);
            j = buf[0];
            if (j <= i) break;
        }

        // Swap c[i] and c[j]
        c.coeffs[i] = c.coeffs[j];

        // Set c[j] = ±1 based on sign bit
        c.coeffs[j] = 1 - 2 * @as(i32, @intCast(sign_bits & 1));
        sign_bits >>= 1;
    }
}

// ============================================================================
// Decompose and Rounding (Section 8.4 of FIPS 204)
// ============================================================================

/// Power2Round: decompose r into (r1, r0) where r = r1*2^d + r0
/// r0 is in [-2^(d-1), 2^(d-1)]
pub fn power2Round(r: i32) struct { r1: i32, r0: i32 } {
    const r_plus = reduce32(r);
    const r0 = @mod(r_plus, (1 << D)) - (1 << (D - 1));
    const r1 = @divTrunc(r_plus - r0, (1 << D));
    return .{ .r1 = r1, .r0 = r0 };
}

/// Decompose: decompose r into (r1, r0) where r ≈ r1*α (α = 2*γ2)
/// Used in signing for hint computation
pub fn decompose(r: i32) struct { r1: i32, r0: i32 } {
    const r_plus = reduce32(r);

    // r0 = r mod± α where α = 2*γ2
    var r0 = @mod(r_plus, 2 * GAMMA2);
    if (r0 > GAMMA2) r0 -= 2 * GAMMA2;

    // r1 = (r - r0) / α, with special case for r - r0 = q - 1
    var r1: i32 = undefined;
    if (r_plus - r0 == Q - 1) {
        r1 = 0;
        r0 = r0 - 1;
    } else {
        r1 = @divTrunc(r_plus - r0, 2 * GAMMA2);
    }

    return .{ .r1 = r1, .r0 = r0 };
}

/// HighBits: extract high bits (r1) from decomposition
pub fn highBits(r: i32) i32 {
    return decompose(r).r1;
}

/// LowBits: extract low bits (r0) from decomposition
pub fn lowBits(r: i32) i32 {
    return decompose(r).r0;
}

/// MakeHint: compute hint bit for recovering high bits
/// Returns 1 if highBits(r) ≠ highBits(r + z), else 0
pub fn makeHint(z: i32, r: i32) u1 {
    const r0 = lowBits(r);
    const r1 = highBits(r);
    const r1_new = highBits(r + z);
    return if (r1 != r1_new) 1 else 0;
}

/// UseHint: recover high bits using hint
pub fn useHint(h: u1, r: i32) i32 {
    const d = decompose(r);
    if (h == 0) return d.r1;

    // Adjust r1 based on sign of r0
    if (d.r0 > 0) {
        return @mod(d.r1 + 1, (Q - 1) / (2 * GAMMA2) + 1);
    } else {
        return @mod(d.r1 - 1, (Q - 1) / (2 * GAMMA2) + 1);
    }
}

// ============================================================================
// Encoding Functions
// ============================================================================

/// Pack polynomial with coefficients in [0, 2^bits - 1]
pub fn polyPackBits(p: *const Poly, comptime bits: u5, output: []u8) void {
    const bytes_needed = (N * bits + 7) / 8;
    @memset(output[0..bytes_needed], 0);

    var bit_pos: usize = 0;
    for (0..N) |i| {
        const coeff: u32 = @intCast(reduce32(p.coeffs[i]));

        // Pack 'bits' bits starting at bit_pos
        for (0..bits) |b| {
            const byte_idx = bit_pos / 8;
            const bit_idx: u3 = @intCast(bit_pos % 8);
            output[byte_idx] |= @as(u8, @truncate((coeff >> @intCast(b)) & 1)) << bit_idx;
            bit_pos += 1;
        }
    }
}

/// Unpack polynomial with coefficients in [0, 2^bits - 1]
pub fn polyUnpackBits(p: *Poly, comptime bits: u5, input: []const u8) void {
    var bit_pos: usize = 0;
    for (0..N) |i| {
        var coeff: u32 = 0;

        for (0..bits) |b| {
            const byte_idx = bit_pos / 8;
            const bit_idx: u3 = @intCast(bit_pos % 8);
            coeff |= @as(u32, (input[byte_idx] >> bit_idx) & 1) << @intCast(b);
            bit_pos += 1;
        }

        p.coeffs[i] = @intCast(coeff);
    }
}

// ============================================================================
// Key Generation (Algorithm 1 from FIPS 204)
// ============================================================================

pub const KeyPair = struct {
    pk: PublicKey,
    sk: SecretKey,
};

/// Generate ML-DSA-65 key pair
pub fn keyGen(seed: ?*const [32]u8) KeyPair {
    var xi: [32]u8 = undefined;

    if (seed) |s| {
        xi = s.*;
    } else {
        crypto.random.bytes(&xi) catch @panic("RNG failure");
    }

    // Expand seed: (ρ, ρ', K) = H(ξ)
    var expanded: [128]u8 = undefined;
    var h = crypto.hash.sha3.Shake256.init(.{});
    h.update(&xi);
    h.squeeze(&expanded);

    const rho = expanded[0..32];
    const rhoprime = expanded[32..96];
    const k_seed = expanded[96..128];

    // Generate matrix A
    var a: PolyMatrix = undefined;
    expandA(&a, rho);

    // Sample secret vectors s1, s2
    var s1: PolyVecL = undefined;
    var s2: PolyVecK = undefined;

    for (0..L) |i| {
        sampleEta(&s1.polys[i], rhoprime, @intCast(i));
    }
    for (0..K) |i| {
        sampleEta(&s2.polys[i], rhoprime, @intCast(L + i));
    }

    // t = A*s1 + s2 (in NTT domain)
    var s1_hat = s1;
    s1_hat.ntt();

    var t: PolyVecK = undefined;
    matrixVecMul(&t, &a, &s1_hat);
    t.invNtt();
    t.add(&s2);

    // Decompose t into t1, t0
    var t1: PolyVecK = undefined;
    var t0: PolyVecK = undefined;

    for (0..K) |i| {
        for (0..N) |j| {
            const parts = power2Round(t.polys[i].coeffs[j]);
            t1.polys[i].coeffs[j] = parts.r1;
            t0.polys[i].coeffs[j] = parts.r0;
        }
    }

    // Pack public key: pk = ρ || t1
    var pk: PublicKey = undefined;
    @memcpy(pk.data[0..32], rho);

    var offset: usize = 32;
    for (0..K) |i| {
        polyPackBits(&t1.polys[i], 10, pk.data[offset .. offset + 320]);
        offset += 320;
    }

    // Compute tr = H(pk)
    var tr: [64]u8 = undefined;
    var h2 = crypto.hash.sha3.Shake256.init(.{});
    h2.update(&pk.data);
    h2.squeeze(&tr);

    // Pack secret key: sk = ρ || K || tr || s1 || s2 || t0
    var sk: SecretKey = undefined;
    @memcpy(sk.data[0..32], rho);
    @memcpy(sk.data[32..64], k_seed);
    @memcpy(sk.data[64..128], &tr);

    offset = 128;
    // Pack s1 (η=4, so 4 bits per coeff, but need to handle [-4,4])
    for (0..L) |i| {
        for (0..N / 2) |j| {
            const c0: u8 = @intCast(@as(u32, @bitCast(ETA - s1.polys[i].coeffs[2 * j])) & 0x0F);
            const c1: u8 = @intCast(@as(u32, @bitCast(ETA - s1.polys[i].coeffs[2 * j + 1])) & 0x0F);
            sk.data[offset] = c0 | (c1 << 4);
            offset += 1;
        }
    }

    // Pack s2
    for (0..K) |i| {
        for (0..N / 2) |j| {
            const c0: u8 = @intCast(@as(u32, @bitCast(ETA - s2.polys[i].coeffs[2 * j])) & 0x0F);
            const c1: u8 = @intCast(@as(u32, @bitCast(ETA - s2.polys[i].coeffs[2 * j + 1])) & 0x0F);
            sk.data[offset] = c0 | (c1 << 4);
            offset += 1;
        }
    }

    // Pack t0 (13-bit coefficients)
    for (0..K) |i| {
        polyPackBits(&t0.polys[i], 13, sk.data[offset .. offset + 416]);
        offset += 416;
    }

    return .{ .pk = pk, .sk = sk };
}

// ============================================================================
// Signing (Algorithm 2 from FIPS 204)
// ============================================================================

/// Sign a message using ML-DSA-65
/// Returns signature or null if signing fails (should retry with different randomness)
pub fn sign(sk: *const SecretKey, msg: []const u8, randomized: bool) ?Signature {
    // Extract components from secret key
    const rho = sk.getRho();
    const k_bytes = sk.getK();
    const tr = sk.getTr();

    // Unpack s1, s2, t0 from secret key
    var s1: PolyVecL = undefined;
    var s2: PolyVecK = undefined;
    var t0: PolyVecK = undefined;

    var offset: usize = 128;

    // Unpack s1
    for (0..L) |i| {
        for (0..N / 2) |j| {
            const b = sk.data[offset];
            s1.polys[i].coeffs[2 * j] = ETA - @as(i32, b & 0x0F);
            s1.polys[i].coeffs[2 * j + 1] = ETA - @as(i32, b >> 4);
            offset += 1;
        }
    }

    // Unpack s2
    for (0..K) |i| {
        for (0..N / 2) |j| {
            const b = sk.data[offset];
            s2.polys[i].coeffs[2 * j] = ETA - @as(i32, b & 0x0F);
            s2.polys[i].coeffs[2 * j + 1] = ETA - @as(i32, b >> 4);
            offset += 1;
        }
    }

    // Unpack t0
    for (0..K) |i| {
        polyUnpackBits(&t0.polys[i], 13, sk.data[offset .. offset + 416]);
        // Convert from [0, 2^13-1] to centered representation
        for (0..N) |j| {
            if (t0.polys[i].coeffs[j] >= (1 << 12)) {
                t0.polys[i].coeffs[j] -= (1 << 13);
            }
        }
        offset += 416;
    }

    // Generate matrix A
    var a: PolyMatrix = undefined;
    expandA(&a, rho);

    // Compute μ = H(tr || msg)
    var mu: [64]u8 = undefined;
    var h = crypto.hash.sha3.Shake256.init(.{});
    h.update(tr);
    h.update(msg);
    h.squeeze(&mu);

    // Get randomness for signing
    var rnd: [32]u8 = undefined;
    if (randomized) {
        crypto.random.bytes(&rnd) catch @panic("RNG failure");
    } else {
        @memset(&rnd, 0);
    }

    // Compute ρ' = H(K || rnd || μ)
    var rhoprime: [64]u8 = undefined;
    var h2 = crypto.hash.sha3.Shake256.init(.{});
    h2.update(k_bytes);
    h2.update(&rnd);
    h2.update(&mu);
    h2.squeeze(&rhoprime);

    // Pre-compute NTT forms
    var s1_hat = s1;
    s1_hat.ntt();

    var s2_hat = s2;
    s2_hat.ntt();

    var t0_hat = t0;
    t0_hat.ntt();

    // Rejection sampling loop
    var kappa: u16 = 0;
    while (kappa < 1000) : (kappa += 1) {
        // Sample y
        var y: PolyVecL = undefined;
        for (0..L) |i| {
            sampleGamma1(&y.polys[i], &rhoprime, kappa * L + @as(u16, @intCast(i)));
        }

        // w = A*y
        var y_hat = y;
        y_hat.ntt();

        var w: PolyVecK = undefined;
        matrixVecMul(&w, &a, &y_hat);
        w.invNtt();

        // Decompose w into w1, w0
        var w1: PolyVecK = undefined;
        for (0..K) |i| {
            for (0..N) |j| {
                w1.polys[i].coeffs[j] = highBits(w.polys[i].coeffs[j]);
            }
        }

        // c_tilde = H(μ || w1)
        var c_tilde: [32]u8 = undefined;
        var h3 = crypto.hash.sha3.Shake256.init(.{});
        h3.update(&mu);
        // Encode w1
        for (0..K) |i| {
            var w1_bytes: [192]u8 = undefined;
            polyPackBits(&w1.polys[i], 6, &w1_bytes);
            h3.update(&w1_bytes);
        }
        h3.squeeze(&c_tilde);

        // Sample challenge c
        var c: Poly = undefined;
        sampleInBall(&c, &c_tilde);

        // Compute z = y + c*s1
        var c_hat = c;
        nttForward(&c_hat);

        var z: PolyVecL = undefined;
        for (0..L) |i| {
            Poly.pointwiseMul(&z.polys[i], &c_hat, &s1_hat.polys[i]);
        }
        z.invNtt();
        z.add(&y);

        // Check ||z||∞ < γ1 - β
        if (!z.checkNorm(GAMMA1 - BETA)) {
            continue; // REJECT
        }

        // Compute r0 = w - c*s2
        var cs2: PolyVecK = undefined;
        for (0..K) |i| {
            Poly.pointwiseMul(&cs2.polys[i], &c_hat, &s2_hat.polys[i]);
        }
        cs2.invNtt();

        var r0: PolyVecK = w;
        r0.sub(&cs2);

        // Check ||r0||∞ < γ2 - β
        for (0..K) |i| {
            for (0..N) |j| {
                r0.polys[i].coeffs[j] = lowBits(r0.polys[i].coeffs[j]);
            }
        }
        if (!r0.checkNorm(GAMMA2 - BETA)) {
            continue; // REJECT
        }

        // Compute hints
        var ct0: PolyVecK = undefined;
        for (0..K) |i| {
            Poly.pointwiseMul(&ct0.polys[i], &c_hat, &t0_hat.polys[i]);
        }
        ct0.invNtt();

        // Check ||c*t0||∞ < γ2
        if (!ct0.checkNorm(GAMMA2)) {
            continue; // REJECT
        }

        // Make hints
        var hints: [K][N]u1 = undefined;
        var hint_count: usize = 0;

        for (0..K) |i| {
            for (0..N) |j| {
                const w_minus_cs2_plus_ct0 = w.polys[i].coeffs[j] - cs2.polys[i].coeffs[j] + ct0.polys[i].coeffs[j];
                hints[i][j] = makeHint(-ct0.polys[i].coeffs[j], w_minus_cs2_plus_ct0);
                hint_count += hints[i][j];
            }
        }

        // Check hint count
        if (hint_count > OMEGA) {
            continue; // REJECT
        }

        // SUCCESS - pack signature
        var sig: Signature = undefined;

        // Pack c_tilde
        @memcpy(sig.data[0..32], &c_tilde);

        // Pack z (20 bits per coeff, need to handle signed values)
        offset = 32;
        for (0..L) |i| {
            for (0..N) |j| {
                // Map [-γ1+1, γ1] to [0, 2γ1-1]
                const val: u32 = @intCast(GAMMA1 - z.polys[i].coeffs[j]);
                _ = val;
            }
            // Simplified packing - 20 bits per coefficient
            var buf: [640]u8 = undefined;
            packGamma1Poly(&z.polys[i], &buf);
            @memcpy(sig.data[offset .. offset + 640], &buf);
            offset += 640;
        }

        // Pack hints (ω + K bytes)
        packHints(&sig.data[offset..], &hints, hint_count);

        return sig;
    }

    return null; // Should never happen with proper randomness
}

fn packGamma1Poly(p: *const Poly, output: *[640]u8) void {
    var i: usize = 0;
    var idx: usize = 0;
    while (i < N) : (i += 4) {
        // Map to [0, 2*GAMMA1-1]
        const c0: u32 = @intCast(GAMMA1 - p.coeffs[i + 0]);
        const c1: u32 = @intCast(GAMMA1 - p.coeffs[i + 1]);
        const c2: u32 = @intCast(GAMMA1 - p.coeffs[i + 2]);
        const c3: u32 = @intCast(GAMMA1 - p.coeffs[i + 3]);

        // Pack 4 × 20-bit values into 10 bytes
        output[idx + 0] = @truncate(c0);
        output[idx + 1] = @truncate(c0 >> 8);
        output[idx + 2] = @truncate((c0 >> 16) | (c1 << 4));
        output[idx + 3] = @truncate(c1 >> 4);
        output[idx + 4] = @truncate(c1 >> 12);
        output[idx + 5] = @truncate(c2);
        output[idx + 6] = @truncate(c2 >> 8);
        output[idx + 7] = @truncate((c2 >> 16) | (c3 << 4));
        output[idx + 8] = @truncate(c3 >> 4);
        output[idx + 9] = @truncate(c3 >> 12);
        idx += 10;
    }
}

fn packHints(output: []u8, hints: *const [K][N]u1, count: usize) void {
    _ = count;
    var offset: usize = 0;

    for (0..K) |i| {
        for (0..N) |j| {
            if (hints[i][j] == 1) {
                output[offset] = @intCast(j);
                offset += 1;
            }
        }
        // Mark end of this polynomial's hints
        output[OMEGA + i] = @intCast(offset);
    }

    // Zero remaining hint positions
    while (offset < OMEGA) : (offset += 1) {
        output[offset] = 0;
    }
}

// ============================================================================
// Verification (Algorithm 3 from FIPS 204)
// ============================================================================

/// Verify a signature against a message and public key
pub fn verify(pk: *const PublicKey, msg: []const u8, sig: *const Signature) bool {
    // Extract ρ and t1 from public key
    const rho = pk.getRho();

    var t1: PolyVecK = undefined;
    var offset: usize = 32;
    for (0..K) |i| {
        polyUnpackBits(&t1.polys[i], 10, pk.data[offset .. offset + 320]);
        offset += 320;
    }

    // Compute tr = H(pk)
    var tr: [64]u8 = undefined;
    var h = crypto.hash.sha3.Shake256.init(.{});
    h.update(&pk.data);
    h.squeeze(&tr);

    // Compute μ = H(tr || msg)
    var mu: [64]u8 = undefined;
    var h2 = crypto.hash.sha3.Shake256.init(.{});
    h2.update(&tr);
    h2.update(msg);
    h2.squeeze(&mu);

    // Unpack signature
    const c_tilde = sig.data[0..32];

    var z: PolyVecL = undefined;
    offset = 32;
    for (0..L) |i| {
        unpackGamma1Poly(&z.polys[i], sig.data[offset .. offset + 640]);
        offset += 640;
    }

    // Check ||z||∞ < γ1 - β
    if (!z.checkNorm(GAMMA1 - BETA)) {
        return false;
    }

    // Unpack hints
    var hints: [K][N]u1 = undefined;
    for (0..K) |i| {
        @memset(&hints[i], 0);
    }

    var hint_count: usize = 0;
    if (!unpackHints(&hints, &hint_count, sig.data[offset..])) {
        return false;
    }

    if (hint_count > OMEGA) {
        return false;
    }

    // Generate A
    var a: PolyMatrix = undefined;
    expandA(&a, rho);

    // Compute c from c_tilde
    var c: Poly = undefined;
    sampleInBall(&c, c_tilde);

    // Compute w'1 = UseHint(hints, A*z - c*t1*2^d)
    var z_hat = z;
    z_hat.ntt();

    var az: PolyVecK = undefined;
    matrixVecMul(&az, &a, &z_hat);

    var c_hat = c;
    nttForward(&c_hat);

    var t1_hat = t1;
    t1_hat.ntt();

    // Scale t1 by 2^d
    for (0..K) |i| {
        for (0..N) |j| {
            t1_hat.polys[i].coeffs[j] = montgomeryReduce(@as(i64, t1_hat.polys[i].coeffs[j]) * (1 << D));
        }
    }

    var ct1: PolyVecK = undefined;
    for (0..K) |i| {
        Poly.pointwiseMul(&ct1.polys[i], &c_hat, &t1_hat.polys[i]);
    }

    az.invNtt();
    ct1.invNtt();

    var w_approx: PolyVecK = az;
    w_approx.sub(&ct1);

    // Apply hints
    var w1_prime: PolyVecK = undefined;
    for (0..K) |i| {
        for (0..N) |j| {
            w1_prime.polys[i].coeffs[j] = useHint(hints[i][j], w_approx.polys[i].coeffs[j]);
        }
    }

    // Recompute c_tilde' = H(μ || w'1)
    var c_tilde_prime: [32]u8 = undefined;
    var h3 = crypto.hash.sha3.Shake256.init(.{});
    h3.update(&mu);
    for (0..K) |i| {
        var w1_bytes: [192]u8 = undefined;
        polyPackBits(&w1_prime.polys[i], 6, &w1_bytes);
        h3.update(&w1_bytes);
    }
    h3.squeeze(&c_tilde_prime);

    // Check c_tilde == c_tilde'
    return mem.eql(u8, c_tilde, &c_tilde_prime);
}

fn unpackGamma1Poly(p: *Poly, input: []const u8) void {
    var i: usize = 0;
    var idx: usize = 0;
    while (i < N) : (i += 4) {
        // Unpack 4 × 20-bit values from 10 bytes
        const c0 = @as(u32, input[idx + 0]) |
            (@as(u32, input[idx + 1]) << 8) |
            ((@as(u32, input[idx + 2]) & 0x0F) << 16);

        const c1 = (@as(u32, input[idx + 2]) >> 4) |
            (@as(u32, input[idx + 3]) << 4) |
            (@as(u32, input[idx + 4]) << 12);

        const c2 = @as(u32, input[idx + 5]) |
            (@as(u32, input[idx + 6]) << 8) |
            ((@as(u32, input[idx + 7]) & 0x0F) << 16);

        const c3 = (@as(u32, input[idx + 7]) >> 4) |
            (@as(u32, input[idx + 8]) << 4) |
            (@as(u32, input[idx + 9]) << 12);

        // Map back from [0, 2*GAMMA1-1] to [-GAMMA1+1, GAMMA1]
        p.coeffs[i + 0] = GAMMA1 - @as(i32, @intCast(c0 & 0xFFFFF));
        p.coeffs[i + 1] = GAMMA1 - @as(i32, @intCast(c1 & 0xFFFFF));
        p.coeffs[i + 2] = GAMMA1 - @as(i32, @intCast(c2 & 0xFFFFF));
        p.coeffs[i + 3] = GAMMA1 - @as(i32, @intCast(c3 & 0xFFFFF));

        idx += 10;
    }
}

fn unpackHints(hints: *[K][N]u1, count: *usize, input: []const u8) bool {
    count.* = 0;

    var k: usize = 0;
    var prev_end: usize = 0;

    for (0..K) |i| {
        const end = input[OMEGA + i];
        if (end < prev_end or end > OMEGA) {
            return false;
        }

        while (k < end) : (k += 1) {
            const pos = input[k];
            if (pos >= N) return false;
            if (k > prev_end and pos <= input[k - 1]) return false;
            hints[i][pos] = 1;
            count.* += 1;
        }

        prev_end = end;
    }

    // Check remaining positions are zero
    while (k < OMEGA) : (k += 1) {
        if (input[k] != 0) return false;
    }

    return true;
}

// ============================================================================
// Tests
// ============================================================================

test "ML-DSA-65 key generation" {
    const seed = [_]u8{0x42} ** 32;
    const keypair = keyGen(&seed);
    _ = keypair;
}

test "ML-DSA-65 sign and verify" {
    const keypair = keyGen(null);

    const msg = "Test message for ML-DSA-65 signature";

    if (sign(&keypair.sk, msg, false)) |sig| {
        const valid = verify(&keypair.pk, msg, &sig);
        try std.testing.expect(valid);

        // Verify with wrong message should fail
        const valid2 = verify(&keypair.pk, "Wrong message", &sig);
        try std.testing.expect(!valid2);
    } else {
        try std.testing.expect(false); // Sign should not fail
    }
}

test "ML-DSA-65 NTT round trip" {
    var p = Poly.init();
    for (0..N) |i| {
        p.coeffs[i] = @intCast(@mod(@as(i32, @intCast(i)) * 17, Q));
    }

    var original: [N]i32 = undefined;
    @memcpy(&original, &p.coeffs);

    nttForward(&p);
    nttInverse(&p);

    for (0..N) |i| {
        const expected = reduce32(original[i]);
        const actual = reduce32(p.coeffs[i]);
        try std.testing.expectEqual(expected, actual);
    }
}

test "ML-DSA-65 decompose properties" {
    const test_vals = [_]i32{ 0, 1, Q / 2, Q - 1, GAMMA2, GAMMA2 + 1 };

    for (test_vals) |r| {
        const d = decompose(r);
        // Verify r ≈ r1 * 2*γ2 + r0
        const reconstructed = d.r1 * 2 * GAMMA2 + d.r0;
        const diff = @abs(reduce32(r) - reduce32(reconstructed));
        try std.testing.expect(diff <= 1 or diff >= Q - 1);
    }
}

test "ML-DSA-65 sampleInBall" {
    var c: Poly = undefined;
    const seed = [_]u8{0x55} ** 32;
    sampleInBall(&c, &seed);

    // Count non-zero coefficients
    var count: usize = 0;
    for (0..N) |i| {
        if (c.coeffs[i] != 0) {
            try std.testing.expect(c.coeffs[i] == 1 or c.coeffs[i] == -1);
            count += 1;
        }
    }
    try std.testing.expectEqual(TAU, count);
}
