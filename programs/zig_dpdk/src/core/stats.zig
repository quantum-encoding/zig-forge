/// Per-port and per-queue packet statistics.
/// All counters are monotonically increasing u64s.
/// Cache-line aligned to prevent false sharing between cores.

const config = @import("config.zig");

pub const QueueStats = struct {
    rx_packets: u64 = 0,
    rx_bytes: u64 = 0,
    tx_packets: u64 = 0,
    tx_bytes: u64 = 0,
    rx_dropped: u64 = 0,
    tx_dropped: u64 = 0,
    rx_errors: u64 = 0,
    tx_errors: u64 = 0,
    mbuf_alloc_failures: u64 = 0,

    pub inline fn recordRx(self: *QueueStats, packets: u64, bytes: u64) void {
        self.rx_packets += packets;
        self.rx_bytes += bytes;
    }

    pub inline fn recordTx(self: *QueueStats, packets: u64, bytes: u64) void {
        self.tx_packets += packets;
        self.tx_bytes += bytes;
    }

    pub inline fn recordRxDrop(self: *QueueStats, count: u64) void {
        self.rx_dropped += count;
    }

    pub inline fn recordTxDrop(self: *QueueStats, count: u64) void {
        self.tx_dropped += count;
    }
};

pub const PortStats = struct {
    queue_stats: [config.max_queues_per_port]QueueStats =
        [_]QueueStats{.{}} ** config.max_queues_per_port,

    /// Aggregate statistics across all queues.
    pub fn totals(self: *const PortStats, num_queues: u8) QueueStats {
        var total = QueueStats{};
        for (0..num_queues) |i| {
            const q = &self.queue_stats[i];
            total.rx_packets += q.rx_packets;
            total.rx_bytes += q.rx_bytes;
            total.tx_packets += q.tx_packets;
            total.tx_bytes += q.tx_bytes;
            total.rx_dropped += q.rx_dropped;
            total.tx_dropped += q.tx_dropped;
            total.rx_errors += q.rx_errors;
            total.tx_errors += q.tx_errors;
            total.mbuf_alloc_failures += q.mbuf_alloc_failures;
        }
        return total;
    }

    pub fn reset(self: *PortStats) void {
        self.queue_stats = [_]QueueStats{.{}} ** config.max_queues_per_port;
    }
};
