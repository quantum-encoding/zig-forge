const std = @import("std");
const gcp = @import("gcp-auth");
const rsa = gcp.rsa;
const jwt = gcp.jwt;

// ============================================================================
// Test key — 2048-bit RSA (PKCS#8 PEM) — NOT for production use.
// Generated with: openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048
// ============================================================================

const test_pem_2048 =
    "-----BEGIN PRIVATE KEY-----\n" ++
    "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCnUz7BuRTCm/VA\n" ++
    "IWa+KiDGcVe7jGM3f2OF8r9MkLOnmBI3eGSp8pkAnebeIdCgM8zSTwCirTbKcnLD\n" ++
    "MY1X+UzOA/KZi5k80X09uoX3Hpw31aHEEDIAZlhSNuwpR2TEGGKc5YPvtSjRHcFk\n" ++
    "a12zlyWboEUeTwi6SOSYP0hzvsH/FKhFuJfEPTFK3SbpwsDEYMPqD0fmAF06Gcc0\n" ++
    "Pe8CcGF2R8cG44zTNu2633E+nGNipcUdMT+HLv/6nWOttCDIFuBdrmcidf/Sqp9O\n" ++
    "JEnWRMxg0gFJ3phj4yjDSlvC/0yh1MtPTq+wbdvYzp8h924QR8tNgBuNTn6p4RoI\n" ++
    "bivs/RUlAgMBAAECggEAAmmHJFLoPoP9HPKMPOv7jsLpEVX0PbKlYh14waG1txIC\n" ++
    "lTidx/EAB7hxICbQmo+wcLvSApcREnkAIeT/DMLegvWOhfHEJ8HNp07hzMv9oY3p\n" ++
    "jvSVmSu/KBWovsDnoETfumAPYScDVWNlaBs6JKgpJock8xPM6d3mrT0KDj80iF/r\n" ++
    "sYgFH9GEx1Y6mYDTg1OUFfD3YeXzdNhyVbXqvFhX+bEyyIDT1oxXh8kmXvgMId4d\n" ++
    "Z/LVqh72dePcGFPEJIM4vpwLTpo1Tkdy7Tt4KfWv6Ym12xUDoxbl2kkjxko+yaj7\n" ++
    "UiKWAyRZev4NYUROT8ltBnGErUcWBGGCkTOmw5ZVEwKBgQDZjQ54E4Tip5AF1zZd\n" ++
    "9YqWiRHStenJXTahPwrOpmMAzFJD2XEaDdcl/qLRP7aUELKddRbLWGM8MHW+R2tz\n" ++
    "i1U8bD//R7JgCS5klpDLnwAD+U2OBn759z84vESH7s3zFDf15OS/oN5vn1wLgaz/\n" ++
    "cQy74uZ/R9whZEWLvs2qlxbJrwKBgQDE5cGSgeBn5kQ4+LE1PXrCarBrLndjq5N6\n" ++
    "zog4kw7sIaseQzwhH5O/Pf/OVo/pvl8A55PDoESu469nnj6PNBrcxAtn4rG+D5mB\n" ++
    "6uK1+zQ69qYZ4WlCxyjW3f+k2VFgyeFX7PsSMsTWqJVgQ6fzDYuezJFy/PiyM66P\n" ++
    "cZGru/0HawKBgBRnsZq7ofQsaUrS88t+U2BpPN25qFL1xkD7i8T0QEb74x9wDra1\n" ++
    "458xsg3UXwimREqWh+vMv4oOtYyCYGa3A+il8p68F9QAKHTQ1oXyxOqagJa4r0I8\n" ++
    "2ZY1umvRj0mkdNdAf+Alc5eep+CAajyPWvVog9weXlxXblp8LAg7Ia0LAoGAejAS\n" ++
    "hjau6gtNvwUmA2IZsli/DmSRlnq9VPKiOmmYUxU5udgDkpKj/4QcIRI60NVg45DS\n" ++
    "dA4bUWTeTzE2pWuyV9oZMejOYKIRozv+YOx5JzY1Mc5eoiAxydWOdeCeza+6dfQM\n" ++
    "guiampOXz1ts+DopsOxGPtOaCgxkgYP64FYS2e0CgYEApKvLy2OYdYtsyDrhaWdk\n" ++
    "vhBolaCawG8CFsG28VEC0l95Z4EKVeSxADAnYLKYWded4Ah8aZIC1kUfdzOGgUv0\n" ++
    "Zei66t7KvwqtByUK6/vBDYt61+XqBTqe94K2W99uZaUMrO2CjEZh41kvnfQVkGHC\n" ++
    "gQwdvS+8u/LVZuVweMwVXTM=\n" ++
    "-----END PRIVATE KEY-----\n";

