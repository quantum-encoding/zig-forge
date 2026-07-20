const std = @import("std");
const libc = std.c;
const c = @cImport({
    @cInclude("time.h");
    @cInclude("utmpx.h");
});

// utmpx ut_type values (POSIX; identical on Linux and macOS/BSD)
const USER_PROCESS = 7;

const OutputBuffer = struct {
    buf: [8192]u8 = undefined,
    pos: usize = 0,

    fn write(self: *OutputBuffer, data: []const u8) void {
        for (data) |ch| self.writeByte(ch);
    }

    fn writeByte(self: *OutputBuffer, ch: u8) void {
        self.buf[self.pos] = ch;
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
    for (buf, 0..) |ch, i| {
        if (ch == 0) return buf[0..i];
    }
    return buf;
}

fn formatTime(tv_sec: c.time_t, time_buf: *[16]u8) []const u8 {
    var t: c.time_t = tv_sec;
    const tm_ptr = c.localtime(&t);
    if (tm_ptr) |p| {
        const tm = p.*;
        // localtime() of any time_t yields tm fields in POSIX-valid ranges
        // (year >= -1900, mon 0..11, etc.), but guard the year explicitly so
        // an out-of-range tv_sec from an attacker-controlled utmpx file can
        // never make the u32 cast underflow/panic. Range failure -> fallback.
        const year: i32 = @as(i32, tm.tm_year) + 1900;
        if (year < 0 or year > 9999) return "????-??-?? ??:??";
        _ = std.fmt.bufPrint(time_buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
            @as(u32, @intCast(year)),
            @as(u32, @intCast(tm.tm_mon + 1)),
            @as(u32, @intCast(tm.tm_mday)),
            @as(u32, @intCast(tm.tm_hour)),
            @as(u32, @intCast(tm.tm_min)),
        }) catch return "????-??-?? ??:??";
        return time_buf[0..16];
    }
    return "????-??-?? ??:??";
}

const help_text =
    \\Usage: zwho [OPTION]...
    \\Print information about users who are currently logged in.
    \\
    \\  -H, --heading    print line of column headings
    \\  -q, --count      all login names and number of users logged on
    \\      --help       display this help and exit
    \\      --version    output version information and exit
    \\
    \\Reads the system utmpx database (/var/run/utmpx on macOS/BSD,
    \\/var/run/utmp on Linux).
    \\
;

const version_text = "zwho (zig_core_utils) 1.0\n";

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();

    var show_heading = false;
    var count_only = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            _ = libc.write(libc.STDOUT_FILENO, help_text.ptr, help_text.len);
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            _ = libc.write(libc.STDOUT_FILENO, version_text.ptr, version_text.len);
            return;
        } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--heading")) {
            show_heading = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--count")) {
            count_only = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            // Unknown option: match GNU who — diagnostic to stderr, exit 1.
            writeStderr("zwho: unrecognized option '");
            writeStderr(arg);
            writeStderr("'\nTry 'zwho --help' for more information.\n");
            std.process.exit(1);
        } else {
            // Non-option argument (FILE / ARG1 ARG2). Not implemented; GNU who
            // would read FILE or presume 'am i'. Refuse rather than silently
            // producing wrong (live-db) output.
            writeStderr("zwho: file and ARG1 ARG2 arguments are not supported\n");
            std.process.exit(1);
        }
    }

    var out = OutputBuffer{};

    if (count_only) {
        countUsers(&out);
        out.flush();
        return;
    }

    if (show_heading) {
        out.write("NAME     LINE         TIME             COMMENT\n");
    }

    processUtmpx(&out);
    out.flush();
}

fn countUsers(out: *OutputBuffer) void {
    c.setutxent();
    defer c.endutxent();

    var n: usize = 0;
    while (c.getutxent()) |entry| {
        if (entry[0].ut_type != USER_PROCESS) continue;
        const user = nullTerminated(entry[0].ut_user[0..]);
        if (user.len == 0) continue;
        if (n > 0) out.writeByte(' ');
        out.write(user);
        n += 1;
    }
    out.writeByte('\n');

    var num_buf: [24]u8 = undefined;
    const num = std.fmt.bufPrint(&num_buf, "# users={d}\n", .{n}) catch "# users=?\n";
    out.write(num);
}

fn processUtmpx(out: *OutputBuffer) void {
    c.setutxent();
    defer c.endutxent();

    while (c.getutxent()) |entry| {
        if (entry[0].ut_type != USER_PROCESS) continue;

        const user = nullTerminated(entry[0].ut_user[0..]);
        const line = nullTerminated(entry[0].ut_line[0..]);
        const host = nullTerminated(entry[0].ut_host[0..]);

        if (user.len == 0) continue;

        // Format: "%-8s %-12s %s [ (host)]" — matches GNU who's default column layout.
        out.write(user);
        const user_pad = if (user.len < 8) 9 - user.len else 1;
        out.writeSpaces(user_pad);

        out.write(line);
        const line_pad = if (line.len < 12) 13 - line.len else 1;
        out.writeSpaces(line_pad);

        var time_buf: [16]u8 = undefined;
        const time_str = formatTime(entry[0].ut_tv.tv_sec, &time_buf);
        out.write(time_str);

        if (host.len > 0) {
            out.write(" (");
            out.write(host);
            out.writeByte(')');
        }

        out.writeByte('\n');
    }
}
