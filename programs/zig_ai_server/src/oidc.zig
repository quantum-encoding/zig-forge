// OIDC JWT Verification — RS256 signature validation against JWKS
// Shared by Apple Sign In and Google Sign In.
//
// Proper cryptographic verification:
//   1. Fetch provider's JWKS (JSON Web Key Set) — cached 24h
//   2. Parse RSA public keys from JWK format (base64url n, e)
//   3. Verify RS256 signature: sig^e mod n → PKCS#1 v1.5 padding check
//   4. Extract and return verified claims

const std = @import("std");
const crypto = std.crypto;
const Sha256 = crypto.hash.sha2.Sha256;
const hs = @import("http-sentinel");
const HttpClient = hs.HttpClient;

// ── RSA Public Key Types ───────────────────────────────────────

const max_modulus_bits = 4096;
const Modulus = crypto.ff.Modulus(max_modulus_bits);
const Fe = Modulus.Fe;
const max_modulus_bytes = max_modulus_bits / 8;

// DigestInfo DER prefix for SHA-256 (RFC 3447 §9.2)
const sha256_digest_info = [_]u8{
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86,
    0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
    0x00, 0x04, 0x20,
};

pub const RsaPublicKey = struct {
    n: Modulus,
    modulus_len: usize,
    e_bytes: [4]u8,
    e_len: usize,
};

// ── JWKS Cache ─────────────────────────────────────────────────

const MAX_JWKS_KEYS = 8;

pub const CachedKey = struct {
    kid: [128]u8 = undefined,
    kid_len: usize = 0,
    key: RsaPublicKey = undefined,
};

pub const JwksCache = struct {
    keys: [MAX_JWKS_KEYS]CachedKey = undefined,
    count: usize = 0,
    fetched_at: i64 = 0,

    pub fn findKey(self: *const JwksCache, kid: []const u8) ?*const RsaPublicKey {
        for (self.keys[0..self.count]) |*entry| {
            if (std.mem.eql(u8, entry.kid[0..entry.kid_len], kid)) return &entry.key;
        }
        return null;
    }

    pub fn isStale(self: *const JwksCache, now_epoch: i64) bool {
        return self.count == 0 or (now_epoch - self.fetched_at > 24 * 3600);
    }
};

// ── Verified Claims ────────────────────────────────────────────

pub const VerifiedClaims = struct {
    sub: []u8,
    email: ?[]u8,
    email_verified: bool,
    exp: i64,
    nonce: ?[]u8,
    aud: ?[]u8,

    pub fn deinit(self: *VerifiedClaims, allocator: std.mem.Allocator) void {
        allocator.free(self.sub);
        if (self.email) |e| allocator.free(e);
        if (self.nonce) |n| allocator.free(n);
        if (self.aud) |a| allocator.free(a);
    }
};

// ── JWT Verification ───────────────────────────────────────────

/// Verify a JWT token's RS256 signature against a JWKS cache and extract claims.
/// Returns verified claims (caller owns, must call deinit).
/// Caller must separately validate issuer, audience, expiration, and nonce.
pub fn verifyJwt(
    allocator: std.mem.Allocator,
    token: []const u8,
    cache: *const JwksCache,
) !VerifiedClaims {
    // Split into header.payload.signature
    const first_dot = std.mem.indexOfScalar(u8, token, '.') orelse return error.InvalidToken;
    const rest = token[first_dot + 1 ..];
    const second_dot = std.mem.indexOfScalar(u8, rest, '.') orelse return error.InvalidToken;

    const header_b64 = token[0..first_dot];
    const payload_b64 = rest[0..second_dot];
    const sig_b64 = rest[second_dot + 1 ..];
    const signing_input = token[0 .. first_dot + 1 + second_dot]; // "header.payload"

    // Parse header to get kid + verify alg is RS256
    var header_buf: [512]u8 = undefined;
    const header_json = base64UrlDecodeFixed(&header_buf, header_b64) orelse return error.InvalidToken;

    const header_parsed = std.json.parseFromSlice(std.json.Value, allocator, header_json, .{}) catch
        return error.InvalidToken;
    defer header_parsed.deinit();

    if (header_parsed.value != .object) return error.InvalidToken;
    const hdr = header_parsed.value.object;

    const alg = strVal(hdr, "alg") orelse return error.InvalidToken;
    if (!std.mem.eql(u8, alg, "RS256")) return error.UnsupportedAlgorithm;

    const kid = strVal(hdr, "kid") orelse return error.InvalidToken;

    // Look up RSA public key by kid
    const key = cache.findKey(kid) orelse return error.KeyNotFound;

    // Decode signature
    var sig_buf: [max_modulus_bytes]u8 = undefined;
    const sig_bytes = base64UrlDecodeFixed(&sig_buf, sig_b64) orelse return error.InvalidToken;

    // Verify RS256 signature
    if (!verifyRS256(key, signing_input, sig_bytes)) return error.SignatureInvalid;

    // Signature valid — parse payload claims
    const payload_json = try base64UrlDecodeAlloc(allocator, payload_b64);
    defer allocator.free(payload_json);

    const payload_parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{}) catch
        return error.InvalidToken;
    defer payload_parsed.deinit();

    if (payload_parsed.value != .object) return error.InvalidToken;
    const obj = payload_parsed.value.object;

    const sub = strVal(obj, "sub") orelse return error.InvalidToken;
    if (sub.len == 0) return error.InvalidToken;

    return .{
        .sub = try allocator.dupe(u8, sub),
        .email = if (strVal(obj, "email")) |e| try allocator.dupe(u8, e) else null,
        .email_verified = boolVal(obj, "email_verified"),
        .exp = intVal(obj, "exp"),
        .nonce = if (strVal(obj, "nonce")) |n| try allocator.dupe(u8, n) else null,
        .aud = if (strVal(obj, "aud")) |a| try allocator.dupe(u8, a) else null,
    };
}

