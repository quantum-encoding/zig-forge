//! zshred - Securely delete files
//!
//! Overwrite files to make recovery difficult, then optionally delete.
//! Uses multiple passes with random data.

const std = @import("std");
const builtin = @import("builtin");
const libc = std.c;

const VERSION = "1.0.0";

extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64;
extern "c" fn fsync(fd: c_int) c_int;
extern "c" fn time(t: ?*i64) i64;

const SEEK_SET: c_int = 0;
const O_WRONLY: c_int = 1;

// Cross-platform stat structure
const Stat = switch (builtin.os.tag) {
    .linux => extern struct {
        st_dev: u64,
        st_ino: u64,
        st_nlink: u64,
        st_mode: u32,
        st_uid: u32,
        st_gid: u32,
        __pad0: u32,
        st_rdev: u64,
        size: i64,
        st_blksize: i64,
        st_blocks: i64,
        st_atime: i64,
        st_atime_nsec: i64,
        st_mtime: i64,
        st_mtime_nsec: i64,
        st_ctime: i64,
        st_ctime_nsec: i64,
        __unused: [3]i64,
    },
    .macos => extern struct {
        st_dev: i32,
        st_mode: u16,
        st_nlink: u16,
        st_ino: u64,
        st_uid: u32,
        st_gid: u32,
        st_rdev: i32,
        st_atime: std.c.timespec,
        st_mtime: std.c.timespec,
        st_ctime: std.c.timespec,
        st_birthtim: std.c.timespec,
        size: i64,
        st_blocks: i64,
        st_blksize: i32,
        st_flags: u32,
        st_gen: u32,
        st_lspare: i32,
        st_qspare: [2]i64,
    },
    else => libc.Stat,
};

extern "c" fn stat(path: [*:0]const u8, buf: *Stat) c_int;

const Config = struct {
    iterations: u32 = 3,
    remove: bool = false,
    zero: bool = false,
    verbose: bool = false,
    force: bool = false,
    exact: bool = false,
    files: [64][]const u8 = undefined,
    file_count: usize = 0,
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zshred [OPTION]... FILE...
        \\Overwrite the specified FILE(s) repeatedly to make recovery difficult.
        \\
        \\Options:
        \\  -f, --force        Change permissions to allow writing if necessary
        \\  -n, --iterations=N Overwrite N times (default: 3)
        \\  -u, --remove       Deallocate and remove file after overwriting
        \\  -v, --verbose      Show progress
        \\  -x, --exact        Do not round file sizes up to the next block
        \\  -z, --zero         Add a final overwrite with zeros to hide shredding
        \\      --help         Display this help and exit
        \\      --version      Output version information and exit
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zshred " ++ VERSION ++ "\n");
}

fn getRandom(buf: []u8) void {
    // Use getrandom syscall on Linux (arc4random_buf not available on glibc)
    const result = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    if (@as(isize, @bitCast(result)) < 0) {
        // Fallback: fill with pseudo-random data using simple PRNG
        var seed: u64 = @bitCast(time(null));
        for (buf) |*byte| {
            seed = seed *% 6364136223846793005 +% 1442695040888963407;
            byte.* = @truncate(seed >> 33);
        }
    }
}

fn formatSize(size: u64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "B", "K", "M", "G", "T" };
    var s: f64 = @floatFromInt(size);
    var unit_idx: usize = 0;

    while (s >= 1024 and unit_idx < units.len - 1) {
        s /= 1024;
        unit_idx += 1;
    }

    if (unit_idx == 0) {
        return std.fmt.bufPrint(buf, "{d}{s}", .{ size, units[0] }) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.1}{s}", .{ s, units[unit_idx] }) catch "?";
    }
}

