/// VirtIO-net poll-mode driver for QEMU/VM testing.
///
/// Implements the VirtIO 1.0 (modern) transport for network devices.
/// Uses virtqueue descriptor rings with available/used ring semantics.
///
/// This driver enables full pipeline testing without:
///   - Real NIC hardware
///   - AF_XDP / XDP sockets
///   - Hugepages or VFIO
///
/// VirtIO transport:
///   - Each virtqueue has 3 parts: descriptor table, available ring, used ring
///   - TX: driver fills descriptors → adds to available ring → notifies device
///   - RX: device fills descriptors → adds to used ring → (optionally) interrupts
///   - In poll mode we never enable interrupts — just poll the used ring
///
/// Reference: VirtIO spec v1.0, §5.1 (Network Device)

const std = @import("std");
const config = @import("../core/config.zig");
const mbuf_mod = @import("../core/mbuf.zig");
const stats_mod = @import("../core/stats.zig");
const pmd = @import("pmd.zig");

const MBuf = mbuf_mod.MBuf;
const MBufPool = mbuf_mod.MBufPool;

/// VirtIO feature flags (§5.1.3).
pub const VIRTIO_NET_F_MAC: u64 = 1 << 5;
pub const VIRTIO_NET_F_STATUS: u64 = 1 << 16;
pub const VIRTIO_NET_F_MRG_RXBUF: u64 = 1 << 15;
pub const VIRTIO_NET_F_MQ: u64 = 1 << 22;
pub const VIRTIO_F_VERSION_1: u64 = 1 << 32;

/// VirtIO device status bits (§2.1).
pub const VIRTIO_STATUS_ACKNOWLEDGE: u8 = 1;
pub const VIRTIO_STATUS_DRIVER: u8 = 2;
pub const VIRTIO_STATUS_DRIVER_OK: u8 = 4;
pub const VIRTIO_STATUS_FEATURES_OK: u8 = 8;

/// VirtIO network header prepended to every packet (§5.1.6).
/// 10 bytes without mergeable rx buffers, 12 bytes with.
pub const VirtioNetHeader = extern struct {
    flags: u8 = 0,
    gso_type: u8 = 0, // VIRTIO_NET_HDR_GSO_NONE = 0
    hdr_len: u16 = 0,
    gso_size: u16 = 0,
    csum_start: u16 = 0,
    csum_offset: u16 = 0,
    // num_buffers: u16 = 0, // only with VIRTIO_NET_F_MRG_RXBUF
};

pub const VIRTIO_NET_HDR_SIZE: u16 = @sizeOf(VirtioNetHeader);

/// Virtqueue descriptor (§2.4.5).
pub const VringDesc = extern struct {
    addr: u64 = 0, // physical address of buffer
    len: u32 = 0,
    flags: u16 = 0,
    next: u16 = 0,
};

pub const VRING_DESC_F_NEXT: u16 = 1;
pub const VRING_DESC_F_WRITE: u16 = 2;

/// Available ring entry (§2.4.6).
pub const VringAvail = extern struct {
    flags: u16 = 0,
    idx: u16 = 0,
    // Followed by ring[queue_size] entries (u16 each)
};

/// Used ring entry (§2.4.8).
pub const VringUsedElem = extern struct {
    id: u32 = 0, // index of descriptor chain head
    len: u32 = 0, // total bytes written by device
};

pub const VringUsed = extern struct {
    flags: u16 = 0,
    idx: u16 = 0,
    // Followed by ring[queue_size] VringUsedElem entries
};

