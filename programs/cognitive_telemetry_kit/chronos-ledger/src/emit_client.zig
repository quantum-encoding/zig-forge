//! Non-blocking IPC writer for the in-agent emit-client (Guardrail 3).
//!
//! The agent's reasoning thread must NEVER stall on the audit path. If the
//! privileged sink daemon is restarting, gone, or its receive buffer is full,
//! the send fails fast and the caller drops the event. A dropped event is not
//! silent data loss in the threat model: the sink/proxy sees a gap in the
//! monotonic `seq`, which is itself a tamper/loss signal.
//!
//! Transport: AF_UNIX SOCK_DGRAM. Datagrams give us message framing for free
//! (one event = one datagram) and need no connection handshake, so a single
//! `sendto` is the entire fire-and-forget write. MSG_DONTWAIT makes that one
//! syscall non-blocking regardless of inherited socket flags.
//!
//! The socket syscalls are declared `extern "c"` rather than via `std.posix`:
//! this Zig 0.16 ships a stripped `std.posix` (no `socket`/`sendto`), the same
//! reason chronos-hook declares `fork`/`execvp` extern.

const std = @import("std");
const builtin = @import("builtin");

pub const EmitError = error{
    SinkUnavailable, // no socket / sink not listening / send error
    WouldBlock, // sink's buffer full right now — drop and move on
    PathTooLong, // socket path exceeds sun_path
    Truncated, // datagram larger than the kernel accepted
};

extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn sendto(fd: c_int, buf: [*]const u8, len: usize, flags: c_int, dest_addr: *const anyopaque, addrlen: u32) isize;
extern "c" fn close(fd: c_int) c_int;

const is_bsd = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly => true,
    else => false,
};

const AF_UNIX: c_int = 1;
const SOCK_DGRAM: c_int = if (is_bsd) 2 else 2; // 2 on both Darwin and Linux
const MSG_DONTWAIT: c_int = if (is_bsd) 0x80 else 0x40;
const EAGAIN: c_int = if (is_bsd) 35 else 11; // EWOULDBLOCK == EAGAIN on both

/// BSD sockaddr_un carries a leading length byte; Linux does not.
const SockaddrUn = if (is_bsd) extern struct {
    sun_len: u8,
    sun_family: u8,
    sun_path: [104]u8,
} else extern struct {
    sun_family: u16,
    sun_path: [108]u8,
};

fn currentErrno() c_int {
    return std.c._errno().*;
}

/// Send one canonical event payload to the sink at `socket_path`. Fire-and-forget,
/// non-blocking, bounded to a single `socket()`+`sendto()`+`close()`.
pub fn emit(socket_path: []const u8, payload: []const u8) EmitError!void {
    var addr: SockaddrUn = std.mem.zeroes(SockaddrUn);
    if (socket_path.len >= addr.sun_path.len) return error.PathTooLong;
    addr.sun_family = if (is_bsd) AF_UNIX else @intCast(AF_UNIX);
    if (is_bsd) addr.sun_len = @sizeOf(SockaddrUn);
    @memcpy(addr.sun_path[0..socket_path.len], socket_path);

    const fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (fd < 0) return error.SinkUnavailable;
    defer _ = close(fd);

    const n = sendto(fd, payload.ptr, payload.len, MSG_DONTWAIT, @ptrCast(&addr), @sizeOf(SockaddrUn));
    if (n < 0) {
        return if (currentErrno() == EAGAIN) error.WouldBlock else error.SinkUnavailable;
    }
    if (@as(usize, @intCast(n)) != payload.len) return error.Truncated;
}

test "emit fails fast when the sink socket does not exist" {
    // No daemon bound → ENOENT/ECONNREFUSED → SinkUnavailable, never blocks.
    const r = emit("/tmp/chronos-ledger-nonexistent-test.sock", "{}");
    try std.testing.expectError(error.SinkUnavailable, r);
}

test "PathTooLong is rejected before any syscall" {
    var long: [200]u8 = undefined;
    @memset(&long, 'a');
    try std.testing.expectError(error.PathTooLong, emit(&long, "{}"));
}
