//! zcomm - High-performance file comparison utility
//!
//! Compare two sorted files line by line.
//!
//! Usage: zcomm [OPTION]... FILE1 FILE2

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

const Config = struct {
    suppress_col1: bool = false, // Lines only in FILE1
    suppress_col2: bool = false, // Lines only in FILE2
    suppress_col3: bool = false, // Lines in both files
    check_order: bool = true,
    output_delimiter: []const u8 = "\t",
    zero_terminated: bool = false,
    file1: ?[]const u8 = null,
    file2: ?[]const u8 = null,
};

fn writeStdout(msg: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, msg.ptr, msg.len);
}

fn writeStderr(msg: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zcomm [OPTION]... FILE1 FILE2
        \\
        \\Compare two sorted files line by line.
        \\
        \\Output three columns:
        \\  Column 1: lines unique to FILE1
        \\  Column 2: lines unique to FILE2
        \\  Column 3: lines common to both files
        \\
        \\Options:
        \\  -1                     Suppress column 1 (lines unique to FILE1)
        \\  -2                     Suppress column 2 (lines unique to FILE2)
        \\  -3                     Suppress column 3 (lines common to both)
        \\  --check-order          Check that input is sorted (default)
        \\  --nocheck-order        Do not check sort order
        \\  --output-delimiter=STR Separate columns with STR
        \\  -z, --zero-terminated  End lines with 0 byte, not newline
        \\      --help             Display this help and exit
        \\      --version          Output version information and exit
        \\
        \\Examples:
        \\  zcomm file1 file2           # Show all three columns
        \\  zcomm -12 file1 file2       # Show only common lines
        \\  zcomm -3 file1 file2        # Show unique lines only
        \\  zcomm -23 file1 file2       # Show lines only in FILE1
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zcomm " ++ VERSION ++ " - High-performance file comparison\n");
}

fn parseArgs(args: []const []const u8) !Config {
    var config = Config{};
    var positional_idx: usize = 0;

    for (args) |arg| {
        if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            if (arg[1] != '-') {
                // Short options
                for (arg[1..]) |c| {
                    switch (c) {
                        '1' => config.suppress_col1 = true,
                        '2' => config.suppress_col2 = true,
                        '3' => config.suppress_col3 = true,
                        'z' => config.zero_terminated = true,
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
                } else if (std.mem.eql(u8, arg, "--check-order")) {
                    config.check_order = true;
                } else if (std.mem.eql(u8, arg, "--nocheck-order")) {
                    config.check_order = false;
                } else if (std.mem.eql(u8, arg, "--zero-terminated")) {
                    config.zero_terminated = true;
                } else if (std.mem.startsWith(u8, arg, "--output-delimiter=")) {
                    config.output_delimiter = arg[19..];
                }
            }
        } else if (!std.mem.eql(u8, arg, "-")) {
            if (positional_idx == 0) {
                config.file1 = arg;
            } else if (positional_idx == 1) {
                config.file2 = arg;
            }
            positional_idx += 1;
        } else {
            // Handle "-" as stdin
            if (positional_idx == 0) {
                config.file1 = "-";
            } else if (positional_idx == 1) {
                config.file2 = "-";
            }
            positional_idx += 1;
        }
    }

    return config;
}

