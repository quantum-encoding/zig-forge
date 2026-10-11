//! Synchronization primitives for Zig 0.16 compatibility
//!
//! Provides Mutex and Condition implementations since std.Thread.Mutex and
//! std.Thread.Condition are not available in Zig 0.16: pthreads where the
//! platform has them, and on Windows, which has none, the Win32 SRW lock and
//! condition variable (kernel32).
//!
//! Requires linking libc (link_libc = true in build.zig).

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

/// The kernel32 SRW lock and condition variable API.
const win32 = struct {
    const SRWLOCK = std.os.windows.SRWLOCK;
    const CONDITION_VARIABLE = std.os.windows.CONDITION_VARIABLE;
    const INFINITE: u32 = 0xFFFF_FFFF;
    const ERROR_TIMEOUT: u32 = 1460;

    extern "kernel32" fn AcquireSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
    extern "kernel32" fn ReleaseSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
    extern "kernel32" fn SleepConditionVariableSRW(
        cond: *CONDITION_VARIABLE,
        lock: *SRWLOCK,
        milliseconds: u32,
        flags: u32,
    ) callconv(.winapi) i32;
    extern "kernel32" fn WakeConditionVariable(cond: *CONDITION_VARIABLE) callconv(.winapi) void;
    extern "kernel32" fn WakeAllConditionVariable(cond: *CONDITION_VARIABLE) callconv(.winapi) void;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
};

/// A mutual exclusion lock backed by pthread_mutex (an SRW lock on Windows).
/// Thread-safe; can be used across multiple threads.
pub const Mutex = struct {
    inner: if (is_windows) win32.SRWLOCK else std.c.pthread_mutex_t =
        if (is_windows) std.os.windows.SRWLOCK_INIT else std.c.PTHREAD_MUTEX_INITIALIZER,

    /// Acquires the lock, blocking until available.
    pub fn lock(self: *Mutex) void {
        if (is_windows) {
            win32.AcquireSRWLockExclusive(&self.inner);
        } else {
            _ = std.c.pthread_mutex_lock(&self.inner);
        }
    }

    /// Releases the lock. Must only be called by the thread that acquired it.
    pub fn unlock(self: *Mutex) void {
        if (is_windows) {
            win32.ReleaseSRWLockExclusive(&self.inner);
        } else {
            _ = std.c.pthread_mutex_unlock(&self.inner);
        }
    }
};

/// A condition variable backed by pthread_cond (a Win32 condition variable on
/// Windows). Used for thread synchronization with an associated Mutex.
pub const Condition = struct {
    inner: if (is_windows) win32.CONDITION_VARIABLE else std.c.pthread_cond_t =
        if (is_windows) std.os.windows.CONDITION_VARIABLE_INIT else std.c.PTHREAD_COND_INITIALIZER,

    /// Blocks the calling thread until the condition is signaled.
    /// The mutex must be locked by the caller before calling wait.
    /// The mutex is atomically released while waiting and re-acquired before returning.
    pub fn wait(self: *Condition, mutex: *Mutex) void {
        if (is_windows) {
            _ = win32.SleepConditionVariableSRW(&self.inner, &mutex.inner, win32.INFINITE, 0);
        } else {
            _ = std.c.pthread_cond_wait(&self.inner, &mutex.inner);
        }
    }

    /// Blocks until signaled or timeout expires.
    /// Returns error.Timeout if the timeout expires before being signaled.
    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
        if (is_windows) {
            // Whole milliseconds, rounded up so a short timeout still waits, and
            // short of INFINITE, which would never time out.
            const ms = timeout_ns / 1_000_000 + @intFromBool(timeout_ns % 1_000_000 != 0);
            const wait_ms: u32 = @intCast(@min(ms, win32.INFINITE - 1));
            if (win32.SleepConditionVariableSRW(&self.inner, &mutex.inner, wait_ms, 0) == 0 and
                win32.GetLastError() == win32.ERROR_TIMEOUT)
            {
                return error.Timeout;
            }
            return;
        }

        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);

        // Add timeout to current time
        const ns_total = @as(u64, @intCast(ts.nsec)) + timeout_ns;
        ts.sec += @intCast(ns_total / 1_000_000_000);
        ts.nsec = @intCast(ns_total % 1_000_000_000);

        const result = std.c.pthread_cond_timedwait(&self.inner, &mutex.inner, &ts);
        if (result == .TIMEDOUT) {
            return error.Timeout;
        }
    }

    /// Wakes one thread waiting on this condition.
    pub fn signal(self: *Condition) void {
        if (is_windows) {
            win32.WakeConditionVariable(&self.inner);
        } else {
            _ = std.c.pthread_cond_signal(&self.inner);
        }
    }

    /// Wakes all threads waiting on this condition.
    pub fn broadcast(self: *Condition) void {
        if (is_windows) {
            win32.WakeAllConditionVariable(&self.inner);
        } else {
            _ = std.c.pthread_cond_broadcast(&self.inner);
        }
    }
};

test "Mutex basic lock/unlock" {
    var mutex = Mutex{};
    mutex.lock();
    mutex.unlock();
}

test "Condition basic signal" {
    var cond = Condition{};
    cond.signal();
    cond.broadcast();
}

test "Condition timedWait times out when nothing signals" {
    var mutex = Mutex{};
    var cond = Condition{};
    mutex.lock();
    defer mutex.unlock();
    // A wait may also end spuriously; with no signaller, a timeout must still come.
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        cond.timedWait(&mutex, 1_000_000) catch |err| {
            try std.testing.expectEqual(error.Timeout, err);
            return;
        };
    }
    return error.TestExpectedTimeout;
}

test "Condition timedWait wakes for a signal from another thread" {
    const Shared = struct {
        mutex: Mutex = .{},
        cond: Condition = .{},
        ready: bool = false,

        fn signaller(s: *@This()) void {
            s.mutex.lock();
            s.ready = true;
            s.mutex.unlock();
            s.cond.signal();
        }
    };
    var shared: Shared = .{};
    shared.mutex.lock();
    const thread = try std.Thread.spawn(.{}, Shared.signaller, .{&shared});
    while (!shared.ready) {
        // Ten seconds: a timeout here means the signal was lost, not a slow host.
        try shared.cond.timedWait(&shared.mutex, 10 * std.time.ns_per_s);
    }
    shared.mutex.unlock();
    thread.join();
}
