//! Zig 0.16 Compatibility Layer
//!
//! Provides Timer and time functions that were removed from std.time in Zig 0.16.
//! Uses POSIX clock_gettime via libc for cross-platform compatibility.

const std = @import("std");

/// Get current time in nanoseconds using CLOCK_MONOTONIC
pub fn nowNs() i128 {
    var ts: std.c.timespec = undefined;
    const result = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    if (result != 0) {
        // Fallback: should never happen on Linux
        return 0;
    }
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

/// Sleep for given nanoseconds using nanosleep
pub fn sleepNs(ns: u64) void {
    var ts: std.c.timespec = undefined;
    ts.sec = @intCast(ns / 1_000_000_000);
    ts.nsec = @intCast(ns % 1_000_000_000);

    var remaining: std.c.timespec = undefined;
    while (std.c.nanosleep(&ts, &remaining) != 0) {
        ts = remaining;
    }
}

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

test "timer basic" {
    var timer = Timer.start();
    std.time.sleep(1_000_000); // 1ms
    const elapsed = timer.read();
    try std.testing.expect(elapsed >= 900_000); // Allow some variance
    try std.testing.expect(elapsed < 100_000_000); // Should be less than 100ms
}

test "nowNs monotonic" {
    const t1 = nowNs();
    std.time.sleep(1_000); // 1 microsecond
    const t2 = nowNs();
    try std.testing.expect(t2 >= t1);
}
