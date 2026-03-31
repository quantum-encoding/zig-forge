//! zmore - File perusal filter for viewing text one screenful at a time
//!
//! A Zig implementation of more.
//! View file contents with paging support.
//!
//! Usage: zmore [OPTIONS] [FILE]...

const std = @import("std");

const VERSION = "1.0.0";

// C functions
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn isatty(fd: c_int) c_int;
extern "c" fn tcgetattr(fd: c_int, termios: *Termios) c_int;
extern "c" fn tcsetattr(fd: c_int, actions: c_int, termios: *const Termios) c_int;

const c_read = @extern(*const fn (c_int, [*]u8, usize) callconv(.c) isize, .{ .name = "read" });

const O_RDONLY: c_int = 0;
const TCSANOW: c_int = 0;

// Termios structure for terminal control
const Termios = extern struct {
    c_iflag: u32,
    c_oflag: u32,
    c_cflag: u32,
    c_lflag: u32,
    c_line: u8,
    c_cc: [32]u8,
    c_ispeed: u32,
    c_ospeed: u32,
};

const ICANON: u32 = 0x00000002;
const ECHO: u32 = 0x00000008;

// ANSI escape codes
const CLEAR_SCREEN = "\x1b[2J\x1b[H";
const CLEAR_LINE = "\x1b[2K\r";
const REVERSE_VIDEO = "\x1b[7m";
const NORMAL_VIDEO = "\x1b[0m";
const CURSOR_UP = "\x1b[A";
const HIDE_CURSOR = "\x1b[?25l";
const SHOW_CURSOR = "\x1b[?25h";

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

fn getTerminalSize() struct { rows: usize, cols: usize } {
    // Try ioctl TIOCGWINSZ
    const TIOCGWINSZ: u32 = 0x5413;
    const Winsize = extern struct {
        ws_row: u16,
        ws_col: u16,
        ws_xpixel: u16,
        ws_ypixel: u16,
    };

    var ws: Winsize = undefined;
    const ioctl = @extern(*const fn (c_int, u32, *Winsize) callconv(.c) c_int, .{ .name = "ioctl" });

    if (ioctl(1, TIOCGWINSZ, &ws) == 0 and ws.ws_row > 0 and ws.ws_col > 0) {
        return .{ .rows = ws.ws_row, .cols = ws.ws_col };
    }

    // Default
    return .{ .rows = 24, .cols = 80 };
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
    var clear_screen = false;
    var squeeze_blank = false;
    var start_line: usize = 0;
    var num_lines: usize = 0;
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            writeStdout("zmore {s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--clean")) {
            clear_screen = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--squeeze")) {
            squeeze_blank = true;
        } else if (std.mem.startsWith(u8, arg, "+")) {
            // +N starts at line N
            start_line = std.fmt.parseInt(usize, arg[1..], 10) catch 0;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--lines")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("zmore: option requires an argument -- 'n'\n", .{});
                std.process.exit(1);
            }
            num_lines = std.fmt.parseInt(usize, args[i], 10) catch {
                writeStderr("zmore: invalid number of lines: '{s}'\n", .{args[i]});
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            // Could be -N for lines
            if (arg[1] >= '0' and arg[1] <= '9') {
                num_lines = std.fmt.parseInt(usize, arg[1..], 10) catch 0;
            } else {
                // Combined short options
                for (arg[1..]) |ch| {
                    switch (ch) {
                        'c' => clear_screen = true,
                        's' => squeeze_blank = true,
                        else => {
                            writeStderr("zmore: invalid option -- '{c}'\n", .{ch});
                            std.process.exit(1);
                        },
                    }
                }
            }
        } else {
            try files.append(allocator, arg);
        }
    }

    // Get terminal size
    const term = getTerminalSize();
    const page_lines = if (num_lines > 0) num_lines else term.rows - 1;

    // Check if output is a tty
    const is_tty = isatty(1) != 0;

    if (files.items.len == 0) {
        // Read from stdin
        _ = try displayFile(allocator, "-", page_lines, start_line, clear_screen, squeeze_blank, is_tty, false);
    } else {
        const show_header = files.items.len > 1;
        for (files.items, 0..) |file, idx| {
            if (show_header) {
                if (idx > 0) writeStdout("\n", .{});
                writeStdout("{s}:::::::::::::::{s}\n", .{ REVERSE_VIDEO, NORMAL_VIDEO });
                writeStdout("{s}{s}{s}\n", .{ REVERSE_VIDEO, file, NORMAL_VIDEO });
                writeStdout("{s}:::::::::::::::{s}\n", .{ REVERSE_VIDEO, NORMAL_VIDEO });
            }
            const should_continue = try displayFile(allocator, file, page_lines, start_line, clear_screen, squeeze_blank, is_tty, idx + 1 < files.items.len);
            if (!should_continue) break;
        }
    }
}

