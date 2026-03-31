//! zgzip/zgunzip - Compress or decompress files using gzip format
//!
//! A high-performance Zig implementation of gzip/gunzip.
//! Uses DEFLATE compression algorithm with gzip container format.
//!
//! Usage: zgzip [OPTION]... [FILE]...
//!        zgunzip [OPTION]... [FILE]...

const std = @import("std");
const flate = std.compress.flate;

const VERSION = "1.0.0";
const BUFFER_SIZE = 65536;

// Gzip magic bytes
const GZIP_MAGIC: [2]u8 = .{ 0x1f, 0x8b };

// C functions for file I/O
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
const c_read = @extern(*const fn (c_int, [*]u8, usize) callconv(.c) isize, .{ .name = "read" });
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn unlink(path: [*:0]const u8) c_int;

const O_RDONLY = 0;
const O_WRONLY = 0x0001;
const O_CREAT = 0x0040;
const O_TRUNC = 0x0200;

// Simple stderr writer for error messages
const StderrWriter = struct {
    pub fn print(comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        _ = write(2, msg.ptr, msg.len);
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

    // Determine mode from program name
    var decompress = false;
    if (args.len > 0) {
        const prog_name = std.fs.path.basename(args[0]);
        if (std.mem.indexOf(u8, prog_name, "gunzip") != null or
            std.mem.indexOf(u8, prog_name, "zcat") != null)
        {
            decompress = true;
        }
    }

    // Parse options
    var to_stdout = false;
    var keep = false;
    var verbose = false;
    var level: u4 = 6;
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            printHelp(decompress);
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            StderrWriter.print("zgzip {s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "--stdout") or std.mem.eql(u8, arg, "--to-stdout")) {
            to_stdout = true;
        } else if (std.mem.eql(u8, arg, "--decompress") or std.mem.eql(u8, arg, "--uncompress")) {
            decompress = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            // Force mode (accepted)
        } else if (std.mem.eql(u8, arg, "--keep")) {
            keep = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--fast")) {
            level = 1;
        } else if (std.mem.eql(u8, arg, "--best")) {
            level = 9;
        } else if (arg.len > 0 and arg[0] == '-' and arg.len > 1 and arg[1] != '-') {
            // Handle combined short options like -dc, -dkv, -9kv
            for (arg[1..]) |ch| {
                switch (ch) {
                    'h' => {
                        printHelp(decompress);
                        return;
                    },
                    'V' => {
                        StderrWriter.print("zgzip {s}\n", .{VERSION});
                        return;
                    },
                    'c' => to_stdout = true,
                    'd' => decompress = true,
                    'f' => {}, // Force mode accepted
                    'k' => keep = true,
                    'v' => verbose = true,
                    '1' => level = 1,
                    '2' => level = 2,
                    '3' => level = 3,
                    '4' => level = 4,
                    '5' => level = 5,
                    '6' => level = 6,
                    '7' => level = 7,
                    '8' => level = 8,
                    '9' => level = 9,
                    else => {
                        StderrWriter.print("zgzip: invalid option -- '{c}'\n", .{ch});
                        std.process.exit(1);
                    },
                }
            }
        } else if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            StderrWriter.print("zgzip: invalid option -- '{s}'\n", .{arg[1..]});
            std.process.exit(1);
        } else {
            try files.append(allocator, arg);
        }
    }

    // If no files, use stdin/stdout
    if (files.items.len == 0) {
        if (decompress) {
            decompressStdin(allocator);
        } else {
            compressStdin(allocator, level);
        }
        return;
    }

    // Process files
    for (files.items) |path| {
        if (decompress) {
            decompressFile(allocator, path, to_stdout, keep, verbose);
        } else {
            compressFile(allocator, path, level, to_stdout, keep, verbose);
        }
    }
}

fn readFileData(allocator: std.mem.Allocator, fd: c_int) ?[]u8 {
    var data: std.ArrayListUnmanaged(u8) = .empty;
    var buffer: [BUFFER_SIZE]u8 = undefined;

    while (true) {
        const bytes = c_read(fd, &buffer, BUFFER_SIZE);
        if (bytes <= 0) break;
        data.appendSlice(allocator, buffer[0..@intCast(bytes)]) catch {
            data.deinit(allocator);
            return null;
        };
    }

    return data.toOwnedSlice(allocator) catch {
        data.deinit(allocator);
        return null;
    };
}

fn compressStdin(allocator: std.mem.Allocator, level: u4) void {
    const input_data = readFileData(allocator, 0) orelse {
        StderrWriter.print("zgzip: memory allocation error\n", .{});
        return;
    };
    defer allocator.free(input_data);

    _ = compressToFd(allocator, input_data, 1, level);
}

