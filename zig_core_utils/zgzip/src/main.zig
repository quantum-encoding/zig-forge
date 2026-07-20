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
extern "c" fn fsync(fd: c_int) c_int;
// Darwin errno location.
extern "c" fn __error() *c_int;

// Darwin (macOS) open(2) flag values. These differ from Linux — using the
// Linux numbers (as the original code did) silently maps O_TRUNC onto O_SHLOCK
// and O_CREAT onto an unrelated bit, so the output file was never truncated.
const O_RDONLY: c_int = 0x0000;
const O_WRONLY: c_int = 0x0001;
const O_CREAT: c_int = 0x0200;
const O_TRUNC: c_int = 0x0400;
const O_EXCL: c_int = 0x0800;
const O_NOFOLLOW: c_int = 0x0100;

const EEXIST: c_int = 17;
const ELOOP: c_int = 62;

// Simple stderr writer for error messages
const StderrWriter = struct {
    pub fn print(comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        _ = write(2, msg.ptr, msg.len);
    }
};

// GNU gzip writes --help / --version to stdout, not stderr.
const StdoutWriter = struct {
    pub fn print(comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        _ = write(1, msg.ptr, msg.len);
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
    var force = false;
    var quiet = false;
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
            StdoutWriter.print("zgzip {s}\n", .{VERSION});
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
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--fast")) {
            level = 1;
        } else if (std.mem.eql(u8, arg, "--best")) {
            level = 9;
        } else if (std.mem.eql(u8, arg, "-")) {
            // A lone '-' means stdin/stdout (POSIX/GNU), not a filename.
            try files.append(allocator, arg);
        } else if (arg.len > 0 and arg[0] == '-' and arg.len > 1 and arg[1] != '-') {
            // Handle combined short options like -dc, -dkv, -9kv
            for (arg[1..]) |ch| {
                switch (ch) {
                    'h' => {
                        printHelp(decompress);
                        return;
                    },
                    'V' => {
                        StdoutWriter.print("zgzip {s}\n", .{VERSION});
                        return;
                    },
                    'c' => to_stdout = true,
                    'd' => decompress = true,
                    'f' => force = true,
                    'k' => keep = true,
                    'q' => quiet = true,
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
        const ok = if (decompress)
            decompressStdin(allocator)
        else
            compressStdin(allocator, level);
        if (!ok) std.process.exit(1);
        return;
    }

    // Process files. Track whether any operation failed so we can exit non-zero
    // like GNU gzip (1 = error). A single bad file must not mask a good one and
    // vice versa.
    var any_failed = false;
    for (files.items) |path| {
        // A lone '-' means stdin -> stdout, regardless of other filenames.
        if (std.mem.eql(u8, path, "-")) {
            const ok = if (decompress)
                decompressStdin(allocator)
            else
                compressStdin(allocator, level);
            if (!ok) any_failed = true;
            continue;
        }
        const ok = if (decompress)
            decompressFile(allocator, path, to_stdout, keep, verbose, force, quiet)
        else
            compressFile(allocator, path, level, to_stdout, keep, verbose, force, quiet);
        if (!ok) any_failed = true;
    }

    if (any_failed) std.process.exit(1);
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

fn compressStdin(allocator: std.mem.Allocator, level: u4) bool {
    const input_data = readFileData(allocator, 0) orelse {
        StderrWriter.print("zgzip: memory allocation error\n", .{});
        return false;
    };
    defer allocator.free(input_data);

    return compressToFd(allocator, input_data, 1, level) != null;
}

fn decompressStdin(allocator: std.mem.Allocator) bool {
    const input_data = readFileData(allocator, 0) orelse {
        StderrWriter.print("zgzip: memory allocation error\n", .{});
        return false;
    };
    defer allocator.free(input_data);

    return decompressToFd(allocator, input_data, 1);
}

fn compressFile(allocator: std.mem.Allocator, path: []const u8, level: u4, to_stdout: bool, keep: bool, verbose: bool, force: bool, quiet: bool) bool {
    if (std.mem.endsWith(u8, path, ".gz")) {
        if (!quiet) StderrWriter.print("zgzip: {s}: already has .gz suffix -- unchanged\n", .{path});
        return false;
    }

    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) {
        StderrWriter.print("zgzip: {s}: file name too long\n", .{path});
        return false;
    }
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const in_fd = open(@ptrCast(&path_buf), O_RDONLY);
    if (in_fd < 0) {
        StderrWriter.print("zgzip: {s}: No such file or directory\n", .{path});
        return false;
    }

    const input_data = readFileData(allocator, in_fd) orelse {
        StderrWriter.print("zgzip: memory allocation error\n", .{});
        _ = close(in_fd);
        return false;
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
            return false;
        }
        @memcpy(out_path_buf[0..path.len], path);
        @memcpy(out_path_buf[path.len .. path.len + 3], ".gz");
        out_path_buf[out_len] = 0;

        out_fd = openOutput(@ptrCast(&out_path_buf), force);
        if (out_fd < 0) {
            reportOpenError(path, ".gz");
            return false;
        }
        close_out = true;
    }

    const compressed_size_opt = compressToFd(allocator, input_data, out_fd, level);

    // Force durability before we consider deleting the source.
    var synced = true;
    if (close_out) {
        if (compressed_size_opt != null and fsync(out_fd) != 0) synced = false;
        _ = close(out_fd);
    }

    if (compressed_size_opt == null) {
        // Compression failed and produced a corrupt/partial output; never
        // delete the source, and remove the botched output if we made it.
        if (close_out) _ = unlink(@ptrCast(&out_path_buf));
        return false;
    }
    const compressed_size = compressed_size_opt.?;

    if (!synced) {
        StderrWriter.print("zgzip: {s}.gz: fsync failed; keeping original\n", .{path});
        return false;
    }

    // Only now — verified-successful compress + fsync — is it safe to unlink.
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
    return true;
}

// Open an output file safely: never follow a symlink, and refuse to clobber an
// existing file unless --force was given. Returns -1 on failure (errno set).
fn openOutput(path: [*:0]const u8, force: bool) c_int {
    var flags: c_int = O_WRONLY | O_CREAT | O_NOFOLLOW;
    flags |= if (force) O_TRUNC else O_EXCL;
    return open(path, flags, @as(c_int, 0o644));
}

fn reportOpenError(path: []const u8, suffix: []const u8) void {
    const e = __error().*;
    if (e == EEXIST) {
        StderrWriter.print("zgzip: {s}{s} already exists; not overwritten (use -f to force)\n", .{ path, suffix });
    } else if (e == ELOOP) {
        StderrWriter.print("zgzip: {s}{s}: is a symlink; refusing to follow\n", .{ path, suffix });
    } else {
        StderrWriter.print("zgzip: {s}{s}: Cannot create file\n", .{ path, suffix });
    }
}

fn decompressFile(allocator: std.mem.Allocator, path: []const u8, to_stdout: bool, keep: bool, verbose: bool, force: bool, quiet: bool) bool {
    if (!std.mem.endsWith(u8, path, ".gz")) {
        if (!quiet) StderrWriter.print("zgzip: {s}: unknown suffix -- ignored\n", .{path});
        return false;
    }
    // Guard the degenerate ".gz" (stem empty): deriving an empty output name
    // would produce a bogus open() call.
    if (path.len <= 3) {
        StderrWriter.print("zgzip: {s}: unknown suffix -- ignored\n", .{path});
        return false;
    }

    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) {
        StderrWriter.print("zgzip: {s}: file name too long\n", .{path});
        return false;
    }
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const in_fd = open(@ptrCast(&path_buf), O_RDONLY);
    if (in_fd < 0) {
        StderrWriter.print("zgzip: {s}: No such file or directory\n", .{path});
        return false;
    }

    const input_data = readFileData(allocator, in_fd) orelse {
        StderrWriter.print("zgzip: memory allocation error\n", .{});
        _ = close(in_fd);
        return false;
    };
    defer allocator.free(input_data);
    _ = close(in_fd);

    var out_fd: c_int = 1;
    var out_path_buf: [4096]u8 = undefined;
    const out_len = path.len - 3;
    var close_out = false;

    if (!to_stdout) {
        @memcpy(out_path_buf[0..out_len], path[0..out_len]);
        out_path_buf[out_len] = 0;

        out_fd = openOutput(@ptrCast(&out_path_buf), force);
        if (out_fd < 0) {
            reportOpenError(path[0..out_len], "");
            return false;
        }
        close_out = true;
    }

    const ok = decompressToFd(allocator, input_data, out_fd);

    var synced = true;
    if (close_out) {
        if (ok and fsync(out_fd) != 0) synced = false;
        _ = close(out_fd);
    }

    if (!ok) {
        // Decompression failed: never delete the source .gz, and remove the
        // partial output we created.
        if (close_out) _ = unlink(@ptrCast(&out_path_buf));
        return false;
    }
    if (!synced) {
        StderrWriter.print("zgzip: {s}: fsync failed; keeping original\n", .{path[0..out_len]});
        return false;
    }

    if (!to_stdout and !keep) {
        _ = unlink(@ptrCast(&path_buf));
    }

    if (verbose and !to_stdout) {
        StderrWriter.print("{s}:\t -- replaced with {s}\n", .{ path, path[0..out_len] });
    }
    return true;
}

