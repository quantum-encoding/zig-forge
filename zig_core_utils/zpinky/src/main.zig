//! zpinky - Lightweight finger utility
//!
//! Show user information for logged in users.

const std = @import("std");
const libc = std.c;

const VERSION = "1.0.0";

extern "c" fn time(t: ?*i64) i64;

const UT_USER_PROCESS: i16 = 7;
const UTMP_SIZE: usize = 384;
const UT_NAMESIZE: usize = 32;
const UT_LINESIZE: usize = 32;
const UT_HOSTSIZE: usize = 256;

const Config = struct {
    long_format: bool = false,
    omit_heading: bool = false,
    omit_fullname: bool = false,
    omit_host: bool = false,
    omit_idle: bool = false,
    omit_home_shell: bool = false,
    users: [32][]const u8 = undefined,
    user_count: usize = 0,
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zpinky [OPTION]... [USER]...
        \\Print user information. With no USER, print all logged in users.
        \\
        \\Options:
        \\  -l              Long format output
        \\  -s              Short format output (default)
        \\  -f              Omit column headings in short format
        \\  -w              Omit full name in short format
        \\  -i              Omit full name and remote host
        \\  -q              Omit full name, remote host, and idle time
        \\  -b              Omit home directory and shell in long format
        \\      --help      Display this help and exit
        \\      --version   Output version information and exit
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zpinky " ++ VERSION ++ "\n");
}

fn extractString(data: []const u8, max_len: usize) []const u8 {
    var len: usize = 0;
    while (len < max_len and len < data.len and data[len] != 0) : (len += 1) {}
    return data[0..len];
}

const PasswdInfo = struct {
    username: []const u8,
    fullname: []const u8,
    home: []const u8,
    shell: []const u8,
};

fn parsePasswdLine(line: []const u8, buf: *[1024]u8) ?PasswdInfo {
    var info = PasswdInfo{
        .username = "",
        .fullname = "",
        .home = "",
        .shell = "",
    };

    var field: usize = 0;
    var start: usize = 0;
    var buf_pos: usize = 0;

    for (line, 0..) |c, i| {
        if (c == ':' or i == line.len - 1) {
            const end = if (c == ':') i else i + 1;
            const value = line[start..end];

            const copy_start = buf_pos;
            for (value) |v| {
                if (buf_pos < buf.len) {
                    buf[buf_pos] = v;
                    buf_pos += 1;
                }
            }

            switch (field) {
                0 => info.username = buf[copy_start..buf_pos],
                4 => {
                    // GECOS field - extract first part (full name)
                    var name_end = copy_start;
                    while (name_end < buf_pos and buf[name_end] != ',') : (name_end += 1) {}
                    info.fullname = buf[copy_start..name_end];
                },
                5 => info.home = buf[copy_start..buf_pos],
                6 => info.shell = buf[copy_start..buf_pos],
                else => {},
            }

            field += 1;
            start = i + 1;
        }
    }

    if (info.username.len > 0) return info;
    return null;
}

fn getUserInfo(username: []const u8, buf: *[1024]u8) ?PasswdInfo {
    const fd = libc.open("/etc/passwd", .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) return null;
    defer _ = libc.close(fd);

    var file_buf: [8192]u8 = undefined;
    var line_buf: [512]u8 = undefined;
    var line_len: usize = 0;
    var file_pos: usize = 0;
    var file_len: usize = 0;

    while (true) {
        // Read more if needed
        if (file_pos >= file_len) {
            const n = libc.read(fd, &file_buf, file_buf.len);
            if (n <= 0) break;
            file_len = @intCast(n);
            file_pos = 0;
        }

        const c = file_buf[file_pos];
        file_pos += 1;

        if (c == '\n') {
            if (line_len > 0) {
                if (parsePasswdLine(line_buf[0..line_len], buf)) |info| {
                    if (std.mem.eql(u8, info.username, username)) {
                        return info;
                    }
                }
            }
            line_len = 0;
        } else {
            if (line_len < line_buf.len) {
                line_buf[line_len] = c;
                line_len += 1;
            }
        }
    }

    return null;
}

