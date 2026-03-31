//! Leaky Bucket Rate Limiter
//!
//! Provides smooth, constant-rate output regardless of input burstiness.
//! Requests queue up in the bucket and "leak" out at a fixed rate.
//!
//! Use cases:
//! - API rate limiting with smooth request distribution
//! - Network traffic shaping
//! - Task scheduling with uniform intervals
//!
//! Example:
//! ```zig
//! var bucket = LeakyBucket.init(100, 10); // 100 capacity, 10 requests/sec
//! if (bucket.tryAcquire()) {
//!     // Request allowed
//! }
//! ```

const std = @import("std");
const compat = @import("compat.zig");

/// Leaky Bucket rate limiter
/// Water (requests) fills the bucket and leaks out at a constant rate
pub const LeakyBucket = struct {
    /// Maximum bucket capacity (queue size)
    capacity: f64,
    /// Leak rate (requests processed per second)
    leak_rate: f64,
    /// Current water level (pending requests)
    water_level: f64,
    /// Last leak timestamp (nanoseconds)
    last_leak: i128,

    const Self = @This();

    /// Initialize a leaky bucket
    /// capacity: Maximum pending requests
    /// leak_rate: Requests processed per second
    pub fn init(capacity: f64, leak_rate: f64) Self {
        return Self{
            .capacity = capacity,
            .leak_rate = leak_rate,
            .water_level = 0, // Start empty
            .last_leak = compat.nowNs(),
        };
    }

    /// Leak water based on elapsed time
    fn leak(self: *Self) void {
        const now = compat.nowNs();
        const elapsed_ns = now - self.last_leak;
        const elapsed_sec = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        const leaked = elapsed_sec * self.leak_rate;

        self.water_level = @max(0, self.water_level - leaked);
        self.last_leak = now;
    }

    /// Try to add a request to the bucket
    /// Returns true if the bucket has room
    pub fn tryAcquire(self: *Self) bool {
        return self.tryAcquireAmount(1.0);
    }

    /// Try to add a weighted request
    pub fn tryAcquireAmount(self: *Self, amount: f64) bool {
        self.leak();

        if (self.water_level + amount <= self.capacity) {
            self.water_level += amount;
            return true;
        }
        return false;
    }

    /// Check if a request would be accepted without adding it
    pub fn check(self: *Self) bool {
        return self.checkAmount(1.0);
    }

    pub fn checkAmount(self: *Self, amount: f64) bool {
        self.leak();
        return self.water_level + amount <= self.capacity;
    }

    /// Get current water level (pending requests)
    pub fn pending(self: *Self) f64 {
        self.leak();
        return self.water_level;
    }

    /// Get available capacity
    pub fn availableCapacity(self: *Self) f64 {
        self.leak();
        return self.capacity - self.water_level;
    }

    /// Get fill ratio (0.0 = empty, 1.0 = full)
    pub fn fillRatio(self: *Self) f64 {
        self.leak();
        return self.water_level / self.capacity;
    }

    /// Estimate time until bucket can accept another request (nanoseconds)
    pub fn timeUntilAvailable(self: *Self, amount: f64) i64 {
        self.leak();

        const available = self.capacity - self.water_level;
        if (available >= amount) {
            return 0;
        }

        const needed = amount - available;
        const wait_sec = needed / self.leak_rate;
        return @intFromFloat(wait_sec * 1_000_000_000.0);
    }

    /// Force set water level (useful for testing)
    pub fn setLevel(self: *Self, level: f64) void {
        self.water_level = @min(level, self.capacity);
        self.last_leak = compat.nowNs();
    }

    /// Reset to empty
    pub fn reset(self: *Self) void {
        self.water_level = 0;
        self.last_leak = compat.nowNs();
    }
};

