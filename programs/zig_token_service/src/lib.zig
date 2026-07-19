//! Token Service - A composable authentication service
//!
//! Demonstrates using multiple zig packages together:
//! - zig_uuid: Generate unique session/token IDs
//! - zig_jwt: Create and verify JWT tokens
//! - zig_ratelimit: Prevent brute-force attacks
//! - zig_metrics: Track authentication metrics
//! - zig_bloom: Fast token revocation checking
//! - zig_base58: Encode tokens for URLs/display
//!
//! This is the SERVER-SIDE path and the only one that is a trust boundary.
//! All JWT crypto and JSON serialization are delegated to `zig_jwt` (a
//! canonical/promoted library) — nothing is hand-rolled here. Verification
//! pins HS256, enforces the configured issuer, and evaluates expiry against
//! an injected clock (`Config.now_fn`) rather than reading the wall clock at
//! the check site. The separate WASM module (`src/wasm_ffi.zig`) holds its
//! secret in browser memory and is explicitly NOT a security boundary; tokens
//! it mints or accepts must be re-verified here.

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

/// Clock used for issuing (`iat`/`exp`) and for expiry validation. Injected
/// rather than read from the host so expiry logic is testable without moving
/// the system clock (zig-forge CLAUDE.md anti-pattern #6). Overriding it can
/// only move the evaluated "now" — every other check (signature, issuer,
/// revocation, rate limit) is unaffected, so a hostile override still fails
/// closed on a token it cannot sign.
pub const NowFn = jwt.NowFn;

