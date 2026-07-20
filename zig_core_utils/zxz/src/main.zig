//! zxz - Decompress files in the xz (.xz) format
//!
//! A Zig implementation of an xz *decompression* utility (unxz/xzcat-style).
//! Supports the xz container format with LZMA2 blocks, including
//! multi-stream (concatenated) .xz files.
//!
//! Compression is NOT implemented: `zxz file` (compress request) is refused
//! with a nonzero exit rather than silently doing nothing. Legacy .lzma
//! (LZMA_ALONE) input is NOT supported and is refused without touching the
//! source file.
//!
//! Usage: zxz [OPTION]... [FILE]...

const std = @import("std");
const builtin = @import("builtin");

const VERSION = "1.0.0";
const BUFFER_SIZE = 65536;

// XZ magic bytes
const XZ_MAGIC: [6]u8 = .{ 0xFD, '7', 'z', 'X', 'Z', 0x00 };

// C functions for file I/O
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
const c_read = @extern(*const fn (c_int, [*]u8, usize) callconv(.c) isize, .{ .name = "read" });
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn unlink(path: [*:0]const u8) c_int;

// open(2) flags differ between Linux and the BSD/Darwin family; the previous
// hard-coded Linux values silently mapped to the WRONG flags on macOS (0x0040
// is O_SHLOCK, not O_CREAT; 0x0200 is O_CREAT, not O_TRUNC), which is why
// existing-file truncation behaved inconsistently. Pick per-platform.
const is_darwin = builtin.os.tag.isDarwin();
const O_RDONLY: c_int = 0x0000;
const O_WRONLY: c_int = 0x0001;
const O_CREAT: c_int = if (is_darwin) 0x0200 else 0o100;
const O_TRUNC: c_int = if (is_darwin) 0x0400 else 0o1000;
const O_EXCL: c_int = if (is_darwin) 0x0800 else 0o200;
const O_NOFOLLOW: c_int = if (is_darwin) 0x0100 else 0o400000;

const EINTR: c_int = @intFromEnum(std.c.E.INTR);

/// Write a formatted message to a file descriptor. Informational output
/// (--help/--version/normal messages) goes to stdout (fd 1); diagnostics go
/// to stderr (fd 2), matching GNU xz.
fn fdPrint(fd: c_int, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = writeAllFd(fd, msg);
}

fn outPrint(comptime fmt: []const u8, args: anytype) void {
    fdPrint(1, fmt, args);
}

fn errPrint(comptime fmt: []const u8, args: anytype) void {
    fdPrint(2, fmt, args);
}

/// Write every byte of `data`, retrying short writes and EINTR. Returns false
/// on any unrecoverable error. The previous code discarded write()'s result,
/// so ENOSPC / short writes silently truncated output.
fn writeAllFd(fd: c_int, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const n = write(fd, data.ptr + off, data.len - off);
        if (n < 0) {
            if (std.c._errno().* == EINTR) continue;
            return false;
        }
        if (n == 0) return false;
        off += @intCast(n);
    }
    return true;
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

    // Determine mode from program name
    var decompress = false;
    if (args.len > 0) {
        const prog_name = std.fs.path.basename(args[0]);
        if (std.mem.indexOf(u8, prog_name, "unxz") != null or
            std.mem.indexOf(u8, prog_name, "xzcat") != null)
        {
            decompress = true;
        }
    }

    // Parse options
    var to_stdout = false;
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
            outPrint("zxz {s}\n", .{VERSION});
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
        } else if (arg.len > 0 and arg[0] == '-' and arg.len > 1 and arg[1] != '-') {
            // Handle combined short options like -dc, -dkv
            for (arg[1..]) |ch| {
                switch (ch) {
                    'h' => {
                        printHelp();
                        return;
                    },
                    'V' => {
                        outPrint("zxz {s}\n", .{VERSION});
                        return;
                    },
                    'c' => to_stdout = true,
                    'd' => decompress = true,
                    'f' => force = true,
                    'k' => keep = true,
                    'v' => verbose = true,
                    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {}, // Compression level accepted (ignored: decompress-only)
                    else => {
                        errPrint("zxz: invalid option -- '{c}'\n", .{ch});
                        std.process.exit(1);
                    },
                }
            }
        } else if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            errPrint("zxz: invalid option -- '{s}'\n", .{arg[1..]});
            std.process.exit(1);
        } else {
            try files.append(allocator, arg);
        }
    }

    var had_error = false;

    // If no files, use stdin/stdout
    if (files.items.len == 0) {
        if (decompress) {
            if (!decompressStdin(allocator)) had_error = true;
        } else {
            errPrint("zxz: compression is not implemented (decompress-only build); use xz to compress\n", .{});
            std.process.exit(1);
        }
        if (had_error) std.process.exit(1);
        return;
    }

    // Process files
    for (files.items) |path| {
        if (decompress) {
            if (!decompressFile(allocator, path, to_stdout, keep, verbose, force)) had_error = true;
        } else {
            errPrint("zxz: {s}: compression is not implemented (decompress-only build); use xz to compress\n", .{path});
            had_error = true;
        }
    }

    if (had_error) std.process.exit(1);
}

