/// Intel 82599ES / X520 / X540 10GbE Poll-Mode Driver.
///
/// Implements the ixgbe native PMD for maximum-performance packet I/O,
/// bypassing the kernel entirely via VFIO BAR0 MMIO register access.
///
/// The full initialization sequence follows Intel 82599 datasheet §4.6.3.
/// All register offsets reference document 331520-006.
///
/// Key design decisions:
///   - RegOps abstraction: read32/write32 go through function pointers so
///     tests can use a flat u32 array (MockRegs) instead of real MMIO.
///   - Shadow array maps each descriptor slot to its MBuf pointer.
///   - Single doorbell write per burst to amortize PCIe cost.
///   - RS (Report Status) on every TX descriptor for simplicity.
///   - data_off = 0 on RX: NIC DMAs to bufDmaAddr() = start of data room.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("../core/config.zig");
const mbuf_mod = @import("../core/mbuf.zig");
const stats_mod = @import("../core/stats.zig");
const pmd = @import("pmd.zig");
const iommu = @import("../mem/iommu.zig");
const hugepage = @import("../mem/hugepage.zig");
const physical = @import("../mem/physical.zig");

const MBuf = mbuf_mod.MBuf;
const MBufPool = mbuf_mod.MBufPool;

// ── Intel 82599 Register Offsets (Datasheet §8) ─────────────────────────

/// Device Control (§8.2.1)
pub const CTRL = 0x00000;
pub const CTRL_RST: u32 = 1 << 26; // Device Reset
pub const CTRL_LRST: u32 = 1 << 3; // Link Reset

/// Extended Interrupt Mask Clear (§8.2.3.5) — write 1 to disable
pub const EIMC = 0x00888;
pub const EIMC_ALL: u32 = 0x7FFFFFFF;

/// EEPROM/Flash Control (§8.2.4.1)
pub const EEC = 0x10010;
pub const EEC_ARD: u32 = 1 << 9; // Auto Read Done

/// Receive Address Low / High (§8.2.3.7.7)
pub const RAL0 = 0x05400;
pub const RAH0 = 0x05404;
pub const RAH_AV: u32 = 1 << 31; // Address Valid

/// Multicast Table Array (128 entries × 4 bytes) (§8.2.3.7.8)
pub const MTA_BASE = 0x05200;
pub const MTA_COUNT = 128;

/// RX Control (§8.2.3.8.1)
pub const RXCTRL = 0x03000;
pub const RXCTRL_RXEN: u32 = 1 << 0;

/// RX Filter Control (§8.2.3.7.1)
pub const FCTRL = 0x05080;
pub const FCTRL_BAM: u32 = 1 << 10; // Broadcast Accept Mode
pub const FCTRL_MPE: u32 = 1 << 8; // Multicast Promiscuous Enable
pub const FCTRL_UPE: u32 = 1 << 9; // Unicast Promiscuous Enable

/// MAC Core Control 0 (§8.2.3.22.8)
pub const HLREG0 = 0x04240;
pub const HLREG0_TXCRCEN: u32 = 1 << 0; // TX CRC Enable
pub const HLREG0_RXCRCSTRP: u32 = 1 << 1; // RX CRC Strip
pub const HLREG0_TXPADEN: u32 = 1 << 10; // TX Padding Enable

/// DMA TX Control (§8.2.3.9.2)
pub const DMATXCTL = 0x04A80;
pub const DMATXCTL_TE: u32 = 1 << 0; // Transmit Enable

/// Per-queue RX Descriptor registers (§8.2.3.8)
/// Queue n: base + 0x40 * n
pub inline fn RDBAL(n: u32) u32 {
    return 0x01000 + 0x40 * n;
}
pub inline fn RDBAH(n: u32) u32 {
    return 0x01004 + 0x40 * n;
}
pub inline fn RDLEN(n: u32) u32 {
    return 0x01008 + 0x40 * n;
}
pub inline fn RDH(n: u32) u32 {
    return 0x01010 + 0x40 * n;
}
pub inline fn RDT(n: u32) u32 {
    return 0x01018 + 0x40 * n;
}
pub inline fn RXDCTL(n: u32) u32 {
    return 0x01028 + 0x40 * n;
}
pub const RXDCTL_ENABLE: u32 = 1 << 25;

/// Split Receive Control (§8.2.3.8.7) — buffer size, header split config
pub inline fn SRRCTL(n: u32) u32 {
    return 0x01014 + 0x40 * n;
}
/// SRRCTL.BSIZEPACKET (bits 4:0) in 1KB units. 2 = 2KB.
pub const SRRCTL_BSIZEPACKET_2K: u32 = 2;
/// SRRCTL.DESCTYPE (bits 27:25). 001 = advanced one-buffer.
pub const SRRCTL_DESCTYPE_ADV_ONE: u32 = 1 << 25;
/// Drop enable — drop packet when no RX descriptors available (§8.2.3.8.7)
pub const SRRCTL_DROP_EN: u32 = 1 << 28;

/// Per-queue TX Descriptor registers (§8.2.3.9)
pub inline fn TDBAL(n: u32) u32 {
    return 0x06000 + 0x40 * n;
}
pub inline fn TDBAH(n: u32) u32 {
    return 0x06004 + 0x40 * n;
}
pub inline fn TDLEN(n: u32) u32 {
    return 0x06008 + 0x40 * n;
}
pub inline fn TDH_REG(n: u32) u32 {
    return 0x06010 + 0x40 * n;
}
pub inline fn TDT_REG(n: u32) u32 {
    return 0x06018 + 0x40 * n;
}
pub inline fn TXDCTL(n: u32) u32 {
    return 0x06028 + 0x40 * n;
}
pub const TXDCTL_ENABLE: u32 = 1 << 25;

/// Link Status (§8.2.3.2.2)
pub const LINKS = 0x042A4;
pub const LINKS_UP: u32 = 1 << 30;
pub const LINKS_SPEED_MASK: u32 = 0x3 << 28;
pub const LINKS_SPEED_10G: u32 = 0x3 << 28;
pub const LINKS_SPEED_1G: u32 = 0x2 << 28;
pub const LINKS_SPEED_100M: u32 = 0x1 << 28;

/// Auto-Negotiation Control (§8.2.3.22.1)
pub const AUTOC = 0x042A0;
pub const AUTOC_LMS_10G_SFI: u32 = 0x3 << 13; // LMS = 10G SFI
pub const AUTOC_AN_RESTART: u32 = 1 << 12;

/// RSS (Receive Side Scaling) registers
/// RSS Key (40 bytes = 10 × u32) (§8.2.3.8.12)
pub inline fn RSSRK(n: u32) u32 {
    return 0x0EB80 + 4 * n;
}
/// RSS Redirection Table (128 entries in 32 u32 words) (§8.2.3.8.11)
pub inline fn RETA(n: u32) u32 {
    return 0x0EB00 + 4 * n;
}
/// Multiple Receive Queues Command (§8.2.3.8.10)
pub const MRQC = 0x0EC80;
pub const MRQC_RSS_EN: u32 = 1 << 0;
pub const MRQC_RSS_FIELD_IPV4_TCP: u32 = 1 << 16;
pub const MRQC_RSS_FIELD_IPV4: u32 = 1 << 17;
pub const MRQC_RSS_FIELD_IPV6_TCP: u32 = 1 << 18;
pub const MRQC_RSS_FIELD_IPV6: u32 = 1 << 19;
pub const MRQC_RSS_FIELD_IPV4_UDP: u32 = 1 << 21;
pub const MRQC_RSS_FIELD_IPV6_UDP: u32 = 1 << 23;

/// Statistics registers (§8.2.3.23) — read to clear
pub const GPRC = 0x04074; // Good Packets Received Count
pub const GPTC = 0x04080; // Good Packets Transmitted Count
pub const GORCL = 0x04088; // Good Octets Received Count Low
pub const GORCH = 0x0408C; // Good Octets Received Count High
pub const GOTCL = 0x04090; // Good Octets Transmitted Count Low
pub const GOTCH = 0x04094; // Good Octets Transmitted Count High

/// Maximum register offset we need to cover in mock.
/// Must be >= all register offsets used: EEC (0x10010) is the highest.
pub const MAX_REG_OFFSET = 0x10014;

// ── RX Descriptor Status/Error Bits (§7.1.5) ───────────────────────────

pub const RXD_STAT_DD: u32 = 1 << 0; // Descriptor Done
pub const RXD_STAT_EOP: u32 = 1 << 1; // End of Packet
pub const RXD_STAT_VP: u32 = 1 << 3; // VLAN Packet

// ── TX Descriptor Command Bits (§7.2.1) ─────────────────────────────────

/// Advanced TX Data Descriptor: DCMD field (bits 31:24 of cmd_type_len)
pub const TXD_CMD_EOP: u32 = 1 << 24; // End of Packet
pub const TXD_CMD_IFCS: u32 = 1 << 25; // Insert FCS/CRC
pub const TXD_CMD_RS: u32 = 1 << 27; // Report Status
/// DTYP = Advanced Data (01) in bits 23:20
pub const TXD_DTYP_ADV_DATA: u32 = 0x3 << 20;
/// PAYLEN shift in olinfo_status (bits 31:14)
pub const TXD_PAYLEN_SHIFT: u5 = 14;

