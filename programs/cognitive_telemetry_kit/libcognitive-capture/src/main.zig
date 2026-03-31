//! libcognitive-capture - macOS DYLD Interposition Library
//!
//! Intercepts write() syscalls to capture Claude Code cognitive states.
//! This is the macOS equivalent of the Linux eBPF approach.
//!
//! Usage:
//!   export DYLD_INSERT_LIBRARIES=/usr/local/lib/libcognitive-capture.dylib
//!
//! Claude Code status line format: ✶ {State}… (ctrl+c to interrupt...)

const std = @import("std");
const c = std.c;

// RTLD_NEXT for dlsym
const RTLD_NEXT: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

// Direct syscall - bypasses ALL interposition (essential to avoid recursion)
// macOS ARM64: write = syscall 4, add 0x2000000 for Unix syscall = 0x2000004
inline fn raw_syscall_write(fd: c_int, buf: [*]const u8, count: usize) isize {
    return asm volatile (
        \\ movz x16, #0x0004
        \\ movk x16, #0x0200, lsl #16
        \\ svc #0x80
        : [ret] "={x0}" (-> isize),
        : [fd] "{x0}" (@as(usize, @intCast(fd))),
          [buf] "{x1}" (@intFromPtr(buf)),
          [count] "{x2}" (count),
    );
}

// Original write function pointer
const CWriteFn = *const fn (c_int, [*]const u8, usize) callconv(std.builtin.CallingConvention.c) isize;
var original_write: ?CWriteFn = null;

// Thread-local recursion guard
threadlocal var in_hook: bool = false;

// Status suffix anchor: "… (" (ellipsis + space + open paren) - this is stable
// The prefix icon is dynamic (various star characters from * to 12-pointed stars)
const STATUS_SUFFIX = "\xe2\x80\xa6 ("; // "… ("

// State capture file
const CAPTURE_FILE: [*:0]const u8 = "/tmp/cognitive-state-capture";

/// Extract cognitive state from Claude Code status line
/// Format: {star} {State}… (ctrl+c to interrupt...)
/// We anchor on "… (" and work backwards to find the state
fn extractState(buf: [*]const u8, count: usize) ?[]const u8 {
    const slice = buf[0..count];

    // Find "… (" suffix anchor
    const suffix_pos = std.mem.indexOf(u8, slice, STATUS_SUFFIX) orelse return null;
    if (suffix_pos < 3) return null; // Need at least icon + space + 1 char

    // Extract everything before the suffix
    const before_suffix = slice[0..suffix_pos];

    // Find the first space after the icon (icon could be 1-4 bytes)
    // Scan for first space within first 6 bytes (covers all Unicode stars + space)
    var state_start: usize = 0;
    for (before_suffix, 0..) |ch, i| {
        if (ch == ' ' and i < 6) {
            state_start = i + 1;
            break;
        }
    }

    if (state_start == 0 or state_start >= suffix_pos) return null;

    const state = before_suffix[state_start..];
    if (state.len == 0) return null;

    return state;
}

/// Get current Unix timestamp
fn getTimestamp() i64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK.REALTIME, &ts) != 0) return 0;
    return ts.sec;
}

/// Capture the cognitive state to file (uses raw_syscall_write to avoid recursion)
fn captureState(state: []const u8, pid: c.pid_t) void {
    var buf: [256]u8 = undefined;
    const ts = getTimestamp();

    const len = std.fmt.bufPrint(&buf, "{d}:{d}:{s}\n", .{ ts, pid, state }) catch return;

    // Write to main capture file - USE RAW SYSCALL
    const fd = c.open(CAPTURE_FILE, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(c.mode_t, 0o644));
    if (fd >= 0) {
        _ = raw_syscall_write(fd, len.ptr, len.len);
        _ = c.close(fd);
    }

    // Write to per-PID cache file
    var pid_path: [64]u8 = undefined;
    const pid_path_slice = std.fmt.bufPrint(&pid_path, "/tmp/cognitive-state-{d}", .{pid}) catch return;
    pid_path[pid_path_slice.len] = 0;

    const pid_fd = c.open(@ptrCast(&pid_path), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o644));
    if (pid_fd >= 0) {
        var state_buf: [128]u8 = undefined;
        const state_len = std.fmt.bufPrint(&state_buf, "{d}:{s}", .{ ts, state }) catch return;
        _ = raw_syscall_write(pid_fd, state_len.ptr, state_len.len);
        _ = c.close(pid_fd);
    }
}

/// Interposed write function - this replaces libc write()
fn my_write(fd: c_int, buf: [*]const u8, count: usize) callconv(std.builtin.CallingConvention.c) isize {
    // Recursion guard - use raw syscall to avoid infinite loop
    if (in_hook) {
        return raw_syscall_write(fd, buf, count);
    }

    in_hook = true;
    defer in_hook = false;

    // Now safe to call dlsym - any write it does goes to raw_syscall_write
    if (original_write == null) {
        if (c.dlsym(RTLD_NEXT, "write")) |p| {
            original_write = @ptrCast(@alignCast(p));
        }
    }

    const real_write = original_write orelse return raw_syscall_write(fd, buf, count);

    // Only inspect stdout/stderr with reasonable sizes
    if ((fd == c.STDOUT_FILENO or fd == c.STDERR_FILENO) and count > 4 and count < 512) {
        if (extractState(buf, count)) |state| {
            captureState(state, c.getpid());
        }
    }

    return real_write(fd, buf, count);
}

// DYLD interposition structure
const InterposeTuple = extern struct {
    replacement: *const anyopaque,
    replacee: *const anyopaque,
};

// Reference original libc write for interposition
extern "c" fn write(c_int, [*]const u8, usize) isize;

// Export the interposition binding
export const cognitive_write_interpose linksection("__DATA,__interpose") = InterposeTuple{
    .replacement = @ptrCast(&my_write),
    .replacee = @ptrCast(&write),
};
