//! zsync - Synchronize cached writes to persistent storage
//!
//! Flush file system buffers to disk.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

extern "c" fn sync() void;
extern "c" fn fsync(fd: c_int) c_int;
extern "c" fn fdatasync(fd: c_int) c_int;
extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern "c" fn strerror(errnum: c_int) [*:0]const u8;

// syncfs is Linux-only; on macOS we use fcntl(F_FULLFSYNC) as a close equivalent
fn syncfs_compat(fd: c_int) c_int {
    if (builtin.os.tag == .linux) {
        const syncfs_fn = @extern(*const fn (c_int) callconv(.c) c_int, .{ .name = "syncfs" });
        return syncfs_fn(fd);
    } else {
        // macOS: F_FULLFSYNC = 51. NOTE: this flushes only the single file,
        // NOT the whole containing filesystem as Linux syncfs() does.
        return fcntl(fd, 51);
    }
}

const Config = struct {
    data_only: bool = false,
    file_system: bool = false,
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zsync [OPTION]... [FILE]...
        \\Synchronize cached writes to persistent storage.
        \\
        \\If one or more files are specified, sync only them,
        \\or their containing file systems.
        \\
        \\Options:
        \\  -d, --data         Sync only file data, no unneeded metadata
        \\  -f, --file-system  Sync the file systems that contain the files
        \\                     (on macOS, -f flushes only the given file via
        \\                     F_FULLFSYNC, not the whole filesystem)
        \\      --help         Display this help and exit
        \\      --version      Output version information and exit
        \\
    ;
    // GNU sync writes --help output to stdout.
    writeStdout(usage);
}

fn printVersion() void {
    // GNU sync writes --version output to stdout.
    writeStdout("zsync (zig-forge coreutils) " ++ VERSION ++ "\n");
}

// GNU getopt error preamble: `<prog>: <msg>` then a "Try ... --help" line.
fn optErrorTry(msg1: []const u8, mid: []const u8, msg2: []const u8) void {
    writeStderr("zsync: ");
    writeStderr(msg1);
    writeStderr(mid);
    writeStderr(msg2);
    writeStderr("\n");
    writeStderr("Try 'zsync --help' for more information.\n");
}

fn syncFile(path: [:0]const u8, cfg: Config) bool {
    // path is already NUL-terminated by the OS argv, so no copy/length limit
    // is needed (the old fixed 4096-byte stack copy overflowed on long paths).
    const path_z: [*:0]const u8 = path.ptr;

    const fd = libc.open(path_z, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) {
        reportPathError("error opening '", path);
        return false;
    }
    defer _ = libc.close(fd);

    const fd_int: c_int = fd;

    if (cfg.file_system) {
        // Sync the filesystem containing the file
        if (syncfs_compat(fd_int) < 0) {
            reportPathError("error syncing filesystem for '", path);
            return false;
        }
    } else if (cfg.data_only) {
        // Sync only data, skip metadata
        if (fdatasync(fd_int) < 0) {
            reportPathError("error syncing '", path);
            return false;
        }
    } else {
        // Full sync including metadata
        if (fsync(fd_int) < 0) {
            reportPathError("error syncing '", path);
            return false;
        }
    }

    return true;
}

// Emit `zsync: <what><path>': <strerror(errno)>` like GNU does.
fn reportPathError(what: []const u8, path: []const u8) void {
    const err = libc._errno().*;
    writeStderr("zsync: ");
    writeStderr(what);
    writeStderr(path);
    writeStderr("': ");
    writeStderr(std.mem.span(strerror(err)));
    writeStderr("\n");
}

pub fn main(init: std.process.Init) void {
    var cfg = Config{};
    var files_count: usize = 0;

    // ---- Scan 1: option parsing (left-to-right, GNU getopt semantics) ----
    // --help / --version / unrecognized-option terminate immediately at the
    // position encountered, matching GNU's precedence.
    {
        var it = std.process.Args.Iterator.init(init.minimal.args);
        _ = it.next(); // skip argv[0]
        var end_of_options = false;
        while (it.next()) |arg| {
            if (end_of_options) {
                files_count += 1;
            } else if (std.mem.eql(u8, arg, "--")) {
                end_of_options = true;
            } else if (std.mem.eql(u8, arg, "-")) {
                // single dash is an operand (a file named "-")
                files_count += 1;
            } else if (arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
                // long option
                if (std.mem.eql(u8, arg, "--help")) {
                    printUsage();
                    return;
                } else if (std.mem.eql(u8, arg, "--version")) {
                    printVersion();
                    return;
                } else if (std.mem.eql(u8, arg, "--data")) {
                    cfg.data_only = true;
                } else if (std.mem.eql(u8, arg, "--file-system")) {
                    cfg.file_system = true;
                } else {
                    optErrorTry("unrecognized option '", arg, "'");
                    std.process.exit(1);
                }
            } else if (arg.len >= 2 and arg[0] == '-') {
                // bundled short options, e.g. -d, -f, -df
                var ci: usize = 1;
                while (ci < arg.len) : (ci += 1) {
                    switch (arg[ci]) {
                        'd' => cfg.data_only = true,
                        'f' => cfg.file_system = true,
                        else => {
                            const c = [_]u8{arg[ci]};
                            optErrorTry("invalid option -- '", &c, "'");
                            std.process.exit(1);
                        },
                    }
                }
            } else {
                files_count += 1;
            }
        }
    }

    // ---- Post-parse validation (GNU checks these after the getopt loop) ----
    if (cfg.data_only and cfg.file_system) {
        writeStderr("zsync: cannot specify both --data and --file-system\n");
        std.process.exit(1);
    }
    // Only --data requires an operand; --file-system with no file syncs all.
    if (cfg.data_only and files_count == 0) {
        writeStderr("zsync: --data needs at least one argument\n");
        std.process.exit(1);
    }

    // No operands: sync every filesystem.
    if (files_count == 0) {
        sync();
        return;
    }

    // ---- Scan 2: process file operands in order ----
    var exit_code: u8 = 0;
    {
        var it = std.process.Args.Iterator.init(init.minimal.args);
        _ = it.next(); // skip argv[0]
        var end_of_options = false;
        while (it.next()) |arg| {
            const is_operand = end_of_options or
                std.mem.eql(u8, arg, "-") or
                arg.len == 0 or arg[0] != '-';
            if (!end_of_options and std.mem.eql(u8, arg, "--")) {
                end_of_options = true;
                continue;
            }
            if (is_operand) {
                if (!syncFile(arg, cfg)) exit_code = 1;
            }
            // options were already validated in scan 1; skip them here
        }
    }

    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}
