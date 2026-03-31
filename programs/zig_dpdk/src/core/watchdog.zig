/// Error recovery and watchdog for zig_dpdk.
///
/// Monitors NIC health and recovers from faults:
///   - TX hang detection: if no TX completions for >1s, reset the queue
///   - Link flap: detect link down, pause traffic, wait for link up
///   - Memory pressure: warn when free mbufs drop below threshold
///
/// The watchdog runs on the control path (not the hot path).
/// It is called periodically (e.g., once per second) from the lifecycle
/// controller or a dedicated management thread.

const std = @import("std");
const config = @import("config.zig");
const stats_mod = @import("stats.zig");

/// Watchdog action returned to the caller.
pub const WatchdogAction = enum {
    ok,
    tx_queue_reset,
    link_down_pause,
    link_restored,
    memory_warning,
    memory_critical,
};

/// Per-queue TX hang detector.
pub const TxHangDetector = struct {
    last_tx_packets: u64 = 0,
    stall_ticks: u32 = 0,
    /// Number of ticks with zero TX progress before declaring a hang.
    hang_threshold: u32 = 5,
    resets: u32 = 0,

    /// Check for TX progress. Call once per watchdog tick.
    /// Returns true if the queue appears hung.
    pub fn check(self: *TxHangDetector, current_tx_packets: u64) bool {
        if (current_tx_packets == self.last_tx_packets and current_tx_packets > 0) {
            self.stall_ticks += 1;
        } else {
            self.stall_ticks = 0;
        }
        self.last_tx_packets = current_tx_packets;
        return self.stall_ticks >= self.hang_threshold;
    }

    /// Record that a reset was performed.
    pub fn recordReset(self: *TxHangDetector) void {
        self.resets += 1;
        self.stall_ticks = 0;
        self.last_tx_packets = 0;
    }
};

/// Link state monitor.
pub const LinkMonitor = struct {
    link_up: bool = false,
    flap_count: u32 = 0,
    down_ticks: u32 = 0,

    /// Update link state. Returns the action to take.
    pub fn update(self: *LinkMonitor, current_link_up: bool) WatchdogAction {
        const prev = self.link_up;
        self.link_up = current_link_up;

        if (prev and !current_link_up) {
            // Link just went down
            self.flap_count += 1;
            self.down_ticks = 0;
            return .link_down_pause;
        }

        if (!prev and current_link_up) {
            // Link restored
            self.down_ticks = 0;
            return .link_restored;
        }

        if (!current_link_up) {
            self.down_ticks += 1;
        }

        return .ok;
    }

    /// True if the link has been down for more than the given number of ticks.
    pub fn isExtendedOutage(self: *const LinkMonitor, threshold: u32) bool {
        return !self.link_up and self.down_ticks > threshold;
    }
};

/// Memory pool pressure monitor.
pub const MemoryMonitor = struct {
    pool_total: u32 = 0,
    /// Fraction (0-100) below which to warn.
    warning_pct: u32 = 10,
    /// Fraction (0-100) below which it's critical.
    critical_pct: u32 = 2,

    pub fn init(pool_total: u32) MemoryMonitor {
        return .{ .pool_total = pool_total };
    }

    /// Check free buffer count against thresholds.
    pub fn check(self: *const MemoryMonitor, free_count: u32) WatchdogAction {
        if (self.pool_total == 0) return .ok;
        const pct = (free_count * 100) / self.pool_total;
        if (pct <= self.critical_pct) return .memory_critical;
        if (pct <= self.warning_pct) return .memory_warning;
        return .ok;
    }

    /// Returns the percentage of buffers currently free.
    pub fn freePct(self: *const MemoryMonitor, free_count: u32) u32 {
        if (self.pool_total == 0) return 100;
        return (free_count * 100) / self.pool_total;
    }
};

/// Combined watchdog that monitors all subsystems.
pub const Watchdog = struct {
    tx_detectors: [config.max_queues_per_port]TxHangDetector =
        [_]TxHangDetector{.{}} ** config.max_queues_per_port,
    link: LinkMonitor = .{},
    memory: MemoryMonitor = .{},
    tick_count: u64 = 0,
    actions_taken: u64 = 0,
    queue_count: u8 = 0,

    pub fn init(queue_count: u8, pool_total: u32) Watchdog {
        return .{
            .queue_count = queue_count,
            .memory = MemoryMonitor.init(pool_total),
        };
    }

    /// Run one watchdog tick. Returns the most severe action needed.
    pub fn tick(
        self: *Watchdog,
        queue_tx_packets: []const u64,
        link_up: bool,
        mbuf_free: u32,
    ) WatchdogAction {
        self.tick_count += 1;
        var worst: WatchdogAction = .ok;

        // Check TX queues for hangs
        const n = @min(self.queue_count, @as(u8, @intCast(queue_tx_packets.len)));
        for (0..n) |i| {
            if (self.tx_detectors[i].check(queue_tx_packets[i])) {
                worst = .tx_queue_reset;
            }
        }

        // Check link state
        const link_action = self.link.update(link_up);
        if (@intFromEnum(link_action) > @intFromEnum(worst)) {
            worst = link_action;
        }

        // Check memory pressure
        const mem_action = self.memory.check(mbuf_free);
        if (@intFromEnum(mem_action) > @intFromEnum(worst)) {
            worst = mem_action;
        }

        if (worst != .ok) {
            self.actions_taken += 1;
        }

        return worst;
    }
};

