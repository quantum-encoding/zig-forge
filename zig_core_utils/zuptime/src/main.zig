//! zuptime - Show how long the system has been running
//!
//! High-performance uptime implementation in Zig.
//!
//! Output format is anchored to procps-ng `library/uptime.c`
//! (https://gitlab.com/procps-ng/procps/-/raw/master/library/uptime.c) and the
//! `-s` boot-time format to procps-ng `src/uptime.c` `print_uptime_since()`.
//! The exact procps format strings are quoted inline where they are reproduced.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

extern "c" fn time(t: ?*i64) i64;
// glibc localtime() returns NULL when the time_t is out of the representable
// range (e.g. a negative boot time derived from a malformed /proc/uptime), so
// this MUST be optional — dereferencing a NULL Tm would segfault. procps guards
// the same call: `if ((up_since = localtime(&s)) == NULL) errx(EXIT_FAILURE...)`.
extern "c" fn localtime(t: *const i64) ?*const Tm;

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

// procps time buckets (library/uptime.c #defines, verbatim).
const SECS_IN_DAY: u64 = 60 * 60 * 24;
const SECS_IN_WEEK: u64 = 60 * 60 * 24 * 7;
const SECS_IN_YEAR: u64 = 60 * 60 * 24 * 365;
const SECS_IN_DECADE: u64 = 60 * 60 * 24 * 365 * 10;

/// Write all of `data` to `fd`, looping over short writes and retrying on EINTR.
/// The previous implementation discarded libc.write's return value, so a short
/// write to a pipe with a small buffer silently truncated the output.
fn writeAll(fd: c_int, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = libc.write(fd, data.ptr + off, data.len - off);
        if (n < 0) {
            if (libc._errno().* == @as(c_int, @intFromEnum(std.posix.E.INTR))) continue;
            return; // unrecoverable write error (e.g. EPIPE): give up
        }
        if (n == 0) return; // no progress; avoid a busy loop
        off += @intCast(n);
    }
}

fn writeStdout(data: []const u8) void {
    writeAll(libc.STDOUT_FILENO, data);
}

fn writeStderr(data: []const u8) void {
    writeAll(libc.STDERR_FILENO, data);
}

// --help / --version go to STDOUT with exit 0 (GNU/POSIX + procps convention:
// getopt handles 'h'/'V' by writing to stdout and exiting 0, so `uptime --help |
// grep` works). The previous version wrote both to stderr.
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
    writeStdout(usage);
}

fn printVersion() void {
    writeStdout("zuptime " ++ VERSION ++ "\n");
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

fn parseLoadAvg() ?struct { load1: f64, load5: f64, load15: f64 } {
    const data = readFile("/proc/loadavg", &g_load_buf) orelse return null;

    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, data, " \n"), ' ');
    const s1 = parts.next() orelse return null;
    const s5 = parts.next() orelse return null;
    const s15 = parts.next() orelse return null;

    // Parse to f64 and re-emit with procps's exact `%.2f` format instead of
    // echoing the raw /proc bytes verbatim. This validates the fields are
    // numeric (garbage no longer flows straight to stdout) and guarantees the
    // "load average: X.XX, Y.YY, Z.ZZ" wire format regardless of the source's
    // native precision.
    const l1 = std.fmt.parseFloat(f64, s1) catch return null;
    const l5 = std.fmt.parseFloat(f64, s5) catch return null;
    const l15 = std.fmt.parseFloat(f64, s15) catch return null;

    return .{ .load1 = l1, .load5 = l5, .load15 = l15 };
}

/// Count logged-in users from /var/run/utmp.
///
/// Returns null when utmp is unreadable (procps prints "? users" in that case).
/// The Linux glibc `struct utmp` is 384 bytes with `short ut_type` at offset 0;
/// the record is streamed so the count is not capped by a fixed buffer, and
/// ut_type is read as the correct 2-byte width (the old code read a 4-byte i32,
/// which only worked when the two padding bytes happened to be zero).
fn countUsers() ?u32 {
    const USER_PROCESS: i16 = 7;
    const entry_size: usize = 384; // glibc struct utmp, 32- and 64-bit.

    const fd = libc.open("/var/run/utmp", .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) return null;
    defer _ = libc.close(fd);

    var rec: [entry_size]u8 = undefined;
    var users: u32 = 0;
    while (true) {
        // Read exactly one record (looping over short reads / EINTR).
        var got: usize = 0;
        while (got < entry_size) {
            const n = libc.read(fd, rec[got..].ptr, entry_size - got);
            if (n < 0) {
                if (libc._errno().* == @as(c_int, @intFromEnum(std.posix.E.INTR))) continue;
                return null;
            }
            if (n == 0) break; // EOF
            got += @intCast(n);
        }
        if (got == 0) break; // clean EOF on a record boundary
        if (got < entry_size) break; // trailing partial record: ignore

        const ut_type = std.mem.readInt(i16, rec[0..2], .little);
        if (ut_type == USER_PROCESS) users += 1;
    }

    return users;
}

