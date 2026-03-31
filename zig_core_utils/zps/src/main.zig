//! zps - Report process status
//!
//! A Zig implementation of ps.
//! Lists running processes with various information.
//!
//! Usage: zps [OPTIONS]

const std = @import("std");

const VERSION = "1.0.0";

// C types and functions
const DIR = opaque {};
const dirent = extern struct {
    d_ino: c_ulong,
    d_off: c_long,
    d_reclen: c_ushort,
    d_type: u8,
    d_name: [256]u8,
};

extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn opendir(name: [*:0]const u8) ?*DIR;
extern "c" fn closedir(dirp: *DIR) c_int;
extern "c" fn readdir(dirp: *DIR) ?*dirent;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn getuid() c_uint;
const c_read = @extern(*const fn (c_int, [*]u8, usize) callconv(.c) isize, .{ .name = "read" });

const O_RDONLY: c_int = 0;

fn writeStderr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(2, msg.ptr, msg.len);
}

fn writeStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [8192]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(1, msg.ptr, msg.len);
}

const ProcessInfo = struct {
    pid: i32,
    ppid: i32,
    uid: u32,
    state: u8,
    name: []const u8,
    cmdline: []const u8,
    utime: u64,
    stime: u64,
    vsize: u64,
    rss: u64,
    tty: []const u8,
    start_time: u64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    // Options
    var show_all = false;
    var show_full = false;
    var show_long = false;
    var show_aux = false;
    var user_filter: ?u32 = null;
    var pid_filter: ?i32 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            writeStdout("zps {s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--all")) {
            show_all = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--full")) {
            show_full = true;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--long")) {
            show_long = true;
        } else if (std.mem.eql(u8, arg, "aux")) {
            show_aux = true;
            show_all = true;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--user")) {
            if (i + 1 >= args.len) {
                writeStderr("zps: option requires an argument -- 'u'\n", .{});
                std.process.exit(1);
            }
            i += 1;
            user_filter = std.fmt.parseInt(u32, args[i], 10) catch {
                writeStderr("zps: invalid user ID: {s}\n", .{args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--pid")) {
            if (i + 1 >= args.len) {
                writeStderr("zps: option requires an argument -- 'p'\n", .{});
                std.process.exit(1);
            }
            i += 1;
            pid_filter = std.fmt.parseInt(i32, args[i], 10) catch {
                writeStderr("zps: invalid PID: {s}\n", .{args[i]});
                std.process.exit(1);
            };
        } else if (arg.len > 0 and arg[0] == '-') {
            // Handle combined options
            for (arg[1..]) |ch| {
                switch (ch) {
                    'a', 'e' => show_all = true,
                    'f' => show_full = true,
                    'l' => show_long = true,
                    'x' => show_all = true,
                    else => {
                        writeStderr("zps: invalid option -- '{c}'\n", .{ch});
                        std.process.exit(1);
                    },
                }
            }
        }
    }

    // Get current user's UID for filtering
    const current_uid = getuid();

    // Collect processes
    var processes: std.ArrayListUnmanaged(ProcessInfo) = .empty;
    defer {
        for (processes.items) |p| {
            allocator.free(p.name);
            allocator.free(p.cmdline);
            allocator.free(p.tty);
        }
        processes.deinit(allocator);
    }

    const dir = opendir("/proc") orelse {
        writeStderr("zps: cannot open /proc\n", .{});
        std.process.exit(1);
    };
    defer _ = closedir(dir);

    while (readdir(dir)) |entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.d_name);
        const name = std.mem.sliceTo(name_ptr, 0);
        const pid = std.fmt.parseInt(i32, name, 10) catch continue;

        // Apply PID filter
        if (pid_filter) |filter_pid| {
            if (pid != filter_pid) continue;
        }

        const info = readProcessInfo(allocator, pid) catch continue;

        // Apply user filter
        if (user_filter) |uid| {
            if (info.uid != uid) {
                freeProcessInfo(allocator, info);
                continue;
            }
        }

        // If not showing all, only show current user's processes
        if (!show_all and info.uid != current_uid) {
            freeProcessInfo(allocator, info);
            continue;
        }

        processes.append(allocator, info) catch {
            freeProcessInfo(allocator, info);
            continue;
        };
    }

    // Sort by PID
    std.mem.sort(ProcessInfo, processes.items, {}, struct {
        fn lessThan(_: void, a: ProcessInfo, b: ProcessInfo) bool {
            return a.pid < b.pid;
        }
    }.lessThan);

    // Print header and processes
    if (show_aux) {
        writeStdout("{s: <8} {s: >6} {s: >4} {s: >4} {s: >8} {s: >8} {s: <8} {s: <4} {s: <5} {s}\n", .{ "USER", "PID", "%CPU", "%MEM", "VSZ", "RSS", "TTY", "STAT", "TIME", "COMMAND" });
        for (processes.items) |p| {
            const cpu_pct: f32 = 0.0; // Would need uptime calculation
            const mem_pct: f32 = 0.0; // Would need total mem
            const time_min = (p.utime + p.stime) / 100 / 60;
            const time_sec = ((p.utime + p.stime) / 100) % 60;
            writeStdout("{d: <8} {d: >6} {d: >4.1} {d: >4.1} {d: >8} {d: >8} {s: <8} {c: <4} {d: >2}:{d:0>2} {s}\n", .{
                p.uid,
                p.pid,
                cpu_pct,
                mem_pct,
                p.vsize / 1024,
                p.rss * 4, // pages to KB
                p.tty,
                p.state,
                time_min,
                time_sec,
                if (show_full) p.cmdline else p.name,
            });
        }
    } else if (show_long) {
        writeStdout("{s: <1} {s: >5} {s: >5} {s: >5} {s: >3} {s: >4} {s: >8} {s: >6} {s: <8} {s: >5} {s}\n", .{ "S", "UID", "PID", "PPID", "C", "PRI", "ADDR", "SZ", "TTY", "TIME", "CMD" });
        for (processes.items) |p| {
            const time_min = (p.utime + p.stime) / 100 / 60;
            const time_sec = ((p.utime + p.stime) / 100) % 60;
            writeStdout("{c: <1} {d: >5} {d: >5} {d: >5} {d: >3} {d: >4} {s: >8} {d: >6} {s: <8} {d: >2}:{d:0>2} {s}\n", .{
                p.state,
                p.uid,
                p.pid,
                p.ppid,
                @as(u8, 0),
                @as(u8, 20),
                "-",
                p.vsize / 4096,
                p.tty,
                time_min,
                time_sec,
                if (show_full) p.cmdline else p.name,
            });
        }
    } else if (show_full) {
        writeStdout("{s: >5} {s: >5} {s: >5} {s: <1} {s: >5} {s: <8} {s}\n", .{ "UID", "PID", "PPID", "S", "TIME", "TTY", "CMD" });
        for (processes.items) |p| {
            const time_min = (p.utime + p.stime) / 100 / 60;
            const time_sec = ((p.utime + p.stime) / 100) % 60;
            writeStdout("{d: >5} {d: >5} {d: >5} {c: <1} {d: >2}:{d:0>2} {s: <8} {s}\n", .{ p.uid, p.pid, p.ppid, p.state, time_min, time_sec, p.tty, p.cmdline });
        }
    } else {
        writeStdout("  PID TTY          TIME CMD\n", .{});
        for (processes.items) |p| {
            const time_min = (p.utime + p.stime) / 100 / 60;
            const time_sec = ((p.utime + p.stime) / 100) % 60;
            var pid_buf: [8]u8 = undefined;
            const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{p.pid}) catch "?";
            var time_buf: [8]u8 = undefined;
            const time_str = std.fmt.bufPrint(&time_buf, "{d}:{d:0>2}", .{ time_min, time_sec }) catch "?:??";
            writeStdout("{s: >5} {s: <8} {s: >5} {s}\n", .{ pid_str, p.tty, time_str, p.name });
        }
    }
}