fn decompressStdin(allocator: std.mem.Allocator) void {
    const input_data = readFileData(allocator, 0) orelse {
        StderrWriter.print("zgzip: memory allocation error\n", .{});
        return;
    };
    defer allocator.free(input_data);

    decompressToFd(allocator, input_data, 1);
}

fn compressFile(allocator: std.mem.Allocator, path: []const u8, level: u4, to_stdout: bool, keep: bool, verbose: bool) void {
    if (std.mem.endsWith(u8, path, ".gz")) {
        StderrWriter.print("zgzip: {s}: already has .gz suffix -- unchanged\n", .{path});
        return;
    }

    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) {
        StderrWriter.print("zgzip: {s}: file name too long\n", .{path});
        return;
    }
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const in_fd = open(@ptrCast(&path_buf), O_RDONLY);
    if (in_fd < 0) {
        StderrWriter.print("zgzip: {s}: No such file or directory\n", .{path});
        return;
    }

    const input_data = readFileData(allocator, in_fd) orelse {
        StderrWriter.print("zgzip: memory allocation error\n", .{});
        _ = close(in_fd);
        return;
    };
    defer allocator.free(input_data);
    _ = close(in_fd);

    const original_size = input_data.len;

    var out_fd: c_int = 1;
    var out_path_buf: [4100]u8 = undefined;
    var close_out = false;

    if (!to_stdout) {
        const out_len = path.len + 3;
        if (out_len >= out_path_buf.len) {
            StderrWriter.print("zgzip: {s}: file name too long\n", .{path});
            return;
        }
        @memcpy(out_path_buf[0..path.len], path);
        @memcpy(out_path_buf[path.len .. path.len + 3], ".gz");
        out_path_buf[out_len] = 0;

        out_fd = open(@ptrCast(&out_path_buf), O_WRONLY | O_CREAT | O_TRUNC, @as(c_int, 0o644));
        if (out_fd < 0) {
            StderrWriter.print("zgzip: {s}.gz: Cannot create file\n", .{path});
            return;
        }
        close_out = true;
    }

    const compressed_size = compressToFd(allocator, input_data, out_fd, level);

    if (close_out) {
        _ = close(out_fd);
    }

    if (!to_stdout and !keep) {
        _ = unlink(@ptrCast(&path_buf));
    }

    if (verbose and !to_stdout) {
        const ratio: f64 = if (original_size > 0)
            100.0 * (1.0 - @as(f64, @floatFromInt(compressed_size)) / @as(f64, @floatFromInt(original_size)))
        else
            0.0;
        StderrWriter.print("{s}:\t{d:.1}% -- replaced with {s}.gz\n", .{ path, ratio, path });
    }
}

fn decompressFile(allocator: std.mem.Allocator, path: []const u8, to_stdout: bool, keep: bool, verbose: bool) void {
    if (!std.mem.endsWith(u8, path, ".gz")) {
        StderrWriter.print("zgzip: {s}: unknown suffix -- ignored\n", .{path});
        return;
    }

    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) {
        StderrWriter.print("zgzip: {s}: file name too long\n", .{path});
        return;
    }
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const in_fd = open(@ptrCast(&path_buf), O_RDONLY);
    if (in_fd < 0) {
        StderrWriter.print("zgzip: {s}: No such file or directory\n", .{path});
        return;
    }

    const input_data = readFileData(allocator, in_fd) orelse {
        StderrWriter.print("zgzip: memory allocation error\n", .{});
        _ = close(in_fd);
        return;
    };
    defer allocator.free(input_data);
    _ = close(in_fd);

    var out_fd: c_int = 1;
    var out_path_buf: [4096]u8 = undefined;
    var close_out = false;

    if (!to_stdout) {
        const out_len = path.len - 3;
        @memcpy(out_path_buf[0..out_len], path[0..out_len]);
        out_path_buf[out_len] = 0;

        out_fd = open(@ptrCast(&out_path_buf), O_WRONLY | O_CREAT | O_TRUNC, @as(c_int, 0o644));
        if (out_fd < 0) {
            StderrWriter.print("zgzip: {s}: Cannot create output file\n", .{path[0 .. path.len - 3]});
            return;
        }
        close_out = true;
    }

    decompressToFd(allocator, input_data, out_fd);

    if (close_out) {
        _ = close(out_fd);
    }

    if (!to_stdout and !keep) {
        _ = unlink(@ptrCast(&path_buf));
    }

    if (verbose and !to_stdout) {
        StderrWriter.print("{s}:\t -- replaced with {s}\n", .{ path, path[0 .. path.len - 3] });
    }
}

