const std = @import("std");
const gcp = @import("gcp-auth");
const rsa = gcp.rsa;
const jwt = gcp.jwt;

// ============================================================================
// PEM / DER parsing tests
// ============================================================================

// Minimal 512-bit RSA test key (PKCS#8 PEM) — NOT for production use.
// Generated with: openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:512
const test_pem_512 =
    "-----BEGIN PRIVATE KEY-----\n" ++
    "MIIBUwIBADANBgkqhkiG9w0BAQEFAASCAT0wggE5AgEAAkEAuJ53eeivJJ7a21Ju\n" ++
    "8Zj8BdGR/g0Q3GakWDg6DXcmR+7lFopfTWV/mWuUdMkChlwjGF9PM2ywiX9RizZh\n" ++
    "8Qq3YwIDAQABAkBogMLujei+GPGXnmTQeyGFhahXHzxBFhTHHyS1RJG1uyvaxEvc\n" ++
    "ddWYuSIXO7yKjo6x/8Ilg8byIA9ZsHvOwQIBAiEA84l4Hka1A/hzGvc/tZ7CVE1H\n" ++
    "VnXyrWK1S4q/h32iqQECIQDCER/fNWVzKFpX6I445ay/sofMbZRQqYvGUpzk52dc\n" ++
    "YwIgEh9/xdkDLXl2r2II5q4azgU2MtPyLD71ONrpZ97MlQECIFJY895CCR9ZUySU\n" ++
    "QK0yACCDwA3lvZaQqwfnjD2xV3GjAiAbEKLL0pR8horQJrNxzQcxsnr7PeUf1sBq\n" ++
    "cdH+B451Rw==\n" ++
    "-----END PRIVATE KEY-----\n";

test "parse PEM private key" {
    var key = try rsa.parsePrivateKeyPem(std.testing.allocator, test_pem_512);
    defer key.deinit();

    // 512-bit key = 64 byte modulus
    try std.testing.expectEqual(@as(usize, 64), key.modulus_len);
    // d_bytes should be non-empty
    try std.testing.expect(key.d_bytes.len > 0);
}

test "RSA sign produces correct length output" {
    var key = try rsa.parsePrivateKeyPem(std.testing.allocator, test_pem_512);
    defer key.deinit();

    const message = "test message to sign";
    const signature = try key.sign(message);
    defer std.testing.allocator.free(signature);

    // Signature length should equal modulus length
    try std.testing.expectEqual(@as(usize, 64), signature.len);
}

test "RSA sign is deterministic" {
    var key = try rsa.parsePrivateKeyPem(std.testing.allocator, test_pem_512);
    defer key.deinit();

    const message = "deterministic signing test";
    const sig1 = try key.sign(message);
    defer std.testing.allocator.free(sig1);

    const sig2 = try key.sign(message);
    defer std.testing.allocator.free(sig2);

    try std.testing.expectEqualSlices(u8, sig1, sig2);
}

test "RSA sign different messages produce different signatures" {
    var key = try rsa.parsePrivateKeyPem(std.testing.allocator, test_pem_512);
    defer key.deinit();

    const sig1 = try key.sign("message one");
    defer std.testing.allocator.free(sig1);

    const sig2 = try key.sign("message two");
    defer std.testing.allocator.free(sig2);

    try std.testing.expect(!std.mem.eql(u8, sig1, sig2));
}

// ============================================================================
// PEM parsing edge cases
// ============================================================================

test "reject invalid PEM" {
    const result = rsa.parsePrivateKeyPem(std.testing.allocator, "not a pem");
    try std.testing.expectError(error.InvalidPem, result);
}

test "reject truncated PEM" {
    const result = rsa.parsePrivateKeyPem(std.testing.allocator, "-----BEGIN PRIVATE KEY-----\nAAAA\n");
    try std.testing.expectError(error.InvalidPem, result);
}

// ============================================================================
// JWT tests
// ============================================================================

test "JWT structure is valid" {
    var key = try rsa.parsePrivateKeyPem(std.testing.allocator, test_pem_512);
    defer key.deinit();

    const token = try jwt.createSignedJwt(std.testing.allocator, &key, .{
        .issuer = "test@test.iam.gserviceaccount.com",
        .scope = "https://www.googleapis.com/auth/cloud-platform",
        .audience = "https://oauth2.googleapis.com/token",
    }, 1700000000);
    defer std.testing.allocator.free(token);

    // JWT should have exactly 3 dot-separated parts
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, token, '.');
    while (it.next()) |_| parts += 1;
    try std.testing.expectEqual(@as(usize, 3), parts);
}

test "JWT header is RS256" {
    var key = try rsa.parsePrivateKeyPem(std.testing.allocator, test_pem_512);
    defer key.deinit();

    const token = try jwt.createSignedJwt(std.testing.allocator, &key, .{
        .issuer = "test@test.iam.gserviceaccount.com",
        .scope = "https://www.googleapis.com/auth/cloud-platform",
        .audience = "https://oauth2.googleapis.com/token",
    }, 1700000000);
    defer std.testing.allocator.free(token);

    // First part should be the RS256 header
    var it = std.mem.splitScalar(u8, token, '.');
    const header_b64 = it.next().?;

    // Decode header
    const header_len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(header_b64);
    const header = try std.testing.allocator.alloc(u8, header_len);
    defer std.testing.allocator.free(header);
    try std.base64.url_safe_no_pad.Decoder.decode(header, header_b64);

    try std.testing.expectEqualStrings("{\"alg\":\"RS256\",\"typ\":\"JWT\"}", header);
}

