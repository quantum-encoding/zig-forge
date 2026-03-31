//! zfactor - Print prime factors
//!
//! High-performance prime factorization in Zig.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zfactor [NUMBER]...
        \\Print the prime factors of each specified integer NUMBER.
        \\
        \\With no arguments, read numbers from standard input.
        \\
        \\Options:
        \\      --help     Display this help and exit
        \\      --version  Output version information and exit
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zfactor " ++ VERSION ++ "\n");
}

fn printNumber(n: u128, buf: []u8) void {
    const s = std.fmt.bufPrint(buf, "{d}", .{n}) catch "?";
    writeStdout(s);
}

fn factorize(n: u128) void {
    var buf: [48]u8 = undefined;

    printNumber(n, &buf);
    writeStdout(":");

    if (n == 0) {
        writeStdout("\n");
        return;
    }

    if (n == 1) {
        writeStdout("\n");
        return;
    }

    var num = n;

    // Factor out 2s
    while (num % 2 == 0) {
        writeStdout(" 2");
        num /= 2;
    }

    // Factor out odd numbers starting from 3
    var factor: u128 = 3;
    while (factor * factor <= num) {
        while (num % factor == 0) {
            writeStdout(" ");
            printNumber(factor, &buf);
            num /= factor;
        }
        factor += 2;
    }

    // If remaining num is > 1, it's a prime factor
    if (num > 1) {
        writeStdout(" ");
        printNumber(num, &buf);
    }

    writeStdout("\n");
}

fn parseNumber(s: []const u8) ?u128 {
    var result: u128 = 0;
    for (s) |c| {
        if (c >= '0' and c <= '9') {
            result = result *| 10 +| (c - '0');
        } else if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            continue;
        } else {
            return null;
        }
    }
    return result;
}

fn trimWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;

    while (start < end and (s[start] == ' ' or s[start] == '\t' or s[start] == '\n' or s[start] == '\r')) {
        start += 1;
    }

    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\n' or s[end - 1] == '\r')) {
        end -= 1;
    }

    return s[start..end];
}

fn processLine(line: []const u8) void {
    const trimmed = trimWhitespace(line);
    if (trimmed.len == 0) return;

    if (parseNumber(trimmed)) |n| {
        factorize(n);
    } else {
        writeStderr("zfactor: '");
        writeStderr(trimmed);
        writeStderr("' is not a valid positive integer\n");
    }
}

fn readStdin() void {
    var buf: [65536]u8 = undefined;
    var line_buf: [256]u8 = undefined;
    var line_len: usize = 0;

    while (true) {
        const n = posix.read(0, &buf) catch break;
        if (n == 0) {
            if (line_len > 0) {
                processLine(line_buf[0..line_len]);
            }
            break;
        }

        for (buf[0..n]) |c| {
            if (c == '\n') {
                processLine(line_buf[0..line_len]);
                line_len = 0;
            } else {
                if (line_len < line_buf.len) {
                    line_buf[line_len] = c;
                    line_len += 1;
                }
            }
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    var numbers_found = false;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else {
            numbers_found = true;
            if (parseNumber(arg)) |n| {
                factorize(n);
            } else {
                writeStderr("zfactor: '");
                writeStderr(arg);
                writeStderr("' is not a valid positive integer\n");
            }
        }
    }

    if (!numbers_found) {
        readStdin();
    }
}
