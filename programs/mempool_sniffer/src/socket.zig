const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

// Platform-specific imports
const is_linux = builtin.os.tag == .linux;
const is_darwin = builtin.os.tag == .macos or builtin.os.tag == .ios;
const is_bsd = builtin.os.tag == .freebsd or builtin.os.tag == .openbsd or builtin.os.tag == .netbsd;

// Use system-specific socket types
pub const socket_t = posix.socket_t;
pub const fd_t = posix.fd_t;

// Address family constants
pub const AF = struct {
    pub const INET: u32 = if (is_darwin or is_bsd) 2 else if (is_linux) std.os.linux.AF.INET else 2;
    pub const INET6: u32 = if (is_darwin or is_bsd) 30 else if (is_linux) std.os.linux.AF.INET6 else 10;
};

// Socket type constants
pub const SOCK = struct {
    pub const STREAM: u32 = if (is_darwin or is_bsd) 1 else if (is_linux) std.os.linux.SOCK.STREAM else 1;
    pub const DGRAM: u32 = if (is_darwin or is_bsd) 2 else if (is_linux) std.os.linux.SOCK.DGRAM else 2;
    pub const NONBLOCK: u32 = if (is_darwin or is_bsd) 0 else if (is_linux) std.os.linux.SOCK.NONBLOCK else 0;
};

// Protocol constants
pub const IPPROTO = struct {
    pub const TCP: u32 = 6;
    pub const UDP: u32 = 17;
};

// IPv4 socket address
pub const sockaddr_in = extern struct {
    // Darwin/BSD use different struct layout
    len: if (is_darwin or is_bsd) u8 else void = if (is_darwin or is_bsd) @sizeOf(sockaddr_in) else {},
    family: if (is_darwin or is_bsd) u8 else u16,
    port: u16, // Network byte order (big-endian)
    addr: u32, // Network byte order (big-endian)
    zero: [8]u8 = [_]u8{0} ** 8,
};

pub const SocketError = error{
    SocketCreationFailed,
    ConnectionFailed,
    SendFailed,
    RecvFailed,
    BindFailed,
    ListenFailed,
    AcceptFailed,
    SetOptFailed,
    WouldBlock,
    ConnectionReset,
    ConnectionRefused,
    TimedOut,
    InvalidAddress,
};

// Platform-specific socket syscalls
fn sysSocket(domain: u32, sock_type: u32, protocol: u32) i32 {
    if (is_linux) {
        return @truncate(@as(isize, @bitCast(std.os.linux.socket(domain, sock_type, protocol))));
    } else {
        // Darwin/BSD/other POSIX
        return std.c.socket(@intCast(domain), @intCast(sock_type), @intCast(protocol));
    }
}

fn sysConnect(fd: fd_t, addr: *const anyopaque, addrlen: u32) isize {
    if (is_linux) {
        return @bitCast(std.os.linux.connect(@intCast(fd), @ptrCast(@alignCast(addr)), addrlen));
    } else {
        return std.c.connect(fd, @ptrCast(@alignCast(addr)), addrlen);
    }
}

fn sysSend(fd: fd_t, buf: []const u8, flags: u32) isize {
    if (is_linux) {
        return @bitCast(std.os.linux.sendto(@intCast(fd), buf.ptr, buf.len, flags, null, 0));
    } else {
        return std.c.send(fd, buf.ptr, buf.len, @intCast(flags));
    }
}

fn sysRecv(fd: fd_t, buf: []u8, flags: u32) isize {
    if (is_linux) {
        return @bitCast(std.os.linux.recvfrom(@intCast(fd), buf.ptr, buf.len, flags, null, null));
    } else {
        return std.c.recv(fd, buf.ptr, buf.len, @intCast(flags));
    }
}

fn sysClose(fd: fd_t) void {
    if (is_linux) {
        _ = std.os.linux.close(@intCast(fd));
    } else {
        _ = std.c.close(fd);
    }
}

fn sysSetSockOpt(fd: fd_t, level: i32, optname: i32, optval: *const anyopaque, optlen: u32) i32 {
    if (is_linux) {
        const opt_ptr: [*]const u8 = @ptrCast(optval);
        return @truncate(@as(isize, @bitCast(std.os.linux.setsockopt(@intCast(fd), @intCast(level), @intCast(optname), opt_ptr, optlen))));
    } else {
        return std.c.setsockopt(fd, level, @intCast(optname), optval, optlen);
    }
}

// Public API

/// Create a TCP socket
pub fn createTcpSocket() SocketError!socket_t {
    const result = sysSocket(AF.INET, SOCK.STREAM, IPPROTO.TCP);
    if (result < 0) return SocketError.SocketCreationFailed;
    return result;
}

