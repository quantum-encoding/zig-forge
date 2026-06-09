// Reactor — readiness event loop.
//
// macOS/BSD: kqueue (this build). The interface (addRead / enableWrite / del /
// poll) is deliberately backend-agnostic so a Linux epoll (and later io_uring)
// backend can drop in behind the same shape — only this file changes.
//
// Design notes:
//  - Read filters are level-triggered persistent (EV.ADD|ENABLE): we get
//    notified whenever a registered fd is readable, and drain it to EAGAIN.
//  - Write filters are ONESHOT: we only arm a write filter when a socket write
//    returned EAGAIN, and it auto-disarms after firing once, so an idle
//    keep-alive connection never sits in the writable set burning wakeups.
//  - `udata` carries a tagged pointer to the connection (or 0 for a listener),
//    so event dispatch is O(1) with no fd→object map.

const std = @import("std");
const c = std.c;
const posix = std.posix;

pub const Event = struct {
    udata: usize,
    filter: i16,
    flags: u16,
    /// Bytes available (read) / writable (write), or error code on EV.ERROR.
    data: isize,

    pub fn isRead(self: Event) bool {
        return self.filter == c.EVFILT.READ;
    }
    pub fn isWrite(self: Event) bool {
        return self.filter == c.EVFILT.WRITE;
    }
    pub fn isEof(self: Event) bool {
        return (self.flags & c.EV.EOF) != 0;
    }
    pub fn isError(self: Event) bool {
        return (self.flags & EV_ERROR) != 0;
    }
};

// EV.ERROR isn't in the std EV struct for macOS; it's 0x4000.
const EV_ERROR: u16 = 0x4000;

pub const Reactor = struct {
    kq: i32,

    pub fn init() !Reactor {
        const kq = c.kqueue();
        if (kq < 0) return error.KqueueFailed;
        return .{ .kq = @intCast(kq) };
    }

    pub fn deinit(self: *Reactor) void {
        _ = c.close(self.kq);
    }

    fn change(self: *Reactor, ident: i32, filter: i16, flags: u16, udata: usize) !void {
        const ev = c.Kevent{
            .ident = @intCast(ident),
            .filter = filter,
            .flags = flags,
            .fflags = 0,
            .data = 0,
            .udata = udata,
        };
        var ev_arr: [1]c.Kevent = .{ev};
        // eventlist must be a valid pointer even with nevents=0 — reuse ev_arr.
        const r = c.kevent(self.kq, &ev_arr, 1, &ev_arr, 0, null);
        if (r < 0) return error.KeventFailed;
    }

    /// Register (or re-arm) a persistent read filter on `fd`.
    pub fn addRead(self: *Reactor, fd: i32, udata: usize) !void {
        try self.change(fd, c.EVFILT.READ, c.EV.ADD | c.EV.ENABLE, udata);
    }

    /// Arm a one-shot write filter on `fd` (used only when a write blocked).
    pub fn enableWrite(self: *Reactor, fd: i32, udata: usize) !void {
        try self.change(fd, c.EVFILT.WRITE, c.EV.ADD | c.EV.ENABLE | c.EV.ONESHOT, udata);
    }

    /// Drop a connection's filters. Deleting the read filter is enough — the
    /// write filter is one-shot and self-clears; closing the fd removes the
    /// rest from the kqueue automatically.
    pub fn del(self: *Reactor, fd: i32) void {
        self.change(fd, c.EVFILT.READ, c.EV.DELETE, 0) catch {};
    }

    /// Wait for events. `timeout_ms < 0` blocks indefinitely. Returns the
    /// number of events written into `out`. EINTR is reported as 0 events.
    pub fn poll(self: *Reactor, out: []c.Kevent, timeout_ms: i32) usize {
        var ts: c.timespec = undefined;
        const tsp: ?*const c.timespec = if (timeout_ms < 0) null else blk: {
            ts = .{
                .sec = @divTrunc(timeout_ms, 1000),
                .nsec = @as(@TypeOf(ts.nsec), @intCast(@mod(timeout_ms, 1000))) * 1_000_000,
            };
            break :blk &ts;
        };
        // changelist must be a valid pointer even with nchanges=0 — reuse out.
        const n = c.kevent(self.kq, out.ptr, 0, out.ptr, @intCast(out.len), tsp);
        if (n < 0) return 0; // EINTR or transient — caller loops again
        return @intCast(n);
    }

    /// Decode a raw kevent into the backend-agnostic Event shape.
    pub fn decode(kev: c.Kevent) Event {
        return .{ .udata = kev.udata, .filter = kev.filter, .flags = kev.flags, .data = kev.data };
    }
};