/// Format the uptime component in classic (non-pretty) form, i.e. the text that
/// follows "up " in the default line. Byte-for-byte reproduction of procps-ng
/// `snprint_uptime_only(..., pretty=0)`:
///   days:   "%s%d %s"  with UNITS = (updays != 1 ? "days" : "day")
///   hours:  "%s%2d:%02d"
///   mins:   "%s%d %s"  with UNITS = "min"
/// where "%s" is ", " once at least one earlier field printed, else "".
/// Note procps uses strict `>` thresholds on the (subtracted) remainder, which
/// is why e.g. exactly 86400s renders "24:00" and 90000s renders "1 day, 60 min".
pub fn formatUptimeComponent(secs: u64, buf: []u8) []const u8 {
    var rem = secs;
    var updays: u64 = 0;
    var uphours: u64 = 0;
    var upmins: u64 = 0;
    if (rem > SECS_IN_DAY) {
        updays = rem / SECS_IN_DAY;
        rem -= updays * SECS_IN_DAY;
    }
    if (rem > 60 * 60) {
        uphours = rem / (60 * 60);
        rem -= uphours * 60 * 60;
    }
    if (rem > 60) {
        upmins = rem / 60;
        rem -= upmins * 60;
    }

    var pos: usize = 0;
    var comma: u32 = 0;

    if (updays > 0) {
        const s = std.fmt.bufPrint(buf[pos..], "{d} {s}", .{ updays, if (updays != 1) "days" else "day" }) catch return buf[0..pos];
        pos += s.len;
        comma += 1;
    }
    if (uphours > 0) {
        const sep = if (comma > 0) ", " else "";
        const s = std.fmt.bufPrint(buf[pos..], "{s}{d: >2}:{d:0>2}", .{ sep, uphours, upmins }) catch return buf[0..pos];
        pos += s.len;
    } else {
        const sep = if (comma > 0) ", " else "";
        const s = std.fmt.bufPrint(buf[pos..], "{s}{d} min", .{ sep, upmins }) catch return buf[0..pos];
        pos += s.len;
    }

    return buf[0..pos];
}

/// Pretty (`-p`) format. Byte-for-byte reproduction of procps-ng
/// `snprint_uptime_only(..., pretty=1)` prefixed with "up ":
/// decades/years/weeks/days/hours/minutes, ", "-joined, singular where the
/// count warrants it (days uses `!= 1`; the rest use `> 1`; minutes are printed
/// even when zero if the leftover seconds are <= 60).
pub fn formatPretty(secs: u64, buf: []u8) []const u8 {
    var rem = secs;
    var updec: u64 = 0;
    var upyears: u64 = 0;
    var upweeks: u64 = 0;
    var updays: u64 = 0;
    var uphours: u64 = 0;
    var upmins: u64 = 0;
    if (rem > SECS_IN_DECADE) {
        updec = rem / SECS_IN_DECADE;
        rem -= updec * SECS_IN_DECADE;
    }
    if (rem > SECS_IN_YEAR) {
        upyears = rem / SECS_IN_YEAR;
        rem -= upyears * SECS_IN_YEAR;
    }
    if (rem > SECS_IN_WEEK) {
        upweeks = rem / SECS_IN_WEEK;
        rem -= upweeks * SECS_IN_WEEK;
    }
    if (rem > SECS_IN_DAY) {
        updays = rem / SECS_IN_DAY;
        rem -= updays * SECS_IN_DAY;
    }
    if (rem > 60 * 60) {
        uphours = rem / (60 * 60);
        rem -= uphours * 60 * 60;
    }
    if (rem > 60) {
        upmins = rem / 60;
        rem -= upmins * 60;
    }

    var pos: usize = 0;
    const prefix = "up ";
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    var comma: u32 = 0;
    const emit = struct {
        fn one(b: []u8, p: *usize, c: *u32, val: u64, units: []const u8) void {
            const sep = if (c.* > 0) ", " else "";
            const s = std.fmt.bufPrint(b[p.*..], "{s}{d} {s}", .{ sep, val, units }) catch return;
            p.* += s.len;
            c.* += 1;
        }
    }.one;

    if (updec > 0) emit(buf, &pos, &comma, updec, if (updec > 1) "decades" else "decade");
    if (upyears > 0) emit(buf, &pos, &comma, upyears, if (upyears > 1) "years" else "year");
    if (upweeks > 0) emit(buf, &pos, &comma, upweeks, if (upweeks > 1) "weeks" else "week");
    if (updays > 0) emit(buf, &pos, &comma, updays, if (updays != 1) "days" else "day");
    if (uphours > 0) emit(buf, &pos, &comma, uphours, if (uphours > 1) "hours" else "hour");
    if (upmins > 0 or rem <= 60) emit(buf, &pos, &comma, upmins, if (upmins > 1) "minutes" else "minute");

    return buf[0..pos];
}

