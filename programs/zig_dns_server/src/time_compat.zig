//! Wall-clock time helpers for Zig 0.16.
//!
//! `std.time.timestamp()` and `std.time.nanoTimestamp()` were removed in this
//! Zig 0.16 toolchain — the current API is `std.Io.Timestamp.now(io, clock)`,
//! which requires an `Io` handle. These libc-backed helpers preserve the
//! previous wall-clock behaviour without threading an `Io` through every
//! caller. build.zig links libc, so `std.c.clock_gettime` is available.

const std = @import("std");

/// Seconds since the Unix epoch (wall clock). Mirrors the old
/// `std.time.timestamp()`.
pub fn timestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

/// Nanoseconds since the Unix epoch (wall clock). Mirrors the old
/// `std.time.nanoTimestamp()`.
pub fn nanoTimestamp() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}
