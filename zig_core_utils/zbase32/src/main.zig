//! zbase32 - Base32 encode/decode
//!
//! High-performance base32 encoding/decoding in Zig.
//!
//! Streaming-correct: encode buffers the <=4 leftover bytes between read()
//! chunks and only emits '=' padding at true EOF; decode carries its 8-char
//! group / pad-count state across chunks. This matters because read() is not
//! guaranteed to fill the buffer (pipes, terminals, FIFOs) and GNU base32
//! emits 76-column wrapped output by default, so decoding real base32 of any
//! size crosses read() boundaries mid-group.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

extern "c" fn strerror(errnum: c_int) [*:0]const u8;

const b32_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

const b32_decode_table = blk: {
    var table: [256]u8 = undefined;
    for (&table) |*v| v.* = 0xFF;
    for (b32_chars, 0..) |c, i| {
        table[c] = @intCast(i);
        // GNU base32 is case-sensitive: lowercase is NOT alphabet. Without
        // -i it is "invalid input" (exit 1); with -i it is ignored as
        // garbage. Do NOT populate lowercase entries.
    }
    table['='] = 0;
    break :blk table;
};

const Config = struct {
    decode: bool = false,
    wrap: usize = 76,
    ignore_garbage: bool = false,
    file: ?[]const u8 = null,
};

fn errnoMsg() []const u8 {
    return std.mem.span(strerror(libc._errno().*));
}

/// write() all of `data`, retrying on EINTR and advancing past short writes.
/// A real write error is fatal (matches GNU, which aborts the transfer).
fn writeAll(fd: c_int, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = libc.write(fd, data.ptr + off, data.len - off);
        if (n < 0) {
            const e = libc._errno().*;
            if (e == @intFromEnum(std.c.E.INTR)) continue;
            const msg = errnoMsg();
            writeRaw(libc.STDERR_FILENO, "zbase32: write error: ");
            writeRaw(libc.STDERR_FILENO, msg);
            writeRaw(libc.STDERR_FILENO, "\n");
            std.process.exit(1);
        }
        if (n == 0) break;
        off += @intCast(n);
    }
}

/// Best-effort raw write for diagnostics (no recursion into error handling).
fn writeRaw(fd: c_int, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = libc.write(fd, data.ptr + off, data.len - off);
        if (n <= 0) {
            const e = libc._errno().*;
            if (n < 0 and e == @intFromEnum(std.c.E.INTR)) continue;
            break;
        }
        off += @intCast(n);
    }
}

fn writeStdout(data: []const u8) void {
    writeAll(libc.STDOUT_FILENO, data);
}

fn writeStderr(data: []const u8) void {
    writeRaw(libc.STDERR_FILENO, data);
}

const usage_text =
    \\Usage: zbase32 [OPTION]... [FILE]
    \\Base32 encode or decode FILE, or standard input, to standard output.
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

fn printUsage() void {
    // GNU writes --help to STDOUT.
    writeStdout(usage_text);
}

fn printVersion() void {
    // GNU writes --version to STDOUT.
    writeStdout("zbase32 " ++ VERSION ++ "\n");
}

fn tryHelp() void {
    writeStderr("Try 'zbase32 --help' for more information.\n");
}

/// Encode exactly 5 input bytes into 8 base32 chars (no padding).
inline fn encodeGroup5(in: [5]u8, out: *[8]u8) void {
    out[0] = b32_chars[in[0] >> 3];
    out[1] = b32_chars[((in[0] & 0x07) << 2) | (in[1] >> 6)];
    out[2] = b32_chars[(in[1] >> 1) & 0x1F];
    out[3] = b32_chars[((in[1] & 0x01) << 4) | (in[2] >> 4)];
    out[4] = b32_chars[((in[2] & 0x0F) << 1) | (in[3] >> 7)];
    out[5] = b32_chars[(in[3] >> 2) & 0x1F];
    out[6] = b32_chars[((in[3] & 0x03) << 3) | (in[4] >> 5)];
    out[7] = b32_chars[in[4] & 0x1F];
}

/// Encode a final partial group of 1..4 bytes into 8 chars WITH '=' padding.
fn encodeFinal(in: []const u8, out: *[8]u8) void {
    const b0 = in[0];
    out[0] = b32_chars[b0 >> 3];
    switch (in.len) {
        1 => {
            out[1] = b32_chars[(b0 & 0x07) << 2];
            @memset(out[2..8], '=');
        },
        2 => {
            const b1 = in[1];
            out[1] = b32_chars[((b0 & 0x07) << 2) | (b1 >> 6)];
            out[2] = b32_chars[(b1 >> 1) & 0x1F];
            out[3] = b32_chars[(b1 & 0x01) << 4];
            @memset(out[4..8], '=');
        },
        3 => {
            const b1 = in[1];
            const b2 = in[2];
            out[1] = b32_chars[((b0 & 0x07) << 2) | (b1 >> 6)];
            out[2] = b32_chars[(b1 >> 1) & 0x1F];
            out[3] = b32_chars[((b1 & 0x01) << 4) | (b2 >> 4)];
            out[4] = b32_chars[(b2 & 0x0F) << 1];
            @memset(out[5..8], '=');
        },
        4 => {
            const b1 = in[1];
            const b2 = in[2];
            const b3 = in[3];
            out[1] = b32_chars[((b0 & 0x07) << 2) | (b1 >> 6)];
            out[2] = b32_chars[(b1 >> 1) & 0x1F];
            out[3] = b32_chars[((b1 & 0x01) << 4) | (b2 >> 4)];
            out[4] = b32_chars[((b2 & 0x0F) << 1) | (b3 >> 7)];
            out[5] = b32_chars[(b3 >> 2) & 0x1F];
            out[6] = b32_chars[(b3 & 0x03) << 3];
            out[7] = '=';
        },
        else => unreachable,
    }
}

