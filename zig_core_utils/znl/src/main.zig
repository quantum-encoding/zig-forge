//! znl - High-performance line numbering utility
//!
//! Write each FILE to standard output with line numbers added.
//!
//! Usage: znl [OPTION]... [FILE]...

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

const NumberingStyle = enum {
    all, // a: number all lines
    non_empty, // t: number non-empty lines (default)
    none, // n: no line numbering
};

const NumberFormat = enum {
    left, // ln: left justified, no leading zeros
    right, // rn: right justified, no leading zeros (default)
    right_zero, // rz: right justified, leading zeros
};

const Config = struct {
    body_style: NumberingStyle = .non_empty,
    header_style: NumberingStyle = .none,
    footer_style: NumberingStyle = .none,
    number_format: NumberFormat = .right,
    width: usize = 6,
    separator: []const u8 = "\t",
    increment: usize = 1,
    starting_line: usize = 1,
    section_delimiter: []const u8 = "\\:",
    join_blank_lines: usize = 1,
    no_renumber: bool = false,
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
        \\Usage: znl [OPTION]... [FILE]...
        \\
        \\Write each FILE to standard output with line numbers added.
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\Options:
        \\  -b, --body-numbering=STYLE      Use STYLE for body lines
        \\  -d, --section-delimiter=CC      Use CC for delimiting sections
        \\  -f, --footer-numbering=STYLE    Use STYLE for footer lines
        \\  -h, --header-numbering=STYLE    Use STYLE for header lines
        \\  -i, --line-increment=NUMBER     Line number increment
        \\  -l, --join-blank-lines=NUMBER   Group of NUMBER empty lines as one
        \\  -n, --number-format=FORMAT      Insert line numbers per FORMAT
        \\  -p, --no-renumber               Do not reset line numbers at sections
        \\  -s, --separator=STRING          Use STRING after line number
        \\  -v, --starting-line-number=NUM  First line number
        \\  -w, --number-width=NUMBER       Use NUMBER columns for line numbers
        \\      --help                      Display this help and exit
        \\      --version                   Output version information and exit
        \\
        \\STYLE is one of:
        \\  a      Number all lines
        \\  t      Number only non-empty lines (default for body)
        \\  n      Number no lines
        \\
        \\FORMAT is one of:
        \\  ln     Left justified, no leading zeros
        \\  rn     Right justified, no leading zeros (default)
        \\  rz     Right justified, leading zeros
        \\
        \\Examples:
        \\  znl file.txt               # Number non-empty lines
        \\  znl -b a file.txt          # Number all lines
        \\  znl -n rz -w 4 file.txt    # Right-justified with zeros, width 4
        \\  znl -s ': ' file.txt       # Use ': ' as separator
        \\  cat file.txt | znl         # Read from stdin
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("znl " ++ VERSION ++ " - High-performance line numbering\n");
}

fn parseStyle(s: []const u8) ?NumberingStyle {
    if (s.len == 0) return null;
    return switch (s[0]) {
        'a' => .all,
        't' => .non_empty,
        'n' => .none,
        else => null,
    };
}

fn parseFormat(s: []const u8) ?NumberFormat {
    if (std.mem.eql(u8, s, "ln")) return .left;
    if (std.mem.eql(u8, s, "rn")) return .right;
    if (std.mem.eql(u8, s, "rz")) return .right_zero;
    return null;
}

