//! zfold - High-performance line folding utility
//!
//! Wrap input lines to fit in specified width.
//!
//! Usage: zfold [OPTION]... [FILE]...

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

const Config = struct {
    width: usize = 80,
    tab_width: usize = 8,
    break_at_spaces: bool = false,
    count_bytes: bool = false,
    files: std.ArrayListUnmanaged([]const u8) = .empty,
};

fn writeStdout(msg: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, msg.ptr, msg.len);
}

fn writeStderr(msg: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zfold [OPTION]... [FILE]...
        \\
        \\Wrap input lines in each FILE (or standard input), writing to
        \\standard output.
        \\
        \\Options:
        \\  -b, --bytes            Count bytes rather than columns
        \\  -s, --spaces           Break at spaces
        \\  -w, --width=WIDTH      Use WIDTH columns instead of 80
        \\  -T, --tab-width=WIDTH  Assume tabs stop at every WIDTH columns (default 8)
        \\      --help             Display this help and exit
        \\      --version          Output version information and exit
        \\
        \\Examples:
        \\  zfold file.txt             # Fold to 80 columns
        \\  zfold -w 40 file.txt       # Fold to 40 columns
        \\  zfold -s -w 60 file.txt    # Fold at spaces, 60 columns
        \\  cat long.txt | zfold -w 72 # Pipe through fold
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zfold " ++ VERSION ++ " - High-performance line folding\n");
}

fn parseArgs(args: []const []const u8, allocator: std.mem.Allocator) !Config {
    var config = Config{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            if (arg[1] != '-') {
                // Short options
                var j: usize = 1;
                while (j < arg.len) : (j += 1) {
                    switch (arg[j]) {
                        'b' => config.count_bytes = true,
                        's' => config.break_at_spaces = true,
                        'w' => {
                            if (j + 1 < arg.len) {
                                config.width = std.fmt.parseInt(usize, arg[j + 1 ..], 10) catch 80;
                                break;
                            } else if (i + 1 < args.len) {
                                i += 1;
                                config.width = std.fmt.parseInt(usize, args[i], 10) catch 80;
                            }
                        },
                        'T' => {
                            if (j + 1 < arg.len) {
                                config.tab_width = std.fmt.parseInt(usize, arg[j + 1 ..], 10) catch 8;
                                break;
                            } else if (i + 1 < args.len) {
                                i += 1;
                                config.tab_width = std.fmt.parseInt(usize, args[i], 10) catch 8;
                            }
                        },
                        '0'...'9' => {
                            // -N shorthand for -w N
                            config.width = std.fmt.parseInt(usize, arg[j..], 10) catch 80;
                            break;
                        },
                        else => {},
                    }
                }
            } else {
                // Long options
                if (std.mem.eql(u8, arg, "--help")) {
                    printUsage();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--version")) {
                    printVersion();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--bytes")) {
                    config.count_bytes = true;
                } else if (std.mem.eql(u8, arg, "--spaces")) {
                    config.break_at_spaces = true;
                } else if (std.mem.startsWith(u8, arg, "--width=")) {
                    config.width = std.fmt.parseInt(usize, arg[8..], 10) catch 80;
                } else if (std.mem.startsWith(u8, arg, "--tab-width=")) {
                    config.tab_width = std.fmt.parseInt(usize, arg[12..], 10) catch 8;
                }
            }
        } else {
            try config.files.append(allocator, arg);
        }
    }

    // Default to stdin if no files
    if (config.files.items.len == 0) {
        try config.files.append(allocator, "-");
    }

    // Minimum width of 1
    if (config.width == 0) {
        config.width = 1;
    }

    // Minimum tab width of 1
    if (config.tab_width == 0) {
        config.tab_width = 1;
    }

    return config;
}

fn charWidth(c: u8, current_col: usize, tab_width: usize) usize {
    // Tab advances to next tab stop
    if (c == '\t') {
        if (tab_width == 0) return 1;
        return tab_width - (current_col % tab_width);
    }
    // Control characters are 0 width for display
    if (c < 32 or c == 127) return 0;
    // Regular characters are 1 column
    return 1;
}

fn processFile(path: []const u8, config: *const Config, allocator: std.mem.Allocator) !void {
    const is_stdin = std.mem.eql(u8, path, "-");

    // Open file or use stdin
    var fd: c_int = 0; // stdin
    if (!is_stdin) {
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch {
            writeStderr("zfold: path too long\n");
            return error.PathTooLong;
        };
        const fd_ret = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd_ret < 0) {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "zfold: {s}: No such file or directory\n", .{path}) catch "zfold: cannot open file\n";
            writeStderr(err_msg);
            return error.FileNotFound;
        }
        fd = fd_ret;
    }
    defer {
        if (!is_stdin) _ = libc.close(fd);
    }

    // Read and process
    var read_buf: [8192]u8 = undefined;
    var line_buf = std.ArrayListUnmanaged(u8).empty;
    defer line_buf.deinit(allocator);

    var column: usize = 0;
    var last_space_idx: ?usize = null;
    var last_space_col: usize = 0;

    while (true) {
        const bytes_ret = libc.read(fd, &read_buf, read_buf.len);
        if (bytes_ret <= 0) break;
        const bytes_read: usize = @intCast(bytes_ret);

        for (read_buf[0..bytes_read]) |c| {
            if (c == '\n') {
                // Output line and reset
                line_buf.append(allocator, c) catch {};
                writeStdout(line_buf.items);
                line_buf.clearRetainingCapacity();
                column = 0;
                last_space_idx = null;
                continue;
            }

            // Calculate width of this character
            const w = if (config.count_bytes) @as(usize, 1) else charWidth(c, column, config.tab_width);

            // Check if we need to wrap
            if (column + w > config.width and column > 0) {
                if (config.break_at_spaces and last_space_idx != null) {
                    // Break at last space
                    const break_idx = last_space_idx.?;
                    // Output up to and including space
                    writeStdout(line_buf.items[0 .. break_idx + 1]);
                    writeStdout("\n");

                    // Keep remainder
                    const remainder_start = break_idx + 1;
                    if (remainder_start < line_buf.items.len) {
                        const remainder = line_buf.items[remainder_start..];
                        // Recalculate column for remainder
                        column = 0;
                        for (remainder) |rc| {
                            column += if (config.count_bytes) 1 else charWidth(rc, column, config.tab_width);
                        }
                        // Shift remainder to beginning
                        std.mem.copyForwards(u8, line_buf.items[0..remainder.len], remainder);
                        line_buf.shrinkRetainingCapacity(remainder.len);
                    } else {
                        line_buf.clearRetainingCapacity();
                        column = 0;
                    }
                    last_space_idx = null;
                } else {
                    // Hard wrap at width
                    writeStdout(line_buf.items);
                    writeStdout("\n");
                    line_buf.clearRetainingCapacity();
                    column = 0;
                    last_space_idx = null;
                }
            }

            // Track spaces for -s option (after wrap check so current space
            // doesn't become break point for itself)
            if (c == ' ' or c == '\t') {
                last_space_idx = line_buf.items.len;
                last_space_col = column;
            }

            line_buf.append(allocator, c) catch {};
            column += w;
        }
    }

    // Output any remaining content
    if (line_buf.items.len > 0) {
        writeStdout(line_buf.items);
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

    var config = parseArgs(args[1..], allocator) catch {
        std.process.exit(1);
    };
    defer config.files.deinit(allocator);

    for (config.files.items) |path| {
        processFile(path, &config, allocator) catch continue;
    }
}
