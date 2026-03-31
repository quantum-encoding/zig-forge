//! zbase64 - Base64 encode/decode
//!
//! High-performance base64 encoding/decoding in Zig.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

const b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

const b64_decode_table = blk: {
    var table: [256]u8 = undefined;
    for (&table) |*v| v.* = 0xFF;
    for (b64_chars, 0..) |c, i| table[c] = @intCast(i);
    table['='] = 0;
    break :blk table;
};

const Config = struct {
    decode: bool = false,
    wrap: usize = 76,
    ignore_garbage: bool = false,
    file: ?[]const u8 = null,
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zbase64 [OPTION]... [FILE]
        \\Base64 encode or decode FILE, or standard input, to standard output.
        \\
        \\Options:
        \\  -d, --decode          Decode data
        \\  -i, --ignore-garbage  When decoding, ignore non-alphabet characters
        \\  -w, --wrap=COLS       Wrap encoded lines after COLS chars (default 76, 0 to disable)
        \\      --help            Display this help and exit
        \\      --version         Output version information and exit
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zbase64 " ++ VERSION ++ "\n");
}

fn encode(input: []const u8, output: []u8) usize {
    var out_idx: usize = 0;
    var i: usize = 0;

    while (i + 2 < input.len) {
        const b0 = input[i];
        const b1 = input[i + 1];
        const b2 = input[i + 2];

        output[out_idx] = b64_chars[b0 >> 2];
        output[out_idx + 1] = b64_chars[((b0 & 0x03) << 4) | (b1 >> 4)];
        output[out_idx + 2] = b64_chars[((b1 & 0x0F) << 2) | (b2 >> 6)];
        output[out_idx + 3] = b64_chars[b2 & 0x3F];

        i += 3;
        out_idx += 4;
    }

    // Handle remaining bytes
    const remaining = input.len - i;
    if (remaining == 1) {
        const b0 = input[i];
        output[out_idx] = b64_chars[b0 >> 2];
        output[out_idx + 1] = b64_chars[(b0 & 0x03) << 4];
        output[out_idx + 2] = '=';
        output[out_idx + 3] = '=';
        out_idx += 4;
    } else if (remaining == 2) {
        const b0 = input[i];
        const b1 = input[i + 1];
        output[out_idx] = b64_chars[b0 >> 2];
        output[out_idx + 1] = b64_chars[((b0 & 0x03) << 4) | (b1 >> 4)];
        output[out_idx + 2] = b64_chars[(b1 & 0x0F) << 2];
        output[out_idx + 3] = '=';
        out_idx += 4;
    }

    return out_idx;
}

fn decode(input: []const u8, output: []u8, ignore_garbage: bool) ?usize {
    var out_idx: usize = 0;
    var buf: [4]u8 = undefined;
    var buf_idx: usize = 0;

    for (input) |c| {
        if (c == '\n' or c == '\r' or c == ' ' or c == '\t') continue;

        const val = b64_decode_table[c];
        if (val == 0xFF) {
            if (ignore_garbage) continue;
            return null;
        }

        buf[buf_idx] = val;
        buf_idx += 1;

        if (buf_idx == 4) {
            output[out_idx] = (buf[0] << 2) | (buf[1] >> 4);
            out_idx += 1;

            if (input[buf_idx - 2] != '=' and buf[2] != 0xFF) {
                output[out_idx] = (buf[1] << 4) | (buf[2] >> 2);
                out_idx += 1;
            }
            if (input[buf_idx - 1] != '=' and buf[3] != 0xFF) {
                output[out_idx] = (buf[2] << 6) | buf[3];
                out_idx += 1;
            }
            buf_idx = 0;
        }
    }

    return out_idx;
}

fn processEncode(fd: c_int, wrap: usize) void {
    var read_buf: [48000]u8 = undefined; // Multiple of 3 for clean encoding
    var enc_buf: [65536]u8 = undefined;
    var col: usize = 0;

    while (true) {
        const n_ret = libc.read(fd, &read_buf, read_buf.len);
        if (n_ret <= 0) break;
        const n: usize = @intCast(n_ret);

        const enc_len = encode(read_buf[0..n], &enc_buf);

        if (wrap == 0) {
            writeStdout(enc_buf[0..enc_len]);
        } else {
            var i: usize = 0;
            while (i < enc_len) {
                const remaining_in_line = wrap - col;
                const chunk = @min(remaining_in_line, enc_len - i);
                writeStdout(enc_buf[i .. i + chunk]);
                i += chunk;
                col += chunk;

                if (col >= wrap) {
                    writeStdout("\n");
                    col = 0;
                }
            }
        }
    }

    if (wrap > 0 and col > 0) {
        writeStdout("\n");
    }
}

fn processDecode(fd: c_int, ignore_garbage: bool) bool {
    var read_buf: [65536]u8 = undefined;
    var dec_buf: [49152]u8 = undefined;

    while (true) {
        const n_ret = libc.read(fd, &read_buf, read_buf.len);
        if (n_ret <= 0) break;
        const n: usize = @intCast(n_ret);

        if (decode(read_buf[0..n], &dec_buf, ignore_garbage)) |dec_len| {
            writeStdout(dec_buf[0..dec_len]);
        } else {
            writeStderr("zbase64: invalid input\n");
            return false;
        }
    }

    return true;
}

fn parseNumber(s: []const u8) ?usize {
    var result: usize = 0;
    for (s) |c| {
        if (c >= '0' and c <= '9') {
            result = result * 10 + (c - '0');
        } else return null;
    }
    return result;
}

pub fn main(init: std.process.Init) !void {
    var cfg = Config{};

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    var next_is_wrap = false;
    while (args_iter.next()) |arg| {
        if (next_is_wrap) {
            cfg.wrap = parseNumber(arg) orelse 76;
            next_is_wrap = false;
            continue;
        }

        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--decode")) {
            cfg.decode = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-garbage")) {
            cfg.ignore_garbage = true;
        } else if (std.mem.eql(u8, arg, "-w")) {
            next_is_wrap = true;
        } else if (std.mem.startsWith(u8, arg, "--wrap=")) {
            cfg.wrap = parseNumber(arg[7..]) orelse 76;
        } else if (arg.len > 0 and arg[0] != '-') {
            cfg.file = arg;
        } else if (std.mem.eql(u8, arg, "-")) {
            cfg.file = null;
        }
    }

    const fd: c_int = if (cfg.file) |path| blk: {
        if (std.mem.eql(u8, path, "-")) break :blk 0;
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch {
            writeStderr("zbase64: path too long\n");
            std.process.exit(1);
        };
        const fd_ret = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd_ret < 0) {
            writeStderr("zbase64: ");
            writeStderr(path);
            writeStderr(": No such file or directory\n");
            std.process.exit(1);
        }
        break :blk fd_ret;
    } else 0;
    defer {
        if (cfg.file != null and !std.mem.eql(u8, cfg.file.?, "-")) _ = libc.close(fd);
    }

    if (cfg.decode) {
        if (!processDecode(fd, cfg.ignore_garbage)) {
            std.process.exit(1);
        }
    } else {
        processEncode(fd, cfg.wrap);
    }
}