fn shredFile(path: []const u8, cfg: *const Config) !void {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.PathTooLong;

    // Get file size
    var stat_buf: Stat = undefined;
    if (stat(path_z, &stat_buf) != 0) {
        writeStderr("zshred: cannot stat '");
        writeStderr(path);
        writeStderr("'\n");
        return error.StatFailed;
    }

    const file_size: u64 = @intCast(stat_buf.size);
    if (file_size == 0) {
        if (cfg.verbose) {
            writeStderr("zshred: ");
            writeStderr(path);
            writeStderr(": empty file\n");
        }
        if (cfg.remove) {
            _ = unlink(path_z);
        }
        return;
    }

    // Open file for writing
    if (cfg.force) {
        // Try to change permissions if needed
        _ = chmod(path_z, 0o600);
    }

    const fd = open(path_z, O_WRONLY, 0);
    if (fd < 0) {
        writeStderr("zshred: cannot open '");
        writeStderr(path);
        writeStderr("' for writing\n");
        return error.OpenFailed;
    }
    defer _ = close(fd);

    var buf: [65536]u8 = undefined;
    var size_buf: [32]u8 = undefined;
    var pass_buf: [8]u8 = undefined;
    var total_buf: [8]u8 = undefined;

    const total_passes = cfg.iterations + @as(u32, if (cfg.zero) 1 else 0);

    // Perform overwrite passes
    var pass: u32 = 0;
    while (pass < cfg.iterations) : (pass += 1) {
        if (cfg.verbose) {
            writeStderr("zshred: ");
            writeStderr(path);
            writeStderr(": pass ");
            const pass_str = std.fmt.bufPrint(&pass_buf, "{d}", .{pass + 1}) catch "?";
            writeStderr(pass_str);
            writeStderr("/");
            const total_str = std.fmt.bufPrint(&total_buf, "{d}", .{total_passes}) catch "?";
            writeStderr(total_str);
            writeStderr(" (random)...");
        }

        // Seek to beginning
        _ = lseek(fd, 0, SEEK_SET);

        var remaining = file_size;
        while (remaining > 0) {
            const chunk = @min(remaining, buf.len);
            getRandom(buf[0..chunk]);

            const written = write(fd, &buf, chunk);
            if (written < 0) {
                if (cfg.verbose) writeStderr(" FAILED\n");
                return error.WriteFailed;
            }
            remaining -= @intCast(written);
        }

        // Sync to disk
        _ = fsync(fd);

        if (cfg.verbose) {
            writeStderr(" ");
            writeStderr(formatSize(file_size, &size_buf));
            writeStderr("\n");
        }
    }

    // Zero pass if requested
    if (cfg.zero) {
        if (cfg.verbose) {
            writeStderr("zshred: ");
            writeStderr(path);
            writeStderr(": pass ");
            const pass_str = std.fmt.bufPrint(&pass_buf, "{d}", .{total_passes}) catch "?";
            writeStderr(pass_str);
            writeStderr("/");
            const total_str = std.fmt.bufPrint(&total_buf, "{d}", .{total_passes}) catch "?";
            writeStderr(total_str);
            writeStderr(" (zeros)...");
        }

        _ = lseek(fd, 0, SEEK_SET);
        @memset(&buf, 0);

        var remaining = file_size;
        while (remaining > 0) {
            const chunk = @min(remaining, buf.len);
            const written = write(fd, &buf, chunk);
            if (written < 0) {
                if (cfg.verbose) writeStderr(" FAILED\n");
                return error.WriteFailed;
            }
            remaining -= @intCast(written);
        }

        _ = fsync(fd);

        if (cfg.verbose) {
            writeStderr(" ");
            writeStderr(formatSize(file_size, &size_buf));
            writeStderr("\n");
        }
    }

    // Remove file if requested
    if (cfg.remove) {
        if (cfg.verbose) {
            writeStderr("zshred: ");
            writeStderr(path);
            writeStderr(": removing\n");
        }
        // Close before unlinking
        _ = close(fd);
        if (unlink(path_z) != 0) {
            writeStderr("zshred: cannot remove '");
            writeStderr(path);
            writeStderr("'\n");
        }
    }
}

fn parseInt(s: []const u8) ?u32 {
    var result: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        result = result * 10 + (c - '0');
    }
    return result;
}

pub fn main(init: std.process.Init) void {
    var cfg = Config{};

    // Collect args into array
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
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            cfg.force = true;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--remove")) {
            cfg.remove = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            cfg.verbose = true;
        } else if (std.mem.eql(u8, arg, "-x") or std.mem.eql(u8, arg, "--exact")) {
            cfg.exact = true;
        } else if (std.mem.eql(u8, arg, "-z") or std.mem.eql(u8, arg, "--zero")) {
            cfg.zero = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--iterations")) {
            i += 1;
            if (i < args.len) {
                const val = args[i];
                if (parseInt(val)) |n| {
                    cfg.iterations = n;
                } else {
                    writeStderr("zshred: invalid iteration count\n");
                    std.process.exit(1);
                }
            }
        } else if (std.mem.startsWith(u8, arg, "--iterations=")) {
            const val = arg[13..];
            if (parseInt(val)) |n| {
                cfg.iterations = n;
            } else {
                writeStderr("zshred: invalid iteration count\n");
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "-n")) {
            const val = arg[2..];
            if (parseInt(val)) |n| {
                cfg.iterations = n;
            } else {
                writeStderr("zshred: invalid iteration count\n");
                std.process.exit(1);
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            if (cfg.file_count < cfg.files.len) {
                cfg.files[cfg.file_count] = arg;
                cfg.file_count += 1;
            }
        } else if (std.mem.eql(u8, arg, "--")) {
            // Rest are files
            i += 1;
            while (i < args.len) : (i += 1) {
                if (cfg.file_count < cfg.files.len) {
                    cfg.files[cfg.file_count] = args[i];
                    cfg.file_count += 1;
                }
            }
            break;
        } else {
            writeStderr("zshred: unrecognized option '");
            writeStderr(arg);
            writeStderr("'\n");
            std.process.exit(1);
        }
    }

    if (cfg.file_count == 0) {
        writeStderr("zshred: missing file operand\n");
        writeStderr("Try 'zshred --help' for more information.\n");
        std.process.exit(1);
    }

    var exit_code: u8 = 0;
    for (cfg.files[0..cfg.file_count]) |path| {
        shredFile(path, &cfg) catch {
            exit_code = 1;
        };
    }

    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}
