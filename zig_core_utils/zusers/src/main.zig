//! zusers - Print the usernames of users currently logged in
//!
//! High-performance users implementation in Zig.

const std = @import("std");
const libc = std.c;

const VERSION = "1.0.0";

// Linux utmp structure (must match kernel/glibc layout)
const UT_LINESIZE = 32;
const UT_NAMESIZE = 32;
const UT_HOSTSIZE = 256;

const Utmp = extern struct {
    ut_type: i16,
    ut_pid: i32,
    ut_line: [UT_LINESIZE]u8,
    ut_id: [4]u8,
    ut_user: [UT_NAMESIZE]u8,
    ut_host: [UT_HOSTSIZE]u8,
    ut_exit: extern struct {
        e_termination: i16,
        e_exit: i16,
    },
    ut_session: i32,
    ut_tv: extern struct {
        tv_sec: i32,
        tv_usec: i32,
    },
    ut_addr_v6: [4]i32,
    __unused: [20]u8,
};

const USER_PROCESS: i16 = 7;

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zusers [OPTION]...
        \\Print the user names of users currently logged in to the current host.
        \\
        \\Options:
        \\      --help     Display this help and exit
        \\      --version  Output version information and exit
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zusers " ++ VERSION ++ "\n");
}

fn nullTerminated(buf: []const u8) []const u8 {
    for (buf, 0..) |c, i| {
        if (c == 0) return buf[0..i];
    }
    return buf;
}

pub fn main(init: std.process.Init) void {
    // Parse arguments
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        }
    }

    // Read /var/run/utmp directly (same approach as zwho)
    var fd = libc.open("/var/run/utmp", .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) {
        fd = libc.open("/run/utmp", .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd < 0) return;
    }
    defer _ = libc.close(fd);

    var users: [64][]const u8 = undefined;
    var user_count: usize = 0;
    var name_storage: [64][UT_NAMESIZE]u8 = undefined;

    var entry_buf: Utmp = undefined;
    const buf: [*]u8 = @ptrCast(&entry_buf);
    while (true) {
        const n = libc.read(fd, buf, @sizeOf(Utmp));
        if (n < @sizeOf(Utmp)) break;

        const entry: *const Utmp = &entry_buf;
        if (entry.ut_type != USER_PROCESS) continue;

        const name = nullTerminated(&entry.ut_user);
        if (name.len == 0) continue;

        if (user_count < users.len) {
            @memcpy(name_storage[user_count][0..name.len], name);
            users[user_count] = name_storage[user_count][0..name.len];
            user_count += 1;
        }
    }

    // Print usernames separated by spaces
    var first = true;
    for (users[0..user_count]) |name| {
        if (!first) writeStdout(" ");
        first = false;
        writeStdout(name);
    }

    if (user_count > 0) {
        writeStdout("\n");
    }
}
