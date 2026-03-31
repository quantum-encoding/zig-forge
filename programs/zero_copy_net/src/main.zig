//! Zero-Copy Network Stack
//!
//! High-performance networking with io_uring
//!
//! Components:
//!   - TcpServer:  io_uring async TCP server with zero-copy BufferPool
//!   - UdpSocket:  io_uring RECVMSG/SENDMSG UDP with source address tracking
//!   - IoUring:    Thin wrapper around std.os.linux.IoUring
//!   - BufferPool: Lock-free, page-aligned buffer pool for io_uring

pub const tcp = @import("tcp/server.zig");
pub const udp = @import("udp/socket.zig");
pub const io_uring = @import("io_uring/ring.zig");
pub const buffer = @import("buffer/pool.zig");

pub const TcpServer = tcp.TcpServer;
pub const UdpSocket = udp.UdpSocket;
pub const Address = udp.Address;
pub const Packet = udp.Packet;
pub const IoUring = io_uring.IoUring;
pub const BufferPool = buffer.BufferPool;

test {
    @import("std").testing.refAllDecls(@This());
}
