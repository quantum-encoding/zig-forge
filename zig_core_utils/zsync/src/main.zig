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

// syncfs is Linux-only; on macOS we use fcntl(F_FULLFSYNC) as a close equivalent
fn syncfs_compat(fd: c_int) c_int {
    if (builtin.os.tag == .linux) {
        const syncfs_fn = @extern(*const fn (c_int) callconv(.c) c_int, .{ .name = "syncfs" });
        return syncfs_fn(fd);
    } else {
        // macOS: F_FULLFSYNC = 51
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
        \\      --help         Display this help and exit
        \\      --version      Output version information and exit
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zsync " ++ VERSION ++ "\n");
}

fn syncFile(path: []const u8, cfg: Config) bool {
    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);

    const fd = libc.open(path_z, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
    if (fd < 0) {
        writeStderr("zsync: error opening '");
        writeStderr(path);
        writeStderr("'\n");
        return false;
    }
    defer _ = libc.close(fd);

    const fd_int: c_int = fd;

    if (cfg.file_system) {
        // Sync the filesystem containing the file
        if (syncfs_compat(fd_int) < 0) {
            writeStderr("zsync: error syncing filesystem for '");
            writeStderr(path);
            writeStderr("'\n");
            return false;
        }
    } else if (cfg.data_only) {
        // Sync only data, skip metadata
        if (fdatasync(fd_int) < 0) {
            writeStderr("zsync: error syncing '");
            writeStderr(path);
            writeStderr("'\n");
            return false;
        }
    } else {
        // Full sync including metadata
        if (fsync(fd_int) < 0) {
            writeStderr("zsync: error syncing '");
            writeStderr(path);
            writeStderr("'\n");
            return false;
        }
    }

    return true;
}

pub fn main(init: std.process.Init) void {
    var cfg = Config{};
    var files_found = false;
    var exit_code: u8 = 0;

    // Collect args
    var args_storage: [256][]const u8 = undefined;
    var args_count: usize = 0;
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        if (args_count < args_storage.len) {
            args_storage[args_count] = arg;
            args_count += 1;
        }
    }
    const args = args_storage[0..args_count];

    var i: usize = 1;

    // First pass: check for help/version
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        }
    }

    // Second pass: parse options and process files
    i = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--data")) {
            cfg.data_only = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file-system")) {
            cfg.file_system = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            files_found = true;
            if (!syncFile(arg, cfg)) {
                exit_code = 1;
            }
        }
    }

    // If no files specified, sync all filesystems
    if (!files_found) {
        sync();
    }

    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}
