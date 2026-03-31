//! ML-KEM High-Level API
//! 
//! This module provides the main ML-KEM functions:
//! - KeyGen: Generate encapsulation/decapsulation key pair
//! - Encaps: Encapsulate a shared secret
//! - Decaps: Decapsulate to recover the shared secret
//!
//! These implement Algorithms 19, 20, 21 from FIPS 203

const std = @import("std");
const crypto = std.crypto;
const ntt = @import("ml_kem.zig");
const rng = @import("rng.zig");

// Cross-platform secure RNG
const getRandomBytes = rng.fillSecureRandom;

const Poly = ntt.Poly;
const Params = ntt.Params;
const ML_KEM_768 = ntt.ML_KEM_768;
const N = ntt.N;
const Q = ntt.Q;

// ============================================================================
// Key Types
// ============================================================================

/// ML-KEM-768 Encapsulation Key (public)
/// Size: 1184 bytes (384*k + 32 = 384*3 + 32)
pub const EncapsulationKey768 = struct {
    data: [1184]u8,

    /// Extract the public seed ρ (last 32 bytes)
    pub fn getSeed(self: *const EncapsulationKey768) *const [32]u8 {
        return self.data[1152..1184];
    }
};

/// ML-KEM-768 Decapsulation Key (private)
/// Size: 2400 bytes (768*k + 96 = 768*3 + 96)
pub const DecapsulationKey768 = struct {
    data: [2400]u8,

    /// The decapsulation key contains:
    /// - s_hat: secret vector in NTT form (384*k bytes)
    /// - ek: encapsulation key (384*k + 32 bytes)  
    /// - H(ek): hash of encapsulation key (32 bytes)
    /// - z: implicit rejection seed (32 bytes)

    pub fn getSecretVector(self: *const DecapsulationKey768) []const u8 {
        return self.data[0..1152]; // 384 * 3
    }

    pub fn getEncapsulationKey(self: *const DecapsulationKey768) *const EncapsulationKey768 {
        return @ptrCast(self.data[1152..2336]);
    }

    pub fn getHashEk(self: *const DecapsulationKey768) *const [32]u8 {
        return self.data[2336..2368];
    }

    pub fn getZ(self: *const DecapsulationKey768) *const [32]u8 {
        return self.data[2368..2400];
    }
};

/// ML-KEM-768 Ciphertext
/// Size: 1088 bytes
pub const Ciphertext768 = struct {
    data: [1088]u8,
};

/// Shared secret key (256 bits)
pub const SharedSecret = [32]u8;

/// Key pair result type
pub const KeyPair768 = struct { ek: EncapsulationKey768, dk: DecapsulationKey768 };

/// Encapsulation result type
pub const EncapsResult768 = struct { K: SharedSecret, c: Ciphertext768 };

// ============================================================================
// Error Types
// ============================================================================

pub const MlKemError = error{
    /// Random number generation failed
    RandomnessFailure,
    /// Invalid encapsulation key format
    InvalidEncapsulationKey,
    /// Invalid ciphertext format
    InvalidCiphertext,
    /// Decapsulation failure (implicit rejection triggered)
    DecapsulationFailure,
};

// ============================================================================
// ML-KEM.KeyGen (Algorithm 19)
// ============================================================================

/// Generate an ML-KEM-768 key pair
///
/// This function generates a fresh encapsulation key (public) and 
/// decapsulation key (private) using cryptographically secure randomness.
///
/// Returns: (ek, dk) key pair, or error if RNG fails
pub fn keyGen768() MlKemError!KeyPair768 {
    // Step 1-2: Generate random seeds d and z
    var d: [32]u8 = undefined;
    var z: [32]u8 = undefined;

    getRandomBytes(&d);
    getRandomBytes(&z);

    // Call internal key generation
    return keyGenInternal768(&d, &z);
}