/// Format the users segment: procps `", %2d %s,  "` (two trailing spaces) with
/// UNITS = (users != 1 ? "users" : "user"), or `", ? users,  "` when `users` is
/// null (utmp unreadable). Both are verbatim from procps procps_uptime_snprint.
pub fn formatUsers(users: ?u32, buf: []u8) []const u8 {
    if (users) |n| {
        return std.fmt.bufPrint(buf, ", {d: >2} {s},  ", .{
            n,
            if (n != 1) "users" else "user",
        }) catch buf[0..0];
    }
    const q = ", ? users,  ";
    @memcpy(buf[0..q.len], q);
    return buf[0..q.len];
}

/// Format the load-average segment: procps `"load average: %.2f, %.2f, %.2f"`.
/// The trailing newline is appended here since the util emits a single line.
pub fn formatLoad(l1: f64, l5: f64, l15: f64, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "load average: {d:.2}, {d:.2}, {d:.2}\n", .{ l1, l5, l15 }) catch buf[0..0];
}

fn fail(msg: []const u8) noreturn {
    writeStderr(msg);
    std.process.exit(1);
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
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--pretty")) {
            pretty = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--since")) {
            since = true;
        } else {
            // Unknown option: GNU/procps prints an error and exits non-zero,
            // rather than silently ignoring it.
            writeStderr("zuptime: unrecognized option '");
            writeStderr(arg);
            writeStderr("'\nTry 'zuptime --help' for more information.\n");
            std.process.exit(1);
        }
    }

    const uptime_info = parseUptime() orelse fail("zuptime: cannot read /proc/uptime\n");

    if (since) {
        // Show boot time: "%04d-%02d-%02d %02d:%02d:%02d\n" (procps src/uptime.c).
        const now = time(null);
        const boot_time = now - @as(i64, @intCast(uptime_info.uptime_secs));
        const tm = localtime(&boot_time) orelse fail("zuptime: localtime failed\n");

        // Fields are formatted as signed ints (procps uses %04d/%02d). This also
        // avoids the previous negative-to-u32 @intCast panic on an out-of-range
        // boot time derived from a malformed /proc/uptime.
        var buf: [64]u8 = undefined;
        const time_str = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}\n", .{
            @as(i32, tm.tm_year) + 1900,
            @as(i32, tm.tm_mon) + 1,
            @as(i32, tm.tm_mday),
            @as(i32, tm.tm_hour),
            @as(i32, tm.tm_min),
            @as(i32, tm.tm_sec),
        }) catch fail("zuptime: format error\n");
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

    // Standard format (procps procps_uptime_snprint, pretty=0):
    //   " %02d:%02d:%02d up " + <component> + ", %2d %s,  " + "load average: ..." + "\n"
    const now = time(null);
    const tm = localtime(&now) orelse fail("zuptime: localtime failed\n");

    var output_buf: [256]u8 = undefined;
    var pos: usize = 0;

    // Current time + " up "
    const time_part = std.fmt.bufPrint(output_buf[pos..], " {d:0>2}:{d:0>2}:{d:0>2} up ", .{
        @as(i32, tm.tm_hour),
        @as(i32, tm.tm_min),
        @as(i32, tm.tm_sec),
    }) catch fail("zuptime: format error\n");
    pos += time_part.len;

    // Uptime duration
    var dur_buf: [64]u8 = undefined;
    const duration = formatUptimeComponent(uptime_info.uptime_secs, &dur_buf);
    @memcpy(output_buf[pos..][0..duration.len], duration);
    pos += duration.len;

    // Users: ", %2d %s,  " (two trailing spaces), or ", ? users,  " when utmp
    // is unreadable — matching procps exactly.
    const users_part = formatUsers(countUsers(), output_buf[pos..]);
    pos += users_part.len;

    // Load averages: "load average: %.2f, %.2f, %.2f\n"
    const load = parseLoadAvg() orelse fail("zuptime: cannot read /proc/loadavg\n");
    const load_part = formatLoad(load.load1, load.load5, load.load15, output_buf[pos..]);
    pos += load_part.len;

    writeStdout(output_buf[0..pos]);
}
