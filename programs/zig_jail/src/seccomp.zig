const std = @import("std");
const linux = std.os.linux;
const profile_mod = @import("profile.zig");

const SECCOMP_RET_KILL_PROCESS = 0x80000000;
const SECCOMP_RET_KILL_THREAD = 0x00000000;
const SECCOMP_RET_ERRNO = 0x00050000;
const SECCOMP_RET_ALLOW = 0x7fff0000;

const BPF_LD = 0x00;
const BPF_W = 0x00;  // Word size (4 bytes)
const BPF_JMP = 0x05;
const BPF_RET = 0x06;
const BPF_K = 0x00;
const BPF_ABS = 0x20;
const BPF_JEQ = 0x10;

const sock_filter = extern struct {
    code: u16,
    jt: u8,
    jf: u8,
    k: u32,
};

const sock_fprog = extern struct {
    len: c_ushort,
    filter: [*]const sock_filter,
};

const SyscallMap = std.StringHashMap(u32);

fn buildSyscallMap(allocator: std.mem.Allocator) !SyscallMap {
    var map = SyscallMap.init(allocator);

    // x86_64 syscall numbers (from Linux kernel arch/x86/entry/syscalls/syscall_64.tbl)
    try map.put("read", 0);
    try map.put("write", 1);
    try map.put("open", 2);
    try map.put("close", 3);
    try map.put("stat", 4);
    try map.put("fstat", 5);
    try map.put("lstat", 6);
    try map.put("poll", 7);
    try map.put("lseek", 8);
    try map.put("mmap", 9);
    try map.put("mprotect", 10);
    try map.put("munmap", 11);
    try map.put("brk", 12);
    try map.put("rt_sigaction", 13);
    try map.put("rt_sigprocmask", 14);
    try map.put("rt_sigreturn", 15);
    try map.put("ioctl", 16);
    try map.put("pread64", 17);
    try map.put("pwrite64", 18);
    try map.put("readv", 19);
    try map.put("writev", 20);
    try map.put("access", 21);
    try map.put("pipe", 22);
    try map.put("select", 23);
    try map.put("sched_yield", 24);
    try map.put("mremap", 25);
    try map.put("msync", 26);
    try map.put("mincore", 27);
    try map.put("remap_file_pages", 216);
    try map.put("madvise", 28);
    try map.put("dup", 32);
    try map.put("dup2", 33);
    try map.put("pause", 34);
    try map.put("nanosleep", 35);
    try map.put("getpid", 39);
    try map.put("socket", 41);
    try map.put("connect", 42);
    try map.put("accept", 43);
    try map.put("sendto", 44);
    try map.put("recvfrom", 45);
    try map.put("sendmsg", 46);
    try map.put("recvmsg", 47);
    try map.put("shutdown", 48);
    try map.put("sendfile", 40);
    try map.put("bind", 49);
    try map.put("listen", 50);
    try map.put("getsockname", 51);
    try map.put("getpeername", 52);
    try map.put("socketpair", 53);
    try map.put("setsockopt", 54);
    try map.put("getsockopt", 55);
    try map.put("clone", 56);
    try map.put("fork", 57);
    try map.put("vfork", 58);
    try map.put("execve", 59);
    try map.put("exit", 60);
    try map.put("wait4", 61);
    try map.put("waitpid", 61); // waitpid is a libc wrapper around wait4
    try map.put("kill", 62);
    try map.put("uname", 63);
    try map.put("fcntl", 72);
    try map.put("flock", 73);
    try map.put("fsync", 74);
    try map.put("fdatasync", 75);
    try map.put("truncate", 76);
    try map.put("ftruncate", 77);
    try map.put("getdents", 78);
    try map.put("getcwd", 79);
    try map.put("chdir", 80);
    try map.put("getdents64", 217);
    try map.put("fchdir", 81);
    try map.put("rename", 82);
    try map.put("mkdir", 83);
    try map.put("rmdir", 84);
    try map.put("creat", 85);
    try map.put("link", 86);
    try map.put("unlink", 87);
    try map.put("symlink", 88);
    try map.put("readlink", 89);
    try map.put("chmod", 90);
    try map.put("fchmod", 91);
    try map.put("chown", 92);
    try map.put("fchown", 93);
    try map.put("lchown", 94);
    try map.put("umask", 95);

    // Extended attributes
    try map.put("setxattr", 188);
    try map.put("lsetxattr", 189);
    try map.put("fsetxattr", 190);
    try map.put("getxattr", 191);
    try map.put("lgetxattr", 192);
    try map.put("fgetxattr", 193);
    try map.put("listxattr", 194);
    try map.put("llistxattr", 195);
    try map.put("flistxattr", 196);
    try map.put("removexattr", 197);
    try map.put("lremovexattr", 198);
    try map.put("fremovexattr", 199);

    try map.put("gettimeofday", 96);
    try map.put("getrlimit", 97);
    try map.put("getrusage", 98);
    try map.put("sysinfo", 99);
    try map.put("times", 100);
    try map.put("getuid", 102);
    try map.put("getgid", 104);
    try map.put("setuid", 105);
    try map.put("setgid", 106);
    try map.put("geteuid", 107);
    try map.put("getegid", 108);
    try map.put("setpgid", 109);
    try map.put("getppid", 110);
    try map.put("getpgrp", 111);
    try map.put("setsid", 112);
    try map.put("setreuid", 113);
    try map.put("setregid", 114);
    try map.put("getgroups", 115);
    try map.put("setgroups", 116);
    try map.put("setresuid", 117);
    try map.put("getresuid", 118);
    try map.put("setresgid", 119);
    try map.put("getresgid", 120);
    try map.put("getpgid", 121);
    try map.put("getsid", 124);
    try map.put("capget", 125);
    try map.put("capset", 126);
    try map.put("rt_sigpending", 127);
    try map.put("rt_sigtimedwait", 128);
    try map.put("rt_sigsuspend", 130);
    try map.put("sigaltstack", 131);
    try map.put("mknod", 133);
    try map.put("personality", 135);
    try map.put("statfs", 137);
    try map.put("fstatfs", 138);
    try map.put("getpriority", 140);
    try map.put("setpriority", 141);
    try map.put("sched_setparam", 142);
    try map.put("sched_getparam", 143);
    try map.put("sched_setscheduler", 144);
    try map.put("sched_getscheduler", 145);
    try map.put("sched_get_priority_max", 146);
    try map.put("sched_get_priority_min", 147);
    try map.put("sched_rr_get_interval", 148);
    try map.put("mlock", 149);
    try map.put("munlock", 150);
    try map.put("mlockall", 151);
    try map.put("munlockall", 152);
    try map.put("pivot_root", 155);
    try map.put("prctl", 157);
    try map.put("arch_prctl", 158);
    try map.put("setrlimit", 160);
    try map.put("chroot", 161);
    try map.put("sync", 162);
    try map.put("mount", 165);
    try map.put("umount2", 166);
    try map.put("gettid", 186);
    try map.put("time", 201);
    try map.put("futex", 202);
    try map.put("sched_setaffinity", 203);
    try map.put("sched_getaffinity", 204);
    try map.put("set_tid_address", 218);
    try map.put("restart_syscall", 219);
    try map.put("clock_gettime", 228);
    try map.put("clock_getres", 229);
    try map.put("clock_nanosleep", 230);
    try map.put("exit_group", 231);
    try map.put("epoll_wait", 232);
    try map.put("epoll_ctl", 233);
    try map.put("tgkill", 234);
    try map.put("epoll_create", 213);
    try map.put("utimes", 235);
    try map.put("mbind", 237);
    try map.put("set_mempolicy", 238);
    try map.put("get_mempolicy", 239);
    try map.put("waitid", 247);
    try map.put("openat", 257);
    try map.put("mkdirat", 258);
    try map.put("mknodat", 259);
    try map.put("fchownat", 260);
    try map.put("newfstatat", 262);
    try map.put("unlinkat", 263);
    try map.put("renameat", 264);
    try map.put("linkat", 265);
    try map.put("symlinkat", 266);
    try map.put("readlinkat", 267);
    try map.put("fchmodat", 268);
    try map.put("faccessat", 269);
    try map.put("pselect6", 270);
    try map.put("ppoll", 271);
    try map.put("set_robust_list", 273);
    try map.put("get_robust_list", 274);
    try map.put("splice", 275);
    try map.put("tee", 276);
    try map.put("sync_file_range", 277);
    try map.put("utimensat", 280);
    try map.put("epoll_pwait", 281);
    try map.put("epoll_pwait2", 441);
    try map.put("signalfd", 282);
    try map.put("timerfd_create", 283);
    try map.put("eventfd", 284);
    try map.put("fallocate", 285);
    try map.put("timerfd_settime", 286);
    try map.put("timerfd_gettime", 287);
    try map.put("accept4", 288);
    try map.put("signalfd4", 289);
    try map.put("eventfd2", 290);
    try map.put("epoll_create1", 291);
    try map.put("dup3", 292);
    try map.put("pipe2", 293);
    try map.put("preadv", 295);
    try map.put("pwritev", 296);
    try map.put("recvmmsg", 299);
    try map.put("prlimit64", 302);
    try map.put("sendmmsg", 307);
    try map.put("getcpu", 309);
    try map.put("sched_setattr", 314);
    try map.put("sched_getattr", 315);
    try map.put("renameat2", 316);
    try map.put("getrandom", 318);
    try map.put("memfd_create", 319);
    try map.put("execveat", 322);
    try map.put("membarrier", 324);
    try map.put("copy_file_range", 326);
    try map.put("preadv2", 327);
    try map.put("pwritev2", 328);
    try map.put("statx", 332);
    try map.put("rseq", 334);
    try map.put("pidfd_send_signal", 424);
    try map.put("io_uring_setup", 425);
    try map.put("io_uring_enter", 426);
    try map.put("pidfd_open", 434);
    try map.put("clone3", 435);
    try map.put("faccessat2", 439);

    return map;
}