fn formatTime(timestamp: i64, buf: []u8) []const u8 {
    // Simple time formatting: "Mon HH:MM"
    const secs_per_day: i64 = 86400;
    const secs_per_hour: i64 = 3600;
    const secs_per_min: i64 = 60;

    // Days since epoch to get day of week
    const days = @divFloor(timestamp, secs_per_day);
    const dow = @mod(days + 4, 7); // Jan 1 1970 was Thursday (4)

    const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

    // Time of day
    const time_of_day = @mod(timestamp, secs_per_day);
    const hours: u8 = @intCast(@divFloor(time_of_day, secs_per_hour));
    const mins: u8 = @intCast(@divFloor(@mod(time_of_day, secs_per_hour), secs_per_min));

    return std.fmt.bufPrint(buf, "{s} {d:0>2}:{d:0>2}", .{
        day_names[@intCast(dow)],
        hours,
        mins,
    }) catch "???";
}

fn formatIdle(idle_secs: i64, buf: []u8) []const u8 {
    if (idle_secs < 60) {
        return std.fmt.bufPrint(buf, "  {d:>2}s", .{idle_secs}) catch "?";
    } else if (idle_secs < 3600) {
        const mins = @divFloor(idle_secs, 60);
        return std.fmt.bufPrint(buf, " {d:>2}m", .{mins}) catch "?";
    } else if (idle_secs < 86400) {
        const hours = @divFloor(idle_secs, 3600);
        const mins = @divFloor(@mod(idle_secs, 3600), 60);
        return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ hours, mins }) catch "?";
    } else {
        const days = @divFloor(idle_secs, 86400);
        return std.fmt.bufPrint(buf, "{d}d", .{days}) catch "?";
    }
}

fn getIdleTime(tty: []const u8) i64 {
    _ = tty;
    // Simplified - would need stat() on /dev/tty for real idle time
    return 0;
}

fn printShortFormat(cfg: *const Config) void {
    // Print header
    if (!cfg.omit_heading) {
        writeStdout("Login    ");
        if (!cfg.omit_fullname) {
            writeStdout(" Name              ");
        }
        writeStdout(" TTY      ");
        if (!cfg.omit_idle) {
            writeStdout(" Idle  ");
        }
        writeStdout(" When         ");
        if (!cfg.omit_host) {
            writeStdout(" Where");
        }
        writeStdout("\n");
    }

    // Read utmp
    const fd = libc.open("/var/run/utmp", .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) {
        writeStderr("zpinky: cannot open /var/run/utmp\n");
        return;
    }
    defer _ = libc.close(fd);

    var entry: [UTMP_SIZE]u8 = undefined;

    while (true) {
        const n = libc.read(fd, &entry, entry.len);
        if (n < UTMP_SIZE) break;

        // Check if user process
        const ut_type = std.mem.readInt(i16, entry[0..2], .little);
        if (ut_type != UT_USER_PROCESS) continue;

        const username = extractString(entry[44 .. 44 + UT_NAMESIZE], UT_NAMESIZE);
        const tty = extractString(entry[8 .. 8 + UT_LINESIZE], UT_LINESIZE);
        const host = extractString(entry[76 .. 76 + UT_HOSTSIZE], UT_HOSTSIZE);
        const login_time = std.mem.readInt(i32, entry[340..344], .little);

        // Filter by user if specified
        if (cfg.user_count > 0) {
            var found = false;
            for (cfg.users[0..cfg.user_count]) |u| {
                if (std.mem.eql(u8, u, username)) {
                    found = true;
                    break;
                }
            }
            if (!found) continue;
        }

        // Get user info
        var passwd_buf: [1024]u8 = undefined;
        const user_info = getUserInfo(username, &passwd_buf);

        // Print login name (8 chars)
        var name_buf: [9]u8 = undefined;
        const name_out = std.fmt.bufPrint(&name_buf, "{s:<8}", .{username}) catch username;
        writeStdout(name_out);
        writeStdout(" ");

        // Print full name (18 chars)
        if (!cfg.omit_fullname) {
            var fullname_buf: [19]u8 = undefined;
            const fullname = if (user_info) |info| info.fullname else "";
            const fullname_out = std.fmt.bufPrint(&fullname_buf, "{s:<18}", .{fullname}) catch fullname;
            writeStdout(fullname_out);
            writeStdout(" ");
        }

        // Print TTY (8 chars)
        var tty_buf: [9]u8 = undefined;
        const tty_out = std.fmt.bufPrint(&tty_buf, "{s:<8}", .{tty}) catch tty;
        writeStdout(tty_out);
        writeStdout(" ");

        // Print idle time
        if (!cfg.omit_idle) {
            var idle_buf: [8]u8 = undefined;
            const idle = formatIdle(0, &idle_buf); // Simplified - would need stat() for real idle
            writeStdout(idle);
            writeStdout(" ");
        }

        // Print login time
        var time_buf: [16]u8 = undefined;
        const time_str = formatTime(login_time, &time_buf);
        writeStdout(time_str);
        writeStdout(" ");

        // Print host
        if (!cfg.omit_host and host.len > 0) {
            writeStdout(host);
        }

        writeStdout("\n");
    }
}

