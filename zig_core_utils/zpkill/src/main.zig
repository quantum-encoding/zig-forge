//! zpkill - Send signals to processes by name
//!
//! A Zig implementation of pkill.
//! Finds processes by name pattern and sends signals to them.
//!
//! Usage: zpkill [OPTIONS] PATTERN

const std = @import("std");
const libc = std.c;

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

extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn getuid() c_uint;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn opendir(name: [*:0]const u8) ?*DIR;
extern "c" fn closedir(dirp: *DIR) c_int;
extern "c" fn readdir(dirp: *DIR) ?*dirent;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
const c_read = @extern(*const fn (c_int, [*]u8, usize) callconv(.c) isize, .{ .name = "read" });

const O_RDONLY: c_int = 0;

// Stderr/stdout writers
fn writeStderr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(2, msg.ptr, msg.len);
}

fn writeStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(1, msg.ptr, msg.len);
}

const ProcessInfo = struct {
    pid: i32,
    name: []const u8,
    cmdline: []const u8,
    uid: u32,
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
    var signal_num: u6 = 15; // SIGTERM
    var full_match = false;
    var exact_match = false;
    var count_only = false;
    var list_pids = false;
    var newest_only = false;
    var oldest_only = false;
    var user_filter: ?u32 = null;
    var pattern: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            writeStdout("zpkill {s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--full")) {
            full_match = true;
        } else if (std.mem.eql(u8, arg, "-x") or std.mem.eql(u8, arg, "--exact")) {
            exact_match = true;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
            count_only = true;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
            list_pids = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--newest")) {
            newest_only = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--oldest")) {
            oldest_only = true;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--uid")) {
            if (i + 1 >= args.len) {
                writeStderr("zpkill: option requires an argument -- 'u'\n", .{});
                std.process.exit(2);
            }
            i += 1;
            user_filter = std.fmt.parseInt(u32, args[i], 10) catch {
                writeStderr("zpkill: invalid user ID: {s}\n", .{args[i]});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--signal")) {
            if (i + 1 >= args.len) {
                writeStderr("zpkill: option requires an argument -- 's'\n", .{});
                std.process.exit(2);
            }
            i += 1;
            signal_num = parseSignal(args[i]) orelse {
                writeStderr("zpkill: invalid signal: {s}\n", .{args[i]});
                std.process.exit(2);
            };
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            // Could be -SIGNAL or combined options
            const spec = arg[1..];
            if (parseSignal(spec)) |sig| {
                signal_num = sig;
            } else {
                // Try as combined short options
                for (spec) |ch| {
                    switch (ch) {
                        'f' => full_match = true,
                        'x' => exact_match = true,
                        'c' => count_only = true,
                        'l' => list_pids = true,
                        'n' => newest_only = true,
                        'o' => oldest_only = true,
                        else => {
                            writeStderr("zpkill: invalid option -- '{c}'\n", .{ch});
                            std.process.exit(2);
                        },
                    }
                }
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            pattern = arg;
        } else {
            writeStderr("zpkill: invalid option: {s}\n", .{arg});
            std.process.exit(2);
        }
    }

    if (pattern == null) {
        writeStderr("zpkill: no process selection criteria\n", .{});
        std.process.exit(2);
    }

    // Find matching processes
    var matches: std.ArrayListUnmanaged(ProcessInfo) = .empty;
    defer {
        for (matches.items) |p| {
            allocator.free(p.name);
            allocator.free(p.cmdline);
        }
        matches.deinit(allocator);
    }

    try findProcesses(allocator, &matches, pattern.?, full_match, exact_match, user_filter);

    if (matches.items.len == 0) {
        std.process.exit(1); // No matches
    }

    // Filter to newest/oldest if requested
    var targets = matches.items;
    var single_target: [1]ProcessInfo = undefined;

    if (newest_only or oldest_only) {
        var selected = targets[0];
        for (targets[1..]) |p| {
            if (newest_only and p.start_time > selected.start_time) {
                selected = p;
            } else if (oldest_only and p.start_time < selected.start_time) {
                selected = p;
            }
        }
        single_target[0] = selected;
        targets = &single_target;
    }

    // Count only mode
    if (count_only) {
        writeStdout("{d}\n", .{targets.len});
        return;
    }

    // List mode
    if (list_pids) {
        for (targets) |p| {
            writeStdout("{d}\n", .{p.pid});
        }
        return;
    }

    // Send signals
    var killed: u32 = 0;
    var errors: u32 = 0;

    for (targets) |p| {
        const result = kill(p.pid, @intCast(signal_num));
        if (result == 0) {
            killed += 1;
        } else {
            errors += 1;
        }
    }

    if (errors > 0 and killed == 0) {
        std.process.exit(1);
    }
}

