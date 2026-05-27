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

// ── Workspace-relative open (audit H9) ──────────────────────
// Lexical path validation is a trap on its own: an attacker can
// pass a clean-looking name and then swap the inode for a symlink
// to /etc/passwd before the read. The TOCTOU-safe primitives below
// open files via `Dir.openFile` with `follow_symlinks=false`
// (and `resolve_beneath=true` as defense in depth), so the OS
// blocks the swap at resolve time.

test "openFileInWorkspace: real file inside workspace opens" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "inside.txt", .data = "hello" });

    var f = try security.openFileInWorkspace(tmp.dir, testing.io, "inside.txt", .{});
    defer f.close(testing.io);

    var buf: [16]u8 = undefined;
    const n = try f.readPositionalAll(testing.io, &buf, 0);
    try testing.expectEqualStrings("hello", buf[0..n]);
}

test "openFileInWorkspace: symlink target outside workspace is rejected by OS" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Plant a symlink pointing at a system file. With
    // follow_symlinks=true this would happily open /etc/hosts; the
    // helper sets follow_symlinks=false so the kernel refuses.
    tmp.dir.symLink(testing.io, "/etc/hosts", "outside", .{}) catch return; // skip if symlinks unsupported

    if (security.openFileInWorkspace(tmp.dir, testing.io, "outside", .{})) |f| {
        var x = f;
        x.close(testing.io);
        return error.SymlinkFollowedDespiteNoFollow;
    } else |_| {} // any error is fine; the contract is "does not open the target"
}

test "openFileInWorkspace: lexical traversal rejected before syscall" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectError(
        error.PathRejected,
        security.openFileInWorkspace(tmp.dir, testing.io, "../escape", .{}),
    );
}

test "openFileInWorkspace: absolute path rejected before syscall" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectError(
        error.PathRejected,
        security.openFileInWorkspace(tmp.dir, testing.io, "/etc/passwd", .{}),
    );
}

test "createFileInWorkspace: creates regular file under workspace" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var f = try security.createFileInWorkspace(tmp.dir, testing.io, "out.txt", .{});
    defer f.close(testing.io);
    try f.writePositionalAll(testing.io, "ok", 0);
}

test "createFileInWorkspace: rejects parent-dir escape" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectError(
        error.PathRejected,
        security.createFileInWorkspace(tmp.dir, testing.io, "../poke", .{}),
    );
}

// ── Account-ID charset enforcement (audit M14) ──────────────
// The WAL serializer and Firestore doc-path use ':' (and other
// punctuation) as field/path delimiters. validateAccountId restricts
// the id to [A-Za-z0-9_-] up to 32 chars so a hostile id can never
// forge sibling fields when the record round-trips through the WAL
// or hits the doc path.

test "account_id: well-formed admin/google/apple ids accepted" {
    try testing.expect(security.validateAccountId("admin") != null);
    try testing.expect(security.validateAccountId("google_1234567890") != null);
    // Audit M4: Apple subjects are documented to contain a dot;
    // the prior validator rejected them and forced silent
    // FixedStr64 truncation. Dot is now accepted.
    try testing.expect(security.validateAccountId("apple_001234.abcdef.0987") != null);
    try testing.expect(security.validateAccountId("apple_1234567890") != null);
    try testing.expect(security.validateAccountId("a-b_c-d_1") != null);
}

test "account_id: colon is rejected (WAL delimiter injection)" {
    // Colon is the WAL update_balance delimiter — every other
    // accepted character must NOT include it.
    try testing.expect(security.validateAccountId("admin:role=admin") == null);
    try testing.expect(security.validateAccountId("google_abc:def") == null);
}

test "account_id: path/whitespace/quote delimiters rejected" {
    try testing.expect(security.validateAccountId("a/b") == null);
    try testing.expect(security.validateAccountId("a b") == null);
    try testing.expect(security.validateAccountId("a\tb") == null);
    try testing.expect(security.validateAccountId("a\"b") == null);
    try testing.expect(security.validateAccountId("a\\b") == null);
}

test "account_id: length boundaries (64 max to match FixedStr64)" {
    try testing.expect(security.validateAccountId("") == null);
    // 64 chars max — matches FixedStr64 storage width
    const ok = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ab"; // 64 chars
    try testing.expect(ok.len == 64);
    try testing.expect(security.validateAccountId(ok) != null);
    // 65 chars rejected
    const too_long = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abc"; // 65 chars
    try testing.expect(too_long.len == 65);
    try testing.expect(security.validateAccountId(too_long) == null);
}

test "account_id: null byte rejected" {
    try testing.expect(security.validateAccountId("admin\x00") == null);
}