pub fn buildSeccompFilter(allocator: std.mem.Allocator, profile: *const profile_mod.Profile) ![]sock_filter {
    var filter_list: std.ArrayList(sock_filter) = .empty;
    defer filter_list.deinit(allocator);

    var syscall_map = try buildSyscallMap(allocator);
    defer syscall_map.deinit();

    var allowed_numbers: std.ArrayList(u32) = .empty;
    defer allowed_numbers.deinit(allocator);

    for (profile.syscalls.allowed) |syscall_name| {
        if (syscall_map.get(syscall_name)) |syscall_num| {
            try allowed_numbers.append(allocator, syscall_num);
        } else {
            std.debug.print("[zig-jail] ⚠️  Unknown syscall: {s}\n", .{syscall_name});
        }
    }

    std.debug.print("[zig-jail] Building BPF filter for {d} allowed syscalls\n", .{allowed_numbers.items.len});

    const default_action: u32 = if (std.mem.eql(u8, profile.syscalls.default_action, "kill"))
        SECCOMP_RET_KILL_PROCESS
    else if (std.mem.eql(u8, profile.syscalls.default_action, "errno"))
        SECCOMP_RET_ERRNO | (profile.syscalls.errno_value orelse 13)
    else
        SECCOMP_RET_ALLOW;

    // BPF Program Construction
    // 0: Load architecture
    try filter_list.append(allocator, .{
        .code = BPF_LD | BPF_W | BPF_ABS,
        .jt = 0,
        .jf = 0,
        .k = 4, // seccomp_data.arch
    });

    // 1: Check x86_64
    try filter_list.append(allocator, .{
        .code = BPF_JMP | BPF_JEQ | BPF_K,
        .jt = 1, // Skip to syscall load
        .jf = 0, // Fall through to kill
        .k = 0xc000003e, // AUDIT_ARCH_X86_64
    });

    // 2: Kill on wrong arch
    try filter_list.append(allocator, .{
        .code = BPF_RET | BPF_K,
        .jt = 0,
        .jf = 0,
        .k = SECCOMP_RET_KILL_PROCESS,
    });

    // 3: Load syscall number
    try filter_list.append(allocator, .{
        .code = BPF_LD | BPF_W | BPF_ABS,
        .jt = 0,
        .jf = 0,
        .k = 0, // seccomp_data.nr
    });

    // 4+: JEQ for each allowed syscall
    const total_instructions = 4 + allowed_numbers.items.len + 2; // prefix + comparisons + default + allow
    for (allowed_numbers.items, 0..) |syscall_num, i| {
        const current_idx = 4 + i;
        // BPF jumps are relative to NEXT instruction, not current
        const jumps_to_allow: u8 = @intCast(total_instructions - 1 - current_idx - 1);
        try filter_list.append(allocator, .{
            .code = BPF_JMP | BPF_JEQ | BPF_K,
            .jt = jumps_to_allow,
            .jf = 0, // Fall through to default
            .k = syscall_num,
        });
    }

    // Default action
    try filter_list.append(allocator, .{
        .code = BPF_RET | BPF_K,
        .jt = 0,
        .jf = 0,
        .k = default_action,
    });

    // ALLOW action
    try filter_list.append(allocator, .{
        .code = BPF_RET | BPF_K,
        .jt = 0,
        .jf = 0,
        .k = SECCOMP_RET_ALLOW,
    });

    return try filter_list.toOwnedSlice(allocator);
}

