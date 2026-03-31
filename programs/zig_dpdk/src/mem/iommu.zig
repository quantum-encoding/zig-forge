/// IOMMU / VFIO DMA mapping for zig_dpdk.
///
/// On Linux with native PMD drivers, the NIC is unbound from the kernel
/// driver and bound to VFIO (Virtual Function I/O). VFIO provides:
///   - Safe userspace access to PCI device BARs (MMIO registers)
///   - DMA mapping: tell the IOMMU which physical pages the NIC can access
///   - Interrupt forwarding (not used in poll mode)
///
/// VFIO hierarchy:
///   /dev/vfio/vfio          — container fd (one per process)
///   /dev/vfio/<group_num>   — group fd (one per IOMMU group)
///   device fd               — obtained from group fd via ioctl
///
/// DMA mapping:
///   The NIC sees IOVA (I/O Virtual Address) space, not host physical.
///   We set IOVA = host physical for simplicity (1:1 mapping).
///   mmap hugepages → read /proc/self/pagemap → map IOVA = phys via VFIO.

const std = @import("std");
const builtin = @import("builtin");
const config = @import("../core/config.zig");

// ── VFIO Ioctl Numbers ──────────────────────────────────────────────────
//
// VFIO ioctls use the ';' (0x3B) type code.
// Encoding: _IO(';', N) = (0x3B << 8) | N

pub const VFIO_GET_API_VERSION = 0x3B64;
pub const VFIO_CHECK_EXTENSION = 0x3B65;
pub const VFIO_SET_IOMMU = 0x3B66;
pub const VFIO_GROUP_GET_STATUS = 0x3B67;
pub const VFIO_GROUP_SET_CONTAINER = 0x3B68;
pub const VFIO_GROUP_GET_DEVICE_FD = 0x3B6A;
pub const VFIO_DEVICE_GET_INFO = 0x3B6B;
pub const VFIO_DEVICE_GET_REGION_INFO = 0x3B6C;
pub const VFIO_DEVICE_RESET = 0x3B6F;
pub const VFIO_IOMMU_MAP_DMA = 0x3B71;
pub const VFIO_IOMMU_UNMAP_DMA = 0x3B72;

// VFIO API version
pub const VFIO_API_VERSION = 0;

// VFIO extensions
pub const VFIO_TYPE1_IOMMU = 1;
pub const VFIO_TYPE1v2_IOMMU = 3;
pub const VFIO_NOIOMMU_IOMMU = 8;

// VFIO group flags
pub const VFIO_GROUP_FLAGS_VIABLE = 1;
pub const VFIO_GROUP_FLAGS_CONTAINER_SET = 2;

// VFIO region flags
pub const VFIO_REGION_INFO_FLAG_READ = 1;
pub const VFIO_REGION_INFO_FLAG_WRITE = 2;
pub const VFIO_REGION_INFO_FLAG_MMAP = 4;

// VFIO DMA map flags
pub const VFIO_DMA_MAP_FLAG_READ = 1;
pub const VFIO_DMA_MAP_FLAG_WRITE = 2;

// PCI BAR indices
pub const VFIO_PCI_BAR0_REGION_INDEX = 0;
pub const VFIO_PCI_CONFIG_REGION_INDEX = 7;

// ── VFIO Structs (C ABI, match kernel headers) ──────────────────────────

pub const VfioGroupStatus = extern struct {
    argsz: u32 = @sizeOf(VfioGroupStatus),
    flags: u32 = 0,
};

pub const VfioDeviceInfo = extern struct {
    argsz: u32 = @sizeOf(VfioDeviceInfo),
    flags: u32 = 0,
    num_regions: u32 = 0,
    num_irqs: u32 = 0,
};

pub const VfioRegionInfo = extern struct {
    argsz: u32 = @sizeOf(VfioRegionInfo),
    flags: u32 = 0,
    index: u32 = 0,
    cap_offset: u32 = 0,
    size: u64 = 0,
    offset: u64 = 0,
};

pub const VfioDmaMap = extern struct {
    argsz: u32 = @sizeOf(VfioDmaMap),
    flags: u32 = 0,
    vaddr: u64 = 0,
    iova: u64 = 0,
    size: u64 = 0,
};

pub const VfioDmaUnmap = extern struct {
    argsz: u32 = @sizeOf(VfioDmaUnmap),
    flags: u32 = 0,
    iova: u64 = 0,
    size: u64 = 0,
};

