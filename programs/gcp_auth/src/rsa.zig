// RSA-SHA256 signing for GCP service account JWT authentication.
// Uses std.crypto.ff for modular exponentiation — pure Zig, zero libc.

const std = @import("std");
const crypto = std.crypto;
const Sha256 = crypto.hash.sha2.Sha256;
const Certificate = crypto.Certificate;
const der = Certificate.der;

const max_modulus_bits = 4096;
const Modulus = crypto.ff.Modulus(max_modulus_bits);
const Fe = Modulus.Fe;
const max_modulus_bytes = max_modulus_bits / 8;

// DigestInfo DER prefix for SHA-256 (RFC 3447 section 9.2, note 1)
const sha256_digest_info = [_]u8{
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86,
    0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
    0x00, 0x04, 0x20,
};

pub const RsaPrivateKey = struct {
    n: Modulus,
    modulus_len: usize,
    d_bytes: []const u8,
    // Keep the DER buffer alive so d_bytes slice remains valid
    _der_buf: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *RsaPrivateKey) void {
        self.allocator.free(self._der_buf);
    }

    /// Sign a message with RSASSA-PKCS1-v1_5-SHA256.
    /// Returns the signature as an allocator-owned byte slice of modulus_len bytes.
    pub fn sign(self: *const RsaPrivateKey, message: []const u8) ![]u8 {
        // 1. SHA-256 hash
        var hash: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(message, &hash, .{});

        // 2. EMSA-PKCS1-v1_5 encoding (RFC 3447 section 9.2)
        //    EM = 0x00 || 0x01 || PS || 0x00 || T
        //    T  = DigestInfo DER prefix || hash
        const t_len = sha256_digest_info.len + Sha256.digest_length;
        if (self.modulus_len < t_len + 11) return error.ModulusTooShort;
        const ps_len = self.modulus_len - 3 - t_len;

        var em: [max_modulus_bytes]u8 = undefined;
        const pad = em[0..self.modulus_len];
        pad[0] = 0x00;
        pad[1] = 0x01;
        @memset(pad[2 .. 2 + ps_len], 0xff);
        pad[2 + ps_len] = 0x00;
        @memcpy(pad[2 + ps_len + 1 ..][0..sha256_digest_info.len], &sha256_digest_info);
        @memcpy(pad[self.modulus_len - Sha256.digest_length ..][0..Sha256.digest_length], &hash);

        // 3. RSA signature: sig = em^d mod n
        const m = Fe.fromBytes(self.n, pad, .big) catch return error.PaddingOverflow;
        const sig_fe = self.n.powWithEncodedExponent(m, self.d_bytes, .big) catch return error.NullExponent;

        const result = try self.allocator.alloc(u8, self.modulus_len);
        errdefer self.allocator.free(result);

        // Fe.toBytes needs the full Fe-width buffer, then we copy out
        var full_buf: [Fe.encoded_bytes]u8 = undefined;
        sig_fe.toBytes(&full_buf, .big) catch unreachable;
        // The signature is in the last modulus_len bytes (big-endian, leading zeros)
        @memcpy(result, full_buf[Fe.encoded_bytes - self.modulus_len ..][0..self.modulus_len]);

        return result;
    }
};

pub const ParseError = error{
    InvalidPem,
    InvalidDer,
    InvalidPkcs8,
    InvalidRsaKey,
    UnsupportedAlgorithm,
    OutOfMemory,
};

/// Parse a PEM-encoded PKCS#8 private key (as found in GCP service account JSON).
pub fn parsePrivateKeyPem(allocator: std.mem.Allocator, pem: []const u8) ParseError!RsaPrivateKey {
    const der_bytes = try decodePem(allocator, pem);
    errdefer allocator.free(der_bytes);
    return parsePkcs8Der(allocator, der_bytes);
}

/// Decode PEM to DER bytes. Strips header/footer and base64-decodes.
fn decodePem(allocator: std.mem.Allocator, pem: []const u8) ParseError![]u8 {
    const begin_marker = "-----BEGIN PRIVATE KEY-----";
    const end_marker = "-----END PRIVATE KEY-----";

    const begin_idx = std.mem.indexOf(u8, pem, begin_marker) orelse return error.InvalidPem;
    const after_begin = begin_idx + begin_marker.len;
    const end_idx = std.mem.indexOfPos(u8, pem, after_begin, end_marker) orelse return error.InvalidPem;

    // Extract base64 content, stripping whitespace/newlines
    const b64_dirty = pem[after_begin..end_idx];
    var b64_clean = allocator.alloc(u8, b64_dirty.len) catch return error.OutOfMemory;
    defer allocator.free(b64_clean);

    var clean_len: usize = 0;
    for (b64_dirty) |c| {
        if (c != '\n' and c != '\r' and c != ' ' and c != '\t') {
            b64_clean[clean_len] = c;
            clean_len += 1;
        }
    }

    const b64_input = b64_clean[0..clean_len];
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(b64_input) catch return error.InvalidPem;
    const der_bytes = allocator.alloc(u8, decoded_len) catch return error.OutOfMemory;
    errdefer allocator.free(der_bytes);

    std.base64.standard.Decoder.decode(der_bytes, b64_input) catch return error.InvalidPem;
    return der_bytes;
}

