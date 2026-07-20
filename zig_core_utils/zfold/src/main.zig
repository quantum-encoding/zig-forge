//! zfold - line folding utility (GNU `fold` reimplementation)
//!
//! Wrap input lines to fit in a specified width.
//!
//! Usage: zfold [OPTION]... [FILE]...

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

// GNU fold hardcodes the tab stop at 8 columns (see coreutils fold.c TAB_WIDTH).
// It is NOT configurable; GNU rejects any -T/--tab-width option.
const TAB_WIDTH: usize = 8;

extern "c" fn strerror(errnum: c_int) [*:0]const u8;

const Config = struct {
    width: usize = 80,
    break_at_spaces: bool = false,
    count_bytes: bool = false,
    files: std.ArrayListUnmanaged([]const u8) = .empty,
};

const ArgError = error{InvalidArg};

fn writeAll(fd: c_int, msg: []const u8) void {
    var off: usize = 0;
    while (off < msg.len) {
        const r = libc.write(fd, msg.ptr + off, msg.len - off);
        if (r < 0) {
            // Retry on EINTR; give up on any other error.
            if (libc._errno().* == @intFromEnum(libc.E.INTR)) continue;
            return;
        }
        if (r == 0) return;
        off += @intCast(r);
    }
}

fn writeStdout(msg: []const u8) void {
    writeAll(libc.STDOUT_FILENO, msg);
}

fn writeStderr(msg: []const u8) void {
    writeAll(libc.STDERR_FILENO, msg);
}

fn printUsage(fd: c_int) void {
    const usage =
        \\Usage: zfold [OPTION]... [FILE]...
        \\Wrap input lines in each FILE (or standard input), writing to
        \\standard output.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\  -b, --bytes            count bytes rather than columns
        \\  -c, --characters       count characters rather than columns
        \\  -s, --spaces           break at spaces
        \\  -w, --width=WIDTH      use WIDTH columns instead of 80
        \\      --help             display this help and exit
        \\      --version          output version information and exit
        \\
    ;
    writeAll(fd, usage);
}

fn printVersion(fd: c_int) void {
    writeAll(fd, "zfold " ++ VERSION ++ "\n");
}

fn printTryHelp() void {
    writeStderr("Try 'zfold --help' for more information.\n");
}

// GNU fold rejects width 0, non-numeric widths, and values that do not fit in
// uintmax_t; it exits 1 with "invalid number of columns" in every case.
fn parseWidth(s: []const u8) ArgError!usize {
    const v = std.fmt.parseInt(usize, s, 10) catch {
        widthError(s);
        return error.InvalidArg;
    };
    if (v == 0) {
        widthError(s);
        return error.InvalidArg;
    }
    return v;
}

fn widthError(s: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zfold: invalid number of columns: '{s}'\n", .{s}) catch "zfold: invalid number of columns\n";
    writeStderr(msg);
}

fn badOption(arg: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "zfold: invalid option -- '{s}'\n", .{arg}) catch "zfold: invalid option\n";
    writeStderr(msg);
    printTryHelp();
}

fn parseArgs(args: []const []const u8, allocator: std.mem.Allocator) !Config {
    var config = Config{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 1 and arg[0] == '-') {
            if (arg[1] != '-') {
                // Short options (possibly clustered).
                var j: usize = 1;
                while (j < arg.len) : (j += 1) {
                    switch (arg[j]) {
                        'b' => config.count_bytes = true,
                        'c' => config.count_bytes = false,
                        's' => config.break_at_spaces = true,
                        'w' => {
                            if (j + 1 < arg.len) {
                                config.width = try parseWidth(arg[j + 1 ..]);
                                break;
                            } else if (i + 1 < args.len) {
                                i += 1;
                                config.width = try parseWidth(args[i]);
                            } else {
                                badOption(arg[j .. j + 1]);
                                return error.InvalidArg;
                            }
                        },
                        '0'...'9' => {
                            // Obsolete -WIDTH shorthand for -w WIDTH.
                            config.width = try parseWidth(arg[j..]);
                            break;
                        },
                        else => {
                            badOption(arg[j .. j + 1]);
                            return error.InvalidArg;
                        },
                    }
                }
            } else {
                // Long options.
                if (std.mem.eql(u8, arg, "--help")) {
                    printUsage(libc.STDOUT_FILENO);
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--version")) {
                    printVersion(libc.STDOUT_FILENO);
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--bytes")) {
                    config.count_bytes = true;
                } else if (std.mem.eql(u8, arg, "--characters")) {
                    config.count_bytes = false;
                } else if (std.mem.eql(u8, arg, "--spaces")) {
                    config.break_at_spaces = true;
                } else if (std.mem.startsWith(u8, arg, "--width=")) {
                    config.width = try parseWidth(arg[8..]);
                } else if (std.mem.eql(u8, arg, "--width")) {
                    if (i + 1 < args.len) {
                        i += 1;
                        config.width = try parseWidth(args[i]);
                    } else {
                        badOption(arg[2..]);
                        return error.InvalidArg;
                    }
                } else if (std.mem.eql(u8, arg, "--")) {
                    // End of options: everything after is a file.
                    i += 1;
                    while (i < args.len) : (i += 1) {
                        try config.files.append(allocator, args[i]);
                    }
                    break;
                } else {
                    badOption(arg[2..]);
                    return error.InvalidArg;
                }
            }
        } else {
            try config.files.append(allocator, arg);
        }
    }

    // Default to stdin if no files given.
    if (config.files.items.len == 0) {
        try config.files.append(allocator, "-");
    }

    return config;
}