/// Simulated virtqueue for testing (in-memory, no real PCI/MMIO).
pub const Virtqueue = struct {
    /// Descriptor table
    descs: [256]VringDesc = [_]VringDesc{.{}} ** 256,
    /// Shadow array: which mbuf is in which descriptor slot
    shadow: [256]?*MBuf = [_]?*MBuf{null} ** 256,
    /// Available ring indices
    avail_idx: u16 = 0,
    /// Last seen used index (our consumer pointer)
    last_used_idx: u16 = 0,
    /// Used ring index (incremented by "device" when it completes)
    used_idx: u16 = 0,
    /// Used ring elements
    used_elems: [256]VringUsedElem = [_]VringUsedElem{.{}} ** 256,
    /// Queue size
    size: u16 = 256,
    /// Queue stats
    stats: stats_mod.QueueStats = .{},

    pub fn init(size: u16) Virtqueue {
        var vq = Virtqueue{};
        vq.size = size;
        return vq;
    }

    /// Add a buffer to the available ring (driver → device direction).
    pub fn addBuf(self: *Virtqueue, desc_idx: u16, mbuf: *MBuf, writable: bool) void {
        self.descs[desc_idx] = .{
            .addr = mbuf.phys_addr,
            .len = if (writable) config.mbuf_data_room_size else mbuf.pkt_len + VIRTIO_NET_HDR_SIZE,
            .flags = if (writable) VRING_DESC_F_WRITE else 0,
            .next = 0,
        };
        self.shadow[desc_idx] = mbuf;
        self.avail_idx +%= 1;
    }

    /// Check if device has completed any buffers.
    pub fn hasUsed(self: *const Virtqueue) bool {
        return self.last_used_idx != self.used_idx;
    }

    /// Consume one used buffer. Returns the descriptor index and length.
    pub fn consumeUsed(self: *Virtqueue) ?VringUsedElem {
        if (!self.hasUsed()) return null;
        const idx = self.last_used_idx % self.size;
        self.last_used_idx +%= 1;
        return self.used_elems[idx];
    }

    /// Simulate device completing a buffer (for testing).
    /// In real VirtIO, the hypervisor writes to the used ring.
    pub fn simulateCompletion(self: *Virtqueue, desc_idx: u16, len: u32) void {
        const idx = self.used_idx % self.size;
        self.used_elems[idx] = .{ .id = desc_idx, .len = len };
        self.used_idx +%= 1;
    }
};

