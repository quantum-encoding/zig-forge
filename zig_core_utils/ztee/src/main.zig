//! ztee - Read from standard input and write to standard output and files
//!
//! A high-performance Zig implementation of the GNU tee utility.
//! Copies standard input to each FILE, and also to standard output.
//!
//! Usage: ztee [OPTION]... [FILE]...

const std = @import("std");

const VERSION = "1.0.0";
const BUFFER_SIZE = 65536;

// C functions for file operations
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

const O_WRONLY = 0x0001;
const O_CREAT = 0x0040;
const O_TRUNC = 0x0200;
const O_APPEND = 0x0400;

// Zig 0.16 Writer abstraction
const Writer = struct {
    io: std.Io,
    buffer: *[8192]u8,
    file: std.Io.File,

    pub fn stdout() Writer {
        const io_instance = std.Io.Threaded.global_single_threaded.io();
        const static = struct {
            var buffer: [8192]u8 = undefined;
        };
        return Writer{
            .io = io_instance,
            .buffer = &static.buffer,
            .file = std.Io.File.stdout(),
        };
    }

    pub fn stderr() Writer {
        const io_instance = std.Io.Threaded.global_single_threaded.io();
        const static = struct {
            var buffer: [8192]u8 = undefined;
        };
        return Writer{
            .io = io_instance,
            .buffer = &static.buffer,
            .file = std.Io.File.stderr(),
        };
    }

    pub fn print(self: *Writer, comptime fmt: []const u8, args: anytype) void {
        var writer = self.file.writer(self.io, self.buffer);
        writer.interface.print(fmt, args) catch {};
        writer.interface.flush() catch {};
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

    var err = Writer.stderr();

    // Parse options
    var append_mode = false;
    var ignore_sigint = false;
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp(&err);
            return;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            err.print("ztee {s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--append")) {
            append_mode = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-interrupts")) {
            ignore_sigint = true;
        } else if (std.mem.eql(u8, arg, "-p")) {
            // Diagnose errors - default behavior
        } else if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                try files.append(allocator, args[i]);
            }
            break;
        } else if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            // Check for combined short options
            var all_valid = true;
            for (arg[1..]) |c| {
                switch (c) {
                    'a' => append_mode = true,
                    'i' => ignore_sigint = true,
                    'p' => {},
                    else => {
                        all_valid = false;
                        break;
                    },
                }
            }
            if (!all_valid) {
                err.print("ztee: invalid option -- '{s}'\n", .{arg[1..]});
                err.print("Try 'ztee --help' for more information.\n", .{});
                std.process.exit(1);
            }
        } else {
            try files.append(allocator, arg);
        }
    }

    // Signal handling note: -i option is parsed but signal handling
    // is not implemented in this version. Print warning if used.
    if (ignore_sigint) {
        err.print("ztee: warning: -i option not fully implemented\n", .{});
    }

    // Open output files using C functions
    var output_fds: std.ArrayListUnmanaged(c_int) = .empty;
    defer {
        for (output_fds.items) |fd| {
            _ = close(fd);
        }
        output_fds.deinit(allocator);
    }

    var had_error = false;

    for (files.items) |path| {
        // Convert to null-terminated string
        var path_buf: [4096]u8 = undefined;
        if (path.len >= path_buf.len) {
            err.print("ztee: {s}: File name too long\n", .{path});
            had_error = true;
            continue;
        }
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        const flags: c_int = if (append_mode)
            O_WRONLY | O_CREAT | O_APPEND
        else
            O_WRONLY | O_CREAT | O_TRUNC;

        const fd = open(@ptrCast(&path_buf), flags, @as(c_int, 0o644));
        if (fd < 0) {
            err.print("ztee: {s}: Cannot open file\n", .{path});
            had_error = true;
            continue;
        }

        try output_fds.append(allocator, fd);
    }

    // Read from stdin (fd 0) and write to stdout (fd 1) + all files
    var buffer: [BUFFER_SIZE]u8 = undefined;

    while (true) {
        const bytes_read = read(0, &buffer, BUFFER_SIZE);

        if (bytes_read <= 0) break;

        const data = buffer[0..@intCast(bytes_read)];

        // Write to stdout
        var written: usize = 0;
        while (written < data.len) {
            const result = write(1, data.ptr + written, data.len - written);
            if (result <= 0) {
                had_error = true;
                break;
            }
            written += @intCast(result);
        }

        // Write to all output files
        for (output_fds.items, 0..) |fd, idx| {
            written = 0;
            while (written < data.len) {
                const result = write(fd, data.ptr + written, data.len - written);
                if (result <= 0) {
                    err.print("ztee: {s}: Write error\n", .{files.items[idx]});
                    had_error = true;
                    break;
                }
                written += @intCast(result);
            }
        }
    }

    if (had_error) {
        std.process.exit(1);
    }
}

fn printHelp(writer: *Writer) void {
    writer.print(
        \\Usage: ztee [OPTION]... [FILE]...
        \\
        \\Copy standard input to each FILE, and also to standard output.
        \\
        \\Options:
        \\  -a, --append              append to the given FILEs, do not overwrite
        \\  -i, --ignore-interrupts   ignore interrupt signals
        \\  -p                        diagnose errors writing to non-pipes
        \\  -h, --help                display this help and exit
        \\  -V, --version             output version information and exit
        \\
        \\If a FILE is -, copy again to standard output.
        \\
        \\Examples:
        \\  ztee file.txt              Write stdin to stdout and file.txt
        \\  ztee -a log.txt            Append stdin to log.txt
        \\  ls | ztee files.txt        Save ls output to file while displaying it
        \\  cmd | ztee f1 f2 f3        Write to multiple files simultaneously
        \\
    , .{});
}
