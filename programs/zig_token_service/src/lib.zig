//! Token Service - A composable authentication service
//!
//! Demonstrates using multiple zig packages together:
//! - zig_uuid: Generate unique session/token IDs
//! - zig_jwt: Create and verify JWT tokens
//! - zig_ratelimit: Prevent brute-force attacks
//! - zig_metrics: Track authentication metrics
//! - zig_bloom: Fast token revocation checking
//! - zig_base58: Encode tokens for URLs/display

const std = @import("std");
const uuid = @import("uuid");
const jwt = @import("jwt");
const ratelimit = @import("ratelimit");
const metrics = @import("metrics");
const bloom = @import("bloom");
const base58 = @import("base58");

pub const version = "0.1.0";

/// Get current Unix timestamp (Zig 0.16 compatible using std.c.clock_gettime)
fn getUnixTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    const result = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    if (result == 0) {
        return ts.sec;
    }
    return 0;
}

/// Token Service configuration
pub const Config = struct {
    /// Secret key for signing JWTs
    secret: []const u8,
    /// Access token TTL in seconds
    access_ttl: i64 = 3600, // 1 hour
    /// Refresh token TTL in seconds
    refresh_ttl: i64 = 86400 * 7, // 7 days
    /// Rate limit: requests per second
    rate_limit: f64 = 10.0,
    /// Rate limit burst capacity
    burst_capacity: f64 = 20.0,
    /// Expected number of revoked tokens (for bloom filter sizing)
    expected_revocations: usize = 10000,
    /// False positive rate for revocation checks
    false_positive_rate: f64 = 0.01,
};

/// Token Service - combines multiple libraries for auth
pub const TokenService = struct {
    allocator: std.mem.Allocator,
    config: Config,
    rate_limiter: ratelimit.TokenBucket,
    revocation_filter: bloom.BloomFilter([]const u8),

    // Metrics
    tokens_issued: metrics.Counter,
    tokens_verified: metrics.Counter,
    tokens_rejected: metrics.Counter,
    tokens_revoked: metrics.Counter,
    active_sessions: metrics.Gauge,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
        // Input validation
        if (config.secret.len == 0 or config.secret.len > 512) {
            return error.InvalidSecretKeyLength;
        }

        // Initialize rate limiter
        const rate_limiter = ratelimit.createLimiter(config.burst_capacity, config.rate_limit);

        // Initialize bloom filter for revocation
        const revocation_filter = try bloom.BloomFilter([]const u8).initCapacity(
            allocator,
            config.expected_revocations,
            config.false_positive_rate,
        );

        return Self{
            .allocator = allocator,
            .config = config,
            .rate_limiter = rate_limiter,
            .revocation_filter = revocation_filter,
            .tokens_issued = metrics.Counter.init("tokens_issued_total", "Total tokens issued"),
            .tokens_verified = metrics.Counter.init("tokens_verified_total", "Total tokens verified"),
            .tokens_rejected = metrics.Counter.init("tokens_rejected_total", "Total tokens rejected"),
            .tokens_revoked = metrics.Counter.init("tokens_revoked_total", "Total tokens revoked"),
            .active_sessions = metrics.Gauge.init("active_sessions", "Currently active sessions"),
        };
    }

    pub fn deinit(self: *Self) void {
        self.revocation_filter.deinit();
    }

    /// Issue a new access token for a user
    pub fn issueToken(self: *Self, user_id: []const u8) !TokenResult {
        // Input validation
        if (user_id.len == 0 or user_id.len > 256) {
            self.tokens_rejected.inc();
            return error.InvalidSubject;
        }

        // Check rate limit
        if (!self.rate_limiter.tryAcquireOne()) {
            self.tokens_rejected.inc();
            return error.RateLimitExceeded;
        }

        // Generate session ID
        const session_uuid = uuid.v4();
        const session_id = session_uuid.toString();

        // Create access token
        const access_token = try jwt.quickSign(
            self.allocator,
            user_id,
            "token-service",
            self.config.access_ttl,
            .HS256,
            self.config.secret,
        );

        // Create refresh token
        const refresh_token = try jwt.quickSign(
            self.allocator,
            user_id,
            "token-service",
            self.config.refresh_ttl,
            .HS256,
            self.config.secret,
        );

        // Encode session ID as base58 for display
        const session_b58 = try base58.encode(self.allocator, &session_id);

        // Update metrics
        self.tokens_issued.add(2); // access + refresh
        self.active_sessions.inc();

        return TokenResult{
            .access_token = access_token,
            .refresh_token = refresh_token,
            .session_id = session_b58,
            .expires_in = self.config.access_ttl,
        };
    }

    /// Verify a token and return claims if valid
    pub fn verifyToken(self: *Self, token: []const u8) !VerifyResult {
        // Check rate limit
        if (!self.rate_limiter.tryAcquireOne()) {
            self.tokens_rejected.inc();
            return error.RateLimitExceeded;
        }

        // Check if token is revoked (bloom filter check)
        if (self.revocation_filter.contains(token)) {
            self.tokens_rejected.inc();
            return error.TokenRevoked;
        }

        // Verify JWT signature and decode
        var claims = jwt.quickVerify(self.allocator, token, .HS256, self.config.secret) catch {
            self.tokens_rejected.inc();
            return error.InvalidToken;
        };
        defer claims.deinit();

        // Check expiration
        const now = getUnixTimestamp();
        if (claims.exp) |exp| {
            if (exp < now) {
                self.tokens_rejected.inc();
                return error.TokenExpired;
            }
        }

        self.tokens_verified.inc();

        return VerifyResult{
            .user_id = try self.allocator.dupe(u8, claims.sub orelse ""),
            .expires_at = claims.exp orelse 0,
            .issued_at = claims.iat orelse 0,
        };
    }

    /// Revoke a token (add to bloom filter)
    pub fn revokeToken(self: *Self, token: []const u8) void {
        self.revocation_filter.add(token);
        self.tokens_revoked.inc();
        self.active_sessions.dec();
    }

    /// Get Prometheus-formatted metrics
    pub fn getMetrics(self: *Self, writer: anytype) !void {
        try self.tokens_issued.write(writer);
        try writer.writeAll("\n");
        try self.tokens_verified.write(writer);
        try writer.writeAll("\n");
        try self.tokens_rejected.write(writer);
        try writer.writeAll("\n");
        try self.tokens_revoked.write(writer);
        try writer.writeAll("\n");
        try self.active_sessions.write(writer);
        try writer.writeAll("\n");
    }
};

