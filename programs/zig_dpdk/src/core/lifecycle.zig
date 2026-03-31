/// Graceful lifecycle management for zig_dpdk.
///
/// Handles clean startup, shutdown, and state transitions.
/// On Linux: signal handling (SIGTERM, SIGUSR1, SIGUSR2).
/// On Zigix: direct kernel event integration.
///
/// Startup flow:
///   1. Allocate hugepage memory pools
///   2. Initialize NIC devices (AF_XDP or native PMD)
///   3. Pre-fill descriptor rings
///   4. Pin cores and start poll loops
///   5. Enter steady state
///
/// Shutdown flow:
///   1. Signal received or stop() called
///   2. Drain all TX queues (wait for completions)
///   3. Return all mbufs to pool
///   4. Stop NIC devices (release hardware/XDP)
///   5. Free hugepage memory
///   6. Log final stats

const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const stats_mod = @import("stats.zig");
const telemetry = @import("telemetry.zig");

/// Application state machine.
pub const State = enum {
    uninitialized,
    initializing,
    running,
    stopping,
    stopped,
};

/// Lifecycle event for callbacks.
pub const Event = enum {
    pre_init,
    post_init,
    pre_start,
    post_start,
    pre_stop,
    post_stop,
    stats_dump,
    stats_reset,
};

/// Lifecycle controller.
pub const Lifecycle = struct {
    state: State = .uninitialized,
    should_stop: bool = false,
    start_time: u64 = 0,
    event_callback: ?*const fn (Event) void = null,
    sys_telemetry: telemetry.SystemTelemetry = .{},

    pub fn init() Lifecycle {
        return .{};
    }

    /// Transition to initializing state.
    pub fn beginInit(self: *Lifecycle) !void {
        if (self.state != .uninitialized) return error.InvalidState;
        self.state = .initializing;
        self.notify(.pre_init);
    }

    /// Transition to running state. Records start time.
    pub fn start(self: *Lifecycle) !void {
        if (self.state != .initializing) return error.InvalidState;
        self.notify(.pre_start);
        self.state = .running;
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        self.start_time = @intCast(@as(i128, ts.sec) * 1_000_000_000 + ts.nsec);
        self.notify(.post_start);
    }

    /// Request graceful shutdown.
    pub fn stop(self: *Lifecycle) void {
        if (self.state != .running) return;
        self.notify(.pre_stop);
        self.state = .stopping;
        self.should_stop = true;
    }

    /// Complete shutdown after draining.
    pub fn finalize(self: *Lifecycle) void {
        self.state = .stopped;
        self.notify(.post_stop);
    }

    /// Check if the main loop should continue.
    pub fn isRunning(self: *const Lifecycle) bool {
        return self.state == .running and !self.should_stop;
    }

    /// Dump stats (triggered by SIGUSR1 or periodic timer).
    pub fn dumpStats(self: *Lifecycle) void {
        self.notify(.stats_dump);
        self.sys_telemetry.dump();
    }

    /// Reset counters (triggered by SIGUSR2).
    pub fn resetStats(self: *Lifecycle) void {
        self.notify(.stats_reset);
        self.sys_telemetry.latency.reset();
    }

    fn notify(self: *const Lifecycle, event: Event) void {
        if (self.event_callback) |cb| {
            cb(event);
        }
    }

    /// Install signal handlers (Linux only).
    pub fn installSignalHandlers(self: *Lifecycle) void {
        if (comptime builtin.os.tag != .linux) return;
        // Store lifecycle pointer in global for signal handler access
        global_lifecycle = self;
        installLinuxSignals();
    }
};

/// Global lifecycle pointer for signal handlers (Linux only).
var global_lifecycle: ?*Lifecycle = null;

fn installLinuxSignals() void {
    if (comptime builtin.os.tag != .linux) return;

    const linux = std.os.linux;
    const SA = linux.SA;

    // SIGTERM → graceful shutdown
    var sa_term = std.mem.zeroes(linux.Sigaction);
    sa_term.__handler = .{ .handler = handleSigterm };
    sa_term.flags = SA.RESTART;
    _ = linux.sigaction(linux.SIG.TERM, &sa_term, null);

    // SIGUSR1 → dump stats
    var sa_usr1 = std.mem.zeroes(linux.Sigaction);
    sa_usr1.__handler = .{ .handler = handleSigusr1 };
    sa_usr1.flags = SA.RESTART;
    _ = linux.sigaction(linux.SIG.USR1, &sa_usr1, null);

    // SIGUSR2 → reset counters
    var sa_usr2 = std.mem.zeroes(linux.Sigaction);
    sa_usr2.__handler = .{ .handler = handleSigusr2 };
    sa_usr2.flags = SA.RESTART;
    _ = linux.sigaction(linux.SIG.USR2, &sa_usr2, null);
}

fn handleSigterm(_: c_int) callconv(.C) void {
    if (global_lifecycle) |lc| lc.stop();
}

fn handleSigusr1(_: c_int) callconv(.C) void {
    if (global_lifecycle) |lc| lc.dumpStats();
}

fn handleSigusr2(_: c_int) callconv(.C) void {
    if (global_lifecycle) |lc| lc.resetStats();
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "lifecycle: state transitions" {
    var lc = Lifecycle.init();
    try testing.expectEqual(State.uninitialized, lc.state);

    try lc.beginInit();
    try testing.expectEqual(State.initializing, lc.state);

    try lc.start();
    try testing.expectEqual(State.running, lc.state);
    try testing.expect(lc.isRunning());

    lc.stop();
    try testing.expectEqual(State.stopping, lc.state);
    try testing.expect(!lc.isRunning());
    try testing.expect(lc.should_stop);

    lc.finalize();
    try testing.expectEqual(State.stopped, lc.state);
}

test "lifecycle: invalid state transition" {
    var lc = Lifecycle.init();
    // Can't start without init
    try testing.expectError(error.InvalidState, lc.start());
    // Can't init twice
    try lc.beginInit();
    try testing.expectError(error.InvalidState, lc.beginInit());
}

test "lifecycle: event callback" {
    const Counter = struct {
        var count: u32 = 0;
        fn cb(_: Event) void {
            count += 1;
        }
    };
    Counter.count = 0;

    var lc = Lifecycle.init();
    lc.event_callback = Counter.cb;
    try lc.beginInit();
    try lc.start();
    // pre_init + pre_start + post_start = 3 events
    try testing.expectEqual(@as(u32, 3), Counter.count);
}

test "lifecycle: stop when not running is no-op" {
    var lc = Lifecycle.init();
    lc.stop(); // should not crash
    try testing.expectEqual(State.uninitialized, lc.state);
}
