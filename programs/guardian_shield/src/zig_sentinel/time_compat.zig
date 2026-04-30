/// Zig 0.16 compatibility layer for time functions
/// Replaces removed std.time.timestamp() and std.time.milliTimestamp()
const std = @import("std");

/// Get current Unix timestamp in seconds (replaces std.time.timestamp())
pub fn timestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

/// Get current time in milliseconds since epoch (replaces std.time.milliTimestamp())
pub fn milliTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, std.time.ns_per_ms);
}
