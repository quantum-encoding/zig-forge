//! Windows implementation of the C-library calls the core makes (see sys.zig).
//!
//! The core was written against POSIX: small-integer file descriptors, C
//! strings, opendir/readdir, openat and friends. Rather than change every call
//! site, this file provides those names over Win32, the way a C runtime does:
//!
//!   * A descriptor is an index into a handle table. Each entry keeps the
//!     path it was opened with, so `openat` and `unlinkat` can resolve a name
//!     against a directory descriptor.
//!   * Paths arrive as WTF-8 with forward slashes (the core's canonical form on
//!     Windows, `C:/Users/...`) and are converted here to `\\?\C:\...` UTF-16,
//!     so long paths work and nothing is normalised behind our back.
//!   * Directories are read with FileIdBothDirectoryInfo, which returns each
//!     entry's size, allocated size, attributes, file id and mtime in one call.
//!     The walker's per-entry stat (`statAt`) is answered from that record,
//!     without opening the file.
//!   * Deletes and renames use POSIX semantics (Windows 10 1709+, NTFS): a
//!     file can be removed or replaced while another handle, or a memory
//!     mapping, still has it open, as on Linux. Filesystems without it (FAT,
//!     exFAT) fall back to the classic calls.
//!   * Reparse points are never followed. Symlinks, junctions and app-execution
//!     aliases are reported as links; cloud placeholders (OneDrive) are files
//!     or folders like any other, marked dataless.
//!
//! Errors are kept per thread and read with `errno`, as with libc.

const std = @import("std");
const windows = std.os.windows;
const unicode = std.unicode;

const HANDLE = windows.HANDLE;
const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
const DWORD = u32;
const BOOL = c_int;
const WCHAR = u16;

const allocator = std.heap.smp_allocator;

// ---------------------------------------------------------------------------
// Win32 declarations (kernel32)
// ---------------------------------------------------------------------------

const GENERIC_READ: DWORD = 0x80000000;
const GENERIC_WRITE: DWORD = 0x40000000;
const DELETE: DWORD = 0x00010000;
const FILE_READ_ATTRIBUTES: DWORD = 0x0080;
const SYNCHRONIZE: DWORD = 0x00100000;

const FILE_SHARE_ALL: DWORD = 0x1 | 0x2 | 0x4; // read | write | delete

const CREATE_NEW: DWORD = 1;
const CREATE_ALWAYS: DWORD = 2;
const OPEN_EXISTING: DWORD = 3;
const OPEN_ALWAYS: DWORD = 4;
const TRUNCATE_EXISTING: DWORD = 5;

const FILE_ATTRIBUTE_READONLY: DWORD = 0x1;
const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x10;
const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
const FILE_ATTRIBUTE_REPARSE_POINT: DWORD = 0x400;
const FILE_ATTRIBUTE_OFFLINE: DWORD = 0x1000;
const FILE_ATTRIBUTE_RECALL_ON_OPEN: DWORD = 0x40000;
const FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS: DWORD = 0x400000;

const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x02000000;
const FILE_FLAG_OPEN_REPARSE_POINT: DWORD = 0x00200000;

const MOVEFILE_REPLACE_EXISTING: DWORD = 0x1;

// Reparse tags (winnt.h) that make an entry a link rather than content.
const IO_REPARSE_TAG_MOUNT_POINT: DWORD = 0xA0000003;
const IO_REPARSE_TAG_SYMLINK: DWORD = 0xA000000C;
const IO_REPARSE_TAG_APPEXECLINK: DWORD = 0x8000001B;

// FILE_INFO_BY_HANDLE_CLASS
const FileStandardInfo: c_int = 1;
const FileAttributeTagInfo: c_int = 9;
const FileIdBothDirectoryInfo: c_int = 10;
const FileIdBothDirectoryRestartInfo: c_int = 11;
const FileDispositionInfoEx: c_int = 21;
const FileRenameInfoEx: c_int = 22;

const FILE_DISPOSITION_FLAG_DELETE: DWORD = 0x1;
const FILE_DISPOSITION_FLAG_POSIX_SEMANTICS: DWORD = 0x2;
const FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE: DWORD = 0x10;
const FILE_RENAME_FLAG_REPLACE_IF_EXISTS: DWORD = 0x1;
const FILE_RENAME_FLAG_POSIX_SEMANTICS: DWORD = 0x2;

// Win32 error codes this layer maps (winerror.h).
const ERROR_FILE_NOT_FOUND: DWORD = 2;
const ERROR_PATH_NOT_FOUND: DWORD = 3;
const ERROR_ACCESS_DENIED: DWORD = 5;
const ERROR_INVALID_HANDLE: DWORD = 6;
const ERROR_NOT_ENOUGH_MEMORY: DWORD = 8;
const ERROR_NOT_SAME_DEVICE: DWORD = 17;
const ERROR_NO_MORE_FILES: DWORD = 18;
const ERROR_WRITE_PROTECT: DWORD = 19;
const ERROR_NOT_READY: DWORD = 21;
const ERROR_SHARING_VIOLATION: DWORD = 32;
const ERROR_LOCK_VIOLATION: DWORD = 33;
const ERROR_HANDLE_EOF: DWORD = 38;
const ERROR_NOT_SUPPORTED: DWORD = 50;
const ERROR_FILE_EXISTS: DWORD = 80;
const ERROR_INVALID_PARAMETER: DWORD = 87;
const ERROR_DISK_FULL: DWORD = 112;
const ERROR_INVALID_NAME: DWORD = 123;
const ERROR_DIR_NOT_EMPTY: DWORD = 145;
const ERROR_BUSY: DWORD = 170;
const ERROR_ALREADY_EXISTS: DWORD = 183;
const ERROR_FILENAME_EXCED_RANGE: DWORD = 206;
const ERROR_DIRECTORY: DWORD = 267;
const ERROR_CANT_ACCESS_FILE: DWORD = 1920;
const ERROR_CANT_RESOLVE_FILENAME: DWORD = 1921;

const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: DWORD = 0,
    OffsetHigh: DWORD = 0,
    hEvent: ?HANDLE = null,
};

const FILETIME = extern struct { dwLowDateTime: DWORD, dwHighDateTime: DWORD };

const BY_HANDLE_FILE_INFORMATION = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    dwVolumeSerialNumber: DWORD,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
    nNumberOfLinks: DWORD,
    nFileIndexHigh: DWORD,
    nFileIndexLow: DWORD,
};

const FILE_STANDARD_INFO = extern struct {
    AllocationSize: i64,
    EndOfFile: i64,
    NumberOfLinks: DWORD,
    DeletePending: u8,
    Directory: u8,
};

const FILE_ATTRIBUTE_TAG_INFO = extern struct {
    FileAttributes: DWORD,
    ReparseTag: DWORD,
};

/// winbase.h FILE_ID_BOTH_DIR_INFO. `EaSize` holds the reparse tag when the
/// entry is a reparse point.
const FILE_ID_BOTH_DIR_INFO = extern struct {
    NextEntryOffset: DWORD,
    FileIndex: DWORD,
    CreationTime: i64,
    LastAccessTime: i64,
    LastWriteTime: i64,
    ChangeTime: i64,
    EndOfFile: i64,
    AllocationSize: i64,
    FileAttributes: DWORD,
    FileNameLength: DWORD,
    EaSize: DWORD,
    ShortNameLength: i8,
    ShortName: [12]WCHAR,
    FileId: i64,
    FileName: [1]WCHAR,
};

comptime {
    // The layout winbase.h gives; a mismatch would misread every entry.
    std.debug.assert(@offsetOf(FILE_ID_BOTH_DIR_INFO, "FileId") == 96);
    std.debug.assert(@offsetOf(FILE_ID_BOTH_DIR_INFO, "FileName") == 104);
}

