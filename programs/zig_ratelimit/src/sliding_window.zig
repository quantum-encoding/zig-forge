//! Sliding Window Rate Limiters
//!
//! Two implementations:
//! - SlidingWindowLog: Exact tracking with timestamp log (memory scales with requests)
//! - SlidingWindowCounter: Approximate tracking with fixed memory
//!
//! Both maintain rate limits across sliding time windows rather than fixed intervals.

const std = @import("std");
const Allocator = std.mem.Allocator;
const compat = @import("compat.zig");

/// Sliding Window Log - Exact tracking using timestamp log
/// More accurate but uses memory proportional to request rate
pub const SlidingWindowLog = struct {
    /// Request timestamps (circular buffer)
    timestamps: []i64,
    /// Current write position
    head: usize,
    /// Number of valid entries
    count: usize,
    /// Maximum requests per window
    limit: usize,
    /// Window duration in nanoseconds
    window_ns: i64,
    /// Allocator
    allocator: Allocator,

    const Self = @This();

    /// Initialize with limit and window duration
    /// limit: Max requests per window
    /// window_ms: Window duration in milliseconds
    pub fn init(allocator: Allocator, limit: usize, window_ms: u64) !Self {
        // Allocate enough space for limit + some buffer
        const capacity = limit * 2;
        const timestamps = try allocator.alloc(i64, capacity);
        @memset(timestamps, 0);

        return Self{
            .timestamps = timestamps,
            .head = 0,
            .count = 0,
            .limit = limit,
            .window_ns = @as(i64, @intCast(window_ms)) * 1_000_000,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.timestamps);
    }

    /// Remove expired entries
    fn cleanup(self: *Self, now: i64) void {
        const cutoff = now - self.window_ns;

        // Remove old entries from the beginning
        while (self.count > 0) {
            // Find oldest entry
            const oldest_idx = if (self.head >= self.count)
                self.head - self.count
            else
                self.timestamps.len - (self.count - self.head);

            if (self.timestamps[oldest_idx] >= cutoff) {
                break;
            }
            self.count -= 1;
        }
    }

    /// Try to acquire (record a request)
    /// Returns true if under limit
    pub fn tryAcquire(self: *Self) bool {
        const now: i64 = @intCast(compat.nowNs());
        self.cleanup(now);

        if (self.count >= self.limit) {
            return false;
        }

        // Record this request
        self.timestamps[self.head] = now;
        self.head = (self.head + 1) % self.timestamps.len;
        self.count += 1;

        return true;
    }

    /// Check if a request would be allowed without recording it
    pub fn check(self: *Self) bool {
        const now: i64 = @intCast(compat.nowNs());
        self.cleanup(now);
        return self.count < self.limit;
    }

    /// Get current request count in window
    pub fn currentCount(self: *Self) usize {
        const now: i64 = @intCast(compat.nowNs());
        self.cleanup(now);
        return self.count;
    }

    /// Get remaining requests allowed
    pub fn remaining(self: *Self) usize {
        const now: i64 = @intCast(compat.nowNs());
        self.cleanup(now);
        return self.limit -| self.count;
    }

    /// Reset the limiter
    pub fn reset(self: *Self) void {
        self.head = 0;
        self.count = 0;
        @memset(self.timestamps, 0);
    }
};

/// Sliding Window Counter - Approximate tracking with fixed memory
/// Uses weighted average between current and previous window counts
pub const SlidingWindowCounter = struct {
    /// Requests in current window
    current_count: u64,
    /// Requests in previous window
    previous_count: u64,
    /// Current window start time (nanoseconds)
    window_start: i64,
    /// Maximum requests per window
    limit: u64,
    /// Window duration in nanoseconds
    window_ns: i64,

    const Self = @This();

    /// Initialize with limit and window duration
    /// limit: Max requests per window
    /// window_ms: Window duration in milliseconds
    pub fn init(limit: u64, window_ms: u64) Self {
        return Self{
            .current_count = 0,
            .previous_count = 0,
            .window_start = @intCast(compat.nowNs()),
            .limit = limit,
            .window_ns = @as(i64, @intCast(window_ms)) * 1_000_000,
        };
    }

    /// Advance windows if needed
    fn advanceWindows(self: *Self, now: i64) void {
        const windows_elapsed = @divFloor(now - self.window_start, self.window_ns);

        if (windows_elapsed >= 2) {
            // More than 2 windows passed, reset everything
            self.previous_count = 0;
            self.current_count = 0;
            self.window_start = now - @rem(now - self.window_start, self.window_ns);
        } else if (windows_elapsed == 1) {
            // One window passed, rotate
            self.previous_count = self.current_count;
            self.current_count = 0;
            self.window_start += self.window_ns;
        }
    }

    /// Calculate weighted count using sliding window approximation
    fn weightedCount(self: *Self, now: i64) f64 {
        self.advanceWindows(now);

        // Position within current window (0.0 to 1.0)
        const elapsed_in_window = now - self.window_start;
        const window_progress = @as(f64, @floatFromInt(elapsed_in_window)) /
            @as(f64, @floatFromInt(self.window_ns));

        // Weighted count: previous * (1 - progress) + current
        const prev_weight = 1.0 - window_progress;
        return prev_weight * @as(f64, @floatFromInt(self.previous_count)) +
            @as(f64, @floatFromInt(self.current_count));
    }

    /// Try to acquire (record a request)
    pub fn tryAcquire(self: *Self) bool {
        const now: i64 = @intCast(compat.nowNs());
        const count = self.weightedCount(now);

        if (count >= @as(f64, @floatFromInt(self.limit))) {
            return false;
        }

        self.current_count += 1;
        return true;
    }

    /// Check without recording
    pub fn check(self: *Self) bool {
        const now: i64 = @intCast(compat.nowNs());
        const count = self.weightedCount(now);
        return count < @as(f64, @floatFromInt(self.limit));
    }

    /// Get approximate current request rate
    pub fn currentRate(self: *Self) f64 {
        const now: i64 = @intCast(compat.nowNs());
        return self.weightedCount(now);
    }

    /// Get remaining requests (approximate)
    pub fn remaining(self: *Self) u64 {
        const now: i64 = @intCast(compat.nowNs());
        const count = self.weightedCount(now);
        const limit_f = @as(f64, @floatFromInt(self.limit));
        if (count >= limit_f) return 0;
        return @intFromFloat(limit_f - count);
    }

    /// Reset the limiter
    pub fn reset(self: *Self) void {
        self.current_count = 0;
        self.previous_count = 0;
        self.window_start = @intCast(compat.nowNs());
    }
};

