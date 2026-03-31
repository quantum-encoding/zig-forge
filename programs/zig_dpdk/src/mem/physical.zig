const std = @import("std");
const builtin = @import("builtin");

/// Translate virtual address to physical address.
///
/// On Linux: reads /proc/self/pagemap. Requires CAP_SYS_ADMIN or
/// suitable /proc permissions. Returns 0 on any failure.
///
/// On macOS / other: returns virtual address as identity mapping.
/// This is safe for testing — physical addresses are only used for
/// DMA descriptor programming which doesn't happen on macOS.
pub fn virtToPhys(virt: usize) u64 {
    if (comptime builtin.os.tag == .linux) {
        return linuxVirtToPhys(virt);
    }
    // Identity mapping for testing on non-Linux platforms
    return @intCast(virt);
}

/// Translate a pointer to a physical address.
pub fn ptrToPhys(ptr: anytype) u64 {
    return virtToPhys(@intFromPtr(ptr));
}

fn linuxVirtToPhys(virt: usize) u64 {
    if (comptime builtin.os.tag != .linux) return 0;

    const page_size: usize = 4096;
    const vpn = virt / page_size;

    // Each pagemap entry is 8 bytes, indexed by virtual page number
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/proc/self/pagemap", .{ .ACCMODE = .RDONLY }, 0) catch return 0;
    defer _ = std.c.close(fd);

    const seek_offset: i64 = @intCast(vpn * 8);

    var buf: [8]u8 = undefined;
    const n = std.c.pread64(fd, &buf, 8, seek_offset);
    if (n != 8) return 0;

    const entry = std.mem.readInt(u64, &buf, .little);

    // Bit 63: page present
    if (entry & (@as(u64, 1) << 63) == 0) return 0;

    // Bits 0-54: page frame number
    const pfn = entry & ((@as(u64, 1) << 55) - 1);
    return pfn * page_size + (virt % page_size);
}

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "physical: identity mapping on non-linux" {
    if (comptime builtin.os.tag == .linux) return error.SkipZigTest;

    const addr: usize = 0x1000_0000;
    try testing.expectEqual(@as(u64, 0x1000_0000), virtToPhys(addr));
}

test "physical: ptrToPhys" {
    var x: u32 = 42;
    const phys = ptrToPhys(&x);
    // On non-Linux, should equal the virtual address
    if (comptime builtin.os.tag != .linux) {
        try testing.expectEqual(@as(u64, @intFromPtr(&x)), phys);
    }
    // On any platform, should be non-zero for a valid stack variable
    try testing.expect(phys != 0);
}