/// ML-KEM.KeyGen_internal (Algorithm 16)
/// Deterministic key generation from seeds d and z
fn keyGenInternal768(d: *const [32]u8, z: *const [32]u8) MlKemError!KeyPair768 {
    var ek: EncapsulationKey768 = undefined;
    var dk: DecapsulationKey768 = undefined;

    // Step 1: (ρ, σ) ← G(d)
    const g_result = ntt.hashG(d);
    const rho = g_result.a; // public seed for A
    const sigma = g_result.b; // secret seed for s, e

    // Steps 2-7: Generate matrix A from ρ
    // A is a k×k matrix of polynomials in NTT form
    // For ML-KEM-768, k = 3
    var a_hat: [3][3]Poly = undefined;
    for (0..3) |i| {
        for (0..3) |j| {
            a_hat[i][j] = sampleNTT(&rho, @intCast(j), @intCast(i));
        }
    }

    // Steps 8-11: Sample secret vector s and error vector e
    var s: [3]Poly = undefined;
    var e: [3]Poly = undefined;
    var nonce: u8 = 0;

    for (0..3) |i| {
        var prf_output: [128]u8 = undefined; // 64 * eta1 = 64 * 2
        ntt.prf(2, &sigma, nonce, &prf_output);
        s[i] = samplePolyCBD2(&prf_output);
        nonce += 1;
    }

    for (0..3) |i| {
        var prf_output: [128]u8 = undefined;
        ntt.prf(2, &sigma, nonce, &prf_output);
        e[i] = samplePolyCBD2(&prf_output);
        nonce += 1;
    }

    // Step 12: Convert s to NTT form
    var s_hat: [3]Poly = undefined;
    for (0..3) |i| {
        s_hat[i] = s[i];
        ntt.ntt(&s_hat[i]);
    }

    // Step 13: Convert e to NTT form
    var e_hat: [3]Poly = undefined;
    for (0..3) |i| {
        e_hat[i] = e[i];
        ntt.ntt(&e_hat[i]);
    }

    // Step 14: t_hat = A ∘ s_hat + e_hat
    var t_hat: [3]Poly = undefined;
    for (0..3) |i| {
        t_hat[i] = Poly.init();
        for (0..3) |j| {
            var product: Poly = undefined;
            ntt.multiplyNTTs(&a_hat[i][j], &s_hat[j], &product);
            t_hat[i].add(&product);
        }
        t_hat[i].add(&e_hat[i]);
    }

    // Step 15: Encode encapsulation key
    // ek = ByteEncode_12(t_hat) || ρ
    var offset: usize = 0;
    for (0..3) |i| {
        ntt.byteEncode(12, &t_hat[i].coeffs, ek.data[offset..][0..384]);
        offset += 384;
    }
    @memcpy(ek.data[1152..1184], &rho);

    // Step 16-17: Encode decapsulation key
    // dk = ByteEncode_12(s_hat) || ek || H(ek) || z
    offset = 0;
    for (0..3) |i| {
        ntt.byteEncode(12, &s_hat[i].coeffs, dk.data[offset..][0..384]);
        offset += 384;
    }

    // Copy encapsulation key
    @memcpy(dk.data[1152..2336], &ek.data);

    // H(ek)
    const h_ek = ntt.hashH(&ek.data);
    @memcpy(dk.data[2336..2368], &h_ek);

    // z (implicit rejection seed)
    @memcpy(dk.data[2368..2400], z);

    return .{ .ek = ek, .dk = dk };
}

// ============================================================================
// ML-KEM.Encaps (Algorithm 20)
// ============================================================================

/// Encapsulate a shared secret using the given encapsulation key
///
/// This function generates a shared secret and corresponding ciphertext.
/// Only the holder of the decapsulation key can recover the shared secret.
///
/// Returns: (K, c) where K is the shared secret and c is the ciphertext
pub fn encaps768(ek: *const EncapsulationKey768) MlKemError!EncapsResult768 {
    // Step 1: Input validation - check that all coefficients decode to valid values
    if (!validateEncapsulationKey768(ek)) {
        return MlKemError.InvalidEncapsulationKey;
    }

    // Step 2: Generate random message m
    var m: [32]u8 = undefined;
    getRandomBytes(&m);

    // Call internal encapsulation
    return encapsInternal768(ek, &m);
}