pub fn installSeccompFilter(filter: []const sock_filter) !void {
    const no_new_privs_ret = linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
    if (no_new_privs_ret != 0) {
        std.debug.print("[zig-jail] ⚠️  prctl(PR_SET_NO_NEW_PRIVS) failed: {d}\n", .{no_new_privs_ret});
        return error.PrctlFailed;
    }

    var prog = sock_fprog{
        .len = @intCast(filter.len),
        .filter = filter.ptr,
    };

    const seccomp_ret = linux.prctl(
        @intFromEnum(linux.PR.SET_SECCOMP),
        2, // SECCOMP_MODE_FILTER
        @intFromPtr(&prog),
        0,
        0,
    );

    if (seccomp_ret != 0) {
        const signed_ret: isize = @bitCast(seccomp_ret);
        const errno_val: i32 = @intCast(-signed_ret);
        std.debug.print("[zig-jail] ⚠️  prctl(PR_SET_SECCOMP) failed: errno={d}\n", .{errno_val});
        return error.SeccompInstallFailed;
    }

    std.debug.print("[zig-jail] 🛡️  seccomp-BPF filter installed ({d} instructions)\n", .{filter.len});
}

// =============================================================================
// Tests
// =============================================================================

test "seccomp: BPF instruction generation - ALLOW opcodes" {
    var filter_list: std.ArrayList(sock_filter) = .empty;
    defer filter_list.deinit(std.testing.allocator);

    try filter_list.append(std.testing.allocator, .{
        .code = BPF_RET | BPF_K,
        .jt = 0,
        .jf = 0,
        .k = SECCOMP_RET_ALLOW,
    });

    const filter = filter_list.items[0];
    try std.testing.expectEqual(@as(u16, BPF_RET | BPF_K), filter.code);
    try std.testing.expectEqual(SECCOMP_RET_ALLOW, filter.k);
}

