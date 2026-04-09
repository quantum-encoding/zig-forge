// Auth endpoint rate limiter — IP-keyed, prevents sign-in brute force.
// Keyed by client IP (extracted from X-Forwarded-For on Cloud Run).
// Default: 10 requests/minute per IP on /qai/v1/auth/* endpoints.
//
// Separate from the per-API-key RateLimiter in ratelimit.zig because
// auth requests don't have an API key yet.

const std = @import("std");
const http = std.http;
const types = @import("store/types.zig");

const SpinLock = struct {
    state: std.atomic.Value(u32) = .init(0),
    pub fn lock(self: *SpinLock) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null)
            std.atomic.spinLoopHint();
    }
    pub fn unlock(self: *SpinLock) void {
        self.state.store(0, .release);
    }
};

/// Default rate limit: 10 requests/minute per IP on auth endpoints.
const DEFAULT_AUTH_RPM: u32 = 10;

/// Max unique IPs tracked (bounded to prevent memory exhaustion from spam).
const MAX_IP_BUCKETS: usize = 4096;

const Bucket = struct {
    tokens: i64,
    last_refill: i64,
};

/// IPv4/IPv6 address as a fixed-size key. We hash the raw string so IPv6
/// works without parsing. Truncated to 64 bytes (enough for any valid IP).
const IpKey = [64]u8;

pub const AuthRateLimiter = struct {
    allocator: std.mem.Allocator,
    mutex: SpinLock = .{},
    buckets: std.HashMapUnmanaged(IpKey, Bucket, IpKeyContext, std.hash_map.default_max_load_percentage) = .empty,
    rate_rpm: u32 = DEFAULT_AUTH_RPM,

    const IpKeyContext = struct {
        pub fn hash(_: @This(), key: IpKey) u64 {
            return std.hash.Wyhash.hash(0, &key);
        }
        pub fn eql(_: @This(), a: IpKey, b: IpKey) bool {
            return std.mem.eql(u8, &a, &b);
        }
    };

    pub fn init(allocator: std.mem.Allocator) AuthRateLimiter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AuthRateLimiter) void {
        self.buckets.deinit(self.allocator);
    }

    /// Check if a request is allowed for the given IP.
    /// Returns true if allowed, false if rate limited.
    pub fn check(self: *AuthRateLimiter, ip: []const u8) bool {
        var key: IpKey = .{0} ** 64;
        const copy_len = @min(ip.len, key.len);
        @memcpy(key[0..copy_len], ip[0..copy_len]);

        self.mutex.lock();
        defer self.mutex.unlock();

        const now = types.nowMs();

        if (self.buckets.getPtr(key)) |bucket| {
            // Refill: rate_rpm tokens per 60 counter ticks
            const elapsed = now - bucket.last_refill;
            if (elapsed > 0) {
                const refill = @divFloor(@as(i64, self.rate_rpm) * elapsed, 60);
                bucket.tokens = @min(bucket.tokens + refill, @as(i64, self.rate_rpm));
                bucket.last_refill = now;
            }
            if (bucket.tokens > 0) {
                bucket.tokens -= 1;
                return true;
            }
            return false;
        }

        // Cap total buckets to prevent memory blowup from IP spam
        if (self.buckets.count() >= MAX_IP_BUCKETS) {
            // Evict a random bucket (simple LRU would be better but this is fine for now)
            var iter = self.buckets.iterator();
            if (iter.next()) |entry| {
                _ = self.buckets.remove(entry.key_ptr.*);
            }
        }

        // First request from this IP — full bucket minus 1
        self.buckets.put(self.allocator, key, .{
            .tokens = @as(i64, self.rate_rpm) - 1,
            .last_refill = now,
        }) catch return true; // OOM: fail open
        return true;
    }
};

/// Extract client IP from request headers.
/// On Cloud Run, the real client IP is in X-Forwarded-For (first entry).
/// Fallback: empty string (will all share the same bucket — safe but shared).
pub fn extractClientIp(request: *const http.Server.Request) []const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-forwarded-for")) {
            // First IP in the comma-separated list is the original client
            const value = std.mem.trim(u8, header.value, " ");
            if (std.mem.indexOfScalar(u8, value, ',')) |comma| {
                return std.mem.trim(u8, value[0..comma], " ");
            }
            return value;
        }
    }
    return "";
}

// ── Tests ──────────────────────────────────────────────────────

test "auth rate limiter: allows first N requests" {
    var rl = AuthRateLimiter.init(std.testing.allocator);
    defer rl.deinit();

    // First 10 requests from 1.2.3.4 should succeed
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        try std.testing.expect(rl.check("1.2.3.4"));
    }
}

test "auth rate limiter: blocks 11th request" {
    var rl = AuthRateLimiter.init(std.testing.allocator);
    defer rl.deinit();

    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        _ = rl.check("1.2.3.4");
    }
    // 11th should be blocked
    try std.testing.expect(!rl.check("1.2.3.4"));
}

test "auth rate limiter: separate buckets per IP" {
    var rl = AuthRateLimiter.init(std.testing.allocator);
    defer rl.deinit();

    // Drain IP 1
    var i: u32 = 0;
    while (i < 10) : (i += 1) _ = rl.check("1.1.1.1");
    try std.testing.expect(!rl.check("1.1.1.1"));

    // IP 2 should be unaffected
    try std.testing.expect(rl.check("2.2.2.2"));
}

test "auth rate limiter: empty IP shares bucket (fail-safe)" {
    var rl = AuthRateLimiter.init(std.testing.allocator);
    defer rl.deinit();

    // Empty IP is allowed but shares one bucket with all other empty IPs
    try std.testing.expect(rl.check(""));
}

test "auth rate limiter: IPv6 address" {
    var rl = AuthRateLimiter.init(std.testing.allocator);
    defer rl.deinit();

    const ipv6 = "2001:db8::1";
    try std.testing.expect(rl.check(ipv6));
    // Different from IPv4
    try std.testing.expect(rl.check("1.2.3.4"));
}

test "auth rate limiter: bucket cap prevents memory blowup" {
    var rl = AuthRateLimiter.init(std.testing.allocator);
    defer rl.deinit();

    // Fill past the cap
    var buf: [32]u8 = undefined;
    var i: u32 = 0;
    while (i < MAX_IP_BUCKETS + 100) : (i += 1) {
        const ip = try std.fmt.bufPrint(&buf, "10.0.{d}.{d}", .{ i / 256, i % 256 });
        _ = rl.check(ip);
    }
    // Bucket count should be capped
    try std.testing.expect(rl.buckets.count() <= MAX_IP_BUCKETS);
}
