/// Telemetry and monitoring for zig_dpdk.
///
/// Per-port counters, per-queue stats, latency histogram, and
/// formatted status output. All counters are plain u64 — no atomics
/// needed because each counter is owned by exactly one core.
///
/// Export: shared memory segment for external monitoring tools,
/// or periodic dump to stderr.

const std = @import("std");
const config = @import("config.zig");
const stats_mod = @import("stats.zig");

/// Latency histogram buckets (nanoseconds).
pub const LatencyHistogram = struct {
    /// Bucket boundaries: <500ns, <1µs, <2µs, <5µs, <10µs, >10µs
    buckets: [6]u64 = [_]u64{0} ** 6,
    total_samples: u64 = 0,
    sum_ns: u64 = 0,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,

    const BOUNDARIES = [_]u64{ 500, 1000, 2000, 5000, 10000, std.math.maxInt(u64) };
    const LABELS = [_][]const u8{ "<500ns", "<1us", "<2us", "<5us", "<10us", ">10us" };

    pub fn record(self: *LatencyHistogram, latency_ns: u64) void {
        self.total_samples += 1;
        self.sum_ns += latency_ns;
        if (latency_ns < self.min_ns) self.min_ns = latency_ns;
        if (latency_ns > self.max_ns) self.max_ns = latency_ns;

        for (BOUNDARIES, 0..) |boundary, i| {
            if (latency_ns < boundary) {
                self.buckets[i] += 1;
                return;
            }
        }
    }

    pub fn avgNs(self: *const LatencyHistogram) u64 {
        if (self.total_samples == 0) return 0;
        return self.sum_ns / self.total_samples;
    }

    /// Percentile from histogram (approximate). Returns bucket boundary.
    pub fn percentile(self: *const LatencyHistogram, pct: u64) u64 {
        if (self.total_samples == 0) return 0;
        const target = (self.total_samples * pct) / 100;
        var cumulative: u64 = 0;
        for (self.buckets, 0..) |count, i| {
            cumulative += count;
            if (cumulative >= target) return BOUNDARIES[i];
        }
        return BOUNDARIES[BOUNDARIES.len - 1];
    }

    pub fn reset(self: *LatencyHistogram) void {
        self.* = .{};
    }
};

/// Per-port telemetry snapshot.
pub const PortTelemetry = struct {
    port_id: u8 = 0,
    rx_packets: u64 = 0,
    tx_packets: u64 = 0,
    rx_bytes: u64 = 0,
    tx_bytes: u64 = 0,
    rx_drops: u64 = 0,
    tx_errors: u64 = 0,
    mbuf_alloc_failures: u64 = 0,
    link_up: bool = false,
    link_speed_mbps: u32 = 0,
};

/// System-wide telemetry.
pub const SystemTelemetry = struct {
    ports: [config.max_ports]PortTelemetry = [_]PortTelemetry{.{}} ** config.max_ports,
    port_count: u8 = 0,
    latency: LatencyHistogram = .{},
    uptime_sec: u64 = 0,
    mbuf_pool_free: u32 = 0,
    mbuf_pool_total: u32 = 0,

    /// Print a formatted status report.
    pub fn dump(self: *const SystemTelemetry) void {
        const print = std.debug.print;
        print("\n╔══════════════════════════════════════════════════╗\n", .{});
        print("║             zig-dpdk telemetry                   ║\n", .{});
        print("╠══════════════════════════════════════════════════╣\n", .{});
        print("║ Uptime: {d}s  MBuf pool: {d}/{d} free           \n", .{
            self.uptime_sec,
            self.mbuf_pool_free,
            self.mbuf_pool_total,
        });

        for (self.ports[0..self.port_count]) |port| {
            print("╠── Port {d} ─────────────────────────────────────\n", .{port.port_id});
            print("║ Link: {s} @ {d} Mbps\n", .{
                if (port.link_up) "UP" else "DOWN",
                port.link_speed_mbps,
            });
            print("║ RX: {d} pkts  {d} bytes  {d} drops\n", .{
                port.rx_packets, port.rx_bytes, port.rx_drops,
            });
            print("║ TX: {d} pkts  {d} bytes  {d} errors\n", .{
                port.tx_packets, port.tx_bytes, port.tx_errors,
            });
        }

        if (self.latency.total_samples > 0) {
            print("╠── Latency ──────────────────────────────────────\n", .{});
            print("║ Samples: {d}  Avg: {d}ns  Min: {d}ns  Max: {d}ns\n", .{
                self.latency.total_samples,
                self.latency.avgNs(),
                self.latency.min_ns,
                self.latency.max_ns,
            });
            print("║ p50: {d}ns  p99: {d}ns\n", .{
                self.latency.percentile(50),
                self.latency.percentile(99),
            });
            print("║ Distribution:\n", .{});
            for (self.latency.buckets, 0..) |count, i| {
                if (self.latency.total_samples > 0) {
                    const pct = (count * 100) / self.latency.total_samples;
                    print("║   {s}: {d} ({d}%)\n", .{ LatencyHistogram.LABELS[i], count, pct });
                }
            }
        }

        print("╚══════════════════════════════════════════════════╝\n\n", .{});
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "telemetry: latency histogram" {
    var hist = LatencyHistogram{};

    hist.record(100); // <500ns bucket
    hist.record(200);
    hist.record(800); // <1µs bucket
    hist.record(1500); // <2µs bucket
    hist.record(8000); // <10µs bucket
    hist.record(15000); // >10µs bucket

    try testing.expectEqual(@as(u64, 6), hist.total_samples);
    try testing.expectEqual(@as(u64, 2), hist.buckets[0]); // <500ns
    try testing.expectEqual(@as(u64, 1), hist.buckets[1]); // <1µs
    try testing.expectEqual(@as(u64, 1), hist.buckets[2]); // <2µs
    try testing.expectEqual(@as(u64, 1), hist.buckets[4]); // <10µs
    try testing.expectEqual(@as(u64, 1), hist.buckets[5]); // >10µs
    try testing.expectEqual(@as(u64, 100), hist.min_ns);
    try testing.expectEqual(@as(u64, 15000), hist.max_ns);
}

test "telemetry: histogram percentile" {
    var hist = LatencyHistogram{};

    // 90 samples under 500ns, 10 samples at 5-10µs
    for (0..90) |_| hist.record(300);
    for (0..10) |_| hist.record(7000);

    // p50 should be in <500ns bucket
    try testing.expectEqual(@as(u64, 500), hist.percentile(50));
    // p99 should be in <10µs bucket
    try testing.expectEqual(@as(u64, 10000), hist.percentile(99));
}

test "telemetry: histogram reset" {
    var hist = LatencyHistogram{};
    hist.record(1000);
    hist.reset();
    try testing.expectEqual(@as(u64, 0), hist.total_samples);
}

test "telemetry: port telemetry defaults" {
    const port = PortTelemetry{};
    try testing.expectEqual(@as(u64, 0), port.rx_packets);
    try testing.expect(!port.link_up);
}

test "telemetry: system telemetry" {
    var sys = SystemTelemetry{};
    sys.port_count = 1;
    sys.ports[0] = .{
        .port_id = 0,
        .rx_packets = 1000000,
        .tx_packets = 999000,
        .link_up = true,
        .link_speed_mbps = 10000,
    };
    sys.latency.record(500);
    sys.latency.record(1000);
    try testing.expectEqual(@as(u64, 750), sys.latency.avgNs());
}
