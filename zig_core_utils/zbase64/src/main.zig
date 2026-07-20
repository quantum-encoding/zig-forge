//! zbase64 - Base64 encode/decode
//!
//! High-performance, GNU-`base64`-compatible encoding/decoding in Zig.
//!
//! Streaming design: encoder carries 0-2 leftover input bytes across reads and
//! only emits '=' padding at end-of-input; decoder carries a partial 4-char
//! group across reads. Decode validation matches GNU coreutils `base64 -d`:
//! only '\n' is skipped by default (all other non-alphabet bytes are errors),
//! `-i`/`--ignore-garbage` skips every non-alphabet byte, '=' is a padding
//! sentinel (never data), excess/misplaced padding and non-canonical trailing
//! bits are rejected.

const std = @import("std");
const libc = std.c;

extern "c" fn strerror(errnum: c_int) [*:0]const u8;

const VERSION = "1.0.0";

const b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

// 0xFF == not a base64 alphabet character. '=' is intentionally left 0xFF here
// and handled as a padding sentinel by the decoder, never as data value 0.
const b64_decode_table = blk: {
    var table: [256]u8 = undefined;
    for (&table) |*v| v.* = 0xFF;
    for (b64_chars, 0..) |c, i| table[c] = @intCast(i);
    break :blk table;
};

const Config = struct {
    decode: bool = false,
    wrap: usize = 76,
    ignore_garbage: bool = false,
    file: ?[]const u8 = null,
};

fn errno() c_int {
    return libc._errno().*;
}

// Tracks whether any write to stdout failed (broken pipe, disk full, ...).
var out_failed: bool = false;

