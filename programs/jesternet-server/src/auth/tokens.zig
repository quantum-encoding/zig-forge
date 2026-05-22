// Token parsing + extraction + hashing.
//
// Canonical format (mirrors src/lib/api-tokens.ts in the Workers
// reference; see CONTRACT §6.3):
//
//   jnpat_jak_<8-char hex id>_<64-char hex secret>
//
//   ^^^^^   ^^^   ^^^^^^^^   ^^^^^^^^^^^^^^^^^^
//   prefix   |    public id   256-bit secret
//            └─ sub-prefix (literal; "jesternet API key")
//
// Total length: 6 + 4 + 8 + 1 + 64 = 83 characters.
//
// The SHA-256 of the WHOLE token string is stored at rest in
// the api_tokens table; verification is hash-the-input + lookup
// by hash. We never log or store the raw token.
//
// Auth flows accepted (mirrors the TypeScript reference):
//   - Authorization: Bearer <token>
//   - Authorization: Basic base64(anything:<token>)        (git smart-HTTP)
//   - URL userinfo:  https://x:<token>@host/...            (git on the wire)
//
// The Bearer path is documented; the Basic path falls out of git's
// HTTPS transport, which always sends Authorization: Basic with the
// URL's userinfo when present. Both must be accepted on /git/* routes
// so plain `git push https://jesternet.dev/git/owner/name` works.

const std = @import("std");
const http = std.http;

pub const TOKEN_PREFIX = "jnpat_";
pub const SUB_PREFIX = "jak_";
pub const ID_HEX_LEN = 8;
pub const SECRET_HEX_LEN = 64;
pub const EXPECTED_LEN =
    TOKEN_PREFIX.len + SUB_PREFIX.len + ID_HEX_LEN + 1 + SECRET_HEX_LEN;

/// True if the raw bytes are well-formed at the surface level —
/// length, prefix, hex character set in the id and secret regions.
/// Doesn't check existence in the store; that's verifyToken's job.
pub fn isWellFormed(raw: []const u8) bool {
    if (raw.len != EXPECTED_LEN) return false;
    if (!std.mem.startsWith(u8, raw, TOKEN_PREFIX ++ SUB_PREFIX)) return false;

    const id_start = TOKEN_PREFIX.len + SUB_PREFIX.len;
    const id_end = id_start + ID_HEX_LEN;
    if (!isHex(raw[id_start..id_end])) return false;

    if (raw[id_end] != '_') return false;

    const secret_start = id_end + 1;
    const secret_end = secret_start + SECRET_HEX_LEN;
    if (!isHex(raw[secret_start..secret_end])) return false;

    return true;
}

/// Extract the public token id (the 8-hex segment after `jak_`).
/// Useful for audit logging without exposing the secret. Caller must
/// have already validated via isWellFormed.
pub fn extractTokenId(raw: []const u8) []const u8 {
    const id_start = TOKEN_PREFIX.len + SUB_PREFIX.len;
    return raw[id_start .. id_start + ID_HEX_LEN];
}

/// SHA-256 hash of the WHOLE token string. This is the value the
/// store's api_tokens table indexes on; lookup is hash → row.
pub fn hashToken(raw: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raw, &hash, .{});
    return hash;
}

/// Hex-encode a 32-byte SHA-256 digest. Used when constructing
/// store lookup keys or audit log entries; the reference stores
/// the hash as a hex string in D1, so this is the wire form.
pub fn hashHex(hash: [32]u8) [64]u8 {
    const hex_chars = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (hash, 0..) |byte, i| {
        out[i * 2] = hex_chars[byte >> 4];
        out[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return out;
}

// ── Header extraction ──

/// Pull a candidate token out of an Authorization header. Tries
/// Bearer first, then Basic (git's smart-HTTP transport). Returns
/// null when no recognisable token is present. Does NOT validate
/// well-formedness; that's isWellFormed's job downstream.
pub fn extractFromRequest(request: *const http.Server.Request) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "authorization")) continue;
        const value = std.mem.trim(u8, header.value, " \t");

        if (std.ascii.startsWithIgnoreCase(value, "Bearer ")) {
            const token = std.mem.trim(u8, value["Bearer ".len..], " \t");
            if (token.len > 0) return token;
        } else if (std.ascii.startsWithIgnoreCase(value, "Basic ")) {
            const b64 = std.mem.trim(u8, value["Basic ".len..], " \t");
            return extractFromBasic(b64);
        }
    }
    return null;
}

/// Decode a Basic auth payload and return the password half. Git's
/// smart-HTTP transport sends `base64(anything:<token>)` so we
/// expect the username to be discardable. Returns null if decode
/// fails or there's no colon separator.
///
/// Caveat: this returns a slice into a STATIC scratch buffer; the
/// caller must use the result before the next call to this function.
/// In the auth pipeline we hash the slice immediately, so the
/// lifetime is bounded by one request and one thread (each
/// connection runs in its own thread per handleConnection).
threadlocal var basic_scratch: [256]u8 = undefined;