// ── Linux Syscall Helpers (behind comptime check) ───────────────────────

/// Open a file path. Uses std.posix.openat (same pattern as physical.zig).
fn linuxOpen(path: [*:0]const u8, flags: u32) VfioError!i32 {
    if (comptime builtin.os.tag != .linux) return error.NotSupported;
    const fd = std.posix.openat(std.posix.AT.FDCWD, std.mem.span(path), @bitCast(flags), 0) catch
        return error.ContainerOpenFailed;
    return fd;
}

/// Close a file descriptor.
fn linuxClose(fd: i32) void {
    if (comptime builtin.os.tag != .linux) return;
    _ = std.c.close(fd);
}

/// Perform an ioctl with a pointer argument. Returns 0 on success or the error code.
fn linuxIoctl(fd: i32, request: u32, arg: usize) VfioError!usize {
    if (comptime builtin.os.tag != .linux) return error.NotSupported;
    const rc = std.os.linux.syscall3(.ioctl, @bitCast(@as(isize, fd)), request, arg);
    const signed: isize = @bitCast(rc);
    if (signed < 0) return error.IoctlFailed;
    return rc;
}

/// Perform an ioctl with a scalar argument. Returns the ioctl return value.
fn linuxIoctlScalar(fd: i32, request: u32, arg: usize) VfioError!usize {
    if (comptime builtin.os.tag != .linux) return error.NotSupported;
    const rc = std.os.linux.syscall3(.ioctl, @bitCast(@as(isize, fd)), request, arg);
    const signed: isize = @bitCast(rc);
    if (signed < 0) return error.IoctlFailed;
    return rc;
}

/// mmap a region. Returns the mapped pointer.
fn linuxMmap(size: usize, prot: u32, flags: u32, fd: i32, offset: u64) VfioError![*]volatile u8 {
    if (comptime builtin.os.tag != .linux) return error.NotSupported;
    const rc = std.os.linux.mmap(null, size, @bitCast(prot), @bitCast(flags), fd, @bitCast(offset));
    const signed: isize = @bitCast(rc);
    if (signed < 0 or rc == 0) return error.MmapFailed;
    return @ptrFromInt(rc);
}

/// munmap a region.
fn linuxMunmap(ptr: [*]volatile u8, size: usize) void {
    if (comptime builtin.os.tag != .linux) return;
    _ = std.os.linux.munmap(@ptrCast(@alignCast(@volatileCast(ptr))), size);
}

/// readlinkat via raw syscall. Returns number of bytes read, or error.
fn linuxReadlink(path: [*:0]const u8, buf: []u8) VfioError!usize {
    if (comptime builtin.os.tag != .linux) return error.NotSupported;
    const rc = std.os.linux.syscall4(
        .readlinkat,
        @bitCast(@as(isize, std.posix.AT.FDCWD)),
        @intFromPtr(path),
        @intFromPtr(buf.ptr),
        buf.len,
    );
    const signed: isize = @bitCast(rc);
    if (signed < 0) return error.IommuGroupNotFound;
    return rc;
}

// ── VfioContainer ───────────────────────────────────────────────────────