fn writeAll(fd: c_int, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const n = libc.write(fd, data.ptr + off, data.len - off);
        if (n < 0) {
            if (errno() == @intFromEnum(libc.E.INTR)) continue;
            return false;
        }
        if (n == 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn writeStdout(data: []const u8) void {
    if (out_failed) return;
    if (!writeAll(libc.STDOUT_FILENO, data)) out_failed = true;
}

fn writeStderr(data: []const u8) void {
    _ = writeAll(libc.STDERR_FILENO, data);
}

fn printUsage(fd: c_int) void {
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
    _ = writeAll(fd, usage);
}

fn printVersion() void {
    _ = writeAll(libc.STDOUT_FILENO, "zbase64 " ++ VERSION ++ "\n");
}

fn printTryHelp() void {
    writeStderr("Try 'zbase64 --help' for more information.\n");
}

// ---------------------------------------------------------------------------
// Encoder (streaming)
// ---------------------------------------------------------------------------

const EncodeState = struct {
    rem: [3]u8 = undefined,
    rem_len: usize = 0,

    fn triple(b0: u8, b1: u8, b2: u8, out: []u8) void {
        out[0] = b64_chars[b0 >> 2];
        out[1] = b64_chars[((b0 & 0x03) << 4) | (b1 >> 4)];
        out[2] = b64_chars[((b1 & 0x0F) << 2) | (b2 >> 6)];
        out[3] = b64_chars[b2 & 0x3F];
    }

    /// Encode a chunk, carrying 0-2 leftover input bytes into state. Emits no
    /// padding. Returns number of base64 chars written to `out`.
    fn chunk(self: *EncodeState, input: []const u8, out: []u8) usize {
        var out_idx: usize = 0;
        var i: usize = 0;

        // Fill any carried remainder up to a full triple.
        while (self.rem_len > 0 and self.rem_len < 3 and i < input.len) {
            self.rem[self.rem_len] = input[i];
            self.rem_len += 1;
            i += 1;
        }
        if (self.rem_len == 3) {
            triple(self.rem[0], self.rem[1], self.rem[2], out[out_idx..]);
            out_idx += 4;
            self.rem_len = 0;
        }

        // Whole triples straight from the input.
        while (i + 3 <= input.len) {
            triple(input[i], input[i + 1], input[i + 2], out[out_idx..]);
            out_idx += 4;
            i += 3;
        }

        // Stash the 0-2 trailing bytes for the next chunk / final flush.
        while (i < input.len) {
            self.rem[self.rem_len] = input[i];
            self.rem_len += 1;
            i += 1;
        }

        return out_idx;
    }

    /// Flush the final 1-2 leftover bytes with '=' padding.
    fn final(self: *EncodeState, out: []u8) usize {
        if (self.rem_len == 1) {
            const b0 = self.rem[0];
            out[0] = b64_chars[b0 >> 2];
            out[1] = b64_chars[(b0 & 0x03) << 4];
            out[2] = '=';
            out[3] = '=';
            self.rem_len = 0;
            return 4;
        } else if (self.rem_len == 2) {
            const b0 = self.rem[0];
            const b1 = self.rem[1];
            out[0] = b64_chars[b0 >> 2];
            out[1] = b64_chars[((b0 & 0x03) << 4) | (b1 >> 4)];
            out[2] = b64_chars[(b1 & 0x0F) << 2];
            out[3] = '=';
            self.rem_len = 0;
            return 4;
        }
        return 0;
    }
};

fn emitWrapped(data: []const u8, wrap: usize, col: *usize) void {
    if (wrap == 0) {
        writeStdout(data);
        return;
    }
    var i: usize = 0;
    while (i < data.len) {
        const remaining_in_line = wrap - col.*;
        const n = @min(remaining_in_line, data.len - i);
        writeStdout(data[i .. i + n]);
        i += n;
        col.* += n;
        if (col.* >= wrap) {
            writeStdout("\n");
            col.* = 0;
        }
    }
}

fn processEncode(fd: c_int, wrap: usize) bool {
    var read_buf: [48000]u8 = undefined; // multiple of 3
    var enc_buf: [65536]u8 = undefined;
    var col: usize = 0;
    var state = EncodeState{};

    while (true) {
        const n_ret = libc.read(fd, &read_buf, read_buf.len);
        if (n_ret < 0) {
            if (errno() == @intFromEnum(libc.E.INTR)) continue;
            writeStderr("zbase64: read error\n");
            return false;
        }
        if (n_ret == 0) break;
        const n: usize = @intCast(n_ret);

        const enc_len = state.chunk(read_buf[0..n], &enc_buf);
        emitWrapped(enc_buf[0..enc_len], wrap, &col);
        if (out_failed) break;
    }

    // Final padded group + trailing newline.
    if (!out_failed) {
        const enc_len = state.final(&enc_buf);
        if (enc_len > 0) emitWrapped(enc_buf[0..enc_len], wrap, &col);
    }
    if (!out_failed and wrap > 0 and col > 0) writeStdout("\n");

    if (out_failed) {
        writeStderr("zbase64: write error\n");
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Decoder (streaming)
// ---------------------------------------------------------------------------

const DecodeResult = enum { ok, invalid };

const DecodeState = struct {
    quad: [4]u8 = undefined, // sextet values for data positions
    gpos: usize = 0, // position within current 4-char group (0..3)
    pad: usize = 0, // count of '=' seen in current group
    pad_seen: bool = false,

    /// Decode a chunk of base64 text, carrying a partial group across calls.
    /// Bytes are written to `out`; `out_len` is advanced. Returns .invalid on
    /// any malformed input (matching GNU `base64 -d`), having still flushed the
    /// bytes decoded so far.
    fn chunk(
        self: *DecodeState,
        input: []const u8,
        out: []u8,
        out_len: *usize,
        ignore_garbage: bool,
    ) DecodeResult {
        var o = out_len.*;
        defer out_len.* = o;

        for (input) |c| {
            if (c == '\n') continue; // GNU always skips newlines

            if (c == '=') {
                // Padding is only legal at group positions 2 or 3.
                if (self.gpos < 2) return .invalid;
                self.pad += 1;
                self.pad_seen = true;
                self.gpos += 1;
            } else {
                const val = b64_decode_table[c];
                if (val == 0xFF) {
                    if (ignore_garbage) continue;
                    return .invalid;
                }
                if (self.pad_seen) return .invalid; // data after padding
                self.quad[self.gpos] = val;
                self.gpos += 1;
            }

            if (self.gpos == 4) {
                // pad==0 -> 3 bytes, pad==1 -> 2 bytes, pad==2 -> 1 byte.
                out[o] = (self.quad[0] << 2) | (self.quad[1] >> 4);
                o += 1;
                if (self.pad < 2) {
                    out[o] = (self.quad[1] << 4) | (self.quad[2] >> 2);
                    o += 1;
                }
                if (self.pad < 1) {
                    out[o] = (self.quad[2] << 6) | self.quad[3];
                    o += 1;
                }
                // Reject non-canonical trailing bits (GNU does).
                if (self.pad == 2 and (self.quad[1] & 0x0F) != 0) return .invalid;
                if (self.pad == 1 and (self.quad[2] & 0x03) != 0) return .invalid;

                self.gpos = 0;
                self.pad = 0;
                self.pad_seen = false;
            }
        }
        return .ok;
    }

    /// Flush at end-of-input. A trailing partial group of 2 or 3 (unpadded)
    /// chars is decoded; a 1-char tail, or any incomplete padded group, is an
    /// error — matching GNU.
    fn final(self: *DecodeState, out: []u8, out_len: *usize) DecodeResult {
        var o = out_len.*;
        defer out_len.* = o;

        if (self.pad_seen) return .invalid; // incomplete padded group
        switch (self.gpos) {
            0 => return .ok,
            1 => return .invalid,
            2 => {
                out[o] = (self.quad[0] << 2) | (self.quad[1] >> 4);
                o += 1;
                if ((self.quad[1] & 0x0F) != 0) return .invalid;
                return .ok;
            },
            3 => {
                out[o] = (self.quad[0] << 2) | (self.quad[1] >> 4);
                o += 1;
                out[o] = (self.quad[1] << 4) | (self.quad[2] >> 2);
                o += 1;
                if ((self.quad[2] & 0x03) != 0) return .invalid;
                return .ok;
            },
            else => unreachable,
        }
    }
};

fn processDecode(fd: c_int, ignore_garbage: bool) bool {
    var read_buf: [65536]u8 = undefined;
    var dec_buf: [49152]u8 = undefined; // >= 65536*3/4
    var state = DecodeState{};

    while (true) {
        const n_ret = libc.read(fd, &read_buf, read_buf.len);
        if (n_ret < 0) {
            if (errno() == @intFromEnum(libc.E.INTR)) continue;
            writeStderr("zbase64: read error\n");
            return false;
        }
        if (n_ret == 0) break;
        const n: usize = @intCast(n_ret);

        var dec_len: usize = 0;
        const res = state.chunk(read_buf[0..n], &dec_buf, &dec_len, ignore_garbage);
        writeStdout(dec_buf[0..dec_len]);
        if (out_failed) {
            writeStderr("zbase64: write error\n");
            return false;
        }
        if (res == .invalid) {
            writeStderr("zbase64: invalid input\n");
            return false;
        }
    }

    var dec_len: usize = 0;
    const res = state.final(&dec_buf, &dec_len);
    writeStdout(dec_buf[0..dec_len]);
    if (out_failed) {
        writeStderr("zbase64: write error\n");
        return false;
    }
    if (res == .invalid) {
        writeStderr("zbase64: invalid input\n");
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

const WrapError = error{ Invalid, Overflow };

/// Parse a --wrap/-w value. Matches GNU: pure-digit strings only; an
/// out-of-range value saturates to the max (GNU accepts it, no crash).
fn parseWrap(s: []const u8) WrapError!usize {
    if (s.len == 0) return WrapError.Invalid;
    var result: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return WrapError.Invalid;
        const digit = c - '0';
        result = std.math.mul(usize, result, 10) catch return WrapError.Overflow;
        result = std.math.add(usize, result, digit) catch return WrapError.Overflow;
    }
    return result;
}

fn dieInvalidWrap(s: []const u8) noreturn {
    writeStderr("zbase64: invalid wrap size: '");
    writeStderr(s);
    writeStderr("'\n");
    std.process.exit(1);
}

fn dieUnknownOption(arg: []const u8) noreturn {
    writeStderr("zbase64: invalid option -- '");
    writeStderr(arg);
    writeStderr("'\n");
    printTryHelp();
    std.process.exit(1);
}

fn setWrap(cfg: *Config, s: []const u8) void {
    cfg.wrap = parseWrap(s) catch |e| switch (e) {
        WrapError.Overflow => std.math.maxInt(usize),
        WrapError.Invalid => dieInvalidWrap(s),
    };
}

pub fn main(init: std.process.Init) !void {
    var cfg = Config{};

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name

    var next_is_wrap = false;
    var seen_file = false;

    while (args_iter.next()) |arg| {
        if (next_is_wrap) {
            setWrap(&cfg, arg);
            next_is_wrap = false;
            continue;
        }

        if (std.mem.eql(u8, arg, "--")) {
            // Everything after "--" is a file operand.
            while (args_iter.next()) |operand| {
                if (!seen_file) {
                    cfg.file = if (std.mem.eql(u8, operand, "-")) null else operand;
                    seen_file = true;
                }
            }
            break;
        } else if (std.mem.eql(u8, arg, "--help")) {
            printUsage(libc.STDOUT_FILENO);
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (std.mem.eql(u8, arg, "--decode")) {
            cfg.decode = true;
        } else if (std.mem.eql(u8, arg, "--ignore-garbage")) {
            cfg.ignore_garbage = true;
        } else if (std.mem.eql(u8, arg, "--wrap")) {
            next_is_wrap = true;
        } else if (std.mem.startsWith(u8, arg, "--wrap=")) {
            setWrap(&cfg, arg[7..]);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            dieUnknownOption(arg);
        } else if (arg.len >= 2 and arg[0] == '-' and !std.mem.eql(u8, arg, "-")) {
            // Combined/short options, e.g. -d, -di, -w0, -w 0.
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                switch (arg[j]) {
                    'd' => cfg.decode = true,
                    'i' => cfg.ignore_garbage = true,
                    'w' => {
                        if (j + 1 < arg.len) {
                            setWrap(&cfg, arg[j + 1 ..]);
                        } else {
                            next_is_wrap = true;
                        }
                        break; // rest of arg consumed as the wrap value
                    },
                    else => {
                        const bad = [_]u8{arg[j]};
                        dieUnknownOption(&bad);
                    },
                }
            }
        } else {
            // File operand ("-" means stdin).
            if (!seen_file) {
                cfg.file = if (std.mem.eql(u8, arg, "-")) null else arg;
                seen_file = true;
            }
        }
    }

    if (next_is_wrap) {
        writeStderr("zbase64: option requires an argument -- 'w'\n");
        printTryHelp();
        std.process.exit(1);
    }

    const fd: c_int = if (cfg.file) |path| blk: {
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch {
            writeStderr("zbase64: path too long\n");
            std.process.exit(1);
        };
        const fd_ret = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd_ret < 0) {
            writeStderr("zbase64: ");
            writeStderr(path);
            writeStderr(": ");
            writeStderr(std.mem.span(strerror(errno())));
            writeStderr("\n");
            std.process.exit(1);
        }
        break :blk fd_ret;
    } else 0;
    defer {
        if (cfg.file != null) _ = libc.close(fd);
    }

    const ok = if (cfg.decode)
        processDecode(fd, cfg.ignore_garbage)
    else
        processEncode(fd, cfg.wrap);

    if (!ok) std.process.exit(1);
}
