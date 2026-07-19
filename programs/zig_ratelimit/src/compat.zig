//! Zig 0.16 Compatibility Layer + injectable Clock
//!
//! Provides Timer and time functions that were removed from std.time in Zig 0.16.
//! Uses POSIX clock_gettime via libc for cross-platform compatibility.
//!
//! Also defines the `Clock` abstraction every limiter in this library reads time
//! through. Production code uses the default monotonic clock; tests inject
//! `ManualClock` so time-dependent behaviour is exercised deterministically and
//! instantly instead of by sleeping and asserting loose bounds.

const std = @import("std");

/// Get current time in nanoseconds using CLOCK_MONOTONIC.
///
/// Panics if the clock is unavailable. CLOCK_MONOTONIC with a valid `timespec`
/// pointer cannot fail on any supported platform, and the previous silent
/// `return 0` fallback was actively harmful: a 0 here makes every limiter
/// compute a hugely negative elapsed interval and jam shut (denial of service)
/// with no diagnostic. A broken monotonic clock must be loud.
pub fn nowNs() i128 {
    var ts: std.c.timespec = undefined;
    const result = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    if (result != 0) {
        @panic("clock_gettime(CLOCK_MONOTONIC) failed — rate limiting cannot proceed without a monotonic clock");
    }
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

/// Sleep for given nanoseconds using nanosleep.
///
/// Only EINTR is retried. `nanosleep` writes the remaining-time struct *only*
/// on EINTR, so the previous unconditional retry loop fed an uninitialized
/// `timespec` back into the next call on any other error.
pub fn sleepNs(ns: u64) void {
    var req: std.c.timespec = .{
        .sec = @intCast(ns / 1_000_000_000),
        .nsec = @intCast(ns % 1_000_000_000),
    };
    var remaining: std.c.timespec = undefined;
    while (std.c.nanosleep(&req, &remaining) != 0) {
        if (std.c._errno().* != @intFromEnum(std.c.E.INTR)) return;
        req = remaining;
    }
}

// ============================================================================
// Clock injection
// ============================================================================

/// A source of monotonic nanoseconds.
///
/// This is the "single injected Clock interface" corrective shape from
/// zig-forge/CLAUDE.md anti-pattern class 6. Note that even the default is a
/// *monotonic* clock, never `std.time.timestamp()`: a rate limiter whose time
/// source can be moved backwards by NTP or an operator is not a rate limiter.
pub const Clock = struct {
    ctx: ?*anyopaque = null,
    now_fn: *const fn (ctx: ?*anyopaque) i128 = monotonicNow,

    pub inline fn now(self: Clock) i128 {
        return self.now_fn(self.ctx);
    }
};

fn monotonicNow(_: ?*anyopaque) i128 {
    return nowNs();
}

/// The default production clock: CLOCK_MONOTONIC.
pub const monotonic_clock: Clock = .{};

/// A test clock whose time only moves when the test moves it.
///
/// Lets time-dependent limiter behaviour be asserted exactly (`expectEqual`)
/// rather than with the loose tolerances that sleep-based tests require, and
/// removes the real wall-time cost and CI-under-load flakiness of sleeping.
pub const ManualClock = struct {
    ns: i128 = 0,

    pub fn clock(self: *ManualClock) Clock {
        return .{ .ctx = @ptrCast(self), .now_fn = read };
    }

    fn read(ctx: ?*anyopaque) i128 {
        const self: *ManualClock = @ptrCast(@alignCast(ctx.?));
        return self.ns;
    }

    pub fn advanceNs(self: *ManualClock, delta: i128) void {
        self.ns += delta;
    }

    pub fn advanceMs(self: *ManualClock, delta_ms: i128) void {
        self.ns += delta_ms * 1_000_000;
    }

    pub fn advanceSec(self: *ManualClock, delta_sec: f64) void {
        self.ns += @intFromFloat(delta_sec * 1_000_000_000.0);
    }
};

/// High-resolution timer for benchmarking and elapsed time measurement.
/// Replacement for std.time.Timer which was removed in Zig 0.16.
pub const Timer = struct {
    start_time: i128,

    const Self = @This();

    /// Start the timer
    pub fn start() Self {
        return Self{
            .start_time = nowNs(),
        };
    }

    /// Read elapsed time in nanoseconds
    pub fn read(self: *Self) u64 {
        const now = nowNs();
        const elapsed = now - self.start_time;
        return if (elapsed < 0) 0 else @intCast(elapsed);
    }

    /// Reset the timer
    pub fn reset(self: *Self) void {
        self.start_time = nowNs();
    }

    /// Lap: read and reset in one operation
    pub fn lap(self: *Self) u64 {
        const elapsed = self.read();
        self.reset();
        return elapsed;
    }
};

// ============================================================================
// Tests
//
// These used to call `std.time.sleep`, removed in Zig 0.16 — i.e. they could
// not compile. They never failed the build only because compat was a separate
// module whose tests were not collected by any test target. Both problems are
// fixed: they use `sleepNs`, and build.zig now runs them.
// ============================================================================

test "timer basic" {
    var timer = Timer.start();
    sleepNs(1_000_000); // 1ms
    const elapsed = timer.read();
    try std.testing.expect(elapsed >= 900_000); // Allow some variance
    try std.testing.expect(elapsed < 100_000_000); // Should be less than 100ms
}

test "nowNs monotonic" {
    const t1 = nowNs();
    sleepNs(1_000); // 1 microsecond
    const t2 = nowNs();
    try std.testing.expect(t2 >= t1);
}

test "default Clock reads the monotonic clock" {
    const c = monotonic_clock;
    const t1 = c.now();
    sleepNs(1_000);
    const t2 = c.now();
    try std.testing.expect(t2 >= t1);
}

test "ManualClock only moves when advanced" {
    var mc = ManualClock{};
    const c = mc.clock();

    try std.testing.expectEqual(@as(i128, 0), c.now());
    sleepNs(2_000_000); // real time passes...
    try std.testing.expectEqual(@as(i128, 0), c.now()); // ...the manual clock does not

    mc.advanceMs(250);
    try std.testing.expectEqual(@as(i128, 250_000_000), c.now());
    mc.advanceSec(1.5);
    try std.testing.expectEqual(@as(i128, 1_750_000_000), c.now());
    mc.advanceNs(7);
    try std.testing.expectEqual(@as(i128, 1_750_000_007), c.now());
}