// Mirrors GNU fold's adjust_column(): advance the screen column for one byte.
// In column mode, backspace decrements, carriage return resets to 0, tab jumps
// to the next tab stop. In byte/char mode every byte counts as one column.
fn adjustColumn(column: usize, c: u8, count_bytes: bool) usize {
    if (!count_bytes) {
        if (c == 0x08) { // backspace
            return if (column > 0) column - 1 else 0;
        } else if (c == '\r') {
            return 0;
        } else if (c == '\t') {
            return column + (TAB_WIDTH - column % TAB_WIDTH);
        } else {
            return column + 1;
        }
    }
    return column + 1;
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn processFile(path: []const u8, config: *const Config, allocator: std.mem.Allocator) !void {
    const is_stdin = std.mem.eql(u8, path, "-");

    var fd: c_int = 0; // stdin
    if (!is_stdin) {
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch {
            writeStderr("zfold: path too long\n");
            return error.PathTooLong;
        };
        const fd_ret = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd_ret < 0) {
            const e = libc._errno().*;
            var err_buf: [512]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "zfold: {s}: {s}\n", .{ path, std.mem.span(strerror(e)) }) catch "zfold: cannot open file\n";
            writeStderr(err_msg);
            return error.OpenFailed;
        }
        fd = fd_ret;
    }
    defer {
        if (!is_stdin) _ = libc.close(fd);
    }

    var read_buf: [8192]u8 = undefined;
    var line_buf = std.ArrayListUnmanaged(u8).empty;
    defer line_buf.deinit(allocator);

    const width = config.width;
    const count_bytes = config.count_bytes;
    var column: usize = 0;

    while (true) {
        const bytes_ret = libc.read(fd, &read_buf, read_buf.len);
        if (bytes_ret < 0) {
            const e = libc._errno().*;
            if (e == @intFromEnum(libc.E.INTR)) continue;
            var err_buf: [512]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "zfold: {s}: {s}\n", .{ path, std.mem.span(strerror(e)) }) catch "zfold: read error\n";
            writeStderr(err_msg);
            return error.ReadFailed;
        }
        if (bytes_ret == 0) break;
        const bytes_read: usize = @intCast(bytes_ret);

        for (read_buf[0..bytes_read]) |c| {
            if (c == '\n') {
                try line_buf.append(allocator, c);
                writeStdout(line_buf.items);
                line_buf.clearRetainingCapacity();
                column = 0;
                continue;
            }

            // rescan loop: after a wrap, GNU re-processes the same byte against
            // the newly-started line (goto rescan in fold.c).
            while (true) {
                column = adjustColumn(column, c, count_bytes);

                if (column > width) {
                    if (config.break_at_spaces) {
                        // Look for the last blank in the buffered line.
                        var logical_end = line_buf.items.len;
                        var found = false;
                        while (logical_end > 0) {
                            logical_end -= 1;
                            if (isBlank(line_buf.items[logical_end])) {
                                found = true;
                                break;
                            }
                        }
                        if (found) {
                            logical_end += 1;
                            writeStdout(line_buf.items[0..logical_end]);
                            writeStdout("\n");
                            const rem = line_buf.items.len - logical_end;
                            std.mem.copyForwards(u8, line_buf.items[0..rem], line_buf.items[logical_end..]);
                            line_buf.shrinkRetainingCapacity(rem);
                            // Recompute column for the moved remainder.
                            column = 0;
                            for (line_buf.items) |bc| column = adjustColumn(column, bc, count_bytes);
                            continue; // rescan c
                        }
                    }

                    if (line_buf.items.len == 0) {
                        // A single char wider than width: emit it as-is.
                        try line_buf.append(allocator, c);
                        break;
                    }

                    // Hard wrap: flush buffered line + newline, restart on c.
                    try line_buf.append(allocator, '\n');
                    writeStdout(line_buf.items);
                    line_buf.clearRetainingCapacity();
                    column = 0;
                    continue; // rescan c
                }

                try line_buf.append(allocator, c);
                break;
            }
        }
    }

    // Flush any trailing content that never ended with a newline.
    if (line_buf.items.len > 0) {
        writeStdout(line_buf.items);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var config = parseArgs(args[1..], allocator) catch {
        std.process.exit(1);
    };
    defer config.files.deinit(allocator);

    var any_failed = false;
    for (config.files.items) |path| {
        processFile(path, &config, allocator) catch {
            any_failed = true;
        };
    }

    if (any_failed) std.process.exit(1);
}
