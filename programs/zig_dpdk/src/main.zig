const std = @import("std");
const config = @import("core/config.zig");
const ring_mod = @import("core/ring.zig");
const mbuf_mod = @import("core/mbuf.zig");
const stats_mod = @import("core/stats.zig");
const mempool_mod = @import("core/mempool.zig");
const hugepage = @import("mem/hugepage.zig");
const physical = @import("mem/physical.zig");
const numa = @import("mem/numa.zig");
const pmd = @import("drivers/pmd.zig");
const linux = @import("platform/linux.zig");
const zigix = @import("platform/zigix.zig");

const MBuf = mbuf_mod.MBuf;
const MBufPool = mbuf_mod.MBufPool;
const Ring = ring_mod.Ring;

const print = std.debug.print;

/// Simple timer using clock_gettime (replaces removed Timer)
const Timer = struct {
    start_ts: std.c.timespec,

    fn start() !Timer {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return .{ .start_ts = ts };
    }

    fn reset(self: *Timer) void {
        _ = std.c.clock_gettime(.MONOTONIC, &self.start_ts);
    }

    fn read(self: *const Timer) u64 {
        var now: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &now);
        const start_ns: i128 = @as(i128, self.start_ts.sec) * 1_000_000_000 + self.start_ts.nsec;
        const now_ns: i128 = @as(i128, now.sec) * 1_000_000_000 + now.nsec;
        const diff = now_ns - start_ns;
        return if (diff > 0) @intCast(diff) else 0;
    }
};

pub fn main() !void {
    print(
        \\
        \\  zig-dpdk  |  Zero-copy poll-mode network stack
        \\  Phase 1   |  Core infrastructure
        \\  NUMA node |  {d}
        \\
        \\
    , .{
        numa.currentNode(),
    });

    // ── MBuf Pool Benchmark ──────────────────────────────────────────
    print("MBuf pool benchmark:\n", .{});

    const pool_size: u32 = 4096;
    var pool = try MBufPool.create(pool_size, .regular);
    defer pool.destroy();
    pool.populate();

    print("  Pool created: {d} mbufs x {d} bytes = {d} KB\n", .{
        pool_size,
        config.mbuf_buf_size,
        (@as(usize, pool_size) * config.mbuf_buf_size) / 1024,
    });

    // Warm up
    {
        const warmup_buf = pool.get().?;
        warmup_buf.free();
    }

    // Single alloc/free latency
    const single_iters: u32 = 100_000;
    var timer = try Timer.start();
    {
        var i: u32 = 0;
        while (i < single_iters) : (i += 1) {
            const m = pool.get().?;
            m.free();
        }
    }
    const single_elapsed = timer.read();
    const single_ns = single_elapsed / single_iters;

    print("  Single alloc/free: {d} ns/op ({d} iterations)\n", .{
        single_ns,
        single_iters,
    });

    // Bulk alloc/free latency
    const bulk_count: u32 = 32;
    const bulk_iters: u32 = 10_000;
    var bufs: [32]*MBuf = undefined;

    timer.reset();
    {
        var i: u32 = 0;
        while (i < bulk_iters) : (i += 1) {
            const got = pool.getBulk(&bufs, bulk_count);
            pool.putBulk(&bufs, got);
        }
    }
    const bulk_elapsed = timer.read();
    const bulk_ns = bulk_elapsed / (bulk_iters * bulk_count);

    print("  Bulk alloc/free ({d}): {d} ns/mbuf ({d} iterations)\n", .{
        bulk_count,
        bulk_ns,
        bulk_iters,
    });

    // ── Ring Benchmark ───────────────────────────────────────────────
    print("\nRing benchmark:\n", .{});

    var ring_buf: [1024]u64 = undefined;
    var ring = Ring(u64).init(&ring_buf, 1024);

    const ring_iters: u32 = 100_000;
    timer.reset();
    {
        var i: u32 = 0;
        while (i < ring_iters) : (i += 1) {
            _ = ring.enqueue(i);
            _ = ring.dequeue();
        }
    }
    const ring_elapsed = timer.read();
    const ring_ns = ring_elapsed / ring_iters;

    print("  Enqueue/dequeue pair: {d} ns/op ({d} iterations)\n", .{
        ring_ns,
        ring_iters,
    });

    // Bulk ring ops
    const ring_bulk_iters: u32 = 10_000;
    var ring_items: [32]u64 = undefined;
    for (&ring_items, 0..) |*item, i| item.* = i;
    var ring_out: [32]u64 = undefined;

    timer.reset();
    {
        var i: u32 = 0;
        while (i < ring_bulk_iters) : (i += 1) {
            _ = ring.enqueueBulk(&ring_items);
            _ = ring.dequeueBulk(&ring_out);
        }
    }
    const ring_bulk_elapsed = timer.read();
    const ring_bulk_ns = ring_bulk_elapsed / (ring_bulk_iters * 32);

    print("  Bulk enqueue/dequeue (32): {d} ns/item ({d} iterations)\n", .{
        ring_bulk_ns,
        ring_bulk_iters,
    });

    // ── Summary ──────────────────────────────────────────────────────
    print(
        \\
        \\Phase 1 infrastructure ready.
        \\  MBuf size:    {d} bytes ({d} metadata + {d} data + {d} tailroom)
        \\  Pool:         {d} mbufs, {d} available
        \\  Ring:         1024 entries, {d} used
        \\
        \\Next: Phase 2A (AF_XDP driver) — requires Linux.
        \\
        \\
    , .{
        config.mbuf_buf_size,
        config.mbuf_metadata_size,
        config.mbuf_data_room_size,
        config.mbuf_tailroom_size,
        pool_size,
        pool.availableCount(),
        ring.count(),
    });
}

// ── Test discovery ───────────────────────────────────────────────────────
// Referencing all modules ensures `zig build test` finds their inline tests.

test {
    _ = @import("core/config.zig");
    _ = @import("core/ring.zig");
    _ = @import("core/stats.zig");
    _ = @import("core/mbuf.zig");
    _ = @import("core/mempool.zig");
    _ = @import("mem/hugepage.zig");
    _ = @import("mem/physical.zig");
    _ = @import("mem/numa.zig");
    _ = @import("mem/iommu.zig");
    _ = @import("drivers/pmd.zig");
    _ = @import("drivers/af_xdp.zig");
    _ = @import("drivers/virtio.zig");
    _ = @import("drivers/zigix.zig");
    _ = @import("drivers/ixgbe.zig");
    _ = @import("net/ethernet.zig");
    _ = @import("net/checksum.zig");
    _ = @import("net/ipv4.zig");
    _ = @import("net/udp.zig");
    _ = @import("net/tcp.zig");
    _ = @import("net/arp.zig");
    _ = @import("pipeline/pipeline.zig");
    _ = @import("pipeline/rx.zig");
    _ = @import("pipeline/tx.zig");
    _ = @import("pipeline/distributor.zig");
    _ = @import("pipeline/runner.zig");
    _ = @import("integration/decimal.zig");
    _ = @import("integration/json_kv.zig");
    _ = @import("integration/order_book.zig");
    _ = @import("integration/market_data.zig");
    _ = @import("core/telemetry.zig");
    _ = @import("core/lifecycle.zig");
    _ = @import("core/watchdog.zig");
    _ = @import("platform/linux.zig");
    _ = @import("platform/zigix.zig");
}
