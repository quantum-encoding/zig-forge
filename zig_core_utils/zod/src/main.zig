//! zod - Octal dump utility
//!
//! Display file contents in octal, hex, decimal, or ASCII.

const std = @import("std");
const libc = std.c;

const VERSION = "1.0.0";

const AddressFormat = enum { octal, decimal, hex, none };

const OutputType = enum {
    octal1,   // -t o1
    octal2,   // -t o2
    octal4,   // -t o4 (default)
    hex1,     // -t x1
    hex2,     // -t x2
    hex4,     // -t x4
    decimal1, // -t d1
    decimal2, // -t d2
    decimal4, // -t d4
    decimal8, // -t d8
    unsigned1,// -t u1
    unsigned2,// -t u2
    unsigned4,// -t u4
    float4,   // -t f4
    ascii,    // -t c
    named,    // -t a
};

const Config = struct {
    address_format: AddressFormat = .octal,
    output_type: OutputType = .octal2,
    bytes_per_line: usize = 16,
    skip_bytes: usize = 0,
    limit_bytes: ?usize = null,
    show_duplicates: bool = false,
    files: [32][]const u8 = undefined,
    file_count: usize = 0,
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn reportInvalidValue(opt: []const u8, val: []const u8) noreturn {
    // GNU od rejects a malformed numeric argument and exits 1, e.g.
    //   od: invalid --read-bytes argument '5xk'
    writeStderr("zod: invalid --");
    writeStderr(opt);
    writeStderr(" argument '");
    writeStderr(val);
    writeStderr("'\n");
    std.process.exit(1);
}

fn printUsage() void {
    const usage =
        \\Usage: zod [OPTION]... [FILE]...
        \\Write an unambiguous representation of FILE to standard output.
        \\
        \\Options:
        \\  -A, --address-radix=RADIX   Output offset radix: d, o, x, or n
        \\  -t, --format=TYPE           Output format type (a, c, d, f, o, u, x + size)
        \\  -j, --skip-bytes=BYTES      Skip BYTES input bytes first
        \\  -N, --read-bytes=BYTES      Limit output to BYTES bytes
        \\  -v, --output-duplicates     Do not suppress duplicate lines
        \\  -w, --width=BYTES           Output BYTES bytes per line (default 16)
        \\  -a             Same as -t a (named characters)
        \\  -b             Same as -t o1
        \\  -c             Same as -t c
        \\  -d             Same as -t u2
        \\  -f             Same as -t fF (single-precision float)
        \\  -i             Same as -t dI (signed decimal int)
        \\  -l             Same as -t dL (signed decimal long)
        \\  -o             Same as -t o2
        \\  -s             Same as -t d2 (signed decimal short)
        \\  -x             Same as -t x2
        \\      --help     Display this help and exit
        \\      --version  Output version information and exit
        \\
        \\With no FILE, or when FILE is -, read standard input.
        \\
    ;
    // GNU od writes --help to stdout (exit 0), not stderr.
    writeStdout(usage);
}

fn printVersion() void {
    // GNU od writes --version to stdout (exit 0), not stderr.
    writeStdout("zod " ++ VERSION ++ "\n");
}

fn formatAddress(addr: usize, format: AddressFormat, buf: []u8) []const u8 {
    return switch (format) {
        .octal => std.fmt.bufPrint(buf, "{o:0>7}", .{addr}) catch "?",
        .decimal => std.fmt.bufPrint(buf, "{d:0>7}", .{addr}) catch "?",
        .hex => std.fmt.bufPrint(buf, "{x:0>6}", .{addr}) catch "?",
        .none => "",
    };
}

fn namedChar(c: u8) []const u8 {
    const names = [_][]const u8{
        "nul", "soh", "stx", "etx", "eot", "enq", "ack", "bel",
        " bs", " ht", " nl", " vt", " ff", " cr", " so", " si",
        "dle", "dc1", "dc2", "dc3", "dc4", "nak", "syn", "etb",
        "can", " em", "sub", "esc", " fs", " gs", " rs", " us",
        " sp",
    };
    if (c < 33) return names[c];
    if (c == 127) return "del";
    return "???";
}

fn escapeChar(c: u8, buf: []u8) []const u8 {
    return switch (c) {
        0 => "\\0",
        7 => "\\a",
        8 => "\\b",
        9 => "\\t",
        10 => "\\n",
        11 => "\\v",
        12 => "\\f",
        13 => "\\r",
        32...126 => blk: {
            buf[0] = ' ';
            buf[1] = ' ';
            buf[2] = c;
            break :blk buf[0..3];
        },
        else => std.fmt.bufPrint(buf, "{o:0>3}", .{c}) catch "???",
    };
}

fn fmtFloat(val: f32, buf: []u8, field_width: usize) []const u8 {
    // Mimic C's printf("%.7g", val) then right-justify in field_width
    // %.7g uses %f-style if exponent in [-4, 7), else %e-style, with 7 significant digits
    var tmp: [48]u8 = undefined;
    var num_str: []const u8 = undefined;

    if (val == 0.0) {
        // GNU prints negative zero as "-0".
        num_str = if (std.math.signbit(val)) "-0" else "0";
    } else {
        const abs_val: f32 = if (val < 0) -val else val;
        // Get exponent to decide format
        const sci = std.fmt.bufPrint(&tmp, "{e}", .{val}) catch return "?";
        // Parse the exponent from scientific notation
        var exp: i32 = 0;
        var exp_neg = false;
        var found_e = false;
        for (sci) |c| {
            if (c == 'e') {
                found_e = true;
                continue;
            }
            if (found_e) {
                if (c == '-') {
                    exp_neg = true;
                } else if (c == '+') {
                    // skip
                } else if (c >= '0' and c <= '9') {
                    exp = exp * 10 + @as(i32, c - '0');
                }
            }
        }
        if (exp_neg) exp = -exp;
        _ = abs_val;

        // %g uses decimal notation when the exponent is in [-4, P); od's float
        // rendering switches to scientific at exponent 7 (P = 7), e.g. 1e7
        // prints as 1e+07 while 9999999 (exp 6) stays decimal.
        if (exp >= -4 and exp < 7) {
            // Use decimal format - use Zig's {d} with appropriate precision
            // {d} gives full decimal; we need 7 significant digits
            const dec = std.fmt.bufPrint(&tmp, "{d}", .{val}) catch return "?";
            // Truncate to 7 significant digits (like %g)
            num_str = truncateToSigDigits(dec, buf, 8);
        } else {
            // Scientific notation "<mantissa>e±NN" with a zero-padded, minimum
            // two-digit exponent (C printf / GNU od style): 1e7 -> 1e+07, not
            // 1e+7. Zig's {e} emits an unpadded exponent, so rebuild it from the
            // exponent already parsed above.
            var out_len: usize = 0;
            for (sci) |c| {
                if (c == 'e') break;
                buf[out_len] = c;
                out_len += 1;
            }
            buf[out_len] = 'e';
            out_len += 1;
            buf[out_len] = if (exp < 0) '-' else '+';
            out_len += 1;
            const e_abs: u32 = @intCast(if (exp < 0) -exp else exp);
            var ebuf: [8]u8 = undefined;
            const e_str = std.fmt.bufPrint(&ebuf, "{d:0>2}", .{e_abs}) catch return "?";
            @memcpy(buf[out_len..][0..e_str.len], e_str);
            out_len += e_str.len;
            // Truncate mantissa to 7 significant digits
            num_str = truncateSciToSigDigits(buf[0..out_len], &tmp, 8);
        }
    }

    if (num_str.len >= field_width) {
        return num_str;
    }
    // Right-justify in field_width - copy to end of buf
    const pad = field_width - num_str.len;
    // Copy num_str to a safe location if it overlaps with buf
    var safe: [48]u8 = undefined;
    @memcpy(safe[0..num_str.len], num_str);
    @memset(buf[0..pad], ' ');
    @memcpy(buf[pad..][0..num_str.len], safe[0..num_str.len]);
    return buf[0..field_width];
}

fn truncateToSigDigits(dec: []const u8, out: []u8, sig: usize) []const u8 {
    // Truncate a decimal number string to `sig` significant digits, removing trailing zeros
    // Input like "1143141500000000000000000000" or "0.1" or "100"
    var sig_count: usize = 0;
    var out_len: usize = 0;
    var started = false;
    var has_dot = false;
    var last_nonzero: usize = 0;

    for (dec) |c| {
        if (c == '-') {
            out[out_len] = c;
            out_len += 1;
            continue;
        }
        if (c == '.') {
            has_dot = true;
            out[out_len] = c;
            out_len += 1;
            continue;
        }
        if (c >= '1' and c <= '9') started = true;
        if (started) sig_count += 1;

        if (sig_count <= sig) {
            out[out_len] = c;
            out_len += 1;
            if (c != '0') last_nonzero = out_len;
        } else if (!has_dot) {
            // Past significant digits but before decimal point: pad with zeros
            out[out_len] = '0';
            out_len += 1;
        }
        // Past sig digits after decimal point: stop
        if (sig_count > sig and has_dot) break;
    }

    // Remove trailing zeros after decimal point (like %g)
    if (has_dot and last_nonzero > 0) {
        // Check if the dot itself should be removed
        if (out[last_nonzero - 1] == '.') {
            return out[0 .. last_nonzero - 1];
        }
        return out[0..last_nonzero];
    }

    return out[0..out_len];
}

fn truncateSciToSigDigits(sci: []const u8, out: []u8, sig: usize) []const u8 {
    // Truncate scientific notation to `sig` significant digits
    // Input like "1.1431415e+27", output "1.143142e+27" (with rounding approx)
    // For simplicity, just truncate the mantissa part
    var out_len: usize = 0;
    var sig_count: usize = 0;
    var in_mantissa = true;
    var last_nonzero: usize = 0;
    var dot_pos: ?usize = null;

    for (sci) |c| {
        if (c == 'e') {
            // End of mantissa - trim trailing zeros after decimal
            if (dot_pos) |dp| {
                _ = dp;
                if (last_nonzero > 0 and last_nonzero < out_len) {
                    out_len = last_nonzero;
                }
                // Remove trailing dot
                if (out_len > 0 and out[out_len - 1] == '.') {
                    out_len -= 1;
                }
            }
            in_mantissa = false;
            out[out_len] = c;
            out_len += 1;
            continue;
        }

        if (!in_mantissa) {
            out[out_len] = c;
            out_len += 1;
            continue;
        }

        if (c == '-') {
            out[out_len] = c;
            out_len += 1;
            continue;
        }

        if (c == '.') {
            dot_pos = out_len;
            out[out_len] = c;
            out_len += 1;
            continue;
        }

        sig_count += 1;
        if (sig_count <= sig) {
            out[out_len] = c;
            out_len += 1;
            if (c != '0') last_nonzero = out_len;
        }
    }

    return out[0..out_len];
}

fn fmtSignedDecimal(comptime T: type, val: T, buf: []u8, field_width: usize) []const u8 {
    // Format the number without width specifier to avoid Zig's '+' prefix
    var tmp: [24]u8 = undefined;
    const num_str = std.fmt.bufPrint(&tmp, "{d}", .{val}) catch return "?";
    // Right-justify in field_width
    if (num_str.len >= field_width) {
        @memcpy(buf[0..num_str.len], num_str);
        return buf[0..num_str.len];
    }
    const pad = field_width - num_str.len;
    @memset(buf[0..pad], ' ');
    @memcpy(buf[pad..][0..num_str.len], num_str);
    return buf[0..field_width];
}

fn dumpLine(data: []const u8, offset: usize, cfg: *const Config) void {
    var addr_buf: [16]u8 = undefined;
    var val_buf: [32]u8 = undefined;

    // Print address
    writeStdout(formatAddress(offset, cfg.address_format, &addr_buf));

    // Print values based on output type
    switch (cfg.output_type) {
        .octal1 => {
            for (data) |b| {
                const s = std.fmt.bufPrint(&val_buf, " {o:0>3}", .{b}) catch " ???";
                writeStdout(s);
            }
        },
        .octal2 => {
            var i: usize = 0;
            while (i + 1 < data.len) : (i += 2) {
                const val = std.mem.readInt(u16, data[i..][0..2], .little);
                const s = std.fmt.bufPrint(&val_buf, " {o:0>6}", .{val}) catch " ???";
                writeStdout(s);
            }
            if (i < data.len) {
                const s = std.fmt.bufPrint(&val_buf, " {o:0>6}", .{data[i]}) catch " ???";
                writeStdout(s);
            }
        },
        .octal4 => {
            var i: usize = 0;
            while (i + 3 < data.len) : (i += 4) {
                const val = std.mem.readInt(u32, data[i..][0..4], .little);
                const s = std.fmt.bufPrint(&val_buf, " {o:0>11}", .{val}) catch " ???";
                writeStdout(s);
            }
            // Handle trailing bytes (partial group): zero-pad to unit size like GNU.
            const remainder = data.len % 4;
            if (remainder != 0) {
                var tmp_bytes: [4]u8 = .{ 0, 0, 0, 0 };
                const start = data.len - remainder;
                @memcpy(tmp_bytes[0..remainder], data[start..]);
                const val = std.mem.readInt(u32, &tmp_bytes, .little);
                const s = std.fmt.bufPrint(&val_buf, " {o:0>11}", .{val}) catch " ???";
                writeStdout(s);
            }
        },
        .hex1 => {
            for (data) |b| {
                const s = std.fmt.bufPrint(&val_buf, " {x:0>2}", .{b}) catch " ??";
                writeStdout(s);
            }
        },
        .hex2 => {
            var i: usize = 0;
            while (i + 1 < data.len) : (i += 2) {
                const val = std.mem.readInt(u16, data[i..][0..2], .little);
                const s = std.fmt.bufPrint(&val_buf, " {x:0>4}", .{val}) catch " ????";
                writeStdout(s);
            }
            if (i < data.len) {
                const s = std.fmt.bufPrint(&val_buf, " {x:0>4}", .{data[i]}) catch " ????";
                writeStdout(s);
            }
        },
        .hex4 => {
            var i: usize = 0;
            while (i + 3 < data.len) : (i += 4) {
                const val = std.mem.readInt(u32, data[i..][0..4], .little);
                const s = std.fmt.bufPrint(&val_buf, " {x:0>8}", .{val}) catch " ????????";
                writeStdout(s);
            }
            // Handle trailing bytes (partial group): zero-pad to unit size like GNU.
            const remainder = data.len % 4;
            if (remainder != 0) {
                var tmp_bytes: [4]u8 = .{ 0, 0, 0, 0 };
                const start = data.len - remainder;
                @memcpy(tmp_bytes[0..remainder], data[start..]);
                const val = std.mem.readInt(u32, &tmp_bytes, .little);
                const s = std.fmt.bufPrint(&val_buf, " {x:0>8}", .{val}) catch " ????????";
                writeStdout(s);
            }
        },
        .decimal1 => {
            for (data) |b| {
                const signed: i8 = @bitCast(b);
                writeStdout(" ");
                writeStdout(fmtSignedDecimal(i8, signed, &val_buf, 4));
            }
        },
        .decimal2 => {
            var i: usize = 0;
            while (i + 1 < data.len) : (i += 2) {
                const val: i16 = @bitCast(std.mem.readInt(u16, data[i..][0..2], .little));
                writeStdout(" ");
                writeStdout(fmtSignedDecimal(i16, val, &val_buf, 6));
            }
            if (data.len % 2 != 0) {
                const val: i16 = @as(i16, @as(i8, @bitCast(data[data.len - 1])));
                writeStdout(" ");
                writeStdout(fmtSignedDecimal(i16, val, &val_buf, 6));
            }
        },
        .decimal4 => {
            var i: usize = 0;
            while (i + 3 < data.len) : (i += 4) {
                const val: i32 = @bitCast(std.mem.readInt(u32, data[i..][0..4], .little));
                writeStdout(" ");
                writeStdout(fmtSignedDecimal(i32, val, &val_buf, 11));
            }
            // Handle trailing bytes (partial group)
            const remainder = data.len % 4;
            if (remainder != 0) {
                var tmp_bytes: [4]u8 = .{ 0, 0, 0, 0 };
                const start = data.len - remainder;
                @memcpy(tmp_bytes[0..remainder], data[start..]);
                const val: i32 = @bitCast(std.mem.readInt(u32, &tmp_bytes, .little));
                writeStdout(" ");
                writeStdout(fmtSignedDecimal(i32, val, &val_buf, 11));
            }
        },
        .decimal8 => {
            var i: usize = 0;
            while (i + 7 < data.len) : (i += 8) {
                const val: i64 = @bitCast(std.mem.readInt(u64, data[i..][0..8], .little));
                writeStdout(" ");
                writeStdout(fmtSignedDecimal(i64, val, &val_buf, 20));
            }
            // Handle trailing bytes (partial group)
            const remainder = data.len % 8;
            if (remainder != 0) {
                var tmp_bytes: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
                const start = data.len - remainder;
                @memcpy(tmp_bytes[0..remainder], data[start..]);
                const val: i64 = @bitCast(std.mem.readInt(u64, &tmp_bytes, .little));
                writeStdout(" ");
                writeStdout(fmtSignedDecimal(i64, val, &val_buf, 20));
            }
        },
        .unsigned1 => {
            for (data) |b| {
                const s = std.fmt.bufPrint(&val_buf, " {d:>3}", .{b}) catch " ???";
                writeStdout(s);
            }
        },
        .unsigned2 => {
            var i: usize = 0;
            while (i + 1 < data.len) : (i += 2) {
                const val = std.mem.readInt(u16, data[i..][0..2], .little);
                const s = std.fmt.bufPrint(&val_buf, " {d:>5}", .{val}) catch " ?????";
                writeStdout(s);
            }
            // Handle final odd byte: zero-pad to u16 like GNU.
            if (data.len % 2 != 0) {
                const val: u16 = data[data.len - 1];
                const s = std.fmt.bufPrint(&val_buf, " {d:>5}", .{val}) catch " ?????";
                writeStdout(s);
            }
        },
        .unsigned4 => {
            var i: usize = 0;
            while (i + 3 < data.len) : (i += 4) {
                const val = std.mem.readInt(u32, data[i..][0..4], .little);
                const s = std.fmt.bufPrint(&val_buf, " {d:>10}", .{val}) catch " ??????????";
                writeStdout(s);
            }
            // Handle trailing bytes (partial group): zero-pad to unit size like GNU.
            const remainder = data.len % 4;
            if (remainder != 0) {
                var tmp_bytes: [4]u8 = .{ 0, 0, 0, 0 };
                const start = data.len - remainder;
                @memcpy(tmp_bytes[0..remainder], data[start..]);
                const val = std.mem.readInt(u32, &tmp_bytes, .little);
                const s = std.fmt.bufPrint(&val_buf, " {d:>10}", .{val}) catch " ??????????";
                writeStdout(s);
            }
        },
        .float4 => {
            var i: usize = 0;
            var float_buf: [32]u8 = undefined;
            while (i + 3 < data.len) : (i += 4) {
                const bits = std.mem.readInt(u32, data[i..][0..4], .little);
                const val: f32 = @bitCast(bits);
                writeStdout(fmtFloat(val, &float_buf, 16));
            }
            // Handle trailing bytes (partial group)
            const remainder = data.len % 4;
            if (remainder != 0) {
                var tmp_bytes: [4]u8 = .{ 0, 0, 0, 0 };
                const start = data.len - remainder;
                @memcpy(tmp_bytes[0..remainder], data[start..]);
                const bits = std.mem.readInt(u32, &tmp_bytes, .little);
                const val: f32 = @bitCast(bits);
                writeStdout(fmtFloat(val, &float_buf, 16));
            }
        },
        .ascii => {
            for (data) |b| {
                const esc = escapeChar(b, &val_buf);
                // Right-justify in 4-char field
                var field: [4]u8 = .{ ' ', ' ', ' ', ' ' };
                const start = 4 - esc.len;
                for (esc, 0..) |ch, j| {
                    field[start + j] = ch;
                }
                writeStdout(&field);
            }
        },
        .named => {
            for (data) |b| {
                // GNU od -t a names the 7-bit character (high bit masked off),
                // so 0x80 -> nul, 0xA0 -> sp, etc.
                const c = b & 0x7f;
                if (c < 33 or c == 127) {
                    writeStdout(" ");
                    writeStdout(namedChar(c));
                } else {
                    val_buf[0] = ' ';
                    val_buf[1] = ' ';
                    val_buf[2] = ' ';
                    val_buf[3] = c;
                    writeStdout(val_buf[0..4]);
                }
            }
        },
    }

    writeStdout("\n");
}

fn parseNumber(s: []const u8) ?usize {
    if (s.len == 0) return null;

    // Check for a size suffix (GNU: b=512, k=1024, m=1048576).
    var multiplier: usize = 1;
    var digits = s;
    switch (s[s.len - 1]) {
        'k', 'K' => {
            multiplier = 1024;
            digits = s[0 .. s.len - 1];
        },
        'm', 'M' => {
            multiplier = 1024 * 1024;
            digits = s[0 .. s.len - 1];
        },
        'b', 'B' => {
            multiplier = 512;
            digits = s[0 .. s.len - 1];
        },
        else => {},
    }
    if (digits.len == 0) return null;

    // Reject malformed / oversized input gracefully instead of panicking on
    // integer overflow (parseInt) or a null suffix prefix.
    const base = std.fmt.parseInt(usize, digits, 10) catch return null;
    return std.math.mul(usize, base, multiplier) catch null;
}

fn parseOutputType(s: []const u8) ?OutputType {
    if (s.len == 0) return null;

    const base = s[0];
    const size: u8 = if (s.len > 1) switch (s[1]) {
        '1'...'8' => s[1] - '0',
        'C' => 1,   // char
        'S' => 2,   // short
        'I' => 4,   // int
        'L' => 8,   // long
        'F' => 4,   // float
        else => 2,
    } else 2;

    return switch (base) {
        'o' => switch (size) {
            1 => .octal1,
            2 => .octal2,
            4 => .octal4,
            else => .octal2,
        },
        'x' => switch (size) {
            1 => .hex1,
            2 => .hex2,
            4 => .hex4,
            else => .hex2,
        },
        'd' => switch (size) {
            1 => .decimal1,
            2 => .decimal2,
            4 => .decimal4,
            8 => .decimal8,
            else => .decimal2,
        },
        'u' => switch (size) {
            1 => .unsigned1,
            2 => .unsigned2,
            4 => .unsigned4,
            else => .unsigned2,
        },
        'f' => .float4,
        'c' => .ascii,
        'a' => .named,
        else => null,
    };
}

fn dumpFile(path: ?[]const u8, cfg: *const Config) !void {
    const fd: c_int = if (path) |p| blk: {
        if (std.mem.eql(u8, p, "-")) break :blk libc.STDIN_FILENO;
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{p}) catch return error.PathTooLong;
        const opened = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (opened < 0) return error.OpenFailed;
        break :blk opened;
    } else libc.STDIN_FILENO;
    defer if (path != null and !std.mem.eql(u8, path.?, "-")) {
        _ = libc.close(fd);
    };

    var buf: [4096]u8 = undefined;
    var line_buf: [64]u8 = undefined;
    var prev_line: [64]u8 = undefined;
    var prev_len: usize = 0;
    var offset: usize = 0;
    var total_read: usize = 0;
    var duplicate_pending = false;

    // Skip bytes
    var skip_remaining = cfg.skip_bytes;
    while (skip_remaining > 0) {
        const to_skip = @min(skip_remaining, buf.len);
        const read_result = libc.read(fd, &buf, to_skip);
        if (read_result <= 0) break;
        const n: usize = @intCast(read_result);
        skip_remaining -= n;
        offset += n;
    }
    // GNU od: skipping *past* the end of input is an error ("cannot skip past
    // end of combined input") — exit 1, no output. Skipping to exactly the end
    // is fine (prints just the final offset line).
    if (skip_remaining > 0) return error.SkipPastEnd;

    while (true) {
        // Check limit
        if (cfg.limit_bytes) |limit| {
            if (total_read >= limit) break;
        }

        const max_read = if (cfg.limit_bytes) |limit|
            @min(cfg.bytes_per_line, limit - total_read)
        else
            cfg.bytes_per_line;

        // Fill a full bytes-per-line buffer, looping on short reads (pipes,
        // sockets, ttys) so lines are width-aligned and duplicate ('*')
        // suppression compares full-width lines the way GNU od does.
        var n: usize = 0;
        while (n < max_read) {
            const read_result = libc.read(fd, line_buf[n..].ptr, max_read - n);
            if (read_result < 0) return error.ReadFailed;
            if (read_result == 0) break;
            n += @intCast(read_result);
        }
        if (n == 0) break;

        total_read += n;
        const data = line_buf[0..n];

        // Check for duplicate suppression
        if (!cfg.show_duplicates and n == prev_len and std.mem.eql(u8, data, prev_line[0..prev_len])) {
            if (!duplicate_pending) {
                writeStdout("*\n");
                duplicate_pending = true;
            }
        } else {
            duplicate_pending = false;
            dumpLine(data, offset, cfg);
            @memcpy(prev_line[0..n], data);
            prev_len = n;
        }

        offset += n;
    }

    // Print the final offset line. GNU od omits it entirely when the address
    // radix is 'none' (-A n) — no trailing empty line.
    if (cfg.address_format != .none) {
        var addr_buf: [16]u8 = undefined;
        writeStdout(formatAddress(offset, cfg.address_format, &addr_buf));
        writeStdout("\n");
    }
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
        } else if (std.mem.eql(u8, arg, "-A") or std.mem.startsWith(u8, arg, "--address-radix=") or std.mem.startsWith(u8, arg, "-A")) {
            const fmt_str = if (std.mem.startsWith(u8, arg, "--address-radix="))
                arg["--address-radix=".len..]
            else if (arg.len > 2)
                arg[2..] // glued form: -Ax
            else blk: {
                i += 1;
                break :blk if (i < args.len) args[i] else "";
            };
            if (fmt_str.len > 0) {
                cfg.address_format = switch (fmt_str[0]) {
                    'd' => .decimal,
                    'o' => .octal,
                    'x' => .hex,
                    'n' => .none,
                    else => .octal,
                };
            }
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.startsWith(u8, arg, "--format=") or std.mem.startsWith(u8, arg, "-t")) {
            const fmt_str = if (std.mem.startsWith(u8, arg, "--format="))
                arg["--format=".len..]
            else if (arg.len > 2)
                arg[2..] // glued form: -tx1
            else blk: {
                i += 1;
                break :blk if (i < args.len) args[i] else "";
            };
            if (parseOutputType(fmt_str)) |ot| {
                cfg.output_type = ot;
            }
        } else if (std.mem.eql(u8, arg, "-j") or std.mem.startsWith(u8, arg, "--skip-bytes=") or std.mem.startsWith(u8, arg, "-j")) {
            const val_str = if (std.mem.startsWith(u8, arg, "--skip-bytes="))
                arg["--skip-bytes=".len..]
            else if (arg.len > 2)
                arg[2..] // glued form: -j10
            else blk: {
                i += 1;
                break :blk if (i < args.len) args[i] else "";
            };
            if (parseNumber(val_str)) |n| {
                cfg.skip_bytes = n;
            } else {
                reportInvalidValue("skip-bytes", val_str);
            }
        } else if (std.mem.eql(u8, arg, "-N") or std.mem.startsWith(u8, arg, "--read-bytes=") or std.mem.startsWith(u8, arg, "-N")) {
            const val_str = if (std.mem.startsWith(u8, arg, "--read-bytes="))
                arg["--read-bytes=".len..]
            else if (arg.len > 2)
                arg[2..] // glued form: -N16
            else blk: {
                i += 1;
                break :blk if (i < args.len) args[i] else "";
            };
            if (parseNumber(val_str)) |n| {
                cfg.limit_bytes = n;
            } else {
                reportInvalidValue("read-bytes", val_str);
            }
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.startsWith(u8, arg, "--width=") or std.mem.startsWith(u8, arg, "-w")) {
            const val_str = if (std.mem.startsWith(u8, arg, "--width="))
                arg["--width=".len..]
            else if (arg.len > 2)
                arg[2..] // glued form: -w32
            else blk: {
                i += 1;
                break :blk if (i < args.len) args[i] else "";
            };
            if (parseNumber(val_str)) |n| {
                cfg.bytes_per_line = n;
            } else {
                reportInvalidValue("width", val_str);
            }
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--output-duplicates")) {
            cfg.show_duplicates = true;
        } else if (std.mem.eql(u8, arg, "-a")) {
            cfg.output_type = .named;
        } else if (std.mem.eql(u8, arg, "-b")) {
            cfg.output_type = .octal1;
        } else if (std.mem.eql(u8, arg, "-c")) {
            cfg.output_type = .ascii;
        } else if (std.mem.eql(u8, arg, "-d")) {
            cfg.output_type = .unsigned2;
        } else if (std.mem.eql(u8, arg, "-f")) {
            cfg.output_type = .float4;
        } else if (std.mem.eql(u8, arg, "-i")) {
            cfg.output_type = .decimal4;
        } else if (std.mem.eql(u8, arg, "-l")) {
            cfg.output_type = .decimal8;
        } else if (std.mem.eql(u8, arg, "-o")) {
            cfg.output_type = .octal2;
        } else if (std.mem.eql(u8, arg, "-s")) {
            cfg.output_type = .decimal2;
        } else if (std.mem.eql(u8, arg, "-x")) {
            cfg.output_type = .hex2;
        } else if (arg.len > 0 and arg[0] != '-') {
            if (cfg.file_count < cfg.files.len) {
                cfg.files[cfg.file_count] = arg;
                cfg.file_count += 1;
            }
        } else if (std.mem.eql(u8, arg, "-")) {
            if (cfg.file_count < cfg.files.len) {
                cfg.files[cfg.file_count] = "-";
                cfg.file_count += 1;
            }
        } else {
            // Any remaining token here starts with '-' and matched no known
            // flag. GNU errors 'invalid option' and exits 1 rather than
            // silently dumping stdin.
            writeStderr("zod: invalid option -- '");
            if (arg.len > 1) writeStderr(arg[1..]);
            writeStderr("'\n");
            std.process.exit(1);
        }
    }

    if (cfg.file_count == 0) {
        dumpFile(null, &cfg) catch {
            writeStderr("zod: read error\n");
            std.process.exit(1);
        };
    } else {
        var had_error = false;
        for (cfg.files[0..cfg.file_count]) |path| {
            dumpFile(path, &cfg) catch {
                writeStderr("zod: ");
                writeStderr(path);
                writeStderr(": error\n");
                had_error = true;
            };
        }
        // GNU od exits 1 if any file could not be opened/read.
        if (had_error) std.process.exit(1);
    }
}
