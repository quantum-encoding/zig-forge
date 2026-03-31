//! zpaste - High-performance line merging utility
//!
//! Merge lines of files.
//!
//! Usage: zpaste [OPTION]... [FILE]...

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

const Config = struct {
    serial: bool = false,
    delimiters: []const u8 = "\t",
    zero_terminated: bool = false,
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
        \\Usage: zpaste [OPTION]... [FILE]...
        \\
        \\Write lines consisting of the sequentially corresponding lines from
        \\each FILE, separated by TABs, to standard output.
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\Options:
        \\  -d, --delimiters=LIST  Use characters from LIST instead of TABs
        \\                         Cycle through LIST characters between columns
        \\                         Escapes: \n \t \r \b \f \v \\ \0
        \\  -s, --serial           Paste one file at a time instead of in parallel
        \\  -z, --zero-terminated  End lines with 0 byte, not newline
        \\      --help             Display this help and exit
        \\      --version          Output version information and exit
        \\
        \\Examples:
        \\  zpaste file1 file2           # Merge files side by side
        \\  zpaste -d, file1 file2       # Use comma as delimiter
        \\  zpaste -d',;:' f1 f2 f3 f4   # Cycle: comma, semicolon, colon
        \\  zpaste -s file1 file2        # Concatenate lines of each file
        \\  ls | zpaste - -              # Two columns from stdin
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zpaste " ++ VERSION ++ " - High-performance line merging\n");
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
                        's' => config.serial = true,
                        'z' => config.zero_terminated = true,
                        'd' => {
                            if (j + 1 < arg.len) {
                                config.delimiters = arg[j + 1 ..];
                                break;
                            } else if (i + 1 < args.len) {
                                i += 1;
                                config.delimiters = args[i];
                            }
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
                } else if (std.mem.eql(u8, arg, "--serial")) {
                    config.serial = true;
                } else if (std.mem.eql(u8, arg, "--zero-terminated")) {
                    config.zero_terminated = true;
                } else if (std.mem.startsWith(u8, arg, "--delimiters=")) {
                    config.delimiters = arg[13..];
                }
            }
        } else {
            try config.files.append(allocator, arg);
        }
    }

    if (config.files.items.len == 0) {
        try config.files.append(allocator, "-");
    }

    return config;
}

fn expandDelimiters(delims: []const u8, buf: *[256]u8) []const u8 {
    var out_len: usize = 0;
    var i: usize = 0;

    while (i < delims.len and out_len < 256) {
        if (delims[i] == '\\' and i + 1 < delims.len) {
            buf[out_len] = switch (delims[i + 1]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                'b' => 0x08, // backspace
                'f' => 0x0C, // form feed
                'v' => 0x0B, // vertical tab
                '\\' => '\\',
                '0' => 0,
                else => delims[i + 1],
            };
            out_len += 1;
            i += 2;
        } else {
            buf[out_len] = delims[i];
            out_len += 1;
            i += 1;
        }
    }

    return buf[0..out_len];
}