/// GCRA (Generic Cell Rate Algorithm) - A variation of leaky bucket
/// Also known as "virtual scheduling" algorithm
/// More precise for bursty traffic patterns
pub const GCRA = struct {
    /// Emission interval (time between allowed requests in nanoseconds)
    emission_interval: i64,
    /// Limit on advance (tolerance for bursts in nanoseconds)
    delay_tolerance: i64,
    /// Theoretical arrival time (TAT)
    tat: i128,

    const Self = @This();

    /// Initialize GCRA
    /// rate: Requests per second
    /// burst: Maximum burst size
    pub fn init(rate: f64, burst: f64) Self {
        const emission_ns = @as(i64, @intFromFloat(1_000_000_000.0 / rate));
        const tolerance_ns = @as(i64, @intFromFloat(burst * 1_000_000_000.0 / rate));

        return Self{
            .emission_interval = emission_ns,
            .delay_tolerance = tolerance_ns,
            .tat = 0, // Will be initialized on first request
        };
    }

    /// Try to acquire a slot
    pub fn tryAcquire(self: *Self) bool {
        const now = compat.nowNs();

        // Initialize TAT on first request
        if (self.tat == 0) {
            self.tat = now + self.emission_interval;
            return true;
        }

        // Check if we're within tolerance
        const new_tat = @max(self.tat, now) + self.emission_interval;
        const allow_at = new_tat - self.delay_tolerance;

        if (allow_at <= now) {
            self.tat = new_tat;
            return true;
        }

        return false;
    }

    /// Check without consuming
    pub fn check(self: *Self) bool {
        const now = compat.nowNs();

        if (self.tat == 0) return true;

        const new_tat = @max(self.tat, now) + self.emission_interval;
        const allow_at = new_tat - self.delay_tolerance;

        return allow_at <= now;
    }

    /// Get time until next request is allowed (nanoseconds)
    pub fn timeUntilAllowed(self: *Self) i64 {
        const now = compat.nowNs();

        if (self.tat == 0) return 0;

        const new_tat = @max(self.tat, now) + self.emission_interval;
        const allow_at = new_tat - self.delay_tolerance;

        if (allow_at <= now) return 0;
        return @intCast(allow_at - now);
    }

    /// Reset the limiter
    pub fn reset(self: *Self) void {
        self.tat = 0;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "leaky bucket basic" {
    var bucket = LeakyBucket.init(5, 10); // 5 capacity, 10/sec leak rate

    // Fill up the bucket
    for (0..5) |_| {
        try std.testing.expect(bucket.tryAcquire());
    }

    // Should be full
    try std.testing.expect(!bucket.tryAcquire());
}

test "leaky bucket fill ratio" {
    var bucket = LeakyBucket.init(10, 100);

    // Empty bucket
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), bucket.fillRatio(), 0.01);

    // Add 5 units
    _ = bucket.tryAcquireAmount(5);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), bucket.fillRatio(), 0.1);
}

test "gcra basic" {
    var gcra = GCRA.init(10, 5); // 10/sec, burst of 5

    // Should allow burst
    for (0..5) |_| {
        try std.testing.expect(gcra.tryAcquire());
    }
}

test "gcra reset" {
    var gcra = GCRA.init(1, 1); // 1/sec, burst of 1
    _ = gcra.tryAcquire();
    try std.testing.expect(!gcra.check());

    gcra.reset();
    try std.testing.expect(gcra.check());
}

test "leaky bucket basic allow deny" {
    var bucket = LeakyBucket.init(3, 10); // 3 capacity, 10/sec leak

    // Should allow requests within capacity
    try std.testing.expect(bucket.tryAcquire());
    try std.testing.expect(bucket.tryAcquire());
    try std.testing.expect(bucket.tryAcquire());

    // Should deny when full
    try std.testing.expect(!bucket.tryAcquire());
}