/// TX Descriptor Status (write-back, bit 0 of sta_rsv field)
pub const TXD_STAT_DD: u32 = 1 << 0;

// ── Descriptor Structures (16 bytes each) ───────────────────────────────

/// Advanced RX Descriptor — Read Format (§7.1.6.1)
/// Written by software, read by NIC.
pub const RxDescRead = extern struct {
    /// Physical address of the packet buffer
    pkt_addr: u64,
    /// Physical address of the header buffer (0 for single-buffer mode)
    hdr_addr: u64,
};

/// Advanced RX Descriptor — Write-Back Format (§7.1.6.2)
/// Written by NIC after packet reception.
/// Layout (16 bytes total):
///   [0..4)   RSS hash / fragment checksum / Flow Director ID
///   [4..8)   status_error (extended status[19:0] + ext_error[31:20])
///   [8..12)  pkt_len[15:0] + vlan[15:0]
///   [12..16) second identification field (header info, SPH, etc.)
///
/// Note: field order matches the actual wire layout of the 82599 write-back
/// descriptor, not a "logical" grouping. The status_error field is at offset 4
/// (not after pkt_len) per the datasheet §7.1.6.2 table 7-18.
pub const RxDescWb = extern struct {
    /// RSS hash / fragment checksum (bytes 0-3)
    rss_hash: u32,
    /// Extended status + error (bytes 4-7)
    status_error: u32,
    /// Packet length (bytes 8-9)
    pkt_len: u16,
    /// VLAN tag (bytes 10-11)
    vlan: u16,
    /// Header info / SPH / etc. (bytes 12-15)
    hdr_info: u32,
};

/// RX Descriptor union — same 16 bytes, different interpretations.
pub const RxDesc = extern union {
    read: RxDescRead,
    wb: RxDescWb,
};

/// Advanced TX Data Descriptor (§7.2.1)
pub const TxDesc = extern struct {
    /// Physical address of packet data
    addr: u64,
    /// Command, type, length (DCMD | DTYP | DTALEN)
    cmd_type_len: u32,
    /// Offload info + status (PAYLEN | POPTS | STA)
    olinfo_status: u32,
};

comptime {
    if (@sizeOf(RxDescRead) != 16)
        @compileError("RxDescRead must be 16 bytes");
    if (@sizeOf(RxDescWb) != 16)
        @compileError("RxDescWb must be 16 bytes");
    if (@sizeOf(RxDesc) != 16)
        @compileError("RxDesc must be 16 bytes");
    if (@sizeOf(TxDesc) != 16)
        @compileError("TxDesc must be 16 bytes");
}

// ── Register Operations Abstraction ─────────────────────────────────────

/// Function pointers for register access. Backed by VFIO MMIO in production
/// or by a flat u32 array (MockRegs) in tests.
pub const RegOps = struct {
    read32: *const fn (ctx: *anyopaque, offset: u32) u32,
    write32: *const fn (ctx: *anyopaque, offset: u32, value: u32) void,
    ctx: *anyopaque,

    pub inline fn read(self: *const RegOps, offset: u32) u32 {
        return self.read32(self.ctx, offset);
    }

    pub inline fn write(self: *const RegOps, offset: u32, value: u32) void {
        self.write32(self.ctx, offset, value);
    }
};

/// Mock register file for testing. Covers all ixgbe registers we use.
/// Indexed by offset / 4 (all registers are 32-bit aligned).
pub const MockRegs = struct {
    /// Register storage: (MAX_REG_OFFSET / 4) + 1 entries
    pub const REG_COUNT = MAX_REG_OFFSET / 4 + 1;
    regs: [REG_COUNT]u32,

    pub fn init() MockRegs {
        return .{ .regs = [_]u32{0} ** REG_COUNT };
    }

    pub fn read32(ctx: *anyopaque, offset: u32) u32 {
        const self: *MockRegs = @ptrCast(@alignCast(ctx));
        const idx = offset / 4;
        if (idx >= REG_COUNT) return 0;
        return self.regs[idx];
    }

    pub fn write32(ctx: *anyopaque, offset: u32, value: u32) void {
        const self: *MockRegs = @ptrCast(@alignCast(ctx));
        const idx = offset / 4;
        if (idx >= REG_COUNT) return;
        self.regs[idx] = value;
    }

    pub fn regOps(self: *MockRegs) RegOps {
        return .{
            .read32 = MockRegs.read32,
            .write32 = MockRegs.write32,
            .ctx = @ptrCast(self),
        };
    }

    /// Read a register by offset (convenience for tests).
    pub fn get(self: *const MockRegs, offset: u32) u32 {
        const idx = offset / 4;
        if (idx >= REG_COUNT) return 0;
        return self.regs[idx];
    }

    /// Write a register by offset (convenience for tests).
    pub fn set(self: *MockRegs, offset: u32, value: u32) void {
        const idx = offset / 4;
        if (idx >= REG_COUNT) return;
        self.regs[idx] = value;
    }
};

// ── Per-Queue Driver State ──────────────────────────────────────────────

/// Maximum descriptor ring size (4096 entries × 16 bytes = 64KB).
pub const MAX_RING_SIZE = 4096;
/// Default ring size for tests.
pub const TEST_RING_SIZE = 32;

/// RX queue state stored in pmd.RxQueue.driver_data.
pub const IxgbeRxQueueData = struct {
    /// Descriptor ring (RxDesc array). Points into the ring region.
    descs: [*]RxDesc,
    /// Shadow array: maps each descriptor slot to its MBuf.
    shadow: [MAX_RING_SIZE]?*MBuf,
    /// Software tail pointer (next descriptor to check for DD bit).
    sw_tail: u32,
    /// Ring size.
    ring_size: u32,
    /// Bitmask for modular indexing.
    ring_mask: u32,
    /// Queue index (for register offsets).
    queue_idx: u32,
    /// Register operations.
    reg_ops: RegOps,
    /// MBuf pool for refilling.
    pool: *MBufPool,

    pub fn init(descs: [*]RxDesc, ring_size: u32, queue_idx: u32, reg_ops: RegOps, pool_ptr: *MBufPool) IxgbeRxQueueData {
        std.debug.assert(ring_size > 0 and (ring_size & (ring_size - 1)) == 0); // power of two
        var data: IxgbeRxQueueData = undefined;
        data.descs = descs;
        data.shadow = [_]?*MBuf{null} ** MAX_RING_SIZE;
        data.sw_tail = 0;
        data.ring_size = ring_size;
        data.ring_mask = ring_size - 1;
        data.queue_idx = queue_idx;
        data.reg_ops = reg_ops;
        data.pool = pool_ptr;
        return data;
    }
};

/// TX queue state stored in pmd.TxQueue.driver_data.
pub const IxgbeTxQueueData = struct {
    /// Descriptor ring (TxDesc array). Points into the ring region.
    descs: [*]TxDesc,
    /// Shadow array: maps each descriptor slot to its MBuf.
    shadow: [MAX_RING_SIZE]?*MBuf,
    /// Software head pointer (next slot to write a new TX descriptor).
    sw_head: u32,
    /// Software tail pointer (oldest un-reclaimed descriptor).
    sw_tail: u32,
    /// Ring size.
    ring_size: u32,
    /// Bitmask for modular indexing.
    ring_mask: u32,
    /// Queue index (for register offsets).
    queue_idx: u32,
    /// Register operations.
    reg_ops: RegOps,

    pub fn init(descs: [*]TxDesc, ring_size: u32, queue_idx: u32, reg_ops: RegOps) IxgbeTxQueueData {
        std.debug.assert(ring_size > 0 and (ring_size & (ring_size - 1)) == 0);
        var data: IxgbeTxQueueData = undefined;
        data.descs = descs;
        data.shadow = [_]?*MBuf{null} ** MAX_RING_SIZE;
        data.sw_head = 0;
        data.sw_tail = 0;
        data.ring_size = ring_size;
        data.ring_mask = ring_size - 1;
        data.queue_idx = queue_idx;
        data.reg_ops = reg_ops;
        return data;
    }

    /// Number of free slots in the ring.
    pub inline fn freeCount(self: *const IxgbeTxQueueData) u32 {
        return self.ring_size - (self.sw_head -% self.sw_tail);
    }
};

// ── IxgbeDevice ─────────────────────────────────────────────────────────

/// Per-device state for an Intel 82599 NIC.
pub const IxgbeDevice = struct {
    dev: pmd.Device,
    reg_ops: RegOps,
    pool: *MBufPool,
    rx_queue_data: [config.max_queues_per_port]IxgbeRxQueueData,
    tx_queue_data: [config.max_queues_per_port]IxgbeTxQueueData,

    /// VFIO handles for cleanup (only valid when opened via ixgbeInit on Linux)
    vfio_container: iommu.VfioContainer = .{},
    vfio_group: iommu.VfioGroup = .{},
    vfio_device: iommu.VfioDevice = .{},
    vfio_reg_ops: iommu.VfioRegOps = .{ .dev = undefined },

    /// Hugepage region backing all descriptor rings (RX + TX)
    desc_region: ?hugepage.Region = null,
    desc_region_phys: u64 = 0,

    /// True if VFIO was used to open this device (false for initWithRegOps)
    vfio_owned: bool = false,
};

