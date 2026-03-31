//! zdate - High-performance date/time display utility
//!
//! Display or set the system date and time.
//!
//! Usage: zdate [OPTION]... [+FORMAT]

const std = @import("std");
const posix = std.posix;

const VERSION = "1.0.0";

// C time functions
extern "c" fn time(t: ?*i64) i64;
extern "c" fn localtime(t: *const i64) ?*Tm;
extern "c" fn gmtime(t: *const i64) ?*Tm;
extern "c" fn strftime(s: [*]u8, max: usize, format: [*:0]const u8, tm: *const Tm) usize;
extern "c" fn mktime(tm: *Tm) i64;

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
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

const Config = struct {
    utc: bool = false,
    format: ?[]const u8 = null,
    date_string: ?[]const u8 = null,
    rfc_2822: bool = false,
    rfc_3339: ?[]const u8 = null, // "date", "seconds", "ns"
    iso_8601: ?[]const u8 = null, // "date", "hours", "minutes", "seconds", "ns"
    reference: ?[]const u8 = null,
};

fn writeStdout(msg: []const u8) void {
    _ = std.c.write(std.c.STDOUT_FILENO, msg.ptr, msg.len);
}

fn writeStderr(msg: []const u8) void {
    _ = std.c.write(std.c.STDERR_FILENO, msg.ptr, msg.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zdate [OPTION]... [+FORMAT]
        \\   or: zdate [-u|--utc] [MMDDhhmm[[CC]YY][.ss]]
        \\
        \\Display the current time in the given FORMAT, or set the system date.
        \\
        \\Options:
        \\  -d, --date=STRING     Display time described by STRING
        \\  -r, --reference=FILE  Display last modification time of FILE
        \\  -R, --rfc-2822        Output in RFC 2822 format
        \\      --rfc-3339=FMT    Output in RFC 3339 format (date, seconds, ns)
        \\  -I, --iso-8601[=FMT]  Output in ISO 8601 format (date, hours, minutes, seconds, ns)
        \\  -u, --utc, --universal  Print or set UTC time
        \\      --help            Display this help
        \\      --version         Output version information
        \\
        \\FORMAT controls the output (strftime-compatible):
        \\  %%   a literal %
        \\  %a   abbreviated weekday (Sun..Sat)
        \\  %A   full weekday (Sunday..Saturday)
        \\  %b   abbreviated month (Jan..Dec)
        \\  %B   full month (January..December)
        \\  %c   locale date and time
        \\  %C   century (00..99)
        \\  %d   day of month (01..31)
        \\  %D   date; same as %m/%d/%y
        \\  %e   day of month, space padded
        \\  %F   full date; same as %Y-%m-%d
        \\  %H   hour (00..23)
        \\  %I   hour (01..12)
        \\  %j   day of year (001..366)
        \\  %m   month (01..12)
        \\  %M   minute (00..59)
        \\  %n   newline
        \\  %p   AM or PM
        \\  %r   12-hour time (hh:mm:ss AM/PM)
        \\  %R   24-hour time (hh:mm)
        \\  %s   seconds since 1970-01-01 00:00:00 UTC
        \\  %S   second (00..60)
        \\  %t   tab
        \\  %T   time; same as %H:%M:%S
        \\  %u   day of week (1..7); 1 is Monday
        \\  %U   week number (00..53); Sunday starts week
        \\  %V   ISO week number (01..53)
        \\  %w   day of week (0..6); 0 is Sunday
        \\  %W   week number (00..53); Monday starts week
        \\  %x   locale date
        \\  %X   locale time
        \\  %y   last two digits of year (00..99)
        \\  %Y   year
        \\  %z   +hhmm numeric time zone
        \\  %Z   time zone abbreviation
        \\
        \\Examples:
        \\  zdate                       # Current date and time
        \\  zdate +%Y-%m-%d             # 2024-01-15
        \\  zdate +"%H:%M:%S"           # 14:30:45
        \\  zdate -u                    # UTC time
        \\  zdate -R                    # RFC 2822 format
        \\  zdate -I                    # ISO 8601 date
        \\  zdate -Iseconds             # ISO 8601 with seconds
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zdate " ++ VERSION ++ " - High-performance date utility\n");
}

fn parseArgs(args: []const []const u8) !Config {
    var config = Config{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '+') {
            // Format string
            config.format = arg[1..];
        } else if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--utc") or std.mem.eql(u8, arg, "--universal")) {
                config.utc = true;
            } else if (std.mem.eql(u8, arg, "-R") or std.mem.eql(u8, arg, "--rfc-2822")) {
                config.rfc_2822 = true;
            } else if (std.mem.eql(u8, arg, "-I") or std.mem.eql(u8, arg, "--iso-8601")) {
                config.iso_8601 = "date";
            } else if (std.mem.startsWith(u8, arg, "-I")) {
                config.iso_8601 = arg[2..];
            } else if (std.mem.startsWith(u8, arg, "--iso-8601=")) {
                config.iso_8601 = arg[11..];
            } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--date")) {
                i += 1;
                if (i >= args.len) {
                    writeStderr("zdate: option '-d' requires an argument\n");
                    return error.MissingArgument;
                }
                config.date_string = args[i];
            } else if (std.mem.startsWith(u8, arg, "-d")) {
                config.date_string = arg[2..];
            } else if (std.mem.startsWith(u8, arg, "--date=")) {
                config.date_string = arg[7..];
            } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--reference")) {
                i += 1;
                if (i >= args.len) {
                    writeStderr("zdate: option '-r' requires an argument\n");
                    return error.MissingArgument;
                }
                config.reference = args[i];
            } else if (std.mem.startsWith(u8, arg, "--reference=")) {
                config.reference = arg[12..];
            } else if (std.mem.startsWith(u8, arg, "--rfc-3339=")) {
                config.rfc_3339 = arg[11..];
            } else if (std.mem.eql(u8, arg, "--help")) {
                printUsage();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                std.process.exit(0);
            } else {
                var err_buf: [256]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "zdate: unrecognized option '{s}'\n", .{arg}) catch "zdate: unrecognized option\n";
                writeStderr(err_msg);
                return error.InvalidOption;
            }
        }
    }

    return config;
}

