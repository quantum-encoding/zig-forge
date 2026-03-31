//! zprintf - Format and print data
//!
//! High-performance printf implementation in Zig.

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

fn writeChar(c: u8) void {
    const buf = [1]u8{c};
    writeStdout(&buf);
}

fn printUsage() void {
    const usage =
        \\Usage: zprintf FORMAT [ARGUMENT]...
        \\Print ARGUMENT(s) according to FORMAT.
        \\
        \\FORMAT controls the output, with escape sequences:
        \\  \\n    newline
        \\  \\t    tab
        \\  \\r    carriage return
        \\  \\\\    backslash
        \\  \\0NNN octal value (1-3 digits)
        \\  \\xHH  hex value (1-2 digits)
        \\
        \\Format specifiers:
        \\  %s    string
        \\  %b    string with backslash escapes interpreted
        \\  %q    shell-quoted string
        \\  %d,%i signed decimal
        \\  %u    unsigned decimal
        \\  %o    octal
        \\  %x    hex (lowercase)
        \\  %X    hex (uppercase)
        \\  %f,%F decimal floating-point
        \\  %e,%E scientific notation
        \\  %g,%G shortest representation
        \\  %c    character
        \\  %%    literal %
        \\
        \\Width and precision: %10s, %.5s, %10.5s, %.3f
        \\Flags: - (left), + (sign), 0 (zero-pad), # (alternate)
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zprintf " ++ VERSION ++ "\n");
}

fn parseEscape(fmt: []const u8, pos: *usize) ?u8 {
    if (pos.* >= fmt.len) return null;

    const c = fmt[pos.*];
    pos.* += 1;

    return switch (c) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        '\\' => '\\',
        '"' => '"',
        '\'' => '\'',
        'a' => 0x07, // bell
        'b' => 0x08, // backspace
        'f' => 0x0C, // form feed
        'v' => 0x0B, // vertical tab
        '0', '1', '2', '3', '4', '5', '6', '7' => blk: {
            // Octal: \0NNN (1-3 digits)
            pos.* -= 1;
            var val: u8 = 0;
            var digits: usize = 0;
            while (digits < 3 and pos.* < fmt.len) {
                const d = fmt[pos.*];
                if (d >= '0' and d <= '7') {
                    val = val * 8 + (d - '0');
                    pos.* += 1;
                    digits += 1;
                } else break;
            }
            break :blk val;
        },
        'x' => blk: {
            // Hex: \xHH (1-2 digits)
            var val: u8 = 0;
            var digits: usize = 0;
            while (digits < 2 and pos.* < fmt.len) {
                const d = fmt[pos.*];
                if (d >= '0' and d <= '9') {
                    val = val * 16 + (d - '0');
                    pos.* += 1;
                    digits += 1;
                } else if (d >= 'a' and d <= 'f') {
                    val = val * 16 + (d - 'a' + 10);
                    pos.* += 1;
                    digits += 1;
                } else if (d >= 'A' and d <= 'F') {
                    val = val * 16 + (d - 'A' + 10);
                    pos.* += 1;
                    digits += 1;
                } else break;
            }
            break :blk val;
        },
        else => c,
    };
}

const FormatSpec = struct {
    left_align: bool = false,
    show_sign: bool = false,
    space_sign: bool = false,
    zero_pad: bool = false,
    alternate: bool = false,
    width: usize = 0,
    precision: ?usize = null,
    specifier: u8 = 's',
};

fn parseFormat(fmt: []const u8, pos: *usize) FormatSpec {
    var spec = FormatSpec{};

    // Parse flags
    while (pos.* < fmt.len) {
        const c = fmt[pos.*];
        switch (c) {
            '-' => spec.left_align = true,
            '+' => spec.show_sign = true,
            ' ' => spec.space_sign = true,
            '0' => spec.zero_pad = true,
            '#' => spec.alternate = true,
            else => break,
        }
        pos.* += 1;
    }

    // Parse width
    while (pos.* < fmt.len) {
        const c = fmt[pos.*];
        if (c >= '0' and c <= '9') {
            spec.width = spec.width * 10 + (c - '0');
            pos.* += 1;
        } else break;
    }

    // Parse precision
    if (pos.* < fmt.len and fmt[pos.*] == '.') {
        pos.* += 1;
        spec.precision = 0;
        while (pos.* < fmt.len) {
            const c = fmt[pos.*];
            if (c >= '0' and c <= '9') {
                spec.precision = spec.precision.? * 10 + (c - '0');
                pos.* += 1;
            } else break;
        }
    }

    // Parse specifier
    if (pos.* < fmt.len) {
        spec.specifier = fmt[pos.*];
        pos.* += 1;
    }

    return spec;
}