// ── RS256 Signature Verification ───────────────────────────────

fn verifyRS256(key: *const RsaPublicKey, message: []const u8, signature: []const u8) bool {
    if (signature.len != key.modulus_len) return false;

    // Compute sig^e mod n (RSA public key operation)
    const sig_fe = Fe.fromBytes(key.n, signature, .big) catch return false;
    const m_fe = key.n.powWithEncodedExponent(sig_fe, key.e_bytes[0..key.e_len], .big) catch return false;

    // Extract decrypted padded message
    var full_buf: [Fe.encoded_bytes]u8 = undefined;
    m_fe.toBytes(&full_buf, .big) catch return false;
    const em = full_buf[Fe.encoded_bytes - key.modulus_len ..];

    // Verify PKCS#1 v1.5 padding (RFC 3447 §8.2.2)
    // EM = 0x00 || 0x01 || PS (0xFF bytes, ≥8) || 0x00 || T
    // T  = DigestInfo || SHA-256(message)
    const t_len = sha256_digest_info.len + Sha256.digest_length;
    if (key.modulus_len < t_len + 11) return false;
    const ps_len = key.modulus_len - 3 - t_len;

    if (em[0] != 0x00 or em[1] != 0x01) return false;
    for (em[2 .. 2 + ps_len]) |b| {
        if (b != 0xFF) return false;
    }
    if (em[2 + ps_len] != 0x00) return false;
    if (!std.mem.eql(u8, em[2 + ps_len + 1 ..][0..sha256_digest_info.len], &sha256_digest_info)) return false;

    // Compare hash
    var expected_hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(message, &expected_hash, .{});
    return std.mem.eql(u8, em[key.modulus_len - Sha256.digest_length ..], &expected_hash);
}

// ── JWKS Fetching ──────────────────────────────────────────────

/// Fetch JWKS from a URL and parse into a cache.
pub fn fetchJwks(
    allocator: std.mem.Allocator,
    client: *HttpClient,
    url: []const u8,
    now_epoch: i64,
) !JwksCache {
    var response = client.get(url, &.{}) catch return error.JwksFetchFailed;
    defer response.deinit();

    if (response.status != .ok) return error.JwksFetchFailed;
    return parseJwks(allocator, response.body, now_epoch);
}

