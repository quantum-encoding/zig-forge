/// Zig 0.16 compatibility layer for time functions
const std = @import("std");
const linux = std.os.linux;

/// Get current Unix timestamp in seconds (replaces std.time.timestamp())
pub fn timestamp() i64 {
    var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
    const result = linux.clock_gettime(.REALTIME, &ts);
    if (@as(isize, @bitCast(result)) < 0) return 0;
    return ts.sec;
}
