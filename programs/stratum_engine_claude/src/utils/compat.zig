//! Compatibility utilities for Zig 0.16+
//! Provides consistent APIs across Zig versions.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

// Socket helper functions for Zig 0.16.2187+
pub fn createSocket(sock_type: u32) !posix.fd_t {
    const result = linux.socket(linux.AF.INET, sock_type, linux.IPPROTO.TCP);
    if (@as(isize, @bitCast(result)) < 0) return error.SocketCreationFailed;
    return @intCast(result);
}

pub fn closeSocket(fd: posix.fd_t) void {
    _ = linux.close(@intCast(fd));
}

pub fn connectSocket(fd: posix.fd_t, addr: *const anyopaque, addrlen: linux.socklen_t) !void {
    const result = linux.connect(@intCast(fd), @ptrCast(@alignCast(addr)), addrlen);
    if (@as(isize, @bitCast(result)) < 0) return error.ConnectionFailed;
}

pub fn sendSocket(fd: posix.fd_t, buf: []const u8) !usize {
    const result = linux.sendto(@intCast(fd), buf.ptr, buf.len, 0, null, 0);
    if (@as(isize, @bitCast(result)) < 0) return error.SendFailed;
    return result;
}

pub fn recvSocket(fd: posix.fd_t, buf: []u8) !usize {
    const result = linux.recvfrom(@intCast(fd), buf.ptr, buf.len, 0, null, null);
    if (@as(isize, @bitCast(result)) < 0) return error.RecvFailed;
    return result;
}

pub fn bindSocket(fd: posix.fd_t, addr: *const anyopaque, addrlen: linux.socklen_t) !void {
    const result = linux.bind(@intCast(fd), @ptrCast(@alignCast(addr)), addrlen);
    if (@as(isize, @bitCast(result)) < 0) return error.BindFailed;
}

pub fn listenSocket(fd: posix.fd_t, backlog: u31) !void {
    const result = linux.listen(@intCast(fd), backlog);
    if (@as(isize, @bitCast(result)) < 0) return error.ListenFailed;
}

pub fn acceptSocket(fd: posix.fd_t, addr: ?*anyopaque, addrlen: ?*linux.socklen_t) !posix.fd_t {
    const result = linux.accept(@intCast(fd), @ptrCast(@alignCast(addr)), @ptrCast(addrlen));
    if (@as(isize, @bitCast(result)) < 0) return error.AcceptFailed;
    return @intCast(result);
}

/// Get current Unix timestamp in seconds
pub fn timestamp() i64 {
    var ts: posix.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return ts.sec;
}

/// Get current Unix timestamp in milliseconds
pub fn timestampMs() i64 {
    var ts: posix.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

/// Simple buffer writer that appends to a slice
pub const BufferWriter = struct {
    buffer: []u8,
    pos: usize,

    pub fn init(buffer: []u8) BufferWriter {
        return .{ .buffer = buffer, .pos = 0 };
    }

    pub fn write(self: *BufferWriter, data: []const u8) !void {
        if (self.pos + data.len > self.buffer.len) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    pub fn writeByte(self: *BufferWriter, byte: u8) !void {
        if (self.pos >= self.buffer.len) return error.NoSpaceLeft;
        self.buffer[self.pos] = byte;
        self.pos += 1;
    }

    pub fn getWritten(self: *const BufferWriter) []const u8 {
        return self.buffer[0..self.pos];
    }
};
