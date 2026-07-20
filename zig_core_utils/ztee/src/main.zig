//! ztee - Read from standard input and write to standard output and files
//!
//! A high-performance Zig implementation of the GNU tee utility.
//! Copies standard input to each FILE, and also to standard output.
//!
//! Usage: ztee [OPTION]... [FILE]...

const std = @import("std");

const VERSION = "1.0.0";
const BUFFER_SIZE = 65536;

// C functions for file operations. Reads go through std.posix.read so that
// EINTR is retried and real I/O errors are surfaced (not mistaken for EOF).
extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

/// A stream writer that persists across print() calls.
///
/// The original implementation rebuilt a fresh File.Writer on every print(),
/// which in positional mode always started at offset 0 — so consecutive
/// diagnostics to a *redirected* (seekable) stream overwrote each other and
/// only the last line survived. Building the File.Writer once and reusing it
/// lets the tracked position accumulate, so every line lands in order.
const StreamWriter = struct {
    fw: std.Io.File.Writer,

    fn init(file: std.Io.File, buffer: []u8) StreamWriter {
        const io_instance = std.Io.Threaded.global_single_threaded.io();
        return .{ .fw = file.writer(io_instance, buffer) };
    }

    pub fn print(self: *StreamWriter, comptime fmt: []const u8, args: anytype) void {
        self.fw.interface.print(fmt, args) catch {};
        self.fw.interface.flush() catch {};
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

    var out_buf: [8192]u8 = undefined;
    var err_buf: [8192]u8 = undefined;
    var out = StreamWriter.init(std.Io.File.stdout(), &out_buf);
    var err = StreamWriter.init(std.Io.File.stderr(), &err_buf);

    // Parse options
    var append_mode = false;
    var ignore_sigint = false;
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            // GNU tee writes --help/--version to stdout, not stderr, so that
            // `tee --help | pager` works.
            printHelp(&out);
            return;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            out.print("ztee {s}\n", .{VERSION});
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
        } else if (arg.len > 1 and arg[0] == '-') {
            // A cluster of short options. The lone "-" has length 1 and falls
            // through to the else branch, where it is treated as a filename
            // (GNU tee treats "-" as a literal file, not stdout).
            for (arg[1..]) |c| {
                switch (c) {
                    'a' => append_mode = true,
                    'i' => ignore_sigint = true,
                    'p' => {},
                    else => {
                        // GNU reports the single offending character.
                        err.print("ztee: invalid option -- '{c}'\n", .{c});
                        err.print("Try 'ztee --help' for more information.\n", .{});
                        std.process.exit(1);
                    },
                }
            }
        } else {
            try files.append(allocator, arg);
        }
    }

    // -i / --ignore-interrupts: install SIG_IGN for SIGINT like GNU tee does,
    // so a Ctrl-C during a long copy does not kill ztee mid-stream.
    if (ignore_sigint) {
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.INT, &act, null);
    }

    // Open output files. Note: GNU tee treats a filename "-" literally (it
    // creates a file named "-") — it does NOT copy again to standard output —
    // so we do the same for parity. (Verified against GNU coreutils 9.10.)
    var output_fds: std.ArrayListUnmanaged(c_int) = .empty;
    defer {
        for (output_fds.items) |fd| {
            _ = close(fd);
        }
        output_fds.deinit(allocator);
    }
    // Parallel to output_fds: the display name for write-error diagnostics.
    var output_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer output_names.deinit(allocator);

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

        // Build open flags via std.posix.O so the bit values are correct on
        // every platform. Hardcoding Linux values (the previous bug) made -a
        // truncate and default mode fail to truncate on macOS — silent data
        // loss/corruption, since O_TRUNC/O_CREAT/O_APPEND differ on Darwin.
        var oflags: std.posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true };
        if (append_mode) {
            oflags.APPEND = true;
        } else {
            oflags.TRUNC = true;
        }

        const fd = std.posix.openatZ(std.posix.AT.FDCWD, @ptrCast(&path_buf), oflags, 0o644) catch {
            err.print("ztee: {s}: Cannot open file\n", .{path});
            had_error = true;
            continue;
        };

        try output_fds.append(allocator, fd);
        try output_names.append(allocator, path);
    }

    // Read from stdin (fd 0) and write to stdout (fd 1) + all files.
    var buffer: [BUFFER_SIZE]u8 = undefined;

    while (true) {
        const bytes_read = std.posix.read(0, &buffer) catch |e| {
            // A real read error must NOT be reported as a clean EOF/success.
            err.print("ztee: read error: {s}\n", .{@errorName(e)});
            had_error = true;
            break;
        };

        if (bytes_read == 0) break; // true EOF

        const data = buffer[0..bytes_read];

        // Write to stdout
        if (!writeAll(1, data)) had_error = true;

        // Write to all output files (and any "-" stdout duplicates)
        for (output_fds.items, 0..) |fd, idx| {
            if (!writeAll(fd, data)) {
                err.print("ztee: {s}: Write error\n", .{output_names.items[idx]});
                had_error = true;
            }
        }
    }

    if (had_error) {
        std.process.exit(1);
    }
}

/// Write the whole slice, looping over short writes. Returns false on error.
fn writeAll(fd: c_int, data: []const u8) bool {
    var written: usize = 0;
    while (written < data.len) {
        const result = write(fd, data.ptr + written, data.len - written);
        if (result <= 0) return false;
        written += @intCast(result);
    }
    return true;
}

fn printHelp(writer: *StreamWriter) void {
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
        \\Examples:
        \\  ztee file.txt              Write stdin to stdout and file.txt
        \\  ztee -a log.txt            Append stdin to log.txt
        \\  ls | ztee files.txt        Save ls output to file while displaying it
        \\  cmd | ztee f1 f2 f3        Write to multiple files simultaneously
        \\
    , .{});
}