/// VFIO container — holds IOMMU domain for DMA mappings.
pub const VfioContainer = struct {
    fd: i32 = -1,
    dma_mappings: [max_dma_mappings]DmaMapping = [_]DmaMapping{.{}} ** max_dma_mappings,
    mapping_count: u32 = 0,

    /// Open the VFIO container (/dev/vfio/vfio).
    /// Verifies API version and TYPE1v2 IOMMU extension support.
    pub fn open() VfioError!VfioContainer {
        if (comptime builtin.os.tag != .linux) return error.NotSupported;

        const fd = try linuxOpen("/dev/vfio/vfio", 2); // O_RDWR = 2
        errdefer linuxClose(fd);

        // Verify API version == VFIO_API_VERSION (0)
        const version = linuxIoctlScalar(fd, VFIO_GET_API_VERSION, 0) catch
            return error.ApiVersionMismatch;
        if (version != VFIO_API_VERSION) return error.ApiVersionMismatch;

        // Check for TYPE1v2 or NOIOMMU extension
        const ext = linuxIoctlScalar(fd, VFIO_CHECK_EXTENSION, VFIO_TYPE1v2_IOMMU) catch blk: {
            break :blk linuxIoctlScalar(fd, VFIO_CHECK_EXTENSION, VFIO_NOIOMMU_IOMMU) catch
                return error.IommuNotSupported;
        };
        if (ext == 0) return error.IommuNotSupported;

        return VfioContainer{ .fd = fd };
    }

    /// Map a hugepage region for DMA access by the NIC.
    /// IOVA is set equal to the host physical address (1:1 mapping).
    pub fn mapDma(self: *VfioContainer, vaddr: usize, phys_addr: u64, size: usize) VfioError!void {
        if (self.mapping_count >= max_dma_mappings) return error.TooManyMappings;

        // Perform kernel VFIO DMA mapping if we have a real fd
        if (comptime builtin.os.tag == .linux) {
            if (self.fd >= 0) {
                var map = VfioDmaMap{
                    .flags = VFIO_DMA_MAP_FLAG_READ | VFIO_DMA_MAP_FLAG_WRITE,
                    .vaddr = vaddr,
                    .iova = phys_addr,
                    .size = size,
                };
                _ = linuxIoctl(self.fd, VFIO_IOMMU_MAP_DMA, @intFromPtr(&map)) catch
                    return error.DmaMappingFailed;
            }
        }

        self.dma_mappings[self.mapping_count] = .{
            .vaddr = vaddr,
            .iova = phys_addr,
            .size = size,
            .valid = true,
        };
        self.mapping_count += 1;
    }

    /// Unmap a DMA region.
    pub fn unmapDma(self: *VfioContainer, iova: u64, size: usize) void {
        // Perform kernel VFIO DMA unmap
        if (comptime builtin.os.tag == .linux) {
            if (self.fd >= 0) {
                var unmap = VfioDmaUnmap{
                    .iova = iova,
                    .size = size,
                };
                _ = linuxIoctl(self.fd, VFIO_IOMMU_UNMAP_DMA, @intFromPtr(&unmap)) catch {};
            }
        }

        for (&self.dma_mappings) |*m| {
            if (m.valid and m.iova == iova and m.size == size) {
                m.valid = false;
                break;
            }
        }
    }

    /// Unmap all DMA regions and close the container.
    pub fn close(self: *VfioContainer) void {
        for (&self.dma_mappings) |*m| {
            m.valid = false;
        }
        self.mapping_count = 0;
        if (comptime builtin.os.tag == .linux) {
            if (self.fd >= 0) linuxClose(self.fd);
        }
        self.fd = -1;
    }

    /// Count of active DMA mappings.
    pub fn activeMappings(self: *const VfioContainer) u32 {
        var count: u32 = 0;
        for (self.dma_mappings[0..self.mapping_count]) |m| {
            if (m.valid) count += 1;
        }
        return count;
    }
};

/// A single DMA mapping entry.
pub const DmaMapping = struct {
    vaddr: usize = 0,
    iova: u64 = 0,
    size: usize = 0,
    valid: bool = false,
};

/// Maximum DMA mappings per container (one per hugepage).
pub const max_dma_mappings: u32 = 512;

// ── VfioGroup ───────────────────────────────────────────────────────────

