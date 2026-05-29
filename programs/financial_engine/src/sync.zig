//! Lightweight, Io-free concurrency primitives for the HFT path.
//!
//! Zig 0.16 removed `std.Thread.Mutex` (the only std lock is now
//! `std.Io.Mutex`, whose `lock(io)` requires threading an `Io` handle through
//! every locker) and `std.Thread.sleep`. For a latency-sensitive order
//! validation path a blocking OS mutex is the wrong tool anyway, so we use an
//! atomic spinlock; and background loops sleep via libc `nanosleep` — neither
//! pollutes the call graph with `Io` handles.

const std = @import("std");

/// Atomic test-and-set spinlock. Drop-in for the old `std.Thread.Mutex` API
/// (`lock()` / `unlock()` take no `Io`). Intended for short critical sections
/// (a few field updates) — never hold it across a syscall or a network call.
pub const SpinLock = struct {
    state: std.atomic.Value(u32) = .init(0),

    pub fn lock(self: *SpinLock) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn tryLock(self: *SpinLock) bool {
        return self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) == null;
    }

    pub fn unlock(self: *SpinLock) void {
        self.state.store(0, .release);
    }
};

/// Sleep for `ns` nanoseconds via libc `nanosleep` — no `Io` handle, usable
/// from spawned background threads. Replaces the removed `std.Thread.sleep`.
/// Resumes after EINTR with the remaining time.
pub fn sleepNs(ns: u64) void {
    var req: std.c.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: std.c.timespec = undefined;
    while (std.c.nanosleep(&req, &rem) != 0) : (req = rem) {}
}

/// Wall-clock seconds via libc `clock_gettime(REALTIME)`. Replaces the removed
/// `std.time.timestamp`. (Same approach order_book.zig already uses.)
pub fn nowSeconds() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

/// Monotonic nanoseconds via libc `clock_gettime(MONOTONIC)`. Replaces the
/// removed `std.time.nanoTimestamp`. Monotonic is correct for elapsed-time
/// math (immune to wall-clock adjustments).
pub fn nowNanos() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

/// Non-cryptographic 32-bit nonce from the monotonic clock — sub-second
/// uniqueness for client order IDs. Replaces `std.crypto.random.int(u32)`
/// (std.crypto.random was removed in 0.16); order IDs need uniqueness, not
/// unpredictability, so a crypto CSPRNG is unnecessary here.
pub fn nonce32() u32 {
    return @truncate(@as(u128, @bitCast(nowNanos())));
}
