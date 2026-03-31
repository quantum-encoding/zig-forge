//! Synchronization primitives for Zig 0.16 compatibility
//!
//! Provides pthread-based Mutex and Condition implementations since
//! std.Thread.Mutex and std.Thread.Condition are not available in Zig 0.16.
//!
//! Requires linking libc (link_libc = true in build.zig).

const std = @import("std");

/// A mutual exclusion lock backed by pthread_mutex.
/// Thread-safe; can be used across multiple threads.
pub const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    /// Acquires the lock, blocking until available.
    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }

    /// Releases the lock. Must only be called by the thread that acquired it.
    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

/// A condition variable backed by pthread_cond.
/// Used for thread synchronization with an associated Mutex.
pub const Condition = struct {
    inner: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,

    /// Blocks the calling thread until the condition is signaled.
    /// The mutex must be locked by the caller before calling wait.
    /// The mutex is atomically released while waiting and re-acquired before returning.
    pub fn wait(self: *Condition, mutex: *Mutex) void {
        _ = std.c.pthread_cond_wait(&self.inner, &mutex.inner);
    }

    /// Blocks until signaled or timeout expires.
    /// Returns error.Timeout if the timeout expires before being signaled.
    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
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
        _ = std.c.pthread_cond_signal(&self.inner);
    }

    /// Wakes all threads waiting on this condition.
    pub fn broadcast(self: *Condition) void {
        _ = std.c.pthread_cond_broadcast(&self.inner);
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