/// Create a TCP socket with non-blocking mode (Linux only via SOCK_NONBLOCK)
pub fn createTcpSocketNonblock() SocketError!socket_t {
    const flags = if (is_linux) SOCK.STREAM | SOCK.NONBLOCK else SOCK.STREAM;
    const result = sysSocket(AF.INET, flags, IPPROTO.TCP);
    if (result < 0) return SocketError.SocketCreationFailed;

    // For non-Linux, set non-blocking via fcntl
    if (!is_linux) {
        const fd: fd_t = result;
        const O_NONBLOCK: c_uint = if (is_darwin or is_bsd) 0x0004 else 0o4000;
        if (std.c.fcntl(fd, std.c.F.SETFL, O_NONBLOCK) < 0) {
            sysClose(fd);
            return SocketError.SocketCreationFailed;
        }
    }

    return result;
}

/// Close a socket
pub fn close(fd: socket_t) void {
    sysClose(fd);
}

/// Connect to an IPv4 address
pub fn connect(fd: socket_t, ip_parts: [4]u8, port: u16) SocketError!void {
    var addr: sockaddr_in = undefined;

    if (is_darwin or is_bsd) {
        addr.len = @sizeOf(sockaddr_in);
        addr.family = @intCast(AF.INET);
    } else {
        addr.family = @intCast(AF.INET);
    }

    addr.port = std.mem.nativeToBig(u16, port);
    addr.addr = std.mem.nativeToBig(u32, (@as(u32, ip_parts[0]) << 24) | (@as(u32, ip_parts[1]) << 16) | (@as(u32, ip_parts[2]) << 8) | ip_parts[3]);
    addr.zero = [_]u8{0} ** 8;

    const result = sysConnect(fd, &addr, @sizeOf(sockaddr_in));
    if (result < 0) {
        const errno_val: u16 = if (is_linux) @intCast(@as(usize, @bitCast(-result))) else @intCast(std.c._errno().*);
        // Common errno values: ECONNREFUSED=111, ETIMEDOUT=110, EINPROGRESS=115
        return switch (errno_val) {
            111 => SocketError.ConnectionRefused, // ECONNREFUSED
            110 => SocketError.TimedOut, // ETIMEDOUT
            115 => {}, // EINPROGRESS - non-blocking connect in progress
            else => SocketError.ConnectionFailed,
        };
    }
}

/// Connect to an IPv4 address from string
pub fn connectFromString(fd: socket_t, ip_str: []const u8, port: u16) SocketError!void {
    var ip_parts: [4]u8 = undefined;
    var iter = std.mem.splitScalar(u8, ip_str, '.');
    var idx: usize = 0;

    while (iter.next()) |part| : (idx += 1) {
        if (idx >= 4) return SocketError.InvalidAddress;
        ip_parts[idx] = std.fmt.parseInt(u8, part, 10) catch return SocketError.InvalidAddress;
    }
    if (idx != 4) return SocketError.InvalidAddress;

    return connect(fd, ip_parts, port);
}

/// Send data on a socket
pub fn send(fd: socket_t, buf: []const u8) SocketError!usize {
    const result = sysSend(fd, buf, 0);
    if (result < 0) return SocketError.SendFailed;
    return @intCast(result);
}

/// Receive data from a socket
pub fn recv(fd: socket_t, buf: []u8) SocketError!usize {
    const result = sysRecv(fd, buf, 0);
    if (result < 0) {
        const errno_val: u16 = if (is_linux) @intCast(@as(usize, @bitCast(-result))) else @intCast(std.c._errno().*);
        // EAGAIN=11, EWOULDBLOCK=11, ECONNRESET=104
        return switch (errno_val) {
            11 => SocketError.WouldBlock, // EAGAIN/EWOULDBLOCK
            104 => SocketError.ConnectionReset, // ECONNRESET
            else => SocketError.RecvFailed,
        };
    }
    return @intCast(result);
}

/// Receive data from a socket (non-blocking)
pub fn recvNonblock(fd: socket_t, buf: []u8) SocketError!usize {
    const MSG_DONTWAIT: u32 = if (is_linux) 0x40 else 0x80;
    const result = sysRecv(fd, buf, MSG_DONTWAIT);
    if (result < 0) {
        const errno_val: u16 = if (is_linux) @intCast(@as(usize, @bitCast(-result))) else @intCast(std.c._errno().*);
        // EAGAIN=11, EWOULDBLOCK=11, ECONNRESET=104
        return switch (errno_val) {
            11 => SocketError.WouldBlock, // EAGAIN/EWOULDBLOCK
            104 => SocketError.ConnectionReset, // ECONNRESET
            else => SocketError.RecvFailed,
        };
    }
    return @intCast(result);
}

/// Set socket receive timeout
pub fn setRecvTimeout(fd: socket_t, timeout_ms: u32) SocketError!void {
    const SOL_SOCKET: i32 = if (is_darwin or is_bsd) 0xFFFF else 1;
    const SO_RCVTIMEO: i32 = if (is_darwin or is_bsd) 0x1006 else 20;

    const tv = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };

    const result = sysSetSockOpt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, @sizeOf(@TypeOf(tv)));
    if (result < 0) return SocketError.SetOptFailed;
}

