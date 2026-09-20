//! Turns "this code never returns" into a test failure.
//!
//! A parser regression that spins forever would otherwise hang `zig build test`
//! with nothing on screen. `arm` schedules SIGALRM, whose default action kills
//! the test process, so the build reports a crashed test instead of stalling.
//! The limit is a backstop set far above the real cost of the guarded code; a
//! test that trips it has stopped terminating, not slowed down.
const std = @import("std");

pub const Watchdog = struct {
    pub fn arm(seconds: c_uint) Watchdog {
        _ = std.c.alarm(seconds);
        return .{};
    }

    pub fn disarm(_: Watchdog) void {
        _ = std.c.alarm(0);
    }
};
