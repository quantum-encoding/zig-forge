//! Token Bucket Rate Limiter
//!
//! Classic rate limiting algorithm where tokens are added at a fixed rate
//! and requests consume tokens. Allows bursts up to bucket capacity.
//!
//! Example:
//! ```zig
//! var limiter = TokenBucket.init(100, 10); // 100 tokens max, 10 tokens/sec
//! if (limiter.tryAcquire(1)) {
//!     // Request allowed
//! } else {
//!     // Rate limited
//! }
//! ```

const std = @import("std");
const compat = @import("compat.zig");

/// Token Bucket rate limiter
pub const TokenBucket = struct {
    /// Maximum tokens in the bucket (burst capacity)
    capacity: f64,
    /// Tokens added per second
    rate: f64,
    /// Current number of tokens
    tokens: f64,
    /// Last refill timestamp (nanoseconds)
    last_refill: i128,

    const Self = @This();

    /// Initialize a token bucket
    /// capacity: Maximum tokens (burst size)
    /// rate: Tokens added per second
    pub fn init(capacity: f64, rate: f64) Self {
        return Self{
            .capacity = capacity,
            .rate = rate,
            .tokens = capacity, // Start full
            .last_refill = compat.nowNs(),
        };
    }

    /// Initialize with specific starting tokens
    pub fn initWithTokens(capacity: f64, rate: f64, initial_tokens: f64) Self {
        return Self{
            .capacity = capacity,
            .rate = rate,
            .tokens = @min(initial_tokens, capacity),
            .last_refill = compat.nowNs(),
        };
    }

    /// Refill tokens based on elapsed time
    fn refill(self: *Self) void {
        const now = compat.nowNs();
        const elapsed_ns = now - self.last_refill;
        const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        const new_tokens = elapsed_sec * self.rate;

        self.tokens = @min(self.capacity, self.tokens + new_tokens);
        self.last_refill = now;
    }

    /// Try to acquire tokens (non-blocking)
    /// Returns true if tokens were acquired
    pub fn tryAcquire(self: *Self, tokens: f64) bool {
        self.refill();

        if (self.tokens >= tokens) {
            self.tokens -= tokens;
            return true;
        }
        return false;
    }

    /// Try to acquire a single token
    pub fn tryAcquireOne(self: *Self) bool {
        return self.tryAcquire(1.0);
    }

    /// Check if tokens are available without consuming them
    pub fn check(self: *Self, tokens: f64) bool {
        self.refill();
        return self.tokens >= tokens;
    }

    /// Get current available tokens
    pub fn available(self: *Self) f64 {
        self.refill();
        return self.tokens;
    }

    /// Get time until specified tokens will be available (in nanoseconds)
    pub fn timeUntilAvailable(self: *Self, tokens: f64) i64 {
        self.refill();

        if (self.tokens >= tokens) {
            return 0;
        }

        const needed = tokens - self.tokens;
        const wait_sec = needed / self.rate;
        return @intFromFloat(wait_sec * 1_000_000_000.0);
    }

    /// Force set token count (useful for testing or reset)
    pub fn setTokens(self: *Self, tokens: f64) void {
        self.tokens = @min(tokens, self.capacity);
        self.last_refill = compat.nowNs();
    }

    /// Reset to full capacity
    pub fn reset(self: *Self) void {
        self.tokens = self.capacity;
        self.last_refill = compat.nowNs();
    }

    /// Get current fill ratio (0.0 to 1.0)
    pub fn fillRatio(self: *Self) f64 {
        self.refill();
        return self.tokens / self.capacity;
    }
};

/// Thread-safe Token Bucket using atomic operations
pub const AtomicTokenBucket = struct {
    /// Maximum tokens (fixed)
    capacity: f64,
    /// Tokens per second (fixed)
    rate: f64,
    /// Current tokens (scaled by 1000 for integer math)
    tokens_scaled: std.atomic.Value(i64),
    /// Last refill timestamp (nanoseconds, using i64 for atomic support - good for 290+ years)
    last_refill_ns: std.atomic.Value(i64),
    /// Scale factor for integer representation
    const SCALE: i64 = 1000;

    const Self = @This();

    pub fn init(capacity: f64, rate: f64) Self {
        const scaled_capacity = @as(i64, @intFromFloat(capacity * @as(f64, SCALE)));
        const now_ns: i64 = @intCast(compat.nowNs());
        return Self{
            .capacity = capacity,
            .rate = rate,
            .tokens_scaled = std.atomic.Value(i64).init(scaled_capacity),
            .last_refill_ns = std.atomic.Value(i64).init(now_ns),
        };
    }

    /// Thread-safe token acquisition using CAS loop
    pub fn tryAcquire(self: *Self, tokens: f64) bool {
        const tokens_needed = @as(i64, @intFromFloat(tokens * @as(f64, SCALE)));
        const scaled_capacity = @as(i64, @intFromFloat(self.capacity * @as(f64, SCALE)));

        while (true) {
            const now: i64 = @intCast(compat.nowNs());
            const last = self.last_refill_ns.load(.acquire);
            const current_tokens = self.tokens_scaled.load(.acquire);

            // Calculate refill
            const elapsed_ns = now - last;
            const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
            const refill_amount = @as(i64, @intFromFloat(elapsed_sec * self.rate * @as(f64, SCALE)));

            var new_tokens = @min(scaled_capacity, current_tokens + refill_amount);

            if (new_tokens < tokens_needed) {
                return false;
            }

            new_tokens -= tokens_needed;

            // Try to update atomically
            if (self.tokens_scaled.cmpxchgWeak(
                current_tokens,
                new_tokens,
                .acq_rel,
                .acquire,
            ) == null) {
                _ = self.last_refill_ns.cmpxchgWeak(last, now, .release, .acquire);
                return true;
            }
            // CAS failed, retry
        }
    }

    pub fn tryAcquireOne(self: *Self) bool {
        return self.tryAcquire(1.0);
    }

    pub fn available(self: *Self) f64 {
        const scaled = self.tokens_scaled.load(.acquire);
        return @as(f64, @floatFromInt(scaled)) / @as(f64, SCALE);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "token bucket basic" {
    var bucket = TokenBucket.init(10, 1); // 10 tokens, 1/sec

    // Should have full capacity
    try std.testing.expect(bucket.tryAcquire(10));

    // Now empty
    try std.testing.expect(!bucket.tryAcquire(1));
}

test "token bucket partial acquire" {
    var bucket = TokenBucket.init(10, 100); // 10 tokens, 100/sec

    try std.testing.expect(bucket.tryAcquire(5));
    try std.testing.expect(bucket.available() <= 5.1); // Some refill may occur
    try std.testing.expect(bucket.tryAcquire(5));
}

test "token bucket reset" {
    var bucket = TokenBucket.init(10, 1);
    _ = bucket.tryAcquire(10);
    try std.testing.expect(!bucket.tryAcquire(1));

    bucket.reset();
    try std.testing.expect(bucket.tryAcquire(10));
}

test "atomic token bucket basic" {
    var bucket = AtomicTokenBucket.init(10, 1);

    try std.testing.expect(bucket.tryAcquire(10));
    try std.testing.expect(!bucket.tryAcquire(1));
}