const FILE_DISPOSITION_INFO_EX = extern struct { Flags: DWORD };

/// FILE_RENAME_INFO as FileRenameInfoEx takes it: the flags word, then the
/// destination as a counted UTF-16 string.
const RenameInfo = extern struct {
    Flags: DWORD,
    RootDirectory: ?HANDLE,
    FileNameLength: DWORD,
    FileName: [1]WCHAR,
};

extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const WCHAR,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;
extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: DWORD, got: ?*DWORD, ov: ?*OVERLAPPED) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: DWORD, put: ?*DWORD, ov: ?*OVERLAPPED) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn DuplicateHandle(src_proc: HANDLE, src: HANDLE, dst_proc: HANDLE, dst: *HANDLE, access: DWORD, inherit: BOOL, options: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "kernel32" fn GetFileInformationByHandle(h: HANDLE, info: *BY_HANDLE_FILE_INFORMATION) callconv(.winapi) BOOL;
extern "kernel32" fn GetFileInformationByHandleEx(h: HANDLE, class: c_int, info: *anyopaque, size: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn SetFileInformationByHandle(h: HANDLE, class: c_int, info: *const anyopaque, size: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn MoveFileExW(from: [*:0]const WCHAR, to: [*:0]const WCHAR, flags: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn DeleteFileW(path: [*:0]const WCHAR) callconv(.winapi) BOOL;
extern "kernel32" fn RemoveDirectoryW(path: [*:0]const WCHAR) callconv(.winapi) BOOL;
extern "kernel32" fn GetFileAttributesW(path: [*:0]const WCHAR) callconv(.winapi) DWORD;
extern "kernel32" fn SetFileAttributesW(path: [*:0]const WCHAR, attrs: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) BOOL;
extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) BOOL;
extern "kernel32" fn GetSystemTimePreciseAsFileTime(ft: *FILETIME) callconv(.winapi) void;
const SRWLOCK = extern struct { ptr: ?*anyopaque = null };
const CONDITION_VARIABLE = extern struct { ptr: ?*anyopaque = null };
const INFINITE: DWORD = 0xFFFFFFFF;
extern "kernel32" fn AcquireSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn SleepConditionVariableSRW(cv: *CONDITION_VARIABLE, lock: *SRWLOCK, ms: DWORD, flags: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn WakeConditionVariable(cv: *CONDITION_VARIABLE) callconv(.winapi) void;
extern "kernel32" fn WakeAllConditionVariable(cv: *CONDITION_VARIABLE) callconv(.winapi) void;
extern "kernel32" fn CreateFileMappingW(file: HANDLE, attrs: ?*anyopaque, protect: DWORD, size_high: DWORD, size_low: DWORD, name: ?[*:0]const WCHAR) callconv(.winapi) ?HANDLE;
extern "kernel32" fn MapViewOfFile(map: HANDLE, access: DWORD, off_high: DWORD, off_low: DWORD, bytes: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn UnmapViewOfFile(base: *const anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn GetFinalPathNameByHandleW(h: HANDLE, buf: [*]WCHAR, len: DWORD, flags: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetVolumePathNameW(path: [*:0]const WCHAR, buf: [*]WCHAR, len: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetDiskFreeSpaceExW(dir: [*:0]const WCHAR, avail: ?*u64, total: ?*u64, free: ?*u64) callconv(.winapi) BOOL;
extern "kernel32" fn CreateDirectoryW(path: [*:0]const WCHAR, attrs: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CreateHardLinkW(link: [*:0]const WCHAR, existing: [*:0]const WCHAR, attrs: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CreateSymbolicLinkW(link: [*:0]const WCHAR, target: [*:0]const WCHAR, flags: DWORD) callconv(.winapi) u8;
extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const WCHAR, value: ?[*:0]const WCHAR) callconv(.winapi) BOOL;
extern "kernel32" fn SetFileTime(h: HANDLE, created: ?*const FILETIME, accessed: ?*const FILETIME, written: ?*const FILETIME) callconv(.winapi) BOOL;
extern "kernel32" fn DeviceIoControl(h: HANDLE, code: DWORD, in_buf: ?*const anyopaque, in_size: DWORD, out_buf: ?*anyopaque, out_size: DWORD, returned: ?*DWORD, ov: ?*OVERLAPPED) callconv(.winapi) BOOL;
extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const WCHAR, buf: ?[*]WCHAR, size: DWORD) callconv(.winapi) DWORD;

// ---------------------------------------------------------------------------
// libc-shaped types
// ---------------------------------------------------------------------------

pub const mode_t = u32;

pub const timespec = extern struct { sec: i64, nsec: i64 };
pub const timeval = extern struct { sec: i64, usec: i64 };

pub const clockid_t = enum(u32) { REALTIME = 0, MONOTONIC = 1, _ };

/// The errno values the core compares against, with their Linux numbers.
pub const E = enum(u16) {
    SUCCESS = 0,
    PERM = 1,
    NOENT = 2,
    INTR = 4,
    IO = 5,
    BADF = 9,
    NOMEM = 12,
    ACCES = 13,
    BUSY = 16,
    EXIST = 17,
    XDEV = 18,
    NOTDIR = 20,
    ISDIR = 21,
    INVAL = 22,
    NOSPC = 28,
    ROFS = 30,
    NAMETOOLONG = 36,
    NOTEMPTY = 39,
    LOOP = 40,
    OPNOTSUPP = 95,
    _,
};

pub const O = packed struct(u32) {
    ACCMODE: enum(u2) { RDONLY = 0, WRONLY = 1, RDWR = 2 } = .RDONLY,
    CREAT: bool = false,
    EXCL: bool = false,
    TRUNC: bool = false,
    APPEND: bool = false,
    NONBLOCK: bool = false,
    DIRECTORY: bool = false,
    NOFOLLOW: bool = false,
    CLOEXEC: bool = false,
    NOCTTY: bool = false,
    _: u21 = 0,
};

pub const AT = struct {
    pub const FDCWD: c_int = -100;
    pub const SYMLINK_NOFOLLOW: c_int = 0x100;
    pub const REMOVEDIR: c_int = 0x200;
};

pub const DT_UNKNOWN: u8 = 0;
pub const DT_DIR: u8 = 4;
pub const DT_REG: u8 = 8;
pub const DT_LNK: u8 = 10;

/// `readdir`'s entry: a NUL-terminated WTF-8 name and a `d_type`.
pub const dirent = extern struct {
    name: [1024]u8,
    type: u8,
};

pub const passwd = extern struct { dir: ?[*:0]const u8 };

// ---------------------------------------------------------------------------
// errno
// ---------------------------------------------------------------------------

threadlocal var last_errno: E = .SUCCESS;

fn setErrno(e: E) void {
    last_errno = e;
}

fn failWith(e: E) c_int {
    last_errno = e;
    return -1;
}

fn mapWin32(code: DWORD) E {
    return switch (code) {
        ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND, ERROR_INVALID_NAME => .NOENT,
        ERROR_ACCESS_DENIED, ERROR_CANT_ACCESS_FILE => .ACCES,
        ERROR_INVALID_HANDLE => .BADF,
        ERROR_NOT_ENOUGH_MEMORY => .NOMEM,
        ERROR_WRITE_PROTECT => .ROFS,
        ERROR_SHARING_VIOLATION, ERROR_LOCK_VIOLATION, ERROR_BUSY => .BUSY,
        ERROR_FILE_EXISTS, ERROR_ALREADY_EXISTS => .EXIST,
        ERROR_DISK_FULL => .NOSPC,
        ERROR_DIR_NOT_EMPTY => .NOTEMPTY,
        ERROR_DIRECTORY => .NOTDIR,
        ERROR_FILENAME_EXCED_RANGE => .NAMETOOLONG,
        ERROR_NOT_SAME_DEVICE => .XDEV,
        ERROR_CANT_RESOLVE_FILENAME => .LOOP,
        ERROR_NOT_SUPPORTED => .OPNOTSUPP,
        ERROR_NOT_READY => .IO,
        ERROR_INVALID_PARAMETER => .INVAL,
        else => .IO,
    };
}

fn failLast() c_int {
    return failWith(mapWin32(GetLastError()));
}

/// libc's `errno` as the core reads it: the calling thread's last error when
/// `rc` is -1, SUCCESS otherwise.
pub fn errno(rc: anytype) E {
    return if (rc == -1) last_errno else .SUCCESS;
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

/// Longest path converted: the `\\?\` form allows 32767 UTF-16 units.
const max_wide = 32767;

threadlocal var wide_buf: [max_wide + 1]WCHAR = undefined;
threadlocal var wide_buf2: [max_wide + 1]WCHAR = undefined;

fn isSep(ch: u8) bool {
    return ch == '/' or ch == '\\';
}

/// `path` (WTF-8, `/` or `\` separators) as a NUL-terminated UTF-16 string.
/// Absolute paths get the `\\?\` (or `\\?\UNC\`) prefix, so length limits
/// and name normalisation do not apply; `/` becomes `\` because the prefixed
/// form takes separators literally.
fn toWide(buf: *[max_wide + 1]WCHAR, path: []const u8) ?[*:0]const WCHAR {
    var prefix: []const u8 = "";
    var rest = path;
    if (rest.len >= 3 and std.ascii.isAlphabetic(rest[0]) and rest[1] == ':' and isSep(rest[2])) {
        prefix = "\\\\?\\";
    } else if (rest.len >= 2 and isSep(rest[0]) and isSep(rest[1])) {
        if (!(rest.len >= 4 and (rest[2] == '?' or rest[2] == '.') and isSep(rest[3]))) {
            prefix = "\\\\?\\UNC\\";
            rest = rest[2..];
        }
    }
    var n: usize = 0;
    for (prefix) |ch| {
        buf[n] = ch;
        n += 1;
    }
    const written = unicode.wtf8ToWtf16Le(buf[n..max_wide], rest) catch return null;
    for (buf[n..][0..written]) |*ch| {
        if (ch.* == '/') ch.* = '\\';
    }
    n += written;
    // A drive root keeps its trailing separator (`\\?\C:\`); anything else
    // drops one, which the prefixed form would otherwise take literally.
    while (n > prefix.len + 3 and buf[n - 1] == '\\') n -= 1;
    buf[n] = 0;
    return @ptrCast(buf);
}

fn joinPath(dir: []const u8, name: []const u8) ?[]u8 {
    const needs_sep = dir.len > 0 and !isSep(dir[dir.len - 1]);
    const sep_len: usize = @intFromBool(needs_sep);
    const out = allocator.alloc(u8, dir.len + sep_len + name.len) catch return null;
    @memcpy(out[0..dir.len], dir);
    if (needs_sep) out[dir.len] = '/';
    @memcpy(out[dir.len + sep_len ..], name);
    return out;
}

// ---------------------------------------------------------------------------
// The descriptor table
// ---------------------------------------------------------------------------

const Slot = struct {
    handle: HANDLE,
    /// The path the handle was opened with (owned), for `openat`/`unlinkat`.
    path: []u8,
    /// Set while a DIR stream reads this descriptor, for `statAt`.
    dir: ?*DIR = null,
};

/// A slim reader/writer lock held exclusively: Windows' own mutex, statically
/// initialisable and never needing cleanup.
const Lock = struct {
    srw: SRWLOCK = .{},
    fn lock(self: *Lock) void {
        AcquireSRWLockExclusive(&self.srw);
    }
    fn unlock(self: *Lock) void {
        ReleaseSRWLockExclusive(&self.srw);
    }
};

const fd_base: c_int = 3;
var table_lock: Lock = .{};
var table: std.ArrayListUnmanaged(?Slot) = .empty;

fn putSlot(slot: Slot) c_int {
    table_lock.lock();
    defer table_lock.unlock();
    for (table.items, 0..) |*s, i| {
        if (s.* == null) {
            s.* = slot;
            return fd_base + @as(c_int, @intCast(i));
        }
    }
    table.append(allocator, slot) catch return -1;
    return fd_base + @as(c_int, @intCast(table.items.len - 1));
}

fn slotIndex(fd: c_int) ?usize {
    if (fd < fd_base) return null;
    return @intCast(fd - fd_base);
}

fn getSlot(fd: c_int) ?Slot {
    const i = slotIndex(fd) orelse return null;
    table_lock.lock();
    defer table_lock.unlock();
    if (i >= table.items.len) return null;
    return table.items[i];
}

fn setSlotDir(fd: c_int, dir: ?*DIR) void {
    const i = slotIndex(fd) orelse return;
    table_lock.lock();
    defer table_lock.unlock();
    if (i < table.items.len) {
        if (table.items[i]) |*s| s.dir = dir;
    }
}

fn takeSlot(fd: c_int) ?Slot {
    const i = slotIndex(fd) orelse return null;
    table_lock.lock();
    defer table_lock.unlock();
    if (i >= table.items.len) return null;
    const s = table.items[i];
    table.items[i] = null;
    return s;
}

/// The handle behind a descriptor, for platform code outside this file.
pub fn handleOf(fd: c_int) ?HANDLE {
    return if (getSlot(fd)) |s| s.handle else null;
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

fn openPath(path: []const u8, flags: O) c_int {
    const w = toWide(&wide_buf, path) orelse return failWith(.NAMETOOLONG);
    var access: DWORD = switch (flags.ACCMODE) {
        .RDONLY => GENERIC_READ,
        .WRONLY => GENERIC_WRITE,
        .RDWR => GENERIC_READ | GENERIC_WRITE,
    };
    access |= FILE_READ_ATTRIBUTES; // what fstat needs
    const disposition: DWORD = if (flags.CREAT and flags.EXCL)
        CREATE_NEW
    else if (flags.CREAT and flags.TRUNC)
        CREATE_ALWAYS
    else if (flags.CREAT)
        OPEN_ALWAYS
    else if (flags.TRUNC)
        TRUNCATE_EXISTING
    else
        OPEN_EXISTING;
    // Backup semantics is what lets CreateFileW open a directory at all.
    var attrs: DWORD = FILE_ATTRIBUTE_NORMAL | FILE_FLAG_BACKUP_SEMANTICS;
    if (flags.NOFOLLOW) attrs |= FILE_FLAG_OPEN_REPARSE_POINT;
    const h = CreateFileW(w, access, FILE_SHARE_ALL, null, disposition, attrs, null);
    if (h == INVALID_HANDLE_VALUE) return failLast();

    var info: BY_HANDLE_FILE_INFORMATION = undefined;
    const is_dir = GetFileInformationByHandle(h, &info) != 0 and info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0;
    if (flags.DIRECTORY and !is_dir) {
        _ = CloseHandle(h);
        return failWith(.NOTDIR);
    }
    if (is_dir and flags.ACCMODE != .RDONLY) {
        _ = CloseHandle(h);
        return failWith(.ISDIR);
    }
    const owned = allocator.dupe(u8, path) catch {
        _ = CloseHandle(h);
        return failWith(.NOMEM);
    };
    const fd = putSlot(.{ .handle = h, .path = owned });
    if (fd < 0) {
        allocator.free(owned);
        _ = CloseHandle(h);
        return failWith(.NOMEM);
    }
    return fd;
}

pub fn open(path: [*:0]const u8, flags: O, mode: mode_t) c_int {
    _ = mode;
    return openPath(std.mem.span(path), flags);
}

fn resolveAt(dir_fd: c_int, name: [*:0]const u8) ?[]u8 {
    const n = std.mem.span(name);
    if (dir_fd == AT.FDCWD) return allocator.dupe(u8, n) catch null;
    const slot = getSlot(dir_fd) orelse return null;
    return joinPath(slot.path, n);
}

pub fn openat(dir_fd: c_int, name: [*:0]const u8, flags: O, mode: mode_t) c_int {
    _ = mode;
    const full = resolveAt(dir_fd, name) orelse return failWith(.BADF);
    defer allocator.free(full);
    return openPath(full, flags);
}

pub fn close(fd: c_int) c_int {
    const slot = takeSlot(fd) orelse return failWith(.BADF);
    allocator.free(slot.path);
    return if (CloseHandle(slot.handle) != 0) 0 else failLast();
}

pub fn dup(fd: c_int) c_int {
    const slot = getSlot(fd) orelse return failWith(.BADF);
    var copy: HANDLE = undefined;
    const DUPLICATE_SAME_ACCESS: DWORD = 0x2;
    if (DuplicateHandle(GetCurrentProcess(), slot.handle, GetCurrentProcess(), &copy, 0, 0, DUPLICATE_SAME_ACCESS) == 0) {
        return failLast();
    }
    const owned = allocator.dupe(u8, slot.path) catch {
        _ = CloseHandle(copy);
        return failWith(.NOMEM);
    };
    const fd2 = putSlot(.{ .handle = copy, .path = owned });
    if (fd2 < 0) {
        allocator.free(owned);
        _ = CloseHandle(copy);
        return failWith(.NOMEM);
    }
    return fd2;
}

fn chunk(n: usize) DWORD {
    return @intCast(@min(n, std.math.maxInt(DWORD)));
}

pub fn read(fd: c_int, buf: [*]u8, n: usize) isize {
    const slot = getSlot(fd) orelse return failWith(.BADF);
    var got: DWORD = 0;
    if (ReadFile(slot.handle, buf, chunk(n), &got, null) == 0) {
        if (GetLastError() == ERROR_HANDLE_EOF) return 0;
        return failLast();
    }
    return got;
}

pub fn write(fd: c_int, buf: [*]const u8, n: usize) isize {
    const slot = getSlot(fd) orelse return failWith(.BADF);
    var put: DWORD = 0;
    if (WriteFile(slot.handle, buf, chunk(n), &put, null) == 0) return failLast();
    return put;
}

pub fn pwrite(fd: c_int, buf: [*]const u8, n: usize, offset: i64) isize {
    const slot = getSlot(fd) orelse return failWith(.BADF);
    const off: u64 = @bitCast(offset);
    var ov: OVERLAPPED = .{ .Offset = @truncate(off), .OffsetHigh = @truncate(off >> 32) };
    var put: DWORD = 0;
    if (WriteFile(slot.handle, buf, chunk(n), &put, &ov) == 0) return failLast();
    return put;
}

pub fn pread(fd: c_int, buf: [*]u8, n: usize, offset: i64) isize {
    const slot = getSlot(fd) orelse return failWith(.BADF);
    const off: u64 = @bitCast(offset);
    var ov: OVERLAPPED = .{ .Offset = @truncate(off), .OffsetHigh = @truncate(off >> 32) };
    var got: DWORD = 0;
    if (ReadFile(slot.handle, buf, chunk(n), &got, &ov) == 0) {
        if (GetLastError() == ERROR_HANDLE_EOF) return 0;
        return failLast();
    }
    return got;
}

const FSCTL_GET_REPARSE_POINT: DWORD = 0x000900A8;
const MAXIMUM_REPARSE_DATA_BUFFER_SIZE = 16 * 1024;

/// Where a symlink or junction points, as stored (its print name, else its
/// substitute name without the `\\??\\` prefix), in the core's path form.
/// Links are never followed on Windows; the target still matters because it
/// is part of a folder's identity. -1 with INVAL for anything but a link.
pub fn readlink(path: [*:0]const u8, buf: [*]u8, size: usize) isize {
    const w = toWide(&wide_buf, std.mem.span(path)) orelse return failWith(.NAMETOOLONG);
    const h = CreateFileW(w, FILE_READ_ATTRIBUTES, FILE_SHARE_ALL, null, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, null);
    if (h == INVALID_HANDLE_VALUE) return failLast();
    defer _ = CloseHandle(h);
    var data: [MAXIMUM_REPARSE_DATA_BUFFER_SIZE]u8 align(4) = undefined;
    var got: DWORD = 0;
    if (DeviceIoControl(h, FSCTL_GET_REPARSE_POINT, null, 0, &data, data.len, &got, null) == 0) {
        const err = GetLastError();
        // Not a reparse point at all: not a link.
        return failWith(if (err == 4390) .INVAL else mapWin32(err));
    }
    const tag = std.mem.readInt(u32, data[0..4], .little);
    // SymbolicLinkReparseBuffer has a Flags word before the names;
    // MountPointReparseBuffer does not.
    const names_at: usize = switch (tag) {
        IO_REPARSE_TAG_SYMLINK => 20,
        IO_REPARSE_TAG_MOUNT_POINT => 16,
        else => return failWith(.INVAL),
    };
    const sub_off = std.mem.readInt(u16, data[8..10], .little);
    const sub_len = std.mem.readInt(u16, data[10..12], .little);
    const print_off = std.mem.readInt(u16, data[12..14], .little);
    const print_len = std.mem.readInt(u16, data[14..16], .little);
    const use_print = print_len > 0;
    const off = names_at + @as(usize, if (use_print) print_off else sub_off);
    const len = @as(usize, if (use_print) print_len else sub_len);
    if (off + len > got) return failWith(.INVAL);
    var name16: [MAXIMUM_REPARSE_DATA_BUFFER_SIZE / 2]WCHAR = undefined;
    const units = len / 2;
    for (0..units) |i| name16[i] = std.mem.readInt(u16, data[off + 2 * i ..][0..2], .little);
    var target = name16[0..units];
    const nt_prefix = [_]WCHAR{ '\\', '?', '?', '\\' };
    if (std.mem.startsWith(WCHAR, target, &nt_prefix)) target = target[nt_prefix.len..];
    if (target.len * 3 > size) return failWith(.NAMETOOLONG);
    const n = unicode.wtf16LeToWtf8(buf[0..size], target);
    for (buf[0..n]) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    if (n >= 2 and buf[1] == ':') buf[0] = std.ascii.toUpper(buf[0]);
    return @intCast(n);
}

// ---------------------------------------------------------------------------
// Removing and renaming
// ---------------------------------------------------------------------------

fn isLinkTag(tag: DWORD) bool {
    return tag == IO_REPARSE_TAG_SYMLINK or tag == IO_REPARSE_TAG_MOUNT_POINT or tag == IO_REPARSE_TAG_APPEXECLINK;
}

/// Delete one entry, POSIX-style: it goes even while open elsewhere, and a
/// read-only file goes too. -2 = this filesystem has no POSIX delete.
fn removeWide(w: [*:0]const WCHAR, want_dir: bool) c_int {
    const h = CreateFileW(w, DELETE | FILE_READ_ATTRIBUTES, FILE_SHARE_ALL, null, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, null);
    if (h == INVALID_HANDLE_VALUE) return failLast();
    defer _ = CloseHandle(h);
    var tag: FILE_ATTRIBUTE_TAG_INFO = undefined;
    if (GetFileInformationByHandleEx(h, FileAttributeTagInfo, &tag, @sizeOf(FILE_ATTRIBUTE_TAG_INFO)) != 0) {
        const is_dir = tag.FileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0;
        const is_link = tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 and isLinkTag(tag.ReparseTag);
        // A junction or directory symlink is a link to the core, removed
        // with `unlink`; Windows stores it as a directory entry.
        if (want_dir and (!is_dir or is_link)) return failWith(.NOTDIR);
        if (!want_dir and is_dir and !is_link) return failWith(.ISDIR);
    }
    var info: FILE_DISPOSITION_INFO_EX = .{ .Flags = FILE_DISPOSITION_FLAG_DELETE | FILE_DISPOSITION_FLAG_POSIX_SEMANTICS | FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE };
    if (SetFileInformationByHandle(h, FileDispositionInfoEx, &info, @sizeOf(FILE_DISPOSITION_INFO_EX)) != 0) return 0;
    const err = GetLastError();
    if (err == ERROR_DIR_NOT_EMPTY) return failWith(.NOTEMPTY);
    if (err != ERROR_INVALID_PARAMETER and err != ERROR_NOT_SUPPORTED) return failWith(mapWin32(err));
    return -2;
}

fn removeClassic(w: [*:0]const WCHAR, want_dir: bool) c_int {
    const attrs = GetFileAttributesW(w);
    const is_dir_entry = attrs != 0xFFFFFFFF and attrs & FILE_ATTRIBUTE_DIRECTORY != 0;
    if (want_dir or is_dir_entry) return if (RemoveDirectoryW(w) != 0) 0 else failLast();
    if (DeleteFileW(w) != 0) return 0;
    if (GetLastError() == ERROR_ACCESS_DENIED and attrs != 0xFFFFFFFF and attrs & FILE_ATTRIBUTE_READONLY != 0) {
        _ = SetFileAttributesW(w, attrs & ~FILE_ATTRIBUTE_READONLY);
        if (DeleteFileW(w) != 0) return 0;
    }
    return failLast();
}

fn removePath(path: []const u8, want_dir: bool) c_int {
    const w = toWide(&wide_buf, path) orelse return failWith(.NAMETOOLONG);
    const rc = removeWide(w, want_dir);
    if (rc != -2) return rc;
    return removeClassic(w, want_dir);
}

pub fn unlink(path: [*:0]const u8) c_int {
    return removePath(std.mem.span(path), false);
}

pub fn rmdir(path: [*:0]const u8) c_int {
    return removePath(std.mem.span(path), true);
}

pub fn unlinkat(dir_fd: c_int, name: [*:0]const u8, flags: c_int) c_int {
    const full = resolveAt(dir_fd, name) orelse return failWith(.BADF);
    defer allocator.free(full);
    return removePath(full, flags & AT.REMOVEDIR != 0);
}

/// Replace `new` with `old`, POSIX-style: a target that is open or mapped
/// elsewhere is replaced all the same (a scan's new results store is renamed
/// over the one an open session still maps).
pub fn rename(old: [*:0]const u8, new: [*:0]const u8) c_int {
    const w_old = toWide(&wide_buf, std.mem.span(old)) orelse return failWith(.NAMETOOLONG);
    const w_new = toWide(&wide_buf2, std.mem.span(new)) orelse return failWith(.NAMETOOLONG);
    if (renamePosix(w_old, w_new)) |rc| return rc;
    // No POSIX rename on this filesystem (FAT, exFAT): the classic call,
    // which cannot replace a file that is open elsewhere.
    return if (MoveFileExW(w_old, w_new, MOVEFILE_REPLACE_EXISTING) != 0) 0 else failLast();
}

/// The POSIX-semantics rename, or null when the filesystem does not offer it.
fn renamePosix(w_old: [*:0]const WCHAR, w_new: [*:0]const WCHAR) ?c_int {
    const h = CreateFileW(w_old, DELETE | SYNCHRONIZE, FILE_SHARE_ALL, null, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, null);
    if (h == INVALID_HANDLE_VALUE) return failLast();
    defer _ = CloseHandle(h);

    const new_len = std.mem.len(w_new);
    const size = @offsetOf(RenameInfo, "FileName") + (new_len + 1) * @sizeOf(WCHAR);
    const mem = allocator.alignedAlloc(u8, .of(RenameInfo), size) catch return failWith(.NOMEM);
    defer allocator.free(mem);
    const info: *RenameInfo = @ptrCast(mem.ptr);
    info.Flags = FILE_RENAME_FLAG_REPLACE_IF_EXISTS | FILE_RENAME_FLAG_POSIX_SEMANTICS;
    info.RootDirectory = null;
    info.FileNameLength = @intCast(new_len * @sizeOf(WCHAR));
    const dest: [*]WCHAR = @ptrCast(&info.FileName);
    @memcpy(dest[0 .. new_len + 1], w_new[0 .. new_len + 1]);
    if (SetFileInformationByHandle(h, FileRenameInfoEx, info, @intCast(size)) != 0) return 0;
    const err = GetLastError();
    if (err == ERROR_INVALID_PARAMETER or err == ERROR_NOT_SUPPORTED) return null;
    return failWith(mapWin32(err));
}

// ---------------------------------------------------------------------------
// Directories
// ---------------------------------------------------------------------------

/// What one directory record says about an entry, kept for `statAt`.
const EntryInfo = struct {
    attributes: DWORD,
    reparse_tag: DWORD,
    size: u64,
    allocated: u64,
    file_id: u64,
    mtime: i64,
};

pub const DIR = struct {
    /// The descriptor the stream reads; closed with the stream.
    fd: c_int,
    buf: [64 * 1024]u8 align(8) = undefined,
    offset: usize = 0,
    filled: bool = false,
    done: bool = false,
    first: bool = true,
    volume_serial: u32 = 0,
    entry: dirent = undefined,
    info: EntryInfo = undefined,
    has_entry: bool = false,
};

pub fn fdopendir(fd: c_int) ?*DIR {
    const slot = getSlot(fd) orelse {
        setErrno(.BADF);
        return null;
    };
    var info: BY_HANDLE_FILE_INFORMATION = undefined;
    if (GetFileInformationByHandle(slot.handle, &info) == 0) {
        setErrno(mapWin32(GetLastError()));
        return null;
    }
    if (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0) {
        setErrno(.NOTDIR);
        return null;
    }
    const dir = allocator.create(DIR) catch {
        setErrno(.NOMEM);
        return null;
    };
    dir.* = .{ .fd = fd, .volume_serial = info.dwVolumeSerialNumber };
    setSlotDir(fd, dir);
    return dir;
}

pub fn opendir(path: [*:0]const u8) ?*DIR {
    const fd = open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (fd < 0) return null;
    return fdopendir(fd) orelse {
        _ = close(fd);
        return null;
    };
}

pub fn closedir(dir: *DIR) c_int {
    const rc = close(dir.fd);
    allocator.destroy(dir);
    return rc;
}

pub fn dirfd(dir: *DIR) c_int {
    return dir.fd;
}

fn fill(dir: *DIR, handle: HANDLE) bool {
    const class = if (dir.first) FileIdBothDirectoryRestartInfo else FileIdBothDirectoryInfo;
    dir.first = false;
    if (GetFileInformationByHandleEx(handle, class, &dir.buf, dir.buf.len) == 0) {
        const err = GetLastError();
        if (err != ERROR_NO_MORE_FILES) setErrno(mapWin32(err));
        dir.done = true;
        return false;
    }
    dir.offset = 0;
    dir.filled = true;
    return true;
}

pub fn readdir(dir: *DIR) ?*dirent {
    const slot = getSlot(dir.fd) orelse return null;
    dir.has_entry = false;
    while (!dir.done) {
        if (!dir.filled and !fill(dir, slot.handle)) return null;
        const base = dir.offset;
        const rec: *align(1) const FILE_ID_BOTH_DIR_INFO = @ptrCast(dir.buf[base..].ptr);
        if (rec.NextEntryOffset == 0) {
            dir.filled = false;
        } else {
            dir.offset += rec.NextEntryOffset;
        }
        const name_start = base + @offsetOf(FILE_ID_BOTH_DIR_INFO, "FileName");
        const name_units = rec.FileNameLength / 2;
        if (name_start + name_units * 2 > dir.buf.len) continue;
        var name16: [512]WCHAR = undefined;
        if (name_units > name16.len) continue;
        for (0..name_units) |i| {
            name16[i] = std.mem.readInt(u16, dir.buf[name_start + 2 * i ..][0..2], .little);
        }
        // Up to three WTF-8 bytes per unit, so 512 units always fit in 1536;
        // the entry holds 1023, which covers every legal name (255 units).
        if (name_units * 3 >= dir.entry.name.len) continue;
        const len = unicode.wtf16LeToWtf8(&dir.entry.name, name16[0..name_units]);
        dir.entry.name[len] = 0;

        const attrs = rec.FileAttributes;
        const tag: DWORD = if (attrs & FILE_ATTRIBUTE_REPARSE_POINT != 0) rec.EaSize else 0;
        dir.entry.type = if (attrs & FILE_ATTRIBUTE_REPARSE_POINT != 0 and isLinkTag(tag))
            DT_LNK
        else if (attrs & FILE_ATTRIBUTE_DIRECTORY != 0)
            DT_DIR
        else
            DT_REG;
        dir.info = .{
            .attributes = attrs,
            .reparse_tag = tag,
            .size = @intCast(@max(rec.EndOfFile, 0)),
            .allocated = @intCast(@max(rec.AllocationSize, 0)),
            .file_id = @bitCast(rec.FileId),
            .mtime = fileTimeToUnix(rec.LastWriteTime),
        };
        dir.has_entry = true;
        return &dir.entry;
    }
    return null;
}

// ---------------------------------------------------------------------------
// stat, for pstat.zig
// ---------------------------------------------------------------------------

pub const S_IFREG: u32 = 0o100000;
pub const S_IFDIR: u32 = 0o040000;
pub const S_IFLNK: u32 = 0o120000;

/// The fields pstat.zig builds its `Stat` from.
pub const StatInfo = struct {
    dev: u64,
    ino: u64,
    mode: u32,
    size: u64,
    mtime_sec: i64,
    nlink: u32,
    allocated: u64,
    dataless: bool,
};

fn fileTimeToUnix(ft: i64) i64 {
    // 100 ns ticks since 1601-01-01, to seconds since 1970-01-01.
    return @divFloor(ft - 116444736000000000, 10_000_000);
}

fn modeOf(attrs: DWORD, tag: DWORD) u32 {
    if (attrs & FILE_ATTRIBUTE_REPARSE_POINT != 0 and isLinkTag(tag)) return S_IFLNK | 0o777;
    if (attrs & FILE_ATTRIBUTE_DIRECTORY != 0) return S_IFDIR | 0o755;
    return S_IFREG | (if (attrs & FILE_ATTRIBUTE_READONLY != 0) @as(u32, 0o444) else 0o644);
}

fn isDataless(attrs: DWORD) bool {
    return attrs & (FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS | FILE_ATTRIBUTE_RECALL_ON_OPEN | FILE_ATTRIBUTE_OFFLINE) != 0;
}

fn statHandle(h: HANDLE) ?StatInfo {
    var info: BY_HANDLE_FILE_INFORMATION = undefined;
    if (GetFileInformationByHandle(h, &info) == 0) {
        setErrno(mapWin32(GetLastError()));
        return null;
    }
    var tag: FILE_ATTRIBUTE_TAG_INFO = .{ .FileAttributes = info.dwFileAttributes, .ReparseTag = 0 };
    if (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0) {
        _ = GetFileInformationByHandleEx(h, FileAttributeTagInfo, &tag, @sizeOf(FILE_ATTRIBUTE_TAG_INFO));
    }
    var std_info: FILE_STANDARD_INFO = undefined;
    const allocated: u64 = if (GetFileInformationByHandleEx(h, FileStandardInfo, &std_info, @sizeOf(FILE_STANDARD_INFO)) != 0)
        @intCast(@max(std_info.AllocationSize, 0))
    else
        0;
    const mtime: i64 = @bitCast((@as(u64, info.ftLastWriteTime.dwHighDateTime) << 32) | info.ftLastWriteTime.dwLowDateTime);
    return .{
        .dev = info.dwVolumeSerialNumber,
        .ino = (@as(u64, info.nFileIndexHigh) << 32) | info.nFileIndexLow,
        .mode = modeOf(info.dwFileAttributes, tag.ReparseTag),
        .size = (@as(u64, info.nFileSizeHigh) << 32) | info.nFileSizeLow,
        .mtime_sec = fileTimeToUnix(mtime),
        .nlink = info.nNumberOfLinks,
        .allocated = allocated,
        .dataless = isDataless(info.dwFileAttributes),
    };
}

pub fn statPath(path: [*:0]const u8, follow: bool) ?StatInfo {
    const w = toWide(&wide_buf, std.mem.span(path)) orelse {
        setErrno(.NAMETOOLONG);
        return null;
    };
    var flags: DWORD = FILE_FLAG_BACKUP_SEMANTICS;
    if (!follow) flags |= FILE_FLAG_OPEN_REPARSE_POINT;
    const h = CreateFileW(w, FILE_READ_ATTRIBUTES, FILE_SHARE_ALL, null, OPEN_EXISTING, flags, null);
    if (h == INVALID_HANDLE_VALUE) {
        setErrno(mapWin32(GetLastError()));
        return null;
    }
    defer _ = CloseHandle(h);
    return statHandle(h);
}

pub fn statFd(fd: c_int) ?StatInfo {
    const slot = getSlot(fd) orelse {
        setErrno(.BADF);
        return null;
    };
    return statHandle(slot.handle);
}

/// `lstat` of `name` inside the directory `dir_fd`. When a DIR stream on that
/// descriptor has just returned `name`, its directory record answers with no
/// system call. The record carries no link count, so a file seen this way
/// reports 0 ("not reported"): the walker then checks its file id against
/// every other file's, which is what finds hard links.
pub fn statAt(dir_fd: c_int, name: [*:0]const u8) ?StatInfo {
    if (getSlot(dir_fd)) |slot| {
        if (slot.dir) |dir| {
            const current: [*:0]const u8 = @ptrCast(&dir.entry.name);
            if (dir.has_entry and std.mem.orderZ(u8, current, name) == .eq) {
                const e = dir.info;
                return .{
                    .dev = dir.volume_serial,
                    .ino = e.file_id,
                    .mode = modeOf(e.attributes, e.reparse_tag),
                    .size = e.size,
                    .mtime_sec = e.mtime,
                    .nlink = 0,
                    .allocated = e.allocated,
                    .dataless = isDataless(e.attributes),
                };
            }
        }
    }
    const full = resolveAt(dir_fd, name) orelse {
        setErrno(.BADF);
        return null;
    };
    defer allocator.free(full);
    const z = allocator.dupeSentinel(u8, full, 0) catch {
        setErrno(.NOMEM);
        return null;
    };
    defer allocator.free(z);
    return statPath(z, false);
}

// ---------------------------------------------------------------------------
// Canonical paths and volumes
// ---------------------------------------------------------------------------

pub const PATH_MAX = 4096;

/// `wide` (UTF-16, maybe `\\?\`-prefixed) in the core's path form: WTF-8,
/// no device prefix, forward slashes, an upper-case drive letter.
fn corePath(w: []const WCHAR, out: []u8) ?usize {
    var rest = w;
    const unc_prefix = [_]WCHAR{ '\\', '\\', '?', '\\', 'U', 'N', 'C', '\\' };
    const dev_prefix = [_]WCHAR{ '\\', '\\', '?', '\\' };
    var lead: []const u8 = "";
    if (std.mem.startsWith(WCHAR, rest, &unc_prefix)) {
        rest = rest[unc_prefix.len..];
        lead = "//";
    } else if (std.mem.startsWith(WCHAR, rest, &dev_prefix)) {
        rest = rest[dev_prefix.len..];
    }
    if (lead.len + rest.len * 3 >= out.len) return null;
    @memcpy(out[0..lead.len], lead);
    const n = lead.len + unicode.wtf16LeToWtf8(out[lead.len..], rest);
    for (out[0..n]) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    if (n >= 2 and out[1] == ':') out[0] = std.ascii.toUpper(out[0]);
    return n;
}

/// libc's realpath: the path of what `path` names, links resolved.
pub fn realpath(path: [*:0]const u8, out: *[PATH_MAX]u8) ?[*:0]u8 {
    const w = toWide(&wide_buf, std.mem.span(path)) orelse return null;
    const h = CreateFileW(w, FILE_READ_ATTRIBUTES, FILE_SHARE_ALL, null, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, null);
    if (h == INVALID_HANDLE_VALUE) {
        setErrno(mapWin32(GetLastError()));
        return null;
    }
    defer _ = CloseHandle(h);
    const n = GetFinalPathNameByHandleW(h, &wide_buf2, max_wide, 0);
    if (n == 0 or n >= max_wide) return null;
    const len = corePath(wide_buf2[0..n], out[0 .. out.len - 1]) orelse return null;
    out[len] = 0;
    return @ptrCast(out);
}

pub const VolumeInfo = struct { mount_len: usize, total: u64, free: u64, available: u64 };

/// The volume holding `path`: its root in the core's form (`C:/`), written
/// to `mount_out`, and its size and free space.
pub fn volumeOf(path: [*:0]const u8, mount_out: []u8) ?VolumeInfo {
    const w = toWide(&wide_buf, std.mem.span(path)) orelse return null;
    if (GetVolumePathNameW(w, &wide_buf2, max_wide) == 0) return null;
    const root_len = std.mem.indexOfScalar(WCHAR, &wide_buf2, 0) orelse return null;
    var total: u64 = 0;
    var free: u64 = 0;
    var available: u64 = 0;
    wide_buf2[root_len] = 0;
    if (GetDiskFreeSpaceExW(@ptrCast(&wide_buf2), &available, &total, &free) == 0) return null;
    const mount_len = corePath(wide_buf2[0..root_len], mount_out) orelse return null;
    return .{ .mount_len = mount_len, .total = total, .free = free, .available = available };
}

// ---------------------------------------------------------------------------
// Memory-mapped files, for sys.mapReadOnly
// ---------------------------------------------------------------------------

const PAGE_READONLY: DWORD = 0x02;
const FILE_MAP_READ: DWORD = 0x0004;

/// A read-only view of the whole of `fd`'s file. The mapping object is closed
/// at once; the view keeps it alive until `unmap`.
pub fn mapReadOnly(fd: c_int, len: usize) ?[]align(std.heap.page_size_min) const u8 {
    const slot = getSlot(fd) orelse return null;
    const mapping = CreateFileMappingW(slot.handle, null, PAGE_READONLY, 0, 0, null) orelse return null;
    defer _ = CloseHandle(mapping);
    const base = MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, len) orelse return null;
    const ptr: [*]align(std.heap.page_size_min) const u8 = @ptrCast(@alignCast(base));
    return ptr[0..len];
}

pub fn unmap(map: []align(std.heap.page_size_min) const u8) void {
    _ = UnmapViewOfFile(map.ptr);
}

// ---------------------------------------------------------------------------
// Time, environment, users
// ---------------------------------------------------------------------------

pub fn clock_gettime(clk: clockid_t, ts: *timespec) c_int {
    switch (clk) {
        .MONOTONIC => {
            var count: i64 = 0;
            var freq: i64 = 1;
            _ = QueryPerformanceCounter(&count);
            _ = QueryPerformanceFrequency(&freq);
            ts.sec = @divFloor(count, freq);
            ts.nsec = @divFloor(@mod(count, freq) * 1_000_000_000, freq);
        },
        else => {
            var ft: FILETIME = undefined;
            GetSystemTimePreciseAsFileTime(&ft);
            const ticks: i64 = @bitCast((@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime);
            const unix_ticks = ticks - 116444736000000000;
            ts.sec = @divFloor(unix_ticks, 10_000_000);
            ts.nsec = @mod(unix_ticks, 10_000_000) * 100;
        },
    }
    return 0;
}

pub fn gettimeofday(tv: *timeval, tz: ?*anyopaque) c_int {
    _ = tz;
    var ts: timespec = undefined;
    _ = clock_gettime(.REALTIME, &ts);
    tv.sec = ts.sec;
    tv.usec = @divFloor(ts.nsec, 1000);
    return 0;
}

pub fn getuid() u32 {
    return 0;
}

/// No user database on Windows: callers fall back to the environment.
pub fn getpwuid(uid: u32) ?*passwd {
    _ = uid;
    return null;
}

var env_lock: Lock = .{};
var env_cache: std.StringHashMapUnmanaged([:0]u8) = .empty;

/// The environment as libc's getenv would give it, in the core's path form
/// (forward slashes). `HOME` is `%USERPROFILE%`. Values are cached for the
/// life of the process, so a returned pointer stays valid.
pub fn getenv(name: [*:0]const u8) ?[*:0]const u8 {
    const key = std.mem.span(name);
    const lookup = if (std.mem.eql(u8, key, "HOME")) "USERPROFILE" else key;
    env_lock.lock();
    defer env_lock.unlock();
    if (env_cache.get(key)) |v| return v.ptr;

    var wname: [256]WCHAR = undefined;
    const wlen = unicode.wtf8ToWtf16Le(wname[0 .. wname.len - 1], lookup) catch return null;
    wname[wlen] = 0;
    const value = allocator.alloc(WCHAR, max_wide) catch return null;
    defer allocator.free(value);
    const n = GetEnvironmentVariableW(@ptrCast(&wname), value.ptr, @intCast(value.len));
    if (n == 0 or n >= value.len) return null;
    const utf8 = unicode.wtf16LeToWtf8Alloc(allocator, value[0..n]) catch return null;
    defer allocator.free(utf8);
    const owned = allocator.dupeSentinel(u8, utf8, 0) catch return null;
    for (owned) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    const key_copy = allocator.dupe(u8, key) catch return null;
    env_cache.put(allocator, key_copy, owned) catch return null;
    return owned.ptr;
}

// ---------------------------------------------------------------------------
// Threads: the pthread names the walker uses, over SRW locks and condition
// variables
// ---------------------------------------------------------------------------

pub const pthread_mutex_t = SRWLOCK;
pub const pthread_cond_t = CONDITION_VARIABLE;
pub const PTHREAD_MUTEX_INITIALIZER: pthread_mutex_t = .{};
pub const PTHREAD_COND_INITIALIZER: pthread_cond_t = .{};

pub fn pthread_mutex_lock(m: *pthread_mutex_t) c_int {
    AcquireSRWLockExclusive(m);
    return 0;
}

pub fn pthread_mutex_unlock(m: *pthread_mutex_t) c_int {
    ReleaseSRWLockExclusive(m);
    return 0;
}

pub fn pthread_cond_wait(cond: *pthread_cond_t, m: *pthread_mutex_t) c_int {
    _ = SleepConditionVariableSRW(cond, m, INFINITE, 0);
    return 0;
}

pub fn pthread_cond_signal(cond: *pthread_cond_t) c_int {
    WakeConditionVariable(cond);
    return 0;
}

pub fn pthread_cond_broadcast(cond: *pthread_cond_t) c_int {
    WakeAllConditionVariable(cond);
    return 0;
}

// ---------------------------------------------------------------------------
// What the test suites use to build their scratch trees
// ---------------------------------------------------------------------------

pub fn mkdir(path: [*:0]const u8, mode: mode_t) c_int {
    _ = mode;
    const w = toWide(&wide_buf, std.mem.span(path)) orelse return failWith(.NAMETOOLONG);
    return if (CreateDirectoryW(w, null) != 0) 0 else failLast();
}

pub fn link(existing: [*:0]const u8, new: [*:0]const u8) c_int {
    const w_existing = toWide(&wide_buf, std.mem.span(existing)) orelse return failWith(.NAMETOOLONG);
    const w_new = toWide(&wide_buf2, std.mem.span(new)) orelse return failWith(.NAMETOOLONG);
    return if (CreateHardLinkW(w_new, w_existing, null) != 0) 0 else failLast();
}

/// A symlink at `link_path` to `target` (relative to the link's folder, as
/// POSIX has it). Needs Developer Mode or an administrator; a directory
/// target gets a directory link, which Windows requires.
pub fn symlink(target: [*:0]const u8, link_path: [*:0]const u8) c_int {
    const SYMBOLIC_LINK_FLAG_DIRECTORY: DWORD = 0x1;
    const SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE: DWORD = 0x2;
    const t = std.mem.span(target);
    const l = std.mem.span(link_path);
    const resolved = if (filtersRootLen(t) > 0)
        allocator.dupe(u8, t) catch return failWith(.NOMEM)
    else blk: {
        const parent = l[0 .. std.mem.lastIndexOfScalar(u8, l, '/') orelse 0];
        break :blk joinPath(parent, t) orelse return failWith(.NOMEM);
    };
    defer allocator.free(resolved);
    const w_res = toWide(&wide_buf, resolved) orelse return failWith(.NAMETOOLONG);
    const attrs = GetFileAttributesW(w_res);
    var flags: DWORD = SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE;
    if (attrs != 0xFFFFFFFF and attrs & FILE_ATTRIBUTE_DIRECTORY != 0) flags |= SYMBOLIC_LINK_FLAG_DIRECTORY;
    const w_link = toWide(&wide_buf2, l) orelse return failWith(.NAMETOOLONG);
    // A relative target stays relative: convert it without the device prefix.
    var target_buf: [max_wide + 1]WCHAR = undefined;
    const n = unicode.wtf8ToWtf16Le(target_buf[0..max_wide], t) catch return failWith(.INVAL);
    for (target_buf[0..n]) |*ch| {
        if (ch.* == '/') ch.* = '\\';
    }
    target_buf[n] = 0;
    const w_target: [*:0]const WCHAR = if (filtersRootLen(t) > 0) toWide(&wide_buf, t) orelse return failWith(.NAMETOOLONG) else @ptrCast(&target_buf);
    return if (CreateSymbolicLinkW(w_link, w_target, flags) != 0) 0 else failLast();
}

fn filtersRootLen(path: []const u8) usize {
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and isSep(path[2])) return 3;
    if (path.len >= 2 and isSep(path[0]) and isSep(path[1])) return 2;
    return 0;
}

var random_counter = std.atomic.Value(u64).init(0);

/// Bytes for scratch-folder names in the tests: unique, not secret. The
/// high-resolution clock and a counter, mixed.
pub fn arc4random_buf(buf: [*]u8, len: usize) void {
    var count: i64 = 0;
    _ = QueryPerformanceCounter(&count);
    var seed = std.hash.Wyhash.hash(random_counter.fetchAdd(1, .monotonic), std.mem.asBytes(&count));
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (i % 8 == 0) seed = std.hash.Wyhash.hash(seed, std.mem.asBytes(&i));
        buf[i] = @truncate(seed >> @intCast((i % 8) * 8));
    }
}

fn setEnvWide(name: [*:0]const u8, value: ?[*:0]const u8) c_int {
    const key = std.mem.span(name);
    const lookup = if (std.mem.eql(u8, key, "HOME")) "USERPROFILE" else key;
    var wname: [256]WCHAR = undefined;
    const wlen = unicode.wtf8ToWtf16Le(wname[0 .. wname.len - 1], lookup) catch return failWith(.INVAL);
    wname[wlen] = 0;
    var ok: BOOL = undefined;
    if (value) |v| {
        const wv = toWide(&wide_buf, std.mem.span(v)) orelse return failWith(.NAMETOOLONG);
        ok = SetEnvironmentVariableW(@ptrCast(&wname), wv);
    } else {
        ok = SetEnvironmentVariableW(@ptrCast(&wname), null);
    }
    if (ok == 0) return failLast();
    // getenv caches what it returns; a changed variable must be read afresh.
    env_lock.lock();
    defer env_lock.unlock();
    _ = env_cache.remove(key);
    return 0;
}

pub fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int {
    if (overwrite == 0 and getenv(name) != null) return 0;
    return setEnvWide(name, value);
}

pub fn unsetenv(name: [*:0]const u8) c_int {
    return setEnvWide(name, null);
}

/// Set a file's modification (and access) time, as `utimes` does.
pub fn utimes(path: [*:0]const u8, times: ?*const [2]timeval) c_int {
    const FILE_WRITE_ATTRIBUTES: DWORD = 0x0100;
    const w = toWide(&wide_buf, std.mem.span(path)) orelse return failWith(.NAMETOOLONG);
    const h = CreateFileW(w, FILE_WRITE_ATTRIBUTES, FILE_SHARE_ALL, null, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, null);
    if (h == INVALID_HANDLE_VALUE) return failLast();
    defer _ = CloseHandle(h);
    const t = times orelse return 0;
    const toFt = struct {
        fn f(tv: timeval) FILETIME {
            const ticks: u64 = @intCast(tv.sec * 10_000_000 + @divFloor(tv.usec, 1) * 10 + 116444736000000000);
            return .{ .dwLowDateTime = @truncate(ticks), .dwHighDateTime = @truncate(ticks >> 32) };
        }
    }.f;
    const accessed = toFt(t[0]);
    const written = toFt(t[1]);
    return if (SetFileTime(h, null, &accessed, &written) != 0) 0 else failLast();
}

pub fn geteuid() c_uint {
    return 0;
}

extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;

pub fn nanosleep(req: *const timespec, rem: ?*timespec) c_int {
    _ = rem;
    const ms = req.sec * 1000 + @divFloor(req.nsec, 1_000_000);
    Sleep(@intCast(@max(ms, 0)));
    return 0;
}

/// No permission bits to change on Windows; callers that need a permission
/// failure skip there (getuid is 0).
pub fn chmod(path: [*:0]const u8, mode: mode_t) c_int {
    _ = path;
    _ = mode;
    return failWith(.OPNOTSUPP);
}

pub fn utimensat(dir_fd: c_int, path: [*:0]const u8, times: *const [2]timespec, flags: c_int) c_int {
    _ = flags;
    if (dir_fd != AT.FDCWD) return failWith(.INVAL);
    const tv = [2]timeval{
        .{ .sec = times[0].sec, .usec = @divFloor(times[0].nsec, 1000) },
        .{ .sec = times[1].sec, .usec = @divFloor(times[1].nsec, 1000) },
    };
    return utimes(path, &tv);
}
