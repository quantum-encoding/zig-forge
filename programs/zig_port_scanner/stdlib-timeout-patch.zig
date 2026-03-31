// Patch for /usr/local/zig/lib/std/Io/Threaded.zig
// Implements timeout support for netConnectIpPosix
//
// This implementation adds non-blocking socket + poll() timeout support
// to the Zig 0.16 networking stack, resolving the TODO at line 3455

const std = @import("std");
const posix = std.posix;
const Threaded = std.Io.Threaded;
const IpAddress = std.Io.net.IpAddress;
const net = std.Io.net;

/// Helper function: Connect with timeout using non-blocking socket + poll()
/// Returns:
/// - .SUCCESS: Connection established
/// - .TIMEOUT: Timeout expired before connection
/// - Other errors from connect()
fn posixConnectWithTimeout(
    t: *Threaded,
    socket_fd: posix.socket_t,
    addr: *const posix.sockaddr,
    addr_len: posix.socklen_t,
    timeout_ns: u64,
) !void {
    // Initiate non-blocking connect
    while (true) {
        try t.checkCancel();
        switch (posix.errno(posix.system.connect(socket_fd, addr, addr_len))) {
            .SUCCESS => return, // Connected immediately (localhost, etc.)
            .INTR => continue,
            .CANCELED => return error.Canceled,

            // INPROGRESS is expected for non-blocking sockets - need to poll
            .INPROGRESS, .AGAIN => break,

            // All other errors are fatal
            .ADDRNOTAVAIL => return error.AddressUnavailable,
            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .ALREADY => return error.ConnectionPending,
            .BADF => unreachable, // Bug: File descriptor used after closed
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .FAULT => unreachable, // Bug: Invalid pointer
            .ISCONN => unreachable, // Bug: Already connected
            .HOSTUNREACH => return error.HostUnreachable,
            .NETUNREACH => return error.NetworkUnreachable,
            .NOTSOCK => unreachable, // Bug: Not a socket
            .PROTOTYPE => unreachable, // Bug: Protocol mismatch
            .TIMEDOUT => return error.Timeout,
            .CONNABORTED => unreachable, // Bug: Should not happen during connect
            .ACCES => return error.AccessDenied,
            .PERM => unreachable, // Bug: Permission denied (should be ACCES)
            .NOENT => unreachable, // Bug: Not applicable to IP sockets
            .NETDOWN => return error.NetworkDown,
            else => |err| return posix.unexpectedErrno(err),
        }
    }

    // Connection in progress - use poll() to wait with timeout
    var fds = [_]posix.pollfd{
        .{
            .fd = socket_fd,
            .events = posix.POLL.OUT, // Wait for socket to become writable
            .revents = 0,
        },
    };

    // Convert nanoseconds to milliseconds for poll()
    const timeout_ms: i32 = @intCast(@min(timeout_ns / std.time.ns_per_ms, std.math.maxInt(i32)));

    while (true) {
        try t.checkCancel();
        const poll_result = posix.poll(&fds, timeout_ms) catch |err| switch (err) {
            error.SystemResources,
            error.Unexpected,
            => |e| return e,
        };

        if (poll_result == 0) {
            // Timeout expired
            return error.Timeout;
        }

        if (poll_result > 0) {
            // Socket became writable - check if connection succeeded or failed
            var socket_err: i32 = 0;
            var err_len: posix.socklen_t = @sizeOf(i32);

            while (true) {
                try t.checkCancel();
                switch (posix.errno(posix.system.getsockopt(
                    socket_fd,
                    posix.SOL.SOCKET,
                    posix.SO.ERROR,
                    @ptrCast(&socket_err),
                    &err_len,
                ))) {
                    .SUCCESS => break,
                    .INTR => continue,
                    .CANCELED => return error.Canceled,
                    .BADF => unreachable, // Bug
                    .FAULT => unreachable, // Bug
                    .INVAL => unreachable, // Bug
                    .NOPROTOOPT => unreachable, // Bug
                    .NOTSOCK => unreachable, // Bug
                    else => |e| return posix.unexpectedErrno(e),
                }
            }

            if (socket_err == 0) {
                // Connection successful
                return;
            }

            // Connection failed - translate socket error to Zig error
            switch (@as(posix.E, @enumFromInt(socket_err))) {
                .SUCCESS => return,
                .CONNREFUSED => return error.ConnectionRefused,
                .CONNRESET => return error.ConnectionResetByPeer,
                .HOSTUNREACH => return error.HostUnreachable,
                .NETUNREACH => return error.NetworkUnreachable,
                .TIMEDOUT => return error.Timeout,
                .NETDOWN => return error.NetworkDown,
                .ACCES => return error.AccessDenied,
                .ADDRNOTAVAIL => return error.AddressUnavailable,
                else => |e| return posix.unexpectedErrno(e),
            }
        }

        // poll_result < 0 would have thrown an error, should not reach here
        unreachable;
    }
}

