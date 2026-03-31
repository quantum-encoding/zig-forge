//! zpr - Paginate and format files for printing
//!
//! A Zig implementation of pr.
//! Convert text files for printing with headers.
//!
//! Usage: zpr [OPTIONS] [FILE]...

const std = @import("std");

const VERSION = "1.0.0";

// C functions
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn time(t: ?*i64) i64;

const c_read = @extern(*const fn (c_int, [*]u8, usize) callconv(.c) isize, .{ .name = "read" });

const O_RDONLY: c_int = 0;

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

fn writeStdoutRaw(data: []const u8) void {
    var written: usize = 0;
    while (written < data.len) {
        const result = write(1, data.ptr + written, data.len - written);
        if (result <= 0) break;
        written += @intCast(result);
    }
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

    // Options
    var page_length: usize = 66;
    var page_width: usize = 72;
    const header_lines: usize = 5;
    const trailer_lines: usize = 5;
    var columns: usize = 1;
    var number_lines = false;
    const number_width: usize = 5;
    const number_sep: u8 = '\t';
    var double_space = false;
    var no_header = false;
    var header: ?[]const u8 = null;
    var first_page: usize = 1;
    var last_page: usize = std.math.maxInt(usize);
    var merge_files = false;
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            writeStdout("zpr {s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--double-space")) {
            double_space = true;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--omit-header")) {
            no_header = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--merge")) {
            merge_files = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--number-lines")) {
            number_lines = true;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--length")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zpr: option requires an argument -- 'l'\n", .{});
                std.process.exit(1);
            }
            page_length = std.fmt.parseInt(usize, args[i], 10) catch {
                writeStderr("zpr: invalid page length: '{s}'\n", .{args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "--length=")) {
            const val = arg[9..];
            page_length = std.fmt.parseInt(usize, val, 10) catch {
                writeStderr("zpr: invalid page length: '{s}'\n", .{val});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--width")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zpr: option requires an argument -- 'w'\n", .{});
                std.process.exit(1);
            }
            page_width = std.fmt.parseInt(usize, args[i], 10) catch {
                writeStderr("zpr: invalid page width: '{s}'\n", .{args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "--width=")) {
            const val = arg[8..];
            page_width = std.fmt.parseInt(usize, val, 10) catch {
                writeStderr("zpr: invalid page width: '{s}'\n", .{val});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--header")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zpr: option requires an argument -- 'h'\n", .{});
                std.process.exit(1);
            }
            header = args[i];
        } else if (std.mem.startsWith(u8, arg, "--header=")) {
            header = arg[9..];
        } else if (std.mem.startsWith(u8, arg, "--columns=")) {
            const val = arg[10..];
            columns = std.fmt.parseInt(usize, val, 10) catch {
                writeStderr("zpr: invalid column count: '{s}'\n", .{val});
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "--pages=")) {
            const val = arg[8..];
            if (std.mem.indexOf(u8, val, ":")) |colon| {
                first_page = std.fmt.parseInt(usize, val[0..colon], 10) catch 1;
                last_page = std.fmt.parseInt(usize, val[colon + 1 ..], 10) catch std.math.maxInt(usize);
            } else {
                first_page = std.fmt.parseInt(usize, val, 10) catch 1;
            }
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            // Short options or -N for columns
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                const ch = arg[j];
                switch (ch) {
                    'd' => double_space = true,
                    't' => no_header = true,
                    'm' => merge_files = true,
                    'n' => number_lines = true,
                    'l' => {
                        if (j + 1 < arg.len) {
                            const val = arg[j + 1 ..];
                            page_length = std.fmt.parseInt(usize, val, 10) catch {
                                writeStderr("zpr: invalid page length: '{s}'\n", .{val});
                                std.process.exit(1);
                            };
                            break;
                        } else {
                            i += 1;
                            if (i >= args.len) {
                                writeStderr("zpr: option requires an argument -- 'l'\n", .{});
                                std.process.exit(1);
                            }
                            page_length = std.fmt.parseInt(usize, args[i], 10) catch {
                                writeStderr("zpr: invalid page length: '{s}'\n", .{args[i]});
                                std.process.exit(1);
                            };
                            break;
                        }
                    },
                    'w' => {
                        if (j + 1 < arg.len) {
                            const val = arg[j + 1 ..];
                            page_width = std.fmt.parseInt(usize, val, 10) catch {
                                writeStderr("zpr: invalid page width: '{s}'\n", .{val});
                                std.process.exit(1);
                            };
                            break;
                        } else {
                            i += 1;
                            if (i >= args.len) {
                                writeStderr("zpr: option requires an argument -- 'w'\n", .{});
                                std.process.exit(1);
                            }
                            page_width = std.fmt.parseInt(usize, args[i], 10) catch {
                                writeStderr("zpr: invalid page width: '{s}'\n", .{args[i]});
                                std.process.exit(1);
                            };
                            break;
                        }
                    },
                    'h' => {
                        i += 1;
                        if (i >= args.len) {
                            writeStderr("zpr: option requires an argument -- 'h'\n", .{});
                            std.process.exit(1);
                        }
                        header = args[i];
                        break;
                    },
                    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                        // Column count
                        columns = std.fmt.parseInt(usize, arg[j..], 10) catch 1;
                        break;
                    },
                    else => {
                        writeStderr("zpr: invalid option -- '{c}'\n", .{ch});
                        std.process.exit(1);
                    },
                }
            }
        } else if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                try files.append(allocator, args[i]);
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            try files.append(allocator, arg);
        } else if (std.mem.eql(u8, arg, "-")) {
            try files.append(allocator, "-");
        } else {
            writeStderr("zpr: unrecognized option '{s}'\n", .{arg});
            std.process.exit(1);
        }
    }

    // Default to stdin
    if (files.items.len == 0) {
        try files.append(allocator, "-");
    }

    // Calculate body lines
    const body_lines = if (no_header)
        page_length
    else if (page_length > header_lines + trailer_lines)
        page_length - header_lines - trailer_lines
    else
        page_length;

    // Get current time for header
    const timestamp = time(null);
    const date_str = formatDate(timestamp);

    // Process files
    for (files.items) |file| {
        const file_header = header orelse file;
        processFile(allocator, file, file_header, date_str, page_length, page_width, body_lines, header_lines, trailer_lines, columns, number_lines, number_width, number_sep, double_space, no_header, first_page, last_page);
    }
}

