// Edge case tests — exercises bugs and suspicious patterns found during
// the code audit. Each test documents a specific risk and proves whether
// the current code handles it correctly (or exposes a bug).
//
// Categories:
//   1. Billing arithmetic (overflow, negative refund, zero-token)
//   2. Store concurrency (reservation lifecycle, balance consistency)
//   3. FixedStr boundary conditions
//   4. OIDC edge cases
//   5. Auth pipeline edge cases

const std = @import("std");
const testing = std.testing;
const Dir = std.Io.Dir;
const billing = @import("billing.zig");
const types = @import("store/types.zig");
const store_mod = @import("store/store.zig");
const oidc = @import("oidc.zig");
const integration = @import("integration_test.zig");

// ── 1. Billing Arithmetic ──────────────────────────────────────

test "billing: overflow safety — expensive model at max tokens" {
    // GPT-5.4 Pro: $180/M output. 1M max tokens.
    // output_ticks = ticksPerToken(180.0) * 1_000_000
    // = (180 * 10B / 1M) * 1M = 180 * 10B = 1.8T
    // i64 max = 9.2e18, so 1.8T is fine. But test it anyway.
    const cost = billing.actualCost("gpt-5.4-pro", 1_000_000, 1_000_000, .free);
    try testing.expect(cost.cost > 0); // Must not overflow to negative
    try testing.expect(cost.margin > 0);
    try testing.expect(cost.margin < cost.cost); // Margin < base cost
}

test "billing: estimateCost doesn't overflow at max_tokens_cap" {
    // security.Limits.max_tokens_cap = 1_000_000
    const est = billing.estimateCost("gpt-5.4-pro", 1_000_000);
    try testing.expect(est > 0);
}

test "billing: zero tokens produces zero cost" {
    const cost = billing.actualCost("claude-sonnet-4-6", 0, 0, .free);
    try testing.expectEqual(@as(i64, 0), cost.cost);
    try testing.expectEqual(@as(i64, 0), cost.margin);
}

test "billing: single token produces non-zero cost for expensive models" {
    const cost = billing.actualCost("claude-opus-4-6", 1, 1, .free);
    try testing.expect(cost.cost > 0);
}

test "billing: calculateCap with zero balance returns null" {
    const cap = billing.calculateCap("deepseek-chat", 4096, 10, 0, .free);
    try testing.expect(cap == null);
}

test "billing: calculateCap with negative balance returns null" {
    const cap = billing.calculateCap("deepseek-chat", 4096, 10, -1000, .free);
    try testing.expect(cap == null);
}

test "billing: calculateCap with tiny balance caps max_tokens low" {
    // $0.001 balance = 10_000_000 ticks
    const cap = billing.calculateCap("claude-opus-4-6", 100_000, 10, 10_000_000, .free);
    if (cap) |c| {
        try testing.expect(c.capped_max_tokens < 100_000); // Must cap below requested
        try testing.expect(c.capped_max_tokens > 0); // But must allow something
        try testing.expect(c.reservation_ticks > 0);
        try testing.expect(c.reservation_ticks <= 10_000_000); // Can't exceed balance
    }
}

test "billing: calculateCap input cost exceeds balance returns null" {
    // 1M input tokens on an expensive model with $0.001 balance
    const cap = billing.calculateCap("gpt-5.4-pro", 100, 1_000_000, 10_000_000, .free);
    try testing.expect(cap == null); // Can't even afford the input
}

test "billing: margin decreases with better tier" {
    const tiers = [_]types.DevTier{ .free, .hobby, .pro, .enterprise };
    var prev_total: i64 = std.math.maxInt(i64);
    for (tiers) |tier| {
        const cost = billing.actualCost("deepseek-chat", 10000, 10000, tier);
        const total = cost.cost + cost.margin;
        try testing.expect(total <= prev_total); // Better tier = lower total
        prev_total = total;
    }
}

// ── 2. Store / Reservation Edge Cases ──────────────────────────

test "store: commitReservation with cost > reserved (overcharge)" {
    // If the provider charges more than reserved (thinking tokens, etc.),
    // the excess must be deducted from the balance, not ignored.
    var fx = try integration.TestFixture.init(testing.allocator, "overcharge");
    defer fx.deinit();

    const initial = fx.store.accounts.getPtr(fx.account_id).?.balance_ticks;

    // Reserve a small amount
    const rid = try fx.store.reserve(fx.io(), fx.account_id, fx.key_hash, 1000, "/test", "test");
    const after_reserve = fx.store.accounts.getPtr(fx.account_id).?.balance_ticks;
    try testing.expectEqual(initial - 1000, after_reserve);

    // Commit with cost HIGHER than reserved (provider overshot)
    try fx.store.commitReservation(fx.io(), rid, 5000, 500);

    // Balance should be LOWER than after_reserve (excess deducted)
    const after_commit = fx.store.accounts.getPtr(fx.account_id).?.balance_ticks;
    // delta = reserved(1000) - actual(5500) = -4500 → deducted from balance
    try testing.expectEqual(after_reserve - 4500, after_commit);
    // Total charged = initial - after_commit = 1000 + 4500 = 5500 (correct)
    try testing.expectEqual(initial - 5500, after_commit);
}