/// Fixed Window Counter - Simplest rate limiter
/// Resets count at fixed intervals (can allow 2x burst at boundary)
pub const FixedWindowCounter = struct {
    /// Current request count
    count: u64,
    /// Window start time
    window_start: i64,
    /// Maximum requests per window
    limit: u64,
    /// Window duration in nanoseconds
    window_ns: i64,

    const Self = @This();

    pub fn init(limit: u64, window_ms: u64) Self {
        return Self{
            .count = 0,
            .window_start = @intCast(compat.nowNs()),
            .limit = limit,
            .window_ns = @as(i64, @intCast(window_ms)) * 1_000_000,
        };
    }

    fn maybeResetWindow(self: *Self, now: i64) void {
        if (now - self.window_start >= self.window_ns) {
            self.count = 0;
            self.window_start = now;
        }
    }

    pub fn tryAcquire(self: *Self) bool {
        const now: i64 = @intCast(compat.nowNs());
        self.maybeResetWindow(now);

        if (self.count >= self.limit) {
            return false;
        }

        self.count += 1;
        return true;
    }

    pub fn check(self: *Self) bool {
        const now: i64 = @intCast(compat.nowNs());
        self.maybeResetWindow(now);
        return self.count < self.limit;
    }

    pub fn remaining(self: *Self) u64 {
        const now: i64 = @intCast(compat.nowNs());
        self.maybeResetWindow(now);
        return self.limit -| self.count;
    }

    pub fn reset(self: *Self) void {
        self.count = 0;
        self.window_start = @intCast(compat.nowNs());
    }
};

// ============================================================================
// Tests
// ============================================================================

test "sliding window log basic" {
    const allocator = std.testing.allocator;
    var limiter = try SlidingWindowLog.init(allocator, 5, 1000); // 5 per second
    defer limiter.deinit();

    // Should allow 5 requests
    for (0..5) |_| {
        try std.testing.expect(limiter.tryAcquire());
    }

    // 6th should fail
    try std.testing.expect(!limiter.tryAcquire());
}

test "sliding window counter basic" {
    var limiter = SlidingWindowCounter.init(10, 1000); // 10 per second

    // Should allow requests up to limit
    for (0..10) |_| {
        try std.testing.expect(limiter.tryAcquire());
    }

    // Should be at or near limit
    try std.testing.expect(!limiter.check());
}

test "fixed window counter basic" {
    var limiter = FixedWindowCounter.init(5, 1000);

    for (0..5) |_| {
        try std.testing.expect(limiter.tryAcquire());
    }

    try std.testing.expect(!limiter.tryAcquire());

    // Reset and try again
    limiter.reset();
    try std.testing.expect(limiter.tryAcquire());
}

test "sliding window log within limit" {
    const allocator = std.testing.allocator;
    var limiter = try SlidingWindowLog.init(allocator, 10, 1000); // 10 per second
    defer limiter.deinit();

    // All requests within limit should pass
    for (0..10) |_| {
        try std.testing.expect(limiter.tryAcquire());
    }

    try std.testing.expect(!limiter.tryAcquire());
}

test "sliding window log remaining" {
    const allocator = std.testing.allocator;
    var limiter = try SlidingWindowLog.init(allocator, 5, 1000);
    defer limiter.deinit();

    try std.testing.expectEqual(@as(usize, 5), limiter.remaining());

    _ = limiter.tryAcquire();
    try std.testing.expectEqual(@as(usize, 4), limiter.remaining());

    for (0..3) |_| {
        _ = limiter.tryAcquire();
    }
    try std.testing.expectEqual(@as(usize, 1), limiter.remaining());
}