fn displayFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    page_lines: usize,
    start_line: usize,
    clear_screen: bool,
    squeeze_blank: bool,
    is_tty: bool,
    has_more_files: bool,
) !bool {
    // Open file
    var fd: c_int = 0;
    if (!std.mem.eql(u8, path, "-")) {
        var path_z: [4097]u8 = undefined;
        if (path.len >= path_z.len) {
            writeStderr("zmore: path too long\n", .{});
            return true;
        }
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        fd = open(@ptrCast(&path_z), O_RDONLY, 0);
        if (fd < 0) {
            writeStderr("zmore: cannot open '{s}'\n", .{path});
            return true;
        }
    }
    defer {
        if (fd != 0) _ = close(fd);
    }

    // Read all lines
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    var buf: [65536]u8 = undefined;
    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(allocator);

    var prev_blank = false;

    while (true) {
        const n = c_read(fd, &buf, buf.len);
        if (n <= 0) break;

        const data = buf[0..@intCast(n)];
        for (data) |byte| {
            if (byte == '\n') {
                const is_blank = line_buf.items.len == 0;

                // Squeeze blank lines
                if (squeeze_blank and is_blank and prev_blank) {
                    line_buf.clearRetainingCapacity();
                    continue;
                }
                prev_blank = is_blank;

                const line_copy = try allocator.dupe(u8, line_buf.items);
                try lines.append(allocator, line_copy);
                line_buf.clearRetainingCapacity();
            } else {
                try line_buf.append(allocator, byte);
            }
        }
    }

    // Handle last line without newline
    if (line_buf.items.len > 0) {
        const line_copy = try allocator.dupe(u8, line_buf.items);
        try lines.append(allocator, line_copy);
    }

    // If not a tty, just output everything
    if (!is_tty) {
        var line_idx: usize = start_line;
        while (line_idx < lines.items.len) : (line_idx += 1) {
            writeStdoutRaw(lines.items[line_idx]);
            writeStdout("\n", .{});
        }
        return true;
    }

    // Interactive paging
    var orig_termios: Termios = undefined;
    const tty_fd: c_int = 2; // Use stderr for tty input (stdin might be pipe)
    const have_tty = tcgetattr(tty_fd, &orig_termios) == 0;

    if (have_tty) {
        var raw = orig_termios;
        raw.c_lflag &= ~(ICANON | ECHO);
        _ = tcsetattr(tty_fd, TCSANOW, &raw);
    }

    defer {
        if (have_tty) {
            _ = tcsetattr(tty_fd, TCSANOW, &orig_termios);
        }
    }

    if (clear_screen) {
        writeStdoutRaw(CLEAR_SCREEN);
    }

    var line_idx: usize = start_line;
    var lines_shown: usize = 0;

    while (line_idx < lines.items.len) {
        // Display lines
        while (lines_shown < page_lines and line_idx < lines.items.len) {
            writeStdoutRaw(lines.items[line_idx]);
            writeStdout("\n", .{});
            line_idx += 1;
            lines_shown += 1;
        }

        // Check if we're at end
        if (line_idx >= lines.items.len) {
            if (has_more_files) {
                // Show prompt for next file
                const pct: usize = 100;
                writeStdout("{s}--More--({d}%) [Next file]{s}", .{ REVERSE_VIDEO, pct, NORMAL_VIDEO });

                var key_buf: [1]u8 = undefined;
                _ = c_read(tty_fd, &key_buf, 1);
                writeStdoutRaw(CLEAR_LINE);

                if (key_buf[0] == 'q' or key_buf[0] == 'Q') {
                    return false;
                }
            }
            break;
        }

        // Show prompt
        const pct = (line_idx * 100) / lines.items.len;
        writeStdout("{s}--More--({d}%){s}", .{ REVERSE_VIDEO, pct, NORMAL_VIDEO });

        // Wait for key
        var key_buf: [1]u8 = undefined;
        _ = c_read(tty_fd, &key_buf, 1);

        // Clear the prompt
        writeStdoutRaw(CLEAR_LINE);

        switch (key_buf[0]) {
            ' ' => {
                // Next page
                lines_shown = 0;
                if (clear_screen) {
                    writeStdoutRaw(CLEAR_SCREEN);
                }
            },
            '\n', '\r' => {
                // Next line
                lines_shown = page_lines - 1;
            },
            'b', 'B' => {
                // Back one page
                if (line_idx > page_lines * 2) {
                    line_idx -= page_lines * 2;
                } else {
                    line_idx = 0;
                }
                lines_shown = 0;
                if (clear_screen) {
                    writeStdoutRaw(CLEAR_SCREEN);
                }
            },
            'q', 'Q' => {
                return false;
            },
            '/' => {
                // Search forward (simplified - just skip to next match)
                writeStdout("/", .{});
                // For now, just continue
                lines_shown = 0;
            },
            'h', 'H', '?' => {
                // Help
                writeStdout("\n", .{});
                writeStdout("Commands:\n", .{});
                writeStdout("  SPACE     - next page\n", .{});
                writeStdout("  ENTER     - next line\n", .{});
                writeStdout("  b         - back one page\n", .{});
                writeStdout("  q         - quit\n", .{});
                writeStdout("  h         - this help\n", .{});
                writeStdout("\nPress any key to continue...", .{});
                _ = c_read(tty_fd, &key_buf, 1);
                lines_shown = 0;
                if (clear_screen) {
                    writeStdoutRaw(CLEAR_SCREEN);
                }
            },
            else => {
                // Unknown key - show next page
                lines_shown = 0;
            },
        }
    }

    return true;
}

fn printHelp() void {
    writeStdout(
        \\Usage: zmore [OPTION]... [FILE]...
        \\View FILE(s) one screenful at a time.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\Options:
        \\  -c, --clean      do not scroll, clear screen before display
        \\  -s, --squeeze    squeeze multiple blank lines into one
        \\  -n, --lines=N    use N lines per screenful
        \\  -NUM             same as --lines=NUM
        \\  +NUM             start at line NUM
        \\      --help       display this help and exit
        \\      --version    output version information and exit
        \\
        \\Interactive commands:
        \\  SPACE    display next page
        \\  ENTER    display next line
        \\  b        go back one page
        \\  q        quit
        \\  h        show help
        \\
        \\Examples:
        \\  zmore file.txt           View file with paging
        \\  zmore -c file.txt        Clear screen before each page
        \\  zmore -s file.txt        Squeeze blank lines
        \\  zmore +100 file.txt      Start at line 100
        \\  cat file | zmore         Page piped input
        \\
    , .{});
}