/// ML-KEM.Encaps_internal (Algorithm 17)
/// Deterministic encapsulation from message m
fn encapsInternal768(ek: *const EncapsulationKey768, m: *const [32]u8) MlKemError!EncapsResult768 {
    // Step 1: (K, r) ← G(m || H(ek))
    var g_input: [64]u8 = undefined;
    @memcpy(g_input[0..32], m);
    const h_ek = ntt.hashH(&ek.data);
    @memcpy(g_input[32..64], &h_ek);

    const g_result = ntt.hashG(&g_input);
    const K = g_result.a; // Shared secret
    const r = g_result.b; // Randomness for encryption

    // Steps 2-9: K-PKE.Encrypt(ek, m, r)
    const c = kpkeEncrypt768(ek, m, &r);

    return .{ .K = K, .c = c };
}

/// Validate encapsulation key format
fn validateEncapsulationKey768(ek: *const EncapsulationKey768) bool {
    // Decode each polynomial and verify coefficients are < q
    for (0..3) |i| {
        var coeffs: [N]i16 = undefined;
        ntt.byteDecode(12, ek.data[i * 384 ..][0..384], &coeffs);

        // Re-encode and compare (ModulusCheck from FIPS 203)
        var reencoded: [384]u8 = undefined;
        ntt.byteEncode(12, &coeffs, &reencoded);

        if (!std.mem.eql(u8, ek.data[i * 384 ..][0..384], &reencoded)) {
            return false;
        }
    }
    return true;
}

// ============================================================================
// ML-KEM.Decaps (Algorithm 21)
// ============================================================================

/// Decapsulate a ciphertext to recover the shared secret
///
/// This function uses the decapsulation key to recover the shared secret
/// from a ciphertext. If the ciphertext is invalid (possibly tampered),
/// implicit rejection returns a pseudorandom value derived from z.
///
/// Returns: K (shared secret)
pub fn decaps768(dk: *const DecapsulationKey768, c: *const Ciphertext768) SharedSecret {
    // Step 1: Extract components from decapsulation key
    const s_hat_bytes = dk.getSecretVector();
    const ek = dk.getEncapsulationKey();
    const h_ek = dk.getHashEk();
    const z = dk.getZ();

    // Step 2: Decrypt to get m'
    const m_prime = kpkeDecrypt768(s_hat_bytes, c);

    // Step 3: (K', r') ← G(m' || H(ek))
    var g_input: [64]u8 = undefined;
    @memcpy(g_input[0..32], &m_prime);
    @memcpy(g_input[32..64], h_ek);

    const g_result = ntt.hashG(&g_input);
    const k_prime = g_result.a;
    const r_prime = g_result.b;

    // Step 4: K_bar ← J(z || c)
    var j_input: [32 + 1088]u8 = undefined;
    @memcpy(j_input[0..32], z);
    @memcpy(j_input[32..], &c.data);
    const k_bar = ntt.hashJ(&j_input);

    // Step 5: Re-encrypt with r' to get c'
    const c_prime = kpkeEncrypt768(ek, &m_prime, &r_prime);

    // Step 6: Constant-time comparison
    // If c == c', return K', else return K_bar (implicit rejection)
    const equal = constantTimeCompare(&c.data, &c_prime.data);

    // Constant-time select
    var K: SharedSecret = undefined;
    for (0..32) |i| {
        K[i] = constantTimeSelect(equal, k_prime[i], k_bar[i]);
    }

    return K;
}

// ============================================================================
// K-PKE Component Scheme (Section 5)
// ============================================================================

