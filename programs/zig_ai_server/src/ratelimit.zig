// Per-Key Rate Limiter — token bucket algorithm
// Keyed by API key hash (32 bytes). Thread-safe via atomic CAS.
// Enforces rate_limit_rpm from key scope.
//
// Token bucket: fills at `rate` tokens per minute, max capacity = rate.
// Each request consumes 1 token. If empty, request is rejected with 429.

const std = @import("std");
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

const Bucket = struct {
    tokens: i64, // Current tokens (can briefly go negative under contention)
    last_refill: i64, // Timestamp of last refill (monotonic counter)
    rate_rpm: u32, // Tokens per minute (also max capacity)
};

pub const RateLimiter = struct {
    allocator: std.mem.Allocator,
    mutex: SpinLock = .{},
    // Map: key_hash bytes → Bucket
    buckets: std.HashMapUnmanaged([32]u8, Bucket, KeyHashContext, std.hash_map.default_max_load_percentage) = .empty,

    const KeyHashContext = struct {
        pub fn hash(_: @This(), key: [32]u8) u64 {
            return std.mem.readInt(u64, key[0..8], .little);
        }
        pub fn eql(_: @This(), a: [32]u8, b: [32]u8) bool {
            return std.mem.eql(u8, &a, &b);
        }
    };

    pub fn init(allocator: std.mem.Allocator) RateLimiter {
        return .{ .allocator = allocator };
    }

    /// Check if a request is allowed for the given key.
    /// Returns true if allowed, false if rate limited.
    /// `rate_rpm` is the configured rate limit (requests per minute). 0 = no limit.
    pub fn check(self: *RateLimiter, key_hash: [32]u8, rate_rpm: u32) bool {
        if (rate_rpm == 0) return true; // No limit configured

        self.mutex.lock();
        defer self.mutex.unlock();

        const now = types.nowMs();

        const entry = self.buckets.getPtr(key_hash);
        if (entry) |bucket| {
            // Refill tokens based on elapsed time
            const elapsed = now - bucket.last_refill;
            if (elapsed > 0) {
                // tokens_to_add = rate_rpm * elapsed_minutes
                // Since our timestamps are monotonic counters (not real time),
                // use a simpler approach: refill 1 token per (60000/rate) ms equivalent
                // With monotonic counters, just refill proportionally
                const refill = @divFloor(@as(i64, rate_rpm) * elapsed, 60);
                bucket.tokens = @min(bucket.tokens + refill, @as(i64, rate_rpm));
                bucket.last_refill = now;
            }

            // Try to consume a token
            if (bucket.tokens > 0) {
                bucket.tokens -= 1;
                return true;
            }
            return false; // Rate limited
        } else {
            // First request for this key — create bucket with full tokens minus 1
            self.buckets.put(self.allocator, key_hash, .{
                .tokens = @as(i64, rate_rpm) - 1,
                .last_refill = now,
                .rate_rpm = rate_rpm,
            }) catch return true; // On OOM, allow the request
            return true;
        }
    }

    /// Get seconds until next token is available (for Retry-After header)
    pub fn retryAfterSecs(self: *RateLimiter, key_hash: [32]u8, rate_rpm: u32) u32 {
        if (rate_rpm == 0) return 0;

        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.buckets.get(key_hash) orelse return 1;
        // Time for 1 token: 60 / rate_rpm seconds
        return @max(1, @divFloor(60, rate_rpm));
    }

    pub fn deinit(self: *RateLimiter) void {
        self.buckets.deinit(self.allocator);
    }
};