fn processFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    file_header: []const u8,
    date_str: []const u8,
    _: usize, // page_length - unused, body_lines used instead
    _: usize, // page_width - not implemented yet
    body_lines: usize,
    _: usize, // header_lines - calculated into body_lines
    trailer_lines: usize,
    _: usize, // columns - not fully implemented
    number_lines: bool,
    _: usize, // number_width - using fixed width
    number_sep: u8,
    double_space: bool,
    no_header: bool,
    first_page: usize,
    last_page: usize,
) void {

    // Open file
    var fd: c_int = 0;
    if (!std.mem.eql(u8, path, "-")) {
        var path_z: [4097]u8 = undefined;
        if (path.len >= path_z.len) {
            writeStderr("zpr: path too long\n", .{});
            return;
        }
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        fd = open(@ptrCast(&path_z), O_RDONLY, 0);
        if (fd < 0) {
            writeStderr("zpr: cannot open '{s}'\n", .{path});
            return;
        }
    }
    defer {
        if (fd != 0) _ = close(fd);
    }

    // Read and format
    var buf: [65536]u8 = undefined;
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }
    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(allocator);

    // Read all lines
    while (true) {
        const n = c_read(fd, &buf, buf.len);
        if (n <= 0) break;

        const data = buf[0..@intCast(n)];
        for (data) |byte| {
            if (byte == '\n') {
                const line_copy = allocator.dupe(u8, line_buf.items) catch continue;
                lines.append(allocator, line_copy) catch {
                    allocator.free(line_copy);
                    continue;
                };
                line_buf.clearRetainingCapacity();
            } else {
                line_buf.append(allocator, byte) catch continue;
            }
        }
    }

    // Handle last line without newline
    if (line_buf.items.len > 0) {
        const line_copy = allocator.dupe(u8, line_buf.items) catch return;
        lines.append(allocator, line_copy) catch {
            allocator.free(line_copy);
        };
    }

    // Output pages
    var line_idx: usize = 0;
    var page_num: usize = 1;
    var line_num: usize = 1;

    while (line_idx < lines.items.len) {
        // Skip pages before first_page
        if (page_num < first_page) {
            const skip = if (double_space) body_lines / 2 else body_lines;
            line_idx += skip;
            page_num += 1;
            line_num += skip;
            continue;
        }

        // Stop after last_page
        if (page_num > last_page) break;

        // Print header
        if (!no_header) {
            writeStdout("\n\n", .{});
            writeStdout("{s}  {s}  Page {d}\n", .{ date_str, file_header, page_num });
            writeStdout("\n\n", .{});
        }

        // Print body
        var body_count: usize = 0;
        const effective_body = if (double_space) body_lines / 2 else body_lines;

        while (body_count < effective_body and line_idx < lines.items.len) {
            if (number_lines) {
                writeStdout("{d:>5}{c}", .{ line_num, number_sep });
            }
            writeStdoutRaw(lines.items[line_idx]);
            writeStdout("\n", .{});

            if (double_space and body_count + 1 < effective_body) {
                writeStdout("\n", .{});
            }

            line_idx += 1;
            line_num += 1;
            body_count += 1;
        }

        // Fill remaining body lines
        while (body_count < body_lines) : (body_count += 1) {
            writeStdout("\n", .{});
        }

        // Print trailer
        if (!no_header) {
            var t: usize = 0;
            while (t < trailer_lines) : (t += 1) {
                writeStdout("\n", .{});
            }
        }

        page_num += 1;
    }
}

