//! ztouch - Update file timestamps or create empty files
//!
//! Compatible with GNU touch:
//! - Create empty files if they don't exist
//! - Update access and modification times
//! - -a: change only access time
//! - -m: change only modification time
//! - -c, --no-create: don't create files
//! - -r, --reference=FILE: use reference file's times

const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;
const Io = std.Io;

// Cross-platform Stat structure
const Stat = switch (builtin.os.tag) {
    .linux => extern struct {
        dev: u64, ino: u64, nlink: u64, mode: u32, uid: u32, gid: u32,
        __pad0: u32 = 0, rdev: u64, size: i64, blksize: i64, blocks: i64,
        atim: libc.timespec, mtim: libc.timespec, ctim: libc.timespec,
        __unused: [3]i64 = .{ 0, 0, 0 },
        pub fn atime(self: @This()) libc.timespec { return self.atim; }
        pub fn mtime(self: @This()) libc.timespec { return self.mtim; }
    },
    .macos, .ios, .tvos, .watchos => extern struct {
        dev: i32, mode: u16, nlink: u16, ino: u64, uid: u32, gid: u32, rdev: i32,
        atim: libc.timespec, mtim: libc.timespec, ctim: libc.timespec, birthtim: libc.timespec,
        size: i64, blocks: i64, blksize: i32, flags: u32, gen: u32, lspare: i32, qspare: [2]i64,
        pub fn atime(self: @This()) libc.timespec { return self.atim; }
        pub fn mtime(self: @This()) libc.timespec { return self.mtim; }
    },
    else => libc.Stat,
};

extern "c" fn stat(path: [*:0]const u8, buf: *Stat) c_int;
extern "c" fn time(timer: ?*i64) i64;

const CTimeT = i64;
const CTm = extern struct {
    tm_sec: c_int = 0,
    tm_min: c_int = 0,
    tm_hour: c_int = 0,
    tm_mday: c_int = 0,
    tm_mon: c_int = 0,
    tm_year: c_int = 0,
    tm_wday: c_int = 0,
    tm_yday: c_int = 0,
    tm_isdst: c_int = -1,
    tm_gmtoff: c_long = 0,
    tm_zone: ?[*:0]const u8 = null,
};

extern "c" fn mktime(tm: *CTm) CTimeT;

const Config = struct {
    access_only: bool = false,
    modify_only: bool = false,
    no_create: bool = false,
    no_dereference: bool = false,
    reference_file: ?[]const u8 = null,
    timestamp: ?Timespec = null,
    files: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.files.items) |item| {
            allocator.free(item);
        }
        self.files.deinit(allocator);
        if (self.reference_file) |ref| {
            allocator.free(ref);
        }
    }
};

const Timespec = extern struct {
    sec: i64,
    nsec: i64,
};

// utimensat flags
const AT_FDCWD: c_int = -100;
const AT_SYMLINK_NOFOLLOW: c_int = 0x100;
const UTIME_NOW: i64 = (1 << 30) - 1;
const UTIME_OMIT: i64 = (1 << 30) - 2;

extern "c" fn utimensat(dirfd: c_int, pathname: [*:0]const u8, times: ?*const [2]Timespec, flags: c_int) c_int;

fn touchFile(allocator: std.mem.Allocator, path: []const u8, config: *const Config) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    // Check if file exists
    const file_exists = fileExists(path_z);

    if (!file_exists) {
        if (config.no_create) {
            return; // Don't create, just skip
        }
        // Create empty file
        try createEmptyFile(path_z);
    }

    // Update timestamps
    var times: [2]Timespec = undefined;

    if (config.reference_file) |ref| {
        const ref_z = try allocator.dupeZ(u8, ref);
        defer allocator.free(ref_z);

        const ref_times = try getFileTimes(ref_z);
        times[0] = ref_times[0]; // access time
        times[1] = ref_times[1]; // modification time
    } else if (config.timestamp) |ts| {
        // Use specified timestamp
        times[0] = ts;
        times[1] = ts;
    } else {
        // Use current time
        times[0] = .{ .sec = 0, .nsec = UTIME_NOW };
        times[1] = .{ .sec = 0, .nsec = UTIME_NOW };
    }

    // Apply filters
    if (config.access_only and !config.modify_only) {
        times[1].nsec = UTIME_OMIT; // Don't change mtime
    } else if (config.modify_only and !config.access_only) {
        times[0].nsec = UTIME_OMIT; // Don't change atime
    }

    const flags: c_int = if (config.no_dereference) AT_SYMLINK_NOFOLLOW else 0;
    const result = utimensat(AT_FDCWD, path_z.ptr, &times, flags);
    if (result != 0) {
        const err = libc._errno().*;
        printErrorFmt("cannot touch '{s}': {s}", .{ path, errnoToString(err) });
        return error.TouchFailed;
    }
}