fn compressToFd(allocator: std.mem.Allocator, data: []const u8, out_fd: c_int, level: u4) usize {
    // Use std.Io.Writer.Allocating for output - need at least 8 bytes for flate
    var out: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, 4096) catch {
        StderrWriter.print("zgzip: memory allocation error\n", .{});
        return 0;
    };
    defer out.deinit();

    // Create compression buffer (must be at least flate.max_window_len)
    var comp_buffer: [flate.max_window_len]u8 = undefined;

    // Map level 1-9 to flate options
    const opts: flate.Compress.Options = switch (level) {
        1 => flate.Compress.Options.level_1,
        2 => flate.Compress.Options.level_2,
        3 => flate.Compress.Options.level_3,
        4 => flate.Compress.Options.level_4,
        5 => flate.Compress.Options.level_5,
        6 => flate.Compress.Options.level_6,
        7 => flate.Compress.Options.level_7,
        8 => flate.Compress.Options.level_8,
        9 => flate.Compress.Options.level_9,
        else => flate.Compress.Options.default,
    };

    // Initialize compressor with gzip container
    var comp = flate.Compress.init(&out.writer, &comp_buffer, .gzip, opts) catch {
        StderrWriter.print("zgzip: compression init error\n", .{});
        return 0;
    };

    // Write input data through compressor
    comp.writer.writeAll(data) catch {
        StderrWriter.print("zgzip: compression error\n", .{});
        return 0;
    };

    // Finalize compression
    comp.writer.flush() catch {
        StderrWriter.print("zgzip: compression finalize error\n", .{});
        return 0;
    };

    // Write compressed data to output fd
    const compressed = out.toOwnedSlice() catch {
        StderrWriter.print("zgzip: memory error\n", .{});
        return 0;
    };
    defer allocator.free(compressed);

    _ = write(out_fd, compressed.ptr, compressed.len);
    return compressed.len;
}

fn decompressToFd(allocator: std.mem.Allocator, data: []const u8, out_fd: c_int) void {
    if (data.len < 18) {
        StderrWriter.print("zgzip: invalid gzip data (too short)\n", .{});
        return;
    }

    // Verify gzip magic
    if (data[0] != GZIP_MAGIC[0] or data[1] != GZIP_MAGIC[1]) {
        StderrWriter.print("zgzip: not in gzip format\n", .{});
        return;
    }

    // Use std.Io.Writer.Allocating for output
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    // Create fixed reader from input data
    var input: std.Io.Reader = .fixed(data);

    // Create decompression buffer
    var decomp_buffer: [flate.max_window_len]u8 = undefined;

    // Initialize decompressor with gzip container
    var decomp = flate.Decompress.init(&input, .gzip, &decomp_buffer);

    // Stream all decompressed data to output
    _ = decomp.reader.streamRemaining(&out.writer) catch |err| {
        StderrWriter.print("zgzip: decompression error: {s}\n", .{@errorName(err)});
        return;
    };

    // Get decompressed data
    const decompressed = out.toOwnedSlice() catch {
        StderrWriter.print("zgzip: memory error\n", .{});
        return;
    };
    defer allocator.free(decompressed);

    // Write to output fd
    _ = write(out_fd, decompressed.ptr, decompressed.len);
}

fn printHelp(decompress: bool) void {
    if (decompress) {
        StderrWriter.print(
            \\Usage: zgunzip [OPTION]... [FILE]...
            \\
            \\Decompress FILEs (by default, in place).
            \\
            \\Options:
            \\  -c, --stdout       write to stdout, keep original files
            \\  -f, --force        force overwrite
            \\  -k, --keep         keep original files
            \\  -v, --verbose      verbose output
            \\  -h, --help         display this help
            \\  -V, --version      display version
            \\
            \\With no FILE, read from stdin.
            \\
        , .{});
    } else {
        StderrWriter.print(
            \\Usage: zgzip [OPTION]... [FILE]...
            \\
            \\Compress FILEs (by default, in place).
            \\
            \\Options:
            \\  -c, --stdout       write to stdout, keep original files
            \\  -d, --decompress   decompress
            \\  -f, --force        force overwrite
            \\  -k, --keep         keep original files
            \\  -1..-9             compression level (1=fast, 9=best, default=6)
            \\  --fast             alias for -1
            \\  --best             alias for -9
            \\  -v, --verbose      verbose output
            \\  -h, --help         display this help
            \\  -V, --version      display version
            \\
            \\With no FILE, read from stdin.
            \\
            \\Examples:
            \\  zgzip file.txt         Compress to file.txt.gz
            \\  zgzip -k file.txt      Compress, keep original
            \\  zgunzip file.txt.gz    Decompress to file.txt
            \\
        , .{});
    }
}
