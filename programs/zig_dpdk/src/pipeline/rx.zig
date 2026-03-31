/// RX poll loop — the entry point for packets into the pipeline.
///
/// Designed to be pinned to a dedicated CPU core. Tight loop:
///   1. rxBurst() from NIC
///   2. Run pipeline stages
///   3. Enqueue forwarded packets to output ring(s)
///
/// No syscalls, no allocations, no branches on the fast path.
/// When no packets: spinLoopHint (PAUSE instruction) to reduce power.

const std = @import("std");
const config = @import("../core/config.zig");
const mbuf_mod = @import("../core/mbuf.zig");
const pmd = @import("../drivers/pmd.zig");
const ring_mod = @import("../core/ring.zig");
const stats_mod = @import("../core/stats.zig");
const pipeline_mod = @import("pipeline.zig");

const MBuf = mbuf_mod.MBuf;

/// RX loop configuration.
pub const RxConfig = struct {
    /// NIC device to poll.
    device: *pmd.Device,
    /// Which RX queue to poll.
    queue_id: u8,
    /// Max packets per burst.
    burst_size: u16 = config.default_burst_size,
    /// Output ring for forwarded packets (optional — if null, packets are freed).
    output_ring: ?*ring_mod.Ring(*MBuf) = null,
    /// Maximum idle spins before yielding (0 = never yield).
    max_idle_spins: u32 = 0,
};

/// RX loop statistics.
pub const RxStats = struct {
    rx_pkts: u64 = 0,
    rx_bytes: u64 = 0,
    forwarded: u64 = 0,
    dropped: u64 = 0,
    ring_full_drops: u64 = 0,
    empty_polls: u64 = 0,
    bursts: u64 = 0,
    /// Number of consecutive empty polls (resets on successful burst).
    /// Used for adaptive spin: the longer we spin idle, the more PAUSE
    /// instructions we issue per iteration to reduce power and contention.
    consecutive_empty: u32 = 0,
};

/// Run one iteration of the RX poll loop. Returns number of packets received.
/// This is the core function — call it in a tight loop from a pinned core.
///
/// For comptime pipeline composition, use `rxBurstPipeline` which inlines
/// the pipeline stages directly into the poll loop.
pub fn rxPoll(rx_config: *const RxConfig, rx_stats: *RxStats) u16 {
    var bufs: [config.max_burst_size]*MBuf = undefined;
    const burst_size = @min(rx_config.burst_size, config.max_burst_size);

    const nb_rx = rx_config.device.rxBurst(
        rx_config.queue_id,
        &bufs,
        burst_size,
    );

    if (nb_rx == 0) {
        rx_stats.empty_polls += 1;
        rx_stats.consecutive_empty +|= 1;
        // Adaptive spin: issue 1..16 PAUSE instructions based on idle duration.
        // More idle → more PAUSEs → less power, less pipeline contention.
        const spins = @min(rx_stats.consecutive_empty, 16);
        for (0..spins) |_| {
            std.atomic.spinLoopHint();
        }
        return 0;
    }

    rx_stats.consecutive_empty = 0;
    rx_stats.rx_pkts += nb_rx;
    rx_stats.bursts += 1;

    // Count bytes
    for (bufs[0..nb_rx]) |mbuf| {
        rx_stats.rx_bytes += mbuf.pkt_len;
    }

    // Forward to output ring or free
    if (rx_config.output_ring) |ring| {
        var sent: u16 = 0;
        for (bufs[0..nb_rx]) |mbuf| {
            if (ring.enqueue(mbuf)) {
                sent += 1;
            } else {
                // Ring full — drop
                mbuf.free();
                rx_stats.ring_full_drops += 1;
            }
        }
        rx_stats.forwarded += sent;
        rx_stats.dropped += nb_rx - sent;
    } else {
        // No output ring — free all packets
        for (bufs[0..nb_rx]) |mbuf| {
            mbuf.free();
        }
        rx_stats.dropped += nb_rx;
    }

    return nb_rx;
}