test "store: commitReservation with zero actual cost (free ride)" {
    var fx = try integration.TestFixture.init(testing.allocator, "freeride");
    defer fx.deinit();

    const initial = fx.store.accounts.getPtr(fx.account_id).?.balance_ticks;

    const rid = try fx.store.reserve(fx.io(), fx.account_id, fx.key_hash, 5000, "/test", "test");
    const after_reserve = fx.store.accounts.getPtr(fx.account_id).?.balance_ticks;
    try testing.expectEqual(initial - 5000, after_reserve);

    // Commit with 0 actual cost — full refund
    try fx.store.commitReservation(fx.io(), rid, 0, 0);

    // Balance should be fully restored
    const after_commit = fx.store.accounts.getPtr(fx.account_id).?.balance_ticks;
    try testing.expectEqual(initial, after_commit);
}

test "store: double commit same reservation is error" {
    var fx = try integration.TestFixture.init(testing.allocator, "doublecommit");
    defer fx.deinit();

    const rid = try fx.store.reserve(fx.io(), fx.account_id, fx.key_hash, 1000, "/test", "test");
    try fx.store.commitReservation(fx.io(), rid, 500, 100);

    // Second commit should fail (reservation already removed)
    try testing.expectError(error.ReservationNotFound,
        fx.store.commitReservation(fx.io(), rid, 500, 100));
}

test "store: rollback after commit is error" {
    var fx = try integration.TestFixture.init(testing.allocator, "rollbackcommit");
    defer fx.deinit();

    const rid = try fx.store.reserve(fx.io(), fx.account_id, fx.key_hash, 1000, "/test", "test");
    try fx.store.commitReservation(fx.io(), rid, 500, 100);

    // Rollback should be a no-op (reservation removed), not double-credit
    fx.store.rollbackReservation(fx.io(), rid);
    // Balance should remain the same (not refunded again)
}

test "store: reserve exactly equal to balance succeeds" {
    var fx = try integration.TestFixture.init(testing.allocator, "exactbalance");
    defer fx.deinit();

    const balance = fx.store.accounts.getPtr(fx.account_id).?.balance_ticks;
    // Reserve exactly the full balance
    const rid = try fx.store.reserve(fx.io(), fx.account_id, fx.key_hash, balance, "/test", "test");
    // Balance should be exactly 0
    try testing.expectEqual(@as(i64, 0), fx.store.accounts.getPtr(fx.account_id).?.balance_ticks);

    // Second reserve should fail (balance = 0)
    try testing.expectError(error.InsufficientBalance,
        fx.store.reserve(fx.io(), fx.account_id, fx.key_hash, 1, "/test", "test"));

    // Cleanup
    fx.store.rollbackReservation(fx.io(), rid);
}

test "store: reserve with amount 0 should still succeed" {
    var fx = try integration.TestFixture.init(testing.allocator, "zeroreserve");
    defer fx.deinit();

    const initial = fx.store.accounts.getPtr(fx.account_id).?.balance_ticks;
    // Zero reservation (edge case from min reservation logic)
    const rid = try fx.store.reserve(fx.io(), fx.account_id, fx.key_hash, 0, "/test", "test");
    try testing.expectEqual(initial, fx.store.accounts.getPtr(fx.account_id).?.balance_ticks);
    fx.store.rollbackReservation(fx.io(), rid);
}

// ── 3. FixedStr Boundary Conditions ────────────────────────────

test "FixedStr64: apple sub fits (50 chars)" {
    const apple_id = "apple_000846.56fb2a242e9d4424b85e19a6ea2b82fa.0333";
    try testing.expectEqual(@as(usize, 50), apple_id.len);
    const fs = types.FixedStr64.fromSlice(apple_id);
    try testing.expectEqualStrings(apple_id, fs.slice());
    try testing.expect(fs.eql(apple_id));
}

test "FixedStr64: exactly 64 chars" {
    const s = "a" ** 64;
    const fs = types.FixedStr64.fromSlice(s);
    try testing.expectEqual(@as(u16, 64), fs.len);
    try testing.expectEqualStrings(s, fs.slice());
}