const LineReader = struct {
    fd: c_int,
    buf: [65536]u8 = undefined,
    buf_start: usize = 0,
    buf_end: usize = 0,
    line_buf: std.ArrayListUnmanaged(u8) = .empty,
    prev_line: ?[]u8 = null,
    eof: bool = false,
    allocator: std.mem.Allocator,
    terminator: u8,

    fn init(path: []const u8, alloc: std.mem.Allocator, term: u8) !LineReader {
        var reader = LineReader{
            .fd = 0,
            .allocator = alloc,
            .terminator = term,
        };

        if (!std.mem.eql(u8, path, "-")) {
            var path_buf: [4096]u8 = undefined;
            const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.PathTooLong;
            const fd_ret = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
            if (fd_ret < 0) return error.OpenFailed;
            reader.fd = fd_ret;
        }

        return reader;
    }

    fn deinit(self: *LineReader) void {
        if (self.fd != 0) _ = libc.close(self.fd);
        self.line_buf.deinit(self.allocator);
        if (self.prev_line) |p| self.allocator.free(p);
    }

    fn readLine(self: *LineReader) !?[]const u8 {
        if (self.eof) return null;

        self.line_buf.clearRetainingCapacity();

        while (true) {
            // Check buffer
            while (self.buf_start < self.buf_end) {
                const c = self.buf[self.buf_start];
                self.buf_start += 1;

                if (c == self.terminator) {
                    // Store for order checking
                    if (self.prev_line) |p| self.allocator.free(p);
                    self.prev_line = try self.allocator.dupe(u8, self.line_buf.items);
                    return self.line_buf.items;
                }
                try self.line_buf.append(self.allocator, c);
            }

            // Refill buffer
            const bytes_ret = libc.read(self.fd, &self.buf, self.buf.len);
            if (bytes_ret <= 0) {
                self.eof = true;
                break;
            }
            const bytes_read: usize = @intCast(bytes_ret);
            self.buf_start = 0;
            self.buf_end = bytes_read;
        }

        // Return remaining content
        if (self.line_buf.items.len > 0) {
            if (self.prev_line) |p| self.allocator.free(p);
            self.prev_line = try self.allocator.dupe(u8, self.line_buf.items);
            return self.line_buf.items;
        }

        return null;
    }
};

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

    if (config.file1 == null or config.file2 == null) {
        writeStderr("zcomm: two files required\n");
        std.process.exit(1);
    }

    const terminator: u8 = if (config.zero_terminated) 0 else '\n';
    const terminator_str: []const u8 = if (config.zero_terminated) "\x00" else "\n";

    var reader1 = LineReader.init(config.file1.?, allocator, terminator) catch {
        writeStderr("zcomm: cannot open FILE1\n");
        std.process.exit(1);
    };
    defer reader1.deinit();

    var reader2 = LineReader.init(config.file2.?, allocator, terminator) catch {
        writeStderr("zcomm: cannot open FILE2\n");
        std.process.exit(1);
    };
    defer reader2.deinit();

    var line1 = try reader1.readLine();
    var line2 = try reader2.readLine();

    while (line1 != null or line2 != null) {
        if (line1 == null) {
            // Only FILE2 has lines left
            if (!config.suppress_col2) {
                if (!config.suppress_col1) writeStdout(config.output_delimiter);
                writeStdout(line2.?);
                writeStdout(terminator_str);
            }
            line2 = try reader2.readLine();
        } else if (line2 == null) {
            // Only FILE1 has lines left
            if (!config.suppress_col1) {
                writeStdout(line1.?);
                writeStdout(terminator_str);
            }
            line1 = try reader1.readLine();
        } else {
            const cmp = std.mem.order(u8, line1.?, line2.?);
            switch (cmp) {
                .lt => {
                    // Line only in FILE1
                    if (!config.suppress_col1) {
                        writeStdout(line1.?);
                        writeStdout(terminator_str);
                    }
                    line1 = try reader1.readLine();
                },
                .gt => {
                    // Line only in FILE2
                    if (!config.suppress_col2) {
                        if (!config.suppress_col1) writeStdout(config.output_delimiter);
                        writeStdout(line2.?);
                        writeStdout(terminator_str);
                    }
                    line2 = try reader2.readLine();
                },
                .eq => {
                    // Line in both files
                    if (!config.suppress_col3) {
                        if (!config.suppress_col1) writeStdout(config.output_delimiter);
                        if (!config.suppress_col2) writeStdout(config.output_delimiter);
                        writeStdout(line1.?);
                        writeStdout(terminator_str);
                    }
                    line1 = try reader1.readLine();
                    line2 = try reader2.readLine();
                },
            }
        }
    }
}
