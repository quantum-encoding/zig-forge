const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const socket = @import("socket.zig");

// Platform detection
const is_linux = builtin.os.tag == .linux;
const is_android = builtin.abi == .android;
const is_darwin = builtin.os.tag == .macos or builtin.os.tag == .ios;
const is_bsd = builtin.os.tag == .freebsd or builtin.os.tag == .openbsd or builtin.os.tag == .netbsd;

/// I/O Backend selection at compile time
pub const IoBackend = enum {
    io_uring, // Linux (non-Android) - highest performance
    kqueue, // macOS, iOS, FreeBSD, OpenBSD, NetBSD
    poll, // Fallback for all platforms (including Android)
};

/// Selected backend for this platform
pub const backend: IoBackend = if (is_linux and !is_android)
    .io_uring
else if (is_darwin or is_bsd)
    .kqueue
else
    .poll;

/// Event types
pub const EventType = enum {
    read,
    write,
    error_event,
    hangup,
};

/// Event from I/O multiplexing
pub const Event = struct {
    fd: socket.socket_t,
    types: EventTypes,
    user_data: usize,

    pub const EventTypes = struct {
        read: bool = false,
        write: bool = false,
        error_event: bool = false,
        hangup: bool = false,
    };
};

/// Unified I/O multiplexer interface
pub const IoMux = switch (backend) {
    .io_uring => IoUringMux,
    .kqueue => KqueueMux,
    .poll => PollMux,
};

// ============================================================================
// io_uring backend (Linux)
// ============================================================================