fn formatDate(timestamp: i64, format: []const u8, utc: bool) void {
    const tm_ptr = if (utc) gmtime(&timestamp) else localtime(&timestamp);
    if (tm_ptr == null) {
        writeStderr("zdate: cannot convert time\n");
        return;
    }

    var format_buf: [256]u8 = undefined;
    const format_z = std.fmt.bufPrintZ(&format_buf, "{s}", .{format}) catch {
        writeStderr("zdate: format string too long\n");
        return;
    };

    var output_buf: [1024]u8 = undefined;
    const len = strftime(&output_buf, output_buf.len, format_z.ptr, tm_ptr.?);

    if (len > 0) {
        writeStdout(output_buf[0..len]);
        writeStdout("\n");
    }
}

fn getDefaultFormat() []const u8 {
    return "%a %b %e %H:%M:%S %Z %Y";
}

fn getRfc2822Format() []const u8 {
    return "%a, %d %b %Y %H:%M:%S %z";
}

fn getIso8601Format(precision: []const u8) []const u8 {
    if (std.mem.eql(u8, precision, "date")) {
        return "%Y-%m-%d";
    } else if (std.mem.eql(u8, precision, "hours")) {
        return "%Y-%m-%dT%H%z";
    } else if (std.mem.eql(u8, precision, "minutes")) {
        return "%Y-%m-%dT%H:%M%z";
    } else if (std.mem.eql(u8, precision, "seconds") or std.mem.eql(u8, precision, "ns")) {
        return "%Y-%m-%dT%H:%M:%S%z";
    } else {
        return "%Y-%m-%d";
    }
}

fn getRfc3339Format(precision: []const u8) []const u8 {
    if (std.mem.eql(u8, precision, "date")) {
        return "%Y-%m-%d";
    } else if (std.mem.eql(u8, precision, "seconds") or std.mem.eql(u8, precision, "ns")) {
        return "%Y-%m-%d %H:%M:%S%z";
    } else {
        return "%Y-%m-%d";
    }
}