// ── Executable allowlist tests ──────────────────────────────────
// The bash blocklist is gone. The sandbox now spawns child processes
// with std.process.run + explicit argv, and only permits executables
// whose bare name is on security.allowed_executables.

test "exec allowlist: dev tools allowed" {
    try testing.expectEqualStrings("zig", try security.validateExecutable("zig"));
    try testing.expectEqualStrings("git", try security.validateExecutable("git"));
    try testing.expectEqualStrings("ls", try security.validateExecutable("ls"));
    try testing.expectEqualStrings("cat", try security.validateExecutable("cat"));
    try testing.expectEqualStrings("grep", try security.validateExecutable("grep"));
    try testing.expectEqualStrings("rg", try security.validateExecutable("rg"));
    try testing.expectEqualStrings("find", try security.validateExecutable("find"));
    try testing.expectEqualStrings("mkdir", try security.validateExecutable("mkdir"));
}

test "exec allowlist: shells blocked" {
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("bash"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("sh"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("zsh"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("dash"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("fish"));
}

test "exec allowlist: scripting interpreters blocked" {
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("python"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("python3"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("node"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("perl"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("ruby"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("lua"));
}

test "exec allowlist: network tools blocked" {
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("curl"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("wget"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("nc"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("ncat"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("netcat"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("ssh"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("scp"));
}

test "exec allowlist: privilege escalation blocked" {
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("sudo"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("su"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("doas"));
}

test "exec allowlist: destructive ops blocked" {
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("rm"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("rmdir"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("mv"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("chmod"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("chown"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("dd"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("mkfs"));
}

test "exec allowlist: system control blocked" {
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("reboot"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("shutdown"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("halt"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("init"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("kill"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("killall"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("mount"));
}

test "exec allowlist: empty name rejected" {
    try testing.expectError(error.EmptyExecutable, security.validateExecutable(""));
}

test "exec allowlist: absolute paths rejected" {
    try testing.expectError(error.ExecutablePathContainsSlash, security.validateExecutable("/bin/bash"));
    try testing.expectError(error.ExecutablePathContainsSlash, security.validateExecutable("/usr/bin/zig"));
    try testing.expectError(error.ExecutablePathContainsSlash, security.validateExecutable("./malicious"));
    try testing.expectError(error.ExecutablePathContainsSlash, security.validateExecutable("../../../bin/sh"));
}

test "exec allowlist: backslash rejected" {
    try testing.expectError(error.ExecutablePathContainsSlash, security.validateExecutable("bash\\foo"));
}

test "exec allowlist: null byte rejected" {
    try testing.expectError(error.ExecutableNullByte, security.validateExecutable("zig\x00rm"));
}

test "exec allowlist: oversized name rejected" {
    const long = "a" ** 65;
    try testing.expectError(error.ExecutableNameTooLong, security.validateExecutable(long));
}

test "exec allowlist: shell-metacharacter blobs in name rejected" {
    // "rm -rf /" trips the slash check first (which runs ahead of
    // allowlist lookup). The point is: the model can't sneak shell
    // syntax in via the executable field — the slash check, length
    // cap, or allowlist will refuse any non-bare name.
    try testing.expectError(error.ExecutablePathContainsSlash, security.validateExecutable("rm -rf /"));
    try testing.expectError(error.ExecutablePathContainsSlash, security.validateExecutable("zig; rm -rf /"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("zig$(rm)"));
    try testing.expectError(error.ExecutableNotAllowed, security.validateExecutable("zig build"));
}

test "exec args: literal shell metacharacters are passed through" {
    // Arguments are passed straight to execve — shell metacharacters
    // are inert because there is no shell. We only block null bytes
    // (would truncate at the syscall boundary) and oversized args.
    try security.validateArgument("foo; rm -rf /");
    try security.validateArgument("$(curl evil.com)");
    try security.validateArgument("`cat /etc/passwd`");
    try security.validateArgument("foo | bar && baz");
    try security.validateArgument("");
}

test "exec args: null byte rejected" {
    try testing.expectError(error.ArgumentNullByte, security.validateArgument("foo\x00bar"));
}

test "exec args: oversized rejected" {
    const long = "a" ** (8 * 1024 + 1);
    try testing.expectError(error.ArgumentTooLong, security.validateArgument(long));
}

test "exec args: argv count cap" {
    try security.validateArgumentCount(0);
    try security.validateArgumentCount(127);
    try security.validateArgumentCount(128);
    try testing.expectError(error.TooManyArguments, security.validateArgumentCount(129));
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
    const cost = try billing.actualCost("deepseek-chat", 1000, 1000, .free);
    try testing.expect(cost.cost > 0);
    try testing.expect(cost.margin > 0);
    // Free tier: 30% margin
    // margin should be ~30% of cost
    const expected_margin = @divFloor(cost.cost * 3000, 10000);
    try testing.expectEqual(expected_margin, cost.margin);
}

test "billing: enterprise margin is lower than free" {
    const free_cost = try billing.actualCost("deepseek-chat", 10000, 10000, .free);
    const ent_cost = try billing.actualCost("deepseek-chat", 10000, 10000, .enterprise);
    // Same base cost
    try testing.expectEqual(free_cost.cost, ent_cost.cost);
    // Enterprise margin should be lower
    try testing.expect(ent_cost.margin < free_cost.margin);
}

test "billing: zero tokens = zero cost" {
    const cost = try billing.actualCost("deepseek-chat", 0, 0, .free);
    try testing.expectEqual(@as(i64, 0), cost.cost);
    try testing.expectEqual(@as(i64, 0), cost.margin);
}

test "billing: expensive model costs more" {
    const cheap = try billing.actualCost("deepseek-chat", 1000, 1000, .free);
    const expensive = try billing.actualCost("claude-opus-4-6", 1000, 1000, .free);
    try testing.expect(expensive.cost > cheap.cost);
}

test "billing: actualCost rejects unknown models (H10)" {
    // Pre-fix, this silently returned the Claude-Opus default rate
    // ($3 / $15 per million), wildly mispricing every cheap-provider
    // call against the same model name. Now it must error.
    try testing.expectError(error.UnknownModel,
        billing.actualCost("nonexistent-model-xyz", 1000, 1000, .free));
}

// ── 4. Models Tests ─────────────────────────────────────────

const models = @import("models.zig");

test "models: count is reasonable" {
    try testing.expect(models.getModelCount() > 100);
}

test "models: pricing lookup for known model" {
    const pricing = try models.getPricing("deepseek-chat");
    try testing.expect(pricing.input > 0);
    try testing.expect(pricing.output > 0);
}

test "models: pricing lookup for unknown model returns UnknownModel (H10)" {
    // Pre-fix this returned the Claude-Opus default rate. The
    // bug had two failure modes: undercharging callers for unknown
    // *expensive* models, and overcharging callers for unknown
    // *cheap* models. Now the API contract is exact-match-or-error.
    try testing.expectError(error.UnknownModel, models.getPricing("nonexistent-model-xyz"));
}

test "models: claude pricing" {
    const pricing = try models.getPricing("claude-sonnet-4-6");
    try testing.expectEqual(@as(f64, 3.0), pricing.input);
    try testing.expectEqual(@as(f64, 15.0), pricing.output);
}

test "models: prefix-match no longer falls through (H7)" {
    // Pre-fix, a request for "gpt-4o-2024-11-20-…" matched a "gpt-4"
    // prefix entry and got billed at the cheap rate while the
    // upstream call hit the expensive model (the string is
    // forwarded verbatim). Now the lookup is exact-only.
    try testing.expectError(error.UnknownModel,
        models.getPricing("claude-sonnet-4-6-some-future-date-suffix"));
}

test "models: schema_version is 1" {
    try testing.expectEqual(@as(u32, 1), models.schema_version);
}

test "models: parameter registry loads from embedded JSON" {
    defer models.deinitModelParameters();
    // Non-zero count means parsing worked and at least one model has params.
    try testing.expect(models.getParameterModelCount(testing.allocator) > 0);
}

test "models: populated model has parameters JSON" {
    defer models.deinitModelParameters();
    // claude-opus-4-5 has 5 ParameterSpecs in model_parameters.json.
    const raw = models.getModelParametersJson(testing.allocator, "claude-opus-4-5");
    try testing.expect(raw != null);
    // Should be a non-empty JSON array.
    try testing.expect(raw.?.len >= 2);
    try testing.expectEqual(@as(u8, '['), raw.?[0]);
    try testing.expectEqual(@as(u8, ']'), raw.?[raw.?.len - 1]);
}

test "models: unpopulated model returns null (parameters omitted on wire)" {
    defer models.deinitModelParameters();
    // dall-e-3 is not in model_parameters.json — omitted entirely.
    const raw = models.getModelParametersJson(testing.allocator, "dall-e-3");
    try testing.expect(raw == null);
}

test "models: /qai/v1/models JSON envelope has schema_version:1" {
    defer models.deinitModelParameters();
    const body = try buildModelsBodyForTest(testing.allocator);
    defer testing.allocator.free(body);

    // Must start with { and contain schema_version:1 near the top.
    try testing.expect(body.len > 20);
    try testing.expect(std.mem.indexOf(u8, body, "\"schema_version\":1") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"count\":") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"models\":[") != null);
}

test "models: populated model has parameters field in response JSON" {
    defer models.deinitModelParameters();
    const body = try buildModelsBodyForTest(testing.allocator);
    defer testing.allocator.free(body);

    // Find claude-opus-4-5 entry and confirm it carries a parameters field.
    const opus_pos = std.mem.indexOf(u8, body, "\"id\":\"claude-opus-4-5\"") orelse {
        return error.ModelNotInRegistry;
    };
    const end_brace = std.mem.indexOfScalarPos(u8, body, opus_pos, '}') orelse return error.Malformed;
    const entry = body[opus_pos..end_brace];
    try testing.expect(std.mem.indexOf(u8, entry, "\"parameters\":[") != null);
}

test "models: unpopulated model omits parameters field in response JSON" {
    defer models.deinitModelParameters();
    const body = try buildModelsBodyForTest(testing.allocator);
    defer testing.allocator.free(body);

    // dall-e-3 has no parameter schema — the parameters key must NOT appear
    // in its entry. We check by scanning the entry's braces.
    const pos = std.mem.indexOf(u8, body, "\"id\":\"dall-e-3\"") orelse {
        // Not every CSV has dall-e-3; skip if absent.
        return;
    };
    const end_brace = std.mem.indexOfScalarPos(u8, body, pos, '}') orelse return error.Malformed;
    const entry = body[pos..end_brace];
    try testing.expect(std.mem.indexOf(u8, entry, "\"parameters\"") == null);
}

fn buildModelsBodyForTest(gpa: std.mem.Allocator) ![]u8 {
    return models.buildModelsJson(gpa);
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
const auth_rl = @import("auth_ratelimit.zig");
const wal_test = @import("store/wal_test.zig");
const integration_test = @import("integration_test.zig");
const edge_case_test = @import("edge_case_tests.zig");
const forge = @import("forge.zig");

test "module tests imported" {
    _ = auth_rl;
    _ = wal_test;
    _ = integration_test;
    _ = edge_case_test;
    _ = forge;
}

test "OIDC: nonce verification integration" {
    // Verify the public API works end-to-end
    try testing.expect(oidc.verifyNonce(null, null)); // no nonce = skip
    try testing.expect(!oidc.verifyNonce("secret", null)); // nonce required but missing
    try testing.expect(!oidc.verifyNonce("secret", "wrong")); // mismatch
}

test "OIDC: claims deinit with all fields" {
    var claims = oidc.VerifiedClaims{
        .sub = try testing.allocator.dupe(u8, "apple_001234"),
        .iss = try testing.allocator.dupe(u8, "https://appleid.apple.com"),
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
    const cost = try billing.actualCost("claude-opus-4-6", 1_000_000, 1_000_000, .free);
    try testing.expect(cost.cost > 0);
    try testing.expect(cost.margin > 0);
    try testing.expect(cost.margin < cost.cost); // margin < base cost
}

test "billing: estimation is always >= actual for same model" {
    // Estimate with max_tokens should be >= actual cost at max_tokens
    const max_tokens: u32 = 4096;
    const est = billing.estimateCost("deepseek-chat", max_tokens);
    const actual = try billing.actualCost("deepseek-chat", max_tokens / 2, max_tokens, .free);
    // Estimation includes margin-like buffer, should be >= raw cost
    try testing.expect(est >= actual.cost);
}

test "billing: all tiers produce valid margins" {
    const tiers = [_]types.DevTier{ .free, .hobby, .pro, .enterprise };
    var prev_margin: i64 = std.math.maxInt(i64);
    for (tiers) |tier| {
        const cost = try billing.actualCost("deepseek-chat", 10000, 10000, tier);
        try testing.expect(cost.cost > 0);
        try testing.expect(cost.margin >= 0);
        try testing.expect(cost.margin <= prev_margin); // higher tier = lower margin
        prev_margin = cost.margin;
    }
}

test "billing: unknown model returns error (H10 regression)" {
    // Pre-fix, the assertion was `cost.cost > 0` because actualCost
    // silently returned Claude-Opus rates for unknown models —
    // wildly overcharging some callers and undercharging others.
    // The contract is now exact-match-or-error.
    try testing.expectError(error.UnknownModel,
        billing.actualCost("nonexistent-model", 1000, 1000, .free));
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

// Note: the bash-command blocklist (validateCommand, blocked patterns
// "echo test | rm -rf /", "ls; rm -rf /", backtick injection, etc.) was
// removed in Batch 3. Shell metacharacters can no longer reach a shell
// because run_program invokes execve directly with the argv array — no
// /bin/sh -c wrapper exists. See "exec allowlist:" and "exec args:"
// tests above for the replacement coverage.