/// Static device storage (same pattern as af_xdp and virtio).
var devices: [config.max_ports]IxgbeDevice = undefined;
var device_count: u8 = 0;

// ── PMD Vtable ──────────────────────────────────────────────────────────

pub const ixgbe_pmd = pmd.PollModeDriver{
    .name = "ixgbe",
    .initFn = ixgbeInit,
    .rxBurstFn = ixgbeRxBurst,
    .txBurstFn = ixgbeTxBurst,
    .stopFn = ixgbeStop,
    .statsFn = ixgbeStats,
    .linkStatusFn = ixgbeLinkStatus,
};

// ── Initialization (Intel 82599 Datasheet §4.6.3) ──────────────────────

fn ixgbeInit(dev_config: *pmd.DeviceConfig) pmd.PmdError!*pmd.Device {
    if (comptime builtin.os.tag != .linux) {
        // VFIO is Linux-only. Use initWithRegOps() for testing on other platforms.
        return error.DeviceNotFound;
    }

    const pool = dev_config.pool orelse return error.OutOfMemory;
    const num_rx = dev_config.num_rx_queues;
    const num_tx = dev_config.num_tx_queues;
    const rx_ring_size = dev_config.rx_ring_size;
    const tx_ring_size = dev_config.tx_ring_size;

    if (num_rx == 0 or num_tx == 0) return error.QueueSetupFailed;
    if (device_count >= config.max_ports) return error.DeviceNotFound;

    // 1. Parse PCI address
    const pci_addr_slice = std.mem.sliceTo(&dev_config.pci_addr, 0);
    if (pci_addr_slice.len < 12) return error.DeviceNotFound;

    // 2. Open VFIO stack: container → group → device → BAR0
    const vfio_stack = iommu.openVfioDevice(pci_addr_slice) catch
        return error.VfioError;

    // Allocate device slot
    const idx = device_count;
    device_count += 1;
    const device = &devices[idx];

    // Store VFIO handles for cleanup
    device.vfio_container = vfio_stack.container;
    device.vfio_group = vfio_stack.group;
    device.vfio_device = vfio_stack.device;
    device.vfio_owned = true;

    // 3. Create RegOps from VFIO device
    device.vfio_reg_ops = device.vfio_device.regOps();
    const reg_ops_raw = device.vfio_reg_ops.toRegOps();
    device.reg_ops = .{
        .read32 = reg_ops_raw.read32,
        .write32 = reg_ops_raw.write32,
        .ctx = reg_ops_raw.ctx,
    };
    const ops = &device.reg_ops;

    // 4. Disable interrupts (§4.6.3.1)
    ops.write(EIMC, EIMC_ALL);

    // 5. Global reset (§4.6.3.2)
    const ctrl = ops.read(CTRL);
    ops.write(CTRL, ctrl | CTRL_RST);

    // 6. Poll until CTRL.RST clears (self-clearing bit)
    try waitForReset(ops, 1_000_000); // ~1 second at spin speed

    // 7. Disable interrupts again (reset re-enables them)
    ops.write(EIMC, EIMC_ALL);

    // 8. Wait for EEPROM auto-read (§4.6.3.3)
    try waitForEeprom(ops, 1_000_000);

    // 9. Post-reset configuration: MTA, HLREG0, FCTRL, SRRCTL, DMATXCTL, etc.
    initHardwarePostReset(ops, num_rx, num_tx);

    // 10. Read MAC address
    const mac = readMacAddr(ops);

    // 11. Clear statistics registers
    clearStatRegisters(ops);

    // 12. Allocate hugepage region for all descriptor rings
    //     Each ring: ring_size * 16 bytes. Total: (num_rx * rx + num_tx * tx) * 16.
    const rx_ring_bytes = @as(usize, num_rx) * @as(usize, rx_ring_size) * 16;
    const tx_ring_bytes = @as(usize, num_tx) * @as(usize, tx_ring_size) * 16;
    const total_desc_bytes = rx_ring_bytes + tx_ring_bytes;

    const desc_region = hugepage.allocRegion(total_desc_bytes, .regular) catch
        return error.OutOfMemory;
    device.desc_region = desc_region;
    device.desc_region_phys = physical.virtToPhys(@intFromPtr(desc_region.ptr));

    // Zero the descriptor memory
    @memset(desc_region.slice(), 0);

    // 13. DMA-map descriptor ring region
    device.vfio_container.mapDma(
        @intFromPtr(desc_region.ptr),
        device.desc_region_phys,
        desc_region.size,
    ) catch return error.VfioError;

    // 14. DMA-map mbuf pool memory
    device.vfio_container.mapDma(
        @intFromPtr(pool.base),
        pool.base_phys,
        pool.total_size,
    ) catch return error.VfioError;

    device.pool = pool;

    // 15. Setup RX queues
    var desc_offset: usize = 0;
    for (0..num_rx) |qi| {
        const q: u8 = @intCast(qi);
        const q32: u32 = @intCast(qi);
        const ring_bytes = @as(usize, rx_ring_size) * 16;
        const ring_ptr: [*]RxDesc = @ptrCast(@alignCast(desc_region.ptr + desc_offset));
        const ring_phys = device.desc_region_phys + desc_offset;

        device.rx_queue_data[qi] = IxgbeRxQueueData.init(ring_ptr, rx_ring_size, q32, device.reg_ops, pool);

        setupRxQueue(ops, ring_ptr, rx_ring_size, q32, ring_phys, pool, &device.rx_queue_data[qi].shadow);

        device.dev.rx_queues[qi] = .{
            .queue_id = q,
            .port_id = idx,
            .driver_data = @ptrCast(&device.rx_queue_data[qi]),
        };

        desc_offset += ring_bytes;
    }

    // 16. Setup TX queues
    for (0..num_tx) |qi| {
        const q: u8 = @intCast(qi);
        const q32: u32 = @intCast(qi);
        const ring_bytes = @as(usize, tx_ring_size) * 16;
        const ring_ptr: [*]TxDesc = @ptrCast(@alignCast(desc_region.ptr + desc_offset));
        const ring_phys = device.desc_region_phys + desc_offset;

        device.tx_queue_data[qi] = IxgbeTxQueueData.init(ring_ptr, tx_ring_size, q32, device.reg_ops);

        setupTxQueue(ops, tx_ring_size, q32, ring_phys);

        device.dev.tx_queues[qi] = .{
            .queue_id = q,
            .port_id = idx,
            .driver_data = @ptrCast(&device.tx_queue_data[qi]),
        };

        desc_offset += ring_bytes;
    }

    // 17. Wait for link up (9M iterations ≈ 9 seconds with spin loop)
    waitForLink(ops, 9_000_000) catch {
        // Link timeout is not fatal — NIC may have no cable connected.
        // Caller can check device.dev.link.link_up.
    };

    // 18. Read link status and populate device
    const link = readLinkStatus(ops);
    device.dev = .{
        .driver = &ixgbe_pmd,
        .port_id = idx,
        .mac_addr = mac,
        .mtu = dev_config.mtu,
        .link = link,
        .num_rx_queues = num_rx,
        .num_tx_queues = num_tx,
        .started = true,
    };

    // Re-wire queue driver_data pointers (dev was overwritten above)
    for (0..num_rx) |qi| {
        device.dev.rx_queues[qi] = .{
            .queue_id = @intCast(qi),
            .port_id = idx,
            .driver_data = @ptrCast(&device.rx_queue_data[qi]),
        };
    }
    for (0..num_tx) |qi| {
        device.dev.tx_queues[qi] = .{
            .queue_id = @intCast(qi),
            .port_id = idx,
            .driver_data = @ptrCast(&device.tx_queue_data[qi]),
        };
    }

    return &device.dev;
}

/// Initialize 82599 hardware registers. Called with either VFIO or mock RegOps.
/// Follows the exact sequence from §4.6.3 of the datasheet.
///
/// This function performs the full init including a non-polled reset (suitable
/// for MockRegs testing where the RST bit doesn't self-clear). For real
/// hardware with polling waits, use the sequence in ixgbeInit() instead.
pub fn initHardware(ops: *const RegOps, num_rx: u8, num_tx: u8) void {
    // 1. Disable interrupts (§4.6.3.1)
    ops.write(EIMC, EIMC_ALL);

    // 2. Global reset (§4.6.3.2)
    const ctrl = ops.read(CTRL);
    ops.write(CTRL, ctrl | CTRL_RST);
    // In real hardware: poll until CTRL.RST clears (self-clearing bit).
    // In mock: the bit stays set, which is fine for testing.

    // 3. Disable interrupts again after reset (reset re-enables them)
    ops.write(EIMC, EIMC_ALL);

    // 4. Wait for EEPROM auto-read: poll EEC.ARD (§4.6.3.3)
    // Real hardware: spin until bit 9 is set (typically <10ms).
    // Mock tests set this bit before calling initHardware.

    // 5. MAC address is read separately via readMacAddr()

    // 6-15. Post-reset configuration (MTA, HLREG0, FCTRL, SRRCTL, DMATXCTL,
    // TXDCTL, RXCTRL, RSS, AUTOC)
    initHardwarePostReset(ops, num_rx, num_tx);
}

