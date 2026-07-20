//! zzstd - Decompress files in the Zstandard format
//!
//! A Zig implementation of the zstd decompression utility.
//! Decompression only: the Zig standard library ships a zstd decompressor
//! (`std.compress.zstd`) but no compressor, so compression requests fail with
//! a clear error and a nonzero exit code (matching GNU's "error → exit 1"
//! contract) rather than silently succeeding.
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
extern "c" fn __error() *c_int;

// Darwin (macOS) fcntl.h open(2) flag values.
const O_RDONLY = 0x0000;
const O_WRONLY = 0x0001;
const O_NOFOLLOW = 0x0100;
const O_CREAT = 0x0200;
const O_TRUNC = 0x0400;
const O_EXCL = 0x0800;
const EEXIST = 17;
const EINTR = 4;

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
    var force_stdout_from_name = false;
    if (args.len > 0) {
        const prog_name = std.fs.path.basename(args[0]);
        if (std.mem.indexOf(u8, prog_name, "zstdcat") != null) {
            // zstdcat implies decompress AND write to stdout (like zcat).
            decompress = true;
            force_stdout_from_name = true;
        } else if (std.mem.indexOf(u8, prog_name, "unzstd") != null) {
            decompress = true;
        }
    }

    // Parse options
    var to_stdout = force_stdout_from_name;
    var keep = false;
    var verbose = false;
    var force = false;
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
            force = true;
        } else if (std.mem.eql(u8, arg, "--keep")) {
            keep = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--fast") or std.mem.eql(u8, arg, "--best") or std.mem.eql(u8, arg, "--ultra")) {
            // Accepted but not used (decompression only).
        } else if (std.mem.eql(u8, arg, "-")) {
            // GNU treats "-" as stdin/stdout.
            try files.append(allocator, arg);
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
                    'f' => force = true,
                    'k' => keep = true,
                    'v' => verbose = true,
                    '1', '2', '3', '4', '5', '6', '7', '8', '9' => {}, // Compression level accepted (decompression only)
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

    var had_error = false;

    // If no files, use stdin/stdout
    if (files.items.len == 0) {
        if (decompress) {
            decompressStdin(allocator) catch {
                had_error = true;
            };
        } else {
            StderrWriter.print("zzstd: compression is not supported (decompression only); use the system zstd to compress\n", .{});
            had_error = true;
        }
        if (had_error) std.process.exit(1);
        return;
    }

    // Process files
    for (files.items) |path| {
        if (!decompress) {
            // Compression is unimplemented. Report and fail (GNU exits nonzero
            // on error); do NOT silently succeed.
            StderrWriter.print("zzstd: {s}: compression is not supported (decompression only); use the system zstd to compress\n", .{path});
            had_error = true;
            continue;
        }

        if (std.mem.eql(u8, path, "-")) {
            // "-" means stdin -> stdout.
            decompressStdin(allocator) catch {
                had_error = true;
            };
            continue;
        }

        decompressFile(allocator, path, to_stdout, keep, verbose, force) catch {
            had_error = true;
        };
    }

    if (had_error) std.process.exit(1);
}

const AppError = error{
    ReadFailed,
    WriteFailed,
    OutOfMemory,
    NotZstd,
    DecompressFailed,
    OpenFailed,
    OutputExists,
};

fn readFileData(allocator: std.mem.Allocator, fd: c_int) AppError![]u8 {
    var data: std.ArrayListUnmanaged(u8) = .empty;
    errdefer data.deinit(allocator);
    var buffer: [BUFFER_SIZE]u8 = undefined;

    while (true) {
        const bytes = c_read(fd, &buffer, BUFFER_SIZE);
        if (bytes < 0) {
            if (__error().* == EINTR) continue;
            return error.ReadFailed;
        }
        if (bytes == 0) break; // clean EOF
        try data.appendSlice(allocator, buffer[0..@intCast(bytes)]);
    }

    return data.toOwnedSlice(allocator);
}