fn freeProcessInfo(allocator: std.mem.Allocator, p: ProcessInfo) void {
    allocator.free(p.name);
    allocator.free(p.cmdline);
    allocator.free(p.tty);
}

fn readProcessInfo(allocator: std.mem.Allocator, pid: i32) !ProcessInfo {
    var path_buf: [64]u8 = undefined;

    // Read comm
    const comm_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return error.PathTooLong;
    path_buf[comm_path.len] = 0;
    const name = blk: {
        const fd = open(@ptrCast(&path_buf), O_RDONLY);
        if (fd < 0) return error.ProcessGone;
        defer _ = close(fd);
        var buf: [256]u8 = undefined;
        const len = c_read(fd, &buf, buf.len);
        if (len <= 0) return error.EmptyName;
        const ulen: usize = @intCast(len);
        const end = if (ulen > 0 and buf[ulen - 1] == '\n') ulen - 1 else ulen;
        break :blk try allocator.dupe(u8, buf[0..end]);
    };
    errdefer allocator.free(name);

    // Read cmdline
    const cmdline_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cmdline", .{pid}) catch return error.PathTooLong;
    path_buf[cmdline_path.len] = 0;
    const cmdline = blk: {
        const fd = open(@ptrCast(&path_buf), O_RDONLY);
        if (fd < 0) break :blk try allocator.dupe(u8, name);
        defer _ = close(fd);
        var buf: [4096]u8 = undefined;
        const len = c_read(fd, &buf, buf.len);
        if (len <= 0) break :blk try allocator.dupe(u8, name);
        const ulen: usize = @intCast(len);
        for (buf[0..ulen]) |*ch| {
            if (ch.* == 0) ch.* = ' ';
        }
        var end = ulen;
        while (end > 0 and buf[end - 1] == ' ') end -= 1;
        break :blk try allocator.dupe(u8, buf[0..end]);
    };
    errdefer allocator.free(cmdline);

    // Read stat for detailed info
    const stat_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return error.PathTooLong;
    path_buf[stat_path.len] = 0;

    var ppid: i32 = 0;
    var state: u8 = '?';
    var utime: u64 = 0;
    var stime: u64 = 0;
    var vsize: u64 = 0;
    var rss: u64 = 0;
    var tty_nr: i32 = 0;
    var start_time: u64 = 0;

    {
        const fd = open(@ptrCast(&path_buf), O_RDONLY);
        if (fd >= 0) {
            defer _ = close(fd);
            var buf: [1024]u8 = undefined;
            const len = c_read(fd, &buf, buf.len);
            if (len > 0) {
                const ulen: usize = @intCast(len);
                const content = buf[0..ulen];
                if (std.mem.lastIndexOf(u8, content, ")")) |paren_pos| {
                    if (paren_pos + 2 < content.len) {
                        state = content[paren_pos + 2];
                    }
                    var parts = std.mem.tokenizeAny(u8, content[paren_pos + 2 ..], " ");
                    _ = parts.next(); // state
                    if (parts.next()) |s| ppid = std.fmt.parseInt(i32, s, 10) catch 0;
                    _ = parts.next(); // pgrp
                    _ = parts.next(); // session
                    if (parts.next()) |s| tty_nr = std.fmt.parseInt(i32, s, 10) catch 0;
                    _ = parts.next(); // tpgid
                    _ = parts.next(); // flags
                    _ = parts.next(); // minflt
                    _ = parts.next(); // cminflt
                    _ = parts.next(); // majflt
                    _ = parts.next(); // cmajflt
                    if (parts.next()) |s| utime = std.fmt.parseInt(u64, s, 10) catch 0;
                    if (parts.next()) |s| stime = std.fmt.parseInt(u64, s, 10) catch 0;
                    _ = parts.next(); // cutime
                    _ = parts.next(); // cstime
                    _ = parts.next(); // priority
                    _ = parts.next(); // nice
                    _ = parts.next(); // num_threads
                    _ = parts.next(); // itrealvalue
                    if (parts.next()) |s| start_time = std.fmt.parseInt(u64, s, 10) catch 0;
                    if (parts.next()) |s| vsize = std.fmt.parseInt(u64, s, 10) catch 0;
                    if (parts.next()) |s| rss = std.fmt.parseInt(u64, s, 10) catch 0;
                }
            }
        }
    }

    // Read UID from status
    const status_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{pid}) catch return error.PathTooLong;
    path_buf[status_path.len] = 0;
    var uid: u32 = 0;
    {
        const fd = open(@ptrCast(&path_buf), O_RDONLY);
        if (fd >= 0) {
            defer _ = close(fd);
            var buf: [2048]u8 = undefined;
            const len = c_read(fd, &buf, buf.len);
            if (len > 0) {
                const ulen: usize = @intCast(len);
                if (std.mem.indexOf(u8, buf[0..ulen], "Uid:")) |pos| {
                    var line_end = pos;
                    while (line_end < ulen and buf[line_end] != '\n') line_end += 1;
                    var parts = std.mem.tokenizeAny(u8, buf[pos..line_end], " \t");
                    _ = parts.next();
                    if (parts.next()) |s| uid = std.fmt.parseInt(u32, s, 10) catch 0;
                }
            }
        }
    }

    // Get TTY name
    const tty = blk: {
        if (tty_nr == 0) break :blk try allocator.dupe(u8, "?");
        const major = @as(u32, @intCast((tty_nr >> 8) & 0xff));
        const minor = @as(u32, @intCast(tty_nr & 0xff));
        if (major == 136) {
            // pts
            var tty_buf: [16]u8 = undefined;
            const tty_name = std.fmt.bufPrint(&tty_buf, "pts/{d}", .{minor}) catch "?";
            break :blk try allocator.dupe(u8, tty_name);
        } else if (major == 4 and minor < 64) {
            var tty_buf: [16]u8 = undefined;
            const tty_name = std.fmt.bufPrint(&tty_buf, "tty{d}", .{minor}) catch "?";
            break :blk try allocator.dupe(u8, tty_name);
        }
        break :blk try allocator.dupe(u8, "?");
    };
    errdefer allocator.free(tty);

    return ProcessInfo{
        .pid = pid,
        .ppid = ppid,
        .uid = uid,
        .state = state,
        .name = name,
        .cmdline = cmdline,
        .utime = utime,
        .stime = stime,
        .vsize = vsize,
        .rss = rss,
        .tty = tty,
        .start_time = start_time,
    };
}

fn printHelp() void {
    writeStdout(
        \\Usage: zps [OPTIONS]
        \\
        \\Report process status.
        \\
        \\Options:
        \\  -a, -e, --all      show all processes
        \\  -f, --full         full format (show command line)
        \\  -l, --long         long format
        \\  aux                BSD style all processes with details
        \\  -u, --user UID     show only processes for UID
        \\  -p, --pid PID      show only specified PID
        \\  -h, --help         display this help
        \\  -V, --version      display version
        \\
        \\Examples:
        \\  zps                Show current user's processes
        \\  zps -a             Show all processes
        \\  zps -af            All processes, full command line
        \\  zps aux            BSD style listing
        \\  zps -u 1000        Processes for UID 1000
        \\  zps -p 1234        Show only PID 1234
        \\
    , .{});
}