fn fileExists(path: [:0]const u8) bool {
    return libc.access(path.ptr, 0) == 0;
}

fn createEmptyFile(path: [:0]const u8) !void {
    const io = Io.Threaded.global_single_threaded.io();
    const Dir = Io.Dir;

    const file = Dir.createFile(Dir.cwd(), io, path, .{}) catch |err| {
        printErrorFmt("cannot create '{s}': {s}", .{ path, @errorName(err) });
        return err;
    };
    file.close(io);
}

fn getFileTimes(path: [:0]const u8) ![2]Timespec {
    var stat_buf: Stat = undefined;
    const result = stat(path.ptr, &stat_buf);
    if (result != 0) {
        return error.StatFailed;
    }

    // On macOS and Linux, libc.Stat has atimespec/mtimespec or atime/mtime
    return .{
        .{ .sec = @intCast(stat_buf.atime().sec), .nsec = stat_buf.atime().nsec },
        .{ .sec = @intCast(stat_buf.mtime().sec), .nsec = stat_buf.mtime().nsec },
    };
}

fn errnoToString(err: c_int) []const u8 {
    return switch (err) {
        1 => "Operation not permitted",
        2 => "No such file or directory",
        13 => "Permission denied",
        17 => "File exists",
        20 => "Not a directory",
        21 => "Is a directory",
        28 => "No space left on device",
        30 => "Read-only file system",
        else => "Unknown error",
    };
}

// Parse date string: supports @epoch, YYYY-MM-DD, YYYY-MM-DD HH:MM:SS
fn parseDateString(date: []const u8) ?Timespec {
    // Handle @epoch format
    if (date.len > 0 and date[0] == '@') {
        const epoch = std.fmt.parseInt(i64, date[1..], 10) catch return null;
        return Timespec{ .sec = epoch, .nsec = 0 };
    }

    // Try YYYY-MM-DD or YYYY-MM-DD HH:MM:SS
    if (date.len < 10) return null;

    // Parse date part: YYYY-MM-DD
    if (date[4] != '-' or date[7] != '-') return null;
    const year = std.fmt.parseInt(c_int, date[0..4], 10) catch return null;
    const month = std.fmt.parseInt(c_int, date[5..7], 10) catch return null;
    const day = std.fmt.parseInt(c_int, date[8..10], 10) catch return null;

    if (month < 1 or month > 12) return null;
    if (day < 1 or day > 31) return null;

    var hour: c_int = 0;
    var minute: c_int = 0;
    var second: c_int = 0;

    // Parse optional time part
    if (date.len > 10) {
        if (date.len < 19) return null;
        if (date[10] != ' ' and date[10] != 'T') return null;
        if (date[13] != ':' or date[16] != ':') return null;
        hour = std.fmt.parseInt(c_int, date[11..13], 10) catch return null;
        minute = std.fmt.parseInt(c_int, date[14..16], 10) catch return null;
        second = std.fmt.parseInt(c_int, date[17..19], 10) catch return null;
        if (hour > 23 or minute > 59 or second > 59) return null;
    }

    // Use mktime to convert to epoch
    var tm = CTm{
        .tm_sec = second,
        .tm_min = minute,
        .tm_hour = hour,
        .tm_mday = day,
        .tm_mon = month - 1,
        .tm_year = year - 1900,
        .tm_isdst = -1,
    };

    const result = mktime(&tm);
    if (result == -1) return null;

    return Timespec{ .sec = result, .nsec = 0 };
}