/// Run one iteration of the RX poll loop with a comptime pipeline.
/// Packets pass through pipeline stages before being forwarded.
pub fn rxPollWithPipeline(
    comptime stage_types: []const type,
    rx_config: *const RxConfig,
    pipe: *pipeline_mod.Pipeline(stage_types),
    rx_stats: *RxStats,
) u16 {
    var bufs: [config.max_burst_size]*MBuf = undefined;
    const burst_size = @min(rx_config.burst_size, config.max_burst_size);

    const nb_rx = rx_config.device.rxBurst(
        rx_config.queue_id,
        &bufs,
        burst_size,
    );

    if (nb_rx == 0) {
        rx_stats.empty_polls += 1;
        rx_stats.consecutive_empty +|= 1;
        const spins = @min(rx_stats.consecutive_empty, 16);
        for (0..spins) |_| {
            std.atomic.spinLoopHint();
        }
        return 0;
    }

    rx_stats.consecutive_empty = 0;
    rx_stats.rx_pkts += nb_rx;
    rx_stats.bursts += 1;

    // Run pipeline — compacts forwarded packets in bufs
    const forwarded = pipe.processBurst(&bufs, nb_rx);

    // Forward survivors to output ring or free
    if (rx_config.output_ring) |ring| {
        var sent: u16 = 0;
        for (bufs[0..forwarded]) |mbuf| {
            if (ring.enqueue(mbuf)) {
                sent += 1;
            } else {
                mbuf.free();
                rx_stats.ring_full_drops += 1;
            }
        }
        rx_stats.forwarded += sent;
    } else {
        for (bufs[0..forwarded]) |mbuf| {
            mbuf.free();
        }
    }

    rx_stats.dropped += nb_rx - forwarded;
    return nb_rx;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "rx: RxStats initial values" {
    const stats = RxStats{};
    try testing.expectEqual(@as(u64, 0), stats.rx_pkts);
    try testing.expectEqual(@as(u64, 0), stats.empty_polls);
    try testing.expectEqual(@as(u64, 0), stats.ring_full_drops);
}

test "rx: RxConfig defaults" {
    // Just verify the struct can be instantiated with defaults
    const device: pmd.Device = .{ .driver = undefined };
    const rx_config = RxConfig{
        .device = @constCast(&device),
        .queue_id = 0,
    };
    try testing.expectEqual(@as(u16, config.default_burst_size), rx_config.burst_size);
    try testing.expect(rx_config.output_ring == null);
}

// ── Mock PMDs for RX tests ────────────────────────────────────────────

const mock_empty_pmd = struct {
    fn rxBurstFn(_: *pmd.RxQueue, _: []*MBuf, _: u16) u16 {
        return 0; // always empty
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
        return .{ .link_up = true };
    }

    const driver = pmd.PollModeDriver{
        .name = "mock-empty",
        .initFn = initFn,
        .rxBurstFn = rxBurstFn,
        .txBurstFn = txBurstFn,
        .stopFn = stopFn,
        .statsFn = statsFn,
        .linkStatusFn = linkStatusFn,
    };
};

/// Stateful mock: returns pre-loaded packets once, then empty.
const mock_pkt_pmd = struct {
    var pkt_buf: [config.max_burst_size]*MBuf = undefined;
    var pkt_count: u16 = 0;
    var delivered: bool = false;

    fn load(bufs: []const *MBuf) void {
        for (bufs, 0..) |b, i| {
            pkt_buf[i] = b;
        }
        pkt_count = @intCast(bufs.len);
        delivered = false;
    }

    fn rxBurstFn(_: *pmd.RxQueue, bufs: []*MBuf, max_pkts: u16) u16 {
        if (delivered) return 0;
        delivered = true;
        const n = @min(pkt_count, max_pkts);
        for (0..n) |i| {
            bufs[i] = pkt_buf[i];
        }
        return n;
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
        return .{ .link_up = true };
    }

    const driver = pmd.PollModeDriver{
        .name = "mock-pkt",
        .initFn = initFn,
        .rxBurstFn = rxBurstFn,
        .txBurstFn = txBurstFn,
        .stopFn = stopFn,
        .statsFn = statsFn,
        .linkStatusFn = linkStatusFn,
    };
};

test "rx: rxPoll with empty device increments consecutive_empty" {
    var device = pmd.Device{ .driver = &mock_empty_pmd.driver };
    const rx_cfg = RxConfig{
        .device = &device,
        .queue_id = 0,
    };
    var rx_stats = RxStats{};

    // 3 empty polls
    _ = rxPoll(&rx_cfg, &rx_stats);
    try testing.expectEqual(@as(u32, 1), rx_stats.consecutive_empty);

    _ = rxPoll(&rx_cfg, &rx_stats);
    try testing.expectEqual(@as(u32, 2), rx_stats.consecutive_empty);

    _ = rxPoll(&rx_cfg, &rx_stats);
    try testing.expectEqual(@as(u32, 3), rx_stats.consecutive_empty);
    try testing.expectEqual(@as(u64, 3), rx_stats.empty_polls);
}

test "rx: rxPoll receives and forwards to output ring" {
    var pool = try mbuf_mod.MBufPool.create(16, .regular);
    defer pool.destroy();
    pool.populate();

    // Load 3 packets into mock
    const pkt1 = pool.get().?;
    pkt1.pkt_len = 64;
    const pkt2 = pool.get().?;
    pkt2.pkt_len = 128;
    const pkt3 = pool.get().?;
    pkt3.pkt_len = 256;
    mock_pkt_pmd.load(&.{ pkt1, pkt2, pkt3 });

    var device = pmd.Device{ .driver = &mock_pkt_pmd.driver };

    var ring_storage: [8]*MBuf = undefined;
    var ring = ring_mod.Ring(*MBuf).init(&ring_storage, 8);

    const rx_cfg = RxConfig{
        .device = &device,
        .queue_id = 0,
        .output_ring = &ring,
    };
    var rx_stats = RxStats{};

    const nb_rx = rxPoll(&rx_cfg, &rx_stats);
    try testing.expectEqual(@as(u16, 3), nb_rx);
    try testing.expectEqual(@as(u64, 3), rx_stats.rx_pkts);
    try testing.expectEqual(@as(u64, 3), rx_stats.forwarded);
    try testing.expectEqual(@as(u64, 1), rx_stats.bursts);
    try testing.expectEqual(@as(u64, 64 + 128 + 256), rx_stats.rx_bytes);

    // Verify packets are in ring
    try testing.expectEqual(@as(u32, 3), ring.count());

    // Clean up
    while (ring.dequeue()) |mbuf| mbuf.free();
}

test "rx: rxPoll with full ring drops packets" {
    var pool = try mbuf_mod.MBufPool.create(16, .regular);
    defer pool.destroy();
    pool.populate();

    // Load 4 packets into mock
    var pkts: [4]*MBuf = undefined;
    for (&pkts) |*p| {
        p.* = pool.get().?;
        p.*.pkt_len = 64;
    }
    mock_pkt_pmd.load(&pkts);

    var device = pmd.Device{ .driver = &mock_pkt_pmd.driver };

    // Ring of size 2 — only 1 usable slot (power-of-2 ring wastes 1)
    // Use size 4 to get 3 usable slots, pre-fill 1 to leave only 2
    var ring_storage: [4]*MBuf = undefined;
    var ring = ring_mod.Ring(*MBuf).init(&ring_storage, 4);

    // Pre-fill ring to leave exactly 2 slots
    const filler = pool.get().?;
    filler.pkt_len = 1;
    _ = ring.enqueue(filler);

    const rx_cfg = RxConfig{
        .device = &device,
        .queue_id = 0,
        .output_ring = &ring,
    };
    var rx_stats = RxStats{};

    const nb_rx = rxPoll(&rx_cfg, &rx_stats);
    try testing.expectEqual(@as(u16, 4), nb_rx);
    try testing.expectEqual(@as(u64, 4), rx_stats.rx_pkts);
    // Ring had limited free slots — some packets should be ring_full_drops
    try testing.expect(rx_stats.ring_full_drops > 0);
    // forwarded + dropped always equals nb_rx (dropped includes ring_full_drops)
    try testing.expectEqual(@as(u64, nb_rx), rx_stats.forwarded + rx_stats.dropped);

    // Clean up
    while (ring.dequeue()) |mbuf| mbuf.free();
}

test "rx: consecutive_empty resets on successful burst" {
    var pool = try mbuf_mod.MBufPool.create(16, .regular);
    defer pool.destroy();
    pool.populate();

    var device_empty = pmd.Device{ .driver = &mock_empty_pmd.driver };
    var device_pkt = pmd.Device{ .driver = &mock_pkt_pmd.driver };

    var rx_stats = RxStats{};

    // Empty polls accumulate consecutive_empty
    const rx_cfg_empty = RxConfig{ .device = &device_empty, .queue_id = 0 };
    _ = rxPoll(&rx_cfg_empty, &rx_stats);
    _ = rxPoll(&rx_cfg_empty, &rx_stats);
    _ = rxPoll(&rx_cfg_empty, &rx_stats);
    try testing.expectEqual(@as(u32, 3), rx_stats.consecutive_empty);

    // Successful burst resets it
    const pkt = pool.get().?;
    pkt.pkt_len = 64;
    mock_pkt_pmd.load(&.{pkt});

    const rx_cfg_pkt = RxConfig{ .device = &device_pkt, .queue_id = 0 };
    _ = rxPoll(&rx_cfg_pkt, &rx_stats);
    try testing.expectEqual(@as(u32, 0), rx_stats.consecutive_empty);
    try testing.expectEqual(@as(u64, 1), rx_stats.rx_pkts);
}