pub const TokenResult = struct {
    access_token: []const u8,
    refresh_token: []const u8,
    session_id: []const u8,
    expires_in: i64,

    pub fn deinit(self: TokenResult, allocator: std.mem.Allocator) void {
        allocator.free(self.access_token);
        allocator.free(self.refresh_token);
        allocator.free(self.session_id);
    }
};

pub const VerifyResult = struct {
    user_id: []const u8,
    expires_at: i64,
    issued_at: i64,

    pub fn deinit(self: VerifyResult, allocator: std.mem.Allocator) void {
        allocator.free(self.user_id);
    }
};

// Re-export dependencies for convenience
pub const UUID = uuid.UUID;
pub const JWT = jwt;
pub const RateLimiter = ratelimit.TokenBucket;
pub const BloomFilter = bloom.BloomFilter;
pub const Metrics = metrics;
pub const Base58 = base58;

// =============================================================================
// COMPREHENSIVE TESTS
// =============================================================================

test "TokenService initialization with valid config" {
    const allocator = std.heap.c_allocator;

    var service = try TokenService.init(allocator, .{
        .secret = "test-secret-key-at-least-32-chars",
        .access_ttl = 3600,
        .refresh_ttl = 86400,
    });
    defer service.deinit();

    try std.testing.expect(service.config.access_ttl == 3600);
    try std.testing.expect(service.config.refresh_ttl == 86400);
}

test "TokenService rejects empty secret" {
    const allocator = std.heap.c_allocator;

    const result = TokenService.init(allocator, .{
        .secret = "",
    });

    try std.testing.expectError(error.InvalidSecretKeyLength, result);
}