fn findProcesses(
    allocator: std.mem.Allocator,
    matches: *std.ArrayListUnmanaged(ProcessInfo),
    pattern: []const u8,
    full_match: bool,
    exact_match: bool,
    user_filter: ?u32,
) !void {
    // Open /proc directory
    const dir = opendir("/proc") orelse return;
    defer _ = closedir(dir);

    while (readdir(dir)) |entry| {
        // Get entry name (null-terminated)
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.d_name);
        const name = std.mem.sliceTo(name_ptr, 0);

        // Only process numeric directories (PIDs)
        const pid = std.fmt.parseInt(i32, name, 10) catch continue;

        // Read process info
        const info = readProcessInfo(allocator, pid) catch continue;

        // Apply user filter
        if (user_filter) |uid| {
            if (info.uid != uid) {
                allocator.free(info.name);
                allocator.free(info.cmdline);
                continue;
            }
        }

        // Match pattern
        const match_str = if (full_match) info.cmdline else info.name;
        const matched = if (exact_match)
            std.mem.eql(u8, match_str, pattern)
        else
            std.mem.indexOf(u8, match_str, pattern) != null;

        if (matched) {
            try matches.append(allocator, info);
        } else {
            allocator.free(info.name);
            allocator.free(info.cmdline);
        }
    }
}

fn readProcessInfo(allocator: std.mem.Allocator, pid: i32) !ProcessInfo {
    var path_buf: [64]u8 = undefined;

    // Read comm (process name)
    const comm_len = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return error.PathTooLong;
    path_buf[comm_len.len] = 0;
    const name = blk: {
        const fd = open(@ptrCast(&path_buf), O_RDONLY);
        if (fd < 0) return error.ProcessGone;
        defer _ = close(fd);
        var buf: [256]u8 = undefined;
        const len = c_read(fd, &buf, buf.len);
        if (len <= 0) return error.EmptyName;
        const ulen: usize = @intCast(len);
        // Remove trailing newline
        const end = if (ulen > 0 and buf[ulen - 1] == '\n') ulen - 1 else ulen;
        break :blk try allocator.dupe(u8, buf[0..end]);
    };
    errdefer allocator.free(name);

    // Read cmdline
    const cmdline_len = std.fmt.bufPrint(&path_buf, "/proc/{d}/cmdline", .{pid}) catch return error.PathTooLong;
    path_buf[cmdline_len.len] = 0;
    const cmdline = blk: {
        const fd = open(@ptrCast(&path_buf), O_RDONLY);
        if (fd < 0) break :blk try allocator.dupe(u8, name);
        defer _ = close(fd);
        var buf: [4096]u8 = undefined;
        const len = c_read(fd, &buf, buf.len);
        if (len <= 0) break :blk try allocator.dupe(u8, name);
        const ulen: usize = @intCast(len);
        // Replace null bytes with spaces
        for (buf[0..ulen]) |*ch| {
            if (ch.* == 0) ch.* = ' ';
        }
        // Trim trailing space
        var end = ulen;
        while (end > 0 and buf[end - 1] == ' ') end -= 1;
        break :blk try allocator.dupe(u8, buf[0..end]);
    };
    errdefer allocator.free(cmdline);

    // Read UID from status
    const status_len = std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{pid}) catch return error.PathTooLong;
    path_buf[status_len.len] = 0;
    var uid: u32 = 0;
    {
        const fd = open(@ptrCast(&path_buf), O_RDONLY);
        if (fd >= 0) {
            defer _ = close(fd);
            var buf: [4096]u8 = undefined;
            const len = c_read(fd, &buf, buf.len);
            if (len > 0) {
                const ulen: usize = @intCast(len);
                const content = buf[0..ulen];

                // Parse Uid line
                if (std.mem.indexOf(u8, content, "Uid:")) |pos| {
                    var line_end = pos;
                    while (line_end < content.len and content[line_end] != '\n') line_end += 1;
                    const line = content[pos..line_end];
                    var parts = std.mem.tokenizeAny(u8, line, " \t");
                    _ = parts.next(); // Skip "Uid:"
                    if (parts.next()) |uid_str| {
                        uid = std.fmt.parseInt(u32, uid_str, 10) catch 0;
                    }
                }
            }
        }
    }

    // Read start time from stat
    const stat_len = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return error.PathTooLong;
    path_buf[stat_len.len] = 0;
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

                // Find end of comm field (after last ')')
                if (std.mem.lastIndexOf(u8, content, ")")) |paren_pos| {
                    const after_comm = content[paren_pos + 1 ..];
                    var parts = std.mem.tokenizeAny(u8, after_comm, " ");
                    // Skip 19 fields to get starttime (field 22)
                    var field: u32 = 0;
                    while (field < 19) : (field += 1) {
                        _ = parts.next();
                    }
                    if (parts.next()) |time_str| {
                        start_time = std.fmt.parseInt(u64, time_str, 10) catch 0;
                    }
                }
            }
        }
    }

    return ProcessInfo{
        .pid = pid,
        .name = name,
        .cmdline = cmdline,
        .uid = uid,
        .start_time = start_time,
    };
}