// 512-bit key for weak-key rejection test
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

// ============================================================================
// PEM / DER parsing
// ============================================================================

test "parse 2048-bit PEM private key" {
    var key = try rsa.parsePrivateKeyPem(std.testing.allocator, test_pem_2048);
    defer key.deinit();

    // 2048-bit key = 256 byte modulus
    try std.testing.expectEqual(@as(usize, 256), key.modulus_len);
    try std.testing.expect(key.d_bytes.len > 0);
}

test "RSA sign produces correct length output" {
    var key = try rsa.parsePrivateKeyPem(std.testing.allocator, test_pem_2048);
    defer key.deinit();

    const signature = try key.sign("test message to sign");
    defer std.testing.allocator.free(signature);

    try std.testing.expectEqual(@as(usize, 256), signature.len);
}

test "RSA sign is deterministic" {
    var key = try rsa.parsePrivateKeyPem(std.testing.allocator, test_pem_2048);
    defer key.deinit();

    const sig1 = try key.sign("deterministic signing test");
    defer std.testing.allocator.free(sig1);

    const sig2 = try key.sign("deterministic signing test");
    defer std.testing.allocator.free(sig2);

    try std.testing.expectEqualSlices(u8, sig1, sig2);
}

test "RSA sign different messages produce different signatures" {
    var key = try rsa.parsePrivateKeyPem(std.testing.allocator, test_pem_2048);
    defer key.deinit();

    const sig1 = try key.sign("message one");
    defer std.testing.allocator.free(sig1);

    const sig2 = try key.sign("message two");
    defer std.testing.allocator.free(sig2);

    try std.testing.expect(!std.mem.eql(u8, sig1, sig2));
}

test "reject invalid PEM" {
    const result = rsa.parsePrivateKeyPem(std.testing.allocator, "not a pem");
    try std.testing.expectError(error.InvalidPem, result);
}

test "reject truncated PEM" {
    const result = rsa.parsePrivateKeyPem(std.testing.allocator, "-----BEGIN PRIVATE KEY-----\nAAAA\n");
    try std.testing.expectError(error.InvalidPem, result);
}

// ============================================================================
// SECURITY: Weak key rejection (#4)
// ============================================================================

test "reject 512-bit RSA key as too weak" {
    const result = rsa.parsePrivateKeyPem(std.testing.allocator, test_pem_512);
    try std.testing.expectError(error.KeyTooWeak, result);
}

// ============================================================================
// JWT tests
// ============================================================================

test "JWT structure is valid (3 dot-separated parts)" {
    var key = try rsa.parsePrivateKeyPem(std.testing.allocator, test_pem_2048);
    defer key.deinit();

    const token = try jwt.createSignedJwt(std.testing.allocator, &key, .{
        .issuer = "test@test.iam.gserviceaccount.com",
        .scope = "https://www.googleapis.com/auth/cloud-platform",
        .audience = "https://oauth2.googleapis.com/token",
    }, 1700000000);
    defer std.testing.allocator.free(token);

    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, token, '.');
    while (it.next()) |_| parts += 1;
    try std.testing.expectEqual(@as(usize, 3), parts);
}

test "JWT header is RS256" {
    var key = try rsa.parsePrivateKeyPem(std.testing.allocator, test_pem_2048);
    defer key.deinit();

    const token = try jwt.createSignedJwt(std.testing.allocator, &key, .{
        .issuer = "test@test.iam.gserviceaccount.com",
        .scope = "https://www.googleapis.com/auth/cloud-platform",
        .audience = "https://oauth2.googleapis.com/token",
    }, 1700000000);
    defer std.testing.allocator.free(token);

    var it = std.mem.splitScalar(u8, token, '.');
    const header_b64 = it.next().?;
    const header_len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(header_b64);
    const header = try std.testing.allocator.alloc(u8, header_len);
    defer std.testing.allocator.free(header);
    try std.base64.url_safe_no_pad.Decoder.decode(header, header_b64);

    try std.testing.expectEqualStrings("{\"alg\":\"RS256\",\"typ\":\"JWT\"}", header);
}