fn extractFromBasic(b64: []const u8) ?[]const u8 {
    if (b64.len == 0 or b64.len > 340) return null; // 340 base64 chars → ~255 raw

    const Decoder = std.base64.standard.Decoder;
    const decoded_len = Decoder.calcSizeForSlice(b64) catch return null;
    if (decoded_len > basic_scratch.len) return null;

    Decoder.decode(basic_scratch[0..decoded_len], b64) catch return null;
    const decoded = basic_scratch[0..decoded_len];

    const colon = std.mem.indexOfScalar(u8, decoded, ':') orelse return null;
    const password = decoded[colon + 1 ..];
    if (password.len == 0) return null;
    return password;
}

// ── Internals ──

fn isHex(s: []const u8) bool {
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!ok) return false;
    }
    return true;
}

// ── Tests ──

test "well-formed PAT (from real fixture)" {
    const raw = "jnpat_jak_d4554b81_75abc1dfa1c5245b783012a05fdcd712226201baac2e6556b92eaf6a86dd1778";
    try std.testing.expect(isWellFormed(raw));
    try std.testing.expectEqual(@as(usize, EXPECTED_LEN), raw.len);
    try std.testing.expectEqualStrings("d4554b81", extractTokenId(raw));
}

test "well-formedness rejects bad inputs" {
    try std.testing.expect(!isWellFormed("")); // empty
    try std.testing.expect(!isWellFormed("notatoken")); // no prefix
    try std.testing.expect(!isWellFormed("jnpat_d4554b81_75abc1dfa1c5245b783012a05fdcd712226201baac2e6556b92eaf6a86dd1778")); // missing jak_
    try std.testing.expect(!isWellFormed("jnpat_jak_GGGGGGGG_75abc1dfa1c5245b783012a05fdcd712226201baac2e6556b92eaf6a86dd1778")); // non-hex id
    try std.testing.expect(!isWellFormed("jnpat_jak_d4554b81-75abc1dfa1c5245b783012a05fdcd712226201baac2e6556b92eaf6a86dd1778")); // wrong separator
    try std.testing.expect(!isWellFormed("jnpat_jak_d4554b81_75abc1dfa1c5245b783012a05fdcd712226201baac2e6556b92eaf6a86dd1778_extra")); // too long
    try std.testing.expect(!isWellFormed("jnpat_jak_d4554b81_75abc")); // too short
}

test "hashing is deterministic" {
    const raw = "jnpat_jak_d4554b81_75abc1dfa1c5245b783012a05fdcd712226201baac2e6556b92eaf6a86dd1778";
    const h1 = hashToken(raw);
    const h2 = hashToken(raw);
    try std.testing.expectEqualSlices(u8, &h1, &h2);

    // Different raw → different hash.
    const other = "jnpat_jak_d4554b82_75abc1dfa1c5245b783012a05fdcd712226201baac2e6556b92eaf6a86dd1778";
    const h3 = hashToken(other);
    try std.testing.expect(!std.mem.eql(u8, &h1, &h3));
}

test "hashHex produces 64 lowercase hex chars" {
    const raw = "jnpat_jak_d4554b81_75abc1dfa1c5245b783012a05fdcd712226201baac2e6556b92eaf6a86dd1778";
    const hex = hashHex(hashToken(raw));
    try std.testing.expectEqual(@as(usize, 64), hex.len);
    for (hex) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(ok);
    }
}

test "extractFromBasic recovers the token from git smart-HTTP form" {
    // git pushes `Authorization: Basic base64("x:" + token)`.
    const raw_token = "jnpat_jak_d4554b81_75abc1dfa1c5245b783012a05fdcd712226201baac2e6556b92eaf6a86dd1778";
    const user_colon_token = "x:" ++ raw_token;

    const Encoder = std.base64.standard.Encoder;
    var buf: [200]u8 = undefined;
    const encoded = Encoder.encode(&buf, user_colon_token);

    const extracted = extractFromBasic(encoded) orelse return error.NoTokenExtracted;
    try std.testing.expectEqualStrings(raw_token, extracted);
}

test "extractFromBasic rejects malformed input" {
    try std.testing.expect(extractFromBasic("") == null);
    try std.testing.expect(extractFromBasic("not-base64!@#") == null);
    // base64 of "no-colon-here" — well-formed base64 but no separator
    const Encoder = std.base64.standard.Encoder;
    var buf: [50]u8 = undefined;
    const encoded = Encoder.encode(&buf, "no-colon-here");
    try std.testing.expect(extractFromBasic(encoded) == null);
}