/// Read all bytes from a fd. Returns null on a genuine read/alloc error
/// (distinct from EOF), so the caller can abort WITHOUT deleting the source.
fn readFileData(allocator: std.mem.Allocator, fd: c_int) ?[]u8 {
    var data: std.ArrayListUnmanaged(u8) = .empty;
    var buffer: [BUFFER_SIZE]u8 = undefined;

    while (true) {
        const bytes = c_read(fd, &buffer, BUFFER_SIZE);
        if (bytes < 0) {
            if (std.c._errno().* == EINTR) continue;
            data.deinit(allocator);
            return null; // real error != EOF
        }
        if (bytes == 0) break; // EOF
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

fn decompressStdin(allocator: std.mem.Allocator) bool {
    const input_data = readFileData(allocator, 0) orelse {
        errPrint("zxz: read error on standard input\n", .{});
        return false;
    };
    defer allocator.free(input_data);

    return decompressToFd(allocator, input_data, 1);
}

fn decompressFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    to_stdout: bool,
    keep: bool,
    verbose: bool,
    force: bool,
) bool {
    // Only real .xz is decoded. Legacy .lzma is advertised nowhere now and is
    // refused up front WITHOUT opening or deleting the source.
    if (std.mem.endsWith(u8, path, ".lzma")) {
        errPrint("zxz: {s}: legacy .lzma (LZMA_ALONE) format is not supported\n", .{path});
        return false;
    }
    if (!std.mem.endsWith(u8, path, ".xz")) {
        errPrint("zxz: {s}: filename has an unknown suffix, skipping\n", .{path});
        return false;
    }

    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) {
        errPrint("zxz: {s}: file name too long\n", .{path});
        return false;
    }
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const in_fd = open(@ptrCast(&path_buf), O_RDONLY);
    if (in_fd < 0) {
        errPrint("zxz: {s}: No such file or directory\n", .{path});
        return false;
    }

    const input_data = readFileData(allocator, in_fd) orelse {
        errPrint("zxz: {s}: read error\n", .{path});
        _ = close(in_fd);
        return false;
    };
    defer allocator.free(input_data);
    _ = close(in_fd);

    var out_fd: c_int = 1;
    var out_path_buf: [4096]u8 = undefined;
    var close_out = false;
    var out_name: []const u8 = "";

    if (!to_stdout) {
        const suffix_len: usize = 3; // ".xz"
        const out_len = path.len - suffix_len;
        @memcpy(out_path_buf[0..out_len], path[0..out_len]);
        out_path_buf[out_len] = 0;
        out_name = path[0..out_len];

        // Without --force: refuse to overwrite an existing file and refuse to
        // follow a symlink at the output path (O_EXCL | O_NOFOLLOW). With
        // --force: truncate/overwrite as xz -f does.
        const flags: c_int = if (force)
            O_WRONLY | O_CREAT | O_TRUNC
        else
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW;

        out_fd = open(@ptrCast(&out_path_buf), flags, @as(c_int, 0o644));
        if (out_fd < 0) {
            if (!force) {
                errPrint("zxz: {s}: output file exists (use -f to force); source kept\n", .{out_name});
            } else {
                errPrint("zxz: {s}: cannot create output file\n", .{out_name});
            }
            return false;
        }
        close_out = true;
    }

    const ok = decompressToFd(allocator, input_data, out_fd);

    if (close_out) {
        _ = close(out_fd);
    }

    if (!ok) {
        // Decompression or writing failed: remove the partial output file and
        // KEEP the source. Never delete the source on a failed decode.
        if (!to_stdout) {
            _ = unlink(@ptrCast(&out_path_buf));
        }
        return false;
    }

    // Success: only now is it safe to remove the source (unless -k/-c).
    if (!to_stdout and !keep) {
        _ = unlink(@ptrCast(&path_buf));
    }

    if (verbose and !to_stdout) {
        errPrint("{s}: replaced with {s}\n", .{ path, out_name });
    }

    return true;
}