fn parseJwks(allocator: std.mem.Allocator, body: []const u8, now_epoch: i64) !JwksCache {
    var cache = JwksCache{ .fetched_at = now_epoch };

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return error.JwksParseError;
    defer parsed.deinit();

    if (parsed.value != .object) return error.JwksParseError;
    const root = parsed.value.object;
    const keys_val = root.get("keys") orelse return error.JwksParseError;
    const keys = if (keys_val == .array) keys_val.array.items else return error.JwksParseError;

    for (keys) |key_val| {
        if (cache.count >= MAX_JWKS_KEYS) break;
        if (key_val != .object) continue;
        const obj = key_val.object;

        // Must be RSA key
        const kty = strVal(obj, "kty") orelse continue;
        if (!std.mem.eql(u8, kty, "RSA")) continue;

        const kid = strVal(obj, "kid") orelse continue;
        const n_b64 = strVal(obj, "n") orelse continue;
        const e_b64 = strVal(obj, "e") orelse continue;

        if (kid.len > 128) continue;

        // Decode modulus (n)
        var n_buf: [max_modulus_bytes + 16]u8 = undefined;
        const n_decoded = base64UrlDecodeFixed(&n_buf, n_b64) orelse continue;
        var n_bytes: []const u8 = n_decoded;
        while (n_bytes.len > 0 and n_bytes[0] == 0) n_bytes = n_bytes[1..];
        if (n_bytes.len == 0 or n_bytes.len > max_modulus_bytes) continue;

        // Decode exponent (e)
        var e_buf: [8]u8 = undefined;
        const e_decoded = base64UrlDecodeFixed(&e_buf, e_b64) orelse continue;
        var e_bytes: []const u8 = e_decoded;
        while (e_bytes.len > 0 and e_bytes[0] == 0) e_bytes = e_bytes[1..];
        if (e_bytes.len == 0 or e_bytes.len > 4) continue;

        // Build RSA public key
        const modulus = Modulus.fromBytes(n_bytes, .big) catch continue;

        var entry = &cache.keys[cache.count];
        @memcpy(entry.kid[0..kid.len], kid);
        entry.kid_len = kid.len;
        entry.key = .{
            .n = modulus,
            .modulus_len = n_bytes.len,
            .e_bytes = .{ 0, 0, 0, 0 },
            .e_len = e_bytes.len,
        };
        @memcpy(entry.key.e_bytes[0..e_bytes.len], e_bytes);
        cache.count += 1;
    }

    if (cache.count == 0) return error.JwksNoKeys;
    return cache;
}

// ── Nonce Verification ─────────────────────────────────────────

/// Verify Apple-style nonce: SHA-256(rawNonce) hex == JWT nonce claim.
/// Returns true if valid or if nonce verification is not required (empty raw nonce).
pub fn verifyNonce(raw_nonce: ?[]const u8, token_nonce: ?[]const u8) bool {
    const nonce = raw_nonce orelse return true; // no nonce provided — skip (backward compat)
    if (nonce.len == 0) return true;

    const claim = token_nonce orelse return false; // nonce required but not in token
    if (claim.len == 0) return false;

    // SHA-256(rawNonce) → hex → compare with token claim
    var hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(nonce, &hash, .{});

    var expected: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (hash, 0..) |b, i| {
        expected[i * 2] = hex_chars[b >> 4];
        expected[i * 2 + 1] = hex_chars[b & 0x0f];
    }

    return std.mem.eql(u8, claim, &expected);
}

// ── Time ───────────────────────────────────────────────────────

/// Get epoch seconds from Io handle (wall-clock time).
pub fn epochSeconds(io: std.Io) i64 {
    const ts = io.vtable.now(io.userdata, .real);
    return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s));
}

// ── Helpers ────────────────────────────────────────────────────

fn strVal(obj: anytype, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn boolVal(obj: anytype, key: []const u8) bool {
    const v = obj.get(key) orelse return false;
    if (v == .bool) return v.bool;
    if (v == .string) return std.mem.eql(u8, v.string, "true");
    return false;
}

fn intVal(obj: anytype, key: []const u8) i64 {
    const v = obj.get(key) orelse return 0;
    return if (v == .integer) v.integer else 0;
}

/// Decode base64url into a fixed stack buffer. Returns slice or null on error.
fn base64UrlDecodeFixed(buf: []u8, input: []const u8) ?[]u8 {
    // base64url → base64: replace - → +, _ → /, add padding
    var tmp: [2048]u8 = undefined;
    if (input.len + 4 > tmp.len) return null;

    var len: usize = 0;
    for (input) |c| {
        tmp[len] = switch (c) {
            '-' => '+',
            '_' => '/',
            else => c,
        };
        len += 1;
    }
    while (len % 4 != 0) {
        tmp[len] = '=';
        len += 1;
    }

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(tmp[0..len]) catch return null;
    if (decoded_len > buf.len) return null;
    std.base64.standard.Decoder.decode(buf[0..decoded_len], tmp[0..len]) catch return null;
    return buf[0..decoded_len];
}

/// Decode base64url with heap allocation (for payloads that may exceed stack buffers).
fn base64UrlDecodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // Convert base64url → base64
    const padded_len = input.len + (4 - (input.len % 4)) % 4;
    const tmp = try allocator.alloc(u8, padded_len);
    defer allocator.free(tmp);

    var len: usize = 0;
    for (input) |c| {
        tmp[len] = switch (c) {
            '-' => '+',
            '_' => '/',
            else => c,
        };
        len += 1;
    }
    while (len % 4 != 0) {
        tmp[len] = '=';
        len += 1;
    }

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(tmp[0..len]) catch return error.InvalidToken;
    const result = try allocator.alloc(u8, decoded_len);
    std.base64.standard.Decoder.decode(result, tmp[0..len]) catch {
        allocator.free(result);
        return error.InvalidToken;
    };
    return result;
}