fn compressToFd(allocator: std.mem.Allocator, data: []const u8, out_fd: c_int, level: u4) ?usize {
    // Use std.Io.Writer.Allocating for output - need at least 8 bytes for flate
    var out: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, 4096) catch {
        StderrWriter.print("zgzip: memory allocation error\n", .{});
        return null;
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
        return null;
    };

    // Write input data through compressor
    comp.writer.writeAll(data) catch {
        StderrWriter.print("zgzip: compression error\n", .{});
        return null;
    };

    // Finalize the gzip stream. finish() emits the final DEFLATE block (BFINAL=1)
    // AND the 8-byte gzip trailer (CRC32 + ISIZE). A plain flush() only byte-
    // aligns the bit buffer and leaves a truncated, undecompressable stream.
    comp.finish() catch {
        StderrWriter.print("zgzip: compression finalize error\n", .{});
        return null;
    };

    // Write compressed data to output fd
    const compressed = out.toOwnedSlice() catch {
        StderrWriter.print("zgzip: memory error\n", .{});
        return null;
    };
    defer allocator.free(compressed);

    if (!writeAllFd(out_fd, compressed)) {
        StderrWriter.print("zgzip: write error\n", .{});
        return null;
    }
    return compressed.len;
}

// Write the whole buffer to fd, handling short writes; returns false on error.
fn writeAllFd(fd: c_int, buf: []const u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = write(fd, buf.ptr + off, buf.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn decompressToFd(allocator: std.mem.Allocator, data: []const u8, out_fd: c_int) bool {
    if (data.len < 18) {
        StderrWriter.print("zgzip: invalid gzip data (too short)\n", .{});
        return false;
    }

    // Verify gzip magic
    if (data[0] != GZIP_MAGIC[0] or data[1] != GZIP_MAGIC[1]) {
        StderrWriter.print("zgzip: not in gzip format\n", .{});
        return false;
    }

    // Use std.Io.Writer.Allocating for output
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    // Create fixed reader from input data
    var input: std.Io.Reader = .fixed(data);

    // Create decompression buffer
    var decomp_buffer: [flate.max_window_len]u8 = undefined;

    // A gzip file may be a concatenation of independent members (e.g. `cat
    // a.gz b.gz`). GNU gzip decodes and emits every member. std's Decompress
    // handles exactly one member, so we loop, re-initialising on the remaining
    // input after each member ends, until the input is exhausted.
    var members: usize = 0;
    while (true) {
        const rem = input.buffer[input.seek..input.end];
        if (rem.len == 0) break;

        if (members > 0) {
            // Anything after the first member that is not another gzip member
            // is trailing garbage; GNU warns and ignores it.
            if (rem.len < 2 or rem[0] != GZIP_MAGIC[0] or rem[1] != GZIP_MAGIC[1]) {
                StderrWriter.print("zgzip: trailing garbage ignored\n", .{});
                break;
            }
        }

        var decomp = flate.Decompress.init(&input, .gzip, &decomp_buffer);
        _ = decomp.reader.streamRemaining(&out.writer) catch |err| {
            StderrWriter.print("zgzip: decompression error: {s}\n", .{@errorName(err)});
            return false;
        };
        members += 1;
    }

    // Get decompressed data
    const decompressed = out.toOwnedSlice() catch {
        StderrWriter.print("zgzip: memory error\n", .{});
        return false;
    };
    defer allocator.free(decompressed);

    // Write to output fd
    if (!writeAllFd(out_fd, decompressed)) {
        StderrWriter.print("zgzip: write error\n", .{});
        return false;
    }
    return true;
}

fn printHelp(decompress: bool) void {
    if (decompress) {
        StdoutWriter.print(
            \\Usage: zgunzip [OPTION]... [FILE]...
            \\
            \\Decompress FILEs (by default, in place).
            \\
            \\Options:
            \\  -c, --stdout       write to stdout, keep original files
            \\  -f, --force        force overwrite (never follows symlinks)
            \\  -k, --keep         keep original files
            \\  -q, --quiet        suppress warnings
            \\  -v, --verbose      verbose output
            \\  -h, --help         display this help
            \\  -V, --version      display version
            \\
            \\With no FILE, or when FILE is -, read from stdin.
            \\
        , .{});
    } else {
        StdoutWriter.print(
            \\Usage: zgzip [OPTION]... [FILE]...
            \\
            \\Compress FILEs (by default, in place).
            \\
            \\Options:
            \\  -c, --stdout       write to stdout, keep original files
            \\  -d, --decompress   decompress
            \\  -f, --force        force overwrite (never follows symlinks)
            \\  -k, --keep         keep original files
            \\  -q, --quiet        suppress warnings
            \\  -1..-9             compression level (1=fast, 9=best, default=6)
            \\  --fast             alias for -1
            \\  --best             alias for -9
            \\  -v, --verbose      verbose output
            \\  -h, --help         display this help
            \\  -V, --version      display version
            \\
            \\With no FILE, or when FILE is -, read from stdin.
            \\
            \\Examples:
            \\  zgzip file.txt         Compress to file.txt.gz
            \\  zgzip -k file.txt      Compress, keep original
            \\  zgunzip file.txt.gz    Decompress to file.txt
            \\
        , .{});
    }
}