/// K-PKE.Encrypt (Algorithm 14)
fn kpkeEncrypt768(ek: *const EncapsulationKey768, m: *const [32]u8, r: *const [32]u8) Ciphertext768 {
    var c: Ciphertext768 = undefined;

    // Decode t_hat from encapsulation key
    var t_hat: [3]Poly = undefined;
    for (0..3) |i| {
        ntt.byteDecode(12, ek.data[i * 384 ..][0..384], &t_hat[i].coeffs);
    }

    // Extract ρ
    const rho = ek.getSeed();

    // Regenerate A_hat from ρ
    var a_hat: [3][3]Poly = undefined;
    for (0..3) |i| {
        for (0..3) |j| {
            a_hat[i][j] = sampleNTT(rho, @intCast(j), @intCast(i));
        }
    }

    // Sample r, e1, e2 using randomness r
    var rv: [3]Poly = undefined;
    var e1: [3]Poly = undefined;
    var e2: Poly = undefined;
    var nonce: u8 = 0;

    for (0..3) |i| {
        var prf_output: [128]u8 = undefined;
        ntt.prf(2, r, nonce, &prf_output);
        rv[i] = samplePolyCBD2(&prf_output);
        nonce += 1;
    }

    for (0..3) |i| {
        var prf_output: [128]u8 = undefined;
        ntt.prf(2, r, nonce, &prf_output);
        e1[i] = samplePolyCBD2(&prf_output);
        nonce += 1;
    }

    {
        var prf_output: [128]u8 = undefined;
        ntt.prf(2, r, nonce, &prf_output);
        e2 = samplePolyCBD2(&prf_output);
    }

    // Convert r to NTT form
    var r_hat: [3]Poly = undefined;
    for (0..3) |i| {
        r_hat[i] = rv[i];
        ntt.ntt(&r_hat[i]);
    }

    // u = NTT^-1(A^T ∘ r_hat) + e1
    var u: [3]Poly = undefined;
    for (0..3) |i| {
        u[i] = Poly.init();
        for (0..3) |j| {
            var product: Poly = undefined;
            ntt.multiplyNTTs(&a_hat[j][i], &r_hat[j], &product);
            u[i].add(&product);
        }
        ntt.nttInverse(&u[i]);
        u[i].add(&e1[i]);
    }

    // v = NTT^-1(t_hat^T ∘ r_hat) + e2 + Decompress_1(m)
    var v: Poly = Poly.init();
    for (0..3) |i| {
        var product: Poly = undefined;
        ntt.multiplyNTTs(&t_hat[i], &r_hat[i], &product);
        v.add(&product);
    }
    ntt.nttInverse(&v);
    v.add(&e2);

    // Add decompressed message
    var m_poly: Poly = undefined;
    decompressMessage(m, &m_poly);
    v.add(&m_poly);

    // Encode ciphertext
    var offset: usize = 0;
    for (0..3) |i| {
        compressAndEncode(&u[i], 10, c.data[offset..][0..320]);
        offset += 320;
    }
    compressAndEncode(&v, 4, c.data[960..][0..128]);

    return c;
}

