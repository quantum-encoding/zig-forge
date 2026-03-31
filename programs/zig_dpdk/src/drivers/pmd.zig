const std = @import("std");
const config = @import("../core/config.zig");
const mbuf_mod = @import("../core/mbuf.zig");
const stats_mod = @import("../core/stats.zig");

pub const MBuf = mbuf_mod.MBuf;
pub const MBufPool = mbuf_mod.MBufPool;

/// Link speed in Mbps.
pub const LinkSpeed = enum(u32) {
    unknown = 0,
    speed_10m = 10,
    speed_100m = 100,
    speed_1g = 1000,
    speed_10g = 10000,
    speed_25g = 25000,
    speed_40g = 40000,
    speed_100g = 100000,
};

/// Link status.
pub const LinkStatus = struct {
    speed: LinkSpeed = .unknown,
    link_up: bool = false,
    full_duplex: bool = false,
    autoneg: bool = false,
};

/// 6-byte MAC address.
pub const MacAddr = extern struct {
    bytes: [6]u8 = [_]u8{0} ** 6,

    pub fn format(self: MacAddr, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
            self.bytes[0], self.bytes[1], self.bytes[2],
            self.bytes[3], self.bytes[4], self.bytes[5],
        });
    }
};

/// Configuration for NIC device initialization.
pub const DeviceConfig = struct {
    /// PCI address string "DDDD:BB:DD.F" (for native PMDs)
    pci_addr: [13]u8 = [_]u8{0} ** 13,
    /// Network interface name "eth0", "ens3f0" (for AF_XDP)
    iface_name: [16]u8 = [_]u8{0} ** 16,
    num_rx_queues: u8 = 1,
    num_tx_queues: u8 = 1,
    rx_ring_size: u32 = config.default_rx_ring_size,
    tx_ring_size: u32 = config.default_tx_ring_size,
    pool: ?*MBufPool = null,
    mtu: u16 = 1500,
};

/// Per-queue RX state (generic wrapper; driver extends with NIC-specific fields).
pub const RxQueue = struct {
    queue_id: u8 = 0,
    port_id: u8 = 0,
    stats: stats_mod.QueueStats = .{},
    /// Driver-specific opaque state
    driver_data: ?*anyopaque = null,
};

/// Per-queue TX state.
pub const TxQueue = struct {
    queue_id: u8 = 0,
    port_id: u8 = 0,
    stats: stats_mod.QueueStats = .{},
    driver_data: ?*anyopaque = null,
};

/// Poll-mode driver vtable.
/// Each NIC driver provides an instance of this struct.
/// When the driver is known at comptime, bypass the vtable and call the
/// driver's functions directly to eliminate indirect call overhead.
pub const PollModeDriver = struct {
    name: []const u8,

    /// Initialize device hardware and allocate queues.
    initFn: *const fn (*DeviceConfig) PmdError!*Device,

    /// Receive up to max_pkts packets. Never blocks. Never allocates.
    rxBurstFn: *const fn (*RxQueue, []*MBuf, u16) u16,

    /// Transmit up to nb_pkts packets. Never blocks.
    /// Caller retains ownership of un-sent packets.
    txBurstFn: *const fn (*TxQueue, []*MBuf, u16) u16,

    /// Stop device, disable queues, release hardware resources.
    stopFn: *const fn (*Device) void,

    /// Read port statistics.
    statsFn: *const fn (*const Device) stats_mod.PortStats,

    /// Read link status.
    linkStatusFn: *const fn (*const Device) LinkStatus,
};

/// NIC device state.
pub const Device = struct {
    driver: *const PollModeDriver,
    port_id: u8 = 0,
    mac_addr: MacAddr = .{},
    mtu: u16 = 1500,
    link: LinkStatus = .{},
    num_rx_queues: u8 = 0,
    num_tx_queues: u8 = 0,
    rx_queues: [config.max_queues_per_port]RxQueue =
        [_]RxQueue{.{}} ** config.max_queues_per_port,
    tx_queues: [config.max_queues_per_port]TxQueue =
        [_]TxQueue{.{}} ** config.max_queues_per_port,
    stats: stats_mod.PortStats = .{},
    started: bool = false,

    /// Receive a burst of packets on the given queue.
    pub inline fn rxBurst(self: *Device, queue_id: u8, bufs: []*MBuf, max_pkts: u16) u16 {
        return self.driver.rxBurstFn(&self.rx_queues[queue_id], bufs, max_pkts);
    }

    /// Transmit a burst of packets on the given queue.
    pub inline fn txBurst(self: *Device, queue_id: u8, bufs: []*MBuf, nb_pkts: u16) u16 {
        return self.driver.txBurstFn(&self.tx_queues[queue_id], bufs, nb_pkts);
    }

    pub fn getStats(self: *const Device) stats_mod.PortStats {
        return self.driver.statsFn(self);
    }

    pub fn getLinkStatus(self: *const Device) LinkStatus {
        return self.driver.linkStatusFn(self);
    }

    pub fn stop(self: *Device) void {
        self.driver.stopFn(self);
        self.started = false;
    }
};

pub const PmdError = error{
    DeviceNotFound,
    BarMappingFailed,
    ResetFailed,
    EepromReadFailed,
    LinkTimeout,
    QueueSetupFailed,
    OutOfMemory,
    VfioError,
    UnsupportedDevice,
    SocketCreationFailed,
    BindFailed,
    XdpProgramLoadFailed,
};