/// Set TCP_NODELAY (disable Nagle's algorithm)
pub fn setNoDelay(fd: socket_t, enable: bool) SocketError!void {
    const IPPROTO_TCP: i32 = 6;
    const TCP_NODELAY: i32 = 1;

    const value: i32 = if (enable) 1 else 0;
    const result = sysSetSockOpt(fd, IPPROTO_TCP, TCP_NODELAY, &value, @sizeOf(i32));
    if (result < 0) return SocketError.SetOptFailed;
}

/// Set socket to non-blocking mode
pub fn setNonblocking(fd: socket_t) SocketError!void {
    const O_NONBLOCK: c_uint = if (is_linux) 0o4000 else 0x0004;
    if (is_linux) {
        _ = std.os.linux.fcntl(@intCast(fd), @intCast(std.c.F.SETFL), O_NONBLOCK);
    } else {
        if (std.c.fcntl(fd, std.c.F.SETFL, O_NONBLOCK) < 0) {
            return SocketError.SetOptFailed;
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "platform detection" {
    // Verify platform constants are set correctly
    if (is_linux) {
        try std.testing.expect(AF.INET == std.os.linux.AF.INET);
        try std.testing.expect(SOCK.STREAM == std.os.linux.SOCK.STREAM);
    } else {
        try std.testing.expectEqual(@as(u32, 2), AF.INET);
        try std.testing.expectEqual(@as(u32, 1), SOCK.STREAM);
    }
    try std.testing.expectEqual(@as(u32, 6), IPPROTO.TCP);
    try std.testing.expectEqual(@as(u32, 17), IPPROTO.UDP);
}

test "socket creation and close" {
    const fd = try createTcpSocket();
    try std.testing.expect(fd >= 0);
    close(fd);
}

test "socket creation nonblocking" {
    const fd = try createTcpSocketNonblock();
    try std.testing.expect(fd >= 0);
    close(fd);
}

test "socket options - TCP_NODELAY" {
    const fd = try createTcpSocket();
    defer close(fd);

    // Should not error
    try setNoDelay(fd, true);
    try setNoDelay(fd, false);
}

test "socket options - recv timeout" {
    const fd = try createTcpSocket();
    defer close(fd);

    // Should not error
    try setRecvTimeout(fd, 1000); // 1 second
    try setRecvTimeout(fd, 5000); // 5 seconds
}

test "IP address parsing - valid" {
    const fd = try createTcpSocket();
    defer close(fd);

    // Try to connect to localhost on a port that's likely closed
    // This should return ConnectionRefused, not InvalidAddress
    const result = connectFromString(fd, "127.0.0.1", 59999);
    if (result) |_| {
        // Unlikely to succeed, but if it does, that's fine
    } else |err| {
        // Expected: ConnectionRefused or ConnectionFailed (not InvalidAddress)
        try std.testing.expect(err != SocketError.InvalidAddress);
    }
}

test "IP address parsing - invalid format" {
    const fd = try createTcpSocket();
    defer close(fd);

    // Invalid IP formats should return InvalidAddress
    try std.testing.expectError(SocketError.InvalidAddress, connectFromString(fd, "invalid", 8080));
    try std.testing.expectError(SocketError.InvalidAddress, connectFromString(fd, "192.168.1", 8080));
    try std.testing.expectError(SocketError.InvalidAddress, connectFromString(fd, "192.168.1.1.1", 8080));
    try std.testing.expectError(SocketError.InvalidAddress, connectFromString(fd, "256.1.1.1", 8080));
    try std.testing.expectError(SocketError.InvalidAddress, connectFromString(fd, "", 8080));
}

test "sockaddr_in structure size" {
    // Verify sockaddr_in is correctly sized for the platform
    if (is_darwin or is_bsd) {
        try std.testing.expectEqual(@as(usize, 16), @sizeOf(sockaddr_in));
    } else {
        try std.testing.expectEqual(@as(usize, 16), @sizeOf(sockaddr_in));
    }
}

test "connect to closed port returns error" {
    const fd = try createTcpSocket();
    defer close(fd);

    // Port 59998 is very unlikely to have anything listening
    const result = connect(fd, .{ 127, 0, 0, 1 }, 59998);
    if (result) |_| {
        // Somehow connected - unlikely but acceptable
    } else |err| {
        // Should be ConnectionRefused or ConnectionFailed
        try std.testing.expect(err == SocketError.ConnectionRefused or err == SocketError.ConnectionFailed);
    }
}

test "multiple socket creation" {
    // Create multiple sockets to verify no resource leaks
    var fds: [10]socket_t = undefined;

    for (&fds) |*fd| {
        fd.* = try createTcpSocket();
        try std.testing.expect(fd.* >= 0);
    }

    for (fds) |fd| {
        close(fd);
    }
}

test "setNonblocking" {
    const fd = try createTcpSocket();
    defer close(fd);

    // Should not error
    try setNonblocking(fd);
}