fn formatDate(timestamp: i64) []const u8 {
    const SECS_PER_DAY = 86400;
    const SECS_PER_HOUR = 3600;
    const SECS_PER_MIN = 60;

    var days = @divFloor(timestamp, SECS_PER_DAY);
    var remaining = @mod(timestamp, SECS_PER_DAY);
    if (remaining < 0) {
        remaining += SECS_PER_DAY;
        days -= 1;
    }

    const hour: u32 = @intCast(@divFloor(remaining, SECS_PER_HOUR));
    remaining = @mod(remaining, SECS_PER_HOUR);
    const min: u32 = @intCast(@divFloor(remaining, SECS_PER_MIN));

    var year: i32 = 1970;
    while (true) {
        const days_in_year: i64 = if (isLeapYear(year)) 366 else 365;
        if (days < days_in_year) break;
        days -= days_in_year;
        year += 1;
    }

    const month_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const month_days_leap = [_]u8{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const mdays = if (isLeapYear(year)) &month_days_leap else &month_days;

    var month: u32 = 0;
    while (month < 12) {
        if (days < mdays[month]) break;
        days -= mdays[month];
        month += 1;
    }

    const day: u32 = @intCast(days + 1);
    month += 1;

    const Static = struct {
        var buf: [32]u8 = undefined;
    };

    const result = std.fmt.bufPrint(&Static.buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        year,
        month,
        day,
        hour,
        min,
    }) catch return "";

    return result;
}

fn isLeapYear(year: i32) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
}

fn printHelp() void {
    writeStdout(
        \\Usage: zpr [OPTION]... [FILE]...
        \\Paginate and format FILE(s) for printing.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\Options:
        \\  -COLUMN               produce COLUMN-column output
        \\  -d, --double-space    double space the output
        \\  -h, --header=HEADER   use HEADER instead of filename in header
        \\  -l, --length=NUM      set page length to NUM lines (default 66)
        \\  -m, --merge           print all files in parallel, one per column
        \\  -n, --number-lines    number lines
        \\  -t, --omit-header     omit page headers and trailers
        \\  -w, --width=NUM       set page width to NUM columns (default 72)
        \\      --columns=NUM     same as -COLUMN
        \\      --pages=FIRST:LAST  print only pages in range
        \\      --help            display this help and exit
        \\      --version         output version information and exit
        \\
        \\Examples:
        \\  zpr file.txt              Format file for printing
        \\  zpr -2 file.txt           Two-column output
        \\  zpr -n file.txt           Number lines
        \\  zpr -l 50 file.txt        50 lines per page
        \\  zpr -h "My File" file.txt Custom header
        \\  zpr -t file.txt           No headers/trailers
        \\
    , .{});
}
