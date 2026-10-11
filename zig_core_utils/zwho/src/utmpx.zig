//! Hand bindings for <utmpx.h> and localtime (Zig 0.17 removed @cImport). Layouts are the
//! macOS/BSD and glibc Linux ones; other targets fail at compile time rather
//! than reading garbage.

const std = @import("std");
const builtin = @import("builtin");

pub const time_t = std.c.time_t;

pub const struct_utmpx = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => extern struct {
        ut_user: [256]u8,
        ut_id: [4]u8,
        ut_line: [32]u8,
        ut_pid: std.c.pid_t,
        ut_type: c_short,
        ut_tv: extern struct { tv_sec: c_long, tv_usec: i32 },
        ut_host: [256]u8,
        ut_pad: [16]u32,
    },
    .linux => if (builtin.abi.isGnu()) extern struct {
        ut_type: c_short,
        ut_pid: std.c.pid_t,
        ut_line: [32]u8,
        ut_id: [4]u8,
        ut_user: [32]u8,
        ut_host: [256]u8,
        ut_exit: extern struct { e_termination: c_short, e_exit: c_short },
        // glibc keeps 32-bit session/time fields on x86_64 (__WORDSIZE_TIME64_COMPAT32).
        ut_session: if (builtin.cpu.arch == .x86_64) i32 else c_long,
        ut_tv: if (builtin.cpu.arch == .x86_64)
            extern struct { tv_sec: i32, tv_usec: i32 }
        else
            extern struct { tv_sec: c_long, tv_usec: c_long },
        ut_addr_v6: [4]i32,
        __glibc_reserved: [20]u8,
    } else @compileError("utmpx layout: only glibc is bound on Linux"),
    else => @compileError("utmpx layout not bound for this OS"),
};

pub extern "c" fn setutxent() void;
pub extern "c" fn endutxent() void;
pub extern "c" fn getutxent() ?[*]struct_utmpx;
pub extern "c" fn pututxline(ut: *const struct_utmpx) ?*struct_utmpx;
pub extern "c" fn utmpxname(file: [*:0]const u8) c_int;

/// <time.h> struct tm (same layout on macOS and glibc).
pub const struct_tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

pub extern "c" fn localtime(t: *const time_t) ?*struct_tm;