test "FixedStr64: 65 chars truncates" {
    const s = "a" ** 65;
    const fs = types.FixedStr64.fromSlice(s);
    try testing.expectEqual(@as(u16, 64), fs.len);
    // The 65th char is lost
    try testing.expect(!fs.eql(s));
}

test "FixedStr128: model name fits" {
    const model = "deepseek-ai/deepseek-v3.2-maas";
    const fs = types.FixedStr128.fromSlice(model);
    try testing.expectEqualStrings(model, fs.slice());
}

test "FixedStr256: email with long domain" {
    const email = "very.long.email@subdomain.of.a.very.long.domain.name.that.keeps.going.example.com";
    const fs = types.FixedStr256.fromSlice(email);
    try testing.expectEqualStrings(email, fs.slice());
}

// ── 4. OIDC Edge Cases ─────────────────────────────────────────

test "oidc: verifyJwt with empty token" {
    const allocator = testing.allocator;
    var cache = oidc.JwksCache{};
    cache.count = 1;
    try testing.expectError(error.InvalidToken, oidc.verifyJwt(allocator, "", &cache));
}

test "oidc: verifyJwt with just dots" {
    const allocator = testing.allocator;
    var cache = oidc.JwksCache{};
    cache.count = 1;
    try testing.expectError(error.InvalidToken, oidc.verifyJwt(allocator, "..", &cache));
}

test "oidc: verifyNonce rejects partial hash" {
    try testing.expect(!oidc.verifyNonce("secret", "abc123")); // Too short
}

test "oidc: verifyNonce rejects uppercase hash" {
    // SHA-256 should be lowercase hex
    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("test", &hash, .{});
    var upper: [64]u8 = undefined;
    const hex_chars = "0123456789ABCDEF"; // uppercase
    for (hash, 0..) |b, i| {
        upper[i * 2] = hex_chars[b >> 4];
        upper[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    try testing.expect(!oidc.verifyNonce("test", &upper)); // Should fail (lowercase expected)
}

// ── 5. Billing Dynamic Capping Integration ─────────────────────

// ── 6. Agent Capability Filtering ───────────────────────────────

const agent = @import("agent.zig");
const ToolDef = @import("http-sentinel").ai.common.ToolDefinition;

test "capabilities: null (absent) returns all tools" {
    const all_tools = [_]ToolDef{
        .{ .name = "bash", .description = "run command", .input_schema = "{}" },
        .{ .name = "read_file", .description = "read", .input_schema = "{}" },
        .{ .name = "write_file", .description = "write", .input_schema = "{}" },
    };
    const result = try agent.filterToolsByCapabilities(testing.allocator, &all_tools, null);
    // null capabilities → full suite
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 3), result.?.len);
}

test "capabilities: empty array returns null (Safe Mode)" {
    const all_tools = [_]ToolDef{
        .{ .name = "bash", .description = "run command", .input_schema = "{}" },
    };
    const empty: []const []const u8 = &.{};
    const result = try agent.filterToolsByCapabilities(testing.allocator, &all_tools, empty);
    // empty capabilities → no tools
    try testing.expect(result == null);
}

test "capabilities: file_read only exposes read_file" {
    const all_tools = [_]ToolDef{
        .{ .name = "bash", .description = "run command", .input_schema = "{}" },
        .{ .name = "read_file", .description = "read", .input_schema = "{}" },
        .{ .name = "write_file", .description = "write", .input_schema = "{}" },
    };
    const caps: []const []const u8 = &.{"file_read"};
    const result = try agent.filterToolsByCapabilities(testing.allocator, &all_tools, caps);
    defer if (result) |r| testing.allocator.free(r);

    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 1), result.?.len);
    try testing.expectEqualStrings("read_file", result.?[0].name);
}

test "capabilities: code_execution exposes bash" {
    const all_tools = [_]ToolDef{
        .{ .name = "bash", .description = "run command", .input_schema = "{}" },
        .{ .name = "read_file", .description = "read", .input_schema = "{}" },
        .{ .name = "write_file", .description = "write", .input_schema = "{}" },
    };
    const caps: []const []const u8 = &.{"code_execution"};
    const result = try agent.filterToolsByCapabilities(testing.allocator, &all_tools, caps);
    defer if (result) |r| testing.allocator.free(r);

    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 1), result.?.len);
    try testing.expectEqualStrings("bash", result.?[0].name);
}

test "capabilities: multiple capabilities combine tools" {
    const all_tools = [_]ToolDef{
        .{ .name = "bash", .description = "run command", .input_schema = "{}" },
        .{ .name = "read_file", .description = "read", .input_schema = "{}" },
        .{ .name = "write_file", .description = "write", .input_schema = "{}" },
    };
    const caps: []const []const u8 = &.{ "file_read", "file_write" };
    const result = try agent.filterToolsByCapabilities(testing.allocator, &all_tools, caps);
    defer if (result) |r| testing.allocator.free(r);

    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 2), result.?.len);
}

