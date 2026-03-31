const builtin = @import("builtin");

/// Detect the NUMA node of the current CPU.
/// Returns 0 on non-NUMA systems (macOS, single-socket).
pub fn currentNode() i32 {
    if (comptime builtin.os.tag == .linux) {
        return detectLinuxNode();
    }
    return 0;
}

/// Get the NUMA node for a PCI device by its sysfs address.
/// Returns 0 if unknown or on non-Linux.
pub fn pciDeviceNode(pci_addr: []const u8) i32 {
    _ = pci_addr;
    // Phase 2: read /sys/bus/pci/devices/{addr}/numa_node
    return 0;
}

fn detectLinuxNode() i32 {
    if (comptime builtin.os.tag != .linux) return 0;
    // Phase 2: use getcpu(2) or read /sys/devices/system/cpu/cpu{N}/topology/
    return 0;
}