test "seccomp: BPF instruction generation - DENY opcodes" {
    var filter_list: std.ArrayList(sock_filter) = .empty;
    defer filter_list.deinit(std.testing.allocator);

    try filter_list.append(std.testing.allocator, .{
        .code = BPF_RET | BPF_K,
        .jt = 0,
        .jf = 0,
        .k = SECCOMP_RET_KILL_PROCESS,
    });

    const filter = filter_list.items[0];
    try std.testing.expectEqual(SECCOMP_RET_KILL_PROCESS, filter.k);
}

test "seccomp: Architecture validation instruction" {
    var filter_list: std.ArrayList(sock_filter) = .empty;
    defer filter_list.deinit(std.testing.allocator);

    try filter_list.append(std.testing.allocator, .{
        .code = BPF_LD | BPF_W | BPF_ABS,
        .jt = 0,
        .jf = 0,
        .k = 4, // seccomp_data.arch
    });

    try filter_list.append(std.testing.allocator, .{
        .code = BPF_JMP | BPF_JEQ | BPF_K,
        .jt = 1,
        .jf = 0,
        .k = 0xc000003e, // AUDIT_ARCH_X86_64
    });

    try std.testing.expectEqual(@as(usize, 2), filter_list.items.len);
    try std.testing.expectEqual(@as(u32, 4), filter_list.items[0].k);
    try std.testing.expectEqual(@as(u32, 0xc000003e), filter_list.items[1].k);
}