/// Setup an RX queue's descriptor ring with pre-filled mbufs.
/// Writes RDBAL/RDBAH/RDLEN/RDH/RDT registers and enables the queue.
pub fn setupRxQueue(
    ops: *const RegOps,
    descs: [*]RxDesc,
    ring_size: u32,
    queue_idx: u32,
    ring_phys_addr: u64,
    pool: *MBufPool,
    shadow: []?*MBuf,
) void {
    // Write ring base address (split into low/high 32 bits)
    ops.write(RDBAL(queue_idx), @truncate(ring_phys_addr));
    ops.write(RDBAH(queue_idx), @truncate(ring_phys_addr >> 32));

    // Ring length in bytes (each descriptor = 16 bytes)
    ops.write(RDLEN(queue_idx), ring_size * 16);

    // Head = 0
    ops.write(RDH(queue_idx), 0);

    // Pre-fill descriptors with mbuf physical addresses
    for (0..ring_size) |i| {
        if (pool.get()) |mbuf| {
            descs[i].read.pkt_addr = mbuf.bufDmaAddr();
            descs[i].read.hdr_addr = 0;
            shadow[i] = mbuf;
        }
    }

    // Tail = ring_size - 1 (all descriptors available to NIC)
    ops.write(RDT(queue_idx), ring_size - 1);

    // Enable queue (§4.6.7.1) — set RXDCTL.ENABLE, then poll until it reads back
    ops.write(RXDCTL(queue_idx), RXDCTL_ENABLE);
}

/// Setup a TX queue's descriptor ring.
pub fn setupTxQueue(
    ops: *const RegOps,
    ring_size: u32,
    queue_idx: u32,
    ring_phys_addr: u64,
) void {
    ops.write(TDBAL(queue_idx), @truncate(ring_phys_addr));
    ops.write(TDBAH(queue_idx), @truncate(ring_phys_addr >> 32));
    ops.write(TDLEN(queue_idx), ring_size * 16);
    ops.write(TDH_REG(queue_idx), 0);
    ops.write(TDT_REG(queue_idx), 0);
    ops.write(TXDCTL(queue_idx), TXDCTL_ENABLE);
}

// ── RX Burst (Hot Path) ─────────────────────────────────────────────────

fn ixgbeRxBurst(queue: *pmd.RxQueue, bufs: []*MBuf, max_pkts: u16) u16 {
    const qdata: *IxgbeRxQueueData = @ptrCast(@alignCast(queue.driver_data orelse return 0));
    var count: u16 = 0;

    while (count < max_pkts) {
        const idx = qdata.sw_tail & qdata.ring_mask;
        const desc = &qdata.descs[idx];

        // Check DD (Descriptor Done) bit in write-back status
        if (desc.wb.status_error & RXD_STAT_DD == 0) break;

        // Extract packet metadata from write-back descriptor
        const mbuf = qdata.shadow[idx] orelse break;
        mbuf.pkt_len = desc.wb.pkt_len;
        mbuf.rss_hash = desc.wb.rss_hash;
        mbuf.data_off = 0; // NIC DMAs to bufDmaAddr() = data room start
        mbuf.port_id = queue.port_id;

        // VLAN tag extraction
        if (desc.wb.status_error & RXD_STAT_VP != 0) {
            mbuf.vlan_tag = desc.wb.vlan;
        } else {
            mbuf.vlan_tag = 0;
        }

        bufs[count] = mbuf;
        qdata.shadow[idx] = null;
        count += 1;
        qdata.sw_tail +%= 1;
    }

    // Refill consumed descriptors with fresh mbufs from the pool
    if (count > 0) {
        var refilled: u16 = 0;
        while (refilled < count) {
            const new_mbuf = qdata.pool.get() orelse {
                queue.stats.mbuf_alloc_failures += 1;
                break;
            };
            const slot = (qdata.sw_tail -% count +% refilled) & qdata.ring_mask;
            qdata.descs[slot].read.pkt_addr = new_mbuf.bufDmaAddr();
            qdata.descs[slot].read.hdr_addr = 0;
            qdata.shadow[slot] = new_mbuf;
            refilled += 1;
        }

        // Single doorbell write: tell NIC new buffers are available
        qdata.reg_ops.write(RDT(qdata.queue_idx), (qdata.sw_tail -% 1) & qdata.ring_mask);

        queue.stats.recordRx(count, 0);
    }

    return count;
}

// ── TX Burst (Hot Path) ─────────────────────────────────────────────────

fn ixgbeTxBurst(queue: *pmd.TxQueue, bufs_arg: []*MBuf, nb_pkts: u16) u16 {
    const qdata: *IxgbeTxQueueData = @ptrCast(@alignCast(queue.driver_data orelse return 0));

    // Reclaim completed TX descriptors (check DD bit in olinfo_status)
    reclaimTxCompleted(qdata);

    var count: u16 = 0;
    while (count < nb_pkts and qdata.freeCount() > 0) {
        const idx = qdata.sw_head & qdata.ring_mask;
        const desc = &qdata.descs[idx];

        desc.addr = bufs_arg[count].dmaAddr();
        desc.cmd_type_len = TXD_DTYP_ADV_DATA | TXD_CMD_EOP | TXD_CMD_IFCS | TXD_CMD_RS | bufs_arg[count].pkt_len;
        desc.olinfo_status = @as(u32, bufs_arg[count].pkt_len) << TXD_PAYLEN_SHIFT;

        qdata.shadow[idx] = bufs_arg[count];
        qdata.sw_head +%= 1;
        count += 1;
    }

    if (count > 0) {
        // Single doorbell write: tell NIC to start transmitting
        qdata.reg_ops.write(TDT_REG(qdata.queue_idx), qdata.sw_head & qdata.ring_mask);
        queue.stats.recordTx(count, 0);
    }

    return count;
}

/// Reclaim TX descriptors where NIC has set the DD (done) bit.
fn reclaimTxCompleted(qdata: *IxgbeTxQueueData) void {
    while (qdata.sw_tail != qdata.sw_head) {
        const idx = qdata.sw_tail & qdata.ring_mask;
        const desc = &qdata.descs[idx];

        // Check DD bit in olinfo_status (NIC write-back sets bit 0)
        if (desc.olinfo_status & TXD_STAT_DD == 0) break;

        // Free the completed mbuf
        if (qdata.shadow[idx]) |mbuf| {
            mbuf.free();
            qdata.shadow[idx] = null;
        }
        qdata.sw_tail +%= 1;
    }
}

// ── RSS Configuration ───────────────────────────────────────────────────

/// Default Toeplitz hash key (same as DPDK ixgbe default, Microsoft recommended).
pub const default_rss_key = [40]u8{
    0x6D, 0x5A, 0x56, 0xDA, 0x25, 0x5B, 0x0E, 0xC2,
    0x41, 0x67, 0x25, 0x3D, 0x43, 0xA3, 0x8F, 0xB0,
    0xD0, 0xCA, 0x2B, 0xCB, 0xAE, 0x7B, 0x30, 0xB4,
    0x77, 0xCB, 0x2D, 0xA3, 0x80, 0x30, 0xF2, 0x0C,
    0x6A, 0x42, 0xB7, 0x3B, 0xBE, 0xAC, 0x01, 0xFA,
};

/// Configure RSS: write hash key, RETA table, and enable in MRQC.
pub fn configureRss(ops: *const RegOps, num_rx_queues: u8) void {
    // Write 40-byte RSS key as 10 × u32 to RSSRK[0..9]
    for (0..10) |i| {
        const off = i * 4;
        const word: u32 = @as(u32, default_rss_key[off]) |
            (@as(u32, default_rss_key[off + 1]) << 8) |
            (@as(u32, default_rss_key[off + 2]) << 16) |
            (@as(u32, default_rss_key[off + 3]) << 24);
        ops.write(RSSRK(@intCast(i)), word);
    }

    // Write 128-entry RETA redirection table (packed 4 per u32 word)
    // Each entry is 4 bits (queue index) in bits [3:0], [11:8], [19:16], [27:24]
    for (0..32) |i| {
        const base: u8 = @intCast(i * 4);
        const q0: u32 = base % num_rx_queues;
        const q1: u32 = (base + 1) % num_rx_queues;
        const q2: u32 = (base + 2) % num_rx_queues;
        const q3: u32 = (base + 3) % num_rx_queues;
        const word = q0 | (q1 << 8) | (q2 << 16) | (q3 << 24);
        ops.write(RETA(@intCast(i)), word);
    }

    // Enable RSS with hash fields for IPv4/IPv6 + TCP/UDP
    ops.write(MRQC, MRQC_RSS_EN |
        MRQC_RSS_FIELD_IPV4 | MRQC_RSS_FIELD_IPV4_TCP | MRQC_RSS_FIELD_IPV4_UDP |
        MRQC_RSS_FIELD_IPV6 | MRQC_RSS_FIELD_IPV6_TCP | MRQC_RSS_FIELD_IPV6_UDP);
}