fn printLongFormat(cfg: *const Config) void {
    // Read utmp
    const fd = libc.open("/var/run/utmp", .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) {
        writeStderr("zpinky: cannot open /var/run/utmp\n");
        return;
    }
    defer _ = libc.close(fd);

    var entry: [UTMP_SIZE]u8 = undefined;
    var first = true;

    while (true) {
        const n = libc.read(fd, &entry, entry.len);
        if (n < UTMP_SIZE) break;

        const ut_type = std.mem.readInt(i16, entry[0..2], .little);
        if (ut_type != UT_USER_PROCESS) continue;

        const username = extractString(entry[44 .. 44 + UT_NAMESIZE], UT_NAMESIZE);
        const tty = extractString(entry[8 .. 8 + UT_LINESIZE], UT_LINESIZE);
        const login_time = std.mem.readInt(i32, entry[340..344], .little);

        // Filter by user if specified
        if (cfg.user_count > 0) {
            var found = false;
            for (cfg.users[0..cfg.user_count]) |u| {
                if (std.mem.eql(u8, u, username)) {
                    found = true;
                    break;
                }
            }
            if (!found) continue;
        }

        if (!first) writeStdout("\n");
        first = false;

        // Get user info
        var passwd_buf: [1024]u8 = undefined;
        const user_info = getUserInfo(username, &passwd_buf);

        writeStdout("Login name: ");
        writeStdout(username);
        writeStdout("\t\t\t\tIn real life: ");
        if (user_info) |info| {
            if (info.fullname.len > 0) {
                writeStdout(info.fullname);
            } else {
                writeStdout("???");
            }
        } else {
            writeStdout("???");
        }
        writeStdout("\n");

        if (!cfg.omit_home_shell) {
            writeStdout("Directory: ");
            if (user_info) |info| {
                writeStdout(info.home);
            } else {
                writeStdout("???");
            }
            writeStdout("\t\t\tShell: ");
            if (user_info) |info| {
                writeStdout(info.shell);
            } else {
                writeStdout("???");
            }
            writeStdout("\n");
        }

        writeStdout("On since ");
        var time_buf: [16]u8 = undefined;
        writeStdout(formatTime(login_time, &time_buf));
        writeStdout(" on ");
        writeStdout(tty);
        writeStdout("\n");
    }
}

pub fn main(init: std.process.Init) void {
    var cfg = Config{};

    // Collect args into array
    var args_storage: [256][]const u8 = undefined;
    var args_count: usize = 0;
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        if (args_count < args_storage.len) {
            args_storage[args_count] = arg;
            args_count += 1;
        }
    }
    const args = args_storage[0..args_count];

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (std.mem.eql(u8, arg, "-l")) {
            cfg.long_format = true;
        } else if (std.mem.eql(u8, arg, "-s")) {
            cfg.long_format = false;
        } else if (std.mem.eql(u8, arg, "-f")) {
            cfg.omit_heading = true;
        } else if (std.mem.eql(u8, arg, "-w")) {
            cfg.omit_fullname = true;
        } else if (std.mem.eql(u8, arg, "-i")) {
            cfg.omit_fullname = true;
            cfg.omit_host = true;
        } else if (std.mem.eql(u8, arg, "-q")) {
            cfg.omit_fullname = true;
            cfg.omit_host = true;
            cfg.omit_idle = true;
        } else if (std.mem.eql(u8, arg, "-b")) {
            cfg.omit_home_shell = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            if (cfg.user_count < cfg.users.len) {
                cfg.users[cfg.user_count] = arg;
                cfg.user_count += 1;
            }
        }
    }

    if (cfg.long_format) {
        printLongFormat(&cfg);
    } else {
        printShortFormat(&cfg);
    }
}