/// Token Service configuration
pub const Config = struct {
    /// Secret key for signing JWTs
    secret: []const u8,
    /// Issuer (`iss`) stamped on every minted token AND required on every
    /// verified token. Without this, any token signed with the same secret by
    /// an unrelated service would verify here.
    issuer: []const u8 = "token-service",
    /// Time source for iat/exp and for expiry validation (see NowFn).
    now_fn: NowFn = &getUnixTimestamp,
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

    /// Sign one HS256 token for `user_id` with iat=`now`, exp=`now + ttl`.
    /// All crypto and JSON serialization happen inside the audited `zig_jwt`
    /// (canonical library) — nothing is hand-rolled here.
    fn signFor(self: *Self, user_id: []const u8, now: i64, ttl: i64) ![]u8 {
        var builder = jwt.Builder.init(self.allocator);
        defer builder.deinit();

        try builder.setSubject(user_id);
        try builder.setIssuer(self.config.issuer);
        builder.setIssuedAt(now);
        builder.setExpiration(now + ttl);

        return try builder.sign(.HS256, self.config.secret);
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

        // Generate session ID. zig_uuid's v4 draws its 16 bytes from the OS
        // CSPRNG (arc4random_buf / getrandom(2)) — never a clock- or
        // address-seeded PRNG.
        const session_uuid = uuid.v4();
        const session_id = session_uuid.toString();

        // Mint both tokens off the SAME injected clock reading so iat/exp are
        // consistent between access and refresh, and so tests can pin time.
        // (jwt.quickSign reads the host clock directly, hence the Builder.)
        const now = self.config.now_fn();

        const access_token = try self.signFor(user_id, now, self.config.access_ttl);
        errdefer self.allocator.free(access_token);

        const refresh_token = try self.signFor(user_id, now, self.config.refresh_ttl);
        errdefer self.allocator.free(refresh_token);

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

        // Verify JWT signature and validate claims. The Verifier enforces
        // HS256 (alg confusion and `alg:none` are refused inside zig_jwt),
        // exp/nbf against the INJECTED clock, and the expected issuer — a
        // token signed with this secret by a different issuer is rejected.
        // There is no second, redundant expiry check here: `validate_exp`
        // above is the single source of truth for expiry.
        var verifier = jwt.Verifier.init(self.allocator);
        defer verifier.deinit();
        verifier.now_fn = self.config.now_fn;
        try verifier.setIssuer(self.config.issuer);

        var claims = verifier.verify(token, .HS256, self.config.secret) catch |err| {
            self.tokens_rejected.inc();
            // Preserve the expiry distinction callers already depend on;
            // everything else collapses to InvalidToken so verification
            // failures do not leak which check tripped.
            return switch (err) {
                error.TokenExpired => error.TokenExpired,
                else => error.InvalidToken,
            };
        };
        defer claims.deinit();

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
// TIER-1 EXTERNAL ANCHORS
//
// Per zig-forge CLAUDE.md golden rule §1, the tests below take BOTH inputs and
// expected outputs from sources this repo did not author:
//
//   - RFC 7515 Appendix A.1: the spec's HS256 example — its JWK octet key, its
//     exact serialized token, and its stated claims. Verified end-to-end
//     through TokenService.verifyToken (not just the jwt library), which is
//     what proves the service's Verifier wiring (HS256 pinning, issuer check,
//     injected clock) is correct.
//   - An INDEPENDENT signer built from std.crypto.auth.hmac.sha2.HmacSha256 +
//     std.base64.url_safe_no_pad, so the verifier is exercised against a token
//     this library did not construct.
//
// Both are non-roundtrip: deleting every `issueToken`-then-`verifyToken` test
// would leave verification still covered.
// =============================================================================

/// Fixed clock: one second before the RFC 7515 A.1 example token's `exp`
/// (1300819380), so the spec token is live rather than expired.
fn rfc7515ClockBeforeExp() i64 {
    return 1300819379;
}

/// Fixed clock: one second after that same `exp`.
fn rfc7515ClockAfterExp() i64 {
    return 1300819381;
}

/// The RFC 7515 A.1 HMAC key, given in the spec as a JWK `k` (base64url).
fn rfc7515Key(out: *[64]u8) ![]const u8 {
    const k = "AyM1SysPpbyDfgZld3umj1qzKObwVMkoqQ-EstJQLr_T-1qS0gZH75aKtMN3Yj0iPS4hcgUuTwjAzZr1Z9CAow";
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const n = try decoder.calcSizeForSlice(k);
    try decoder.decode(out[0..n], k);
    return out[0..n];
}

/// The exact token serialized in RFC 7515 Appendix A.1.
const rfc7515_token = "eyJ0eXAiOiJKV1QiLA0KICJhbGciOiJIUzI1NiJ9." ++
    "eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ." ++
    "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";

test "anchor: RFC 7515 A.1 spec token verifies through TokenService" {
    const allocator = std.heap.c_allocator;

    var key_buf: [64]u8 = undefined;
    const key = try rfc7515Key(&key_buf);

    var service = try TokenService.init(allocator, .{
        .secret = key,
        .issuer = "joe", // the spec token's `iss`
        .now_fn = &rfc7515ClockBeforeExp,
    });
    defer service.deinit();

    const result = try service.verifyToken(rfc7515_token);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(i64, 1300819380), result.expires_at);
}

test "anchor: RFC 7515 A.1 token with one flipped signature byte is rejected" {
    const allocator = std.heap.c_allocator;

    var key_buf: [64]u8 = undefined;
    const key = try rfc7515Key(&key_buf);

    var service = try TokenService.init(allocator, .{
        .secret = key,
        .issuer = "joe",
        .now_fn = &rfc7515ClockBeforeExp,
    });
    defer service.deinit();

    // Final signature character 'k' -> 'j'.
    const tampered = rfc7515_token[0 .. rfc7515_token.len - 1] ++ "j";
    try std.testing.expectError(error.InvalidToken, service.verifyToken(tampered));
}

test "anchor: RFC 7515 A.1 token expires against the INJECTED clock" {
    const allocator = std.heap.c_allocator;

    var key_buf: [64]u8 = undefined;
    const key = try rfc7515Key(&key_buf);

    var service = try TokenService.init(allocator, .{
        .secret = key,
        .issuer = "joe",
        .now_fn = &rfc7515ClockAfterExp, // one second past exp
    });
    defer service.deinit();

    try std.testing.expectError(error.TokenExpired, service.verifyToken(rfc7515_token));
}

test "anchor: a token signed by an INDEPENDENT std.crypto signer verifies" {
    const allocator = std.heap.c_allocator;

    const secret = "test-secret-key-at-least-32-chars";
    const header = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const payload = "{\"iss\":\"token-service\",\"sub\":\"external-alice\",\"exp\":2000000000}";

    // Build header.payload with std's base64url — nothing from this repo.
    const enc = std.base64.url_safe_no_pad.Encoder;
    var signing_input: [256]u8 = undefined;
    var n = enc.encode(&signing_input, header).len;
    signing_input[n] = '.';
    n += 1;
    n += enc.encode(signing_input[n..], payload).len;

    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, signing_input[0..n], secret);

    var token_buf: [384]u8 = undefined;
    @memcpy(token_buf[0..n], signing_input[0..n]);
    token_buf[n] = '.';
    const total = n + 1 + enc.encode(token_buf[n + 1 ..], &mac).len;

    var service = try TokenService.init(allocator, .{
        .secret = secret,
        .now_fn = &rfc7515ClockBeforeExp, // well before exp=2000000000
    });
    defer service.deinit();

    const result = try service.verifyToken(token_buf[0..total]);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("external-alice", result.user_id);
}

