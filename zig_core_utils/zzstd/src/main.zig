//! zzstd - Compress or decompress files using Zstandard format
//!
//! A Zig implementation of zstd decompression utility.
//! Supports Zstandard decompression.
//!
//! Usage: zzstd [OPTION]... [FILE]...

const std = @import("std");

const VERSION = "1.0.0";
const BUFFER_SIZE = 65536;

// Zstd magic number
const ZSTD_MAGIC: u32 = 0xFD2FB528;

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
        if (std.mem.indexOf(u8, prog_name, "unzstd") != null or
            std.mem.indexOf(u8, prog_name, "zstdcat") != null)
        {
            decompress = true;
        }
    }

    // Parse options
    var to_stdout = false;
    var keep = false;
    var verbose = false;
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            StderrWriter.print("zzstd {s}\n", .{VERSION});
            return;
        } else if (std.mem.eql(u8, arg, "--stdout") or std.mem.eql(u8, arg, "--to-stdout")) {
            to_stdout = true;
        } else if (std.mem.eql(u8, arg, "--decompress") or std.mem.eql(u8, arg, "--uncompress")) {
            decompress = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            // Force mode accepted
        } else if (std.mem.eql(u8, arg, "--keep")) {
            keep = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--fast") or std.mem.eql(u8, arg, "--best") or std.mem.eql(u8, arg, "--ultra")) {
            // Accepted but not used
        } else if (arg.len > 0 and arg[0] == '-' and arg.len > 1 and arg[1] != '-') {
            // Handle combined short options like -dc, -dkv
            for (arg[1..]) |ch| {
                switch (ch) {
                    'h' => {
                        printHelp();
                        return;
                    },
                    'V' => {
                        StderrWriter.print("zzstd {s}\n", .{VERSION});
                        return;
                    },
                    'c' => to_stdout = true,
                    'd' => decompress = true,
                    'f' => {}, // Force mode accepted
                    'k' => keep = true,
                    'v' => verbose = true,
                    '1', '2', '3', '4', '5', '6', '7', '8', '9' => {}, // Compression level accepted
                    else => {
                        StderrWriter.print("zzstd: invalid option -- '{c}'\n", .{ch});
                        std.process.exit(1);
                    },
                }
            }
        } else if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            StderrWriter.print("zzstd: invalid option -- '{s}'\n", .{arg[1..]});
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
            StderrWriter.print("zzstd: compression requires external zstd tool (decompression supported)\n", .{});
            std.process.exit(1);
        }
        return;
    }

    // Process files
    for (files.items) |path| {
        if (decompress) {
            decompressFile(allocator, path, to_stdout, keep, verbose);
        } else {
            StderrWriter.print("zzstd: compression not yet implemented, use: zstd {s}\n", .{path});
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

fn decompressStdin(allocator: std.mem.Allocator) void {
    const input_data = readFileData(allocator, 0) orelse {
        StderrWriter.print("zzstd: memory allocation error\n", .{});
        return;
    };
    defer allocator.free(input_data);

    decompressToFd(allocator, input_data, 1);
}

fn decompressFile(allocator: std.mem.Allocator, path: []const u8, to_stdout: bool, keep: bool, verbose: bool) void {
    if (!std.mem.endsWith(u8, path, ".zst") and !std.mem.endsWith(u8, path, ".zstd")) {
        StderrWriter.print("zzstd: {s}: unknown suffix -- ignored\n", .{path});
        return;
    }

    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) {
        StderrWriter.print("zzstd: {s}: file name too long\n", .{path});
        return;
    }
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const in_fd = open(@ptrCast(&path_buf), O_RDONLY);
    if (in_fd < 0) {
        StderrWriter.print("zzstd: {s}: No such file or directory\n", .{path});
        return;
    }

    const input_data = readFileData(allocator, in_fd) orelse {
        StderrWriter.print("zzstd: memory allocation error\n", .{});
        _ = close(in_fd);
        return;
    };
    defer allocator.free(input_data);
    _ = close(in_fd);

    var out_fd: c_int = 1;
    var out_path_buf: [4096]u8 = undefined;
    var close_out = false;
    var out_name: []const u8 = "";

    if (!to_stdout) {
        const suffix_len: usize = if (std.mem.endsWith(u8, path, ".zst")) 4 else 5;
        const out_len = path.len - suffix_len;
        @memcpy(out_path_buf[0..out_len], path[0..out_len]);
        out_path_buf[out_len] = 0;
        out_name = path[0..out_len];

        out_fd = open(@ptrCast(&out_path_buf), O_WRONLY | O_CREAT | O_TRUNC, @as(c_int, 0o644));
        if (out_fd < 0) {
            StderrWriter.print("zzstd: Cannot create output file\n", .{});
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
        StderrWriter.print("{s}: -- replaced with {s}\n", .{ path, out_name });
    }
}

fn decompressToFd(allocator: std.mem.Allocator, data: []const u8, out_fd: c_int) void {
    if (data.len < 4) {
        StderrWriter.print("zzstd: invalid zstd data (too short)\n", .{});
        return;
    }

    // Check for Zstd magic
    const magic = @as(u32, data[0]) |
        (@as(u32, data[1]) << 8) |
        (@as(u32, data[2]) << 16) |
        (@as(u32, data[3]) << 24);

    if (magic != ZSTD_MAGIC) {
        StderrWriter.print("zzstd: not in zstd format\n", .{});
        return;
    }

    // Use std.Io.Writer.Allocating for output
    var out: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, 4096) catch {
        StderrWriter.print("zzstd: memory allocation error\n", .{});
        return;
    };
    defer out.deinit();

    // Create fixed reader from input data
    var input: std.Io.Reader = .fixed(data);

    // Initialize Zstd decompressor
    var zstd_stream: std.compress.zstd.Decompress = .init(&input, &.{}, .{});

    // Stream all decompressed data to output
    _ = zstd_stream.reader.streamRemaining(&out.writer) catch |err| {
        StderrWriter.print("zzstd: decompression error: {s}\n", .{@errorName(err)});
        return;
    };

    // Get decompressed data
    const decompressed = out.toOwnedSlice() catch {
        StderrWriter.print("zzstd: memory error\n", .{});
        return;
    };
    defer allocator.free(decompressed);

    // Write to output fd
    _ = write(out_fd, decompressed.ptr, decompressed.len);
}

fn printHelp() void {
    StderrWriter.print(
        \\Usage: zzstd [OPTION]... [FILE]...
        \\
        \\Decompress FILEs in the .zst format.
        \\
        \\Options:
        \\  -c, --stdout       write to stdout, keep original files
        \\  -d, --decompress   decompress (default for unzstd/zstdcat)
        \\  -f, --force        force overwrite
        \\  -k, --keep         keep original files
        \\  -v, --verbose      verbose output
        \\  -h, --help         display this help
        \\  -V, --version      display version
        \\
        \\Note: Compression requires external zstd tool.
        \\      Decompression of .zst files is supported.
        \\
        \\Examples:
        \\  zzstd -d file.zst        Decompress to file
        \\  zzstd -dc file.zst       Decompress to stdout
        \\  zzstd -k -d file.zst     Decompress, keep original
        \\
    , .{});
}
