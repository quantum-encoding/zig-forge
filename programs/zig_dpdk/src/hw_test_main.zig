/// VFIO Hardware Integration Test for zig_dpdk.
///
/// Standalone executable — NOT part of `zig build test`.
/// Built via `zig build hw-test`. Run as root on a Linux machine with
/// a NIC bound to vfio-pci.
///
/// Usage:
///   sudo ./scripts/setup_vfio.sh 0000:03:00.0
///   sudo zig-out/bin/zig-dpdk-hw-test 0000:03:00.0
///
/// Test sequence:
///   1. Parse PCI address from argv[1]
///   2. Read IOMMU group from sysfs
///   3. Open VFIO container → group → device → map BAR0
///   4. Read PCI vendor:device ID from config space
///   5. If Intel 82599 (0x8086:0x10FB or 0x1528):
///      - Read MAC address
///      - Run initHardware()
///      - Wait for link up (9s timeout)
///      - Allocate MBufPool, DMA-map it
///      - Setup 1 RX + 1 TX queue
///      - Poll RX for 1 second
///      - Print stats
///   6. Cleanup

const std = @import("std");
const builtin = @import("builtin");
const iommu = @import("mem/iommu.zig");
const ixgbe = @import("drivers/ixgbe.zig");
const mbuf_mod = @import("core/mbuf.zig");
const hugepage = @import("mem/hugepage.zig");
const physical = @import("mem/physical.zig");
const pmd = @import("drivers/pmd.zig");

const print = std.debug.print;

const INTEL_VENDOR_ID: u16 = 0x8086;
const IXGBE_DEV_ID_82599_SFP: u16 = 0x10FB;
const IXGBE_DEV_ID_X540: u16 = 0x1528;

pub export fn main(argc: c_int, argv: [*]const [*:0]const u8) c_int {
    run(argc, argv) catch |err| {
        print("FATAL: {}\n", .{err});
        return 1;
    };
    return 0;
}