fn writeAll(fd: c_int, data: []const u8) AppError!void {
    var off: usize = 0;
    while (off < data.len) {
        const n = write(fd, data.ptr + off, data.len - off);
        if (n < 0) {
            if (__error().* == EINTR) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

fn decompressStdin(allocator: std.mem.Allocator) AppError!void {
    const input_data = readFileData(allocator, 0) catch |err| {
        StderrWriter.print("zzstd: stdin: read error\n", .{});
        return err;
    };
    defer allocator.free(input_data);

    // Decompress into memory, then write; on failure nothing partial is left
    // in a file (stdout may already carry bytes, matching GNU's streaming).
    const out = try decompressToBuffer(allocator, input_data);
    defer allocator.free(out);
    try writeAll(1, out);
}

fn decompressFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    to_stdout: bool,
    keep: bool,
    verbose: bool,
    force: bool,
) AppError!void {
    if (!std.mem.endsWith(u8, path, ".zst") and !std.mem.endsWith(u8, path, ".zstd")) {
        StderrWriter.print("zzstd: {s}: unknown suffix -- ignored\n", .{path});
        return error.OpenFailed;
    }

    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) {
        StderrWriter.print("zzstd: {s}: file name too long\n", .{path});
        return error.OpenFailed;
    }
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const in_fd = open(@ptrCast(&path_buf), O_RDONLY);
    if (in_fd < 0) {
        StderrWriter.print("zzstd: {s}: No such file or directory\n", .{path});
        return error.OpenFailed;
    }

    const input_data = readFileData(allocator, in_fd) catch |err| {
        StderrWriter.print("zzstd: {s}: read error\n", .{path});
        _ = close(in_fd);
        return err;
    };
    defer allocator.free(input_data);
    _ = close(in_fd);

    // Decompress fully into memory BEFORE touching the output or the source.
    // This is what makes the source-unlink safe: if decompression fails we
    // never created an output file and never delete the source.
    const decompressed = decompressToBuffer(allocator, input_data) catch |err| {
        StderrWriter.print("zzstd: {s}: decompression failed\n", .{path});
        return err;
    };
    defer allocator.free(decompressed);

    if (to_stdout) {
        try writeAll(1, decompressed);
        return;
    }

    // Build the output path (strip the .zst / .zstd suffix).
    const suffix_len: usize = if (std.mem.endsWith(u8, path, ".zst")) 4 else 5;
    const out_len = path.len - suffix_len;
    var out_path_buf: [4096]u8 = undefined;
    @memcpy(out_path_buf[0..out_len], path[0..out_len]);
    out_path_buf[out_len] = 0;
    const out_name = path[0..out_len];

    // Overwrite protection: without -f, refuse to clobber an existing target
    // (and never follow a symlink). With -f, truncate.
    var out_fd: c_int = undefined;
    if (force) {
        out_fd = open(@ptrCast(&out_path_buf), O_WRONLY | O_CREAT | O_TRUNC, @as(c_int, 0o644));
        if (out_fd < 0) {
            StderrWriter.print("zzstd: {s}: cannot create output file\n", .{out_name});
            return error.OpenFailed;
        }
    } else {
        out_fd = open(@ptrCast(&out_path_buf), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, @as(c_int, 0o644));
        if (out_fd < 0) {
            if (__error().* == EEXIST) {
                StderrWriter.print("zzstd: {s} already exists; not overwritten (use -f to force)\n", .{out_name});
                return error.OutputExists;
            }
            StderrWriter.print("zzstd: {s}: cannot create output file\n", .{out_name});
            return error.OpenFailed;
        }
    }

    // Write the fully-decompressed data. On any write failure, remove the
    // partial output and keep the source intact.
    writeAll(out_fd, decompressed) catch |err| {
        _ = close(out_fd);
        _ = unlink(@ptrCast(&out_path_buf));
        StderrWriter.print("zzstd: {s}: write error\n", .{out_name});
        return err;
    };
    _ = close(out_fd);

    // Only now, after a fully successful decompress AND write, remove source.
    if (!keep) {
        _ = unlink(@ptrCast(&path_buf));
    }

    if (verbose) {
        StderrWriter.print("{s}: -- replaced with {s}\n", .{ path, out_name });
    }
}

/// Decompress a zstd frame held entirely in `data` into a freshly-allocated
/// buffer. Returns an error (never a partial buffer) on any failure.
fn decompressToBuffer(allocator: std.mem.Allocator, data: []const u8) AppError![]u8 {
    if (data.len < 4) {
        StderrWriter.print("zzstd: invalid zstd data (too short)\n", .{});
        return error.NotZstd;
    }

    // Check for Zstd magic
    const magic = @as(u32, data[0]) |
        (@as(u32, data[1]) << 8) |
        (@as(u32, data[2]) << 16) |
        (@as(u32, data[3]) << 24);

    if (magic != ZSTD_MAGIC) {
        StderrWriter.print("zzstd: not in zstd format\n", .{});
        return error.NotZstd;
    }

    var out: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, 4096) catch {
        return error.OutOfMemory;
    };
    errdefer out.deinit();

    var input: std.Io.Reader = .fixed(data);
    var zstd_stream: std.compress.zstd.Decompress = .init(&input, &.{}, .{});

    _ = zstd_stream.reader.streamRemaining(&out.writer) catch |err| {
        StderrWriter.print("zzstd: decompression error: {s}\n", .{@errorName(err)});
        return error.DecompressFailed;
    };

    return out.toOwnedSlice() catch error.OutOfMemory;
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
        \\  -f, --force        force overwrite of output and follow-through
        \\  -k, --keep         keep original files
        \\  -v, --verbose      verbose output
        \\  -h, --help         display this help
        \\  -V, --version      display version
        \\
        \\Note: Compression is not supported (decompression only).
        \\      Use the system zstd to compress.
        \\
        \\Examples:
        \\  zzstd -d file.zst        Decompress to file
        \\  zzstd -dc file.zst       Decompress to stdout
        \\  zzstd -k -d file.zst     Decompress, keep original
        \\
    , .{});
}