/// VirtIO-net device state.
pub const VirtioDevice = struct {
    base_dev: pmd.Device = .{ .driver = &virtio_pmd },
    rx_vq: Virtqueue = Virtqueue.init(256),
    tx_vq: Virtqueue = Virtqueue.init(256),
    pool: ?*MBufPool = null,
    rx_prefilled: u16 = 0,

    /// Pre-fill RX virtqueue with empty buffers for the device to receive into.
    pub fn prefillRx(self: *VirtioDevice, pool: *MBufPool, count: u16) u16 {
        var filled: u16 = 0;
        while (filled < count) {
            const mbuf = pool.get() orelse break;
            self.rx_vq.addBuf(filled, mbuf, true);
            filled += 1;
        }
        self.rx_prefilled = filled;
        self.pool = pool;
        return filled;
    }

    /// Poll RX virtqueue for received packets.
    pub fn rxBurst(self: *VirtioDevice, bufs: []*MBuf, max_pkts: u16) u16 {
        var count: u16 = 0;
        while (count < max_pkts) {
            const used = self.rx_vq.consumeUsed() orelse break;
            const desc_idx: u16 = @intCast(used.id);
            if (self.rx_vq.shadow[desc_idx]) |mbuf| {
                // Strip virtio-net header from length
                if (used.len > VIRTIO_NET_HDR_SIZE) {
                    mbuf.pkt_len = @intCast(used.len - VIRTIO_NET_HDR_SIZE);
                    mbuf.data_off = config.mbuf_default_headroom + VIRTIO_NET_HDR_SIZE;
                } else {
                    mbuf.pkt_len = 0;
                }
                bufs[count] = mbuf;
                self.rx_vq.shadow[desc_idx] = null;
                count += 1;
            }
        }

        // Refill RX descriptors with fresh buffers
        if (count > 0) {
            if (self.pool) |pool| {
                var refilled: u16 = 0;
                while (refilled < count) {
                    const mbuf = pool.get() orelse break;
                    // Reuse the descriptor slots we just consumed
                    const slot = (self.rx_prefilled + refilled) % self.rx_vq.size;
                    self.rx_vq.addBuf(slot, mbuf, true);
                    refilled += 1;
                }
            }
        }

        self.rx_vq.stats.recordRx(count, 0);
        return count;
    }

    /// Submit packets for transmission.
    pub fn txBurst(self: *VirtioDevice, bufs: []*MBuf, nb_pkts: u16) u16 {
        // Reclaim completed TX buffers
        while (self.tx_vq.hasUsed()) {
            const used = self.tx_vq.consumeUsed() orelse break;
            const desc_idx: u16 = @intCast(used.id);
            if (self.tx_vq.shadow[desc_idx]) |mbuf| {
                mbuf.free();
                self.tx_vq.shadow[desc_idx] = null;
            }
        }

        // Submit new packets
        var count: u16 = 0;
        while (count < nb_pkts) {
            const slot = (self.tx_vq.avail_idx) % self.tx_vq.size;
            self.tx_vq.addBuf(slot, bufs[count], false);
            count += 1;
        }

        self.tx_vq.stats.recordTx(count, 0);
        return count;
    }

    /// Simulate receiving a packet (for testing).
    /// Fills data into a pre-filled RX buffer and marks it as used.
    pub fn injectRxPacket(self: *VirtioDevice, desc_idx: u16, data: []const u8) void {
        if (self.rx_vq.shadow[desc_idx]) |mbuf| {
            // Write virtio-net header (all zeros) + packet data into mbuf
            const buf_ptr = mbuf.dataRoom();
            // Zero the virtio-net header
            for (0..VIRTIO_NET_HDR_SIZE) |i| {
                buf_ptr[i] = 0;
            }
            // Copy packet data after header
            const copy_len = @min(data.len, config.mbuf_data_room_size - VIRTIO_NET_HDR_SIZE);
            for (0..copy_len) |i| {
                buf_ptr[VIRTIO_NET_HDR_SIZE + i] = data[i];
            }
            // Mark as completed in used ring
            self.rx_vq.simulateCompletion(desc_idx, @intCast(VIRTIO_NET_HDR_SIZE + copy_len));
        }
    }
};

// ── PMD vtable wrappers ────────────────────────────────────────────────

fn virtioInit(dev_config: *pmd.DeviceConfig) pmd.PmdError!*pmd.Device {
    _ = dev_config;
    // In real usage, this would create a VirtioDevice and return &base_dev.
    // For now, return an error since init requires state allocation.
    return error.UnsupportedDevice;
}

fn virtioRxBurst(_: *pmd.RxQueue, _: []*MBuf, _: u16) u16 {
    return 0;
}

fn virtioTxBurst(_: *pmd.TxQueue, _: []*MBuf, _: u16) u16 {
    return 0;
}

fn virtioStop(dev: *pmd.Device) void {
    dev.started = false;
}

fn virtioStats(dev: *const pmd.Device) stats_mod.PortStats {
    return dev.stats;
}

fn virtioLinkStatus(dev: *const pmd.Device) pmd.LinkStatus {
    return dev.link;
}

pub const virtio_pmd = pmd.PollModeDriver{
    .name = "virtio-net",
    .initFn = virtioInit,
    .rxBurstFn = virtioRxBurst,
    .txBurstFn = virtioTxBurst,
    .stopFn = virtioStop,
    .statsFn = virtioStats,
    .linkStatusFn = virtioLinkStatus,
};

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "virtio: net header size" {
    try testing.expectEqual(@as(u16, 10), VIRTIO_NET_HDR_SIZE);
}

test "virtio: virtqueue init" {
    const vq = Virtqueue.init(128);
    try testing.expectEqual(@as(u16, 128), vq.size);
    try testing.expectEqual(@as(u16, 0), vq.avail_idx);
    try testing.expect(!vq.hasUsed());
}

