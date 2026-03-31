/// Zigix native poll-mode driver — Tier 3 (bare metal, zero kernel transitions on hot path).
///
/// Talks directly to the Zigix kernel's zcnet shared-memory interface.
/// After attach, RX is pure polling of shared memory (zero syscalls).
/// TX writes descriptors to shared memory + optional kick syscall for flush.
///
/// Buffer layout:
///   Buffers 0..15  — RX (kernel posts packets here, userspace reads)
///   Buffers 16..31 — TX (userspace writes packets here, kernel drains)
///   Each buffer is 2048 bytes with a 10-byte virtio net header prefix.
///
/// Single-device driver: zcnet supports exactly one owner process.

const std = @import("std");
const config = @import("../core/config.zig");
const mbuf_mod = @import("../core/mbuf.zig");
const stats_mod = @import("../core/stats.zig");
const pmd = @import("pmd.zig");
const platform = @import("../platform/zigix.zig");

const MBuf = mbuf_mod.MBuf;
const MBufPool = mbuf_mod.MBufPool;

/// Compiler + memory barrier. Prevents reordering across shared-memory writes.
/// On x86_64 this is sufficient (stores are not reordered with other stores).
/// A full hardware fence (mfence) would be needed on weakly-ordered archs,
/// but zcnet only runs on x86_64 Zigix.
inline fn compilerFence() void {
    asm volatile ("" ::: "memory");
}

const RING_SIZE = platform.RING_SIZE;
const BUF_SIZE = platform.BUF_SIZE;
const NET_HDR_SIZE = platform.NET_HDR_SIZE;
const DESC_FLAG_VALID = platform.DESC_FLAG_VALID;
const TX_BUF_START = platform.TX_BUF_START;
const TX_BUF_COUNT = platform.TX_BUF_COUNT;

/// Zigix device state (single instance — zcnet supports one owner).
const ZigixDevice = struct {
    dev: pmd.Device = .{ .driver = &zigix_pmd },

    /// Shared-memory queue pointers.
    queue: ?platform.SharedNetQueue = null,

    /// MBuf pool for allocating receive buffers.
    pool: ?*MBufPool = null,

    /// Local RX consumer index (tracks what we've read from rx ring).
    local_rx_cons: u32 = 0,

    /// Local TX producer index (tracks what we've written to tx ring).
    local_tx_prod: u32 = 0,

    /// Round-robin index for TX buffer allocation (cycles through 16..31).
    tx_buf_next: u16 = TX_BUF_START,
};

/// Static device instance.
var device: ZigixDevice = .{};
var device_initialized: bool = false;

// ── PMD vtable functions ─────────────────────────────────────────────────

fn zigixInit(dev_config: *pmd.DeviceConfig) pmd.PmdError!*pmd.Device {
    if (device_initialized) return error.UnsupportedDevice;

    const base = platform.zcnetAttach() catch return error.BarMappingFailed;

    device.queue = platform.SharedNetQueue.initFromBase(base);
    device.pool = dev_config.pool;
    device.local_rx_cons = 0;
    device.local_tx_prod = 0;
    device.tx_buf_next = TX_BUF_START;

    device.dev.mac_addr = .{ .bytes = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 } }; // QEMU default
    device.dev.link = .{
        .speed = .speed_1g,
        .link_up = true,
        .full_duplex = true,
        .autoneg = false,
    };
    device.dev.num_rx_queues = 1;
    device.dev.num_tx_queues = 1;
    device.dev.started = true;

    device_initialized = true;
    return &device.dev;
}

/// RX burst — poll shared-memory ring for received packets.
///
/// Hot path: reads rx_prod (volatile), copies packet data from shared buffers
/// into MBufs, advances rx_cons to signal kernel to repost buffers.
fn zigixRxBurst(_: *pmd.RxQueue, bufs: []*MBuf, max_pkts: u16) u16 {
    const q = device.queue orelse return 0;
    const pool = device.pool orelse return 0;

    const prod = q.rx_prod.*;
    var cons = device.local_rx_cons;
    var count: u16 = 0;

    while (count < max_pkts) {
        // No more packets available
        if (cons == prod) break;

        const slot = cons % RING_SIZE;
        const desc = q.rx_descs[slot];

        // Skip invalid descriptors
        if (desc.flags & DESC_FLAG_VALID == 0) {
            cons +%= 1;
            continue;
        }

        // Allocate an MBuf for this packet
        const mbuf = pool.get() orelse break;

        // Copy packet data from shared buffer into mbuf.
        // Shared buffer layout: [10-byte net header][frame data]
        // We skip the net header and copy only the frame.
        const frame_len: usize = desc.len;
        if (frame_len > 0 and frame_len <= config.mbuf_data_room_size) {
            const src_offset = @as(usize, desc.buf_idx) * BUF_SIZE + NET_HDR_SIZE;
            const src: [*]const u8 = q.buf_base + src_offset;
            const dst = mbuf.data();
            @memcpy(dst[0..frame_len], src[0..frame_len]);
            mbuf.pkt_len = @intCast(frame_len);
        } else {
            mbuf.pkt_len = 0;
        }

        bufs[count] = mbuf;
        count += 1;
        cons +%= 1;
    }

    if (count > 0) {
        // Write updated consumer index — signals kernel to repost consumed buffers
        device.local_rx_cons = cons;
        // Memory barrier before writing shared index
        compilerFence();
        q.rx_cons.* = cons;
    }

    return count;
}

