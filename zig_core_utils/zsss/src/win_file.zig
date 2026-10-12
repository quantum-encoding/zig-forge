//! The zsss CLI's file I/O on Windows, which has none of the POSIX calls the
//! other platforms' branches use (open/read/write/mkdir/clock_gettime).
//!
//! The POSIX branch opens with O_NOFOLLOW so a symlink planted at an input or
//! output path is never read or written through. The same guarantee here: each
//! file is opened with FILE_FLAG_OPEN_REPARSE_POINT, which opens a symlink (or
//! junction, or any reparse point) itself rather than its target, and the
//! handle's attributes are then checked, so a reparse point is refused before a
//! byte moves. The check is on the open handle, not the path, so nothing can be
//! swapped in between the check and the I/O.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const HANDLE = *anyopaque;
const INVALID_HANDLE_VALUE: usize = std.math.maxInt(usize);

const GENERIC_READ: u32 = 0x8000_0000;
const GENERIC_WRITE: u32 = 0x4000_0000;
const FILE_SHARE_READ: u32 = 0x0000_0001;
const OPEN_EXISTING: u32 = 3;
const OPEN_ALWAYS: u32 = 4;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x0000_0080;
const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0000_0400;
const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x0000_0010;
const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
const ERROR_ALREADY_EXISTS: u32 = 183;

const FILETIME = extern struct { low: u32, high: u32 };

const BY_HANDLE_FILE_INFORMATION = extern struct {
    attributes: u32,
    creation_time: FILETIME,
    last_access_time: FILETIME,
    last_write_time: FILETIME,
    volume_serial_number: u32,
    file_size_high: u32,
    file_size_low: u32,
    number_of_links: u32,
    file_index_high: u32,
    file_index_low: u32,
};

extern "kernel32" fn CreateFileW(
    name: [*:0]const u16,
    access: u32,
    share: u32,
    security: ?*anyopaque,
    disposition: u32,
    flags: u32,
    template: ?HANDLE,
) callconv(.winapi) usize;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, len: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, len: u32, written: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn SetEndOfFile(h: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn GetFileInformationByHandle(h: HANDLE, info: *BY_HANDLE_FILE_INFORMATION) callconv(.winapi) i32;
extern "kernel32" fn CreateDirectoryW(name: [*:0]const u16, security: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn GetSystemTimeAsFileTime(time: *FILETIME) callconv(.winapi) void;

/// Opens `path` without following a reparse point, then refuses one: the handle is
/// returned only for a plain file. Null when it cannot be opened or is refused.
fn openPlainFile(allocator: Allocator, path: []const u8, access: u32, share: u32, disposition: u32) !?HANDLE {
    const wide = std.unicode.utf8ToUtf16LeAllocZ(allocator, path) catch |err| switch (err) {
        error.InvalidUtf8 => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(wide);

    const raw = CreateFileW(wide.ptr, access, share, null, disposition, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, null);
    if (raw == INVALID_HANDLE_VALUE) return null;
    const h: HANDLE = @ptrFromInt(raw);

    var info: BY_HANDLE_FILE_INFORMATION = undefined;
    if (GetFileInformationByHandle(h, &info) == 0 or
        info.attributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY) != 0)
    {
        _ = CloseHandle(h);
        return null;
    }
    return h;
}

/// `readFileAlloc` for Windows: the same errors as the POSIX branch.
pub fn readFileAlloc(allocator: Allocator, path: []const u8, max_size: usize) ![]u8 {
    const h = (try openPlainFile(allocator, path, GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING)) orelse
        return error.FileNotFound;
    defer _ = CloseHandle(h);

    var data: std.ArrayListUnmanaged(u8) = .empty;
    errdefer data.deinit(allocator);

    var read_buf: [65536]u8 = undefined;
    while (true) {
        var n: u32 = 0;
        if (ReadFile(h, &read_buf, read_buf.len, &n, null) == 0 or n == 0) break;
        if (data.items.len + n > max_size) return error.FileTooBig;
        try data.appendSlice(allocator, read_buf[0..n]);
    }
    return data.toOwnedSlice(allocator);
}

/// `writeFileAlloc` for Windows: creates or truncates `path`, refusing a reparse
/// point there, with the same errors as the POSIX branch.
pub fn writeFile(allocator: Allocator, path: []const u8, data: []const u8) !void {
    const h = (try openPlainFile(allocator, path, GENERIC_WRITE, 0, OPEN_ALWAYS)) orelse
        return error.CreateFileFailed;
    defer _ = CloseHandle(h);

    // OPEN_ALWAYS keeps an existing file's bytes; the handle is at offset 0, so this
    // truncates it the way O_TRUNC does.
    if (SetEndOfFile(h) == 0) return error.WriteFailed;

    var written: usize = 0;
    while (written < data.len) {
        const chunk: u32 = @intCast(@min(data.len - written, std.math.maxInt(u32)));
        var n: u32 = 0;
        if (WriteFile(h, data.ptr + written, chunk, &n, null) == 0 or n == 0) return error.WriteFailed;
        written += n;
    }
}

/// `makeDirectory` for Windows: an existing directory is not an error.
pub fn makeDirectory(allocator: Allocator, path: []const u8) !void {
    const wide = std.unicode.utf8ToUtf16LeAllocZ(allocator, path) catch |err| switch (err) {
        error.InvalidUtf8 => return error.MkdirFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(wide);
    if (CreateDirectoryW(wide.ptr, null) == 0 and GetLastError() != ERROR_ALREADY_EXISTS) {
        return error.MkdirFailed;
    }
}

/// Wall-clock seconds since the Unix epoch. FILETIME counts 100 ns intervals since
/// 1601-01-01; 11 644 473 600 s separate the two epochs.
pub fn wallClockSeconds() i64 {
    var ft: FILETIME = undefined;
    GetSystemTimeAsFileTime(&ft);
    const ticks = (@as(u64, ft.high) << 32) | ft.low;
    return @as(i64, @intCast(ticks / 10_000_000)) - 11_644_473_600;
}
