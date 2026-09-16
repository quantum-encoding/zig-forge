//! Runtime macOS version, read from the `kern.osproductversion` sysctl
//! (the same value `sw_vers -productVersion` prints).
//!
//! Apple's C APIs are gated by OS version, not by compile-time SDK, so a
//! binary built against the macOS 27 SDK still has to ask which functions
//! exist on the machine it is running on.

const std = @import("std");

pub const Version = struct {
    major: u32,
    minor: u32 = 0,
    patch: u32 = 0,

    pub fn atLeast(self: Version, major: u32, minor: u32) bool {
        return self.major > major or (self.major == major and self.minor >= minor);
    }

    pub fn order(a: Version, b: Version) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        return std.math.order(a.patch, b.patch);
    }

    /// Parse "27.0", "26.1.2", "10.15.7". Trailing NUL or newline is ignored.
    pub fn parse(text: []const u8) error{InvalidVersion}!Version {
        const trimmed = std.mem.trim(u8, std.mem.sliceTo(text, 0), " \n\r\t");
        var it = std.mem.splitScalar(u8, trimmed, '.');
        const major = std.fmt.parseInt(u32, it.next() orelse return error.InvalidVersion, 10) catch return error.InvalidVersion;
        var v = Version{ .major = major };
        if (it.next()) |m| v.minor = std.fmt.parseInt(u32, m, 10) catch return error.InvalidVersion;
        if (it.next()) |p| v.patch = std.fmt.parseInt(u32, p, 10) catch return error.InvalidVersion;
        if (it.next() != null) return error.InvalidVersion;
        return v;
    }
};

// Packed as (1 << 63) | major << 40 | minor << 20 | patch once loaded; 0 while unloaded.
var cached = std.atomic.Value(u64).init(0);
const loaded_bit: u64 = 1 << 63;

fn loadVersion() ?Version {
    var buf: [64]u8 = undefined;
    var len: usize = buf.len;
    if (std.c.sysctlbyname("kern.osproductversion", &buf, &len, null, 0) != 0) return null;
    return Version.parse(buf[0..len]) catch null;
}

/// The running macOS version, or null if the sysctl is unavailable.
/// Read once from the kernel; concurrent first callers compute the same value.
pub fn current() ?Version {
    const packed_val = cached.load(.acquire);
    if (packed_val & loaded_bit != 0) {
        return .{
            .major = @truncate(packed_val >> 40),
            .minor = @truncate((packed_val >> 20) & 0xFFFFF),
            .patch = @truncate(packed_val & 0xFFFFF),
        };
    }
    const v = loadVersion() orelse return null;
    cached.store(loaded_bit | (@as(u64, v.major) << 40) | (@as(u64, v.minor & 0xFFFFF) << 20) | (v.patch & 0xFFFFF), .release);
    return v;
}

// ───────────────────────────── tests ─────────────────────────────

test "parse" {
    try std.testing.expectEqual(Version{ .major = 27 }, try Version.parse("27.0"));
    try std.testing.expectEqual(Version{ .major = 26, .minor = 1, .patch = 2 }, try Version.parse("26.1.2\n"));
    try std.testing.expectEqual(Version{ .major = 10, .minor = 15, .patch = 7 }, try Version.parse("10.15.7\x00"));
    try std.testing.expectError(error.InvalidVersion, Version.parse(""));
    try std.testing.expectError(error.InvalidVersion, Version.parse("1.2.3.4"));
    try std.testing.expectError(error.InvalidVersion, Version.parse("abc"));
}

test "comparison" {
    const v = Version{ .major = 15, .minor = 4 };
    try std.testing.expect(v.atLeast(15, 4));
    try std.testing.expect(v.atLeast(13, 0));
    try std.testing.expect(!v.atLeast(15, 5));
    try std.testing.expect(!v.atLeast(26, 0));
    try std.testing.expectEqual(std.math.Order.lt, v.order(.{ .major = 15, .minor = 4, .patch = 1 }));
}

test "anchor: product version agrees with the kernel release" {
    // Since macOS 26 the Darwin kernel major equals the product major, so
    // uname(3) is an independent witness for the sysctl's leading component.
    const v = current() orelse return error.SkipZigTest;
    var uts: std.c.utsname = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.uname(&uts));
    const release = try Version.parse(std.mem.sliceTo(&uts.release, 0));
    if (v.major >= 26) {
        try std.testing.expectEqual(release.major, v.major);
    } else {
        // Darwin major = macOS major + 9 for 11..15 (Darwin 20..24).
        try std.testing.expectEqual(v.major + 9, release.major);
    }
}