// ── Helper Functions ────────────────────────────────────────────────────

/// Read MAC address from RAL0/RAH0 registers.
pub fn readMacAddr(ops: *const RegOps) pmd.MacAddr {
    const ral = ops.read(RAL0);
    const rah = ops.read(RAH0);
    return .{
        .bytes = .{
            @truncate(ral),
            @truncate(ral >> 8),
            @truncate(ral >> 16),
            @truncate(ral >> 24),
            @truncate(rah),
            @truncate(rah >> 8),
        },
    };
}

/// Read link status from LINKS register.
pub fn readLinkStatus(ops: *const RegOps) pmd.LinkStatus {
    const links = ops.read(LINKS);
    const up = (links & LINKS_UP) != 0;
    const speed: pmd.LinkSpeed = switch (links & LINKS_SPEED_MASK) {
        LINKS_SPEED_10G => .speed_10g,
        LINKS_SPEED_1G => .speed_1g,
        LINKS_SPEED_100M => .speed_100m,
        else => .unknown,
    };
    return .{
        .link_up = up,
        .speed = speed,
        .full_duplex = up, // 82599 is always full duplex at 10G
        .autoneg = true,
    };
}

/// Clear all hardware statistics registers by reading them.
pub fn clearStatRegisters(ops: *const RegOps) void {
    _ = ops.read(GPRC);
    _ = ops.read(GPTC);
    _ = ops.read(GORCL);
    _ = ops.read(GORCH);
    _ = ops.read(GOTCL);
    _ = ops.read(GOTCH);
}

// ── Hardware Wait / Polling Helpers ──────────────────────────────────────

/// Poll until CTRL.RST bit clears (self-clearing on real hardware).
/// On real silicon the reset completes in ~1ms; we spin with PAUSE to avoid
/// wasting power. Returns error.ResetFailed if the bit doesn't clear within
/// `max_attempts` iterations.
pub fn waitForReset(ops: *const RegOps, max_attempts: u32) pmd.PmdError!void {
    var i: u32 = 0;
    while (i < max_attempts) : (i += 1) {
        if (ops.read(CTRL) & CTRL_RST == 0) return;
        std.atomic.spinLoopHint();
    }
    return error.ResetFailed;
}

/// Poll until EEC.ARD (Auto Read Done) bit is set, indicating the EEPROM
/// has been loaded into shadow RAM (§4.6.3.3). Typically completes in <10ms
/// on real hardware. Returns error.EepromReadFailed on timeout.
pub fn waitForEeprom(ops: *const RegOps, max_attempts: u32) pmd.PmdError!void {
    var i: u32 = 0;
    while (i < max_attempts) : (i += 1) {
        if (ops.read(EEC) & EEC_ARD != 0) return;
        std.atomic.spinLoopHint();
    }
    return error.EepromReadFailed;
}

/// Poll until LINKS.UP bit is set, indicating physical link is established
/// (§4.6.3.8). On real hardware with SFP+ modules this can take several
/// seconds after autoneg restart; use a large max_attempts (e.g., 9_000_000
/// ≈ 9 seconds at ~1µs per spin iteration).
/// Returns error.LinkTimeout if the link doesn't come up.
pub fn waitForLink(ops: *const RegOps, max_attempts: u32) pmd.PmdError!void {
    var i: u32 = 0;
    while (i < max_attempts) : (i += 1) {
        if (ops.read(LINKS) & LINKS_UP != 0) return;
        std.atomic.spinLoopHint();
    }
    return error.LinkTimeout;
}

// ── Post-Reset Hardware Configuration ────────────────────────────────────

/// Configure 82599 registers after reset has completed.
/// This is the second half of the §4.6.3 sequence — steps 6-15 from
/// initHardware(), skipping the interrupt disable / reset / EEPROM wait
/// steps which are done with proper polling in ixgbeInit().
///
/// initHardware() calls this internally (after its non-polling reset).
/// ixgbeInit() calls it directly after doing polled reset + EEPROM wait.
pub fn initHardwarePostReset(ops: *const RegOps, num_rx: u8, num_tx: u8) void {
    // 6. Clear Multicast Table Array (§4.6.3.4)
    for (0..MTA_COUNT) |i| {
        ops.write(MTA_BASE + @as(u32, @intCast(i)) * 4, 0);
    }

    // 7. Configure HLREG0: CRC strip on RX, CRC insertion on TX, pad short frames
    ops.write(HLREG0, HLREG0_TXCRCEN | HLREG0_RXCRCSTRP | HLREG0_TXPADEN);

    // 8. Configure FCTRL: accept broadcast (required for ARP)
    ops.write(FCTRL, FCTRL_BAM);

    // 9. Configure per-queue RX (SRRCTL, RXDCTL) for each queue
    for (0..num_rx) |qi| {
        const q: u32 = @intCast(qi);
        ops.write(SRRCTL(q), SRRCTL_BSIZEPACKET_2K | SRRCTL_DESCTYPE_ADV_ONE | SRRCTL_DROP_EN);
    }

    // 10. Enable DMA TX engine (§4.6.3.7)
    ops.write(DMATXCTL, DMATXCTL_TE);

    // 11. Configure per-queue TX (TXDCTL) for each queue
    for (0..num_tx) |qi| {
        const q: u32 = @intCast(qi);
        ops.write(TXDCTL(q), TXDCTL_ENABLE);
    }

    // 12. Enable RX globally (§4.6.3.6)
    ops.write(RXCTRL, RXCTRL_RXEN);

    // 13. Configure RSS if multiple RX queues
    if (num_rx > 1) {
        configureRss(ops, num_rx);
    }

    // 14. Link configuration: set AUTOC for 10G SFI and restart autoneg
    const autoc = ops.read(AUTOC);
    ops.write(AUTOC, (autoc & ~@as(u32, 0x7 << 13)) | AUTOC_LMS_10G_SFI | AUTOC_AN_RESTART);
}

// ── Stop / Stats / LinkStatus (PMD vtable) ──────────────────────────────

fn ixgbeStop(dev: *pmd.Device) void {
    // Find our IxgbeDevice from the embedded pmd.Device pointer.
    // IxgbeDevice.dev is the first field, so pointer arithmetic works.
    const ixdev: *IxgbeDevice = @fieldParentPtr("dev", dev);
    const ops = &ixdev.reg_ops;

    // 1. Disable RX globally: clear RXCTRL.RXEN
    ops.write(RXCTRL, ops.read(RXCTRL) & ~RXCTRL_RXEN);

    // 2. Disable each RX queue
    for (0..dev.num_rx_queues) |qi| {
        const q: u32 = @intCast(qi);
        ops.write(RXDCTL(q), ops.read(RXDCTL(q)) & ~RXDCTL_ENABLE);
    }

    // 3. Disable DMA TX engine: clear DMATXCTL.TE
    ops.write(DMATXCTL, ops.read(DMATXCTL) & ~DMATXCTL_TE);

    // 4. Disable each TX queue
    for (0..dev.num_tx_queues) |qi| {
        const q: u32 = @intCast(qi);
        ops.write(TXDCTL(q), ops.read(TXDCTL(q)) & ~TXDCTL_ENABLE);
    }

    // 5. Free all RX shadow mbufs (return to pool)
    for (0..dev.num_rx_queues) |qi| {
        for (&ixdev.rx_queue_data[qi].shadow) |*slot| {
            if (slot.*) |mbuf| {
                mbuf.free();
                slot.* = null;
            }
        }
    }

    // 6. Free all TX shadow mbufs (return to pool)
    for (0..dev.num_tx_queues) |qi| {
        for (&ixdev.tx_queue_data[qi].shadow) |*slot| {
            if (slot.*) |mbuf| {
                mbuf.free();
                slot.* = null;
            }
        }
    }

    // 7. VFIO cleanup (only if this device was opened via ixgbeInit)
    if (ixdev.vfio_owned) {
        ixdev.vfio_device.close();
        ixdev.vfio_group.close();
        ixdev.vfio_container.close();
        ixdev.vfio_owned = false;
    }

    // 8. Free descriptor ring hugepage region
    if (ixdev.desc_region) |*region| {
        hugepage.freeRegion(region);
        ixdev.desc_region = null;
        ixdev.desc_region_phys = 0;
    }

    dev.started = false;
}

fn ixgbeStats(dev: *const pmd.Device) stats_mod.PortStats {
    return dev.stats;
}

fn ixgbeLinkStatus(dev: *const pmd.Device) pmd.LinkStatus {
    return dev.link;
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "ixgbe: descriptor struct sizes" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(RxDescRead));
    try testing.expectEqual(@as(usize, 16), @sizeOf(RxDescWb));
    try testing.expectEqual(@as(usize, 16), @sizeOf(RxDesc));
    try testing.expectEqual(@as(usize, 16), @sizeOf(TxDesc));
}