/// TX burst — write packets into shared TX buffers and submit descriptors.
///
/// Hot path: copies packet data into shared buffers (indices 16..31),
/// writes TX descriptors, advances tx_prod, then kicks kernel to drain.
fn zigixTxBurst(_: *pmd.TxQueue, bufs: []*MBuf, nb_pkts: u16) u16 {
    const q = device.queue orelse return 0;

    const cons = q.tx_cons.*;
    var prod = device.local_tx_prod;
    var count: u16 = 0;

    while (count < nb_pkts) {
        // Check for free slots in the ring
        if (prod -% cons >= RING_SIZE) break;

        const mbuf = bufs[count];
        const frame_len: usize = mbuf.pkt_len;

        if (frame_len == 0 or frame_len > BUF_SIZE - NET_HDR_SIZE) {
            mbuf.free();
            count += 1;
            continue;
        }

        // Select a TX buffer (round-robin through 16..31)
        const buf_idx = device.tx_buf_next;
        device.tx_buf_next = TX_BUF_START + ((buf_idx - TX_BUF_START + 1) % TX_BUF_COUNT);

        // Copy packet data into shared buffer after the 10-byte net header.
        // Zero the net header first (virtio expects it).
        const dst_offset = @as(usize, buf_idx) * BUF_SIZE;
        const dst: [*]u8 = q.buf_base + dst_offset;
        @memset(dst[0..NET_HDR_SIZE], 0);
        @memcpy(dst[NET_HDR_SIZE .. NET_HDR_SIZE + frame_len], mbuf.dataSlice());

        // Write TX descriptor
        const slot = prod % RING_SIZE;
        q.tx_descs[slot] = .{
            .buf_idx = buf_idx,
            .len = @intCast(frame_len),
            .flags = DESC_FLAG_VALID,
            ._pad = 0,
        };

        prod +%= 1;

        // Free the MBuf — data has been copied to shared memory
        mbuf.free();
        count += 1;
    }

    if (count > 0) {
        // Memory barrier before publishing producer index
        compilerFence();
        device.local_tx_prod = prod;
        q.tx_prod.* = prod;

        // Kick kernel to drain TX ring immediately
        platform.zcnetKick();
    }

    return count;
}

fn zigixStop(dev: *pmd.Device) void {
    if (device_initialized) {
        platform.zcnetDetach();
        device.queue = null;
        device.pool = null;
        device.local_rx_cons = 0;
        device.local_tx_prod = 0;
        device.tx_buf_next = TX_BUF_START;
        device_initialized = false;
    }
    dev.started = false;
}

fn zigixStats(dev: *const pmd.Device) stats_mod.PortStats {
    var port_stats = dev.stats;

    // Read live counters from shared memory if attached
    if (device.queue) |q| {
        port_stats.queue_stats[0].rx_packets = q.stats_rx_count.*;
        port_stats.queue_stats[0].tx_packets = q.stats_tx_count.*;
        port_stats.queue_stats[0].rx_dropped = q.stats_rx_drops.*;
    }

    return port_stats;
}

fn zigixLinkStatus(_: *const pmd.Device) pmd.LinkStatus {
    return .{
        .speed = .speed_1g,
        .link_up = device_initialized,
        .full_duplex = true,
        .autoneg = false,
    };
}

/// The Zigix native PMD vtable.
pub const zigix_pmd = pmd.PollModeDriver{
    .name = "zigix-zcnet",
    .initFn = zigixInit,
    .rxBurstFn = zigixRxBurst,
    .txBurstFn = zigixTxBurst,
    .stopFn = zigixStop,
    .statsFn = zigixStats,
    .linkStatusFn = zigixLinkStatus,
};

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "zigix: pmd vtable is valid" {
    try testing.expect(std.mem.eql(u8, zigix_pmd.name, "zigix-zcnet"));
    try testing.expect(@intFromPtr(zigix_pmd.initFn) != 0);
    try testing.expect(@intFromPtr(zigix_pmd.rxBurstFn) != 0);
    try testing.expect(@intFromPtr(zigix_pmd.txBurstFn) != 0);
    try testing.expect(@intFromPtr(zigix_pmd.stopFn) != 0);
    try testing.expect(@intFromPtr(zigix_pmd.statsFn) != 0);
    try testing.expect(@intFromPtr(zigix_pmd.linkStatusFn) != 0);
}

test "zigix: device defaults" {
    // Verify default state before init
    try testing.expect(!device_initialized);
    try testing.expect(device.queue == null);
    try testing.expect(device.pool == null);
    try testing.expectEqual(@as(u32, 0), device.local_rx_cons);
    try testing.expectEqual(@as(u32, 0), device.local_tx_prod);
    try testing.expectEqual(TX_BUF_START, device.tx_buf_next);
}

test "zigix: rx burst returns 0 when not attached" {
    var rx_q = pmd.RxQueue{};
    var bufs: [16]*MBuf = undefined;
    const count = zigixRxBurst(&rx_q, &bufs, 16);
    try testing.expectEqual(@as(u16, 0), count);
}

test "zigix: tx burst returns 0 when not attached" {
    var tx_q = pmd.TxQueue{};
    var bufs: [16]*MBuf = undefined;
    const count = zigixTxBurst(&tx_q, &bufs, 0);
    try testing.expectEqual(@as(u16, 0), count);
}

test "zigix: link status when not initialized" {
    const dev = pmd.Device{ .driver = &zigix_pmd };
    const link = zigixLinkStatus(&dev);
    try testing.expect(!link.link_up);
    try testing.expectEqual(pmd.LinkSpeed.speed_1g, link.speed);
    try testing.expect(link.full_duplex);
}