const FileReader = struct {
    fd: c_int,
    buf: [8192]u8 = undefined,
    buf_start: usize = 0,
    buf_end: usize = 0,
    line_buf: std.ArrayListUnmanaged(u8) = .empty,
    eof: bool = false,
    is_stdin: bool,
    allocator: std.mem.Allocator,
    terminator: u8,

    fn init(path: []const u8, alloc: std.mem.Allocator, term: u8) !FileReader {
        var reader = FileReader{
            .fd = 0,
            .is_stdin = std.mem.eql(u8, path, "-"),
            .allocator = alloc,
            .terminator = term,
        };

        if (!reader.is_stdin) {
            var path_buf: [4096]u8 = undefined;
            const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.PathTooLong;
            const fd_ret = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
            if (fd_ret < 0) return error.OpenFailed;
            reader.fd = fd_ret;
        }

        return reader;
    }

    fn deinit(self: *FileReader) void {
        if (!self.is_stdin and self.fd != 0) _ = libc.close(self.fd);
        self.line_buf.deinit(self.allocator);
    }

    fn readLine(self: *FileReader) !?[]const u8 {
        if (self.eof) return null;

        self.line_buf.clearRetainingCapacity();

        while (true) {
            while (self.buf_start < self.buf_end) {
                const c = self.buf[self.buf_start];
                self.buf_start += 1;

                if (c == self.terminator) {
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

        if (self.line_buf.items.len > 0) {
            return self.line_buf.items;
        }

        return null;
    }
};

fn pasteParallel(config: *const Config, allocator: std.mem.Allocator) !void {
    const terminator: u8 = if (config.zero_terminated) 0 else '\n';
    const terminator_str: []const u8 = if (config.zero_terminated) "\x00" else "\n";

    var delim_buf: [256]u8 = undefined;
    const delimiters = expandDelimiters(config.delimiters, &delim_buf);

    // Open all files
    var readers = try allocator.alloc(FileReader, config.files.items.len);
    defer allocator.free(readers);

    for (config.files.items, 0..) |path, idx| {
        readers[idx] = FileReader.init(path, allocator, terminator) catch {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "zpaste: cannot open '{s}'\n", .{path}) catch "zpaste: cannot open file\n";
            writeStderr(err_msg);
            std.process.exit(1);
        };
    }
    defer for (readers) |*r| r.deinit();

    // Read and paste lines
    // Buffer each line to avoid writing trailing delimiters when all files hit EOF
    var line_parts = try allocator.alloc(?[]const u8, config.files.items.len);
    defer allocator.free(line_parts);
    var line_copies = try allocator.alloc([]u8, config.files.items.len);
    defer {
        for (line_copies, line_parts) |copy, part| {
            if (part != null) allocator.free(copy);
        }
        allocator.free(line_copies);
    }

    while (true) {
        var any_data = false;

        // Read from all files first
        for (readers, 0..) |*reader, idx| {
            if (try reader.readLine()) |line| {
                line_copies[idx] = try allocator.dupe(u8, line);
                line_parts[idx] = line_copies[idx];
                any_data = true;
            } else {
                line_parts[idx] = null;
            }
        }

        if (!any_data) break;

        // Write the merged line
        var delim_idx: usize = 0;
        for (line_parts, 0..) |part, idx| {
            if (idx > 0) {
                const d = if (delimiters.len > 0) delimiters[delim_idx % delimiters.len] else '\t';
                writeStdout(&[_]u8{d});
                delim_idx += 1;
            }
            if (part) |line| {
                writeStdout(line);
            }
        }
        writeStdout(terminator_str);

        // Free copies
        for (line_parts, 0..) |part, idx| {
            if (part != null) {
                allocator.free(line_copies[idx]);
                line_parts[idx] = null;
            }
        }
    }
}

fn pasteSerial(config: *const Config, allocator: std.mem.Allocator) !void {
    const terminator: u8 = if (config.zero_terminated) 0 else '\n';
    const terminator_str: []const u8 = if (config.zero_terminated) "\x00" else "\n";

    var delim_buf: [256]u8 = undefined;
    const delimiters = expandDelimiters(config.delimiters, &delim_buf);

    for (config.files.items) |path| {
        var reader = FileReader.init(path, allocator, terminator) catch {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "zpaste: cannot open '{s}'\n", .{path}) catch "zpaste: cannot open file\n";
            writeStderr(err_msg);
            continue;
        };
        defer reader.deinit();

        var first = true;
        var delim_idx: usize = 0;

        while (try reader.readLine()) |line| {
            if (!first) {
                const d = if (delimiters.len > 0) delimiters[delim_idx % delimiters.len] else '\t';
                writeStdout(&[_]u8{d});
                delim_idx += 1;
            }
            writeStdout(line);
            first = false;
        }

        if (!first) {
            writeStdout(terminator_str);
        }
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

    if (config.serial) {
        try pasteSerial(&config, allocator);
    } else {
        try pasteParallel(&config, allocator);
    }
}