test "leaky bucket drain rate behavior" {
    var bucket = LeakyBucket.init(5, 100); // 5 capacity, 100/sec leak rate

    // Fill to capacity
    for (0..5) |_| {
        _ = bucket.tryAcquire();
    }
    try std.testing.expect(!bucket.tryAcquire());

    // Wait for some water to leak out
    compat.sleepNs(50_000_000); // 50ms, 5 requests should leak

    // Should now allow more
    try std.testing.expect(bucket.tryAcquire());
}

test "leaky bucket burst handling" {
    var bucket = LeakyBucket.init(10, 1); // 10 capacity, 1/sec leak

    // Try to add more than capacity at once
    try std.testing.expect(bucket.tryAcquireAmount(10));
    try std.testing.expect(!bucket.tryAcquireAmount(1)); // Should overflow

    // Queue should be full
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), bucket.fillRatio(), 0.05);
}

test "leaky bucket zero rate denial" {
    var bucket = LeakyBucket.init(5, 0.0001); // Very low leak rate

    // Fill up
    for (0..5) |_| {
        try std.testing.expect(bucket.tryAcquire());
    }

    // Should deny new requests when full (extremely slow leak)
    try std.testing.expect(!bucket.tryAcquire());
}

test "leaky bucket available capacity" {
    var bucket = LeakyBucket.init(10, 100);

    try std.testing.expectApproxEqAbs(@as(f64, 10.0), bucket.availableCapacity(), 0.1);

    _ = bucket.tryAcquireAmount(3);
    try std.testing.expectApproxEqAbs(@as(f64, 7.0), bucket.availableCapacity(), 0.1);
}

test "leaky bucket pending level" {
    var bucket = LeakyBucket.init(10, 100);

    try std.testing.expectApproxEqAbs(@as(f64, 0.0), bucket.pending(), 0.1);

    _ = bucket.tryAcquireAmount(4);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), bucket.pending(), 0.1);
}

test "leaky bucket reset" {
    var bucket = LeakyBucket.init(10, 100);

    _ = bucket.tryAcquireAmount(8);
    try std.testing.expect(bucket.pending() > 0);

    bucket.reset();
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), bucket.pending(), 0.1);
}

test "leaky bucket check without consuming" {
    var bucket = LeakyBucket.init(5, 10);

    try std.testing.expect(bucket.check());

    // Add 5 items
    for (0..5) |_| {
        _ = bucket.tryAcquire();
    }

    // check should return false (full)
    try std.testing.expect(!bucket.check());
}

test "gcra steady state traffic" {
    var gcra = GCRA.init(100, 10); // 100 req/sec, burst of 10

    // Initial burst should succeed (up to burst size)
    for (0..10) |_| {
        try std.testing.expect(gcra.tryAcquire());
    }

    // After burst is consumed, subsequent requests should be rate limited
    try std.testing.expect(!gcra.tryAcquire());
}

test "gcra burst followed by steady" {
    var gcra = GCRA.init(10, 5); // 10 req/sec, burst of 5

    // Initial burst should succeed
    for (0..5) |_| {
        try std.testing.expect(gcra.tryAcquire());
    }

    // Following requests should be delayed or fail
    try std.testing.expect(!gcra.check());

    // Wait and try again
    compat.sleepNs(100_000_000); // 100ms
    try std.testing.expect(gcra.check());
}

test "gcra over limit rejection" {
    var gcra = GCRA.init(5, 2); // 5 req/sec, burst of 2

    // Acquire burst
    try std.testing.expect(gcra.tryAcquire());
    try std.testing.expect(gcra.tryAcquire());

    // Excess should be blocked
    try std.testing.expect(!gcra.check());
}

test "gcra time until allowed" {
    var gcra = GCRA.init(10, 1); // 10 req/sec, burst of 1

    // Use first request
    _ = gcra.tryAcquire();

    // Next request should show a wait time
    const wait_ns = gcra.timeUntilAllowed();
    try std.testing.expect(wait_ns > 0);
    try std.testing.expect(wait_ns < 200_000_000); // Less than 200ms
}