/// Decode every xz stream in `data` and write the concatenated output to
/// `out_fd`. Returns false on any error (bad magic, corrupt data, short
/// write). Handles multi-stream (concatenated) files: after each stream ends,
/// stream padding (null bytes) is skipped and any remaining input is decoded
/// as the next stream, matching xz's default LZMA_CONCATENATED behavior.
fn decompressToFd(allocator: std.mem.Allocator, data: []const u8, out_fd: c_int) bool {
    if (data.len < 12 or !std.mem.eql(u8, data[0..6], &XZ_MAGIC)) {
        errPrint("zxz: not in xz format\n", .{});
        return false;
    }

    var input: std.Io.Reader = .fixed(data);

    while (true) {
        // Skip inter-stream padding (spec: zero or more null bytes, a multiple
        // of four). A fixed reader keeps all remaining bytes in its buffer.
        while (input.bufferedLen() > 0 and input.buffered()[0] == 0) {
            input.toss(1);
        }
        if (input.bufferedLen() == 0) break; // all streams consumed

        // Fresh dictionary buffer per stream; Decompress.deinit() frees it.
        const decomp_buffer = allocator.alloc(u8, 4096) catch {
            errPrint("zxz: memory allocation error\n", .{});
            return false;
        };

        var decomp = std.compress.xz.Decompress.init(&input, allocator, decomp_buffer) catch |err| {
            errPrint("zxz: {s}\n", .{@errorName(err)});
            allocator.free(decomp_buffer);
            return false;
        };
        defer decomp.deinit();

        var out: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, 4096) catch {
            errPrint("zxz: memory allocation error\n", .{});
            return false;
        };
        defer out.deinit();

        _ = decomp.reader.streamRemaining(&out.writer) catch |err| {
            errPrint("zxz: {s}\n", .{@errorName(err)});
            return false;
        };

        if (!writeAllFd(out_fd, out.writer.buffered())) {
            errPrint("zxz: write error\n", .{});
            return false;
        }
    }

    return true;
}

fn printHelp() void {
    outPrint(
        \\Usage: zxz [OPTION]... [FILE]...
        \\
        \\Decompress FILEs in the .xz format.
        \\
        \\Options:
        \\  -c, --stdout       write to stdout, keep original files
        \\  -d, --decompress   decompress (default for unxz/xzcat)
        \\  -f, --force        force overwrite of output and follow symlinks
        \\  -k, --keep         keep original files
        \\  -v, --verbose      verbose output
        \\  -h, --help         display this help
        \\  -V, --version      display version
        \\
        \\Note: This is a decompress-only build. Compression is not
        \\      implemented (use xz to compress). Legacy .lzma input is
        \\      not supported.
        \\
        \\Examples:
        \\  zxz -d file.xz        Decompress to file
        \\  zxz -dc file.xz       Decompress to stdout
        \\  zxz -k -d file.xz     Decompress, keep original
        \\
    , .{});
}