fn parseArgs(args: []const []const u8, allocator: std.mem.Allocator) !Config {
    var config = Config{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-' and arg.len > 1 and arg[1] != '-') {
            // Short options
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                switch (arg[j]) {
                    'b' => {
                        if (j + 1 < arg.len) {
                            config.body_style = parseStyle(arg[j + 1 ..]) orelse .non_empty;
                            break;
                        } else if (i + 1 < args.len) {
                            i += 1;
                            config.body_style = parseStyle(args[i]) orelse .non_empty;
                        }
                    },
                    'f' => {
                        if (j + 1 < arg.len) {
                            config.footer_style = parseStyle(arg[j + 1 ..]) orelse .none;
                            break;
                        } else if (i + 1 < args.len) {
                            i += 1;
                            config.footer_style = parseStyle(args[i]) orelse .none;
                        }
                    },
                    'h' => {
                        if (j + 1 < arg.len) {
                            config.header_style = parseStyle(arg[j + 1 ..]) orelse .none;
                            break;
                        } else if (i + 1 < args.len) {
                            i += 1;
                            config.header_style = parseStyle(args[i]) orelse .none;
                        }
                    },
                    'n' => {
                        if (j + 1 < arg.len) {
                            config.number_format = parseFormat(arg[j + 1 ..]) orelse .right;
                            break;
                        } else if (i + 1 < args.len) {
                            i += 1;
                            config.number_format = parseFormat(args[i]) orelse .right;
                        }
                    },
                    'w' => {
                        if (j + 1 < arg.len) {
                            config.width = std.fmt.parseInt(usize, arg[j + 1 ..], 10) catch 6;
                            break;
                        } else if (i + 1 < args.len) {
                            i += 1;
                            config.width = std.fmt.parseInt(usize, args[i], 10) catch 6;
                        }
                    },
                    's' => {
                        if (j + 1 < arg.len) {
                            config.separator = arg[j + 1 ..];
                            break;
                        } else if (i + 1 < args.len) {
                            i += 1;
                            config.separator = args[i];
                        }
                    },
                    'i' => {
                        if (j + 1 < arg.len) {
                            config.increment = std.fmt.parseInt(usize, arg[j + 1 ..], 10) catch 1;
                            break;
                        } else if (i + 1 < args.len) {
                            i += 1;
                            config.increment = std.fmt.parseInt(usize, args[i], 10) catch 1;
                        }
                    },
                    'v' => {
                        if (j + 1 < arg.len) {
                            config.starting_line = std.fmt.parseInt(usize, arg[j + 1 ..], 10) catch 1;
                            break;
                        } else if (i + 1 < args.len) {
                            i += 1;
                            config.starting_line = std.fmt.parseInt(usize, args[i], 10) catch 1;
                        }
                    },
                    'd' => {
                        if (j + 1 < arg.len) {
                            config.section_delimiter = arg[j + 1 ..];
                            break;
                        } else if (i + 1 < args.len) {
                            i += 1;
                            config.section_delimiter = args[i];
                        }
                    },
                    'l' => {
                        if (j + 1 < arg.len) {
                            config.join_blank_lines = std.fmt.parseInt(usize, arg[j + 1 ..], 10) catch 1;
                            break;
                        } else if (i + 1 < args.len) {
                            i += 1;
                            config.join_blank_lines = std.fmt.parseInt(usize, args[i], 10) catch 1;
                        }
                    },
                    'p' => {
                        config.no_renumber = true;
                    },
                    else => {},
                }
            }
        } else if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.eql(u8, arg, "--help")) {
                printUsage();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                std.process.exit(0);
            } else if (std.mem.startsWith(u8, arg, "--body-numbering=")) {
                config.body_style = parseStyle(arg[17..]) orelse .non_empty;
            } else if (std.mem.startsWith(u8, arg, "--header-numbering=")) {
                config.header_style = parseStyle(arg[19..]) orelse .none;
            } else if (std.mem.startsWith(u8, arg, "--footer-numbering=")) {
                config.footer_style = parseStyle(arg[19..]) orelse .none;
            } else if (std.mem.startsWith(u8, arg, "--number-format=")) {
                config.number_format = parseFormat(arg[16..]) orelse .right;
            } else if (std.mem.startsWith(u8, arg, "--number-width=")) {
                config.width = std.fmt.parseInt(usize, arg[15..], 10) catch 6;
            } else if (std.mem.startsWith(u8, arg, "--separator=")) {
                config.separator = arg[12..];
            } else if (std.mem.startsWith(u8, arg, "--line-increment=")) {
                config.increment = std.fmt.parseInt(usize, arg[17..], 10) catch 1;
            } else if (std.mem.startsWith(u8, arg, "--starting-line-number=")) {
                config.starting_line = std.fmt.parseInt(usize, arg[23..], 10) catch 1;
            } else if (std.mem.startsWith(u8, arg, "--section-delimiter=")) {
                config.section_delimiter = arg[20..];
            } else if (std.mem.startsWith(u8, arg, "--join-blank-lines=")) {
                config.join_blank_lines = std.fmt.parseInt(usize, arg[19..], 10) catch 1;
            } else if (std.mem.eql(u8, arg, "--no-renumber")) {
                config.no_renumber = true;
            }
        } else {
            try config.files.append(allocator, arg);
        }
    }

    // Default to stdin if no files
    if (config.files.items.len == 0) {
        try config.files.append(allocator, "-");
    }

    return config;
}

fn formatLineNumber(num: usize, format: NumberFormat, width: usize, buf: []u8) []const u8 {
    return switch (format) {
        .left => std.fmt.bufPrint(buf, "{d: <[1]}", .{ num, width }) catch "",
        .right => std.fmt.bufPrint(buf, "{d: >[1]}", .{ num, width }) catch "",
        .right_zero => std.fmt.bufPrint(buf, "{d:0>[1]}", .{ num, width }) catch "",
    };
}

const SectionType = enum {
    header,
    body,
    footer,
};