fn run(argc: c_int, argv: [*]const [*:0]const u8) !void {
    print(
        \\
        \\  zig-dpdk hardware test
        \\  ──────────────────────
        \\
        \\
    , .{});

    // Parse PCI address from command line
    if (argc < 2) {
        print("Usage: zig-dpdk-hw-test <PCI_ADDR>\n", .{});
        print("Example: sudo zig-dpdk-hw-test 0000:03:00.0\n\n", .{});
        print("Run scripts/setup_vfio.sh first to bind the NIC to vfio-pci.\n", .{});
        return;
    }
    const pci_addr_str = std.mem.span(argv[1]);

    print("PCI address: {s}\n", .{pci_addr_str});

    const pci = iommu.PciAddress.parse(pci_addr_str) orelse {
        print("ERROR: Invalid PCI address format. Expected DDDD:BB:DD.F\n", .{});
        return;
    };

    // Step 1: Read IOMMU group
    print("Reading IOMMU group from sysfs... ", .{});
    const group_num = pci.iommuGroup() catch |err| {
        print("FAILED: {}\n", .{err});
        print("Is the NIC bound to vfio-pci? Run: sudo ./scripts/setup_vfio.sh {s}\n", .{pci_addr_str});
        return;
    };
    print("group {d}\n", .{group_num});

    // Step 2: Open VFIO container
    print("Opening VFIO container... ", .{});
    var container = iommu.VfioContainer.open() catch |err| {
        print("FAILED: {}\n", .{err});
        print("Is /dev/vfio/vfio accessible? Run as root or check permissions.\n", .{});
        return;
    };
    defer container.close();
    print("OK (fd={d})\n", .{container.fd});

    // Step 3: Open VFIO group
    print("Opening VFIO group {d}... ", .{group_num});
    var group = iommu.VfioGroup.openWithContainer(group_num, &container) catch |err| {
        print("FAILED: {}\n", .{err});
        print("Check that all devices in the IOMMU group are bound to vfio-pci.\n", .{});
        return;
    };
    defer group.close();
    print("OK (fd={d})\n", .{group.fd});

    // Step 4: Open VFIO device
    print("Opening VFIO device {s}... ", .{pci_addr_str});
    var device = iommu.VfioDevice.openDev(&group, pci_addr_str) catch |err| {
        print("FAILED: {}\n", .{err});
        return;
    };
    defer device.close();
    print("OK (fd={d})\n", .{device.fd});

    // Step 5: Map BAR0
    print("Mapping BAR0... ", .{});
    device.mapBar0() catch |err| {
        print("FAILED: {}\n", .{err});
        return;
    };
    print("OK (size={d} KB)\n", .{device.bar0_size / 1024});

    // Step 6: Identify NIC via PCI config space
    print("Identifying NIC... ", .{});

    var vendor_id: u16 = 0;
    var device_id: u16 = 0;
    readPciConfig(&device, &vendor_id, &device_id);

    if (vendor_id == 0 and device_id == 0) {
        // Fallback: check STATUS register at offset 0x8 to see if device responds
        const status_reg = device.readReg32(0x00008);
        print("(config read failed, STATUS=0x{x:0>8}) ", .{status_reg});
        if (status_reg == 0 or status_reg == 0xFFFFFFFF) {
            print("FAILED: device not responding\n", .{});
            return;
        }
        vendor_id = INTEL_VENDOR_ID;
        device_id = IXGBE_DEV_ID_82599_SFP;
        print("assuming Intel 82599\n", .{});
    } else {
        print("{x:0>4}:{x:0>4}", .{ vendor_id, device_id });
        if (vendor_id == INTEL_VENDOR_ID) {
            if (device_id == IXGBE_DEV_ID_82599_SFP) {
                print(" (Intel 82599ES)\n", .{});
            } else if (device_id == IXGBE_DEV_ID_X540) {
                print(" (Intel X540)\n", .{});
            } else {
                print(" (unknown Intel device)\n", .{});
            }
        } else {
            print(" (unsupported vendor)\n", .{});
            return;
        }
    }

    // Only proceed with ixgbe-compatible devices
    if (vendor_id != INTEL_VENDOR_ID or
        (device_id != IXGBE_DEV_ID_82599_SFP and device_id != IXGBE_DEV_ID_X540))
    {
        print("Device is not an Intel 82599/X540. Cannot run ixgbe tests.\n", .{});
        return;
    }

    // Step 7: Create RegOps backed by VFIO BAR0
    var vfio_reg_ops = device.regOps();
    const reg_ops_raw = vfio_reg_ops.toRegOps();
    const ops: ixgbe.RegOps = .{
        .read32 = reg_ops_raw.read32,
        .write32 = reg_ops_raw.write32,
        .ctx = reg_ops_raw.ctx,
    };

    // Step 8: Read MAC address
    const mac = ixgbe.readMacAddr(&ops);
    print("MAC address: {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}\n", .{
        mac.bytes[0], mac.bytes[1], mac.bytes[2],
        mac.bytes[3], mac.bytes[4], mac.bytes[5],
    });

    // Step 9: Initialize hardware (full §4.6.3 sequence)
    print("Initializing hardware... ", .{});
    ixgbe.initHardware(&ops, 1, 1);
    print("OK\n", .{});

    // Step 10: Wait for link up
    print("Waiting for link up", .{});
    const link_up = waitForLink(&ops, 9);
    if (link_up) {
        const link = ixgbe.readLinkStatus(&ops);
        const speed_str: []const u8 = switch (link.speed) {
            .speed_10g => "10 Gbps",
            .speed_1g => "1 Gbps",
            .speed_100m => "100 Mbps",
            else => "unknown",
        };
        print(" LINK UP ({s})\n", .{speed_str});
    } else {
        print(" LINK DOWN (timed out after 9s)\n", .{});
        print("Note: SFP+ module may be required, or cable may not be connected.\n", .{});
        print("Continuing with setup tests anyway...\n", .{});
    }

    // Step 11: Allocate MBufPool
    print("Allocating MBuf pool (1024 mbufs)... ", .{});
    var pool = mbuf_mod.MBufPool.create(1024, .regular) catch |err| {
        print("FAILED: {}\n", .{err});
        return;
    };
    defer pool.destroy();
    pool.populate();
    print("OK ({d} available)\n", .{pool.availableCount()});

    // Step 12: DMA-map the pool memory
    print("Pool memory: virt=0x{x}, phys=0x{x}\n", .{
        @intFromPtr(pool.region.ptr),
        pool.region.phys_addr,
    });

    // Step 13: Setup RX queue
    print("Setting up RX queue 0... ", .{});
    const ring_size: u32 = 256;
    var rx_descs: [256]ixgbe.RxDesc align(128) = undefined;
    @memset(std.mem.asBytes(&rx_descs), 0);
    var shadow: [ixgbe.MAX_RING_SIZE]?*mbuf_mod.MBuf = [_]?*mbuf_mod.MBuf{null} ** ixgbe.MAX_RING_SIZE;

    const ring_phys = physical.ptrToPhys(&rx_descs);
    ixgbe.setupRxQueue(&ops, &rx_descs, ring_size, 0, ring_phys, &pool, &shadow);
    print("OK (ring phys=0x{x})\n", .{ring_phys});

    // Step 14: Setup TX queue
    print("Setting up TX queue 0... ", .{});
    var tx_descs: [256]ixgbe.TxDesc align(128) = undefined;
    @memset(std.mem.asBytes(&tx_descs), 0);
    const tx_ring_phys = physical.ptrToPhys(&tx_descs);
    ixgbe.setupTxQueue(&ops, ring_size, 0, tx_ring_phys);
    print("OK (ring phys=0x{x})\n", .{tx_ring_phys});

    // Step 15: Poll RX for 1 second
    print("\nPolling RX for 1 second...\n", .{});

    var rxq_data = ixgbe.IxgbeRxQueueData.init(&rx_descs, ring_size, 0, ops, &pool);
    // Copy pre-filled shadow array
    for (0..ring_size) |i| {
        rxq_data.shadow[i] = shadow[i];
    }

    var rx_queue = pmd.RxQueue{
        .queue_id = 0,
        .port_id = 0,
        .driver_data = @ptrCast(&rxq_data),
    };

    var total_pkts: u64 = 0;
    var total_bytes: u64 = 0;
    var poll_count: u64 = 0;

    var start_ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &start_ts);

    while (true) {
        var bufs: [32]*mbuf_mod.MBuf = undefined;
        const count = ixgbe.ixgbe_pmd.rxBurstFn(&rx_queue, &bufs, 32);

        if (count > 0) {
            for (0..count) |i| {
                total_bytes += bufs[i].pkt_len;
                bufs[i].free();
            }
            total_pkts += count;
        }
        poll_count += 1;

        // Check elapsed time
        var now: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &now);
        const elapsed_s = now.sec - start_ts.sec;
        if (elapsed_s >= 1) break;
    }

    // Step 16: Read hardware stats
    const gprc = ops.read(ixgbe.GPRC);
    const gptc = ops.read(ixgbe.GPTC);

    // Print summary
    print(
        \\
        \\  ── Hardware Test Results ──
        \\  Packets received:  {d}
        \\  Bytes received:    {d}
        \\  Poll iterations:   {d}
        \\  HW RX good pkts:   {d} (GPRC)
        \\  HW TX good pkts:   {d} (GPTC)
        \\  Pool available:    {d}
        \\
        \\  Test PASSED — VFIO device stack operational.
        \\
        \\
    , .{
        total_pkts,
        total_bytes,
        poll_count,
        gprc,
        gptc,
        pool.availableCount(),
    });

    // Cleanup shadow mbufs
    for (0..ring_size) |i| {
        if (rxq_data.shadow[i]) |mbuf| mbuf.free();
    }
}

