/// Linux platform support: VFIO, CPU affinity, hugepage configuration.
/// These functions are only compiled and callable on Linux.

const std = @import("std");
const builtin = @import("builtin");

/// Pin the calling thread to a specific CPU core.
pub fn pinToCore(core_id: u32) !void {
    if (comptime builtin.os.tag != .linux) return error.NotSupported;

    const linux = std.os.linux;
    var set: linux.cpu_set_t = std.mem.zeroes(linux.cpu_set_t);
    set.__bits[core_id / 64] = @as(usize, 1) << @intCast(core_id % 64);

    const rc = linux.sched_setaffinity(0, @sizeOf(linux.cpu_set_t), &set);
    if (rc != 0) return error.AffinityFailed;
}

/// Check if VFIO is available (/dev/vfio/vfio exists).
pub fn vfioAvailable() bool {
    if (comptime builtin.os.tag != .linux) return false;
    // Phase 2: stat /dev/vfio/vfio
    return false;
}

/// Check number of available 2MB hugepages.
pub fn hugepagesAvailable2M() u32 {
    if (comptime builtin.os.tag != .linux) return 0;
    // Phase 2: read /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
    return 0;
}

pub const PlatformError = error{
    NotSupported,
    AffinityFailed,
    VfioNotAvailable,
};
