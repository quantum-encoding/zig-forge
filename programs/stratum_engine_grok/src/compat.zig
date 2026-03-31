//! Socket compatibility helpers for Zig 0.16.2187+
//! These wrappers provide socket operations using linux syscalls
//! since std.posix.socket/connect/etc were removed

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// Create a TCP socket using linux syscalls
pub fn createSocket(sock_type: u32) !posix.fd_t {
    const result = linux.socket(linux.AF.INET, sock_type, linux.IPPROTO.TCP);
    if (@as(isize, @bitCast(result)) < 0) {
        return error.SocketCreationFailed;
    }
    return @intCast(result);
}

/// Close a socket
pub fn closeSocket(fd: posix.fd_t) void {
    _ = linux.close(@intCast(fd));
}

/// Connect to a remote address
pub fn connectSocket(fd: posix.fd_t, addr: *const anyopaque, addrlen: linux.socklen_t) !void {
    const result = linux.connect(@intCast(fd), @ptrCast(@alignCast(addr)), addrlen);
    if (@as(isize, @bitCast(result)) < 0) {
        return error.ConnectionFailed;
    }
}

/// Send data on a connected socket
pub fn sendSocket(fd: posix.fd_t, buf: []const u8) !usize {
    const result = linux.sendto(@intCast(fd), buf.ptr, buf.len, 0, null, 0);
    if (@as(isize, @bitCast(result)) < 0) {
        return error.SendFailed;
    }
    return result;
}

/// Receive data from a connected socket
pub fn recvSocket(fd: posix.fd_t, buf: []u8) !usize {
    const result = linux.recvfrom(@intCast(fd), buf.ptr, buf.len, 0, null, null);
    if (@as(isize, @bitCast(result)) < 0) {
        return error.RecvFailed;
    }
    return result;
}

/// Bind a socket to a local address
pub fn bindSocket(fd: posix.fd_t, addr: *const anyopaque, addrlen: linux.socklen_t) !void {
    const result = linux.bind(@intCast(fd), @ptrCast(@alignCast(addr)), addrlen);
    if (@as(isize, @bitCast(result)) < 0) {
        return error.BindFailed;
    }
}

/// Listen for incoming connections
pub fn listenSocket(fd: posix.fd_t, backlog: u31) !void {
    const result = linux.listen(@intCast(fd), backlog);
    if (@as(isize, @bitCast(result)) < 0) {
        return error.ListenFailed;
    }
}

/// Accept an incoming connection
pub fn acceptSocket(fd: posix.fd_t, addr: ?*anyopaque, addrlen: ?*linux.socklen_t) !posix.fd_t {
    const result = linux.accept4(
        @intCast(fd),
        @ptrCast(@alignCast(addr)),
        addrlen,
        0,
    );
    if (@as(isize, @bitCast(result)) < 0) {
        return error.AcceptFailed;
    }
    return @intCast(result);
}