/// VFIO device group — one per IOMMU group.
pub const VfioGroup = struct {
    fd: i32 = -1,
    group_num: u32 = 0,
    container: ?*VfioContainer = null,

    /// Open a VFIO group and attach it to a container.
    /// Sets the IOMMU type on the container (TYPE1v2 or NOIOMMU).
    pub fn openWithContainer(group_num: u32, container: *VfioContainer) VfioError!VfioGroup {
        if (comptime builtin.os.tag != .linux) return error.NotSupported;

        // Format "/dev/vfio/<N>" or "/dev/vfio/noiommu-<N>"
        var path_buf: [64]u8 = undefined;
        const path = formatGroupPath(&path_buf, group_num) orelse return error.GroupOpenFailed;

        const fd = linuxOpen(path, 2) catch {
            // Try noiommu path
            const noiommu_path = formatNoIommuGroupPath(&path_buf, group_num) orelse return error.GroupOpenFailed;
            const fd2 = try linuxOpen(noiommu_path, 2);
            return openGroupWithFd(fd2, group_num, container);
        };
        return openGroupWithFd(fd, group_num, container);
    }

    fn openGroupWithFd(fd: i32, group_num: u32, container: *VfioContainer) VfioError!VfioGroup {
        if (comptime builtin.os.tag != .linux) return error.NotSupported;
        errdefer linuxClose(fd);

        // Check group is viable
        var status = VfioGroupStatus{};
        _ = linuxIoctl(fd, VFIO_GROUP_GET_STATUS, @intFromPtr(&status)) catch
            return error.GroupNotViable;
        if (status.flags & VFIO_GROUP_FLAGS_VIABLE == 0) return error.GroupNotViable;

        // Attach group to container
        var container_fd_val: i32 = container.fd;
        _ = linuxIoctl(fd, VFIO_GROUP_SET_CONTAINER, @intFromPtr(&container_fd_val)) catch
            return error.GroupOpenFailed;

        // Set IOMMU type on container (try TYPE1v2 first, then NOIOMMU)
        _ = linuxIoctlScalar(container.fd, VFIO_SET_IOMMU, VFIO_TYPE1v2_IOMMU) catch {
            _ = linuxIoctlScalar(container.fd, VFIO_SET_IOMMU, VFIO_NOIOMMU_IOMMU) catch
                return error.IommuNotSupported;
        };

        return VfioGroup{
            .fd = fd,
            .group_num = group_num,
            .container = container,
        };
    }

    /// Legacy open (group only, no container). Kept for API compat.
    pub fn open(group_num: u32) VfioError!VfioGroup {
        _ = group_num;
        if (comptime builtin.os.tag != .linux) return error.NotSupported;
        return error.NotSupported;
    }

    pub fn close(self: *VfioGroup) void {
        if (comptime builtin.os.tag == .linux) {
            if (self.fd >= 0) linuxClose(self.fd);
        }
        self.fd = -1;
        self.container = null;
    }
};

// ── VfioDevice ──────────────────────────────────────────────────────────

/// VFIO device handle — provides BAR access and interrupt control.
pub const VfioDevice = struct {
    fd: i32 = -1,
    group: ?*VfioGroup = null,
    /// BAR0 base address (mmap'd MMIO region)
    bar0_base: ?[*]volatile u8 = null,
    bar0_size: usize = 0,

    /// Open a device within a VFIO group by PCI address.
    pub fn openDev(group: *VfioGroup, pci_addr: []const u8) VfioError!VfioDevice {
        if (comptime builtin.os.tag != .linux) return error.NotSupported;

        // The PCI address string must be null-terminated for the ioctl
        var addr_buf: [16]u8 = [_]u8{0} ** 16;
        if (pci_addr.len > 15) return error.DeviceOpenFailed;
        @memcpy(addr_buf[0..pci_addr.len], pci_addr);
        addr_buf[pci_addr.len] = 0;

        // VFIO_GROUP_GET_DEVICE_FD takes a pointer to the null-terminated PCI address string
        const rc = linuxIoctlScalar(group.fd, VFIO_GROUP_GET_DEVICE_FD, @intFromPtr(&addr_buf)) catch
            return error.DeviceOpenFailed;
        const fd: i32 = @intCast(rc);
        if (fd < 0) return error.DeviceOpenFailed;

        return VfioDevice{
            .fd = fd,
            .group = group,
        };
    }

    /// Legacy open (kept for API compat).
    pub fn open(group: *VfioGroup, pci_addr: []const u8) VfioError!VfioDevice {
        return openDev(group, pci_addr);
    }

    /// Map BAR0 into userspace. Returns pointer to MMIO region.
    pub fn mapBar0(self: *VfioDevice) VfioError!void {
        if (comptime builtin.os.tag != .linux) return error.NotSupported;
        if (self.fd < 0) return error.BarMappingFailed;

        // Get BAR0 region info
        var region_info = VfioRegionInfo{
            .index = VFIO_PCI_BAR0_REGION_INDEX,
        };
        _ = linuxIoctl(self.fd, VFIO_DEVICE_GET_REGION_INFO, @intFromPtr(&region_info)) catch
            return error.BarMappingFailed;

        if (region_info.size == 0) return error.BarMappingFailed;
        if (region_info.flags & VFIO_REGION_INFO_FLAG_MMAP == 0) return error.BarMappingFailed;

        // mmap BAR0: MAP_SHARED, PROT_READ|PROT_WRITE
        const PROT_READ: u32 = 1;
        const PROT_WRITE: u32 = 2;
        const MAP_SHARED: u32 = 1;

        self.bar0_base = try linuxMmap(
            region_info.size,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            self.fd,
            region_info.offset,
        );
        self.bar0_size = region_info.size;
    }

    /// Read a 32-bit NIC register.
    pub inline fn readReg32(self: *const VfioDevice, offset: u32) u32 {
        if (self.bar0_base) |base| {
            const ptr: *volatile u32 = @ptrCast(@alignCast(base + offset));
            return ptr.*;
        }
        return 0;
    }

    /// Write a 32-bit NIC register.
    pub inline fn writeReg32(self: *const VfioDevice, offset: u32, value: u32) void {
        if (self.bar0_base) |base| {
            const ptr: *volatile u32 = @ptrCast(@alignCast(base + offset));
            ptr.* = value;
        }
    }

    /// Create a RegOps interface backed by this VFIO device's BAR0 mapping.
    /// The returned RegOps holds a pointer to this VfioDevice — caller must
    /// ensure the VfioDevice outlives the RegOps.
    pub fn regOps(self: *VfioDevice) VfioRegOps {
        return VfioRegOps{ .dev = self };
    }

    /// Reset the device via VFIO.
    pub fn reset(self: *VfioDevice) VfioError!void {
        if (comptime builtin.os.tag != .linux) return error.NotSupported;
        if (self.fd < 0) return error.DeviceOpenFailed;
        _ = linuxIoctlScalar(self.fd, VFIO_DEVICE_RESET, 0) catch return error.IoctlFailed;
    }

    pub fn close(self: *VfioDevice) void {
        if (comptime builtin.os.tag == .linux) {
            if (self.bar0_base) |base| {
                if (self.bar0_size > 0) linuxMunmap(base, self.bar0_size);
            }
            if (self.fd >= 0) linuxClose(self.fd);
        }
        self.bar0_base = null;
        self.bar0_size = 0;
        self.fd = -1;
    }
};