fn formatInt(value: i64, base: u8, uppercase: bool, buf: []u8) []const u8 {
    const digits_lower = "0123456789abcdef";
    const digits_upper = "0123456789ABCDEF";
    const digits = if (uppercase) digits_upper else digits_lower;

    var v: u64 = if (value < 0) @bitCast(-value) else @bitCast(value);
    var i: usize = buf.len;

    if (v == 0) {
        i -= 1;
        buf[i] = '0';
    } else {
        while (v > 0) {
            i -= 1;
            buf[i] = digits[@intCast(v % base)];
            v /= base;
        }
    }

    if (value < 0) {
        i -= 1;
        buf[i] = '-';
    }

    return buf[i..];
}

fn formatUint(value: u64, base: u8, uppercase: bool, buf: []u8) []const u8 {
    const digits_lower = "0123456789abcdef";
    const digits_upper = "0123456789ABCDEF";
    const digits = if (uppercase) digits_upper else digits_lower;

    var v = value;
    var i: usize = buf.len;

    if (v == 0) {
        i -= 1;
        buf[i] = '0';
    } else {
        while (v > 0) {
            i -= 1;
            buf[i] = digits[@intCast(v % base)];
            v /= base;
        }
    }

    return buf[i..];
}

fn printPadded(data: []const u8, spec: *const FormatSpec) void {
    var output = data;

    // Apply precision for strings
    if (spec.specifier == 's') {
        if (spec.precision) |prec| {
            if (output.len > prec) {
                output = output[0..prec];
            }
        }
    }

    const pad_len = if (spec.width > output.len) spec.width - output.len else 0;
    const pad_char: u8 = if (spec.zero_pad and !spec.left_align) '0' else ' ';

    if (!spec.left_align) {
        var p: usize = 0;
        while (p < pad_len) : (p += 1) {
            writeChar(pad_char);
        }
    }

    writeStdout(output);

    if (spec.left_align) {
        var p: usize = 0;
        while (p < pad_len) : (p += 1) {
            writeChar(' ');
        }
    }
}

fn parseFloat(s: []const u8) f64 {
    return std.fmt.parseFloat(f64, s) catch 0.0;
}

fn formatFloatF(value: f64, precision: usize, buf: []u8) []const u8 {
    // Format as fixed decimal (like %f)
    const result = std.fmt.bufPrint(buf, "{d:.[1]}", .{ value, precision }) catch return "0";
    return result;
}

fn formatFloatE(value: f64, precision: usize, uppercase: bool, buf: []u8) []const u8 {
    // Format as scientific notation (like %e)
    if (uppercase) {
        const result = std.fmt.bufPrint(buf, "{E:.[1]}", .{ value, precision }) catch return "0";
        return result;
    } else {
        const result = std.fmt.bufPrint(buf, "{e:.[1]}", .{ value, precision }) catch return "0";
        return result;
    }
}

fn formatFloatG(value: f64, precision: usize, uppercase: bool, buf: []u8) []const u8 {
    // Format as shortest (like %g): uses %e or %f depending on magnitude
    const abs_val = @abs(value);
    const prec = if (precision == 0) 1 else precision;

    // Use scientific notation if exponent < -4 or >= precision
    if (abs_val != 0 and (abs_val < 0.0001 or abs_val >= std.math.pow(f64, 10, @floatFromInt(prec)))) {
        return formatFloatE(value, if (prec > 0) prec - 1 else 0, uppercase, buf);
    } else {
        return formatFloatF(value, prec, buf);
    }
}

fn parseInt(s: []const u8) i64 {
    var result: i64 = 0;
    var negative = false;
    var i: usize = 0;

    if (i < s.len and s[i] == '-') {
        negative = true;
        i += 1;
    } else if (i < s.len and s[i] == '+') {
        i += 1;
    }

    // Handle hex/octal prefixes
    if (i + 1 < s.len and s[i] == '0') {
        if (s[i + 1] == 'x' or s[i + 1] == 'X') {
            // Hex
            i += 2;
            while (i < s.len) {
                const c = s[i];
                if (c >= '0' and c <= '9') {
                    result = result * 16 + (c - '0');
                } else if (c >= 'a' and c <= 'f') {
                    result = result * 16 + (c - 'a' + 10);
                } else if (c >= 'A' and c <= 'F') {
                    result = result * 16 + (c - 'A' + 10);
                } else break;
                i += 1;
            }
            return if (negative) -result else result;
        } else if (s[i + 1] >= '0' and s[i + 1] <= '7') {
            // Octal
            while (i < s.len and s[i] >= '0' and s[i] <= '7') {
                result = result * 8 + (s[i] - '0');
                i += 1;
            }
            return if (negative) -result else result;
        }
    }

    // Decimal
    while (i < s.len) {
        const c = s[i];
        if (c >= '0' and c <= '9') {
            result = result * 10 + (c - '0');
        } else break;
        i += 1;
    }

    return if (negative) -result else result;
}

