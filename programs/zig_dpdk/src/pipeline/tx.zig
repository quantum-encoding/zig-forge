/// TX drain loop — transmits packets from processing cores to the NIC.
///
/// Designed to be pinned to a dedicated CPU core. Drains input ring(s)
/// and batches into txBurst calls for doorbell amortisation.
///
/// Features:
///   - Batching: accumulates packets up to burst_size before calling txBurst
///   - Flush timer: if fewer than burst_size packets pending after flush_timeout_us,
///     flush anyway to prevent latency spikes for low-rate flows
///   - Zero-allocation on the fast path

const std = @import("std");
const config = @import("../core/config.zig");
const mbuf_mod = @import("../core/mbuf.zig");
const pmd = @import("../drivers/pmd.zig");
const ring_mod = @import("../core/ring.zig");
const stats_mod = @import("../core/stats.zig");

const MBuf = mbuf_mod.MBuf;

/// Read monotonic clock in nanoseconds. Uses clock_gettime(MONOTONIC) which
/// is vDSO-accelerated on Linux (~20ns). Same pattern as lifecycle.zig:74.
fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    const ns: i128 = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
    return if (ns > 0) @intCast(ns) else 0;
}

/// TX loop configuration.
pub const TxConfig = struct {
    /// NIC device for transmission.
    device: *pmd.Device,
    /// Which TX queue to use.
    queue_id: u8,
    /// Target burst size for batching.
    burst_size: u16 = config.default_burst_size,
    /// Input ring to drain packets from.
    input_ring: ?*ring_mod.Ring(*MBuf) = null,
    /// Flush timeout in microseconds (0 = no timeout, always batch).
    flush_timeout_us: u64 = 100,
};

/// TX loop statistics.
pub const TxStats = struct {
    tx_pkts: u64 = 0,
    tx_bytes: u64 = 0,
    tx_errors: u64 = 0,
    flushes: u64 = 0,
    bursts: u64 = 0,
    empty_polls: u64 = 0,
};

/// TX batch buffer — accumulates packets for batched transmission.
pub const TxBatch = struct {
    bufs: [config.max_burst_size]*MBuf = undefined,
    count: u16 = 0,
    last_flush_time: u64 = 0, // nanoseconds from Timer

    /// Add a packet to the batch. Returns true if accepted.
    pub fn add(self: *TxBatch, mbuf: *MBuf) bool {
        if (self.count >= config.max_burst_size) return false;
        self.bufs[self.count] = mbuf;
        self.count += 1;
        return true;
    }

    /// Flush the batch via txBurst. Returns number of packets sent.
    pub fn flush(self: *TxBatch, device: *pmd.Device, queue_id: u8, tx_stats: *TxStats) u16 {
        if (self.count == 0) return 0;

        const sent = device.txBurst(queue_id, &self.bufs, self.count);
        tx_stats.tx_pkts += sent;
        tx_stats.bursts += 1;

        // Count bytes
        for (self.bufs[0..sent]) |mbuf| {
            tx_stats.tx_bytes += mbuf.pkt_len;
        }

        // Free unsent packets (caller retains ownership)
        if (sent < self.count) {
            const unsent = self.count - sent;
            tx_stats.tx_errors += unsent;
            for (self.bufs[sent..self.count]) |mbuf| {
                mbuf.free();
            }
        }

        self.count = 0;
        self.last_flush_time = nowNs();
        tx_stats.flushes += 1;
        return sent;
    }

    /// Check if batch is full and should be flushed.
    pub fn isFull(self: *const TxBatch) bool {
        return self.count >= config.max_burst_size;
    }

    /// Check if batch has any pending packets.
    pub fn hasPending(self: *const TxBatch) bool {
        return self.count > 0;
    }
};