test "TokenService rejects secret that's too long" {
    const allocator = std.heap.c_allocator;

    var long_secret: [513]u8 = undefined;
    @memset(&long_secret, 'a');

    const result = TokenService.init(allocator, .{
        .secret = &long_secret,
    });

    try std.testing.expectError(error.InvalidSecretKeyLength, result);
}

test "Issue token with valid user ID" {
    const allocator = std.heap.c_allocator;

    var service = try TokenService.init(allocator, .{
        .secret = "test-secret-key-at-least-32-chars",
    });
    defer service.deinit();

    const result = try service.issueToken("test_user");
    defer result.deinit(allocator);

    try std.testing.expect(result.access_token.len > 0);
    try std.testing.expect(result.refresh_token.len > 0);
    try std.testing.expect(result.session_id.len > 0);
    try std.testing.expect(result.expires_in == 3600);
}

test "Issue token rejects empty user ID" {
    const allocator = std.heap.c_allocator;

    var service = try TokenService.init(allocator, .{
        .secret = "test-secret-key-at-least-32-chars",
    });
    defer service.deinit();

    const result = service.issueToken("");
    try std.testing.expectError(error.InvalidSubject, result);
}

test "Issue token rejects user ID that's too long" {
    const allocator = std.heap.c_allocator;

    var service = try TokenService.init(allocator, .{
        .secret = "test-secret-key-at-least-32-chars",
    });
    defer service.deinit();

    var long_user: [257]u8 = undefined;
    @memset(&long_user, 'a');

    const result = service.issueToken(&long_user);
    try std.testing.expectError(error.InvalidSubject, result);
}

test "Verify freshly issued token succeeds" {
    const allocator = std.heap.c_allocator;

    var service = try TokenService.init(allocator, .{
        .secret = "test-secret-key-at-least-32-chars",
    });
    defer service.deinit();

    const token_result = try service.issueToken("alice");
    defer token_result.deinit(allocator);

    const verify_result = try service.verifyToken(token_result.access_token);
    defer verify_result.deinit(allocator);

    const user_slice = verify_result.user_id;
    try std.testing.expectEqualSlices(u8, user_slice, "alice");
    try std.testing.expect(verify_result.expires_at > 0);
}

test "Revoked token fails verification" {
    const allocator = std.heap.c_allocator;

    var service = try TokenService.init(allocator, .{
        .secret = "test-secret-key-at-least-32-chars",
    });
    defer service.deinit();

    const token_result = try service.issueToken("bob");
    defer token_result.deinit(allocator);

    // Verify before revocation (just check it returns without error)
    {
        const verify_result = try service.verifyToken(token_result.access_token);
        defer verify_result.deinit(allocator);
    }

    // Revoke the token
    service.revokeToken(token_result.access_token);

    // Verify after revocation should fail
    const verify_result = service.verifyToken(token_result.access_token);
    try std.testing.expectError(error.TokenRevoked, verify_result);
}

test "Rate limiting prevents excessive token issuance" {
    const allocator = std.heap.c_allocator;

    var service = try TokenService.init(allocator, .{
        .secret = "test-secret-key-at-least-32-chars",
        .rate_limit = 2.0, // Very low rate limit
        .burst_capacity = 2.0,
    });
    defer service.deinit();

    // First two should succeed (burst)
    {
        const r1 = try service.issueToken("user1");
        r1.deinit(allocator);
    }
    {
        const r2 = try service.issueToken("user2");
        r2.deinit(allocator);
    }

    // Third should fail due to rate limit
    const result = service.issueToken("user3");
    try std.testing.expectError(error.RateLimitExceeded, result);
}

test "Metrics track token issuance" {
    const allocator = std.heap.c_allocator;

    var service = try TokenService.init(allocator, .{
        .secret = "test-secret-key-at-least-32-chars",
        .rate_limit = 100.0,
    });
    defer service.deinit();

    const initial = service.tokens_issued.get();

    const token_result = try service.issueToken("user");
    defer token_result.deinit(allocator);

    const after = service.tokens_issued.get();
    try std.testing.expect(after == initial + 2); // access + refresh
}

