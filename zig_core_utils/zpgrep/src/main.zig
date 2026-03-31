//! zpgrep - Search for processes by name
//!
//! A Zig implementation of pgrep.
//! Finds processes by name pattern and displays their PIDs.
//!
//! Usage: zpgrep [OPTIONS] PATTERN

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
const c_read = @extern(*const fn (c_int, [*]u8, usize) callconv(.c) isize, .{ .name = "read" });

const O_RDONLY: c_int = 0;

// Writers
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
    var full_match = false;
    var exact_match = false;
    var count_only = false;
    var list_name = false;
    var list_full = false;
    var newest_only = false;
    var oldest_only = false;
    var user_filter: ?u32 = null;
    var delimiter: []const u8 = "\n";
    var pattern: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            writeStdout("zpgrep {s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--full")) {
            full_match = true;
        } else if (std.mem.eql(u8, arg, "-x") or std.mem.eql(u8, arg, "--exact")) {
            exact_match = true;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
            count_only = true;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list-name")) {
            list_name = true;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--list-full")) {
            list_full = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--newest")) {
            newest_only = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--oldest")) {
            oldest_only = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--delimiter")) {
            if (i + 1 >= args.len) {
                writeStderr("zpgrep: option requires an argument -- 'd'\n", .{});
                std.process.exit(2);
            }
            i += 1;
            delimiter = args[i];
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--uid")) {
            if (i + 1 >= args.len) {
                writeStderr("zpgrep: option requires an argument -- 'u'\n", .{});
                std.process.exit(2);
            }
            i += 1;
            user_filter = std.fmt.parseInt(u32, args[i], 10) catch {
                writeStderr("zpgrep: invalid user ID: {s}\n", .{args[i]});
                std.process.exit(2);
            };
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            // Combined short options (but not -d or -u which need args)
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                const ch = arg[j];
                switch (ch) {
                    'f' => full_match = true,
                    'x' => exact_match = true,
                    'c' => count_only = true,
                    'l' => list_name = true,
                    'a' => list_full = true,
                    'n' => newest_only = true,
                    'o' => oldest_only = true,
                    'd' => {
                        // Rest of arg is delimiter, or next arg
                        if (j + 1 < arg.len) {
                            delimiter = arg[j + 1 ..];
                        } else if (i + 1 < args.len) {
                            i += 1;
                            delimiter = args[i];
                        } else {
                            writeStderr("zpgrep: option requires an argument -- 'd'\n", .{});
                            std.process.exit(2);
                        }
                        break;
                    },
                    'u' => {
                        if (i + 1 >= args.len) {
                            writeStderr("zpgrep: option requires an argument -- 'u'\n", .{});
                            std.process.exit(2);
                        }
                        i += 1;
                        user_filter = std.fmt.parseInt(u32, args[i], 10) catch {
                            writeStderr("zpgrep: invalid user ID: {s}\n", .{args[i]});
                            std.process.exit(2);
                        };
                        break;
                    },
                    else => {
                        writeStderr("zpgrep: invalid option -- '{c}'\n", .{ch});
                        std.process.exit(2);
                    },
                }
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            pattern = arg;
        } else {
            writeStderr("zpgrep: invalid option: {s}\n", .{arg});
            std.process.exit(2);
        }
    }

    if (pattern == null) {
        writeStderr("zpgrep: no process selection criteria\n", .{});
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

    // Output results
    var first = true;
    for (targets) |p| {
        if (!first) {
            writeStdout("{s}", .{delimiter});
        }
        first = false;

        if (list_full) {
            writeStdout("{d} {s}", .{ p.pid, p.cmdline });
        } else if (list_name) {
            writeStdout("{d} {s}", .{ p.pid, p.name });
        } else {
            writeStdout("{d}", .{p.pid});
        }
    }
    writeStdout("\n", .{});
}

fn findProcesses(
    allocator: std.mem.Allocator,
    matches: *std.ArrayListUnmanaged(ProcessInfo),
    pattern: []const u8,
    full_match: bool,
    exact_match: bool,
    user_filter: ?u32,
) !void {
    const dir = opendir("/proc") orelse return;
    defer _ = closedir(dir);

    while (readdir(dir)) |entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.d_name);
        const name = std.mem.sliceTo(name_ptr, 0);

        const pid = std.fmt.parseInt(i32, name, 10) catch continue;
        const info = readProcessInfo(allocator, pid) catch continue;

        if (user_filter) |uid| {
            if (info.uid != uid) {
                allocator.free(info.name);
                allocator.free(info.cmdline);
                continue;
            }
        }

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

    // Read comm
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
        for (buf[0..ulen]) |*ch| {
            if (ch.* == 0) ch.* = ' ';
        }
        var end = ulen;
        while (end > 0 and buf[end - 1] == ' ') end -= 1;
        break :blk try allocator.dupe(u8, buf[0..end]);
    };
    errdefer allocator.free(cmdline);

    // Read UID
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
                if (std.mem.indexOf(u8, content, "Uid:")) |pos| {
                    var line_end = pos;
                    while (line_end < content.len and content[line_end] != '\n') line_end += 1;
                    var parts = std.mem.tokenizeAny(u8, content[pos..line_end], " \t");
                    _ = parts.next();
                    if (parts.next()) |uid_str| {
                        uid = std.fmt.parseInt(u32, uid_str, 10) catch 0;
                    }
                }
            }
        }
    }

    // Read start time
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
                if (std.mem.lastIndexOf(u8, content, ")")) |paren_pos| {
                    var parts = std.mem.tokenizeAny(u8, content[paren_pos + 1 ..], " ");
                    var field: u32 = 0;
                    while (field < 19) : (field += 1) _ = parts.next();
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

fn printHelp() void {
    writeStdout(
        \\Usage: zpgrep [OPTIONS] PATTERN
        \\
        \\Search for processes matching PATTERN and display their PIDs.
        \\
        \\Options:
        \\  -f, --full         match against full command line
        \\  -x, --exact        require exact match of process name
        \\  -n, --newest       select most recently started process
        \\  -o, --oldest       select least recently started process
        \\  -u, --uid UID      match only processes with this UID
        \\  -c, --count        count matching processes
        \\  -l, --list-name    show process name with PID
        \\  -a, --list-full    show full command line with PID
        \\  -d, --delimiter D  set output delimiter (default: newline)
        \\  -h, --help         display this help
        \\  -V, --version      display version
        \\
        \\Exit status:
        \\   0  One or more processes matched
        \\   1  No processes matched
        \\   2  Syntax or usage error
        \\
        \\Examples:
        \\  zpgrep bash           Find PIDs of bash processes
        \\  zpgrep -l bash        Show PIDs with process names
        \\  zpgrep -a bash        Show PIDs with full command lines
        \\  zpgrep -f "python"    Match in full command line
        \\  zpgrep -x bash        Only exact "bash" matches
        \\  zpgrep -n sleep       Find newest sleep process
        \\  zpgrep -u 1000 python Find python owned by UID 1000
        \\  zpgrep -c ssh         Count ssh processes
        \\  zpgrep -d, bash       Comma-separated output
        \\
    , .{});
}