test "JWT claims contain required fields" {
    var key = try rsa.parsePrivateKeyPem(std.testing.allocator, test_pem_2048);
    defer key.deinit();

    const token = try jwt.createSignedJwt(std.testing.allocator, &key, .{
        .issuer = "test@project.iam.gserviceaccount.com",
        .scope = "https://www.googleapis.com/auth/cloud-platform",
        .audience = "https://oauth2.googleapis.com/token",
    }, 1700000000);
    defer std.testing.allocator.free(token);

    var it = std.mem.splitScalar(u8, token, '.');
    _ = it.next();
    const claims_b64 = it.next().?;
    const claims_len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(claims_b64);
    const claims = try std.testing.allocator.alloc(u8, claims_len);
    defer std.testing.allocator.free(claims);
    try std.base64.url_safe_no_pad.Decoder.decode(claims, claims_b64);

    try std.testing.expect(std.mem.indexOf(u8, claims, "\"iss\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, claims, "\"scope\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, claims, "\"aud\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, claims, "\"iat\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, claims, "\"exp\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, claims, "test@project.iam.gserviceaccount.com") != null);
}

// ============================================================================
// SECURITY: JWT claims injection (#1)
// ============================================================================

test "JWT claims injection via double-quote in issuer is escaped" {
    var key = try rsa.parsePrivateKeyPem(std.testing.allocator, test_pem_2048);
    defer key.deinit();

    // Attacker tries: evil","admin":true,"iss":"real
    // Without escaping, this would inject {"admin":true} into the claims.
    const token = try jwt.createSignedJwt(std.testing.allocator, &key, .{
        .issuer = "evil\",\"admin\":true,\"iss\":\"real",
        .scope = "https://www.googleapis.com/auth/cloud-platform",
        .audience = "https://oauth2.googleapis.com/token",
    }, 1700000000);
    defer std.testing.allocator.free(token);

    // Decode claims and verify it's valid JSON with NO injected admin field
    var it = std.mem.splitScalar(u8, token, '.');
    _ = it.next();
    const claims_b64 = it.next().?;
    const claims_len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(claims_b64);
    const claims = try std.testing.allocator.alloc(u8, claims_len);
    defer std.testing.allocator.free(claims);
    try std.base64.url_safe_no_pad.Decoder.decode(claims, claims_b64);

    // Must parse as valid JSON (not broken by injection)
    const parsed = try std.json.parseFromSlice(struct {
        iss: []const u8,
        scope: []const u8,
        aud: []const u8,
        iat: i64,
        exp: i64,
    }, std.testing.allocator, claims, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // The issuer must contain the raw attack string (escaped), NOT be split
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.iss, "admin") != null);
    // There must NOT be a separate "admin" key in the JSON
    try std.testing.expect(std.mem.indexOf(u8, claims, "\"admin\":true") == null);
}

test "JWT claims injection via backslash in scope is escaped" {
    var key = try rsa.parsePrivateKeyPem(std.testing.allocator, test_pem_2048);
    defer key.deinit();

    const token = try jwt.createSignedJwt(std.testing.allocator, &key, .{
        .issuer = "test@test.iam.gserviceaccount.com",
        .scope = "scope\\\"},{\"injected\":true",
        .audience = "https://oauth2.googleapis.com/token",
    }, 1700000000);
    defer std.testing.allocator.free(token);

    var it = std.mem.splitScalar(u8, token, '.');
    _ = it.next();
    const claims_b64 = it.next().?;
    const claims_len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(claims_b64);
    const claims = try std.testing.allocator.alloc(u8, claims_len);
    defer std.testing.allocator.free(claims);
    try std.base64.url_safe_no_pad.Decoder.decode(claims, claims_b64);

    // Must parse as valid JSON — injection was neutralized
    const parsed = try std.json.parseFromSlice(struct {
        iss: []const u8,
        scope: []const u8,
        aud: []const u8,
        iat: i64,
        exp: i64,
    }, std.testing.allocator, claims, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    // No injected field
    try std.testing.expect(std.mem.indexOf(u8, claims, "\"injected\":true") == null);
}

test "JSON escape handles control characters" {
    const escaped = try jwt.jsonEscape(std.testing.allocator, "line1\nline2\ttab\x00null");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("line1\\nline2\\ttab\\u0000null", escaped);
}

test "JSON escape handles quotes and backslashes" {
    const escaped = try jwt.jsonEscape(std.testing.allocator, "say \"hello\" \\ world");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("say \\\"hello\\\" \\\\ world", escaped);
}

// ============================================================================
// SECURITY: Token URI SSRF (#2)
// ============================================================================

test "token URI allows googleapis.com" {
    try std.testing.expect(gcp.isAllowedTokenUri("https://oauth2.googleapis.com/token"));
}

test "token URI allows accounts.google.com" {
    try std.testing.expect(gcp.isAllowedTokenUri("https://accounts.google.com/o/oauth2/token"));
}

test "token URI rejects HTTP (non-TLS)" {
    try std.testing.expect(!gcp.isAllowedTokenUri("http://oauth2.googleapis.com/token"));
}

test "token URI rejects attacker domain" {
    try std.testing.expect(!gcp.isAllowedTokenUri("https://evil.com/steal?r=googleapis.com"));
}

test "token URI rejects internal service" {
    try std.testing.expect(!gcp.isAllowedTokenUri("https://10.0.0.1:8080/token"));
}

test "token URI rejects empty string" {
    try std.testing.expect(!gcp.isAllowedTokenUri(""));
}

test "SA fromJson rejects malicious token_uri" {
    const sa_json =
        \\{"type":"service_account","project_id":"test",
    ++
        \\"client_email":"test@test.iam.gserviceaccount.com",
    ++
        \\"private_key":"-----BEGIN PRIVATE KEY-----\n
    ++ "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCnUz7BuRTCm/VA\\n" ++
        "IWa+KiDGcVe7jGM3f2OF8r9MkLOnmBI3eGSp8pkAnebeIdCgM8zSTwCirTbKcnLD\\n" ++
        "MY1X+UzOA/KZi5k80X09uoX3Hpw31aHEEDIAZlhSNuwpR2TEGGKc5YPvtSjRHcFk\\n" ++
        "a12zlyWboEUeTwi6SOSYP0hzvsH/FKhFuJfEPTFK3SbpwsDEYMPqD0fmAF06Gcc0\\n" ++
        "Pe8CcGF2R8cG44zTNu2633E+nGNipcUdMT+HLv/6nWOttCDIFuBdrmcidf/Sqp9O\\n" ++
        "JEnWRMxg0gFJ3phj4yjDSlvC/0yh1MtPTq+wbdvYzp8h924QR8tNgBuNTn6p4RoI\\n" ++
        "bivs/RUlAgMBAAECggEAAmmHJFLoPoP9HPKMPOv7jsLpEVX0PbKlYh14waG1txIC\\n" ++
        "lTidx/EAB7hxICbQmo+wcLvSApcREnkAIeT/DMLegvWOhfHEJ8HNp07hzMv9oY3p\\n" ++
        "jvSVmSu/KBWovsDnoETfumAPYScDVWNlaBs6JKgpJock8xPM6d3mrT0KDj80iF/r\\n" ++
        "sYgFH9GEx1Y6mYDTg1OUFfD3YeXzdNhyVbXqvFhX+bEyyIDT1oxXh8kmXvgMId4d\\n" ++
        "Z/LVqh72dePcGFPEJIM4vpwLTpo1Tkdy7Tt4KfWv6Ym12xUDoxbl2kkjxko+yaj7\\n" ++
        "UiKWAyRZev4NYUROT8ltBnGErUcWBGGCkTOmw5ZVEwKBgQDZjQ54E4Tip5AF1zZd\\n" ++
        "9YqWiRHStenJXTahPwrOpmMAzFJD2XEaDdcl/qLRP7aUELKddRbLWGM8MHW+R2tz\\n" ++
        "i1U8bD//R7JgCS5klpDLnwAD+U2OBn759z84vESH7s3zFDf15OS/oN5vn1wLgaz/\\n" ++
        "cQy74uZ/R9whZEWLvs2qlxbJrwKBgQDE5cGSgeBn5kQ4+LE1PXrCarBrLndjq5N6\\n" ++
        "zog4kw7sIaseQzwhH5O/Pf/OVo/pvl8A55PDoESu469nnj6PNBrcxAtn4rG+D5mB\\n" ++
        "6uK1+zQ69qYZ4WlCxyjW3f+k2VFgyeFX7PsSMsTWqJVgQ6fzDYuezJFy/PiyM66P\\n" ++
        "cZGru/0HawKBgBRnsZq7ofQsaUrS88t+U2BpPN25qFL1xkD7i8T0QEb74x9wDra1\\n" ++
        "458xsg3UXwimREqWh+vMv4oOtYyCYGa3A+il8p68F9QAKHTQ1oXyxOqagJa4r0I8\\n" ++
        "2ZY1umvRj0mkdNdAf+Alc5eep+CAajyPWvVog9weXlxXblp8LAg7Ia0LAoGAejAS\\n" ++
        "hjau6gtNvwUmA2IZsli/DmSRlnq9VPKiOmmYUxU5udgDkpKj/4QcIRI60NVg45DS\\n" ++
        "dA4bUWTeTzE2pWuyV9oZMejOYKIRozv+YOx5JzY1Mc5eoiAxydWOdeCeza+6dfQM\\n" ++
        "guiampOXz1ts+DopsOxGPtOaCgxkgYP64FYS2e0CgYEApKvLy2OYdYtsyDrhaWdk\\n" ++
        "vhBolaCawG8CFsG28VEC0l95Z4EKVeSxADAnYLKYWded4Ah8aZIC1kUfdzOGgUv0\\n" ++
        "Zei66t7KvwqtByUK6/vBDYt61+XqBTqe94K2W99uZaUMrO2CjEZh41kvnfQVkGHC\\n" ++
        "gQwdvS+8u/LVZuVweMwVXTM=\\n-----END PRIVATE KEY-----\\n" ++
        \\",
    ++
        \\"token_uri":"https://evil.com/steal-jwt"}
    ;

    const result = gcp.ServiceAccountProvider.fromJson(
        std.testing.allocator,
        sa_json,
        gcp.SCOPE_CLOUD_PLATFORM,
    );
    try std.testing.expectError(error.InvalidCredentials, result);
}

// ============================================================================
// SECURITY: Token expiry bounds (#5, #7)
// ============================================================================

test "isExpired with normal values" {
    const now: i64 = 1700000000;

    var valid = gcp.Token{
        .access_token = try std.testing.allocator.dupe(u8, "t"),
        .expires_at = now + 3600,
        .allocator = std.testing.allocator,
    };
    defer valid.deinit();
    try std.testing.expect(!valid.isExpired(now));

    var expired = gcp.Token{
        .access_token = try std.testing.allocator.dupe(u8, "t"),
        .expires_at = now - 100,
        .allocator = std.testing.allocator,
    };
    defer expired.deinit();
    try std.testing.expect(expired.isExpired(now));
}

test "isExpired does not underflow near i64 min" {
    // If expires_at is very small, (expires_at - 60) would underflow with
    // wrapping arithmetic, producing a huge positive number. An expired
    // token would appear valid. Saturating arithmetic prevents this.
    var token = gcp.Token{
        .access_token = try std.testing.allocator.dupe(u8, "t"),
        .expires_at = std.math.minInt(i64) + 10, // near minimum
        .allocator = std.testing.allocator,
    };
    defer token.deinit();

    // Should be expired (token is from the deep past), not valid
    try std.testing.expect(token.isExpired(0));
}

test "isExpired within 60s grace window triggers refresh" {
    const now: i64 = 1700000000;
    var token = gcp.Token{
        .access_token = try std.testing.allocator.dupe(u8, "t"),
        .expires_at = now + 30, // expires in 30s, but 60s grace window
        .allocator = std.testing.allocator,
    };
    defer token.deinit();

    // Should be considered expired (within 60s grace)
    try std.testing.expect(token.isExpired(now));
}

// ============================================================================
// URL encoding
// ============================================================================

test "URL encode special characters" {
    const encoded = try jwt.urlEncode(std.testing.allocator, "urn:ietf:params:oauth:grant-type:jwt-bearer");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer", encoded);
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
    const sa_json =
        \\{"type":"service_account","project_id":"test-project",
    ++
        \\"client_email":"test@test.iam.gserviceaccount.com",
    ++
        \\"private_key":"-----BEGIN PRIVATE KEY-----\n
    ++ "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCnUz7BuRTCm/VA\\n" ++
        "IWa+KiDGcVe7jGM3f2OF8r9MkLOnmBI3eGSp8pkAnebeIdCgM8zSTwCirTbKcnLD\\n" ++
        "MY1X+UzOA/KZi5k80X09uoX3Hpw31aHEEDIAZlhSNuwpR2TEGGKc5YPvtSjRHcFk\\n" ++
        "a12zlyWboEUeTwi6SOSYP0hzvsH/FKhFuJfEPTFK3SbpwsDEYMPqD0fmAF06Gcc0\\n" ++
        "Pe8CcGF2R8cG44zTNu2633E+nGNipcUdMT+HLv/6nWOttCDIFuBdrmcidf/Sqp9O\\n" ++
        "JEnWRMxg0gFJ3phj4yjDSlvC/0yh1MtPTq+wbdvYzp8h924QR8tNgBuNTn6p4RoI\\n" ++
        "bivs/RUlAgMBAAECggEAAmmHJFLoPoP9HPKMPOv7jsLpEVX0PbKlYh14waG1txIC\\n" ++
        "lTidx/EAB7hxICbQmo+wcLvSApcREnkAIeT/DMLegvWOhfHEJ8HNp07hzMv9oY3p\\n" ++
        "jvSVmSu/KBWovsDnoETfumAPYScDVWNlaBs6JKgpJock8xPM6d3mrT0KDj80iF/r\\n" ++
        "sYgFH9GEx1Y6mYDTg1OUFfD3YeXzdNhyVbXqvFhX+bEyyIDT1oxXh8kmXvgMId4d\\n" ++
        "Z/LVqh72dePcGFPEJIM4vpwLTpo1Tkdy7Tt4KfWv6Ym12xUDoxbl2kkjxko+yaj7\\n" ++
        "UiKWAyRZev4NYUROT8ltBnGErUcWBGGCkTOmw5ZVEwKBgQDZjQ54E4Tip5AF1zZd\\n" ++
        "9YqWiRHStenJXTahPwrOpmMAzFJD2XEaDdcl/qLRP7aUELKddRbLWGM8MHW+R2tz\\n" ++
        "i1U8bD//R7JgCS5klpDLnwAD+U2OBn759z84vESH7s3zFDf15OS/oN5vn1wLgaz/\\n" ++
        "cQy74uZ/R9whZEWLvs2qlxbJrwKBgQDE5cGSgeBn5kQ4+LE1PXrCarBrLndjq5N6\\n" ++
        "zog4kw7sIaseQzwhH5O/Pf/OVo/pvl8A55PDoESu469nnj6PNBrcxAtn4rG+D5mB\\n" ++
        "6uK1+zQ69qYZ4WlCxyjW3f+k2VFgyeFX7PsSMsTWqJVgQ6fzDYuezJFy/PiyM66P\\n" ++
        "cZGru/0HawKBgBRnsZq7ofQsaUrS88t+U2BpPN25qFL1xkD7i8T0QEb74x9wDra1\\n" ++
        "458xsg3UXwimREqWh+vMv4oOtYyCYGa3A+il8p68F9QAKHTQ1oXyxOqagJa4r0I8\\n" ++
        "2ZY1umvRj0mkdNdAf+Alc5eep+CAajyPWvVog9weXlxXblp8LAg7Ia0LAoGAejAS\\n" ++
        "hjau6gtNvwUmA2IZsli/DmSRlnq9VPKiOmmYUxU5udgDkpKj/4QcIRI60NVg45DS\\n" ++
        "dA4bUWTeTzE2pWuyV9oZMejOYKIRozv+YOx5JzY1Mc5eoiAxydWOdeCeza+6dfQM\\n" ++
        "guiampOXz1ts+DopsOxGPtOaCgxkgYP64FYS2e0CgYEApKvLy2OYdYtsyDrhaWdk\\n" ++
        "vhBolaCawG8CFsG28VEC0l95Z4EKVeSxADAnYLKYWded4Ah8aZIC1kUfdzOGgUv0\\n" ++
        "Zei66t7KvwqtByUK6/vBDYt61+XqBTqe94K2W99uZaUMrO2CjEZh41kvnfQVkGHC\\n" ++
        "gQwdvS+8u/LVZuVweMwVXTM=\\n-----END PRIVATE KEY-----\\n" ++
        \\",
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