test "a token from a DIFFERENT issuer signed with the same secret is rejected" {
    const allocator = std.heap.c_allocator;

    const secret = "test-secret-key-at-least-32-chars";

    // Mint under issuer "other-service"...
    var minter = try TokenService.init(allocator, .{
        .secret = secret,
        .issuer = "other-service",
    });
    defer minter.deinit();

    const minted = try minter.issueToken("mallory");
    defer minted.deinit(allocator);

    // ...and present it to a service that expects the default issuer.
    var service = try TokenService.init(allocator, .{ .secret = secret });
    defer service.deinit();

    try std.testing.expectError(error.InvalidToken, service.verifyToken(minted.access_token));
}

test "expiry is evaluated against the injected clock, not the host clock" {
    const allocator = std.heap.c_allocator;

    const Clock = struct {
        var now: i64 = 1_700_000_000;
        fn read() i64 {
            return now;
        }
    };
    Clock.now = 1_700_000_000;

    var service = try TokenService.init(allocator, .{
        .secret = "test-secret-key-at-least-32-chars",
        .access_ttl = 60,
        .now_fn = &Clock.read,
    });
    defer service.deinit();

    const issued = try service.issueToken("carol");
    defer issued.deinit(allocator);

    // Still inside the TTL.
    {
        const ok = try service.verifyToken(issued.access_token);
        defer ok.deinit(allocator);
        try std.testing.expectEqualStrings("carol", ok.user_id);
    }

    // Move the injected clock past exp — no system clock was touched.
    Clock.now = 1_700_000_000 + 61;
    try std.testing.expectError(error.TokenExpired, service.verifyToken(issued.access_token));
}

test "alg:none token is refused even when the payload is otherwise valid" {
    const allocator = std.heap.c_allocator;

    const enc = std.base64.url_safe_no_pad.Encoder;
    var token_buf: [256]u8 = undefined;
    var n = enc.encode(&token_buf, "{\"alg\":\"none\",\"typ\":\"JWT\"}").len;
    token_buf[n] = '.';
    n += 1;
    n += enc.encode(token_buf[n..], "{\"iss\":\"token-service\",\"sub\":\"root\",\"exp\":2000000000}").len;
    token_buf[n] = '.'; // empty signature, as RFC 7519 §6 unsecured JWTs use
    n += 1;

    var service = try TokenService.init(allocator, .{
        .secret = "test-secret-key-at-least-32-chars",
    });
    defer service.deinit();

    try std.testing.expectError(error.InvalidToken, service.verifyToken(token_buf[0..n]));
}

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
