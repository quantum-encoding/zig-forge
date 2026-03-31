//! Token Service Demo
//!
//! Demonstrates using multiple zig packages together in a composable service.

const std = @import("std");
const Io = std.Io;
const token_service = @import("token_service");
const uuid = @import("uuid");
const base58 = @import("base58");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print(
        \\
        \\══════════════════════════════════════════════════════════════════
        \\              Zig Token Service v{s}
        \\     Combining: UUID + JWT + RateLimiter + Metrics + Bloom
        \\══════════════════════════════════════════════════════════════════
        \\
        \\
    , .{token_service.version});

    // Show package versions
    try stdout.print("Loaded packages:\n", .{});
    try stdout.print("  - zig_uuid      - UUID generation\n", .{});
    try stdout.print("  - zig_jwt       - JSON Web Tokens\n", .{});
    try stdout.print("  - zig_ratelimit - Rate limiting\n", .{});
    try stdout.print("  - zig_metrics   - Prometheus metrics\n", .{});
    try stdout.print("  - zig_bloom     - Bloom filters\n", .{});
    try stdout.print("  - zig_base58    - Base58 encoding\n", .{});
    try stdout.print("\n", .{});

    // Initialize service
    try stdout.print("Initializing token service...\n", .{});
    var service = try token_service.TokenService.init(arena, .{
        .secret = "super-secret-key-for-jwt-signing",
        .access_ttl = 3600,
        .refresh_ttl = 86400 * 7,
        .rate_limit = 100.0,
        .burst_capacity = 200.0,
    });
    defer service.deinit();
    try stdout.print("  [OK] Service initialized\n\n", .{});

    // Demo: Issue tokens for users
    try stdout.print("=== Issuing Tokens ===\n\n", .{});

    const users = [_][]const u8{ "alice", "bob", "charlie" };

    for (users) |user| {
        try stdout.print("User: {s}\n", .{user});

        const result = try service.issueToken(user);
        defer result.deinit(arena);

        try stdout.print("  Session:  {s}\n", .{result.session_id});
        try stdout.print("  Access:   {s}...{s}\n", .{
            result.access_token[0..20],
            result.access_token[result.access_token.len - 10 ..],
        });
        try stdout.print("  Refresh:  {s}...{s}\n", .{
            result.refresh_token[0..20],
            result.refresh_token[result.refresh_token.len - 10 ..],
        });
        try stdout.print("  Expires:  {d} seconds\n\n", .{result.expires_in});
    }

    // Demo: Verify a token
    try stdout.print("=== Token Verification ===\n\n", .{});

    const test_result = try service.issueToken("test_user");
    defer test_result.deinit(arena);

    try stdout.print("Verifying token for test_user...\n", .{});
    const verify = try service.verifyToken(test_result.access_token);
    defer verify.deinit(arena);

    try stdout.print("  [OK] Token valid\n", .{});
    try stdout.print("  User ID:    {s}\n", .{verify.user_id});
    try stdout.print("  Issued at:  {d}\n", .{verify.issued_at});
    try stdout.print("  Expires at: {d}\n\n", .{verify.expires_at});

    // Demo: Revoke a token
    try stdout.print("=== Token Revocation ===\n\n", .{});

    try stdout.print("Revoking token...\n", .{});
    service.revokeToken(test_result.access_token);
    try stdout.print("  [OK] Token added to revocation bloom filter\n\n", .{});

    // Try to verify revoked token
    try stdout.print("Verifying revoked token...\n", .{});
    if (service.verifyToken(test_result.access_token)) |_| {
        try stdout.print("  [FAIL] Token should have been rejected!\n", .{});
    } else |err| {
        try stdout.print("  [OK] Token rejected: {}\n\n", .{err});
    }

    // Demo: Direct UUID usage
    try stdout.print("=== Direct Package Usage ===\n\n", .{});

    // UUID
    const id = uuid.v4();
    try stdout.print("UUID v4:     {s}\n", .{id.toString()});
    try stdout.print("UUID v7:     {s}\n", .{uuid.v7().toString()});

    // Base58
    const data = "Hello, Zig packages!";
    const encoded = try base58.encode(arena, data);
    try stdout.print("Base58:      \"{s}\" -> {s}\n\n", .{ data, encoded });

    // Demo: Metrics summary
    try stdout.print("=== Metrics Summary ===\n\n", .{});
    try stdout.print("  tokens_issued:   {d}\n", .{service.tokens_issued.get()});
    try stdout.print("  tokens_verified: {d}\n", .{service.tokens_verified.get()});
    try stdout.print("  tokens_rejected: {d}\n", .{service.tokens_rejected.get()});
    try stdout.print("  tokens_revoked:  {d}\n", .{service.tokens_revoked.get()});
    try stdout.print("  active_sessions: {d}\n\n", .{service.active_sessions.get()});

    try stdout.print(
        \\===================================================================
        \\  Token Service demo complete!
        \\  This demonstrates composable Zig packages working together.
        \\===================================================================
        \\
        \\
    , .{});

    try stdout.flush();
}