/// Run one iteration of the TX drain loop. Returns packets sent.
pub fn txDrain(tx_config: *const TxConfig, batch: *TxBatch, tx_stats: *TxStats) u16 {
    // Drain input ring into batch
    if (tx_config.input_ring) |ring| {
        while (!batch.isFull()) {
            const mbuf = ring.dequeue() orelse break;
            if (!batch.add(mbuf)) break;
        }
    }

    // Flush if batch is full — no timer check, no nowNs() call
    if (batch.isFull()) {
        return batch.flush(tx_config.device, tx_config.queue_id, tx_stats);
    }

    // Flush on timeout if we have pending packets
    if (batch.hasPending()) {
        if (tx_config.flush_timeout_us > 0) {
            const now = nowNs();
            // Saturating subtraction handles initial last_flush_time=0 correctly:
            // first call with pending always flushes because elapsed >= timeout.
            const elapsed_ns = now -| batch.last_flush_time;
            const timeout_ns = tx_config.flush_timeout_us * 1000;
            if (elapsed_ns >= timeout_ns) {
                return batch.flush(tx_config.device, tx_config.queue_id, tx_stats);
            }
        }
        // timeout=0 means never timer-flush (only flush on batch full)
        return 0;
    }

    tx_stats.empty_polls += 1;
    return 0;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "tx: TxBatch add and count" {
    var batch = TxBatch{};
    try testing.expectEqual(@as(u16, 0), batch.count);
    try testing.expect(!batch.hasPending());
    try testing.expect(!batch.isFull());
}

test "tx: TxStats initial values" {
    const stats = TxStats{};
    try testing.expectEqual(@as(u64, 0), stats.tx_pkts);
    try testing.expectEqual(@as(u64, 0), stats.tx_errors);
}

test "tx: TxConfig defaults" {
    const device: pmd.Device = .{ .driver = undefined };
    const tx_cfg = TxConfig{
        .device = @constCast(&device),
        .queue_id = 0,
    };
    try testing.expectEqual(@as(u16, config.default_burst_size), tx_cfg.burst_size);
    try testing.expectEqual(@as(u64, 100), tx_cfg.flush_timeout_us);
}

// ── Mock PMD for TX tests ─────────────────────────────────────────────

const mock_tx = struct {
    /// Mock txBurst: accepts all packets (returns nb_pkts).
    fn txBurstFn(_: *pmd.TxQueue, _: []*MBuf, nb_pkts: u16) u16 {
        return nb_pkts;
    }

    fn rxBurstFn(_: *pmd.RxQueue, _: []*MBuf, _: u16) u16 {
        return 0;
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
        .name = "mock-tx",
        .initFn = initFn,
        .rxBurstFn = rxBurstFn,
        .txBurstFn = txBurstFn,
        .stopFn = stopFn,
        .statsFn = statsFn,
        .linkStatusFn = linkStatusFn,
    };
};

test "tx: txDrain with mock device drains ring" {
    // Setup mock device
    var device = pmd.Device{ .driver = &mock_tx.driver };

    // Setup input ring
    var ring_storage: [4]*MBuf = undefined;
    var ring = ring_mod.Ring(*MBuf).init(&ring_storage, 4);

    // Create pool and packets
    var pool = try mbuf_mod.MBufPool.create(8, .regular);
    defer pool.destroy();
    pool.populate();

    const pkt1 = pool.get().?;
    pkt1.pkt_len = 64;
    const pkt2 = pool.get().?;
    pkt2.pkt_len = 128;

    _ = ring.enqueue(pkt1);
    _ = ring.enqueue(pkt2);

    const tx_cfg = TxConfig{
        .device = &device,
        .queue_id = 0,
        .burst_size = 32,
        .input_ring = &ring,
        .flush_timeout_us = 0, // never timer-flush
    };
    var batch = TxBatch{};
    var tx_stats = TxStats{};

    // Drain — should pull 2 packets from ring into batch, but NOT flush (timeout=0, batch not full)
    const sent = txDrain(&tx_cfg, &batch, &tx_stats);
    try testing.expectEqual(@as(u16, 0), sent);
    try testing.expectEqual(@as(u16, 2), batch.count);
    try testing.expect(ring.isEmpty());
}

test "tx: txDrain full batch flushes immediately" {
    var device = pmd.Device{ .driver = &mock_tx.driver };

    var ring_storage: [128]*MBuf = undefined;
    var ring = ring_mod.Ring(*MBuf).init(&ring_storage, 128);

    var pool = try mbuf_mod.MBufPool.create(128, .regular);
    defer pool.destroy();
    pool.populate();

    // Fill ring with max_burst_size packets to trigger a full-batch flush
    for (0..config.max_burst_size) |_| {
        const pkt = pool.get().?;
        pkt.pkt_len = 64;
        _ = ring.enqueue(pkt);
    }

    const tx_cfg = TxConfig{
        .device = &device,
        .queue_id = 0,
        .burst_size = config.max_burst_size,
        .input_ring = &ring,
        .flush_timeout_us = 0, // no timer — flush only when full
    };
    var batch = TxBatch{};
    var tx_stats = TxStats{};

    const sent = txDrain(&tx_cfg, &batch, &tx_stats);
    try testing.expectEqual(config.max_burst_size, sent);
    try testing.expectEqual(@as(u64, config.max_burst_size), tx_stats.tx_pkts);
    try testing.expectEqual(@as(u64, 1), tx_stats.flushes);
    try testing.expectEqual(@as(u16, 0), batch.count); // batch drained
}

test "tx: flush timer does NOT flush before timeout" {
    var device = pmd.Device{ .driver = &mock_tx.driver };

    const tx_cfg = TxConfig{
        .device = &device,
        .queue_id = 0,
        .burst_size = 32,
        .input_ring = null,
        .flush_timeout_us = 1_000_000, // 1 second — won't expire during test
    };
    var batch = TxBatch{};
    var tx_stats = TxStats{};

    // Pre-load 2 packets into the batch
    var pool = try mbuf_mod.MBufPool.create(8, .regular);
    defer pool.destroy();
    pool.populate();

    const pkt1 = pool.get().?;
    pkt1.pkt_len = 64;
    _ = batch.add(pkt1);
    const pkt2 = pool.get().?;
    pkt2.pkt_len = 64;
    _ = batch.add(pkt2);

    // Set last_flush_time to now — far from 1s timeout
    batch.last_flush_time = nowNs();

    const sent = txDrain(&tx_cfg, &batch, &tx_stats);
    try testing.expectEqual(@as(u16, 0), sent);
    try testing.expectEqual(@as(u16, 2), batch.count); // still pending
    try testing.expectEqual(@as(u64, 0), tx_stats.flushes);

    // Clean up manually
    for (batch.bufs[0..batch.count]) |mbuf| mbuf.free();
}

test "tx: flush timer with timeout=0 never flushes partial" {
    var device = pmd.Device{ .driver = &mock_tx.driver };

    const tx_cfg = TxConfig{
        .device = &device,
        .queue_id = 0,
        .burst_size = 32,
        .input_ring = null,
        .flush_timeout_us = 0, // never timer-flush
    };
    var batch = TxBatch{};
    var tx_stats = TxStats{};

    var pool = try mbuf_mod.MBufPool.create(8, .regular);
    defer pool.destroy();
    pool.populate();

    const pkt = pool.get().?;
    pkt.pkt_len = 64;
    _ = batch.add(pkt);

    // Multiple calls should never flush because timeout=0 and batch not full
    for (0..10) |_| {
        const sent = txDrain(&tx_cfg, &batch, &tx_stats);
        try testing.expectEqual(@as(u16, 0), sent);
    }
    try testing.expectEqual(@as(u16, 1), batch.count); // still pending
    try testing.expectEqual(@as(u64, 0), tx_stats.flushes);

    // Clean up
    for (batch.bufs[0..batch.count]) |mbuf| mbuf.free();
}