test "ixgbe: register offset calculations" {
    // RX queue 0
    try testing.expectEqual(@as(u32, 0x01000), RDBAL(0));
    try testing.expectEqual(@as(u32, 0x01004), RDBAH(0));
    try testing.expectEqual(@as(u32, 0x01008), RDLEN(0));
    try testing.expectEqual(@as(u32, 0x01018), RDT(0));
    // RX queue 3
    try testing.expectEqual(@as(u32, 0x01000 + 0xC0), RDBAL(3));
    // TX queue 0
    try testing.expectEqual(@as(u32, 0x06000), TDBAL(0));
    try testing.expectEqual(@as(u32, 0x06018), TDT_REG(0));
    // TX queue 2
    try testing.expectEqual(@as(u32, 0x06000 + 0x80), TDBAL(2));
    // RSS
    try testing.expectEqual(@as(u32, 0x0EB80), RSSRK(0));
    try testing.expectEqual(@as(u32, 0x0EB00), RETA(0));
}

test "ixgbe: mock register read/write" {
    var mock = MockRegs.init();
    var ops = mock.regOps();

    ops.write(CTRL, 0xDEADBEEF);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), ops.read(CTRL));

    ops.write(EIMC, EIMC_ALL);
    try testing.expectEqual(EIMC_ALL, ops.read(EIMC));

    // Convenience accessors
    mock.set(LINKS, LINKS_UP | LINKS_SPEED_10G);
    try testing.expectEqual(LINKS_UP | LINKS_SPEED_10G, mock.get(LINKS));
}

test "ixgbe: read MAC address" {
    var mock = MockRegs.init();
    const ops = mock.regOps();

    // Set MAC = DE:AD:BE:EF:CA:FE
    mock.set(RAL0, 0xEFBEADDE); // little-endian: bytes 0-3
    mock.set(RAH0, 0x0000FECA | RAH_AV); // bytes 4-5 + address valid

    const mac = readMacAddr(&ops);
    try testing.expectEqual(@as(u8, 0xDE), mac.bytes[0]);
    try testing.expectEqual(@as(u8, 0xAD), mac.bytes[1]);
    try testing.expectEqual(@as(u8, 0xBE), mac.bytes[2]);
    try testing.expectEqual(@as(u8, 0xEF), mac.bytes[3]);
    try testing.expectEqual(@as(u8, 0xCA), mac.bytes[4]);
    try testing.expectEqual(@as(u8, 0xFE), mac.bytes[5]);
}

test "ixgbe: read link status" {
    var mock = MockRegs.init();
    const ops = mock.regOps();

    // Link down
    mock.set(LINKS, 0);
    const down = readLinkStatus(&ops);
    try testing.expect(!down.link_up);
    try testing.expectEqual(pmd.LinkSpeed.unknown, down.speed);

    // Link up at 10G
    mock.set(LINKS, LINKS_UP | LINKS_SPEED_10G);
    const up = readLinkStatus(&ops);
    try testing.expect(up.link_up);
    try testing.expectEqual(pmd.LinkSpeed.speed_10g, up.speed);
    try testing.expect(up.full_duplex);
}

test "ixgbe: init hardware writes correct registers" {
    var mock = MockRegs.init();
    const ops = mock.regOps();

    // Pre-set EEC.ARD so init doesn't need to poll
    mock.set(EEC, EEC_ARD);

    initHardware(&ops, 2, 2);

    // Verify interrupts disabled
    try testing.expectEqual(EIMC_ALL, mock.get(EIMC));

    // Verify MTA cleared (spot check first and last)
    try testing.expectEqual(@as(u32, 0), mock.get(MTA_BASE));
    try testing.expectEqual(@as(u32, 0), mock.get(MTA_BASE + 127 * 4));

    // Verify HLREG0 configured
    try testing.expectEqual(HLREG0_TXCRCEN | HLREG0_RXCRCSTRP | HLREG0_TXPADEN, mock.get(HLREG0));

    // Verify FCTRL configured
    try testing.expectEqual(FCTRL_BAM, mock.get(FCTRL));

    // Verify DMA TX enabled
    try testing.expectEqual(DMATXCTL_TE, mock.get(DMATXCTL));

    // Verify RX globally enabled
    try testing.expectEqual(RXCTRL_RXEN, mock.get(RXCTRL));

    // Verify SRRCTL for queues 0 and 1
    try testing.expectEqual(
        SRRCTL_BSIZEPACKET_2K | SRRCTL_DESCTYPE_ADV_ONE | SRRCTL_DROP_EN,
        mock.get(SRRCTL(0)),
    );
    try testing.expectEqual(
        SRRCTL_BSIZEPACKET_2K | SRRCTL_DESCTYPE_ADV_ONE | SRRCTL_DROP_EN,
        mock.get(SRRCTL(1)),
    );

    // Verify TX queues enabled
    try testing.expectEqual(TXDCTL_ENABLE, mock.get(TXDCTL(0)));
    try testing.expectEqual(TXDCTL_ENABLE, mock.get(TXDCTL(1)));

    // Verify RSS configured (2 queues → RSS enabled)
    try testing.expect(mock.get(MRQC) & MRQC_RSS_EN != 0);
}

test "ixgbe: RSS configuration" {
    var mock = MockRegs.init();
    const ops = mock.regOps();

    configureRss(&ops, 4);

    // Verify RSS key was written (first word)
    const expected_key0: u32 = @as(u32, 0x6D) |
        (@as(u32, 0x5A) << 8) |
        (@as(u32, 0x56) << 16) |
        (@as(u32, 0xDA) << 24);
    try testing.expectEqual(expected_key0, mock.get(RSSRK(0)));

    // Verify RETA table: first word should distribute to queues 0,1,2,3
    const reta0 = mock.get(RETA(0));
    try testing.expectEqual(@as(u32, 0), reta0 & 0xFF); // entry 0 → queue 0
    try testing.expectEqual(@as(u32, 1), (reta0 >> 8) & 0xFF); // entry 1 → queue 1
    try testing.expectEqual(@as(u32, 2), (reta0 >> 16) & 0xFF); // entry 2 → queue 2
    try testing.expectEqual(@as(u32, 3), (reta0 >> 24) & 0xFF); // entry 3 → queue 3

    // Verify MRQC
    const mrqc = mock.get(MRQC);
    try testing.expect(mrqc & MRQC_RSS_EN != 0);
    try testing.expect(mrqc & MRQC_RSS_FIELD_IPV4_TCP != 0);
    try testing.expect(mrqc & MRQC_RSS_FIELD_IPV4_UDP != 0);
}

test "ixgbe: rxBurst with simulated packets" {
    // Create an mbuf pool
    var pool = try MBufPool.create(64, .regular);
    defer pool.destroy();
    pool.populate();

    // Allocate descriptor ring on the stack (aligned)
    var descs: [TEST_RING_SIZE]RxDesc align(16) = undefined;
    @memset(std.mem.asBytes(&descs), 0);

    var mock = MockRegs.init();
    const reg_ops = mock.regOps();

    // Create RX queue data
    var rxq_data = IxgbeRxQueueData.init(&descs, TEST_RING_SIZE, 0, reg_ops, &pool);

    // Pre-fill descriptors with mbufs (simulating setupRxQueue)
    for (0..TEST_RING_SIZE) |i| {
        if (pool.get()) |mbuf| {
            descs[i].read.pkt_addr = mbuf.bufDmaAddr();
            descs[i].read.hdr_addr = 0;
            rxq_data.shadow[i] = mbuf;
        }
    }

    // Simulate NIC writing back 3 packets.
    // The NIC overwrites the entire 16-byte descriptor with write-back format,
    // so we must zero each descriptor before setting write-back fields (the
    // pre-fill wrote physical addresses into the read format which overlaps).

    @memset(std.mem.asBytes(&descs[0]), 0);
    descs[0].wb.status_error = RXD_STAT_DD | RXD_STAT_EOP;
    descs[0].wb.pkt_len = 64;
    descs[0].wb.rss_hash = 0x12345678;

    @memset(std.mem.asBytes(&descs[1]), 0);
    descs[1].wb.status_error = RXD_STAT_DD | RXD_STAT_EOP | RXD_STAT_VP;
    descs[1].wb.pkt_len = 128;
    descs[1].wb.vlan = 100;

    @memset(std.mem.asBytes(&descs[2]), 0);
    descs[2].wb.status_error = RXD_STAT_DD | RXD_STAT_EOP;
    descs[2].wb.pkt_len = 1500;
    descs[2].wb.rss_hash = 0xAABBCCDD;

    // Ensure remaining descriptors have status_error = 0 (no DD bit).
    // Pre-fill wrote physical addresses into read.pkt_addr; the upper 32 bits
    // overlap with wb.status_error at offset 4. Clear them.
    for (3..TEST_RING_SIZE) |i| {
        descs[i].wb.status_error = 0;
    }

    // Create PMD RxQueue wrapper
    var rx_queue = pmd.RxQueue{
        .queue_id = 0,
        .port_id = 1,
        .driver_data = @ptrCast(&rxq_data),
    };

    // Burst receive
    var bufs: [16]*MBuf = undefined;
    const count = ixgbeRxBurst(&rx_queue, &bufs, 16);

    try testing.expectEqual(@as(u16, 3), count);

    // Verify packet 0
    try testing.expectEqual(@as(u16, 64), bufs[0].pkt_len);
    try testing.expectEqual(@as(u32, 0x12345678), bufs[0].rss_hash);
    try testing.expectEqual(@as(u16, 0), bufs[0].data_off);
    try testing.expectEqual(@as(u8, 1), bufs[0].port_id);
    try testing.expectEqual(@as(u16, 0), bufs[0].vlan_tag);

    // Verify packet 1 (VLAN tagged)
    try testing.expectEqual(@as(u16, 128), bufs[1].pkt_len);
    try testing.expectEqual(@as(u16, 100), bufs[1].vlan_tag);

    // Verify packet 2
    try testing.expectEqual(@as(u16, 1500), bufs[2].pkt_len);
    try testing.expectEqual(@as(u32, 0xAABBCCDD), bufs[2].rss_hash);

    // Verify RDT doorbell was written
    try testing.expectEqual(@as(u32, 2), mock.get(RDT(0)));

    // Free received mbufs
    for (0..count) |i| {
        bufs[i].free();
    }

    // Free remaining shadow mbufs
    for (3..TEST_RING_SIZE) |i| {
        if (rxq_data.shadow[i]) |mbuf| mbuf.free();
    }
}