/// Parse PKCS#8 DER to extract RSA private key components.
/// PKCS#8 structure:
///   SEQUENCE {
///     INTEGER 0 (version)
///     SEQUENCE { OID rsaEncryption, NULL }
///     OCTET STRING containing RSAPrivateKey
///   }
fn parsePkcs8Der(allocator: std.mem.Allocator, der_bytes: []u8) ParseError!RsaPrivateKey {
    const bytes = der_bytes;

    // Outer SEQUENCE
    const outer_seq = der.Element.parse(bytes, 0) catch return error.InvalidDer;
    if (outer_seq.identifier.tag != .sequence) return error.InvalidPkcs8;

    // Version INTEGER (skip it)
    const version_elem = der.Element.parse(bytes, outer_seq.slice.start) catch return error.InvalidDer;
    if (version_elem.identifier.tag != .integer) return error.InvalidPkcs8;

    // Algorithm SEQUENCE (verify it's rsaEncryption, then skip)
    const algo_seq = der.Element.parse(bytes, version_elem.slice.end) catch return error.InvalidDer;
    if (algo_seq.identifier.tag != .sequence) return error.InvalidPkcs8;

    // Check OID inside algorithm sequence
    const oid_elem = der.Element.parse(bytes, algo_seq.slice.start) catch return error.InvalidDer;
    if (oid_elem.identifier.tag != .object_identifier) return error.InvalidPkcs8;
    const rsa_oid = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01 };
    const oid_bytes = bytes[oid_elem.slice.start..oid_elem.slice.end];
    if (!std.mem.eql(u8, oid_bytes, &rsa_oid)) return error.UnsupportedAlgorithm;

    // OCTET STRING containing the RSAPrivateKey
    const octet_elem = der.Element.parse(bytes, algo_seq.slice.end) catch return error.InvalidDer;
    if (octet_elem.identifier.tag != .octetstring) return error.InvalidPkcs8;

    // Parse inner RSAPrivateKey:
    //   SEQUENCE {
    //     INTEGER version,
    //     INTEGER n (modulus),
    //     INTEGER e (publicExponent),
    //     INTEGER d (privateExponent),
    //     ... (p, q, dp, dq, qinv)
    //   }
    const inner_bytes = bytes[octet_elem.slice.start..octet_elem.slice.end];
    const rsa_seq = der.Element.parse(inner_bytes, 0) catch return error.InvalidDer;
    if (rsa_seq.identifier.tag != .sequence) return error.InvalidRsaKey;

    // Skip version
    const rsa_version = der.Element.parse(inner_bytes, rsa_seq.slice.start) catch return error.InvalidDer;
    if (rsa_version.identifier.tag != .integer) return error.InvalidRsaKey;

    // Modulus (n)
    const n_elem = der.Element.parse(inner_bytes, rsa_version.slice.end) catch return error.InvalidDer;
    if (n_elem.identifier.tag != .integer) return error.InvalidRsaKey;
    var n_bytes = inner_bytes[n_elem.slice.start..n_elem.slice.end];
    // Strip leading zero byte (ASN.1 integers are signed, leading 0x00 for positive)
    while (n_bytes.len > 0 and n_bytes[0] == 0) n_bytes = n_bytes[1..];
    if (n_bytes.len == 0 or n_bytes.len > max_modulus_bytes) return error.InvalidRsaKey;

    // Public exponent (e) — skip, we don't need it for signing
    const e_elem = der.Element.parse(inner_bytes, n_elem.slice.end) catch return error.InvalidDer;
    if (e_elem.identifier.tag != .integer) return error.InvalidRsaKey;

    // Private exponent (d)
    const d_elem = der.Element.parse(inner_bytes, e_elem.slice.end) catch return error.InvalidDer;
    if (d_elem.identifier.tag != .integer) return error.InvalidRsaKey;
    var d_bytes = inner_bytes[d_elem.slice.start..d_elem.slice.end];
    while (d_bytes.len > 0 and d_bytes[0] == 0) d_bytes = d_bytes[1..];
    if (d_bytes.len == 0) return error.InvalidRsaKey;

    // Create the modulus for ff arithmetic
    const modulus = Modulus.fromBytes(n_bytes, .big) catch return error.InvalidRsaKey;

    // d_bytes is a slice into der_bytes which the caller keeps alive via _der_buf
    // But we need to compute the offset into the original der_bytes, not inner_bytes.
    // inner_bytes starts at octet_elem.slice.start within der_bytes.
    const d_start_in_der = octet_elem.slice.start + d_elem.slice.start;
    const d_end_in_der = octet_elem.slice.start + d_elem.slice.end;
    var d_in_der = der_bytes[d_start_in_der..d_end_in_der];
    while (d_in_der.len > 0 and d_in_der[0] == 0) d_in_der = d_in_der[1..];

    return RsaPrivateKey{
        .n = modulus,
        .modulus_len = n_bytes.len,
        .d_bytes = d_in_der,
        ._der_buf = der_bytes,
        .allocator = allocator,
    };
}
