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
extern "c" fn fstat(fd: c_int, buf: *Stat) c_int;

const Config = struct {
    iterations: u32 = 3,
    remove: bool = false,
    zero: bool = false,
    verbose: bool = false,
    force: bool = false,
    exact: bool = false,
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
    writeStdout(usage);
}

fn printVersion() void {
    writeStdout("zshred " ++ VERSION ++ "\n");
}

fn rngFatal() noreturn {
    // A secure-wipe tool must NEVER fall back to a predictable stream: if the
    // OS entropy source fails we abort the pass rather than write guessable
    // "random" data (the old code fell back to a time()-seeded LCG). Better to
    // leave the file un-shredded and error than to give a false guarantee.
    writeStderr("zshred: fatal: could not obtain random data from the OS\n");
    std.process.exit(1);
}

fn getRandom(buf: []u8) void {
    // Cross-platform OS CSPRNG.
    //
    // The previous implementation called std.os.linux.getrandom directly on
    // ALL platforms; on macOS that issues a Linux-ABI raw syscall that returns
    // a non-negative value WITHOUT filling the buffer, so every "random" pass
    // wrote the uninitialized stack buffer (a constant 0xAA in Debug, zeros in
    // ReleaseFast) to disk — voiding the entire security guarantee. See the
    // gnu_parity_test.zig "random overwrite is non-constant" anchor.
    switch (builtin.os.tag) {
        .linux => {
            // getrandom(2) may return short; loop until the buffer is full.
            var off: usize = 0;
            while (off < buf.len) {
                const rc = std.os.linux.getrandom(buf[off..].ptr, buf.len - off, 0);
                const signed: isize = @bitCast(rc);
                if (signed <= 0) rngFatal();
                off += @intCast(signed);
            }
        },
        // arc4random_buf is a CSPRNG on Darwin/BSD, cannot fail, no length cap.
        else => std.c.arc4random_buf(buf.ptr, buf.len),
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

/// Write exactly `len` bytes from `buf` to `fd`, advancing past short writes.
/// Treats a return of 0 as an error (it is never a success and previously
/// spun the loop forever), and resumes from the correct buffer offset instead
/// of re-writing the head bytes on every partial write.
fn writeFull(fd: c_int, buf: []const u8, len: usize) !void {
    var off: usize = 0;
    while (off < len) {
        const w = write(fd, buf[off..].ptr, len - off);
        if (w <= 0) return error.WriteFailed;
        off += @intCast(w);
    }
}

fn roundUpToBlock(size: u64, blksize: u64) u64 {
    if (blksize == 0) return size;
    return ((size + blksize - 1) / blksize) * blksize;
}

fn shredFile(path: []const u8, cfg: *const Config) !void {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.PathTooLong;

    // Open FIRST, then stat via the fd. Doing stat(path) then open(path) as two
    // separate name resolutions is a TOCTOU window (an attacker could swap the
    // target between the two); fstat(fd) measures exactly the object we will
    // overwrite. Under -f we only chmod-and-retry when the initial open fails,
    // rather than unconditionally chmod'ing a path we have not yet opened.
    var fd = open(path_z, O_WRONLY, 0);
    if (fd < 0 and cfg.force) {
        _ = chmod(path_z, 0o600);
        fd = open(path_z, O_WRONLY, 0);
    }
    if (fd < 0) {
        writeStderr("zshred: cannot open '");
        writeStderr(path);
        writeStderr("' for writing\n");
        return error.OpenFailed;
    }
    defer _ = close(fd);

    // Get file size from the opened descriptor.
    var stat_buf: Stat = undefined;
    if (fstat(fd, &stat_buf) != 0) {
        writeStderr("zshred: cannot stat '");
        writeStderr(path);
        writeStderr("'\n");
        return error.StatFailed;
    }

    const file_size: u64 = @intCast(stat_buf.size);
    // GNU shred overwrites up to the next filesystem-block boundary by default
    // to scrub tail slack; -x/--exact disables that and writes only file_size.
    const blksize: u64 = if (stat_buf.st_blksize > 0) @intCast(stat_buf.st_blksize) else 0;
    const write_size: u64 = if (cfg.exact) file_size else roundUpToBlock(file_size, blksize);
    if (file_size == 0) {
        if (cfg.verbose) {
            writeStderr("zshred: ");
            writeStderr(path);
            writeStderr(": empty file\n");
        }
        if (cfg.remove) {
            _ = close(fd);
            _ = unlink(path_z);
        }
        return;
    }

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

        var remaining = write_size;
        while (remaining > 0) {
            const chunk = @min(remaining, buf.len);
            getRandom(buf[0..chunk]);

            writeFull(fd, &buf, chunk) catch {
                if (cfg.verbose) writeStderr(" FAILED\n");
                return error.WriteFailed;
            };
            remaining -= chunk;
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

        var remaining = write_size;
        while (remaining > 0) {
            const chunk = @min(remaining, buf.len);
            writeFull(fd, &buf, chunk) catch {
                if (cfg.verbose) writeStderr(" FAILED\n");
                return error.WriteFailed;
            };
            remaining -= chunk;
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
    // std.fmt.parseInt rejects empty strings, non-digits, and — critically —
    // values that overflow u32, returning error.Overflow instead of the raw
    // `result * 10 + d` u32 wrap/panic the hand-rolled loop performed. GNU
    // shred likewise rejects a pass count that overflows its integer type
    // ("invalid number of passes: 'N': Value too large to be stored...").
    return std.fmt.parseInt(u32, s, 10) catch null;
}

fn oom() noreturn {
    writeStderr("zshred: out of memory\n");
    std.process.exit(1);
}

pub fn main(init: std.process.Init) void {
    var cfg = Config{};
    const alloc = std.heap.page_allocator;

    // Collect args into a growable list — no fixed cap. The previous [256]
    // arg / [64] file caps silently DROPPED operands past the limit, so
    // `zshred *` on a large glob would report success while leaving files
    // untouched. GNU shred processes every operand; so must we.
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var files_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        args_list.append(alloc, arg) catch oom();
    }
    const args = args_list.items;

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
                    writeStderr("zshred: invalid number of passes\n");
                    std.process.exit(1);
                }
            }
        } else if (std.mem.startsWith(u8, arg, "--iterations=")) {
            const val = arg[13..];
            if (parseInt(val)) |n| {
                cfg.iterations = n;
            } else {
                writeStderr("zshred: invalid number of passes\n");
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "-n")) {
            const val = arg[2..];
            if (parseInt(val)) |n| {
                cfg.iterations = n;
            } else {
                writeStderr("zshred: invalid number of passes\n");
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--")) {
            // Rest are files
            i += 1;
            while (i < args.len) : (i += 1) {
                files_list.append(alloc, args[i]) catch oom();
            }
            break;
        } else if (arg.len > 0 and arg[0] != '-') {
            files_list.append(alloc, arg) catch oom();
        } else {
            writeStderr("zshred: unrecognized option '");
            writeStderr(arg);
            writeStderr("'\n");
            std.process.exit(1);
        }
    }

    if (files_list.items.len == 0) {
        writeStderr("zshred: missing file operand\n");
        writeStderr("Try 'zshred --help' for more information.\n");
        std.process.exit(1);
    }

    var exit_code: u8 = 0;
    for (files_list.items) |path| {
        shredFile(path, &cfg) catch {
            exit_code = 1;
        };
    }

    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}
