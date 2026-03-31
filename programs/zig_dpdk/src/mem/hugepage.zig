const std = @import("std");
const builtin = @import("builtin");
const config = @import("../core/config.zig");

pub const Region = struct {
    ptr: [*]align(4096) u8,
    size: usize,
    page_size: config.HugepageSize,
    phys_addr: u64, // 0 if unknown (macOS, or pagemap read failed)

    pub fn slice(self: *const Region) []u8 {
        return @as([*]u8, @ptrCast(self.ptr))[0..self.size];
    }
};

pub const AllocError = error{
    MmapFailed,
    OutOfMemory,
};

/// Allocate a contiguous memory region.
/// On Linux with hugepage_size != .regular, attempts hugepage allocation with fallback.
/// On macOS / other, uses regular page-aligned allocation.
pub fn allocRegion(size: usize, page_size: config.HugepageSize) AllocError!Region {
    const aligned_size = alignUp(size, page_size.bytes());

    if (comptime builtin.os.tag == .linux) {
        if (page_size != .regular) {
            return allocLinuxHugepages(aligned_size, page_size) catch {
                return allocRegularPages(aligned_size);
            };
        }
    }
    return allocRegularPages(aligned_size);
}

/// Free a previously allocated region.
pub fn freeRegion(region: *const Region) void {
    if (comptime builtin.os.tag == .linux) {
        freeLinuxRegion(region);
    } else {
        freeFallbackRegion(region);
    }
}

// ── Regular pages (all platforms) ────────────────────────────────────────

fn allocRegularPages(size: usize) AllocError!Region {
    const memory = std.heap.page_allocator.alloc(u8, size) catch
        return AllocError.OutOfMemory;
    return Region{
        .ptr = @alignCast(memory.ptr),
        .size = size,
        .page_size = .regular,
        .phys_addr = 0,
    };
}

fn freeFallbackRegion(region: *const Region) void {
    const ptr: [*]u8 = @ptrCast(region.ptr);
    std.heap.page_allocator.free(ptr[0..region.size]);
}

// ── Linux hugepages ──────────────────────────────────────────────────────

fn allocLinuxHugepages(size: usize, page_size: config.HugepageSize) AllocError!Region {
    if (comptime builtin.os.tag != .linux) return AllocError.MmapFailed;

    const linux = std.os.linux;
    const MAP_HUGETLB: u32 = 0x40000;
    const MAP_HUGE_2MB: u32 = 21 << 26;
    const MAP_HUGE_1GB: u32 = 30 << 26;

    const huge_flag: u32 = MAP_HUGETLB | switch (page_size) {
        .huge_2m => MAP_HUGE_2MB,
        .huge_1g => MAP_HUGE_1GB,
        .regular => 0,
    };

    // MAP.PRIVATE | MAP.ANONYMOUS | huge flags
    const base_flags: u32 = @bitCast(linux.MAP{ .TYPE = .PRIVATE, .ANONYMOUS = true });
    const flags: u32 = base_flags | huge_flag;

    const rc = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, @bitCast(flags), -1, 0);
    const result: isize = @bitCast(rc);
    if (result < 0 or rc == 0) return AllocError.MmapFailed;

    return Region{
        .ptr = @ptrFromInt(rc),
        .size = size,
        .page_size = page_size,
        .phys_addr = 0, // caller fills via physical.virtToPhys()
    };
}

fn freeLinuxRegion(region: *const Region) void {
    if (comptime builtin.os.tag != .linux) return;
    const linux = std.os.linux;
    _ = linux.munmap(@ptrCast(region.ptr), region.size);
}

// ── Utilities ────────────────────────────────────────────────────────────

fn alignUp(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "hugepage: allocate and free regular pages" {
    const region = try allocRegion(4096 * 4, .regular);
    defer freeRegion(&region);

    try testing.expect(region.size >= 4096 * 4);
    try testing.expect(@intFromPtr(region.ptr) % 4096 == 0);

    // Write pattern to verify access
    const sl = region.slice();
    for (sl) |*byte| byte.* = 0xAA;
    try testing.expectEqual(@as(u8, 0xAA), sl[0]);
    try testing.expectEqual(@as(u8, 0xAA), sl[sl.len - 1]);
}

test "hugepage: alignUp" {
    try testing.expectEqual(@as(usize, 4096), alignUp(1, 4096));
    try testing.expectEqual(@as(usize, 4096), alignUp(4096, 4096));
    try testing.expectEqual(@as(usize, 8192), alignUp(4097, 4096));
    try testing.expectEqual(@as(usize, 2 * 1024 * 1024), alignUp(1, 2 * 1024 * 1024));
}
