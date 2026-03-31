const std = @import("std");
const posix = std.posix;
const libc = std.c;
const ctime = @cImport(@cInclude("time.h"));

// Linux utmp structure
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

const USER_PROCESS = 7;

const OutputBuffer = struct {
    buf: [8192]u8 = undefined,
    pos: usize = 0,

    fn write(self: *OutputBuffer, data: []const u8) void {
        for (data) |c| self.writeByte(c);
    }

    fn writeByte(self: *OutputBuffer, c: u8) void {
        self.buf[self.pos] = c;
        self.pos += 1;
        if (self.pos == self.buf.len) self.flush();
    }

    fn writeSpaces(self: *OutputBuffer, n: usize) void {
        var i: usize = 0;
        while (i < n) : (i += 1) self.writeByte(' ');
    }

    fn flush(self: *OutputBuffer) void {
        if (self.pos > 0) {
            _ = libc.write(libc.STDOUT_FILENO, &self.buf, self.pos);
            self.pos = 0;
        }
    }
};

fn nullTerminated(buf: []const u8) []const u8 {
    for (buf, 0..) |c, i| {
        if (c == 0) return buf[0..i];
    }
    return buf;
}

fn formatTime(tv_sec: i32, time_buf: *[16]u8) []const u8 {
    var t: ctime.time_t = @intCast(tv_sec);
    const tm_ptr = ctime.localtime(&t);
    if (tm_ptr) |p| {
        const tm = p.*;
        _ = std.fmt.bufPrint(time_buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
            @as(u32, @intCast(tm.tm_year + 1900)),
            @as(u32, @intCast(tm.tm_mon + 1)),
            @as(u32, @intCast(tm.tm_mday)),
            @as(u32, @intCast(tm.tm_hour)),
            @as(u32, @intCast(tm.tm_min)),
        }) catch return "????-??-?? ??:??";
        return time_buf[0..16];
    }
    return "????-??-?? ??:??";
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();

    var show_heading = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            const help =
                \\Usage: zwho [OPTION]...
                \\Show who is logged on.
                \\
                \\  -H, --heading    print column headings
                \\      --help       display this help and exit
                \\
            ;
            _ = libc.write(libc.STDOUT_FILENO, help.ptr, help.len);
            return;
        } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--heading")) {
            show_heading = true;
        }
    }

    var out = OutputBuffer{};

    if (show_heading) {
        out.write("NAME     LINE         TIME             HOST\n");
    }

    // Read /var/run/utmp
    var fd = libc.open("/var/run/utmp", .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) {
        // Try /run/utmp as fallback
        fd = libc.open("/run/utmp", .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd < 0) {
            out.flush();
            return;
        }
    }
    defer _ = libc.close(fd);

    processUtmp(fd, &out);
    out.flush();
}

fn processUtmp(fd: c_int, out: *OutputBuffer) void {
    var buf: [@sizeOf(Utmp)]u8 = undefined;

    while (true) {
        const n = libc.read(fd, &buf, buf.len);
        if (n < @sizeOf(Utmp)) break;

        const entry: *const Utmp = @ptrCast(@alignCast(&buf));

        if (entry.ut_type != USER_PROCESS) continue;

        const user = nullTerminated(&entry.ut_user);
        const line = nullTerminated(&entry.ut_line);
        const host = nullTerminated(&entry.ut_host);

        if (user.len == 0) continue;

        // Format: NAME     LINE         TIME             HOST
        out.write(user);
        const user_pad = if (user.len < 8) 9 - user.len else 1;
        out.writeSpaces(user_pad);

        out.write(line);
        const line_pad = if (line.len < 12) 13 - line.len else 1;
        out.writeSpaces(line_pad);

        var time_buf: [16]u8 = undefined;
        const time_str = formatTime(entry.ut_tv.tv_sec, &time_buf);
        out.write(time_str);
        out.writeByte(' ');

        if (host.len > 0) {
            out.writeByte('(');
            out.write(host);
            out.writeByte(')');
        }

        out.writeByte('\n');
    }
}