/// RegOps adapter for VfioDevice — bridges VfioDevice.readReg32/writeReg32
/// to the ixgbe RegOps function-pointer interface.
pub const VfioRegOps = struct {
    dev: *VfioDevice,

    pub fn read32(ctx: *anyopaque, offset: u32) u32 {
        const self: *VfioRegOps = @ptrCast(@alignCast(ctx));
        return self.dev.readReg32(offset);
    }

    pub fn write32(ctx: *anyopaque, offset: u32, value: u32) void {
        const self: *VfioRegOps = @ptrCast(@alignCast(ctx));
        self.dev.writeReg32(offset, value);
    }

    /// Convert to ixgbe.RegOps (imported at callsite to avoid circular deps).
    pub fn toRegOps(self: *VfioRegOps) struct { read32: *const fn (*anyopaque, u32) u32, write32: *const fn (*anyopaque, u32, u32) void, ctx: *anyopaque } {
        return .{
            .read32 = VfioRegOps.read32,
            .write32 = VfioRegOps.write32,
            .ctx = @ptrCast(self),
        };
    }
};

// ── PciAddress ──────────────────────────────────────────────────────────

/// PCI address parsed from "DDDD:BB:DD.F" string.
pub const PciAddress = struct {
    domain: u16 = 0,
    bus: u8 = 0,
    device: u5 = 0,
    function: u3 = 0,

    /// Parse "0000:03:00.0" format.
    pub fn parse(s: []const u8) ?PciAddress {
        if (s.len < 12) return null;
        // DDDD:BB:DD.F
        const domain = parseHex16(s[0..4]) orelse return null;
        if (s[4] != ':') return null;
        const bus = parseHex8(s[5..7]) orelse return null;
        if (s[7] != ':') return null;
        const dev = parseHex8(s[8..10]) orelse return null;
        if (dev > 31) return null;
        if (s[10] != '.') return null;
        const func_val = hexDigit(s[11]) orelse return null;
        if (func_val > 7) return null;
        return PciAddress{
            .domain = domain,
            .bus = bus,
            .device = @intCast(dev),
            .function = @intCast(func_val),
        };
    }

    /// Format as "DDDD:BB:DD.F" null-terminated string.
    /// Returns a pointer to the null-terminated string within the buffer.
    pub fn sysfsPath(self: *const PciAddress, buf: []u8) ?[*:0]const u8 {
        if (buf.len < 13) return null;
        const hex_chars = "0123456789abcdef";
        // DDDD
        buf[0] = hex_chars[(self.domain >> 12) & 0xF];
        buf[1] = hex_chars[(self.domain >> 8) & 0xF];
        buf[2] = hex_chars[(self.domain >> 4) & 0xF];
        buf[3] = hex_chars[self.domain & 0xF];
        buf[4] = ':';
        // BB
        buf[5] = hex_chars[(self.bus >> 4) & 0xF];
        buf[6] = hex_chars[self.bus & 0xF];
        buf[7] = ':';
        // DD
        const dev_u8: u8 = @intCast(self.device);
        buf[8] = hex_chars[(dev_u8 >> 4) & 0xF];
        buf[9] = hex_chars[dev_u8 & 0xF];
        buf[10] = '.';
        // F
        const func_u8: u8 = @intCast(self.function);
        buf[11] = hex_chars[func_u8 & 0xF];
        buf[12] = 0;
        return @ptrCast(buf.ptr);
    }

    /// Get the IOMMU group number from sysfs.
    /// Reads /sys/bus/pci/devices/<addr>/iommu_group symlink.
    pub fn iommuGroup(self: *const PciAddress) VfioError!u32 {
        if (comptime builtin.os.tag != .linux) return error.NotSupported;

        // Format sysfs path
        var addr_buf: [16]u8 = undefined;
        const addr_str = self.sysfsPath(&addr_buf) orelse return error.IommuGroupNotFound;

        // Build "/sys/bus/pci/devices/DDDD:BB:DD.F/iommu_group"
        var path_buf: [128]u8 = undefined;
        const prefix = "/sys/bus/pci/devices/";
        const suffix = "/iommu_group";
        const addr_len: usize = 12;
        @memcpy(path_buf[0..prefix.len], prefix);
        @memcpy(path_buf[prefix.len..][0..addr_len], std.mem.span(addr_str));
        @memcpy(path_buf[prefix.len + addr_len ..][0..suffix.len], suffix);
        path_buf[prefix.len + addr_len + suffix.len] = 0;

        // readlink returns the target path like "../../../../kernel/iommu_groups/42"
        var link_buf: [256]u8 = undefined;
        const link_len = try linuxReadlink(@ptrCast(path_buf[0 .. prefix.len + addr_len + suffix.len + 1].ptr), &link_buf);
        if (link_len == 0) return error.IommuGroupNotFound;

        // Parse the group number from the last path component
        const link = link_buf[0..link_len];
        const last_slash = std.mem.lastIndexOfScalar(u8, link, '/') orelse return error.IommuGroupNotFound;
        if (last_slash + 1 >= link_len) return error.IommuGroupNotFound;

        const group_str = link[last_slash + 1 .. link_len];
        var group_num: u32 = 0;
        for (group_str) |c| {
            if (c < '0' or c > '9') return error.IommuGroupNotFound;
            group_num = group_num * 10 + (c - '0');
        }
        return group_num;
    }
};