// Parse timestamp in format [[CC]YY]MMDDhhmm[.ss]
fn parseTimestamp(ts: []const u8) ?Timespec {
    // Split on '.' to get seconds
    var seconds: u8 = 0;
    var main_part = ts;
    if (std.mem.indexOfScalar(u8, ts, '.')) |dot_pos| {
        if (dot_pos + 1 < ts.len) {
            seconds = std.fmt.parseInt(u8, ts[dot_pos + 1 ..], 10) catch return null;
            if (seconds > 59) return null;
        }
        main_part = ts[0..dot_pos];
    }

    // Parse based on length:
    // 8 chars: MMDDhhmm (use current year)
    // 10 chars: YYMMDDhhmm
    // 12 chars: CCYYMMDDhhmm
    var year: u16 = undefined;
    var month: u8 = undefined;
    var day: u8 = undefined;
    var hour: u8 = undefined;
    var minute: u8 = undefined;

    switch (main_part.len) {
        8 => { // MMDDhhmm
            // Get current year from time
            const now = time(null);
            year = @intCast(1970 + @divTrunc(now, 365 * 24 * 60 * 60));
            month = std.fmt.parseInt(u8, main_part[0..2], 10) catch return null;
            day = std.fmt.parseInt(u8, main_part[2..4], 10) catch return null;
            hour = std.fmt.parseInt(u8, main_part[4..6], 10) catch return null;
            minute = std.fmt.parseInt(u8, main_part[6..8], 10) catch return null;
        },
        10 => { // YYMMDDhhmm
            const yy = std.fmt.parseInt(u8, main_part[0..2], 10) catch return null;
            year = if (yy >= 69) 1900 + @as(u16, yy) else 2000 + @as(u16, yy);
            month = std.fmt.parseInt(u8, main_part[2..4], 10) catch return null;
            day = std.fmt.parseInt(u8, main_part[4..6], 10) catch return null;
            hour = std.fmt.parseInt(u8, main_part[6..8], 10) catch return null;
            minute = std.fmt.parseInt(u8, main_part[8..10], 10) catch return null;
        },
        12 => { // CCYYMMDDhhmm
            year = std.fmt.parseInt(u16, main_part[0..4], 10) catch return null;
            month = std.fmt.parseInt(u8, main_part[4..6], 10) catch return null;
            day = std.fmt.parseInt(u8, main_part[6..8], 10) catch return null;
            hour = std.fmt.parseInt(u8, main_part[8..10], 10) catch return null;
            minute = std.fmt.parseInt(u8, main_part[10..12], 10) catch return null;
        },
        else => return null,
    }

    // Validate ranges
    if (month < 1 or month > 12) return null;
    if (day < 1 or day > 31) return null;
    if (hour > 23) return null;
    if (minute > 59) return null;

    // Convert to Unix timestamp
    const epoch_seconds = dateToTimestamp(year, month, day, hour, minute, seconds);
    return Timespec{ .sec = epoch_seconds, .nsec = 0 };
}

fn dateToTimestamp(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) i64 {
    // Days from 1970 to start of year
    var days: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) {
        days += if (isLeapYear(y)) 366 else 365;
    }

    // Days from start of year to start of month
    const month_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: usize = 0;
    while (m < month - 1) : (m += 1) {
        days += month_days[m];
        if (m == 1 and isLeapYear(year)) days += 1; // February in leap year
    }

    days += day - 1;

    return days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
}