fn getFileModTime(path: []const u8) !i64 {
    const Io = std.Io;
    const io = Io.Threaded.global_single_threaded.io();
    const cwd = Io.Dir.cwd();

    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.PathTooLong;

    const stat = cwd.statFile(io, path_z, .{}) catch return error.StatFailed;
    // mtime is an Io.Timestamp with nanoseconds field
    const ns: i128 = stat.mtime.nanoseconds;
    return @intCast(@divFloor(ns, std.time.ns_per_s));
}

fn parseDateString(date_str: []const u8, utc: bool) ?i64 {
    // @EPOCH - epoch seconds
    if (date_str.len > 0 and date_str[0] == '@') {
        return parseI64(date_str[1..]);
    }

    // Get current time as base for relative calculations
    var now_ts = time(null);
    const tm_ptr = if (utc) gmtime(&now_ts) else localtime(&now_ts);
    if (tm_ptr == null) return null;
    var tm = tm_ptr.?.*;

    const s = date_str;

    // "yesterday"
    if (eqlIgnoreCase(s, "yesterday")) {
        tm.tm_mday -= 1;
        tm.tm_hour = 0;
        tm.tm_min = 0;
        tm.tm_sec = 0;
        return mktime(&tm);
    }
    // "tomorrow"
    if (eqlIgnoreCase(s, "tomorrow")) {
        tm.tm_mday += 1;
        tm.tm_hour = 0;
        tm.tm_min = 0;
        tm.tm_sec = 0;
        return mktime(&tm);
    }
    // "now"
    if (eqlIgnoreCase(s, "now")) {
        return now_ts;
    }
    // "today"
    if (eqlIgnoreCase(s, "today")) {
        tm.tm_hour = 0;
        tm.tm_min = 0;
        tm.tm_sec = 0;
        return mktime(&tm);
    }

    // "N days ago", "N hours ago", etc.
    if (parseRelativeDate(s, &tm)) {
        return mktime(&tm);
    }

    // "next Monday", "last Friday", etc.
    if (parseWeekday(s, &tm)) {
        return mktime(&tm);
    }

    return null;
}

fn parseI64(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    var negative = false;
    var start: usize = 0;
    if (s[0] == '-') {
        negative = true;
        start = 1;
    } else if (s[0] == '+') {
        start = 1;
    }
    var val: i64 = 0;
    for (s[start..]) |c| {
        if (c < '0' or c > '9') return null;
        val = val * 10 + @as(i64, c - '0');
    }
    return if (negative) -val else val;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la: u8 = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb: u8 = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return eqlIgnoreCase(haystack[0..needle.len], needle);
}

fn parseRelativeDate(s: []const u8, tm: *Tm) bool {
    // Parse patterns like: "N days ago", "N hours ago", "+N days", "-N days"
    var idx: usize = 0;
    var negative = false;

    // Skip leading whitespace
    while (idx < s.len and s[idx] == ' ') : (idx += 1) {}

    // Check for leading sign
    if (idx < s.len and s[idx] == '-') {
        negative = true;
        idx += 1;
    } else if (idx < s.len and s[idx] == '+') {
        idx += 1;
    }

    // Parse number
    var num: c_int = 0;
    var has_num = false;
    while (idx < s.len and s[idx] >= '0' and s[idx] <= '9') {
        num = num * 10 + @as(c_int, @intCast(s[idx] - '0'));
        has_num = true;
        idx += 1;
    }
    if (!has_num) return false;

    // Skip whitespace
    while (idx < s.len and s[idx] == ' ') : (idx += 1) {}

    // Parse unit
    const rest = s[idx..];
    const signed_num: c_int = if (negative) -num else num;

    if (startsWithIgnoreCase(rest, "day")) {
        // Check for "ago"
        const has_ago = hasSuffix(rest, "ago");
        const n = if (has_ago) -signed_num else signed_num;
        tm.tm_mday += n;
        return true;
    } else if (startsWithIgnoreCase(rest, "hour")) {
        const has_ago = hasSuffix(rest, "ago");
        const n = if (has_ago) -signed_num else signed_num;
        tm.tm_hour += n;
        return true;
    } else if (startsWithIgnoreCase(rest, "minute") or startsWithIgnoreCase(rest, "min")) {
        const has_ago = hasSuffix(rest, "ago");
        const n = if (has_ago) -signed_num else signed_num;
        tm.tm_min += n;
        return true;
    } else if (startsWithIgnoreCase(rest, "second") or startsWithIgnoreCase(rest, "sec")) {
        const has_ago = hasSuffix(rest, "ago");
        const n = if (has_ago) -signed_num else signed_num;
        tm.tm_sec += n;
        return true;
    } else if (startsWithIgnoreCase(rest, "week")) {
        const has_ago = hasSuffix(rest, "ago");
        const n = if (has_ago) -signed_num else signed_num;
        tm.tm_mday += n * 7;
        return true;
    } else if (startsWithIgnoreCase(rest, "month")) {
        const has_ago = hasSuffix(rest, "ago");
        const n = if (has_ago) -signed_num else signed_num;
        tm.tm_mon += n;
        return true;
    } else if (startsWithIgnoreCase(rest, "year")) {
        const has_ago = hasSuffix(rest, "ago");
        const n = if (has_ago) -signed_num else signed_num;
        tm.tm_year += n;
        return true;
    }

    return false;
}

