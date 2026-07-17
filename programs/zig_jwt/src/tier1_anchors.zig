//! Tier-1 externally-anchored test vectors for zig_jwt.
//!
//! Per zig-forge/CLAUDE.md golden rule §1, a money/key/auth library
//! must have tests whose inputs AND expected outputs both come from a
//! source the library author did not write. The 24 inline tests in
//! `jwt.zig` are high-quality but every one of them is self-generated
//! (mint with `Builder.sign`, verify with `Verifier.verify`) — a
//! self-consistent HMAC-input or base64url bug would pass all of them.
//! (This is the exact zig_base58 failure mode: 15/15 roundtrips green
//! while the on-wire output was wrong.)
//!
//! The vectors below are anchored to two sources external to this repo:
//!
//!   1. RFC 7515 Appendix A.1 — the JWS spec's worked HS256 example:
//!      the exact JWK octet key, the exact compact serialization, and
//!      the exact base64url signature `dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk`.
//!      https://www.rfc-editor.org/rfc/rfc7515#appendix-A.1
//!
//!   2. jwt.io's canonical HS256 debugger default token, the most
//!      widely-published cross-implementation JWT fixture:
//!      header {"alg":"HS256","typ":"JWT"}, payload
//!      {"sub":"1234567890","name":"John Doe","iat":1516239022},
//!      secret "your-256-bit-secret", signature
//!      `SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c`.
//!      HS384/HS512 golden tokens over the same header/payload/secret
//!      are the RFC 4231-family HMAC of that fixed input — reproducible
//!      by any conforming JWT library (PyJWT, jsonwebtoken, jose).
//!
//! A green `verify()` on these tokens exercises the library's HMAC
//! recomputation + constant-time compare + base64url DECODE against
//! bytes it did not produce; the base64url-ENCODE assertion pins the
//! other direction against the RFC's published segment.

const std = @import("std");
const jwt = @import("jwt.zig");

// ── RFC 7515 Appendix A.1 ───────────────────────────────────────────

// The 64-octet HMAC key, given in A.1 as a JSON array of bytes.
const rfc7515_a1_key = [_]u8{
    3,   35,  53,  75,  43,  15,  165, 188, 131, 126, 6,   101, 119, 123, 166,
    143, 90,  179, 40,  230, 240, 84,  201, 40,  169, 15,  132, 178, 210, 80,
    46,  191, 211, 251, 90,  146, 210, 6,   71,  239, 150, 138, 180, 195, 119,
    98,  61,  34,  61,  46,  33,  114, 5,   46,  79,  8,   192, 205, 154, 245,
    103, 208, 128, 163,
};

// The exact compact JWS from A.1 (note the CR/LF and spaces inside the
// header and payload JSON are part of the signed material).
const rfc7515_a1_token =
    "eyJ0eXAiOiJKV1QiLA0KICJhbGciOiJIUzI1NiJ9" ++
    "." ++
    "eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQog" ++
    "Imh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ" ++
    "." ++
    "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";

test "RFC 7515 A.1: HS256 example token verifies with the spec's JWK octet key" {
    const allocator = std.testing.allocator;

    var verifier = jwt.Verifier.init(allocator);
    defer verifier.deinit();
    // exp = 1300819380 (2011) is long past; A.1 is a signature example,
    // not a liveness example. validate_exp is a public field.
    verifier.validate_exp = false;

    var claims = try verifier.verify(rfc7515_a1_token, .HS256, &rfc7515_a1_key);
    defer claims.deinit();

    // iss "joe" is an RFC-published claim value, not one we minted.
    try std.testing.expectEqualStrings("joe", claims.iss.?);
    try std.testing.expectEqual(@as(i64, 1300819380), claims.exp.?);
}

test "RFC 7515 A.1: a one-bit key change is rejected (HMAC recompute is real)" {
    const allocator = std.testing.allocator;

    var wrong_key = rfc7515_a1_key;
    wrong_key[0] ^= 0x01;

    var verifier = jwt.Verifier.init(allocator);
    defer verifier.deinit();
    verifier.validate_exp = false;

    try std.testing.expectError(
        jwt.Error.InvalidSignature,
        verifier.verify(rfc7515_a1_token, .HS256, &wrong_key),
    );
}

test "RFC 7515 A.1: base64url ENCODE matches the spec's published header segment" {
    const allocator = std.testing.allocator;

    // A.1 header octets decode to this exact byte string (CRLF + space).
    const header_bytes = "{\"typ\":\"JWT\",\r\n \"alg\":\"HS256\"}";
    const encoded = try jwt.base64UrlEncode(allocator, header_bytes);
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("eyJ0eXAiOiJKV1QiLA0KICJhbGciOiJIUzI1NiJ9", encoded);
}