fn isLeapYear(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

fn parseArgs(allocator: std.mem.Allocator, minimal_args: anytype) !Config {
    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(minimal_args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var config = Config{};
    var i: usize = 1;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            if (arg[1] == '-') {
                if (std.mem.eql(u8, arg, "--help")) {
                    printHelp();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--version")) {
                    printVersion();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--no-create")) {
                    config.no_create = true;
                } else if (std.mem.eql(u8, arg, "--no-dereference")) {
                    config.no_dereference = true;
                } else if (std.mem.startsWith(u8, arg, "--date=")) {
                    const date_str = arg[7..];
                    const ts = parseDateString(date_str);
                    if (ts == null) {
                        printErrorFmt("invalid date '{s}'", .{date_str});
                        std.process.exit(1);
                    }
                    config.timestamp = ts;
                } else if (std.mem.eql(u8, arg, "--date")) {
                    i += 1;
                    if (i >= args.len) {
                        printError("option '--date' requires an argument");
                        std.process.exit(1);
                    }
                    const date_str = args[i];
                    const ts = parseDateString(date_str);
                    if (ts == null) {
                        printErrorFmt("invalid date '{s}'", .{date_str});
                        std.process.exit(1);
                    }
                    config.timestamp = ts;
                } else if (std.mem.startsWith(u8, arg, "--reference=")) {
                    config.reference_file = try allocator.dupe(u8, arg[12..]);
                } else if (std.mem.eql(u8, arg, "--reference")) {
                    i += 1;
                    if (i >= args.len) {
                        printError("option '--reference' requires an argument");
                        std.process.exit(1);
                    }
                    config.reference_file = try allocator.dupe(u8, args[i]);
                } else if (std.mem.startsWith(u8, arg, "--time=")) {
                    const time_val = arg[7..];
                    if (std.mem.eql(u8, time_val, "access") or std.mem.eql(u8, time_val, "atime") or std.mem.eql(u8, time_val, "use")) {
                        config.access_only = true;
                    } else if (std.mem.eql(u8, time_val, "modify") or std.mem.eql(u8, time_val, "mtime")) {
                        config.modify_only = true;
                    } else {
                        printErrorFmt("invalid argument '{s}' for '--time'", .{time_val});
                        std.process.exit(1);
                    }
                } else if (std.mem.eql(u8, arg, "--")) {
                    i += 1;
                    while (i < args.len) : (i += 1) {
                        try config.files.append(allocator, try allocator.dupe(u8, args[i]));
                    }
                    break;
                } else {
                    printErrorFmt("unrecognized option '{s}'", .{arg});
                    std.process.exit(1);
                }
            } else {
                // Short options
                var j: usize = 1;
                while (j < arg.len) : (j += 1) {
                    const ch = arg[j];
                    switch (ch) {
                        'a' => config.access_only = true,
                        'm' => config.modify_only = true,
                        'c' => config.no_create = true,
                        'f' => {}, // ignored for compatibility
                        'h' => config.no_dereference = true,
                        'd' => {
                            // -d requires argument: date string
                            var date_arg: []const u8 = undefined;
                            if (j + 1 < arg.len) {
                                date_arg = arg[j + 1 ..];
                            } else {
                                i += 1;
                                if (i >= args.len) {
                                    printError("option requires an argument -- 'd'");
                                    std.process.exit(1);
                                }
                                date_arg = args[i];
                            }
                            const ts = parseDateString(date_arg);
                            if (ts == null) {
                                printErrorFmt("invalid date '{s}'", .{date_arg});
                                std.process.exit(1);
                            }
                            config.timestamp = ts;
                            break;
                        },
                        'r' => {
                            // -r requires argument
                            if (j + 1 < arg.len) {
                                config.reference_file = try allocator.dupe(u8, arg[j + 1 ..]);
                                break;
                            } else {
                                i += 1;
                                if (i >= args.len) {
                                    printError("option requires an argument -- 'r'");
                                    std.process.exit(1);
                                }
                                config.reference_file = try allocator.dupe(u8, args[i]);
                            }
                        },
                        't' => {
                            // -t requires argument: [[CC]YY]MMDDhhmm[.ss]
                            var ts_arg: []const u8 = undefined;
                            if (j + 1 < arg.len) {
                                ts_arg = arg[j + 1 ..];
                            } else {
                                i += 1;
                                if (i >= args.len) {
                                    printError("option requires an argument -- 't'");
                                    std.process.exit(1);
                                }
                                ts_arg = args[i];
                            }
                            const ts = parseTimestamp(ts_arg);
                            if (ts == null) {
                                printError("invalid timestamp format");
                                std.process.exit(1);
                            }
                            config.timestamp = ts;
                            break;
                        },
                        else => {
                            printErrorFmt("invalid option -- '{c}'", .{ch});
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else {
            try config.files.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    if (config.files.items.len == 0) {
        printError("missing file operand");
        std.debug.print("Try 'ztouch --help' for more information.\n", .{});
        std.process.exit(1);
    }

    return config;
}

fn printError(msg: []const u8) void {
    std.debug.print("ztouch: {s}\n", .{msg});
}

fn printErrorFmt(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("ztouch: " ++ fmt ++ "\n", args);
}

fn printHelp() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [2048]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll(
        \\Usage: ztouch [OPTION]... FILE...
        \\Update the access and modification times of each FILE to the current time.
        \\
        \\A FILE argument that does not exist is created empty, unless -c is supplied.
        \\
        \\  -a                     change only the access time
        \\  -c, --no-create        do not create any files
        \\  -d, --date=STRING      parse STRING and use it instead of current time
        \\  -f                     (ignored)
        \\  -h, --no-dereference   affect each symbolic link instead of any referenced file
        \\  -m                     change only the modification time
        \\  -r, --reference=FILE   use this file's times instead of current time
        \\  -t STAMP               use [[CC]YY]MMDDhhmm[.ss] instead of current time
        \\      --time=WORD        change the specified time: access/atime/use, modify/mtime
        \\      --help             display this help and exit
        \\      --version          output version information and exit
        \\
        \\ztouch - High-performance file touch utility in Zig
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [64]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll("ztouch 0.1.0\n") catch {};
    writer.interface.flush() catch {};
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var config = parseArgs(allocator, init.minimal.args) catch {
        printError("failed to parse arguments");
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    var error_occurred = false;

    for (config.files.items) |file| {
        touchFile(allocator, file, &config) catch {
            error_occurred = true;
        };
    }

    if (error_occurred) {
        std.process.exit(1);
    }
}