// ── Convenience Wrapper ─────────────────────────────────────────────────

/// Result of opening a full VFIO device stack.
pub const VfioDeviceStack = struct {
    container: VfioContainer,
    group: VfioGroup,
    device: VfioDevice,
};

/// Open a VFIO device by PCI address string ("0000:03:00.0").
/// Opens container → group → device → maps BAR0 in one call.
pub fn openVfioDevice(pci_addr_str: []const u8) VfioError!VfioDeviceStack {
    if (comptime builtin.os.tag != .linux) return error.NotSupported;

    const pci = PciAddress.parse(pci_addr_str) orelse return error.DeviceOpenFailed;

    // Get IOMMU group
    const group_num = try pci.iommuGroup();

    // Open container
    var container = try VfioContainer.open();
    errdefer container.close();

    // Open group and attach to container
    var group = try VfioGroup.openWithContainer(group_num, &container);
    errdefer group.close();

    // Open device
    var device = try VfioDevice.openDev(&group, pci_addr_str);
    errdefer device.close();

    // Map BAR0
    try device.mapBar0();

    return VfioDeviceStack{
        .container = container,
        .group = group,
        .device = device,
    };
}

// ── Path Formatting Helpers ─────────────────────────────────────────────

/// Format "/dev/vfio/<N>" into buffer. Returns null-terminated pointer or null.
fn formatGroupPath(buf: []u8, group_num: u32) ?[*:0]const u8 {
    const prefix = "/dev/vfio/";
    if (buf.len < prefix.len + 11) return null; // prefix + up to 10 digits + null
    @memcpy(buf[0..prefix.len], prefix);
    const num_len = formatU32(buf[prefix.len..], group_num);
    buf[prefix.len + num_len] = 0;
    return @ptrCast(buf[0 .. prefix.len + num_len + 1].ptr);
}