// -- Tests --------------------------------------------------------------------

const testing = std.testing;

test "watchdog: tx hang detection" {
    var det = TxHangDetector{ .hang_threshold = 3 };

    // Progressing TX — no hang
    try testing.expect(!det.check(100));
    try testing.expect(!det.check(200));
    try testing.expect(!det.check(300));

    // Stalled at 300 for 3 ticks
    try testing.expect(!det.check(300));
    try testing.expect(!det.check(300));
    try testing.expect(det.check(300)); // 3rd stall → hung

    // Reset clears state
    det.recordReset();
    try testing.expectEqual(@as(u32, 1), det.resets);
    try testing.expectEqual(@as(u32, 0), det.stall_ticks);
}

test "watchdog: tx hang clears on progress" {
    var det = TxHangDetector{ .hang_threshold = 3 };

    try testing.expect(!det.check(100));
    try testing.expect(!det.check(100)); // stall 1
    try testing.expect(!det.check(100)); // stall 2
    try testing.expect(!det.check(200)); // progress resets stall
    try testing.expect(!det.check(200)); // stall 1 again
    try testing.expect(!det.check(200)); // stall 2
    try testing.expect(det.check(200)); // stall 3 → hung
}

test "watchdog: link monitor transitions" {
    var lm = LinkMonitor{};

    // Start down, come up
    try testing.expectEqual(WatchdogAction.ok, lm.update(false));
    try testing.expectEqual(WatchdogAction.link_restored, lm.update(true));

    // Stay up
    try testing.expectEqual(WatchdogAction.ok, lm.update(true));

    // Go down
    try testing.expectEqual(WatchdogAction.link_down_pause, lm.update(false));
    try testing.expectEqual(@as(u32, 1), lm.flap_count);

    // Stay down
    try testing.expectEqual(WatchdogAction.ok, lm.update(false));
    try testing.expect(lm.down_ticks > 0);

    // Come back up
    try testing.expectEqual(WatchdogAction.link_restored, lm.update(true));
}

test "watchdog: link extended outage" {
    var lm = LinkMonitor{};
    _ = lm.update(true);
    _ = lm.update(false); // link down

    for (0..10) |_| _ = lm.update(false);

    try testing.expect(lm.isExtendedOutage(5));
    try testing.expect(!lm.isExtendedOutage(20));
}

test "watchdog: memory pressure" {
    const mm = MemoryMonitor.init(1000);

    try testing.expectEqual(WatchdogAction.ok, mm.check(500)); // 50% free
    try testing.expectEqual(WatchdogAction.ok, mm.check(110)); // 11% free
    try testing.expectEqual(WatchdogAction.memory_warning, mm.check(100)); // 10% free
    try testing.expectEqual(WatchdogAction.memory_warning, mm.check(50)); // 5% free
    try testing.expectEqual(WatchdogAction.memory_critical, mm.check(20)); // 2% free
    try testing.expectEqual(WatchdogAction.memory_critical, mm.check(0)); // 0% free
}

test "watchdog: memory free percentage" {
    const mm = MemoryMonitor.init(4096);
    try testing.expectEqual(@as(u32, 50), mm.freePct(2048));
    try testing.expectEqual(@as(u32, 0), mm.freePct(0));
    try testing.expectEqual(@as(u32, 100), mm.freePct(4096));
}

test "watchdog: combined tick" {
    var wd = Watchdog.init(2, 1000);

    // First tick with link_up — transitions from initial false→true
    var tx = [_]u64{ 100, 200 };
    try testing.expectEqual(WatchdogAction.link_restored, wd.tick(&tx, true, 500));

    // TX progressing, link up, memory ok
    tx = [_]u64{ 200, 400 };
    try testing.expectEqual(WatchdogAction.ok, wd.tick(&tx, true, 500));

    // Memory pressure
    tx = [_]u64{ 300, 600 };
    try testing.expectEqual(WatchdogAction.memory_critical, wd.tick(&tx, true, 10));
    try testing.expect(wd.actions_taken > 0);
}

test "watchdog: zero pool is always ok" {
    const mm = MemoryMonitor.init(0);
    try testing.expectEqual(WatchdogAction.ok, mm.check(0));
    try testing.expectEqual(@as(u32, 100), mm.freePct(0));
}