/// REPLACEMENT for netConnectIpPosix in /usr/local/zig/lib/std/Io/Threaded.zig
/// This version implements the TODO for timeout support
fn netConnectIpPosix(
    userdata: ?*anyopaque,
    address: *const IpAddress,
    options: IpAddress.ConnectOptions,
) IpAddress.ConnectError!net.Stream {
    if (!Threaded.have_networking) return error.NetworkDown;

    const t: *Threaded = @ptrCast(@alignCast(userdata));
    const family = Threaded.posixAddressFamily(address);

    // Determine if we need non-blocking socket for timeout
    const use_timeout = options.timeout != .none;
    const base_mode = Threaded.posixSocketMode(options.mode);
    const socket_mode = if (use_timeout) base_mode | posix.SOCK.NONBLOCK else base_mode;

    // Create socket with appropriate blocking mode
    const socket_fd = try openSocketPosixWithMode(t, family, socket_mode, .{
        .mode = options.mode,
        .protocol = options.protocol,
    });
    errdefer _ = std.c.close(socket_fd);

    // Convert address to POSIX format
    var storage: Threaded.PosixAddress = undefined;
    var addr_len = Threaded.addressToPosix(address, &storage);

    // Connect with or without timeout
    if (use_timeout) {
        const timeout_ns: u64 = switch (options.timeout) {
            .none => unreachable, // Checked above
            .ns => |ns| ns,
        };
        try posixConnectWithTimeout(t, socket_fd, &storage.any, addr_len, timeout_ns);
    } else {
        try Threaded.posixConnect(t, socket_fd, &storage.any, addr_len);
    }

    // Get local address
    try Threaded.posixGetSockName(t, socket_fd, &storage.any, &addr_len);

    return .{ .socket = .{
        .handle = socket_fd,
        .address = Threaded.addressFromPosix(&storage),
    } };
}

/// Helper function: Open socket with custom mode flags
/// Similar to openSocketPosix but accepts pre-computed mode with NONBLOCK flag
fn openSocketPosixWithMode(
    t: *Threaded,
    family: posix.sa_family_t,
    mode: u32, // Pre-computed socket mode (may include SOCK.NONBLOCK)
    options: IpAddress.BindOptions,
) error{
    AddressFamilyUnsupported,
    ProtocolUnsupportedBySystem,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    ProtocolUnsupportedByAddressFamily,
    SocketModeUnsupported,
    OptionUnsupported,
    Unexpected,
    Canceled,
}!posix.socket_t {
    const protocol = Threaded.posixProtocol(options.protocol);
    const socket_fd = while (true) {
        try t.checkCancel();
        const flags: u32 = mode | if (Threaded.socket_flags_unsupported) 0 else posix.SOCK.CLOEXEC;
        const socket_rc = posix.system.socket(family, flags, protocol);
        switch (posix.errno(socket_rc)) {
            .SUCCESS => {
                const fd: posix.fd_t = @intCast(socket_rc);
                errdefer _ = std.c.close(fd);
                if (Threaded.socket_flags_unsupported) while (true) {
                    try t.checkCancel();
                    switch (posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC)))) {
                        .SUCCESS => break,
                        .INTR => continue,
                        .CANCELED => return error.Canceled,
                        else => |err| return posix.unexpectedErrno(err),
                    }
                };
                break fd;
            },
            .INTR => continue,
            .CANCELED => return error.Canceled,

            .AFNOSUPPORT => return error.AddressFamilyUnsupported,
            .INVAL => return error.ProtocolUnsupportedBySystem,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .PROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
            .PROTOTYPE => return error.SocketModeUnsupported,
            else => |err| return posix.unexpectedErrno(err),
        }
    };
    errdefer _ = std.c.close(socket_fd);

    if (options.ip6_only) {
        if (posix.IPV6 == void) return error.OptionUnsupported;
        try Threaded.setSocketOption(t, socket_fd, posix.IPPROTO.IPV6, posix.IPV6.V6ONLY, 0);
    }

    return socket_fd;
}

// USAGE EXAMPLE: How to use timeout in application code
pub fn exampleUsage() !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const addr = try IpAddress.parse("1.1.1.1", 80);

    // Connect with 3-second timeout
    const stream = try addr.connect(io, .{
        .timeout = .{ .ns = 3 * std.time.ns_per_s },
    });
    defer stream.close(io);

    // Use stream...
}
