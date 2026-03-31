/// Top-level pipeline orchestrator.
///
/// Ties together RX poll, TX drain, flow distributor, lifecycle management,
/// and watchdog monitoring into a single run loop. One Runner per NIC port.
///
/// Usage:
///   var runner = Runner.init(.{
///       .device = &device,
///       .num_rx_queues = 2,
///       .num_tx_queues = 2,
///       .num_workers = 4,
///       .pool = &pool,
///   });
///   runner.run(); // blocks until lifecycle.stop() or signal

const std = @import("std");
const config = @import("../core/config.zig");
const mbuf_mod = @import("../core/mbuf.zig");
const pmd = @import("../drivers/pmd.zig");
const ring_mod = @import("../core/ring.zig");
const stats_mod = @import("../core/stats.zig");
const lifecycle_mod = @import("../core/lifecycle.zig");
const watchdog_mod = @import("../core/watchdog.zig");
const telemetry_mod = @import("../core/telemetry.zig");
const rx_mod = @import("rx.zig");
const tx_mod = @import("tx.zig");
const distributor_mod = @import("distributor.zig");

const MBuf = mbuf_mod.MBuf;

/// Maximum queues the runner supports (matches config.max_queues_per_port).
const MAX_QUEUES: u8 = config.max_queues_per_port;

/// Read monotonic clock in nanoseconds.
fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    const ns: i128 = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
    return if (ns > 0) @intCast(ns) else 0;
}

/// Runner configuration.
pub const RunnerConfig = struct {
    device: *pmd.Device,
    num_rx_queues: u8 = 1,
    num_tx_queues: u8 = 1,
    num_workers: u8 = 1,
    burst_size: u16 = config.default_burst_size,
    flush_timeout_us: u64 = 100,
    /// How often to run the watchdog tick (nanoseconds). Default 1 second.
    watchdog_interval_ns: u64 = 1_000_000_000,
    pool: ?*mbuf_mod.MBufPool = null,
};

/// Aggregated runner statistics.
pub const RunnerStats = struct {
    total_rx_pkts: u64 = 0,
    total_tx_pkts: u64 = 0,
    total_rx_bytes: u64 = 0,
    total_tx_bytes: u64 = 0,
    total_rx_drops: u64 = 0,
    total_tx_errors: u64 = 0,
    total_empty_polls: u64 = 0,
    total_flushes: u64 = 0,
    poll_iterations: u64 = 0,
};

