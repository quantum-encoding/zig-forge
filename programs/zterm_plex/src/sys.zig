//! sys — the descriptor-level calls zterm_plex's event loops make, on every
//! platform it builds for.
//!
//! On POSIX each name here is an ALIAS of the call it stands for (`read` is
//! `std.posix.read`, `write` is `std.c.write`, `poll` is `std.posix.poll`, …),
//! so code written against sys compiles to exactly what it did when it called
//! those directly. On Windows the same names are Winsock: every descriptor the
//! loops see there is a SOCKET — control and runner doors are AF_UNIX sockets,
//! and a pane's PTY is presented as one end of an AF_UNIX socket pair that a
//! relay thread joins to the ConPTY pipes (pty_windows.zig) — so one WSAPoll
//! set waits on all of them, as one poll(2) set does on POSIX.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;

pub const is_windows = builtin.os.tag == .windows;
pub const win = if (is_windows) @import("win32.zig") else struct {};

/// A pollable descriptor. On Windows a SOCKET held as a signed integer, so
/// INVALID_SOCKET reads as -1: the same "no descriptor" sentinel the POSIX
/// code already uses.
pub const fd_t = if (is_windows) isize else posix.fd_t;

/// One poll entry. Windows' WSAPOLLFD has this layout (SOCKET, SHORT, SHORT).
pub const pollfd = if (is_windows) extern struct {
    fd: fd_t,
    events: i16,
    revents: i16,
} else posix.pollfd;

/// Poll event bits. Windows' POLLIN is POLLRDNORM|POLLRDBAND (winsock2.h).
pub const POLL = if (is_windows) struct {
    pub const IN: i16 = win.POLLRDNORM | win.POLLRDBAND;
    pub const OUT: i16 = win.POLLWRNORM;
    pub const ERR: i16 = win.POLLERR;
    pub const HUP: i16 = win.POLLHUP;
    pub const NVAL: i16 = win.POLLNVAL;
} else posix.POLL;

/// Wait for any of `fds`; an empty set sleeps `timeout` ms (WSAPoll rejects
/// an empty set, and callers use one as a sleep).
pub const poll = if (is_windows) pollWindows else posix.poll;

/// Read from a descriptor (a socket, on Windows). error.WouldBlock means
/// nothing is ready or a receive timeout expired, as EAGAIN does on POSIX.
pub const read = if (is_windows) recvWindows else posix.read;

/// `c.write`'s shape: bytes written, or -1 with the reason in `errno(-1)`.
pub const write = if (is_windows) sendWindows else c.write;

/// Close a descriptor.
pub const close = if (is_windows) closesocketWindows else c.close;

/// The reason the last `write` on this thread returned -1. On Windows the
/// Winsock error is folded onto the errno values callers test (AGAIN, INTR).
pub fn errno(rc: anytype) posix.E {
    if (is_windows) {
        if (rc != -1) return .SUCCESS;
        return switch (win.WSAGetLastError()) {
            win.WSAEWOULDBLOCK, win.WSAETIMEDOUT => .AGAIN,
            win.WSAEINTR => .INTR,
            else => .IO,
        };
    }
    return posix.errno(rc);
}

/// Make `fd` non-blocking.
pub fn setNonblock(fd: fd_t) void {
    if (is_windows) {
        var on: c_ulong = 1;
        _ = win.ioctlsocket(@bitCast(fd), win.FIONBIO, &on);
        return;
    }
    const fl = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
    _ = c.fcntl(fd, c.F.SETFL, fl | @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
}

/// Receive and send timeouts on a connected socket, in milliseconds.
pub fn setSockTimeouts(fd: fd_t, recv_ms: u32, send_ms: u32) void {
    if (is_windows) {
        // Winsock takes a DWORD of milliseconds, not a timeval.
        const r: u32 = recv_ms;
        const s: u32 = send_ms;
        _ = win.setsockopt(@bitCast(fd), win.SOL_SOCKET, win.SO_RCVTIMEO, @ptrCast(&r), @sizeOf(u32));
        _ = win.setsockopt(@bitCast(fd), win.SOL_SOCKET, win.SO_SNDTIMEO, @ptrCast(&s), @sizeOf(u32));
        return;
    }
    const rtv = c.timeval{ .sec = @intCast(recv_ms / 1000), .usec = @intCast((recv_ms % 1000) * 1000) };
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.RCVTIMEO, @ptrCast(&rtv), @sizeOf(c.timeval));
    const stv = c.timeval{ .sec = @intCast(send_ms / 1000), .usec = @intCast((send_ms % 1000) * 1000) };
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.SNDTIMEO, @ptrCast(&stv), @sizeOf(c.timeval));
}