fn hasSuffix(s: []const u8, suffix: []const u8) bool {
    // Check if trimmed string ends with suffix
    var end = s.len;
    while (end > 0 and s[end - 1] == ' ') : (end -= 1) {}
    if (end < suffix.len) return false;
    return eqlIgnoreCase(s[end - suffix.len .. end], suffix);
}

fn parseWeekday(s: []const u8, tm: *Tm) bool {
    // "next Monday", "last Tuesday", etc.
    var direction: c_int = 0;
    var rest = s;
    if (startsWithIgnoreCase(s, "next ")) {
        direction = 1;
        rest = s[5..];
    } else if (startsWithIgnoreCase(s, "last ")) {
        direction = -1;
        rest = s[5..];
    } else {
        return false;
    }

    // Skip whitespace
    while (rest.len > 0 and rest[0] == ' ') rest = rest[1..];

    const target_wday = getWeekday(rest) orelse return false;

    // Calculate days to add/subtract
    const current_wday = tm.tm_wday;
    var diff: c_int = undefined;
    if (direction > 0) {
        diff = target_wday - current_wday;
        if (diff <= 0) diff += 7;
    } else {
        diff = target_wday - current_wday;
        if (diff >= 0) diff -= 7;
    }

    tm.tm_mday += diff;
    tm.tm_hour = 0;
    tm.tm_min = 0;
    tm.tm_sec = 0;
    return true;
}

fn getWeekday(s: []const u8) ?c_int {
    const days = [_][]const u8{ "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday" };
    const short_days = [_][]const u8{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" };
    for (days, 0..) |d, idx| {
        if (eqlIgnoreCase(s, d)) return @intCast(idx);
    }
    for (short_days, 0..) |d, idx| {
        if (eqlIgnoreCase(s, d)) return @intCast(idx);
    }
    return null;
}

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

    const config = parseArgs(args[1..]) catch {
        std.process.exit(1);
    };

    // Get timestamp
    var timestamp: i64 = undefined;

    if (config.reference) |ref_path| {
        timestamp = getFileModTime(ref_path) catch {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "zdate: cannot stat '{s}'\n", .{ref_path}) catch "zdate: cannot stat file\n";
            writeStderr(err_msg);
            std.process.exit(1);
        };
    } else if (config.date_string) |date_str| {
        if (parseDateString(date_str, config.utc)) |ts| {
            timestamp = ts;
        } else {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "zdate: invalid date '{s}'\n", .{date_str}) catch "zdate: invalid date\n";
            writeStderr(err_msg);
            std.process.exit(1);
        }
    } else {
        timestamp = time(null);
    }

    // Determine format
    const format: []const u8 = if (config.format) |f|
        f
    else if (config.rfc_2822)
        getRfc2822Format()
    else if (config.rfc_3339) |precision|
        getRfc3339Format(precision)
    else if (config.iso_8601) |precision|
        getIso8601Format(precision)
    else
        getDefaultFormat();

    formatDate(timestamp, format, config.utc);
}