test "JWT claims contain required fields" {
    var key = try rsa.parsePrivateKeyPem(std.testing.allocator, test_pem_512);
    defer key.deinit();

    const token = try jwt.createSignedJwt(std.testing.allocator, &key, .{
        .issuer = "test@project.iam.gserviceaccount.com",
        .scope = "https://www.googleapis.com/auth/cloud-platform",
        .audience = "https://oauth2.googleapis.com/token",
    }, 1700000000);
    defer std.testing.allocator.free(token);

    // Decode claims (second part)
    var it = std.mem.splitScalar(u8, token, '.');
    _ = it.next(); // skip header
    const claims_b64 = it.next().?;

    const claims_len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(claims_b64);
    const claims = try std.testing.allocator.alloc(u8, claims_len);
    defer std.testing.allocator.free(claims);
    try std.base64.url_safe_no_pad.Decoder.decode(claims, claims_b64);

    // Verify required fields are present
    try std.testing.expect(std.mem.indexOf(u8, claims, "\"iss\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, claims, "\"scope\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, claims, "\"aud\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, claims, "\"iat\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, claims, "\"exp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, claims, "test@project.iam.gserviceaccount.com") != null);
}

// ============================================================================
// URL encoding test
// ============================================================================

test "URL encode special characters" {
    const encoded = try jwt.urlEncode(std.testing.allocator, "urn:ietf:params:oauth:grant-type:jwt-bearer");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer", encoded);
}

// ============================================================================
// Token tests
// ============================================================================

test "token expiry check" {
    const now: i64 = 1700000000;

    var token = gcp.Token{
        .access_token = try std.testing.allocator.dupe(u8, "test"),
        .expires_at = now + 3600,
        .allocator = std.testing.allocator,
    };
    defer token.deinit();

    try std.testing.expect(!token.isExpired(now));

    var expired_token = gcp.Token{
        .access_token = try std.testing.allocator.dupe(u8, "test"),
        .expires_at = now - 100,
        .allocator = std.testing.allocator,
    };
    defer expired_token.deinit();

    try std.testing.expect(expired_token.isExpired(now));
}

// ============================================================================
// Static provider
// ============================================================================

test "static provider returns token" {
    var provider = gcp.StaticProvider.init("ya29.test-token");
    const token = try provider.getToken();
    try std.testing.expectEqualStrings("ya29.test-token", token);
}

// ============================================================================
// Service account JSON parsing
// ============================================================================

test "parse service account JSON" {
    // JSON-escaped PEM (newlines as literal \n in JSON string)
    const sa_json =
        \\{"type":"service_account","project_id":"test-project",
    ++
        \\"client_email":"test@test.iam.gserviceaccount.com",
    ++
        \\"private_key":"-----BEGIN PRIVATE KEY-----\n
    ++
        \\MIIBUwIBADANBgkqhkiG9w0BAQEFAASCAT0wggE5AgEAAkEAuJ53eeivJJ7a21Ju\n
    ++
        \\8Zj8BdGR/g0Q3GakWDg6DXcmR+7lFopfTWV/mWuUdMkChlwjGF9PM2ywiX9RizZh\n
    ++
        \\8Qq3YwIDAQABAkBogMLujei+GPGXnmTQeyGFhahXHzxBFhTHHyS1RJG1uyvaxEvc\n
    ++
        \\ddWYuSIXO7yKjo6x/8Ilg8byIA9ZsHvOwQIBAiEA84l4Hka1A/hzGvc/tZ7CVE1H\n
    ++
        \\VnXyrWK1S4q/h32iqQECIQDCER/fNWVzKFpX6I445ay/sofMbZRQqYvGUpzk52dc\n
    ++
        \\YwIgEh9/xdkDLXl2r2II5q4azgU2MtPyLD71ONrpZ97MlQECIFJY895CCR9ZUySU\n
    ++
        \\QK0yACCDwA3lvZaQqwfnjD2xV3GjAiAbEKLL0pR8horQJrNxzQcxsnr7PeUf1sBq\n
    ++
        \\cdH+B451Rw==\n-----END PRIVATE KEY-----\n",
    ++
        \\"token_uri":"https://oauth2.googleapis.com/token"}
    ;

    var provider = try gcp.ServiceAccountProvider.fromJson(
        std.testing.allocator,
        sa_json,
        gcp.SCOPE_CLOUD_PLATFORM,
    );
    defer provider.deinit();

    try std.testing.expectEqualStrings("test@test.iam.gserviceaccount.com", provider.client_email);
    try std.testing.expectEqualStrings("https://oauth2.googleapis.com/token", provider.token_uri);
}
