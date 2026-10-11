//! Hand bindings for the libc socket/unistd surface zigix_chat uses. Replaces the former
//! `@cImport` of sys/socket.h, netinet/in.h, arpa/inet.h, unistd.h, stdlib.h, string.h and
//! time.h (Zig 0.17 removed `@cImport`); prototypes are the C ones, constants come from std.c.

const std = @import("std");
const builtin = @import("builtin");

pub const socklen_t = std.c.socklen_t;

pub const AF_INET = std.c.AF.INET;
pub const SOCK_STREAM = std.c.SOCK.STREAM;
pub const SOCK_DGRAM = std.c.SOCK.DGRAM;
pub const SOL_SOCKET = std.c.SOL.SOCKET;
pub const SO_REUSEADDR = std.c.SO.REUSEADDR;
pub const SO_RCVTIMEO = std.c.SO.RCVTIMEO;

pub const struct_in_addr = extern struct { s_addr: u32 };

/// `struct sockaddr_in` with its C field names: BSD-derived systems carry a leading
/// `sin_len` and an 8-bit `sa_family_t`; Linux has a 16-bit family and no length byte.
pub const struct_sockaddr_in = if (builtin.os.tag.isDarwin() or builtin.os.tag.isBSD()) extern struct {
    sin_len: u8,
    sin_family: u8,
    sin_port: u16,
    sin_addr: struct_in_addr,
    sin_zero: [8]u8,
} else extern struct {
    sin_family: u16,
    sin_port: u16,
    sin_addr: struct_in_addr,
    sin_zero: [8]u8,
};

pub extern "c" fn socket(domain: c_int, type: c_int, protocol: c_int) c_int;
pub extern "c" fn bind(fd: c_int, addr: ?*const anyopaque, len: socklen_t) c_int;
pub extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
pub extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*socklen_t) c_int;
pub extern "c" fn connect(fd: c_int, addr: ?*const anyopaque, len: socklen_t) c_int;
pub extern "c" fn setsockopt(fd: c_int, level: c_int, name: c_int, value: ?*const anyopaque, len: socklen_t) c_int;
pub extern "c" fn read(fd: c_int, buf: ?*anyopaque, count: usize) isize;
pub extern "c" fn write(fd: c_int, buf: ?*const anyopaque, count: usize) isize;
pub extern "c" fn close(fd: c_int) c_int;
pub extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;
