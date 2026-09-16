//! Mach absolute time: the tick clock behind `mach_absolute_time`, which is
//! also the unit EndpointSecurity uses for `es_message_t.mach_time` and
//! `es_message_t.deadline`.
//!
//! Ticks are converted to nanoseconds through `mach_timebase_info`, which is
//! fetched once and cached (numer/denom packed into one atomic u64).

const std = @import("std");

pub const Timebase = struct {
    numer: u32,
    denom: u32,
};

var cached_timebase = std.atomic.Value(u64).init(0);

/// The machine's tick-to-nanosecond ratio (1/1 on Intel, 125/3 on Apple silicon).
pub fn timebase() Timebase {
    const packed_val = cached_timebase.load(.acquire);
    if (packed_val != 0) return unpack(packed_val);

    var info: std.c.mach_timebase_info_data = undefined;
    // mach_timebase_info only fails for an invalid pointer.
    _ = std.c.mach_timebase_info(&info);
    const tb = Timebase{ .numer = info.numer, .denom = info.denom };
    cached_timebase.store(pack(tb), .release);
    return tb;
}

fn pack(tb: Timebase) u64 {
    return (@as(u64, tb.denom) << 32) | @as(u64, tb.numer);
}

fn unpack(v: u64) Timebase {
    return .{ .numer = @truncate(v), .denom = @truncate(v >> 32) };
}

/// Current `mach_absolute_time` in ticks. Monotonic, stops while asleep.
pub fn now() u64 {
    return std.c.mach_absolute_time();
}

/// Ticks → nanoseconds. Widened through u128 so large tick counts cannot overflow.
pub fn ticksToNanos(ticks: u64) u64 {
    const tb = timebase();
    return @intCast((@as(u128, ticks) * tb.numer) / tb.denom);
}

/// Nanoseconds → ticks.
pub fn nanosToTicks(ns: u64) u64 {
    const tb = timebase();
    return @intCast((@as(u128, ns) * tb.denom) / tb.numer);
}

/// Nanoseconds from now until `deadline_ticks`, or null once the deadline has passed.
pub fn nanosUntil(deadline_ticks: u64) ?u64 {
    const t = now();
    if (deadline_ticks <= t) return null;
    return ticksToNanos(deadline_ticks - t);
}

/// Nanoseconds elapsed since `ticks`, or null if `ticks` is in the future.
pub fn nanosSince(ticks: u64) ?u64 {
    const t = now();
    if (ticks > t) return null;
    return ticksToNanos(t - ticks);
}

/// Wall-clock `timespec` → nanoseconds since the Unix epoch.
pub fn timespecToNanos(ts: std.c.timespec) i128 {
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Wall-clock `timeval` → nanoseconds since the Unix epoch.
pub fn timevalToNanos(tv: std.c.timeval) i128 {
    return @as(i128, tv.sec) * std.time.ns_per_s + @as(i128, tv.usec) * std.time.ns_per_us;
}

// ───────────────────────────── tests ─────────────────────────────

test "timebase is sane and cached" {
    const a = timebase();
    try std.testing.expect(a.numer != 0 and a.denom != 0);
    const b = timebase();
    try std.testing.expectEqual(a, b);
}

test "ticks round-trip through nanoseconds" {
    const t = now();
    const ns = ticksToNanos(t);
    const back = nanosToTicks(ns);
    // Integer division loses at most one tick's worth of nanoseconds each way.
    const tb = timebase();
    const slack: u64 = (tb.numer / tb.denom) + 2;
    try std.testing.expect(back <= t and t - back <= slack);
}

test "anchor: mach ticks agree with CLOCK_UPTIME_RAW" {
    // CLOCK_UPTIME_RAW is documented by Apple as mach_absolute_time() in
    // nanoseconds, so the kernel's own conversion is the reference here.
    var ts: std.c.timespec = undefined;
    const t0 = now();
    try std.testing.expectEqual(@as(c_int, 0), std.c.clock_gettime(.UPTIME_RAW, &ts));
    const t1 = now();
    const kernel_ns: u64 = @intCast(timespecToNanos(ts));
    const lo = ticksToNanos(t0);
    const hi = ticksToNanos(t1);
    try std.testing.expect(kernel_ns >= lo -| 1000 and kernel_ns <= hi + 1000);
}

test "deadline arithmetic" {
    const t = now();
    const future = t + nanosToTicks(std.time.ns_per_s);
    const until = nanosUntil(future) orelse return error.TestUnexpectedResult;
    try std.testing.expect(until <= std.time.ns_per_s and until > std.time.ns_per_s / 2);
    try std.testing.expect(nanosUntil(t - 1) == null);
    try std.testing.expect(nanosSince(future) == null);
    try std.testing.expect(nanosSince(t) != null);
}

test "unix timestamps" {
    try std.testing.expectEqual(@as(i128, 1_500_000_000), timespecToNanos(.{ .sec = 1, .nsec = 500_000_000 }));
    try std.testing.expectEqual(@as(i128, 1_000_250_000), timevalToNanos(.{ .sec = 1, .usec = 250 }));
}
