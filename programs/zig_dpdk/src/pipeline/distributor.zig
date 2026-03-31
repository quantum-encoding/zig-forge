/// Flow-based packet distributor.
///
/// Uses RSS hash from NIC hardware to assign packets to processing cores.
/// Consistent hashing: same flow → same core (preserves ordering within a flow).
///
/// Design:
///   - One output ring per processing core
///   - RSS hash → core mapping via modular arithmetic (hash % num_cores)
///   - Overflow: if a core's ring is full, drop + increment counter. Never block RX.
///   - Stats: per-core queue depth, drops, distribution evenness

const std = @import("std");
const config = @import("../core/config.zig");
const mbuf_mod = @import("../core/mbuf.zig");
const ring_mod = @import("../core/ring.zig");

const MBuf = mbuf_mod.MBuf;

/// Maximum number of worker cores for distribution.
pub const MAX_WORKERS: u8 = 16;

/// Distributor statistics.
pub const DistributorStats = struct {
    distributed: u64 = 0,
    drops: u64 = 0,
    per_worker_pkts: [MAX_WORKERS]u64 = [_]u64{0} ** MAX_WORKERS,
    per_worker_drops: [MAX_WORKERS]u64 = [_]u64{0} ** MAX_WORKERS,
};

/// Packet distributor configuration.
pub const DistributorConfig = struct {
    num_workers: u8,
    output_rings: [MAX_WORKERS]?*ring_mod.Ring(*MBuf),

    pub fn init(num_workers: u8) DistributorConfig {
        return .{
            .num_workers = num_workers,
            .output_rings = [_]?*ring_mod.Ring(*MBuf){null} ** MAX_WORKERS,
        };
    }
};

/// Distribute a burst of packets to worker cores based on RSS hash.
/// Returns number of packets successfully distributed.
pub fn distribute(
    dc: *const DistributorConfig,
    stats: *DistributorStats,
    bufs: []*MBuf,
    count: u16,
) u16 {
    if (dc.num_workers == 0) return 0;

    var sent: u16 = 0;

    for (0..count) |i| {
        const mbuf = bufs[i];
        // Use RSS hash from NIC hardware for flow affinity.
        // If no RSS hash, fall back to simple round-robin via packet index.
        const hash = if (mbuf.rss_hash != 0) mbuf.rss_hash else @as(u32, @intCast(i));
        const worker_id: u8 = @intCast(hash % dc.num_workers);

        if (dc.output_rings[worker_id]) |ring| {
            if (ring.enqueue(mbuf)) {
                stats.per_worker_pkts[worker_id] += 1;
                stats.distributed += 1;
                sent += 1;
            } else {
                // Ring full — drop. Never block the RX loop.
                mbuf.free();
                stats.per_worker_drops[worker_id] += 1;
                stats.drops += 1;
            }
        } else {
            // No ring for this worker — drop
            mbuf.free();
            stats.drops += 1;
        }
    }

    return sent;
}

/// Compute distribution evenness as a percentage (0-100).
/// 100 = perfectly even, lower = skewed.
/// Useful for monitoring RSS hash quality.
pub fn computeEvenness(stats: *const DistributorStats, num_workers: u8) u8 {
    if (num_workers == 0 or stats.distributed == 0) return 100;

    const expected: u64 = stats.distributed / num_workers;
    if (expected == 0) return 100;

    var max_deviation: u64 = 0;
    for (0..num_workers) |i| {
        const actual = stats.per_worker_pkts[i];
        const deviation = if (actual > expected) actual - expected else expected - actual;
        if (deviation > max_deviation) max_deviation = deviation;
    }

    const skew_pct = (max_deviation * 100) / expected;
    return if (skew_pct >= 100) 0 else @intCast(100 - skew_pct);
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "distributor: stats initial values" {
    const stats = DistributorStats{};
    try testing.expectEqual(@as(u64, 0), stats.distributed);
    try testing.expectEqual(@as(u64, 0), stats.drops);
}

test "distributor: config init" {
    const dc = DistributorConfig.init(4);
    try testing.expectEqual(@as(u8, 4), dc.num_workers);
    try testing.expect(dc.output_rings[0] == null);
}

test "distributor: evenness calculation" {
    var stats = DistributorStats{};
    stats.distributed = 100;
    // Perfectly even: 25 packets per worker (4 workers)
    stats.per_worker_pkts[0] = 25;
    stats.per_worker_pkts[1] = 25;
    stats.per_worker_pkts[2] = 25;
    stats.per_worker_pkts[3] = 25;
    try testing.expectEqual(@as(u8, 100), computeEvenness(&stats, 4));

    // Skewed: one worker gets 50, others get ~17
    stats.per_worker_pkts[0] = 50;
    stats.per_worker_pkts[1] = 17;
    stats.per_worker_pkts[2] = 17;
    stats.per_worker_pkts[3] = 16;
    const evenness = computeEvenness(&stats, 4);
    try testing.expect(evenness < 100); // should be less than perfect
}

test "distributor: zero workers returns zero" {
    const dc = DistributorConfig.init(0);
    var stats = DistributorStats{};
    var buf_array: [0]*MBuf = undefined;
    const sent = distribute(&dc, &stats, &buf_array, 0);
    try testing.expectEqual(@as(u16, 0), sent);
}