fn parseSignal(spec: []const u8) ?u6 {
    // Try as number
    if (std.fmt.parseInt(u6, spec, 10)) |num| {
        if (num <= 31) return num;
        return null;
    } else |_| {}

    // Try as signal name
    var name = spec;
    if (name.len > 3 and std.ascii.eqlIgnoreCase(name[0..3], "SIG")) {
        name = name[3..];
    }

    const sig_names = [_]struct { name: []const u8, num: u6 }{
        .{ .name = "HUP", .num = 1 },
        .{ .name = "INT", .num = 2 },
        .{ .name = "QUIT", .num = 3 },
        .{ .name = "ILL", .num = 4 },
        .{ .name = "TRAP", .num = 5 },
        .{ .name = "ABRT", .num = 6 },
        .{ .name = "BUS", .num = 7 },
        .{ .name = "FPE", .num = 8 },
        .{ .name = "KILL", .num = 9 },
        .{ .name = "USR1", .num = 10 },
        .{ .name = "SEGV", .num = 11 },
        .{ .name = "USR2", .num = 12 },
        .{ .name = "PIPE", .num = 13 },
        .{ .name = "ALRM", .num = 14 },
        .{ .name = "TERM", .num = 15 },
        .{ .name = "STKFLT", .num = 16 },
        .{ .name = "CHLD", .num = 17 },
        .{ .name = "CONT", .num = 18 },
        .{ .name = "STOP", .num = 19 },
        .{ .name = "TSTP", .num = 20 },
        .{ .name = "TTIN", .num = 21 },
        .{ .name = "TTOU", .num = 22 },
        .{ .name = "URG", .num = 23 },
        .{ .name = "XCPU", .num = 24 },
        .{ .name = "XFSZ", .num = 25 },
        .{ .name = "VTALRM", .num = 26 },
        .{ .name = "PROF", .num = 27 },
        .{ .name = "WINCH", .num = 28 },
        .{ .name = "IO", .num = 29 },
        .{ .name = "PWR", .num = 30 },
        .{ .name = "SYS", .num = 31 },
    };

    for (sig_names) |sig| {
        if (std.ascii.eqlIgnoreCase(name, sig.name)) {
            return sig.num;
        }
    }

    return null;
}

fn printHelp() void {
    writeStdout(
        \\Usage: zpkill [OPTIONS] PATTERN
        \\
        \\Send signals to processes matching PATTERN.
        \\
        \\Options:
        \\  -SIGNAL            specify signal (e.g., -9, -KILL)
        \\  -s, --signal SIG   specify signal by name or number
        \\  -f, --full         match against full command line
        \\  -x, --exact        require exact match of process name
        \\  -n, --newest       select most recently started process
        \\  -o, --oldest       select least recently started process
        \\  -u, --uid UID      match only processes with this UID
        \\  -c, --count        count matching processes, don't signal
        \\  -l, --list         list matching PIDs, don't signal
        \\  -h, --help         display this help
        \\  -V, --version      display version
        \\
        \\Exit status:
        \\   0  One or more processes matched
        \\   1  No processes matched
        \\   2  Syntax or usage error
        \\
        \\Examples:
        \\  zpkill firefox         Kill all firefox processes
        \\  zpkill -9 chrome       Force kill all chrome processes
        \\  zpkill -HUP nginx      Send SIGHUP to nginx (reload)
        \\  zpkill -f "python app" Match full command line
        \\  zpkill -x bash         Only exact "bash" (not bashrc)
        \\  zpkill -n sleep        Kill newest sleep process
        \\  zpkill -u 1000 python  Kill python owned by UID 1000
        \\  zpkill -l java         List PIDs of java processes
        \\  zpkill -c ssh          Count ssh processes
        \\
    , .{});
}
