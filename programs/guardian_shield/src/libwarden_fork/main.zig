//! libwarden-fork.so - Smart Fork Bomb Protection
//!
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
//!
//! Purpose: Rate-limit fork() with build-tool awareness to prevent fork bombs
//!          without breaking legitimate compilation workflows

const std = @import("std");

const c = @cImport({
    @cInclude("dlfcn.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
    @cInclude("time.h");
    @cInclude("fcntl.h");
    @cInclude("stdlib.h");
});

// Helper for getenv compatibility with Zig 0.16.2187+
fn getenvCompat(name: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const ptr = c.getenv(@ptrCast(&buf));
    if (ptr) |p| {
        return std.mem.span(p);
    }
    return null;
}

// ============================================================
// Configuration
// ============================================================

const ForkConfig = struct {
    max_forks_per_second: u32 = 100,        // Increased for build tools
    max_total_forks: u32 = 10000,           // Increased for large compilations
    idle_reset_seconds: u32 = 10,           // Reset after idle period
    burst_window_ms: u64 = 100,             // Window for burst detection
    burst_threshold: u32 = 20,              // Max forks in burst window
    enable_logging: bool = false,
    enable_override: bool = true,
};

// ============================================================
// State Tracking
// ============================================================

var config: ForkConfig = .{};
var initialized: bool = false;

var fork_count_current_second: u32 = 0;
var total_fork_count: u32 = 0;
var last_fork_time_sec: i64 = 0;
var last_activity_time_sec: i64 = 0;

// Burst detection
var burst_forks: [100]i64 = undefined;
var burst_index: usize = 0;

// Original function pointers
var original_fork: ?*const fn () callconv(.c) c.pid_t = null;
var original_vfork: ?*const fn () callconv(.c) c.pid_t = null;

// ============================================================
// Initialization
// ============================================================

fn initConfig() void {
    if (initialized) return;

    // Load from environment using getenvCompat for Zig 0.16.2187+
    if (getenvCompat("SAFE_FORK_MAX_PER_SEC")) |val| {
        config.max_forks_per_second = std.fmt.parseInt(u32, val, 10) catch 100;
    }

    if (getenvCompat("SAFE_FORK_MAX_TOTAL")) |val| {
        config.max_total_forks = std.fmt.parseInt(u32, val, 10) catch 10000;
    }

    if (getenvCompat("SAFE_FORK_LOG")) |val| {
        config.enable_logging = std.mem.eql(u8, val, "1");
    }

    initialized = true;

    if (config.enable_logging) {
        std.debug.print("[libwarden-fork] ⚡ Initialized: max {d} forks/sec, {d} total\n", .{
            config.max_forks_per_second,
            config.max_total_forks,
        });
    }
}

// ============================================================
// Process Context Detection
// ============================================================

fn getProcessName() ?[]const u8 {
    var buf: [256]u8 = undefined;
    const fd = c.open("/proc/self/comm", c.O_RDONLY, @as(c_uint, 0));
    if (fd < 0) return null;
    defer _ = c.close(fd);

    const bytes_read_raw = c.read(fd, &buf, buf.len);
    if (bytes_read_raw <= 0) return null;
    var bytes_read: usize = @intCast(bytes_read_raw);

    // Trim newline
    while (bytes_read > 0 and (buf[bytes_read - 1] == '\n' or buf[bytes_read - 1] == 0)) : (bytes_read -= 1) {}

    return buf[0..bytes_read];
}

fn isBuildToolProcess() bool {
    const name = getProcessName() orelse return false;

    const build_tools = [_][]const u8{
        "make",   "cmake", "ninja", "cargo", "rustc",
        "gcc",    "g++",   "clang", "clang++",
        "zig",    "npm",   "node",  "python", "python3",
        "ld",     "ld.lld", "ld.gold",
        "cc",     "c++",
    };

    for (build_tools) |tool| {
        if (std.mem.eql(u8, name, tool)) {
            return true;
        }
    }

    return false;
}

// ============================================================
// Fork Bomb Detection
// ============================================================

fn getCurrentTimeMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1000000);
}