/// Pipeline runner — the main entry point for packet processing.
pub const Runner = struct {
    cfg: RunnerConfig,
    lifecycle: lifecycle_mod.Lifecycle,
    watchdog: watchdog_mod.Watchdog,

    // Per-queue state
    rx_configs: [MAX_QUEUES]rx_mod.RxConfig,
    rx_stats: [MAX_QUEUES]rx_mod.RxStats,
    tx_configs: [MAX_QUEUES]tx_mod.TxConfig,
    tx_stats: [MAX_QUEUES]tx_mod.TxStats,
    tx_batches: [MAX_QUEUES]tx_mod.TxBatch,

    // Worker output rings — packets flow from RX → worker rings → TX
    worker_ring_storage: [distributor_mod.MAX_WORKERS][1024]*MBuf,
    worker_rings: [distributor_mod.MAX_WORKERS]ring_mod.Ring(*MBuf),

    // Distributor
    dist_config: distributor_mod.DistributorConfig,
    dist_stats: distributor_mod.DistributorStats,

    // Watchdog timing
    last_watchdog_ns: u64,

    // Total poll count
    poll_iterations: u64,

    pub fn init(cfg: RunnerConfig) Runner {
        var self: Runner = undefined;
        self.cfg = cfg;
        self.lifecycle = lifecycle_mod.Lifecycle.init();
        self.watchdog = watchdog_mod.Watchdog.init(
            cfg.num_tx_queues,
            if (cfg.pool) |p| p.capacity else 0,
        );
        self.last_watchdog_ns = 0;
        self.poll_iterations = 0;

        // Init worker rings
        for (0..distributor_mod.MAX_WORKERS) |i| {
            self.worker_ring_storage[i] = undefined;
            self.worker_rings[i] = ring_mod.Ring(*MBuf).init(
                &self.worker_ring_storage[i],
                1024,
            );
        }

        // Init distributor
        self.dist_config = distributor_mod.DistributorConfig.init(cfg.num_workers);
        for (0..cfg.num_workers) |i| {
            self.dist_config.output_rings[i] = &self.worker_rings[i];
        }
        self.dist_stats = .{};

        // Init RX queues
        for (0..MAX_QUEUES) |i| {
            self.rx_configs[i] = .{
                .device = cfg.device,
                .queue_id = @intCast(i),
                .burst_size = cfg.burst_size,
                .output_ring = if (i < cfg.num_workers) &self.worker_rings[i] else null,
            };
            self.rx_stats[i] = .{};
        }

        // Init TX queues
        for (0..MAX_QUEUES) |i| {
            self.tx_configs[i] = .{
                .device = cfg.device,
                .queue_id = @intCast(i),
                .burst_size = cfg.burst_size,
                .input_ring = if (i < cfg.num_workers) &self.worker_rings[i] else null,
                .flush_timeout_us = cfg.flush_timeout_us,
            };
            self.tx_stats[i] = .{};
            self.tx_batches[i] = .{};
        }

        return self;
    }

    /// Run one poll iteration: RX all queues, TX drain all queues.
    /// Returns total packets received across all RX queues.
    pub fn poll(self: *Runner) u32 {
        var total_rx: u32 = 0;
        self.poll_iterations += 1;

        // RX burst on all active queues
        for (0..self.cfg.num_rx_queues) |i| {
            const nb_rx = rx_mod.rxPoll(&self.rx_configs[i], &self.rx_stats[i]);
            total_rx += nb_rx;
        }

        // TX drain on all active queues
        for (0..self.cfg.num_tx_queues) |i| {
            _ = tx_mod.txDrain(&self.tx_configs[i], &self.tx_batches[i], &self.tx_stats[i]);
        }

        return total_rx;
    }

    /// Main run loop — blocks until lifecycle.stop() is called.
    pub fn run(self: *Runner) void {
        self.lifecycle.beginInit() catch return;
        self.lifecycle.start() catch return;
        self.lifecycle.installSignalHandlers();
        self.last_watchdog_ns = nowNs();

        while (self.lifecycle.isRunning()) {
            _ = self.poll();

            // Periodic watchdog
            const now = nowNs();
            if (now -| self.last_watchdog_ns >= self.cfg.watchdog_interval_ns) {
                self.tickWatchdog();
                self.last_watchdog_ns = now;
            }
        }

        // Drain all TX batches on shutdown
        self.drainAll();
        self.lifecycle.finalize();
    }

    /// Flush all pending TX batches (shutdown path).
    pub fn drainAll(self: *Runner) void {
        for (0..self.cfg.num_tx_queues) |i| {
            if (self.tx_batches[i].hasPending()) {
                _ = self.tx_batches[i].flush(
                    self.cfg.device,
                    @intCast(i),
                    &self.tx_stats[i],
                );
            }
        }
    }

    /// Run one watchdog tick — aggregate TX stats and check health.
    pub fn tickWatchdog(self: *Runner) void {
        var tx_packets: [MAX_QUEUES]u64 = [_]u64{0} ** MAX_QUEUES;
        for (0..self.cfg.num_tx_queues) |i| {
            tx_packets[i] = self.tx_stats[i].tx_pkts;
        }

        const link = self.cfg.device.getLinkStatus();
        const mbuf_free: u32 = if (self.cfg.pool) |p| p.availableCount() else 0;

        _ = self.watchdog.tick(&tx_packets, link.link_up, mbuf_free);
    }

    /// Aggregate statistics from all queues.
    pub fn getStats(self: *const Runner) RunnerStats {
        var s = RunnerStats{};
        s.poll_iterations = self.poll_iterations;

        for (0..self.cfg.num_rx_queues) |i| {
            s.total_rx_pkts += self.rx_stats[i].rx_pkts;
            s.total_rx_bytes += self.rx_stats[i].rx_bytes;
            s.total_rx_drops += self.rx_stats[i].dropped + self.rx_stats[i].ring_full_drops;
            s.total_empty_polls += self.rx_stats[i].empty_polls;
        }

        for (0..self.cfg.num_tx_queues) |i| {
            s.total_tx_pkts += self.tx_stats[i].tx_pkts;
            s.total_tx_bytes += self.tx_stats[i].tx_bytes;
            s.total_tx_errors += self.tx_stats[i].tx_errors;
            s.total_flushes += self.tx_stats[i].flushes;
        }

        return s;
    }

    /// Build a SystemTelemetry snapshot from current runner state.
    pub fn getTelemetry(self: *const Runner) telemetry_mod.SystemTelemetry {
        var telem = telemetry_mod.SystemTelemetry{};
        telem.port_count = 1;
        telem.ports[0].port_id = self.cfg.device.port_id;

        // Aggregate RX across queues
        for (0..self.cfg.num_rx_queues) |i| {
            telem.ports[0].rx_packets += self.rx_stats[i].rx_pkts;
            telem.ports[0].rx_bytes += self.rx_stats[i].rx_bytes;
            telem.ports[0].rx_drops += self.rx_stats[i].dropped + self.rx_stats[i].ring_full_drops;
        }

        // Aggregate TX across queues
        for (0..self.cfg.num_tx_queues) |i| {
            telem.ports[0].tx_packets += self.tx_stats[i].tx_pkts;
            telem.ports[0].tx_bytes += self.tx_stats[i].tx_bytes;
            telem.ports[0].tx_errors += self.tx_stats[i].tx_errors;
        }

        // Link status
        const link = self.cfg.device.getLinkStatus();
        telem.ports[0].link_up = link.link_up;
        telem.ports[0].link_speed_mbps = @intFromEnum(link.speed);

        // Pool status
        if (self.cfg.pool) |p| {
            telem.mbuf_pool_total = p.capacity;
            telem.mbuf_pool_free = p.availableCount();
        }

        return telem;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

const mock_runner_pmd = struct {
    fn rxBurstFn(_: *pmd.RxQueue, _: []*MBuf, _: u16) u16 {
        return 0;
    }

    fn txBurstFn(_: *pmd.TxQueue, _: []*MBuf, nb_pkts: u16) u16 {
        return nb_pkts;
    }

    fn initFn(_: *pmd.DeviceConfig) pmd.PmdError!*pmd.Device {
        return error.UnsupportedDevice;
    }

    fn stopFn(_: *pmd.Device) void {}

    fn statsFn(_: *const pmd.Device) stats_mod.PortStats {
        return .{};
    }

    fn linkStatusFn(_: *const pmd.Device) pmd.LinkStatus {
        return .{ .link_up = true, .speed = .speed_10g };
    }

    const driver = pmd.PollModeDriver{
        .name = "mock-runner",
        .initFn = initFn,
        .rxBurstFn = rxBurstFn,
        .txBurstFn = txBurstFn,
        .stopFn = stopFn,
        .statsFn = statsFn,
        .linkStatusFn = linkStatusFn,
    };
};

test "runner: init with defaults" {
    var device = pmd.Device{ .driver = &mock_runner_pmd.driver };

    const runner = Runner.init(.{
        .device = &device,
        .num_rx_queues = 2,
        .num_tx_queues = 2,
        .num_workers = 4,
    });

    try testing.expectEqual(@as(u8, 2), runner.cfg.num_rx_queues);
    try testing.expectEqual(@as(u8, 2), runner.cfg.num_tx_queues);
    try testing.expectEqual(@as(u8, 4), runner.cfg.num_workers);
    try testing.expectEqual(lifecycle_mod.State.uninitialized, runner.lifecycle.state);
    try testing.expectEqual(@as(u64, 0), runner.poll_iterations);
}

test "runner: poll with no packets returns zero" {
    var device = pmd.Device{ .driver = &mock_runner_pmd.driver };

    var runner = Runner.init(.{
        .device = &device,
        .num_rx_queues = 1,
        .num_tx_queues = 1,
        .num_workers = 1,
    });

    const nb_rx = runner.poll();
    try testing.expectEqual(@as(u32, 0), nb_rx);
    try testing.expectEqual(@as(u64, 1), runner.poll_iterations);
    try testing.expectEqual(@as(u64, 1), runner.rx_stats[0].empty_polls);
}

test "runner: getStats aggregates correctly" {
    var device = pmd.Device{ .driver = &mock_runner_pmd.driver };

    var runner = Runner.init(.{
        .device = &device,
        .num_rx_queues = 2,
        .num_tx_queues = 2,
        .num_workers = 2,
    });

    // Manually set stats to verify aggregation
    runner.rx_stats[0].rx_pkts = 100;
    runner.rx_stats[0].rx_bytes = 6400;
    runner.rx_stats[0].dropped = 5;
    runner.rx_stats[1].rx_pkts = 200;
    runner.rx_stats[1].rx_bytes = 12800;
    runner.rx_stats[1].ring_full_drops = 3;

    runner.tx_stats[0].tx_pkts = 90;
    runner.tx_stats[0].tx_bytes = 5760;
    runner.tx_stats[0].tx_errors = 2;
    runner.tx_stats[0].flushes = 10;
    runner.tx_stats[1].tx_pkts = 180;
    runner.tx_stats[1].tx_bytes = 11520;
    runner.tx_stats[1].flushes = 20;

    runner.poll_iterations = 1000;

    const s = runner.getStats();
    try testing.expectEqual(@as(u64, 300), s.total_rx_pkts);
    try testing.expectEqual(@as(u64, 19200), s.total_rx_bytes);
    try testing.expectEqual(@as(u64, 8), s.total_rx_drops); // 5 dropped + 3 ring_full
    try testing.expectEqual(@as(u64, 270), s.total_tx_pkts);
    try testing.expectEqual(@as(u64, 17280), s.total_tx_bytes);
    try testing.expectEqual(@as(u64, 2), s.total_tx_errors);
    try testing.expectEqual(@as(u64, 30), s.total_flushes);
    try testing.expectEqual(@as(u64, 1000), s.poll_iterations);
}

test "runner: getTelemetry aggregates ports" {
    var device = pmd.Device{ .driver = &mock_runner_pmd.driver, .port_id = 7 };

    var pool = try mbuf_mod.MBufPool.create(64, .regular);
    defer pool.destroy();
    pool.populate();

    var runner = Runner.init(.{
        .device = &device,
        .num_rx_queues = 1,
        .num_tx_queues = 1,
        .num_workers = 1,
        .pool = &pool,
    });

    runner.rx_stats[0].rx_pkts = 500;
    runner.rx_stats[0].rx_bytes = 32000;
    runner.tx_stats[0].tx_pkts = 480;
    runner.tx_stats[0].tx_bytes = 30720;
    runner.tx_stats[0].tx_errors = 1;

    const telem = runner.getTelemetry();
    try testing.expectEqual(@as(u8, 1), telem.port_count);
    try testing.expectEqual(@as(u8, 7), telem.ports[0].port_id);
    try testing.expectEqual(@as(u64, 500), telem.ports[0].rx_packets);
    try testing.expectEqual(@as(u64, 480), telem.ports[0].tx_packets);
    try testing.expectEqual(@as(u64, 1), telem.ports[0].tx_errors);
    try testing.expect(telem.ports[0].link_up);
    try testing.expectEqual(@as(u32, 10000), telem.ports[0].link_speed_mbps);
    try testing.expectEqual(@as(u32, 64), telem.mbuf_pool_total);
    try testing.expectEqual(@as(u32, 64), telem.mbuf_pool_free);
}

test "runner: lifecycle transitions through runner" {
    var device = pmd.Device{ .driver = &mock_runner_pmd.driver };

    var runner = Runner.init(.{
        .device = &device,
        .num_rx_queues = 1,
        .num_tx_queues = 1,
        .num_workers = 1,
    });

    try testing.expectEqual(lifecycle_mod.State.uninitialized, runner.lifecycle.state);

    try runner.lifecycle.beginInit();
    try testing.expectEqual(lifecycle_mod.State.initializing, runner.lifecycle.state);

    try runner.lifecycle.start();
    try testing.expectEqual(lifecycle_mod.State.running, runner.lifecycle.state);
    try testing.expect(runner.lifecycle.isRunning());

    runner.lifecycle.stop();
    try testing.expectEqual(lifecycle_mod.State.stopping, runner.lifecycle.state);
    try testing.expect(!runner.lifecycle.isRunning());

    runner.lifecycle.finalize();
    try testing.expectEqual(lifecycle_mod.State.stopped, runner.lifecycle.state);
}