/// Format "/dev/vfio/noiommu-<N>" into buffer.
fn formatNoIommuGroupPath(buf: []u8, group_num: u32) ?[*:0]const u8 {
    const prefix = "/dev/vfio/noiommu-";
    if (buf.len < prefix.len + 11) return null;
    @memcpy(buf[0..prefix.len], prefix);
    const num_len = formatU32(buf[prefix.len..], group_num);
    buf[prefix.len + num_len] = 0;
    return @ptrCast(buf[0 .. prefix.len + num_len + 1].ptr);
}

/// Format a u32 as decimal into buffer. Returns number of characters written.
fn formatU32(buf: []u8, val: u32) usize {
    if (val == 0) {
        buf[0] = '0';
        return 1;
    }
    var v = val;
    var digits: [10]u8 = undefined;
    var len: usize = 0;
    while (v > 0) {
        digits[len] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
        len += 1;
    }
    // Reverse
    for (0..len) |i| {
        buf[i] = digits[len - 1 - i];
    }
    return len;
}

// ── Hex Parsing Helpers ─────────────────────────────────────────────────

fn hexDigit(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn parseHex8(s: []const u8) ?u8 {
    if (s.len != 2) return null;
    const hi = hexDigit(s[0]) orelse return null;
    const lo = hexDigit(s[1]) orelse return null;
    return @as(u8, hi) * 16 + lo;
}

fn parseHex16(s: []const u8) ?u16 {
    if (s.len != 4) return null;
    const b0 = parseHex8(s[0..2]) orelse return null;
    const b1 = parseHex8(s[2..4]) orelse return null;
    return @as(u16, b0) * 256 + b1;
}

// ── Errors ──────────────────────────────────────────────────────────────

pub const VfioError = error{
    NotSupported,
    ContainerOpenFailed,
    GroupOpenFailed,
    DeviceOpenFailed,
    BarMappingFailed,
    DmaMappingFailed,
    TooManyMappings,
    IommuGroupNotFound,
    IoctlFailed,
    ApiVersionMismatch,
    IommuNotSupported,
    GroupNotViable,
    MmapFailed,
};

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "iommu: pci address parsing" {
    const addr = PciAddress.parse("0000:03:00.0").?;
    try testing.expectEqual(@as(u16, 0), addr.domain);
    try testing.expectEqual(@as(u8, 3), addr.bus);
    try testing.expectEqual(@as(u5, 0), addr.device);
    try testing.expectEqual(@as(u3, 0), addr.function);

    const addr2 = PciAddress.parse("0000:82:1f.3").?;
    try testing.expectEqual(@as(u8, 0x82), addr2.bus);
    try testing.expectEqual(@as(u5, 31), addr2.device);
    try testing.expectEqual(@as(u3, 3), addr2.function);
}

test "iommu: pci address invalid" {
    try testing.expect(PciAddress.parse("") == null);
    try testing.expect(PciAddress.parse("too short") == null);
    try testing.expect(PciAddress.parse("0000:03:00:0") == null); // wrong separator
}

test "iommu: vfio container dma mapping" {
    var container = VfioContainer{};

    try container.mapDma(0x7F000000, 0x100000, 0x200000);
    try testing.expectEqual(@as(u32, 1), container.mapping_count);
    try testing.expectEqual(@as(u32, 1), container.activeMappings());

    try container.mapDma(0x7F200000, 0x300000, 0x200000);
    try testing.expectEqual(@as(u32, 2), container.activeMappings());

    container.unmapDma(0x100000, 0x200000);
    try testing.expectEqual(@as(u32, 1), container.activeMappings());

    container.close();
    try testing.expectEqual(@as(u32, 0), container.activeMappings());
}

test "iommu: vfio device register access" {
    const dev = VfioDevice{};
    // With null bar0_base, reads return 0 and writes are no-ops
    try testing.expectEqual(@as(u32, 0), dev.readReg32(0));
    dev.writeReg32(0, 0xDEADBEEF); // should not crash
}

test "iommu: hex parsing helpers" {
    try testing.expectEqual(@as(u8, 0xFF), parseHex8("ff").?);
    try testing.expectEqual(@as(u8, 0x00), parseHex8("00").?);
    try testing.expectEqual(@as(u8, 0xA3), parseHex8("a3").?);
    try testing.expect(parseHex8("zz") == null);

    try testing.expectEqual(@as(u16, 0x0000), parseHex16("0000").?);
    try testing.expectEqual(@as(u16, 0xFFFF), parseHex16("ffff").?);
    try testing.expectEqual(@as(u16, 0x1234), parseHex16("1234").?);
}

// New tests for VFIO structs and constants

test "iommu: vfio ioctl constant values" {
    // Verify _IO(';', N) encoding: (0x3B << 8) | N
    try testing.expectEqual(@as(u32, 0x3B64), VFIO_GET_API_VERSION);
    try testing.expectEqual(@as(u32, 0x3B65), VFIO_CHECK_EXTENSION);
    try testing.expectEqual(@as(u32, 0x3B66), VFIO_SET_IOMMU);
    try testing.expectEqual(@as(u32, 0x3B67), VFIO_GROUP_GET_STATUS);
    try testing.expectEqual(@as(u32, 0x3B68), VFIO_GROUP_SET_CONTAINER);
    try testing.expectEqual(@as(u32, 0x3B6A), VFIO_GROUP_GET_DEVICE_FD);
    try testing.expectEqual(@as(u32, 0x3B6B), VFIO_DEVICE_GET_INFO);
    try testing.expectEqual(@as(u32, 0x3B6C), VFIO_DEVICE_GET_REGION_INFO);
    try testing.expectEqual(@as(u32, 0x3B6F), VFIO_DEVICE_RESET);
    try testing.expectEqual(@as(u32, 0x3B71), VFIO_IOMMU_MAP_DMA);
    try testing.expectEqual(@as(u32, 0x3B72), VFIO_IOMMU_UNMAP_DMA);
}

test "iommu: vfio struct sizes" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(VfioGroupStatus));
    try testing.expectEqual(@as(usize, 16), @sizeOf(VfioDeviceInfo));
    try testing.expectEqual(@as(usize, 32), @sizeOf(VfioRegionInfo));
    try testing.expectEqual(@as(usize, 32), @sizeOf(VfioDmaMap));
    try testing.expectEqual(@as(usize, 24), @sizeOf(VfioDmaUnmap));
}