/// Process backslash escapes in argument string for %b.
/// Returns true if \c was encountered (stop all output).
fn processBackslashEscapes(arg: []const u8) struct { stop: bool } {
    var pos: usize = 0;
    while (pos < arg.len) {
        if (arg[pos] == '\\') {
            pos += 1;
            if (pos >= arg.len) {
                writeChar('\\');
                break;
            }
            const c = arg[pos];
            pos += 1;
            switch (c) {
                '\\' => writeChar('\\'),
                'a' => writeChar(0x07),
                'b' => writeChar(0x08),
                'f' => writeChar(0x0C),
                'n' => writeChar('\n'),
                'r' => writeChar('\r'),
                't' => writeChar('\t'),
                'v' => writeChar(0x0B),
                'c' => return .{ .stop = true },
                '0' => {
                    // Octal: \0NNN (up to 3 octal digits after the 0)
                    var val: u8 = 0;
                    var digits: usize = 0;
                    while (digits < 3 and pos < arg.len and arg[pos] >= '0' and arg[pos] <= '7') {
                        val = val * 8 + (arg[pos] - '0');
                        pos += 1;
                        digits += 1;
                    }
                    writeChar(val);
                },
                'x' => {
                    // Hex: \xHH (up to 2 hex digits)
                    var val: u8 = 0;
                    var digits: usize = 0;
                    while (digits < 2 and pos < arg.len) {
                        const d = arg[pos];
                        if (d >= '0' and d <= '9') {
                            val = val * 16 + (d - '0');
                        } else if (d >= 'a' and d <= 'f') {
                            val = val * 16 + (d - 'a' + 10);
                        } else if (d >= 'A' and d <= 'F') {
                            val = val * 16 + (d - 'A' + 10);
                        } else break;
                        pos += 1;
                        digits += 1;
                    }
                    writeChar(val);
                },
                else => {
                    writeChar('\\');
                    writeChar(c);
                },
            }
        } else {
            writeChar(arg[pos]);
            pos += 1;
        }
    }
    return .{ .stop = false };
}

/// Shell-quote a string for %q.
fn shellQuote(arg: []const u8) void {
    if (arg.len == 0) {
        writeStdout("''");
        return;
    }

    // Check if quoting is needed
    var needs_quoting = false;
    for (arg) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '/', ':', '@', '%', '+', ',' => {},
            else => {
                needs_quoting = true;
                break;
            },
        }
    }

    if (!needs_quoting) {
        writeStdout(arg);
        return;
    }

    // Use single quotes, escaping embedded single quotes as '\''
    writeChar('\'');
    for (arg) |c| {
        if (c == '\'') {
            writeStdout("'\\''");
        } else {
            writeChar(c);
        }
    }
    writeChar('\'');
}