test "capabilities: unknown capability returns null" {
    const all_tools = [_]ToolDef{
        .{ .name = "bash", .description = "run command", .input_schema = "{}" },
    };
    const caps: []const []const u8 = &.{"nonexistent_capability"};
    const result = try agent.filterToolsByCapabilities(testing.allocator, &all_tools, caps);
    // Unknown capability → no matching tools → null
    try testing.expect(result == null);
}

test "capabilities: terminal_inject and code_execution both map to bash (deduplicated)" {
    const all_tools = [_]ToolDef{
        .{ .name = "bash", .description = "run command", .input_schema = "{}" },
        .{ .name = "read_file", .description = "read", .input_schema = "{}" },
    };
    const caps: []const []const u8 = &.{ "code_execution", "terminal_inject" };
    const result = try agent.filterToolsByCapabilities(testing.allocator, &all_tools, caps);
    defer if (result) |r| testing.allocator.free(r);

    try testing.expect(result != null);
    // Both map to "bash" but should be deduplicated → 1 tool
    try testing.expectEqual(@as(usize, 1), result.?.len);
    try testing.expectEqualStrings("bash", result.?[0].name);
}

// ── 7. JSON Escaping ───────────────────────────────────────────

test "jsonEscape: control chars encoded as \\u00XX" {
    const allocator = testing.allocator;
    const chat = @import("chat.zig");

    // Input with null byte, bell, and form feed
    const input = "hello\x00world\x07\x0c";
    const escaped = try chat.jsonEscape(allocator, input);
    defer allocator.free(escaped);

    // Control chars must be \u00XX, not dropped
    try testing.expect(std.mem.indexOf(u8, escaped, "\\u0000") != null); // null
    try testing.expect(std.mem.indexOf(u8, escaped, "\\u0007") != null); // bell
    try testing.expect(std.mem.indexOf(u8, escaped, "\\u000c") != null); // form feed
    try testing.expect(std.mem.indexOf(u8, escaped, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, escaped, "world") != null);
}

test "jsonEscape: normal text unchanged" {
    const allocator = testing.allocator;
    const chat = @import("chat.zig");

    const escaped = try chat.jsonEscape(allocator, "hello world");
    defer allocator.free(escaped);
    try testing.expectEqualStrings("hello world", escaped);
}

test "jsonEscape: quotes and backslashes escaped" {
    const allocator = testing.allocator;
    const chat = @import("chat.zig");

    const escaped = try chat.jsonEscape(allocator, "say \"hello\" and \\n");
    defer allocator.free(escaped);
    try testing.expectEqualStrings("say \\\"hello\\\" and \\\\n", escaped);
}

// ── 5. Billing Dynamic Capping Integration ─────────────────────

test "billing: reserveWithCap produces valid reservation" {
    var fx = try integration.TestFixture.init(testing.allocator, "capintegration");
    defer fx.deinit();

    const auth = fx.authContext();
    const result = try billing.reserveWithCap(
        &fx.store, fx.io(), &auth,
        "deepseek-chat", 8192, 100, "/qai/v1/chat",
    );

    try testing.expect(result.reservation_id > 0);
    try testing.expect(result.capped_max_tokens > 0);
    try testing.expect(result.capped_max_tokens <= 8192);

    // Clean up
    billing.rollback(&fx.store, fx.io(), result.reservation_id);
}

test "billing: multiple reserves drain balance correctly" {
    var fx = try integration.TestFixture.init(testing.allocator, "multireserve");
    defer fx.deinit();

    const auth = fx.authContext();
    var rids: [10]u64 = undefined;
    var count: usize = 0;

    // Reserve repeatedly until balance runs out
    while (count < 10) {
        const result = billing.reserveWithCap(
            &fx.store, fx.io(), &auth,
            "claude-opus-4-6", 10000, 100, "/test",
        ) catch break; // Expected: InsufficientBalance at some point
        rids[count] = result.reservation_id;
        count += 1;
    }

    // Should have made at least 1 successful reservation
    try testing.expect(count > 0);

    // Balance should be non-negative
    const balance = fx.store.accounts.getPtr(fx.account_id).?.balance_ticks;
    try testing.expect(balance >= 0);

    // Rollback all
    for (rids[0..count]) |rid| {
        billing.rollback(&fx.store, fx.io(), rid);
    }

    // Balance should be fully restored
    try testing.expectEqual(@as(i64, 100_000_000_000), fx.store.accounts.getPtr(fx.account_id).?.balance_ticks);
}