test "seccomp: Syscall number mapping - read" {
    var map = try buildSyscallMap(std.testing.allocator);
    defer map.deinit();

    try std.testing.expectEqual(@as(u32, 0), map.get("read").?);
}

test "seccomp: Syscall number mapping - write" {
    var map = try buildSyscallMap(std.testing.allocator);
    defer map.deinit();

    try std.testing.expectEqual(@as(u32, 1), map.get("write").?);
}

test "seccomp: Syscall number mapping - open" {
    var map = try buildSyscallMap(std.testing.allocator);
    defer map.deinit();

    try std.testing.expectEqual(@as(u32, 2), map.get("open").?);
}

test "seccomp: Syscall number mapping - execve" {
    var map = try buildSyscallMap(std.testing.allocator);
    defer map.deinit();

    try std.testing.expectEqual(@as(u32, 59), map.get("execve").?);
}

test "seccomp: Syscall number mapping - exit" {
    var map = try buildSyscallMap(std.testing.allocator);
    defer map.deinit();

    try std.testing.expectEqual(@as(u32, 60), map.get("exit").?);
}

test "seccomp: Filter chain construction - basic structure" {
    var profile = profile_mod.Profile{
        .profile_name = "test",
        .description = "Test profile",
        .version = "1.0",
        .syscalls = .{
            .default_action = "kill",
            .allowed = &[_][]const u8{ "read", "write" },
            .blocked = &[_][]const u8{},
        },
        .allocator = std.testing.allocator,
    };

    const filter = try buildSeccompFilter(std.testing.allocator, &profile);
    defer std.testing.allocator.free(filter);

    // Filter should have: arch check (3) + syscall comparisons (2) + default action (1) + allow action (1)
    try std.testing.expect(filter.len >= 6);

    // First instruction should load architecture
    try std.testing.expectEqual(@as(u16, BPF_LD | BPF_W | BPF_ABS), filter[0].code);

    // Second should check for x86_64
    try std.testing.expectEqual(@as(u16, BPF_JMP | BPF_JEQ | BPF_K), filter[1].code);

    // Last instruction should be return
    try std.testing.expectEqual(@as(u16, BPF_RET | BPF_K), filter[filter.len - 1].code);
}

test "seccomp: Error handling - invalid syscall names" {
    var profile = profile_mod.Profile{
        .profile_name = "test",
        .description = "Test profile",
        .version = "1.0",
        .syscalls = .{
            .default_action = "kill",
            .allowed = &[_][]const u8{ "read", "nonexistent_syscall" },
            .blocked = &[_][]const u8{},
        },
        .allocator = std.testing.allocator,
    };

    const filter = try buildSeccompFilter(std.testing.allocator, &profile);
    defer std.testing.allocator.free(filter);

    // Should still build successfully, just with the valid syscall
    try std.testing.expect(filter.len > 0);
}