fn processFile(path: []const u8, config: *const Config, line_num: *usize, allocator: std.mem.Allocator) !void {
    const is_stdin = std.mem.eql(u8, path, "-");

    // Open file or use stdin
    var fd: c_int = 0; // stdin
    if (!is_stdin) {
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch {
            writeStderr("znl: path too long\n");
            return error.PathTooLong;
        };
        const fd_ret = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd_ret < 0) {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "znl: {s}: No such file or directory\n", .{path}) catch "znl: cannot open file\n";
            writeStderr(err_msg);
            return error.FileNotFound;
        }
        fd = fd_ret;
    }
    defer {
        if (!is_stdin) _ = libc.close(fd);
    }

    var current_section: SectionType = .body;
    var consecutive_blanks: usize = 0;

    // Read and process line by line
    var read_buf: [8192]u8 = undefined;
    var line_buf = std.ArrayListUnmanaged(u8).empty;
    defer line_buf.deinit(allocator);

    while (true) {
        const bytes_ret = libc.read(fd, &read_buf, read_buf.len);
        if (bytes_ret <= 0) break;
        const bytes_read: usize = @intCast(bytes_ret);

        for (read_buf[0..bytes_read]) |c| {
            if (c == '\n') {
                // Check for section delimiter
                const section_change = detectSection(line_buf.items, config.section_delimiter);
                if (section_change) |new_section| {
                    current_section = new_section;
                    if (!config.no_renumber) {
                        line_num.* = config.starting_line;
                    }
                    consecutive_blanks = 0;
                    // Section delimiter lines are not printed
                    writeStdout("\n");
                    line_buf.clearRetainingCapacity();
                } else {
                    // Process complete line
                    outputLine(line_buf.items, config, line_num, current_section, &consecutive_blanks);
                    line_buf.clearRetainingCapacity();
                }
            } else {
                line_buf.append(allocator, c) catch {};
            }
        }
    }

    // Handle last line without newline
    if (line_buf.items.len > 0) {
        outputLine(line_buf.items, config, line_num, current_section, &consecutive_blanks);
    }
}

fn detectSection(line: []const u8, delimiter: []const u8) ?SectionType {
    // Section delimiters are lines consisting of the delimiter repeated:
    // delimiter x 3 = header (e.g. \:\:\:)
    // delimiter x 2 = body (e.g. \:\:)
    // delimiter x 1 = footer (e.g. \:)
    if (delimiter.len == 0) return null;

    // Check header (3x delimiter)
    if (delimiter.len * 3 == line.len) {
        if (std.mem.startsWith(u8, line, delimiter)) {
            const rest1 = line[delimiter.len..];
            if (std.mem.startsWith(u8, rest1, delimiter)) {
                const rest2 = rest1[delimiter.len..];
                if (std.mem.eql(u8, rest2, delimiter)) {
                    return .header;
                }
            }
        }
    }

    // Check body (2x delimiter)
    if (delimiter.len * 2 == line.len) {
        if (std.mem.startsWith(u8, line, delimiter)) {
            const rest = line[delimiter.len..];
            if (std.mem.eql(u8, rest, delimiter)) {
                return .body;
            }
        }
    }

    // Check footer (1x delimiter)
    if (delimiter.len == line.len) {
        if (std.mem.eql(u8, line, delimiter)) {
            return .footer;
        }
    }

    return null;
}

fn outputLine(line: []const u8, config: *const Config, line_num: *usize, section: SectionType, consecutive_blanks: *usize) void {
    const is_empty = line.len == 0;
    const style = switch (section) {
        .header => config.header_style,
        .body => config.body_style,
        .footer => config.footer_style,
    };

    // Handle blank line joining
    if (is_empty) {
        consecutive_blanks.* += 1;
    } else {
        consecutive_blanks.* = 0;
    }

    var should_number = switch (style) {
        .all => true,
        .non_empty => !is_empty,
        .none => false,
    };

    // For -l (join blank lines): when style is 'a', only number every Nth blank line
    if (is_empty and style == .all and config.join_blank_lines > 1) {
        if (consecutive_blanks.* % config.join_blank_lines != 0) {
            should_number = false;
        }
    }

    if (should_number) {
        var num_buf: [32]u8 = undefined;
        const num_str = formatLineNumber(line_num.*, config.number_format, config.width, &num_buf);
        writeStdout(num_str);
        writeStdout(config.separator);
        line_num.* += config.increment;
    } else {
        // Output spaces for alignment (no separator for un-numbered lines, matching GNU nl)
        var space_buf: [64]u8 = undefined;
        const pad_width = config.width + config.separator.len;
        const spaces = std.fmt.bufPrint(&space_buf, "{s: >[1]}", .{ "", pad_width }) catch "";
        writeStdout(spaces);
    }

    writeStdout(line);
    writeStdout("\n");
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

    var line_num: usize = config.starting_line;

    for (config.files.items) |path| {
        processFile(path, &config, &line_num, allocator) catch continue;
    }
}
