//! Guardian Shield - eBPF-based System Security Framework
//!
//! Copyright (c) 2025 Richard Tune / Quantum Encoding Ltd
//! Author: Richard Tune
//! Contact: info@quantumencoding.io
//! Website: https://quantumencoding.io
//!
//! License: Dual License - MIT (Non-Commercial) / Commercial License
//!
//! NON-COMMERCIAL USE (MIT License):
//! Permission is hereby granted, free of charge, to any person obtaining a copy
//! of this software and associated documentation files (the "Software"), to deal
//! in the Software without restriction for NON-COMMERCIAL purposes, including
//! without limitation the rights to use, copy, modify, merge, publish, distribute,
//! sublicense, and/or sell copies of the Software for non-commercial purposes,
//! and to permit persons to whom the Software is furnished to do so, subject to
//! the following conditions:
//!
//! The above copyright notice and this permission notice shall be included in all
//! copies or substantial portions of the Software.
//!
//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//! SOFTWARE.
//!
//! COMMERCIAL USE:
//! Commercial use of this software requires a separate commercial license.
//! Contact info@quantumencoding.io for commercial licensing terms.


// chronos.zig - The Sovereign Clock: Monotonically Increasing Timeline
// Purpose: Provide absolute, verifiable sequencing for parallel agentic warfare
//
// Doctrine: The JesterNet maintains its own sovereign timeline, independent of
// system clocks. Every agentic action is marked with a unique Chronos Tick.
//
// Architecture:
//   - Persistent AtomicU64 counter (survives reboots)
//   - Lock-free atomic operations (thread-safe)
//   - Monotonic guarantee (only increments, never decrements)
//   - File-backed persistence (/var/lib/chronos/tick.dat)

const std = @import("std");
const c = std.c;
const posix = std.posix;

/// Default path for persistent tick storage
pub const DEFAULT_TICK_PATH = "/var/lib/chronos/tick.dat";

/// Fallback path if system path not writable (for development/testing)
pub const FALLBACK_TICK_PATH = "/tmp/chronos-tick.dat";

/// The Chronos Clock - maintains sovereign timeline
pub const ChronosClock = struct {
    tick: std.atomic.Value(u64),
    tick_path: []const u8,
    allocator: std.mem.Allocator,

    /// Initialize Chronos Clock with persistent storage
    pub fn init(allocator: std.mem.Allocator, tick_path: ?[]const u8) !ChronosClock {
        const path = tick_path orelse DEFAULT_TICK_PATH;

        // Ensure directory exists
        const dir_path = std.fs.path.dirname(path) orelse "/var/lib/chronos";

        // Try to create directory using libc mkdir
        const dir_z = allocator.dupeZ(u8, dir_path) catch {
            return initWithPath(allocator, FALLBACK_TICK_PATH);
        };
        defer allocator.free(dir_z);

        const mkdir_result = c.mkdir(dir_z.ptr, 0o755);
        if (mkdir_result < 0) {
            const errno = std.c._errno().*;
            // EEXIST (17) means directory already exists - that's fine
            if (errno != 17) {
                // Permission denied (EACCES=13, EPERM=1) or other error - fall back
                if (errno == 13 or errno == 1) {
                    std.debug.print("⚠️  Cannot create {s}, using fallback: {s}\n", .{ dir_path, FALLBACK_TICK_PATH });
                    return initWithPath(allocator, FALLBACK_TICK_PATH);
                }
            }
        }

        return initWithPath(allocator, path);
    }

    fn initWithPath(allocator: std.mem.Allocator, path: []const u8) !ChronosClock {
        // Load existing tick from file, or start at 0
        const initial_tick = loadTickFromFile(path) catch |err| blk: {
            if (err == error.FileNotFound) {
                std.debug.print("🕐 Chronos Clock initializing (no previous tick found)\n", .{});
                break :blk 0;
            }
            return err;
        };

        std.debug.print("🕐 Chronos Clock initialized at TICK-{d:0>10}\n", .{initial_tick});

        return ChronosClock{
            .tick = std.atomic.Value(u64).init(initial_tick),
            .tick_path = path,
            .allocator = allocator,
        };
    }

    /// Get current tick (non-destructive read)
    pub fn getTick(self: *const ChronosClock) u64 {
        return self.tick.load(.monotonic);
    }

    /// Increment and return next tick (atomic operation)
    pub fn nextTick(self: *ChronosClock) !u64 {
        const new_tick = self.tick.fetchAdd(1, .monotonic) + 1;

        // Persist to disk after increment
        try self.persistTick(new_tick);

        return new_tick;
    }

    /// Persist current tick to disk
    pub fn persistTick(self: *const ChronosClock, tick: u64) !void {
        const path_z = self.allocator.dupeZ(u8, self.tick_path) catch return error.OutOfMemory;
        defer self.allocator.free(path_z);

        // Open file for writing (create if not exists, truncate)
        const fd = posix.openatZ(c.AT.FDCWD, path_z.ptr, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
        }, 0o644) catch return error.FileOpenFailed;
        defer _ = std.c.close(fd);

        var buf: [32]u8 = undefined;
        const tick_str = std.fmt.bufPrint(&buf, "{d}\n", .{tick}) catch return error.FormatFailed;
        _ = c.write(fd, tick_str.ptr, tick_str.len);
    }

    /// Graceful shutdown - ensure tick is persisted
    pub fn deinit(self: *ChronosClock) void {
        const current_tick = self.getTick();
        self.persistTick(current_tick) catch |err| {
            std.debug.print("⚠️  Failed to persist tick on shutdown: {any}\n", .{err});
        };
        std.debug.print("🕐 Chronos Clock shutdown at TICK-{d:0>10}\n", .{current_tick});
    }
};