test "ixgbe: txBurst with completion" {
    var pool = try MBufPool.create(64, .regular);
    defer pool.destroy();
    pool.populate();

    var descs: [TEST_RING_SIZE]TxDesc align(16) = undefined;
    @memset(std.mem.asBytes(&descs), 0);

    var mock = MockRegs.init();
    const reg_ops = mock.regOps();

    var txq_data = IxgbeTxQueueData.init(&descs, TEST_RING_SIZE, 0, reg_ops);

    var tx_queue = pmd.TxQueue{
        .queue_id = 0,
        .port_id = 0,
        .driver_data = @ptrCast(&txq_data),
    };

    // Allocate 4 mbufs to transmit
    var bufs: [4]*MBuf = undefined;
    for (&bufs) |*b| {
        b.* = pool.get().?;
        b.*.pkt_len = 64;
    }

    // Transmit burst
    const sent = ixgbeTxBurst(&tx_queue, &bufs, 4);
    try testing.expectEqual(@as(u16, 4), sent);

    // Verify descriptors were written
    try testing.expect(descs[0].cmd_type_len & TXD_CMD_EOP != 0);
    try testing.expect(descs[0].cmd_type_len & TXD_CMD_IFCS != 0);
    try testing.expect(descs[0].cmd_type_len & TXD_CMD_RS != 0);

    // Verify PAYLEN in olinfo_status
    try testing.expectEqual(@as(u32, 64) << TXD_PAYLEN_SHIFT, descs[0].olinfo_status);

    // Verify TDT doorbell
    try testing.expectEqual(@as(u32, 4), mock.get(TDT_REG(0)));

    // Verify sw_head advanced
    try testing.expectEqual(@as(u32, 4), txq_data.sw_head);
    try testing.expectEqual(@as(u32, 0), txq_data.sw_tail);

    // Simulate NIC completing first 2 descriptors (set DD bit)
    descs[0].olinfo_status |= TXD_STAT_DD;
    descs[1].olinfo_status |= TXD_STAT_DD;

    // Next txBurst should reclaim those 2
    var more: [1]*MBuf = undefined;
    more[0] = pool.get().?;
    more[0].pkt_len = 100;
    _ = ixgbeTxBurst(&tx_queue, &more, 1);

    // sw_tail should have advanced past the 2 completed descriptors
    try testing.expectEqual(@as(u32, 2), txq_data.sw_tail);

    // Clean up remaining shadow mbufs
    for (0..TEST_RING_SIZE) |i| {
        if (txq_data.shadow[i]) |mbuf| mbuf.free();
    }
}

test "ixgbe: tx ring full" {
    var pool = try MBufPool.create(128, .regular);
    defer pool.destroy();
    pool.populate();

    var descs: [TEST_RING_SIZE]TxDesc align(16) = undefined;
    @memset(std.mem.asBytes(&descs), 0);

    var mock = MockRegs.init();
    const reg_ops = mock.regOps();
    var txq_data = IxgbeTxQueueData.init(&descs, TEST_RING_SIZE, 0, reg_ops);

    var tx_queue = pmd.TxQueue{
        .queue_id = 0,
        .port_id = 0,
        .driver_data = @ptrCast(&txq_data),
    };

    // Fill the entire ring
    var bufs: [TEST_RING_SIZE]*MBuf = undefined;
    for (&bufs) |*b| {
        b.* = pool.get().?;
        b.*.pkt_len = 64;
    }
    const sent = ixgbeTxBurst(&tx_queue, &bufs, TEST_RING_SIZE);
    try testing.expectEqual(@as(u16, TEST_RING_SIZE), sent);

    // Try to send one more — should return 0 (ring full)
    var extra: [1]*MBuf = undefined;
    extra[0] = pool.get().?;
    extra[0].pkt_len = 64;
    const sent2 = ixgbeTxBurst(&tx_queue, &extra, 1);
    try testing.expectEqual(@as(u16, 0), sent2);

    // Free the extra mbuf we couldn't send
    extra[0].free();

    // Clean up shadow
    for (0..TEST_RING_SIZE) |i| {
        if (txq_data.shadow[i]) |mbuf| mbuf.free();
    }
}

test "ixgbe: pmd vtable" {
    try testing.expect(std.mem.eql(u8, ixgbe_pmd.name, "ixgbe"));
    try testing.expect(@intFromPtr(ixgbe_pmd.initFn) != 0);
    try testing.expect(@intFromPtr(ixgbe_pmd.rxBurstFn) != 0);
    try testing.expect(@intFromPtr(ixgbe_pmd.txBurstFn) != 0);
    try testing.expect(@intFromPtr(ixgbe_pmd.stopFn) != 0);
    try testing.expect(@intFromPtr(ixgbe_pmd.statsFn) != 0);
    try testing.expect(@intFromPtr(ixgbe_pmd.linkStatusFn) != 0);
}

test "ixgbe: setup rx queue writes registers" {
    var pool = try MBufPool.create(64, .regular);
    defer pool.destroy();
    pool.populate();

    var descs: [TEST_RING_SIZE]RxDesc align(16) = undefined;
    @memset(std.mem.asBytes(&descs), 0);

    var shadow: [MAX_RING_SIZE]?*MBuf = [_]?*MBuf{null} ** MAX_RING_SIZE;

    var mock = MockRegs.init();
    const ops = mock.regOps();

    const ring_phys: u64 = 0x0000_0001_0000_0000; // test phys addr > 4GB
    setupRxQueue(&ops, &descs, TEST_RING_SIZE, 2, ring_phys, &pool, &shadow);

    // Verify register writes for queue 2
    try testing.expectEqual(@as(u32, 0x0000_0000), mock.get(RDBAL(2))); // low 32 bits
    try testing.expectEqual(@as(u32, 0x0000_0001), mock.get(RDBAH(2))); // high 32 bits
    try testing.expectEqual(TEST_RING_SIZE * 16, mock.get(RDLEN(2)));
    try testing.expectEqual(@as(u32, 0), mock.get(RDH(2)));
    try testing.expectEqual(TEST_RING_SIZE - 1, mock.get(RDT(2)));
    try testing.expectEqual(RXDCTL_ENABLE, mock.get(RXDCTL(2)));

    // Verify descriptors were pre-filled with mbuf physical addresses
    for (0..TEST_RING_SIZE) |i| {
        try testing.expect(shadow[i] != null);
        if (shadow[i]) |mbuf| {
            try testing.expectEqual(mbuf.bufDmaAddr(), descs[i].read.pkt_addr);
        }
    }

    // Clean up
    for (0..TEST_RING_SIZE) |i| {
        if (shadow[i]) |mbuf| mbuf.free();
    }
}

test "ixgbe: setup tx queue writes registers" {
    var mock = MockRegs.init();
    const ops = mock.regOps();

    const ring_phys: u64 = 0x0000_0002_AABB_0000;
    setupTxQueue(&ops, 512, 1, ring_phys);

    try testing.expectEqual(@as(u32, 0xAABB_0000), mock.get(TDBAL(1)));
    try testing.expectEqual(@as(u32, 0x0000_0002), mock.get(TDBAH(1)));
    try testing.expectEqual(@as(u32, 512 * 16), mock.get(TDLEN(1)));
    try testing.expectEqual(@as(u32, 0), mock.get(TDH_REG(1)));
    try testing.expectEqual(@as(u32, 0), mock.get(TDT_REG(1)));
    try testing.expectEqual(TXDCTL_ENABLE, mock.get(TXDCTL(1)));
}

// ── initWithRegOps (test-friendly init, no VFIO) ────────────────────────

