//! zcksum - Compute CRC checksum and byte counts
//!
//! POSIX-compatible cksum implementation in Zig.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

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

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
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
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zcksum " ++ VERSION ++ "\n");
}

fn computeCksum(fd: c_int) struct { crc: u32, len: u64 } {
    var crc: u32 = 0;
    var total_len: u64 = 0;
    var buf: [65536]u8 = undefined;

    while (true) {
        const n_ret = libc.read(fd, &buf, buf.len);
        if (n_ret <= 0) break;
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
            writeStderr("zcksum: ");
            writeStderr(p);
            writeStderr(": No such file or directory\n");
            return false;
        }
        break :blk fd_ret;
    } else 0;
    defer {
        if (path != null and !std.mem.eql(u8, path.?, "-")) _ = libc.close(fd);
    }

    const result = computeCksum(fd);
    printResult(result.crc, result.len, path);
    return true;
}

pub fn main(init: std.process.Init) !void {
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    var files_found = false;
    var exit_code: u8 = 0;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
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
