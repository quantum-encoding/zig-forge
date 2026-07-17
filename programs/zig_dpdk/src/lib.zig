//! zig_dpdk — consumable library root.
//!
//! Re-exports the userspace packet-processing subsystems as namespaces so
//! other in-tree projects can `@import` the stack. This is a packaging root
//! only: it adds no behavior and changes no existing export. The `main.zig`
//! and `hw_test_main.zig` executables remain the runnable entry points.

pub const core = struct {
    pub const config = @import("core/config.zig");
    pub const lifecycle = @import("core/lifecycle.zig");
    pub const mbuf = @import("core/mbuf.zig");
    pub const mempool = @import("core/mempool.zig");
    pub const ring = @import("core/ring.zig");
    pub const stats = @import("core/stats.zig");
    pub const telemetry = @import("core/telemetry.zig");
    pub const watchdog = @import("core/watchdog.zig");
};

pub const mem = struct {
    pub const hugepage = @import("mem/hugepage.zig");
    pub const iommu = @import("mem/iommu.zig");
    pub const numa = @import("mem/numa.zig");
    pub const physical = @import("mem/physical.zig");
};

pub const net = struct {
    pub const arp = @import("net/arp.zig");
    pub const checksum = @import("net/checksum.zig");
    pub const ethernet = @import("net/ethernet.zig");
    pub const ipv4 = @import("net/ipv4.zig");
    pub const tcp = @import("net/tcp.zig");
    pub const udp = @import("net/udp.zig");
};

pub const drivers = struct {
    pub const af_xdp = @import("drivers/af_xdp.zig");
    pub const ixgbe = @import("drivers/ixgbe.zig");
    pub const pmd = @import("drivers/pmd.zig");
    pub const virtio = @import("drivers/virtio.zig");
    pub const zigix = @import("drivers/zigix.zig");
};

pub const pipeline = struct {
    pub const distributor = @import("pipeline/distributor.zig");
    pub const pipeline = @import("pipeline/pipeline.zig");
    pub const runner = @import("pipeline/runner.zig");
    pub const rx = @import("pipeline/rx.zig");
    pub const tx = @import("pipeline/tx.zig");
};

pub const platform = struct {
    pub const linux = @import("platform/linux.zig");
    pub const zigix = @import("platform/zigix.zig");
};