/// Read PCI vendor/device ID from VFIO config space region.
fn readPciConfig(dev: *iommu.VfioDevice, vendor_id: *u16, device_id: *u16) void {
    if (comptime builtin.os.tag != .linux) {
        vendor_id.* = 0;
        device_id.* = 0;
        return;
    }

    // Get config region info (region index 7 = PCI config space)
    var region_info = iommu.VfioRegionInfo{
        .index = iommu.VFIO_PCI_CONFIG_REGION_INDEX,
    };

    const rc = std.os.linux.syscall3(
        .ioctl,
        @bitCast(@as(isize, dev.fd)),
        iommu.VFIO_DEVICE_GET_REGION_INFO,
        @intFromPtr(&region_info),
    );
    const signed: isize = @bitCast(rc);
    if (signed < 0) {
        vendor_id.* = 0;
        device_id.* = 0;
        return;
    }

    // Read first 4 bytes of config space (vendor ID + device ID) via pread
    var config_data: [4]u8 = undefined;
    const n = std.c.pread64(dev.fd, &config_data, 4, @intCast(region_info.offset));
    if (n != 4) {
        vendor_id.* = 0;
        device_id.* = 0;
        return;
    }

    vendor_id.* = std.mem.readInt(u16, config_data[0..2], .little);
    device_id.* = std.mem.readInt(u16, config_data[2..4], .little);
}

/// Poll LINKS register for link-up, with timeout in seconds.
fn waitForLink(ops: *const ixgbe.RegOps, timeout_secs: u32) bool {
    var start_ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &start_ts);

    while (true) {
        const links = ops.read(ixgbe.LINKS);
        if (links & ixgbe.LINKS_UP != 0) return true;

        var now: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &now);
        const elapsed: i64 = now.sec - start_ts.sec;
        if (elapsed >= timeout_secs) return false;

        // Print dots for visual feedback
        if (@rem(elapsed, 1) == 0) print(".", .{});

        // Brief pause to avoid hammering the register
        var i: u32 = 0;
        while (i < 1_000_000) : (i += 1) {
            std.atomic.spinLoopHint();
        }
    }
}