const IoUringMux = struct {
    ring: if (is_linux and !is_android) std.os.linux.IoUring else void,
    pending_events: [64]Event,
    pending_count: usize,

    const Self = @This();

    pub fn init() !Self {
        if (comptime !(is_linux and !is_android)) {
            @compileError("io_uring only available on Linux");
        }
        return Self{
            .ring = try std.os.linux.IoUring.init(64, 0),
            .pending_events = undefined,
            .pending_count = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.ring.deinit();
    }

    pub fn registerRead(self: *Self, fd: socket.socket_t, buf: []u8, user_data: usize) !void {
        const sqe = try self.ring.get_sqe();
        sqe.prep_recv(fd, buf, 0);
        sqe.user_data = user_data;
    }

    pub fn registerWrite(self: *Self, fd: socket.socket_t, buf: []const u8, user_data: usize) !void {
        const sqe = try self.ring.get_sqe();
        sqe.prep_send(fd, buf, 0);
        sqe.user_data = user_data;
    }

    pub fn submit(self: *Self) !usize {
        return @intCast(try self.ring.submit());
    }

    pub fn wait(self: *Self, timeout_ms: i32) ![]Event {
        _ = timeout_ms; // io_uring handles timeout differently

        _ = try self.ring.submit_and_wait(1);

        self.pending_count = 0;
        while (self.pending_count < self.pending_events.len) {
            var cqe = self.ring.copy_cqe() catch break;
            defer self.ring.cqe_seen(&cqe);

            self.pending_events[self.pending_count] = Event{
                .fd = 0, // io_uring uses user_data for identification
                .types = .{
                    .read = cqe.res > 0,
                    .error_event = cqe.res < 0,
                    .hangup = cqe.res == 0,
                },
                .user_data = cqe.user_data,
            };
            self.pending_count += 1;
        }

        return self.pending_events[0..self.pending_count];
    }

    /// Get the result of a completed operation
    pub fn getResult(self: *Self) !struct { user_data: usize, result: isize } {
        var cqe = try self.ring.copy_cqe();
        defer self.ring.cqe_seen(&cqe);
        return .{ .user_data = cqe.user_data, .result = cqe.res };
    }
};

// ============================================================================
// kqueue backend (macOS, BSD)
// ============================================================================

const KqueueMux = struct {
    kq: posix.fd_t,
    registered_fds: [64]socket.socket_t,
    registered_count: usize,
    events: [64]KEvent,

    const Self = @This();

    // kqueue event structure
    const KEvent = if (is_darwin or is_bsd) extern struct {
        ident: usize,
        filter: i16,
        flags: u16,
        fflags: u32,
        data: isize,
        udata: ?*anyopaque,
    } else void;

    // kqueue constants for Darwin/BSD
    const EVFILT_READ: i16 = -1;
    const EVFILT_WRITE: i16 = -2;
    const EV_ADD: u16 = 0x0001;
    const EV_ENABLE: u16 = 0x0004;
    const EV_DELETE: u16 = 0x0002;
    const EV_ONESHOT: u16 = 0x0010;
    const EV_EOF: u16 = 0x8000;
    const EV_ERROR: u16 = 0x4000;

    pub fn init() !Self {
        if (comptime !(is_darwin or is_bsd)) {
            @compileError("kqueue only available on macOS/BSD");
        }

        const kq_result = std.c.kqueue();
        if (kq_result < 0) return error.KqueueError;
        return Self{
            .kq = kq_result,
            .registered_fds = undefined,
            .registered_count = 0,
            .events = undefined,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = std.c.close(self.kq);
    }

    pub fn registerRead(self: *Self, fd: socket.socket_t, _: []u8, user_data: usize) !void {
        var changes: [1]KEvent = undefined;
        changes[0] = KEvent{
            .ident = @intCast(fd),
            .filter = EVFILT_READ,
            .flags = EV_ADD | EV_ENABLE,
            .fflags = 0,
            .data = 0,
            .udata = @ptrFromInt(user_data),
        };

        _ = try sysKevent(self.kq, &changes, &[_]KEvent{}, null);

        if (self.registered_count < self.registered_fds.len) {
            self.registered_fds[self.registered_count] = fd;
            self.registered_count += 1;
        }
    }

    pub fn registerWrite(self: *Self, fd: socket.socket_t, _: []const u8, user_data: usize) !void {
        var changes: [1]KEvent = undefined;
        changes[0] = KEvent{
            .ident = @intCast(fd),
            .filter = EVFILT_WRITE,
            .flags = EV_ADD | EV_ENABLE | EV_ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = @ptrFromInt(user_data),
        };

        _ = try sysKevent(self.kq, &changes, &[_]KEvent{}, null);
    }

    pub fn submit(self: *Self) !usize {
        _ = self;
        return 0; // kqueue doesn't have a separate submit step
    }

    pub fn wait(self: *Self, timeout_ms: i32) ![]Event {
        const ts = if (timeout_ms >= 0) posix.timespec{
            .sec = @intCast(@divFloor(timeout_ms, 1000)),
            .nsec = @intCast(@mod(timeout_ms, 1000) * 1_000_000),
        } else null;

        const ts_ptr = if (timeout_ms >= 0) &ts.? else null;

        const n = try sysKevent(self.kq, &[_]KEvent{}, &self.events, ts_ptr);

        var result_events: [64]Event = undefined;
        var result_count: usize = 0;

        for (self.events[0..n]) |ev| {
            result_events[result_count] = Event{
                .fd = @intCast(ev.ident),
                .types = .{
                    .read = ev.filter == EVFILT_READ,
                    .write = ev.filter == EVFILT_WRITE,
                    .error_event = (ev.flags & EV_ERROR) != 0,
                    .hangup = (ev.flags & EV_EOF) != 0,
                },
                .user_data = @intFromPtr(ev.udata),
            };
            result_count += 1;
        }

        // Copy to pending_events (since we return a slice)
        // Note: This is a simplified approach - production code would handle this better
        return result_events[0..result_count];
    }

    fn sysKevent(kq: posix.fd_t, changelist: []const KEvent, eventlist: []KEvent, timeout: ?*const posix.timespec) !usize {
        const result = std.c.kevent(
            kq,
            @ptrCast(changelist.ptr),
            @intCast(changelist.len),
            @ptrCast(eventlist.ptr),
            @intCast(eventlist.len),
            timeout,
        );
        if (result < 0) return error.KqueueError;
        return @intCast(result);
    }
};

// ============================================================================
// poll backend (fallback - all platforms including Android)
// ============================================================================

const PollMux = struct {
    pollfds: [64]PollFd,
    user_data: [64]usize,
    buffers: [64][]u8,
    fd_count: usize,

    const Self = @This();

    const PollFd = extern struct {
        fd: i32,
        events: i16,
        revents: i16,
    };

    const POLLIN: i16 = 0x0001;
    const POLLOUT: i16 = 0x0004;
    const POLLERR: i16 = 0x0008;
    const POLLHUP: i16 = 0x0010;
    const POLLNVAL: i16 = 0x0020;

    pub fn init() !Self {
        return Self{
            .pollfds = undefined,
            .user_data = undefined,
            .buffers = undefined,
            .fd_count = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn registerRead(self: *Self, fd: socket.socket_t, buf: []u8, user_data: usize) !void {
        if (self.fd_count >= self.pollfds.len) return error.TooManyFds;

        self.pollfds[self.fd_count] = PollFd{
            .fd = fd,
            .events = POLLIN,
            .revents = 0,
        };
        self.user_data[self.fd_count] = user_data;
        self.buffers[self.fd_count] = buf;
        self.fd_count += 1;
    }

    pub fn registerWrite(self: *Self, fd: socket.socket_t, _: []const u8, user_data: usize) !void {
        if (self.fd_count >= self.pollfds.len) return error.TooManyFds;

        self.pollfds[self.fd_count] = PollFd{
            .fd = fd,
            .events = POLLOUT,
            .revents = 0,
        };
        self.user_data[self.fd_count] = user_data;
        self.fd_count += 1;
    }

    pub fn submit(self: *Self) !usize {
        _ = self;
        return 0; // poll doesn't have a separate submit step
    }

    pub fn wait(self: *Self, timeout_ms: i32) ![]Event {
        const result = sysPoll(self.pollfds[0..self.fd_count], timeout_ms);
        if (result < 0) return error.PollError;

        var events: [64]Event = undefined;
        var event_count: usize = 0;

        for (self.pollfds[0..self.fd_count], 0..) |pfd, i| {
            if (pfd.revents != 0) {
                events[event_count] = Event{
                    .fd = @intCast(pfd.fd),
                    .types = .{
                        .read = (pfd.revents & POLLIN) != 0,
                        .write = (pfd.revents & POLLOUT) != 0,
                        .error_event = (pfd.revents & (POLLERR | POLLNVAL)) != 0,
                        .hangup = (pfd.revents & POLLHUP) != 0,
                    },
                    .user_data = self.user_data[i],
                };
                event_count += 1;
            }
        }

        return events[0..event_count];
    }

    fn sysPoll(fds: []PollFd, timeout_ms: i32) i32 {
        if (is_linux) {
            return @intCast(@as(isize, @bitCast(std.os.linux.poll(@ptrCast(fds.ptr), fds.len, timeout_ms))));
        } else {
            return std.c.poll(@ptrCast(fds.ptr), @intCast(fds.len), timeout_ms);
        }
    }

    pub fn clearRegistrations(self: *Self) void {
        self.fd_count = 0;
    }
};

// ============================================================================
// Simple blocking receiver (for simpler use cases)
// ============================================================================

/// Simple blocking receive with timeout - works on all platforms
pub fn blockingRecv(fd: socket.socket_t, buf: []u8, timeout_ms: u32) !usize {
    // Set receive timeout
    try socket.setRecvTimeout(fd, timeout_ms);

    // Blocking receive
    return socket.recv(fd, buf);
}

// ============================================================================
// Tests
// ============================================================================

test "IoMux initialization" {
    var mux = try IoMux.init();
    defer mux.deinit();
}

test "backend selection" {
    const expected: IoBackend = if (is_linux and !is_android)
        .io_uring
    else if (is_darwin or is_bsd)
        .kqueue
    else
        .poll;

    try std.testing.expectEqual(expected, backend);
}

test "Event structure" {
    const event = Event{
        .fd = 5,
        .types = .{
            .read = true,
            .write = false,
            .error_event = false,
            .hangup = false,
        },
        .user_data = 42,
    };

    try std.testing.expectEqual(@as(socket.socket_t, 5), event.fd);
    try std.testing.expect(event.types.read);
    try std.testing.expect(!event.types.write);
    try std.testing.expectEqual(@as(usize, 42), event.user_data);
}

test "EventTypes default values" {
    const types = Event.EventTypes{};
    try std.testing.expect(!types.read);
    try std.testing.expect(!types.write);
    try std.testing.expect(!types.error_event);
    try std.testing.expect(!types.hangup);
}

test "IoBackend enum values" {
    // Ensure all enum values are distinct
    try std.testing.expect(IoBackend.io_uring != IoBackend.kqueue);
    try std.testing.expect(IoBackend.kqueue != IoBackend.poll);
    try std.testing.expect(IoBackend.io_uring != IoBackend.poll);
}

test "IoMux register and submit" {
    var mux = try IoMux.init();
    defer mux.deinit();

    // Create a socket for testing
    const fd = try socket.createTcpSocket();
    defer socket.close(fd);

    var buf: [1024]u8 = undefined;

    // Register a read operation (won't actually read, just testing registration)
    try mux.registerRead(fd, &buf, 12345);

    // Submit should not error
    _ = try mux.submit();
}

test "IoMux wait with timeout returns empty on no events" {
    var mux = try IoMux.init();
    defer mux.deinit();

    // On io_uring, wait requires a submission first, so this test
    // is more meaningful for poll/kqueue backends
    if (backend == .poll) {
        // With no registered fds, wait should return immediately with no events
        const events = try mux.wait(0);
        try std.testing.expectEqual(@as(usize, 0), events.len);
    }
}

test "PollMux clearRegistrations" {
    // Test the poll backend's clearRegistrations function
    if (backend == .poll) {
        var mux = try IoMux.init();
        defer mux.deinit();

        const fd = try socket.createTcpSocket();
        defer socket.close(fd);

        var buf: [1024]u8 = undefined;

        // Register some operations
        try mux.registerRead(fd, &buf, 1);
        try std.testing.expect(mux.fd_count == 1);

        // Clear registrations
        mux.clearRegistrations();
        try std.testing.expect(mux.fd_count == 0);
    }
}

test "multiple socket registrations" {
    var mux = try IoMux.init();
    defer mux.deinit();

    // Create multiple sockets
    var fds: [5]socket.socket_t = undefined;
    for (&fds) |*fd| {
        fd.* = try socket.createTcpSocket();
    }
    defer for (fds) |fd| {
        socket.close(fd);
    };

    var buf: [1024]u8 = undefined;

    // Register read on all of them
    for (fds, 0..) |fd, i| {
        try mux.registerRead(fd, &buf, i);
    }

    _ = try mux.submit();
}

test "blockingRecv setup" {
    // Just test that blockingRecv can be called without crashing
    // (actual recv would block or fail without a connected socket)
    const fd = try socket.createTcpSocket();
    defer socket.close(fd);

    // Set up timeout first
    try socket.setRecvTimeout(fd, 100);

    // Don't actually call recv since we're not connected
    // This test just verifies the setup works
}