/// K-PKE.Decrypt (Algorithm 15)
fn kpkeDecrypt768(s_hat_bytes: []const u8, c: *const Ciphertext768) [32]u8 {
    // Decode s_hat
    var s_hat: [3]Poly = undefined;
    for (0..3) |i| {
        ntt.byteDecode(12, s_hat_bytes[i * 384 ..][0..384], &s_hat[i].coeffs);
    }

    // Decode u from ciphertext
    var u: [3]Poly = undefined;
    for (0..3) |i| {
        decodeAndDecompress(c.data[i * 320 ..][0..320], 10, &u[i]);
    }

    // Decode v from ciphertext
    var v: Poly = undefined;
    decodeAndDecompress(c.data[960..][0..128], 4, &v);

    // Convert u to NTT form
    var u_hat: [3]Poly = undefined;
    for (0..3) |i| {
        u_hat[i] = u[i];
        ntt.ntt(&u_hat[i]);
    }

    // w = v - NTT^-1(s_hat^T ∘ u_hat)
    var w: Poly = v;
    var inner_product: Poly = Poly.init();
    for (0..3) |i| {
        var product: Poly = undefined;
        ntt.multiplyNTTs(&s_hat[i], &u_hat[i], &product);
        inner_product.add(&product);
    }
    ntt.nttInverse(&inner_product);
    w.sub(&inner_product);

    // Compress w to get message
    var m: [32]u8 = undefined;
    compressMessage(&w, &m);

    return m;
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Sample polynomial from NTT domain using XOF
fn sampleNTT(seed: *const [32]u8, i: u8, j: u8) Poly {
    var result: Poly = undefined;

    // XOF input: seed || i || j
    var xof_input: [34]u8 = undefined;
    @memcpy(xof_input[0..32], seed);
    xof_input[32] = i;
    xof_input[33] = j;

    // Use SHAKE128 to generate coefficients
    var xof = crypto.hash.sha3.Shake128.init(.{});
    xof.update(&xof_input);

    var idx: usize = 0;
    while (idx < N) {
        var buf: [3]u8 = undefined;
        xof.squeeze(&buf);

        const d1: u16 = @as(u16, buf[0]) + (@as(u16, buf[1] & 0x0F) << 8);
        const d2: u16 = (@as(u16, buf[1]) >> 4) + (@as(u16, buf[2]) << 4);

        if (d1 < Q) {
            result.coeffs[idx] = @intCast(d1);
            idx += 1;
        }
        if (d2 < Q and idx < N) {
            result.coeffs[idx] = @intCast(d2);
            idx += 1;
        }
    }

    return result;
}

/// Sample polynomial from centered binomial distribution (eta=2)
fn samplePolyCBD2(bytes: *const [128]u8) Poly {
    var result: Poly = undefined;

    for (0..N) |i| {
        const byte_idx = i / 2;
        const bit_offset: u3 = @intCast((i % 2) * 4);

        const nibble = (bytes[byte_idx] >> bit_offset) & 0x0F;

        // CBD_2: sum of 2 bits - sum of 2 bits
        const a: i16 = @as(i16, nibble & 1) + @as(i16, (nibble >> 1) & 1);
        const b: i16 = @as(i16, (nibble >> 2) & 1) + @as(i16, (nibble >> 3) & 1);

        result.coeffs[i] = ntt.barrettReduce(a - b);
    }

    return result;
}

/// Decompress 32-byte message to polynomial
fn decompressMessage(m: *const [32]u8, result: *Poly) void {
    for (0..N) |i| {
        const byte_idx = i / 8;
        const bit_idx: u3 = @intCast(i % 8);
        const bit = (m[byte_idx] >> bit_idx) & 1;

        // Decompress_1: 0 -> 0, 1 -> (q+1)/2 ≈ 1665
        result.coeffs[i] = if (bit == 1) 1665 else 0;
    }
}

/// Compress polynomial to 32-byte message
fn compressMessage(poly: *const Poly, m: *[32]u8) void {
    @memset(m, 0);

    for (0..N) |i| {
        // Compress_1: round(2x/q) mod 2
        const x: u32 = @intCast(@mod(@as(i32, poly.coeffs[i]), Q));
        const bit: u8 = @intCast(((x << 1) + @as(u32, @intCast(Q)) / 2) / @as(u32, @intCast(Q)) & 1);

        const byte_idx = i / 8;
        const bit_idx: u3 = @intCast(i % 8);
        m[byte_idx] |= bit << bit_idx;
    }
}

/// Compress polynomial and encode to bytes
fn compressAndEncode(poly: *const Poly, comptime d: comptime_int, output: []u8) void {
    var compressed: [N]i16 = undefined;
    for (0..N) |i| {
        compressed[i] = @intCast(ntt.compress(poly.coeffs[i], d));
    }
    ntt.byteEncode(d, &compressed, output[0 .. 32 * d]);
}

/// Decode bytes and decompress to polynomial
fn decodeAndDecompress(input: []const u8, comptime d: comptime_int, result: *Poly) void {
    var decoded: [N]i16 = undefined;
    ntt.byteDecode(d, input[0 .. 32 * d], &decoded);

    for (0..N) |i| {
        result.coeffs[i] = ntt.decompress(@intCast(decoded[i]), d);
    }
}

/// Constant-time comparison of two byte arrays
fn constantTimeCompare(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;

    var diff: u8 = 0;
    for (a, b) |x, y| {
        diff |= x ^ y;
    }
    return diff == 0;
}

/// Constant-time select: returns a if condition is true, b otherwise
fn constantTimeSelect(condition: bool, a: u8, b: u8) u8 {
    const mask = @as(u8, 0) -% @intFromBool(condition);
    return (mask & a) | (~mask & b);
}

// ============================================================================
// Tests
// ============================================================================

test "ML-KEM-768 key generation" {
    const result = try keyGen768();
    _ = result.ek;
    _ = result.dk;
}

test "ML-KEM-768 encapsulation" {
    const keypair = try keyGen768();
    const encaps_result = try encaps768(&keypair.ek);
    _ = encaps_result.K;
    _ = encaps_result.c;
}

test "ML-KEM-768 round trip" {
    // Generate key pair
    const keypair = try keyGen768();

    // Encapsulate
    const encaps_result = try encaps768(&keypair.ek);

    // Decapsulate
    const K_decaps = decaps768(&keypair.dk, &encaps_result.c);

    // Shared secrets should match
    try std.testing.expectEqualSlices(u8, &encaps_result.K, &K_decaps);
}