const Encoder = struct {
    wrap: usize,
    col: usize = 0,
    pending: [4]u8 = undefined,
    pending_len: usize = 0,

    /// Emit encoded chars honoring the wrap column, carrying `col` across calls.
    fn emit(self: *Encoder, bytes: []const u8) void {
        if (self.wrap == 0) {
            writeStdout(bytes);
            return;
        }
        var i: usize = 0;
        while (i < bytes.len) {
            const room = self.wrap - self.col;
            const chunk = @min(room, bytes.len - i);
            writeStdout(bytes[i .. i + chunk]);
            i += chunk;
            self.col += chunk;
            if (self.col >= self.wrap) {
                writeStdout("\n");
                self.col = 0;
            }
        }
    }

    fn update(self: *Encoder, data_in: []const u8) void {
        var data = data_in;
        // read_buf is 40000 bytes -> at most 8000 groups -> 64000 chars,
        // plus one pending-completion group (8) -> 64008. 65536 is ample.
        var enc: [65536]u8 = undefined;
        var out_idx: usize = 0;

        // Complete a carried-over partial group first.
        if (self.pending_len > 0) {
            const need = 5 - self.pending_len;
            if (data.len < need) {
                @memcpy(self.pending[self.pending_len .. self.pending_len + data.len], data);
                self.pending_len += data.len;
                return;
            }
            var grp: [5]u8 = undefined;
            @memcpy(grp[0..self.pending_len], self.pending[0..self.pending_len]);
            @memcpy(grp[self.pending_len..5], data[0..need]);
            encodeGroup5(grp, enc[out_idx..][0..8]);
            out_idx += 8;
            data = data[need..];
            self.pending_len = 0;
        }

        // Process full 5-byte groups directly.
        var i: usize = 0;
        while (i + 5 <= data.len) : (i += 5) {
            encodeGroup5(data[i..][0..5].*, enc[out_idx..][0..8]);
            out_idx += 8;
        }

        // Stash the <=4 leftover bytes for the next chunk / finish().
        const rem = data.len - i;
        @memcpy(self.pending[0..rem], data[i..]);
        self.pending_len = rem;

        if (out_idx > 0) self.emit(enc[0..out_idx]);
    }

    fn finish(self: *Encoder) void {
        if (self.pending_len > 0) {
            var out: [8]u8 = undefined;
            encodeFinal(self.pending[0..self.pending_len], &out);
            self.emit(&out);
            self.pending_len = 0;
        }
        if (self.wrap > 0 and self.col > 0) {
            writeStdout("\n");
            self.col = 0;
        }
    }
};

const Decoder = struct {
    ignore_garbage: bool,
    buf: [8]u8 = undefined,
    buf_idx: usize = 0,
    pad_count: usize = 0,

    /// Decode a chunk; returns false on invalid input (no -i). State (buf /
    /// buf_idx / pad_count) persists across chunks so a group split at a read
    /// boundary is not silently dropped.
    fn update(self: *Decoder, input: []const u8) bool {
        var dec: [65536]u8 = undefined;
        var out_idx: usize = 0;

        for (input) |c| {
            if (c == '\n' or c == '\r' or c == ' ' or c == '\t') continue;
            if (c == '=') {
                self.pad_count += 1;
                self.buf[self.buf_idx] = 0;
                self.buf_idx += 1;
            } else {
                const val = b32_decode_table[c];
                if (val == 0xFF) {
                    if (self.ignore_garbage) continue;
                    if (out_idx > 0) writeStdout(dec[0..out_idx]);
                    return false;
                }
                self.buf[self.buf_idx] = val;
                self.buf_idx += 1;
            }

            if (self.buf_idx == 8) {
                const b = &self.buf;
                dec[out_idx] = (b[0] << 3) | (b[1] >> 2);
                out_idx += 1;
                if (self.pad_count < 6) {
                    dec[out_idx] = (b[1] << 6) | (b[2] << 1) | (b[3] >> 4);
                    out_idx += 1;
                }
                if (self.pad_count < 4) {
                    dec[out_idx] = (b[3] << 4) | (b[4] >> 1);
                    out_idx += 1;
                }
                if (self.pad_count < 3) {
                    dec[out_idx] = (b[4] << 7) | (b[5] << 2) | (b[6] >> 3);
                    out_idx += 1;
                }
                if (self.pad_count < 1) {
                    dec[out_idx] = (b[6] << 5) | b[7];
                    out_idx += 1;
                }
                self.buf_idx = 0;
                self.pad_count = 0;
            }
        }

        if (out_idx > 0) writeStdout(dec[0..out_idx]);
        return true;
    }
};