/// Initialize an ixgbe device with externally-provided RegOps and pool.
/// For integration testing with MockRegs — no VFIO needed.
/// Allocates a device slot from the static `devices[]` array and wires up
/// queues with stack-allocated descriptor rings (caller provides the memory).
pub fn initWithRegOps(
    ops: RegOps,
    pool: *MBufPool,
    num_rx: u8,
    num_tx: u8,
    rx_descs: [*]RxDesc,
    tx_descs: [*]TxDesc,
    ring_size: u32,
) *IxgbeDevice {
    std.debug.assert(device_count < config.max_ports);

    const idx = device_count;
    device_count += 1;
    const device = &devices[idx];

    device.* = IxgbeDevice{
        .dev = .{
            .driver = &ixgbe_pmd,
            .port_id = idx,
            .num_rx_queues = num_rx,
            .num_tx_queues = num_tx,
            .started = false,
        },
        .reg_ops = ops,
        .pool = pool,
        .rx_queue_data = undefined,
        .tx_queue_data = undefined,
    };

    // Run the full hardware init sequence (non-polled, suitable for MockRegs)
    initHardware(&device.reg_ops, num_rx, num_tx);

    // Setup RX queues
    for (0..num_rx) |qi| {
        const q: u8 = @intCast(qi);
        const q32: u32 = @intCast(qi);
        const rx_ring_ptr: [*]RxDesc = rx_descs + qi * ring_size;

        device.rx_queue_data[qi] = IxgbeRxQueueData.init(rx_ring_ptr, ring_size, q32, device.reg_ops, pool);

        setupRxQueue(&device.reg_ops, rx_ring_ptr, ring_size, q32, 0x1000 * (q32 + 1), pool, &device.rx_queue_data[qi].shadow);

        device.dev.rx_queues[qi] = .{
            .queue_id = q,
            .port_id = idx,
            .driver_data = @ptrCast(&device.rx_queue_data[qi]),
        };
    }

    // Setup TX queues
    for (0..num_tx) |qi| {
        const q: u8 = @intCast(qi);
        const q32: u32 = @intCast(qi);

        device.tx_queue_data[qi] = IxgbeTxQueueData.init(
            tx_descs + qi * ring_size,
            ring_size,
            q32,
            device.reg_ops,
        );

        setupTxQueue(&device.reg_ops, ring_size, q32, 0x2000 * (q32 + 1));

        device.dev.tx_queues[qi] = .{
            .queue_id = q,
            .port_id = idx,
            .driver_data = @ptrCast(&device.tx_queue_data[qi]),
        };
    }

    device.dev.started = true;
    return device;
}

/// Reset the static device counter (for test isolation).
pub fn resetDeviceCount() void {
    device_count = 0;
}

// ── New Tests: Hardware Wait Functions ───────────────────────────────────

test "ixgbe: waitForReset succeeds when RST bit is clear" {
    var mock = MockRegs.init();
    const ops = mock.regOps();

    // CTRL.RST is already 0 in a fresh MockRegs — bit clear = reset complete
    try waitForReset(&ops, 100);
}

test "ixgbe: waitForReset times out when RST bit stays set" {
    var mock = MockRegs.init();
    const ops = mock.regOps();

    // Set CTRL.RST — simulates hardware mid-reset
    mock.set(CTRL, CTRL_RST);

    const result = waitForReset(&ops, 10);
    try testing.expectError(error.ResetFailed, result);
}

test "ixgbe: waitForEeprom succeeds when ARD bit is set" {
    var mock = MockRegs.init();
    const ops = mock.regOps();

    // Pre-set EEC.ARD — EEPROM auto-read complete
    mock.set(EEC, EEC_ARD);

    try waitForEeprom(&ops, 100);
}

test "ixgbe: waitForEeprom times out when ARD bit never set" {
    var mock = MockRegs.init();
    const ops = mock.regOps();

    // EEC.ARD is 0 — EEPROM never completes
    const result = waitForEeprom(&ops, 10);
    try testing.expectError(error.EepromReadFailed, result);
}

test "ixgbe: waitForLink succeeds when link is up" {
    var mock = MockRegs.init();
    const ops = mock.regOps();

    // Pre-set LINKS.UP
    mock.set(LINKS, LINKS_UP | LINKS_SPEED_10G);

    try waitForLink(&ops, 100);
}

test "ixgbe: waitForLink times out when link stays down" {
    var mock = MockRegs.init();
    const ops = mock.regOps();

    // LINKS.UP is 0 — no cable / no SFP
    const result = waitForLink(&ops, 10);
    try testing.expectError(error.LinkTimeout, result);
}

test "ixgbe: initHardwarePostReset configures registers correctly" {
    var mock = MockRegs.init();
    const ops = mock.regOps();

    initHardwarePostReset(&ops, 2, 2);

    // Verify MTA cleared
    try testing.expectEqual(@as(u32, 0), mock.get(MTA_BASE));
    try testing.expectEqual(@as(u32, 0), mock.get(MTA_BASE + 127 * 4));

    // Verify HLREG0
    try testing.expectEqual(HLREG0_TXCRCEN | HLREG0_RXCRCSTRP | HLREG0_TXPADEN, mock.get(HLREG0));

    // Verify FCTRL
    try testing.expectEqual(FCTRL_BAM, mock.get(FCTRL));

    // Verify SRRCTL for both queues
    try testing.expectEqual(
        SRRCTL_BSIZEPACKET_2K | SRRCTL_DESCTYPE_ADV_ONE | SRRCTL_DROP_EN,
        mock.get(SRRCTL(0)),
    );
    try testing.expectEqual(
        SRRCTL_BSIZEPACKET_2K | SRRCTL_DESCTYPE_ADV_ONE | SRRCTL_DROP_EN,
        mock.get(SRRCTL(1)),
    );

    // Verify DMATXCTL
    try testing.expectEqual(DMATXCTL_TE, mock.get(DMATXCTL));

    // Verify TXDCTL
    try testing.expectEqual(TXDCTL_ENABLE, mock.get(TXDCTL(0)));
    try testing.expectEqual(TXDCTL_ENABLE, mock.get(TXDCTL(1)));

    // Verify RXCTRL
    try testing.expectEqual(RXCTRL_RXEN, mock.get(RXCTRL));

    // Verify RSS enabled (2 queues)
    try testing.expect(mock.get(MRQC) & MRQC_RSS_EN != 0);

    // Verify AUTOC configured for 10G SFI
    try testing.expect(mock.get(AUTOC) & AUTOC_LMS_10G_SFI != 0);
    try testing.expect(mock.get(AUTOC) & AUTOC_AN_RESTART != 0);
}

test "ixgbe: device stop disables queues and frees mbufs" {
    // Save and restore device_count for test isolation
    const saved_count = device_count;
    defer {
        device_count = saved_count;
    }

    var pool = try MBufPool.create(128, .regular);
    defer pool.destroy();
    pool.populate();

    const initial_free = pool.availableCount();

    var mock = MockRegs.init();
    const ops = mock.regOps();

    // Pre-set EEC.ARD and LINKS.UP for initHardware
    mock.set(EEC, EEC_ARD);
    mock.set(LINKS, LINKS_UP | LINKS_SPEED_10G);

    var rx_descs: [TEST_RING_SIZE]RxDesc align(16) = undefined;
    @memset(std.mem.asBytes(&rx_descs), 0);
    var tx_descs: [TEST_RING_SIZE]TxDesc align(16) = undefined;
    @memset(std.mem.asBytes(&tx_descs), 0);

    const ixdev = initWithRegOps(ops, &pool, 1, 1, &rx_descs, &tx_descs, TEST_RING_SIZE);

    // Device should be started
    try testing.expect(ixdev.dev.started);

    // RX queue should have shadow mbufs (pre-filled by setupRxQueue)
    var rx_mbuf_count: u32 = 0;
    for (ixdev.rx_queue_data[0].shadow[0..TEST_RING_SIZE]) |slot| {
        if (slot != null) rx_mbuf_count += 1;
    }
    try testing.expect(rx_mbuf_count > 0);

    // Record how many mbufs are allocated (away from pool)
    const pre_stop_free = pool.availableCount();
    try testing.expect(pre_stop_free < initial_free);

    // Stop the device
    ixgbeStop(&ixdev.dev);

    // Device should be stopped
    try testing.expect(!ixdev.dev.started);

    // RXCTRL should have RXEN cleared
    try testing.expectEqual(@as(u32, 0), mock.get(RXCTRL) & RXCTRL_RXEN);

    // DMATXCTL should have TE cleared
    try testing.expectEqual(@as(u32, 0), mock.get(DMATXCTL) & DMATXCTL_TE);

    // RXDCTL queue 0 should have ENABLE cleared
    try testing.expectEqual(@as(u32, 0), mock.get(RXDCTL(0)) & RXDCTL_ENABLE);

    // TXDCTL queue 0 should have ENABLE cleared
    try testing.expectEqual(@as(u32, 0), mock.get(TXDCTL(0)) & TXDCTL_ENABLE);

    // All shadow mbufs should have been returned to the pool
    try testing.expectEqual(initial_free, pool.availableCount());
}