/// Monotonic milliseconds.
pub fn monotonicMs() i64 {
    if (is_windows) {
        // QueryPerformanceCounter: GetTickCount64 ticks at ~15.6 ms, coarser
        // than the 8 ms frame pacing that reads this clock.
        var f: i64 = 0;
        var t: i64 = 0;
        _ = win.QueryPerformanceFrequency(&f);
        _ = win.QueryPerformanceCounter(&t);
        if (f <= 0) return @intCast(win.GetTickCount64());
        return @intCast(@divTrunc(@as(i128, t) * 1000, f));
    }
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @intCast(@as(i128, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000));
}

/// Sleep `ms` milliseconds.
pub fn sleepMs(ms: u32) void {
    if (is_windows) return win.Sleep(ms);
    var none = [_]posix.pollfd{};
    _ = posix.poll(&none, @intCast(ms)) catch {};
}

// ── Windows implementations ──────────────────────────────────────────────────

fn pollWindows(fds: []pollfd, timeout: i32) error{Unexpected}!usize {
    if (fds.len == 0) {
        if (timeout > 0) win.Sleep(@intCast(timeout));
        return 0;
    }
    netInit();
    const rc = win.WSAPoll(@ptrCast(fds.ptr), @intCast(fds.len), timeout);
    if (rc < 0) return error.Unexpected;
    return @intCast(rc);
}

pub const RecvError = error{ WouldBlock, ConnectionResetByPeer, InputOutput };

fn recvWindows(fd: fd_t, buf: []u8) RecvError!usize {
    const want: c_int = @intCast(@min(buf.len, std.math.maxInt(c_int)));
    const n = win.recv(@bitCast(fd), buf.ptr, want, 0);
    if (n >= 0) return @intCast(n);
    return switch (win.WSAGetLastError()) {
        win.WSAEWOULDBLOCK, win.WSAETIMEDOUT => error.WouldBlock,
        win.WSAECONNRESET, win.WSAECONNABORTED, win.WSAESHUTDOWN => error.ConnectionResetByPeer,
        else => error.InputOutput,
    };
}

fn sendWindows(fd: fd_t, buf: [*]const u8, len: usize) isize {
    const want: c_int = @intCast(@min(len, std.math.maxInt(c_int)));
    return win.send(@bitCast(fd), buf, want, 0);
}

fn closesocketWindows(fd: fd_t) c_int {
    return win.closesocket(@bitCast(fd));
}

var net_once = std.atomic.Value(u8).init(0);

/// WSAStartup, once per process. Every socket helper calls it, so no entry
/// point has to remember to.
pub fn netInit() void {
    if (!is_windows) return;
    if (net_once.load(.acquire) == 2) return;
    if (net_once.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
        var data: win.WSADATA = .{};
        _ = win.WSAStartup(0x0202, &data);
        net_once.store(2, .release);
        return;
    }
    while (net_once.load(.acquire) != 2) std.atomic.spinLoopHint();
}