test "virtio: virtqueue add and consume" {
    var pool = try MBufPool.create(64, .regular);
    defer pool.destroy();
    pool.populate();

    var vq = Virtqueue.init(256);
    const mbuf = pool.get().?;

    vq.addBuf(0, mbuf, true);
    try testing.expectEqual(@as(u16, 1), vq.avail_idx);
    try testing.expect(vq.shadow[0] != null);

    // Simulate device completion
    vq.simulateCompletion(0, 100);
    try testing.expect(vq.hasUsed());

    const used = vq.consumeUsed().?;
    try testing.expectEqual(@as(u32, 0), used.id);
    try testing.expectEqual(@as(u32, 100), used.len);
    try testing.expect(!vq.hasUsed());

    // Clean up
    mbuf.free();
}

test "virtio: device prefill rx" {
    var pool = try MBufPool.create(64, .regular);
    defer pool.destroy();
    pool.populate();

    var dev = VirtioDevice{};
    const filled = dev.prefillRx(&pool, 16);
    try testing.expectEqual(@as(u16, 16), filled);
    try testing.expectEqual(@as(u16, 16), dev.rx_prefilled);

    // All 16 slots should have mbufs
    for (0..16) |i| {
        try testing.expect(dev.rx_vq.shadow[i] != null);
    }

    // Clean up pre-filled mbufs
    for (0..16) |i| {
        if (dev.rx_vq.shadow[i]) |mbuf| mbuf.free();
    }
}

test "virtio: inject and receive packet" {
    var pool = try MBufPool.create(64, .regular);
    defer pool.destroy();
    pool.populate();

    var dev = VirtioDevice{};
    _ = dev.prefillRx(&pool, 16);

    // Inject a test packet into slot 0
    const test_data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04 };
    dev.injectRxPacket(0, &test_data);

    // Receive it
    var bufs: [16]*MBuf = undefined;
    const rx_count = dev.rxBurst(&bufs, 16);
    try testing.expectEqual(@as(u16, 1), rx_count);
    try testing.expectEqual(@as(u16, 8), bufs[0].pkt_len);

    // Free received mbuf
    bufs[0].free();

    // Clean up remaining pre-filled mbufs
    for (1..16) |i| {
        if (dev.rx_vq.shadow[i]) |mbuf| mbuf.free();
    }
}

test "virtio: tx burst" {
    var pool = try MBufPool.create(64, .regular);
    defer pool.destroy();
    pool.populate();

    var dev = VirtioDevice{};

    // Get some mbufs to transmit
    var bufs: [4]*MBuf = undefined;
    for (&bufs) |*b| {
        b.* = pool.get().?;
        b.*.pkt_len = 64;
    }

    const sent = dev.txBurst(&bufs, 4);
    try testing.expectEqual(@as(u16, 4), sent);
    try testing.expectEqual(@as(u16, 4), dev.tx_vq.avail_idx);

    // Simulate completion of all 4 (frees the mbufs)
    for (0..4) |i| {
        dev.tx_vq.simulateCompletion(@intCast(i), 74); // 64 + 10 (net hdr)
    }

    // Next txBurst reclaims them
    var more_bufs: [1]*MBuf = undefined;
    more_bufs[0] = pool.get().?;
    more_bufs[0].pkt_len = 64;
    _ = dev.txBurst(&more_bufs, 1);

    // Clean up
    for (0..5) |i| {
        if (dev.tx_vq.shadow[i]) |mbuf| mbuf.free();
    }
}

test "virtio: pmd vtable" {
    try testing.expect(std.mem.eql(u8, virtio_pmd.name, "virtio-net"));
    try testing.expect(@intFromPtr(virtio_pmd.rxBurstFn) != 0);
    try testing.expect(@intFromPtr(virtio_pmd.txBurstFn) != 0);
}