test "sliding window log check without consuming" {
    const allocator = std.testing.allocator;
    var limiter = try SlidingWindowLog.init(allocator, 3, 1000);
    defer limiter.deinit();

    try std.testing.expect(limiter.check());

    for (0..3) |_| {
        _ = limiter.tryAcquire();
    }

    try std.testing.expect(!limiter.check());
    try std.testing.expectEqual(@as(usize, 3), limiter.currentCount());
}

test "sliding window log reset" {
    const allocator = std.testing.allocator;
    var limiter = try SlidingWindowLog.init(allocator, 5, 1000);
    defer limiter.deinit();

    for (0..5) |_| {
        _ = limiter.tryAcquire();
    }

    try std.testing.expectEqual(@as(usize, 5), limiter.currentCount());

    limiter.reset();
    try std.testing.expectEqual(@as(usize, 0), limiter.currentCount());
    try std.testing.expect(limiter.tryAcquire());
}

test "sliding window counter within limit" {
    var limiter = SlidingWindowCounter.init(20, 1000);

    // Should allow requests up to limit
    for (0..20) |_| {
        try std.testing.expect(limiter.tryAcquire());
    }

    // Over limit should fail
    try std.testing.expect(!limiter.check());
}

test "sliding window counter sliding behavior" {
    var limiter = SlidingWindowCounter.init(5, 100); // 5 per 100ms

    for (0..5) |_| {
        _ = limiter.tryAcquire();
    }

    try std.testing.expect(!limiter.check());

    // Wait for window to advance
    compat.sleepNs(120_000_000); // 120ms

    // Should allow more requests in new window
    try std.testing.expect(limiter.check());
}

test "sliding window counter current rate" {
    var limiter = SlidingWindowCounter.init(10, 1000);

    for (0..7) |_| {
        _ = limiter.tryAcquire();
    }

    const rate = limiter.currentRate();
    try std.testing.expect(rate >= 6.5 and rate <= 7.5);
}

test "sliding window counter remaining" {
    var limiter = SlidingWindowCounter.init(10, 1000);

    for (0..3) |_| {
        _ = limiter.tryAcquire();
    }

    const remaining = limiter.remaining();
    try std.testing.expect(remaining >= 6 and remaining <= 7);
}

test "sliding window counter reset" {
    var limiter = SlidingWindowCounter.init(5, 1000);

    for (0..5) |_| {
        _ = limiter.tryAcquire();
    }

    limiter.reset();
    try std.testing.expect(limiter.check());
}

test "fixed window counter within limit" {
    var limiter = FixedWindowCounter.init(10, 1000);

    // All requests within limit should pass
    for (0..10) |_| {
        try std.testing.expect(limiter.tryAcquire());
    }

    // Over limit should fail
    try std.testing.expect(!limiter.tryAcquire());
}

test "fixed window counter check without consuming" {
    var limiter = FixedWindowCounter.init(5, 1000);

    try std.testing.expect(limiter.check());

    for (0..5) |_| {
        _ = limiter.tryAcquire();
    }

    try std.testing.expect(!limiter.check());
}

test "fixed window counter remaining" {
    var limiter = FixedWindowCounter.init(8, 1000);

    for (0..3) |_| {
        _ = limiter.tryAcquire();
    }

    const remaining = limiter.remaining();
    try std.testing.expectEqual(@as(u64, 5), remaining);
}

test "fixed window counter reset behavior" {
    var limiter = FixedWindowCounter.init(5, 1000);

    for (0..5) |_| {
        _ = limiter.tryAcquire();
    }

    // Full, can't acquire
    try std.testing.expect(!limiter.tryAcquire());

    // Reset
    limiter.reset();

    // Should be able to acquire again
    try std.testing.expect(limiter.tryAcquire());
}

test "fixed window counter boundary behavior" {
    var limiter = FixedWindowCounter.init(3, 100); // 3 per 100ms window

    // Fill first window
    for (0..3) |_| {
        _ = limiter.tryAcquire();
    }

    // Should be full
    try std.testing.expect(!limiter.check());

    // Wait for window to expire
    compat.sleepNs(110_000_000); // 110ms

    // Should allow new requests in new window
    try std.testing.expect(limiter.tryAcquire());
}

test "sliding window log window expiry" {
    const allocator = std.testing.allocator;
    var limiter = try SlidingWindowLog.init(allocator, 2, 50); // 2 per 50ms
    defer limiter.deinit();

    for (0..2) |_| {
        _ = limiter.tryAcquire();
    }

    // Full now
    try std.testing.expect(!limiter.check());

    // Wait for window to expire
    compat.sleepNs(60_000_000); // 60ms

    // Should allow new requests
    try std.testing.expect(limiter.tryAcquire());
}
