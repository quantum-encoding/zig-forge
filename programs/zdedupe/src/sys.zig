//! The C-library surface the core calls, by platform.
//!
//! On Linux and macOS this is `std.c`, unchanged. On Windows there is no C
//! runtime to link (Zig cannot provide MSVC's), so `sys_windows.zig` supplies
//! the same names over Win32 and the NT API. Core files import `c` from here
//! in place of `std.c`, and their call sites stay as they are.

const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;

pub const c = if (is_windows) @import("sys_windows.zig") else @import("std").c;

const std = @import("std");

pub const Mapping = []align(std.heap.page_size_min) const u8;

/// Map `len` bytes of the open file `fd`, read-only and private. The file may
/// be replaced on disk afterwards (renamed over); the mapping keeps the old
/// contents. On Windows that holds only because every file is opened with
/// delete sharing and replaced with a POSIX-semantics rename (sys_windows.zig).
pub fn mapReadOnly(fd: c_int, len: usize) error{MapFailed}!Mapping {
    if (is_windows) return c.mapReadOnly(fd, len) orelse error.MapFailed;
    return std.posix.mmap(null, len, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) catch error.MapFailed;
}

pub fn unmap(map: Mapping) void {
    if (is_windows) return c.unmap(map);
    std.posix.munmap(map);
}
