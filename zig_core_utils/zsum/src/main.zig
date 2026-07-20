//! zsum - Checksum and count the blocks in a file
//!
//! Compatible with GNU sum (coreutils):
//! - Default: BSD checksum algorithm (`%05d %5lu %s` format, 1K blocks)
//! - -r: use BSD algorithm (default)
//! - -s, --sysv: use System V algorithm (`%d %d %s` format, 512-byte blocks)
//! - Output format: CHECKSUM BLOCKS FILENAME
//!
//! Exit status matches GNU: 0 on full success, 1 if any operand failed.

const std = @import("std");
const Io = std.Io;

const Algorithm = enum { bsd, sysv };

/// Map a caught Zig error to the GNU/POSIX strerror-style message GNU sum
/// emits, so `zsum missing` says "No such file or directory" rather than
/// "error.FileNotFound", and a directory says "Is a directory".
fn gnuErrorString(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.IsDir => "Is a directory",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.NotDir => "Not a directory",
        error.NameTooLong => "File name too long",
        error.SymLinkLoop => "Too many levels of symbolic links",
        error.FileTooBig => "File too large",
        error.SystemResources => "Cannot allocate memory",
        error.DeviceBusy => "Device or resource busy",
        error.InputOutput => "Input/output error",
        error.BrokenPipe => "Broken pipe",
        error.ConnectionResetByPeer => "Connection reset by peer",
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => "Too many open files",
        else => @errorName(err),
    };
}

/// Compute and print one file's checksum. `path` is null (or "-") for stdin.
/// A read error (e.g. reading a directory yields EISDIR -> error.IsDir) is
/// propagated so the caller can print the GNU diagnostic and set exit status;
/// no checksum line is emitted in that case, matching GNU.
fn sumFile(writer: *Io.Writer, path: ?[]const u8, algo: Algorithm) !void {
    const is_stdin = path == null or std.mem.eql(u8, path.?, "-");
    const io = Io.Threaded.global_single_threaded.io();
    // Opening a directory read-only succeeds (allow_directory defaults true);
    // the EISDIR -> error.IsDir surfaces on the first read, matching GNU sum.
    const file: ?Io.File = if (is_stdin) null else try Io.Dir.cwd().openFile(io, path.?, .{});
    defer if (file) |f| f.close(io);
    const fd: std.posix.fd_t = if (file) |f| f.handle else std.posix.STDIN_FILENO;

    var buf: [65536]u8 = undefined;
    var total_bytes: u64 = 0;

    switch (algo) {
        .bsd => {
            var checksum: u16 = 0;
            while (true) {
                const n = try std.posix.read(fd, &buf);
                if (n == 0) break;
                total_bytes += n;
                for (buf[0..n]) |b| {
                    // Rotate right by 1 bit, then add the byte.
                    checksum = (checksum >> 1) + ((checksum & 1) << 15);
                    checksum +%= b;
                }
            }
            const blocks = (total_bytes + 1023) / 1024;
            // GNU BSD format: "%05d %5lu %s" — checksum zero-padded to 5,
            // block count right-justified in 5.
            if (path) |p| {
                try writer.print("{d:0>5} {d:>5} {s}\n", .{ checksum, blocks, p });
            } else {
                try writer.print("{d:0>5} {d:>5}\n", .{ checksum, blocks });
            }
        },
        .sysv => {
            var checksum: u32 = 0;
            while (true) {
                const n = try std.posix.read(fd, &buf);
                if (n == 0) break;
                total_bytes += n;
                for (buf[0..n]) |b| {
                    checksum +%= b;
                }
            }
            // Fold 32-bit sum down to 16 bits.
            checksum = (checksum & 0xFFFF) + (checksum >> 16);
            checksum = (checksum & 0xFFFF) + (checksum >> 16);
            const blocks = (total_bytes + 511) / 512;
            // GNU SysV format: "%d %d %s" — no padding.
            if (path) |p| {
                try writer.print("{d} {d} {s}\n", .{ checksum, blocks, p });
            } else {
                try writer.print("{d} {d}\n", .{ checksum, blocks });
            }
        },
    }
}

fn printHelp() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [512]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll(
        \\Usage: sum [OPTION]... [FILE]...
        \\Print checksum and block counts for each FILE.
        \\
        \\  -r         use BSD sum algorithm (default), use 1K blocks
        \\  -s, --sysv use System V sum algorithm, use 512 bytes blocks
        \\      --help display this help and exit
        \\      --version output version information and exit
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const io = Io.Threaded.global_single_threaded.io();
    var buf: [64]u8 = undefined;
    const stdout = Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    writer.interface.writeAll("zsum 1.0.0\n") catch {};
    writer.interface.flush() catch {};
}

fn invalidShortOption(c: u8) noreturn {
    std.debug.print("zsum: invalid option -- '{c}'\n", .{c});
    std.debug.print("Try 'zsum --help' for more information.\n", .{});
    std.process.exit(1);
}

fn unrecognizedLongOption(arg: []const u8) noreturn {
    std.debug.print("zsum: unrecognized option '{s}'\n", .{arg});
    std.debug.print("Try 'zsum --help' for more information.\n", .{});
    std.process.exit(1);
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var algorithm: Algorithm = .bsd;
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(allocator);

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    var options_ended = false;
    while (args_iter.next()) |arg| {
        if (!options_ended and std.mem.eql(u8, arg, "--")) {
            // Everything after "--" is a file operand, even if it starts with '-'.
            options_ended = true;
        } else if (!options_ended and std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (!options_ended and std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (!options_ended and std.mem.eql(u8, arg, "--sysv")) {
            algorithm = .sysv;
        } else if (!options_ended and std.mem.startsWith(u8, arg, "--")) {
            unrecognizedLongOption(arg);
        } else if (!options_ended and arg.len > 1 and arg[0] == '-') {
            // A cluster of one or more short options, e.g. "-r", "-s", "-rs".
            for (arg[1..]) |c| {
                switch (c) {
                    'r' => algorithm = .bsd,
                    's' => algorithm = .sysv,
                    else => invalidShortOption(c),
                }
            }
        } else {
            // A file operand (including "-" for stdin, or any name once
            // options have ended). Grows unbounded — no fixed cap.
            files.append(allocator, arg) catch {
                std.debug.print("zsum: memory allocation failed\n", .{});
                std.process.exit(1);
            };
        }
    }

    // One shared stdout writer for the whole run: its positional offset must
    // advance across every line, or a per-file writer would pwrite each line
    // at offset 0 and clobber all but the last when stdout is a regular file.
    const io = Io.Threaded.global_single_threaded.io();
    var out_buf: [4096]u8 = undefined;
    const stdout_file = Io.File.stdout();
    var writer = stdout_file.writer(io, &out_buf);

    var any_error = false;

    if (files.items.len == 0) {
        sumFile(&writer.interface, null, algorithm) catch |err| {
            std.debug.print("zsum: -: {s}\n", .{gnuErrorString(err)});
            any_error = true;
        };
    } else {
        for (files.items) |path| {
            sumFile(&writer.interface, path, algorithm) catch |err| {
                std.debug.print("zsum: {s}: {s}\n", .{ path, gnuErrorString(err) });
                any_error = true;
            };
        }
    }

    writer.interface.flush() catch {};

    if (any_error) std.process.exit(1);
}
