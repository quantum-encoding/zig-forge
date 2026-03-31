//! zuptime - Show how long the system has been running
//!
//! High-performance uptime implementation in Zig.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

extern "c" fn time(t: ?*i64) i64;
extern "c" fn localtime(t: *const i64) *const Tm;

const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
};

const VERSION = "1.0.0";

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zuptime [OPTION]...
        \\Print the current time, how long the system has been running,
        \\the number of users, and the system load averages.
        \\
        \\Options:
        \\  -p, --pretty   Show uptime in pretty format
        \\  -s, --since    System up since (boot time)
        \\      --help     Display this help and exit
        \\      --version  Output version information and exit
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zuptime " ++ VERSION ++ "\n");
}

fn readFile(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    const fd = libc.open(path, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) return null;
    defer _ = libc.close(fd);
    const n = libc.read(fd, buf.ptr, buf.len);
    if (n <= 0) return null;
    return buf[0..@intCast(n)];
}

fn parseUptime() ?struct { uptime_secs: u64, idle_secs: u64 } {
    var buf: [128]u8 = undefined;
    const data = readFile("/proc/uptime", &buf) orelse return null;

    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, data, " \n"), ' ');
    const uptime_str = parts.next() orelse return null;
    const idle_str = parts.next() orelse return null;

    // Parse float-like "12345.67" - just take integer part
    var up_int = std.mem.splitScalar(u8, uptime_str, '.');
    var idle_int = std.mem.splitScalar(u8, idle_str, '.');

    const uptime = std.fmt.parseInt(u64, up_int.next() orelse return null, 10) catch return null;
    const idle = std.fmt.parseInt(u64, idle_int.next() orelse return null, 10) catch return null;

    return .{ .uptime_secs = uptime, .idle_secs = idle };
}

// Static buffer for load averages
var g_load_buf: [128]u8 = undefined;

fn parseLoadAvg() ?struct { load1: []const u8, load5: []const u8, load15: []const u8 } {
    const data = readFile("/proc/loadavg", &g_load_buf) orelse return null;

    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, data, " \n"), ' ');
    const load1 = parts.next() orelse return null;
    const load5 = parts.next() orelse return null;
    const load15 = parts.next() orelse return null;

    return .{ .load1 = load1, .load5 = load5, .load15 = load15 };
}

fn countUsers() u32 {
    // Count logged in users from /var/run/utmp
    // Simplified: just return 1 for now (proper impl would parse utmp)
    var buf: [4096]u8 = undefined;
    const data = readFile("/var/run/utmp", &buf) orelse return 1;
    
    // Each utmp entry is 384 bytes on x86_64 Linux
    // User entries have type 7 (USER_PROCESS) at offset 0
    const entry_size: usize = 384;
    var users: u32 = 0;
    var offset: usize = 0;
    
    while (offset + entry_size <= data.len) : (offset += entry_size) {
        // Check type field (first 4 bytes as i32)
        const entry_type = std.mem.readInt(i32, data[offset..][0..4], .little);
        if (entry_type == 7) { // USER_PROCESS
            users += 1;
        }
    }
    
    return if (users > 0) users else 1;
}

fn formatDuration(secs: u64, buf: []u8) []const u8 {
    const days = secs / 86400;
    const hours = (secs % 86400) / 3600;
    const mins = (secs % 3600) / 60;

    if (days > 0) {
        if (hours > 0) {
            return std.fmt.bufPrint(buf, "{d} day(s), {d}:{d:0>2}", .{ days, hours, mins }) catch buf[0..0];
        } else {
            return std.fmt.bufPrint(buf, "{d} day(s), {d} min", .{ days, mins }) catch buf[0..0];
        }
    } else if (hours > 0) {
        return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ hours, mins }) catch buf[0..0];
    } else {
        return std.fmt.bufPrint(buf, "{d} min", .{mins}) catch buf[0..0];
    }
}

fn formatPretty(secs: u64, buf: []u8) []const u8 {
    const days = secs / 86400;
    const hours = (secs % 86400) / 3600;
    const mins = (secs % 3600) / 60;

    var pos: usize = 0;
    const prefix = "up ";
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    if (days > 0) {
        const d = std.fmt.bufPrint(buf[pos..], "{d} day{s}, ", .{ days, if (days == 1) "" else "s" }) catch return buf[0..pos];
        pos += d.len;
    }
    if (hours > 0) {
        const h = std.fmt.bufPrint(buf[pos..], "{d} hour{s}, ", .{ hours, if (hours == 1) "" else "s" }) catch return buf[0..pos];
        pos += h.len;
    }
    const m = std.fmt.bufPrint(buf[pos..], "{d} minute{s}", .{ mins, if (mins == 1) "" else "s" }) catch return buf[0..pos];
    pos += m.len;

    return buf[0..pos];
}

pub fn main(init: std.process.Init) void {
    var pretty = false;
    var since = false;

    // Parse arguments
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // skip program name
    while (args.next()) |arg| {

        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--pretty")) {
            pretty = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--since")) {
            since = true;
        }
    }

    const uptime_info = parseUptime() orelse {
        writeStderr("zuptime: cannot read /proc/uptime\n");
        return;
    };

    if (since) {
        // Show boot time
        const now = time(null);
        const boot_time = now - @as(i64, @intCast(uptime_info.uptime_secs));
        const tm = localtime(&boot_time);

        var buf: [64]u8 = undefined;
        const time_str = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}\n", .{
            @as(u32, @intCast(tm.tm_year)) + 1900,
            @as(u32, @intCast(tm.tm_mon)) + 1,
            @as(u32, @intCast(tm.tm_mday)),
            @as(u32, @intCast(tm.tm_hour)),
            @as(u32, @intCast(tm.tm_min)),
            @as(u32, @intCast(tm.tm_sec)),
        }) catch return;
        writeStdout(time_str);
        return;
    }

    if (pretty) {
        var buf: [128]u8 = undefined;
        const pretty_str = formatPretty(uptime_info.uptime_secs, &buf);
        writeStdout(pretty_str);
        writeStdout("\n");
        return;
    }

    // Standard format: " HH:MM:SS up X days, H:MM, N users, load average: X.XX, X.XX, X.XX"
    const now = time(null);
    const tm = localtime(&now);

    var output_buf: [256]u8 = undefined;
    var pos: usize = 0;

    // Current time
    const time_part = std.fmt.bufPrint(output_buf[pos..], " {d:0>2}:{d:0>2}:{d:0>2} up ", .{
        @as(u32, @intCast(tm.tm_hour)),
        @as(u32, @intCast(tm.tm_min)),
        @as(u32, @intCast(tm.tm_sec)),
    }) catch return;
    pos += time_part.len;

    // Uptime duration
    var dur_buf: [64]u8 = undefined;
    const duration = formatDuration(uptime_info.uptime_secs, &dur_buf);
    @memcpy(output_buf[pos..][0..duration.len], duration);
    pos += duration.len;

    // Users
    const users = countUsers();
    const users_part = std.fmt.bufPrint(output_buf[pos..], ", {d} user{s}, ", .{
        users,
        if (users == 1) "" else "s",
    }) catch return;
    pos += users_part.len;

    // Load averages
    if (parseLoadAvg()) |load| {
        const load_part = std.fmt.bufPrint(output_buf[pos..], "load average: {s}, {s}, {s}\n", .{
            load.load1,
            load.load5,
            load.load15,
        }) catch return;
        pos += load_part.len;
    }

    writeStdout(output_buf[0..pos]);
}