/// Load tick from persistent storage
fn loadTickFromFile(path: []const u8) !u64 {
    // Create null-terminated path on stack
    var path_buf: [256]u8 = undefined;
    if (path.len >= path_buf.len) return error.PathTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const fd = posix.openatZ(c.AT.FDCWD, path_buf[0..path.len :0], .{
        .ACCMODE = .RDONLY,
    }, 0) catch return error.FileNotFound;
    defer _ = std.c.close(fd);

    var buf: [32]u8 = undefined;
    const read_result = c.read(fd, &buf, buf.len);
    if (read_result <= 0) return error.FileNotFound;

    const bytes_read: usize = @intCast(read_result);
    const content = std.mem.trim(u8, buf[0..bytes_read], &std.ascii.whitespace);

    if (content.len == 0) return error.InvalidCharacter;
    return std.fmt.parseInt(u64, content, 10) catch return error.InvalidCharacter;
}

// ============================================================
// Tests
// ============================================================

test "ChronosClock init and increment" {
    const allocator = std.testing.allocator;

    // Use temporary path for testing
    const test_path = "/tmp/chronos-test-tick.dat";
    defer _ = c.unlink(test_path);

    var clock = try ChronosClock.init(allocator, test_path);
    defer clock.deinit();

    // Initial tick should be 0
    try std.testing.expectEqual(@as(u64, 0), clock.getTick());

    // Increment and verify
    const tick1 = try clock.nextTick();
    try std.testing.expectEqual(@as(u64, 1), tick1);

    const tick2 = try clock.nextTick();
    try std.testing.expectEqual(@as(u64, 2), tick2);

    // Current tick should match last increment
    try std.testing.expectEqual(@as(u64, 2), clock.getTick());
}

test "ChronosClock persistence across restarts" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/chronos-persist-test.dat";
    defer _ = c.unlink(test_path);

    // First instance
    {
        var clock = try ChronosClock.init(allocator, test_path);
        defer clock.deinit();

        _ = try clock.nextTick(); // 1
        _ = try clock.nextTick(); // 2
        _ = try clock.nextTick(); // 3
    }

    // Second instance (simulates restart)
    {
        var clock = try ChronosClock.init(allocator, test_path);
        defer clock.deinit();

        // Should resume from persisted tick
        try std.testing.expectEqual(@as(u64, 3), clock.getTick());

        const tick4 = try clock.nextTick();
        try std.testing.expectEqual(@as(u64, 4), tick4);
    }
}

test "ChronosClock monotonic guarantee" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/chronos-monotonic-test.dat";
    defer {
        const path_z: [*:0]const u8 = @ptrCast(test_path.ptr);
        _ = std.os.linux.unlink(path_z);
    }

    var clock = try ChronosClock.init(allocator, test_path);
    defer clock.deinit();

    var prev_tick: u64 = 0;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const tick = try clock.nextTick();
        try std.testing.expect(tick > prev_tick); // Strict monotonic increase
        prev_tick = tick;
    }
}
