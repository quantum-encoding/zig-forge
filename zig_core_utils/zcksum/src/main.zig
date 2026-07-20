//! zcksum - Compute CRC checksum and byte counts
//!
//! POSIX-compatible cksum implementation in Zig.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

// libc strerror is not surfaced by std.c; declare it directly so open()/read()
// diagnostics carry the real system message (matching GNU, which also uses
// strerror): ENOENT -> "No such file or directory", EACCES -> "Permission
// denied", EISDIR -> "Is a directory", etc.
extern "c" fn strerror(errnum: c_int) [*:0]const u8;

fn errnoValue() c_int {
    return libc._errno().*;
}

// POSIX CRC-32 table (polynomial 0x04C11DB7, MSB first)
const crc_table = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u32 = undefined;
    for (0..256) |i| {
        var crc: u32 = @as(u32, @intCast(i)) << 24;
        for (0..8) |_| {
            if (crc & 0x80000000 != 0) {
                crc = (crc << 1) ^ 0x04C11DB7;
            } else {
                crc <<= 1;
            }
        }
        table[i] = crc;
    }
    break :blk table;
};

// Write all bytes, looping over short/interrupted writes. A checksum tool must
// never emit a partial line and report success, so a real write error aborts.
fn writeAll(fd: c_int, data: []const u8) void {
    var written: usize = 0;
    while (written < data.len) {
        const n = libc.write(fd, data[written..].ptr, data.len - written);
        if (n < 0) {
            const e: libc.E = @enumFromInt(errnoValue());
            if (e == .INTR or e == .AGAIN) continue;
            return; // unrecoverable; nothing more we can do on this fd
        }
        if (n == 0) return;
        written += @intCast(n);
    }
}

fn writeStdout(data: []const u8) void {
    writeAll(libc.STDOUT_FILENO, data);
}

fn writeStderr(data: []const u8) void {
    writeAll(libc.STDERR_FILENO, data);
}

fn printUsage() void {
    const usage =
        \\Usage: zcksum [FILE]...
        \\Print CRC checksum and byte counts of each FILE.
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\Options:
        \\      --help     Display this help and exit
        \\      --version  Output version information and exit
        \\
    ;
    // GNU cksum writes --help/--version to stdout, not stderr.
    writeStdout(usage);
}

fn printVersion() void {
    writeStdout("zcksum " ++ VERSION ++ "\n");
}

const Result = struct { crc: u32, len: u64 };

// Returns null on a read() error, storing the errno in `err_out`. A negative
// read return (EIO, EISDIR, EFAULT, ...) is NOT treated as EOF: doing so would
// fold in the truncated length and print a plausible-but-wrong CRC with exit 0.
// EINTR/EAGAIN are retried.
fn computeCksum(fd: c_int, err_out: *c_int) ?Result {
    var crc: u32 = 0;
    var total_len: u64 = 0;
    var buf: [65536]u8 = undefined;

    while (true) {
        const n_ret = libc.read(fd, &buf, buf.len);
        if (n_ret < 0) {
            const e: libc.E = @enumFromInt(errnoValue());
            if (e == .INTR or e == .AGAIN) continue;
            err_out.* = @intFromEnum(e);
            return null;
        }
        if (n_ret == 0) break; // true EOF
        const n: usize = @intCast(n_ret);

        for (buf[0..n]) |byte| {
            crc = crc_table[((crc >> 24) ^ byte) & 0xFF] ^ (crc << 8);
        }
        total_len += n;
    }

    // Fold in the length (POSIX requirement) - process length bytes
    var len = total_len;
    while (len > 0) {
        crc = crc_table[((crc >> 24) ^ @as(u8, @truncate(len))) & 0xFF] ^ (crc << 8);
        len >>= 8;
    }

    return .{ .crc = ~crc, .len = total_len };
}

fn printResult(crc: u32, len: u64, name: ?[]const u8) void {
    var buf: [64]u8 = undefined;

    const crc_str = std.fmt.bufPrint(&buf, "{d}", .{crc}) catch "?";
    writeStdout(crc_str);
    writeStdout(" ");

    const len_str = std.fmt.bufPrint(&buf, "{d}", .{len}) catch "?";
    writeStdout(len_str);

    if (name) |n| {
        writeStdout(" ");
        writeStdout(n);
    }
    writeStdout("\n");
}

fn reportError(name: []const u8, err: c_int) void {
    writeStderr("zcksum: ");
    writeStderr(name);
    writeStderr(": ");
    writeStderr(std.mem.span(strerror(err)));
    writeStderr("\n");
}

fn processFile(path: ?[]const u8) bool {
    const fd: c_int = if (path) |p| blk: {
        if (std.mem.eql(u8, p, "-")) break :blk 0;
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{p}) catch {
            writeStderr("zcksum: path too long\n");
            return false;
        };
        const fd_ret = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd_ret < 0) {
            // Report the real reason (Permission denied / Is a directory /
            // No such file or directory), not a hardcoded ENOENT message.
            reportError(p, errnoValue());
            return false;
        }
        break :blk fd_ret;
    } else 0;
    defer {
        if (path != null and !std.mem.eql(u8, path.?, "-")) _ = libc.close(fd);
    }

    var err_code: c_int = 0;
    const result = computeCksum(fd, &err_code) orelse {
        reportError(path orelse "-", err_code);
        return false;
    };
    printResult(result.crc, result.len, path);
    return true;
}

// GNU prints `cksum: invalid option -- 'x'` (short) or
// `cksum: unrecognized option '--foo'` (long), then a Try-help line, exit 1.
fn invalidOption(arg: []const u8) noreturn {
    if (std.mem.startsWith(u8, arg, "--")) {
        writeStderr("zcksum: unrecognized option '");
        writeStderr(arg);
        writeStderr("'\n");
    } else {
        writeStderr("zcksum: invalid option -- '");
        // report the first offending short-option character
        writeStderr(arg[1..2]);
        writeStderr("'\n");
    }
    writeStderr("Try 'zcksum --help' for more information.\n");
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    var files_found = false;
    var exit_code: u8 = 0;
    var opts_done = false;

    while (args_iter.next()) |arg| {
        if (!opts_done and std.mem.eql(u8, arg, "--")) {
            opts_done = true;
            continue;
        }
        if (!opts_done and arg.len > 1 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--help")) {
                printUsage();
                return;
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                return;
            } else {
                // Unknown option: diagnose and exit 1 (do not treat as a path).
                invalidOption(arg);
            }
        } else {
            files_found = true;
            if (!processFile(arg)) {
                exit_code = 1;
            }
        }
    }

    if (!files_found) {
        if (!processFile(null)) {
            exit_code = 1;
        }
    }

    if (exit_code != 0) {
        std.process.exit(exit_code);
    }
}