/// Fill an AF_UNIX address. error.SocketPathTooLong when `path` (plus its
/// terminator) does not fit sun_path.
pub fn unixAddr(path: []const u8) error{SocketPathTooLong}!win.sockaddr_un {
    var addr: win.sockaddr_un = .{};
    if (path.len == 0 or path.len >= addr.path.len) return error.SocketPathTooLong;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

/// A listening AF_UNIX socket at `path`, replacing whatever file is there.
/// Windows: the socket file's ACL is inherited from its directory, which for
/// every path zterm uses (%TEMP%, the fleet home) is the user's own.
pub fn unixListen(path: []const u8) !fd_t {
    if (!is_windows) @compileError("unixListen is the Windows path; POSIX binds inline");
    netInit();
    const addr = try unixAddr(path);
    _ = deletePath(path);
    const s = win.socket(win.AF_UNIX, win.SOCK_STREAM, 0);
    if (s == win.INVALID_SOCKET) return error.SocketCreateFailed;
    errdefer _ = win.closesocket(s);
    if (win.bind(s, &addr, @sizeOf(win.sockaddr_un)) != 0) return error.BindFailed;
    if (win.listen(s, 16) != 0) return error.ListenFailed;
    return @bitCast(s);
}

/// A connected AF_UNIX socket to `path`.
pub fn unixConnect(path: []const u8) !fd_t {
    if (!is_windows) @compileError("unixConnect is the Windows path; POSIX connects inline");
    netInit();
    const addr = try unixAddr(path);
    const s = win.socket(win.AF_UNIX, win.SOCK_STREAM, 0);
    if (s == win.INVALID_SOCKET) return error.SocketCreateFailed;
    if (win.connect(s, &addr, @sizeOf(win.sockaddr_un)) != 0) {
        _ = win.closesocket(s);
        return error.ConnectFailed;
    }
    return @bitCast(s);
}

/// Accept a connection on a listening socket.
pub fn acceptConn(lfd: fd_t) !fd_t {
    if (!is_windows) @compileError("acceptConn is the Windows path");
    const s = win.accept(@bitCast(lfd), null, null);
    if (s == win.INVALID_SOCKET) return error.AcceptFailed;
    return @bitCast(s);
}

/// Remove a file by UTF-8 path; a missing file is not an error. Returns
/// false when the file exists and could not be removed.
pub fn deletePath(path: []const u8) bool {
    if (!is_windows) @compileError("deletePath is the Windows path");
    var wbuf: [1024]u16 = undefined;
    const w = toWide(&wbuf, path) orelse return false;
    if (win.DeleteFileW(w) != 0) return true;
    const e = win.GetLastError();
    return e == win.ERROR_FILE_NOT_FOUND or e == win.ERROR_PATH_NOT_FOUND;
}

/// Whether a UTF-8 path names an existing directory.
pub fn isDirectoryW(path: []const u8) bool {
    if (!is_windows) @compileError("isDirectoryW is the Windows path");
    var wbuf: [1024]u16 = undefined;
    const w = toWide(&wbuf, path) orelse return false;
    const a = win.GetFileAttributesW(w);
    return a != win.INVALID_FILE_ATTRIBUTES and (a & win.FILE_ATTRIBUTE_DIRECTORY) != 0;
}

/// Create a directory by UTF-8 path (an existing one is fine).
pub fn makeDir(path: []const u8) void {
    if (!is_windows) @compileError("makeDir is the Windows path");
    var wbuf: [1024]u16 = undefined;
    const w = toWide(&wbuf, path) orelse return;
    _ = win.CreateDirectoryW(w, null);
}

/// UTF-8 → NUL-terminated UTF-16 in `buf`, or null if it does not fit or is
/// not valid UTF-8.
pub fn toWide(buf: []u16, s: []const u8) ?[:0]const u16 {
    if (s.len >= buf.len) return null;
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], s) catch return null;
    if (n >= buf.len) return null;
    buf[n] = 0;
    return buf[0..n :0];
}

var env_cache_mutex: std.atomic.Value(bool) = .init(false);
var env_cache: std.StringHashMapUnmanaged([:0]u8) = .empty;

/// An environment variable as UTF-8, or null when unset or empty. POSIX:
/// libc's getenv. Windows: GetEnvironmentVariableW, converted once per name
/// and kept for the process lifetime (the CRT's getenv speaks the ANSI code
/// page, which mangles a non-ASCII profile path).
pub fn getenv(name: [:0]const u8) ?[]const u8 {
    if (!is_windows) {
        const v = c.getenv(name.ptr) orelse return null;
        const s = std.mem.sliceTo(v, 0);
        return if (s.len == 0) null else s;
    }
    while (env_cache_mutex.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer env_cache_mutex.store(false, .release);
    if (env_cache.get(name)) |v| return if (v.len == 0) null else v;
    var wname: [256]u16 = undefined;
    const wn = toWide(&wname, name) orelse return null;
    const alloc = std.heap.c_allocator;
    const need = win.GetEnvironmentVariableW(wn, null, 0);
    if (need == 0) return null;
    const wbuf = alloc.alloc(u16, need) catch return null;
    defer alloc.free(wbuf);
    const got = win.GetEnvironmentVariableW(wn, wbuf.ptr, need);
    if (got == 0 or got >= need) return null;
    const utf8 = std.unicode.utf16LeToUtf8AllocZ(alloc, wbuf[0..got]) catch return null;
    const key = alloc.dupe(u8, name) catch return utf8;
    env_cache.put(alloc, key, utf8) catch {};
    return if (utf8.len == 0) null else utf8;
}

/// A process id: POSIX pid_t, a Windows DWORD process id.
pub const pid_t = if (is_windows) u32 else posix.pid_t;

/// This process's id.
pub fn selfPid() pid_t {
    if (is_windows) return win.GetCurrentProcessId();
    return std.c.getpid();
}