fn detectBurstPattern() bool {
    const now_ms = getCurrentTimeMs();

    // Add current fork to burst tracking
    burst_forks[burst_index] = now_ms;
    burst_index = (burst_index + 1) % burst_forks.len;

    // Count forks in burst window
    var count: u32 = 0;
    const window_start = now_ms - @as(i64, @intCast(config.burst_window_ms));

    for (burst_forks) |fork_time| {
        if (fork_time >= window_start) {
            count += 1;
        }
    }

    return count > config.burst_threshold;
}

fn shouldAllowFork() bool {
    initConfig();

    const now_sec = @divTrunc(getCurrentTimeMs(), 1000);

    // Reset counters if in new second
    if (now_sec != last_fork_time_sec) {
        fork_count_current_second = 0;
        last_fork_time_sec = now_sec;
    }

    // Check for idle reset
    if (last_activity_time_sec != 0) {
        const idle_time = now_sec - last_activity_time_sec;
        if (idle_time >= config.idle_reset_seconds) {
            fork_count_current_second = 0;
            total_fork_count = 0;

            if (config.enable_logging) {
                std.debug.print("[libwarden-fork] ℹ️  Rate counter reset after {d}s idle\n", .{idle_time});
            }
        }
    }

    last_activity_time_sec = now_sec;

    // Increment counters
    fork_count_current_second += 1;
    total_fork_count += 1;

    // Check if this is a build tool - use more lenient limits
    const is_build_tool = isBuildToolProcess();
    const rate_limit = if (is_build_tool) config.max_forks_per_second * 2 else config.max_forks_per_second;

    // Rate limit check
    if (fork_count_current_second > rate_limit) {
        std.debug.print("\n[libwarden-fork] ⛔ BLOCKED: Fork rate limit exceeded\n", .{});
        std.debug.print("[libwarden-fork] Current: {d} forks/sec, limit: {d}\n", .{
            fork_count_current_second,
            rate_limit,
        });
        std.debug.print("[libwarden-fork] Possible fork bomb detected!\n", .{});

        // Check override
        if (config.enable_override) {
            if (getenvCompat("SAFE_FORK_OVERRIDE")) |val| {
                if (std.mem.eql(u8, val, "1")) {
                    std.debug.print("[libwarden-fork] ⚠️  Override enabled, allowing...\n", .{});
                    return true;
                }
            }
        }

        return false;
    }

    // Burst pattern detection (fork bomb signature)
    if (!is_build_tool and detectBurstPattern()) {
        std.debug.print("\n[libwarden-fork] ⛔ BLOCKED: Fork bomb pattern detected\n", .{});
        std.debug.print("[libwarden-fork] Rapid burst of {d} forks in {d}ms window\n", .{
            config.burst_threshold,
            config.burst_window_ms,
        });
        return false;
    }

    // Total fork limit
    if (total_fork_count > config.max_total_forks) {
        std.debug.print("\n[libwarden-fork] ⛔ BLOCKED: Total fork limit exceeded\n", .{});
        std.debug.print("[libwarden-fork] Total: {d}, limit: {d}\n", .{
            total_fork_count,
            config.max_total_forks,
        });
        return false;
    }

    if (config.enable_logging) {
        std.debug.print("[libwarden-fork] ✓ Allowed fork #{d} (rate: {d}/sec)\n", .{
            total_fork_count,
            fork_count_current_second,
        });
    }

    return true;
}

// ============================================================
// Syscall Interceptors
// ============================================================

export fn fork() c.pid_t {
    if (original_fork == null) {
        original_fork = @ptrCast(c.dlsym(c.RTLD_NEXT, "fork"));
        if (original_fork == null) {
            std.debug.print("[libwarden-fork] Error: Failed to load original fork\n", .{});
            c.__errno_location().* = c.ENOSYS;
            return -1;
        }
    }

    if (!shouldAllowFork()) {
        c.__errno_location().* = c.EAGAIN;
        return -1;
    }

    return original_fork.?();
}

export fn vfork() c.pid_t {
    if (original_vfork == null) {
        original_vfork = @ptrCast(c.dlsym(c.RTLD_NEXT, "vfork"));
        if (original_vfork == null) {
            std.debug.print("[libwarden-fork] Error: Failed to load original vfork\n", .{});
            c.__errno_location().* = c.ENOSYS;
            return -1;
        }
    }

    if (!shouldAllowFork()) {
        c.__errno_location().* = c.EAGAIN;
        return -1;
    }

    return original_vfork.?();
}

// Expose errno access for C compatibility
extern "c" fn __errno_location() *c_int;
