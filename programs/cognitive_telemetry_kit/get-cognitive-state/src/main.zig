//! get-cognitive-state - macOS Version
//!
//! Returns the current cognitive state of Claude Code.
//! Reads from cache file written by libcognitive-capture.dylib
//!
//! State sources (in priority order):
//! 1. Cache file written by DYLD interposition (/tmp/cognitive-state-{pid})
//! 2. Fallback: no output (empty)
//!
//! Usage: get-cognitive-state [claude_pid]

const std = @import("std");
const c = std.c;
const Io = std.Io;

const CACHE_DIR = "/tmp";
const STATE_TIMEOUT_SECS: i64 = 30; // Consider stale after 30s

/// Get current Unix timestamp (Zig 0.16 compatible using libc)
fn getTimestamp() i64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK.REALTIME, &ts) != 0) return 0;
    return ts.sec;
}

pub fn main() !u8 {
    const allocator = std.heap.c_allocator;

    // Get PID from environment or find Claude process
    var claude_pid: ?u32 = null;

    // Check for CLAUDE_PID environment variable first
    if (c.getenv("CLAUDE_PID")) |ptr| {
        const pid_str = std.mem.sliceTo(ptr, 0);
        claude_pid = std.fmt.parseInt(u32, pid_str, 10) catch null;
    }

    if (claude_pid == null) {
        claude_pid = try findClaudePid(allocator);
    }

    // Try to read state from cache
    if (claude_pid) |pid| {
        if (readCachedState(pid)) |state| {
            // Write to stdout using C write
            _ = c.write(c.STDOUT_FILENO, state.ptr, state.len);
            _ = c.write(c.STDOUT_FILENO, "\n", 1);
        }
    }

    return 0;
}

fn findClaudePid(allocator: std.mem.Allocator) !?u32 {
    // Use pgrep to find Claude process
    const io = Io.Threaded.global_single_threaded.io();

    var child = std.process.spawn(io, .{
        .argv = &[_][]const u8{ "pgrep", "-f", "claude" },
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;

    // Manually read stdout using c.read (collectOutput no longer exists in Zig 0.16)
    var stdout_buf = std.ArrayListUnmanaged(u8).empty;
    defer stdout_buf.deinit(allocator);

    if (child.stdout) |stdout_file| {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n_signed = c.read(stdout_file.handle, &buf, buf.len);
            if (n_signed <= 0) break;
            const n: usize = @intCast(n_signed);
            stdout_buf.appendSlice(allocator, buf[0..n]) catch break;
        }
        _ = c.close(stdout_file.handle);
        child.stdout = null;
    }

    const term = child.wait(io) catch return null;

    if (term != .exited or term.exited != 0) return null;
    if (stdout_buf.items.len == 0) return null;

    // Get first line (first PID)
    const newline = std.mem.indexOf(u8, stdout_buf.items, "\n") orelse stdout_buf.items.len;
    const pid_str = std.mem.trim(u8, stdout_buf.items[0..newline], " \t\n\r");

    return std.fmt.parseInt(u32, pid_str, 10) catch null;
}

fn readCachedState(pid: u32) ?[]const u8 {
    // Build cache file path (null-terminated for C)
    var path_buf: [256]u8 = undefined;
    const path_slice = std.fmt.bufPrint(&path_buf, "{s}/cognitive-state-{d}", .{ CACHE_DIR, pid }) catch return null;
    path_buf[path_slice.len] = 0;

    // Open cache file using C open
    const fd = c.open(@ptrCast(&path_buf), .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = c.close(fd);

    // Read file contents
    var buf: [512]u8 = undefined;
    const bytes_read = c.read(fd, &buf, buf.len);
    if (bytes_read <= 0) return null;

    const content = std.mem.trim(u8, buf[0..@intCast(bytes_read)], " \t\n\r");

    // Parse: timestamp:state:
    var parts = std.mem.splitScalar(u8, content, ':');
    const ts_str = parts.next() orelse return null;
    const state_str = parts.next() orelse return null;

    // Check if stale
    const cache_ts = std.fmt.parseInt(i64, ts_str, 10) catch return null;
    const now = getTimestamp();
    if (now - cache_ts > STATE_TIMEOUT_SECS) {
        return null; // Stale - no state
    }

    // Return the state string directly (it's from the captured terminal output)
    return state_str;
}