test "Metrics track token verification" {
    const allocator = std.heap.c_allocator;

    var service = try TokenService.init(allocator, .{
        .secret = "test-secret-key-at-least-32-chars",
    });
    defer service.deinit();

    const token_result = try service.issueToken("user");
    defer token_result.deinit(allocator);

    const initial = service.tokens_verified.get();

    // Verify token
    const verify_result = try service.verifyToken(token_result.access_token);
    defer verify_result.deinit(allocator);

    const after = service.tokens_verified.get();
    try std.testing.expect(after == initial + 1);
}

test "Metrics track token revocation" {
    const allocator = std.heap.c_allocator;

    var service = try TokenService.init(allocator, .{
        .secret = "test-secret-key-at-least-32-chars",
    });
    defer service.deinit();

    const token_result = try service.issueToken("user");
    defer token_result.deinit(allocator);

    const initial = service.tokens_revoked.get();

    service.revokeToken(token_result.access_token);

    const after = service.tokens_revoked.get();
    try std.testing.expect(after == initial + 1);
}

test "Bloom filter detects revoked tokens" {
    const allocator = std.heap.c_allocator;

    var service = try TokenService.init(allocator, .{
        .secret = "test-secret-key-at-least-32-chars",
    });
    defer service.deinit();

    const token_result = try service.issueToken("user");
    defer token_result.deinit(allocator);

    // Token should not be in revocation filter yet
    try std.testing.expect(!service.revocation_filter.contains(token_result.access_token));

    // Add to revocation filter
    service.revocation_filter.add(token_result.access_token);

    // Now it should be in the filter
    try std.testing.expect(service.revocation_filter.contains(token_result.access_token));
}

test "JWT token structure is valid" {
    const allocator = std.heap.c_allocator;

    var service = try TokenService.init(allocator, .{
        .secret = "test-secret-key-at-least-32-chars",
    });
    defer service.deinit();

    const token_result = try service.issueToken("testuser");
    defer token_result.deinit(allocator);

    const token = token_result.access_token;

    // JWT should have format: header.payload.signature (exactly 2 dots)
    var dot_count: usize = 0;
    var first_dot: ?usize = null;
    var second_dot: ?usize = null;

    for (token, 0..) |c, i| {
        if (c == '.') {
            dot_count += 1;
            if (first_dot == null) {
                first_dot = i;
            } else if (second_dot == null) {
                second_dot = i;
            }
        }
    }

    try std.testing.expect(dot_count == 2);
    try std.testing.expect(first_dot != null and first_dot.? > 0);
    try std.testing.expect(second_dot != null and second_dot.? > first_dot.?);
}

test "UUID generation produces valid UUIDs" {
    const allocator = std.heap.c_allocator;

    var service = try TokenService.init(allocator, .{
        .secret = "test-secret-key-at-least-32-chars",
    });
    defer service.deinit();

    const token_result = try service.issueToken("user");
    defer token_result.deinit(allocator);

    // Session ID should be a valid base58 string
    try std.testing.expect(token_result.session_id.len > 0);

    // Base58 uses specific characters
    const base58_chars = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    for (token_result.session_id) |c| {
        var found = false;
        for (base58_chars) |valid_c| {
            if (c == valid_c) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "Multiple users can have active sessions" {
    const allocator = std.heap.c_allocator;

    var service = try TokenService.init(allocator, .{
        .secret = "test-secret-key-at-least-32-chars",
        .rate_limit = 100.0,
    });
    defer service.deinit();

    const result1 = try service.issueToken("alice");
    defer result1.deinit(allocator);

    const result2 = try service.issueToken("bob");
    defer result2.deinit(allocator);

    const result3 = try service.issueToken("charlie");
    defer result3.deinit(allocator);

    try std.testing.expect(service.active_sessions.get() == 3);

    // Verify token structure - check for JWT format without full parsing
    try std.testing.expect(result1.access_token.len > 0);
    try std.testing.expect(result2.access_token.len > 0);
    try std.testing.expect(result3.access_token.len > 0);
}