test "iommu: pci address sysfsPath" {
    const addr = PciAddress.parse("0000:03:00.0").?;
    var buf: [16]u8 = undefined;
    const path = addr.sysfsPath(&buf).?;
    try testing.expect(std.mem.eql(u8, std.mem.span(path), "0000:03:00.0"));

    const addr2 = PciAddress.parse("0000:82:1f.3").?;
    const path2 = addr2.sysfsPath(&buf).?;
    try testing.expect(std.mem.eql(u8, std.mem.span(path2), "0000:82:1f.3"));
}

test "iommu: formatU32" {
    var buf: [16]u8 = undefined;

    const len0 = formatU32(&buf, 0);
    try testing.expectEqual(@as(usize, 1), len0);
    try testing.expectEqual(@as(u8, '0'), buf[0]);

    const len42 = formatU32(&buf, 42);
    try testing.expectEqual(@as(usize, 2), len42);
    try testing.expect(std.mem.eql(u8, buf[0..2], "42"));

    const len999 = formatU32(&buf, 999);
    try testing.expectEqual(@as(usize, 3), len999);
    try testing.expect(std.mem.eql(u8, buf[0..3], "999"));
}

test "iommu: formatGroupPath" {
    var buf: [64]u8 = undefined;
    const path = formatGroupPath(&buf, 42).?;
    try testing.expect(std.mem.eql(u8, std.mem.span(path), "/dev/vfio/42"));

    const path0 = formatGroupPath(&buf, 0).?;
    try testing.expect(std.mem.eql(u8, std.mem.span(path0), "/dev/vfio/0"));
}

test "iommu: VfioRegOps adapter" {
    // VfioRegOps with null bar0 should read 0 / write no-op (same as VfioDevice default)
    var dev = VfioDevice{};
    var vfio_ops = dev.regOps();
    const val = VfioRegOps.read32(@ptrCast(&vfio_ops), 0);
    try testing.expectEqual(@as(u32, 0), val);
    VfioRegOps.write32(@ptrCast(&vfio_ops), 0, 0xBEEF); // no-op, should not crash
}