// ── jwt.io canonical cross-implementation vectors ───────────────────

const jwtio_secret = "your-256-bit-secret";

const jwtio_hs256 =
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" ++
    ".eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ" ++
    ".SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";

const jwtio_hs384 =
    "eyJhbGciOiJIUzM4NCIsInR5cCI6IkpXVCJ9" ++
    ".eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ" ++
    ".RGFdh_VuEuURSubru7xP4rbaA4boUyueI7rEm75l1cNdE9gQ7H6mx2DYpauBjX5S";

const jwtio_hs512 =
    "eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9" ++
    ".eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ" ++
    ".pazba9Pj009HgANP4pTCQAHpXNU7pVbjIGff_plktSzsa9rXTGzFngaawzXGEO6Q0Hx5dtGi-dMDlIadV81o3Q";

fn expectCrossImplVerifies(comptime token: []const u8, alg: jwt.Algorithm) !void {
    const allocator = std.testing.allocator;
    var verifier = jwt.Verifier.init(allocator);
    defer verifier.deinit();
    var claims = try verifier.verify(token, alg, jwtio_secret);
    defer claims.deinit();
    try std.testing.expectEqualStrings("1234567890", claims.sub.?);
    try std.testing.expectEqual(@as(i64, 1516239022), claims.iat.?);
}

test "cross-impl: jwt.io canonical HS256 token verifies" {
    try expectCrossImplVerifies(jwtio_hs256, .HS256);
}

test "cross-impl: HS384 golden token over the same fixture verifies" {
    try expectCrossImplVerifies(jwtio_hs384, .HS384);
}

test "cross-impl: HS512 golden token over the same fixture verifies" {
    try expectCrossImplVerifies(jwtio_hs512, .HS512);
}

test "cross-impl: HS256 token under the wrong secret is rejected" {
    const allocator = std.testing.allocator;
    var verifier = jwt.Verifier.init(allocator);
    defer verifier.deinit();
    try std.testing.expectError(
        jwt.Error.InvalidSignature,
        verifier.verify(jwtio_hs256, .HS256, "not-the-secret"),
    );
}

test "cross-impl: HS256 token presented as HS384 is rejected (alg confusion)" {
    const allocator = std.testing.allocator;
    var verifier = jwt.Verifier.init(allocator);
    defer verifier.deinit();
    // Header declares HS256; asking the verifier for HS384 must fail
    // the enum-compare, not silently recompute under a different alg.
    try std.testing.expectError(
        jwt.Error.InvalidAlgorithm,
        verifier.verify(jwtio_hs256, .HS384, jwtio_secret),
    );
}

// ── Claim-smuggling guard (Tier 1B upgrade #2) ──────────────────────

test "collision guard: custom claim colliding with a registered claim is refused at sign time" {
    const allocator = std.testing.allocator;

    var builder = jwt.Builder.init(allocator);
    defer builder.deinit();

    try builder.setSubject("real");
    builder.setExpiration(1300819380);
    // Attacker-influenced custom text tries to smuggle a second `sub`.
    try builder.setCustomClaims("\"sub\":\"admin\"");

    // Previously this emitted a signed payload with two `sub` keys
    // ("real" then "admin") that a last-wins downstream verifier reads
    // as sub=admin. The Builder must now refuse to mint it.
    try std.testing.expectError(
        jwt.Error.InvalidPayload,
        builder.sign(.HS256, "secret-key"),
    );
}

test "collision guard: each registered claim name is rejected as a custom key" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "iss", "sub", "aud", "exp", "nbf", "iat", "jti" };
    inline for (names) |name| {
        var builder = jwt.Builder.init(allocator);
        defer builder.deinit();
        try builder.setSubject("real");
        try builder.setCustomClaims("\"" ++ name ++ "\":\"x\"");
        try std.testing.expectError(
            jwt.Error.InvalidPayload,
            builder.sign(.HS256, "secret-key"),
        );
    }
}

test "collision guard: a genuinely-custom claim still signs and round-trips" {
    const allocator = std.testing.allocator;

    var builder = jwt.Builder.init(allocator);
    defer builder.deinit();
    try builder.setSubject("real");
    builder.setExpiration(32503680000); // far future (year 3000)
    try builder.setCustomClaims("\"role\":\"admin\"");

    const token = try builder.sign(.HS256, "secret-key");
    defer allocator.free(token);

    var verifier = jwt.Verifier.init(allocator);
    defer verifier.deinit();
    var claims = try verifier.verify(token, .HS256, "secret-key");
    defer claims.deinit();
    try std.testing.expectEqualStrings("real", claims.sub.?);
    // The non-colliding custom claim is preserved in the raw payload.
    try std.testing.expect(std.mem.indexOf(u8, claims.custom.?, "\"role\":\"admin\"") != null);
}