fn doFormat(fmt: []const u8, arguments: []const []const u8) void {
    var arg_idx: usize = 0;

    // Loop: reuse format string while there are remaining arguments (GNU behavior)
    var first_pass = true;
    while (first_pass or arg_idx < arguments.len) {
        first_pass = false;
        var pos: usize = 0;
        var int_buf: [32]u8 = undefined;
        var used_arg_this_pass = false;

    while (pos < fmt.len) {
        const c = fmt[pos];

        if (c == '\\') {
            pos += 1;
            if (parseEscape(fmt, &pos)) |escaped| {
                writeChar(escaped);
            }
        } else if (c == '%') {
            pos += 1;
            if (pos >= fmt.len) {
                writeChar('%');
                break;
            }

            if (fmt[pos] == '%') {
                writeChar('%');
                pos += 1;
                continue;
            }

            const spec = parseFormat(fmt, &pos);
            const arg = if (arg_idx < arguments.len) arguments[arg_idx] else "";
            used_arg_this_pass = true;

            switch (spec.specifier) {
                's' => {
                    printPadded(arg, &spec);
                },
                'b' => {
                    const result = processBackslashEscapes(arg);
                    if (result.stop) return;
                },
                'q' => {
                    shellQuote(arg);
                },
                'd', 'i' => {
                    const val = parseInt(arg);
                    const result = formatInt(val, 10, false, &int_buf);

                    // Handle sign flags
                    if (val >= 0) {
                        if (spec.show_sign) {
                            writeChar('+');
                        } else if (spec.space_sign) {
                            writeChar(' ');
                        }
                    }

                    printPadded(result, &spec);
                },
                'u' => {
                    const val: u64 = @bitCast(parseInt(arg));
                    const result = formatUint(val, 10, false, &int_buf);
                    printPadded(result, &spec);
                },
                'o' => {
                    const val: u64 = @bitCast(parseInt(arg));
                    const result = formatUint(val, 8, false, &int_buf);
                    if (spec.alternate and result.len > 0 and result[0] != '0') {
                        writeChar('0');
                    }
                    printPadded(result, &spec);
                },
                'x' => {
                    const val: u64 = @bitCast(parseInt(arg));
                    const result = formatUint(val, 16, false, &int_buf);
                    if (spec.alternate and val != 0) {
                        writeStdout("0x");
                    }
                    printPadded(result, &spec);
                },
                'X' => {
                    const val: u64 = @bitCast(parseInt(arg));
                    const result = formatUint(val, 16, true, &int_buf);
                    if (spec.alternate and val != 0) {
                        writeStdout("0X");
                    }
                    printPadded(result, &spec);
                },
                'c' => {
                    if (arg.len > 0) {
                        writeChar(arg[0]);
                    }
                },
                'f', 'F' => {
                    const val = parseFloat(arg);
                    var float_buf: [64]u8 = undefined;
                    const prec = spec.precision orelse 6;
                    const result = formatFloatF(val, prec, &float_buf);

                    if (val >= 0) {
                        if (spec.show_sign) {
                            writeChar('+');
                        } else if (spec.space_sign) {
                            writeChar(' ');
                        }
                    }

                    printPadded(result, &spec);
                },
                'e', 'E' => {
                    const val = parseFloat(arg);
                    var float_buf: [64]u8 = undefined;
                    const prec = spec.precision orelse 6;
                    const uppercase = spec.specifier == 'E';
                    const result = formatFloatE(val, prec, uppercase, &float_buf);

                    if (val >= 0) {
                        if (spec.show_sign) {
                            writeChar('+');
                        } else if (spec.space_sign) {
                            writeChar(' ');
                        }
                    }

                    printPadded(result, &spec);
                },
                'g', 'G' => {
                    const val = parseFloat(arg);
                    var float_buf: [64]u8 = undefined;
                    const prec = spec.precision orelse 6;
                    const uppercase = spec.specifier == 'G';
                    const result = formatFloatG(val, prec, uppercase, &float_buf);

                    if (val >= 0) {
                        if (spec.show_sign) {
                            writeChar('+');
                        } else if (spec.space_sign) {
                            writeChar(' ');
                        }
                    }

                    printPadded(result, &spec);
                },
                else => {
                    writeChar('%');
                    writeChar(spec.specifier);
                },
            }

            if (arguments.len > 0) {
                arg_idx += 1;
            }
        } else {
            writeChar(c);
            pos += 1;
        }
    } // end inner while (format string)

        // If no format specifier consumed an arg this pass, stop to avoid infinite loop
        if (!used_arg_this_pass) break;
    } // end outer while (reuse format for remaining args)
}

pub fn main(init: std.process.Init) void {
    // Collect args into array
    var args_arr: [64][]const u8 = undefined;
    var args_len: usize = 0;
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        if (args_len < args_arr.len) {
            args_arr[args_len] = arg;
            args_len += 1;
        }
    }

    if (args_len < 2) {
        printUsage();
        std.process.exit(1);
    }

    const first_arg = args_arr[1];

    if (std.mem.eql(u8, first_arg, "--help")) {
        printUsage();
        return;
    } else if (std.mem.eql(u8, first_arg, "--version")) {
        printVersion();
        return;
    }

    // First argument is format string
    const format = first_arg;

    // Collect remaining arguments
    var arguments: [64][]const u8 = undefined;
    var arg_count: usize = 0;

    var i: usize = 2;
    while (i < args_len and arg_count < arguments.len) : (i += 1) {
        arguments[arg_count] = args_arr[i];
        arg_count += 1;
    }

    doFormat(format, arguments[0..arg_count]);
}