/// Read a chunk; returns bytes read, 0 at EOF. On a read error prints a GNU-
/// style "read error: <strerror>" diagnostic and exits 1 (never confused with
/// EOF).
fn readChunk(fd: c_int, buf: []u8) usize {
    while (true) {
        const n = libc.read(fd, buf.ptr, buf.len);
        if (n < 0) {
            const e = libc._errno().*;
            if (e == @intFromEnum(std.c.E.INTR)) continue;
            const msg = errnoMsg();
            writeStderr("zbase32: read error: ");
            writeStderr(msg);
            writeStderr("\n");
            std.process.exit(1);
        }
        return @intCast(n);
    }
}

fn processEncode(fd: c_int, wrap: usize) void {
    var read_buf: [40000]u8 = undefined; // multiple of 5
    var enc = Encoder{ .wrap = wrap };

    while (true) {
        const n = readChunk(fd, &read_buf);
        if (n == 0) break;
        enc.update(read_buf[0..n]);
    }
    enc.finish();
}

fn processDecode(fd: c_int, ignore_garbage: bool) bool {
    var read_buf: [65536]u8 = undefined;
    var dec = Decoder{ .ignore_garbage = ignore_garbage };

    while (true) {
        const n = readChunk(fd, &read_buf);
        if (n == 0) break;
        if (!dec.update(read_buf[0..n])) {
            writeStderr("zbase32: invalid input\n");
            return false;
        }
    }
    return true;
}

/// Parse a wrap-size argument. Returns null on non-numeric / overflow, which
/// the caller turns into GNU's "invalid wrap size" diagnostic (exit 1).
fn parseWrap(s: []const u8) ?usize {
    if (s.len == 0) return null;
    return std.fmt.parseInt(usize, s, 10) catch null;
}

fn invalidWrap(val: []const u8) noreturn {
    writeStderr("zbase32: invalid wrap size: '");
    writeStderr(val);
    writeStderr("'\n");
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    var cfg = Config{};

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    var no_more_opts = false;

    while (args_iter.next()) |arg| {
        if (no_more_opts or arg.len == 0 or arg[0] != '-' or std.mem.eql(u8, arg, "-")) {
            // Operand (file). "-" means stdin.
            if (std.mem.eql(u8, arg, "-")) {
                cfg.file = null;
            } else {
                cfg.file = arg;
            }
            continue;
        }

        // "--" ends option processing.
        if (std.mem.eql(u8, arg, "--")) {
            no_more_opts = true;
            continue;
        }

        // Long options.
        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.eql(u8, arg, "--help")) {
                printUsage();
                return;
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                return;
            } else if (std.mem.eql(u8, arg, "--decode")) {
                cfg.decode = true;
            } else if (std.mem.eql(u8, arg, "--ignore-garbage")) {
                cfg.ignore_garbage = true;
            } else if (std.mem.eql(u8, arg, "--wrap")) {
                const val = args_iter.next() orelse invalidWrap("");
                cfg.wrap = parseWrap(val) orelse invalidWrap(val);
            } else if (std.mem.startsWith(u8, arg, "--wrap=")) {
                const val = arg[7..];
                cfg.wrap = parseWrap(val) orelse invalidWrap(val);
            } else {
                writeStderr("zbase32: unrecognized option '");
                writeStderr(arg);
                writeStderr("'\n");
                tryHelp();
                std.process.exit(1);
            }
            continue;
        }

        // Short-option cluster: -d, -i, -w, and combinations like -di, -w4.
        var j: usize = 1;
        while (j < arg.len) : (j += 1) {
            switch (arg[j]) {
                'd' => cfg.decode = true,
                'i' => cfg.ignore_garbage = true,
                'w' => {
                    // Attached value (-w4) or the next argument (-w 4).
                    if (j + 1 < arg.len) {
                        const val = arg[j + 1 ..];
                        cfg.wrap = parseWrap(val) orelse invalidWrap(val);
                    } else {
                        const val = args_iter.next() orelse invalidWrap("");
                        cfg.wrap = parseWrap(val) orelse invalidWrap(val);
                    }
                    break; // rest of cluster consumed as the value
                },
                else => {
                    const ch = [_]u8{arg[j]};
                    writeStderr("zbase32: invalid option -- '");
                    writeStderr(&ch);
                    writeStderr("'\n");
                    tryHelp();
                    std.process.exit(1);
                },
            }
        }
    }

    const fd: c_int = if (cfg.file) |path| blk: {
        if (std.mem.eql(u8, path, "-")) break :blk 0;
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch {
            writeStderr("zbase32: path too long\n");
            std.process.exit(1);
        };
        const fd_ret = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd_ret < 0) {
            // Report the real errno (ENOENT / EACCES / EISDIR / ELOOP / ...).
            const msg = errnoMsg();
            writeStderr("zbase32: ");
            writeStderr(path);
            writeStderr(": ");
            writeStderr(msg);
            writeStderr("\n");
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
