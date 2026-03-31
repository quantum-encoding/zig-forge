//! zseq - Print a sequence of numbers
//!
//! A high-performance Zig implementation of the GNU seq utility.
//! Prints sequences of numbers with customizable format, separator, and width.
//!
//! Usage: zseq [OPTION]... LAST
//!        zseq [OPTION]... FIRST LAST
//!        zseq [OPTION]... FIRST INCREMENT LAST

const std = @import("std");

const VERSION = "1.0.0";

// Zig 0.16 Writer abstraction
const Writer = struct {
    io: std.Io,
    buffer: *[8192]u8,
    file: std.Io.File,

    pub fn stdout() Writer {
        const io_instance = std.Io.Threaded.global_single_threaded.io();
        const static = struct {
            var buffer: [8192]u8 = undefined;
        };
        return Writer{
            .io = io_instance,
            .buffer = &static.buffer,
            .file = std.Io.File.stdout(),
        };
    }

    pub fn stderr() Writer {
        const io_instance = std.Io.Threaded.global_single_threaded.io();
        const static = struct {
            var buffer: [8192]u8 = undefined;
        };
        return Writer{
            .io = io_instance,
            .buffer = &static.buffer,
            .file = std.Io.File.stderr(),
        };
    }

    pub fn print(self: *Writer, comptime fmt: []const u8, args: anytype) void {
        var writer = self.file.writer(self.io, self.buffer);
        writer.interface.print(fmt, args) catch {};
        writer.interface.flush() catch {};
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var out = Writer.stdout();
    var err = Writer.stderr();

    // Parse options
    var separator: []const u8 = "\n";
    var equal_width = false;
    var format_string: ?[]const u8 = null;
    var positional_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer positional_args.deinit(allocator);

    var i: usize = 1;
    var options_done = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (!options_done and arg.len > 0 and arg[0] == '-' and arg.len > 1 and !isNumericArg(arg)) {
            if (std.mem.eql(u8, arg, "--")) {
                options_done = true;
            } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                printHelp(&err);
                return;
            } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
                err.print("zseq {s}\n", .{VERSION});
                return;
            } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--equal-width")) {
                equal_width = true;
            } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--separator")) {
                if (i + 1 < args.len) {
                    i += 1;
                    separator = args[i];
                } else {
                    err.print("zseq: option requires an argument -- 's'\n", .{});
                    std.process.exit(1);
                }
            } else if (std.mem.startsWith(u8, arg, "-s")) {
                separator = arg[2..];
            } else if (std.mem.startsWith(u8, arg, "--separator=")) {
                separator = arg["--separator=".len..];
            } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--format")) {
                if (i + 1 < args.len) {
                    i += 1;
                    format_string = args[i];
                } else {
                    err.print("zseq: option requires an argument -- 'f'\n", .{});
                    std.process.exit(1);
                }
            } else if (std.mem.startsWith(u8, arg, "-f")) {
                format_string = arg[2..];
            } else if (std.mem.startsWith(u8, arg, "--format=")) {
                format_string = arg["--format=".len..];
            } else {
                err.print("zseq: invalid option -- '{s}'\n", .{arg[1..]});
                err.print("Try 'zseq --help' for more information.\n", .{});
                std.process.exit(1);
            }
        } else {
            try positional_args.append(allocator, arg);
        }
    }

    // Validate format string if provided
    var parsed_format: ?ParsedFormat = null;
    if (format_string) |fmt| {
        parsed_format = parseFormatString(fmt) orelse {
            err.print("zseq: format '{s}' has no % directive\n", .{fmt});
            std.process.exit(1);
        };
        if (parsed_format.?.invalid) {
            err.print("zseq: format '{s}' has unknown %{c} directive\n", .{ fmt, parsed_format.?.specifier });
            std.process.exit(1);
        }
    }

    // Parse FIRST, INCREMENT, LAST from positional args
    var first: f64 = 1.0;
    var increment: f64 = 1.0;
    var last: f64 = undefined;
    var max_precision: usize = 0; // Track decimal precision from input

    switch (positional_args.items.len) {
        0 => {
            err.print("zseq: missing operand\n", .{});
            err.print("Try 'zseq --help' for more information.\n", .{});
            std.process.exit(1);
        },
        1 => {
            last = parseNumber(positional_args.items[0]) catch {
                err.print("zseq: invalid floating point argument: '{s}'\n", .{positional_args.items[0]});
                std.process.exit(1);
            };
            max_precision = getDecimalPrecision(positional_args.items[0]);
        },
        2 => {
            first = parseNumber(positional_args.items[0]) catch {
                err.print("zseq: invalid floating point argument: '{s}'\n", .{positional_args.items[0]});
                std.process.exit(1);
            };
            last = parseNumber(positional_args.items[1]) catch {
                err.print("zseq: invalid floating point argument: '{s}'\n", .{positional_args.items[1]});
                std.process.exit(1);
            };
            max_precision = @max(getDecimalPrecision(positional_args.items[0]), getDecimalPrecision(positional_args.items[1]));
        },
        3 => {
            first = parseNumber(positional_args.items[0]) catch {
                err.print("zseq: invalid floating point argument: '{s}'\n", .{positional_args.items[0]});
                std.process.exit(1);
            };
            increment = parseNumber(positional_args.items[1]) catch {
                err.print("zseq: invalid floating point argument: '{s}'\n", .{positional_args.items[1]});
                std.process.exit(1);
            };
            last = parseNumber(positional_args.items[2]) catch {
                err.print("zseq: invalid floating point argument: '{s}'\n", .{positional_args.items[2]});
                std.process.exit(1);
            };
            max_precision = @max(getDecimalPrecision(positional_args.items[0]), @max(getDecimalPrecision(positional_args.items[1]), getDecimalPrecision(positional_args.items[2])));
        },
        else => {
            err.print("zseq: extra operand '{s}'\n", .{positional_args.items[3]});
            err.print("Try 'zseq --help' for more information.\n", .{});
            std.process.exit(1);
        },
    }

    // Validate increment
    if (increment == 0.0) {
        err.print("zseq: zero increment\n", .{});
        std.process.exit(1);
    }

    // Calculate width for -w option
    var width: usize = 0;
    if (equal_width) {
        width = @max(getWidthWithPrecision(first, max_precision), getWidthWithPrecision(last, max_precision));
    }

    // Generate sequence
    var is_first_output = true;
    var current = first;

    if (increment > 0) {
        while (current <= last + 0.0000001) {
            if (!is_first_output) {
                out.print("{s}", .{separator});
            }
            is_first_output = false;

            if (parsed_format) |pf| {
                printFormatted(&out, current, pf);
            } else if (equal_width) {
                printWithWidth(&out, current, width, max_precision);
            } else {
                printNumber(&out, current, max_precision);
            }

            current += increment;
        }
    } else {
        while (current >= last - 0.0000001) {
            if (!is_first_output) {
                out.print("{s}", .{separator});
            }
            is_first_output = false;

            if (parsed_format) |pf| {
                printFormatted(&out, current, pf);
            } else if (equal_width) {
                printWithWidth(&out, current, width, max_precision);
            } else {
                printNumber(&out, current, max_precision);
            }

            current += increment;
        }
    }

    // Print final newline
    if (!is_first_output) {
        out.print("\n", .{});
    }
}

fn isNumericArg(arg: []const u8) bool {
    if (arg.len == 0) return false;
    var idx: usize = 0;
    if (arg[0] == '-' or arg[0] == '+') idx = 1;
    if (idx >= arg.len) return false;

    var has_digit = false;
    var has_dot = false;

    while (idx < arg.len) : (idx += 1) {
        const c = arg[idx];
        if (c >= '0' and c <= '9') {
            has_digit = true;
        } else if (c == '.' and !has_dot) {
            has_dot = true;
        } else if (c == 'e' or c == 'E') {
            idx += 1;
            if (idx < arg.len and (arg[idx] == '+' or arg[idx] == '-')) {
                idx += 1;
            }
            if (idx >= arg.len) return false;
            while (idx < arg.len) : (idx += 1) {
                if (arg[idx] < '0' or arg[idx] > '9') return false;
            }
            return has_digit;
        } else {
            return false;
        }
    }
    return has_digit;
}

// Printf-style format parsing
const ParsedFormat = struct {
    prefix: []const u8, // Text before %
    suffix: []const u8, // Text after specifier
    specifier: u8, // e, E, f, F, g, G, a, A
    width: ?usize, // Minimum field width
    precision: ?usize, // Decimal places
    left_align: bool, // - flag
    plus_sign: bool, // + flag
    space_sign: bool, // space flag
    alt_form: bool, // # flag
    zero_pad: bool, // 0 flag
    invalid: bool, // Unknown specifier
};

fn parseFormatString(fmt: []const u8) ?ParsedFormat {
    // Find the % conversion specifier
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        if (fmt[i] == '%') {
            if (i + 1 < fmt.len and fmt[i + 1] == '%') {
                i += 1; // Skip %%
                continue;
            }
            // Found a conversion
            const prefix = fmt[0..i];
            var j = i + 1;

            // Parse flags
            var left_align = false;
            var plus_sign = false;
            var space_sign = false;
            var alt_form = false;
            var zero_pad = false;

            while (j < fmt.len) {
                switch (fmt[j]) {
                    '-' => left_align = true,
                    '+' => plus_sign = true,
                    ' ' => space_sign = true,
                    '#' => alt_form = true,
                    '0' => zero_pad = true,
                    else => break,
                }
                j += 1;
            }

            // Parse width
            var width: ?usize = null;
            if (j < fmt.len and fmt[j] >= '1' and fmt[j] <= '9') {
                var w: usize = 0;
                while (j < fmt.len and fmt[j] >= '0' and fmt[j] <= '9') {
                    w = w * 10 + (fmt[j] - '0');
                    j += 1;
                }
                width = w;
            }

            // Parse precision
            var precision: ?usize = null;
            if (j < fmt.len and fmt[j] == '.') {
                j += 1;
                var p: usize = 0;
                while (j < fmt.len and fmt[j] >= '0' and fmt[j] <= '9') {
                    p = p * 10 + (fmt[j] - '0');
                    j += 1;
                }
                precision = p;
            }

            // Parse specifier
            if (j >= fmt.len) return null;
            const spec = fmt[j];
            const valid = switch (spec) {
                'e', 'E', 'f', 'F', 'g', 'G', 'a', 'A' => true,
                else => false,
            };

            return ParsedFormat{
                .prefix = prefix,
                .suffix = fmt[j + 1 ..],
                .specifier = spec,
                .width = width,
                .precision = precision,
                .left_align = left_align,
                .plus_sign = plus_sign,
                .space_sign = space_sign,
                .alt_form = alt_form,
                .zero_pad = zero_pad,
                .invalid = !valid,
            };
        }
    }
    return null; // No % found
}

fn printFormatted(writer: *Writer, num: f64, pf: ParsedFormat) void {
    // Print prefix (handling %% escapes)
    var k: usize = 0;
    while (k < pf.prefix.len) {
        if (pf.prefix[k] == '%' and k + 1 < pf.prefix.len and pf.prefix[k + 1] == '%') {
            writer.print("%", .{});
            k += 2;
        } else {
            writer.print("{c}", .{pf.prefix[k]});
            k += 1;
        }
    }

    // Format the number
    var buf: [128]u8 = undefined;
    const prec = pf.precision orelse 6;

    const formatted = switch (pf.specifier) {
        'f', 'F' => formatDecimal(&buf, num, prec, pf.specifier == 'F'),
        'e', 'E' => formatExponential(&buf, num, prec, pf.specifier == 'E'),
        'g', 'G' => formatGeneral(&buf, num, prec, pf.specifier == 'G'),
        'a', 'A' => formatHex(&buf, num, prec, pf.specifier == 'A'),
        else => formatDecimal(&buf, num, prec, false),
    };

    // Handle sign prefix
    var sign_char: ?u8 = null;
    var value_start: usize = 0;
    if (formatted.len > 0 and formatted[0] == '-') {
        sign_char = '-';
        value_start = 1;
    } else if (pf.plus_sign) {
        sign_char = '+';
    } else if (pf.space_sign) {
        sign_char = ' ';
    }

    const value_part = formatted[value_start..];
    const sign_len: usize = if (sign_char != null) 1 else 0;
    const total_len = sign_len + value_part.len;

    // Calculate padding
    const width = pf.width orelse 0;
    const padding = if (total_len < width) width - total_len else 0;

    if (pf.left_align) {
        // Left align: sign, value, padding
        if (sign_char) |s| writer.print("{c}", .{s});
        writer.print("{s}", .{value_part});
        for (0..padding) |_| writer.print(" ", .{});
    } else if (pf.zero_pad) {
        // Zero pad: sign, zeros, value
        if (sign_char) |s| writer.print("{c}", .{s});
        for (0..padding) |_| writer.print("0", .{});
        writer.print("{s}", .{value_part});
    } else {
        // Right align: padding, sign, value
        for (0..padding) |_| writer.print(" ", .{});
        if (sign_char) |s| writer.print("{c}", .{s});
        writer.print("{s}", .{value_part});
    }

    // Print suffix (handling %% escapes)
    k = 0;
    while (k < pf.suffix.len) {
        if (pf.suffix[k] == '%' and k + 1 < pf.suffix.len and pf.suffix[k + 1] == '%') {
            writer.print("%", .{});
            k += 2;
        } else {
            writer.print("{c}", .{pf.suffix[k]});
            k += 1;
        }
    }
}

fn formatDecimal(buf: []u8, num: f64, precision: usize, uppercase: bool) []u8 {
    _ = uppercase;
    // Manual precision formatting for %f
    const is_neg = num < 0;
    const abs_val = @abs(num);

    // Get integer and fractional parts
    const int_part: i64 = @intFromFloat(abs_val);
    const frac_part = abs_val - @as(f64, @floatFromInt(int_part));

    // Format integer part
    var pos: usize = 0;
    if (is_neg) {
        buf[pos] = '-';
        pos += 1;
    }

    // Integer digits
    var int_buf: [32]u8 = undefined;
    const int_str = std.fmt.bufPrint(&int_buf, "{d}", .{int_part}) catch return buf[0..0];
    @memcpy(buf[pos .. pos + int_str.len], int_str);
    pos += int_str.len;

    if (precision > 0) {
        buf[pos] = '.';
        pos += 1;

        // Generate fractional digits
        var frac = frac_part;
        for (0..precision) |_| {
            frac *= 10;
            const digit: u8 = @intFromFloat(@mod(frac, 10));
            buf[pos] = '0' + digit;
            pos += 1;
        }
    }

    return buf[0..pos];
}

fn formatExponential(buf: []u8, num: f64, precision: usize, uppercase: bool) []u8 {
    const is_neg = num < 0;
    const abs_val = @abs(num);

    var pos: usize = 0;
    if (is_neg) {
        buf[pos] = '-';
        pos += 1;
    }

    if (abs_val == 0) {
        buf[pos] = '0';
        pos += 1;
        if (precision > 0) {
            buf[pos] = '.';
            pos += 1;
            for (0..precision) |_| {
                buf[pos] = '0';
                pos += 1;
            }
        }
        buf[pos] = if (uppercase) 'E' else 'e';
        pos += 1;
        buf[pos] = '+';
        pos += 1;
        buf[pos] = '0';
        pos += 1;
        buf[pos] = '0';
        pos += 1;
        return buf[0..pos];
    }

    // Calculate exponent
    const log_val = @log10(abs_val);
    var exp: i32 = @intFromFloat(@floor(log_val));
    var mantissa = abs_val / std.math.pow(f64, 10, @as(f64, @floatFromInt(exp)));

    // Normalize mantissa to [1, 10)
    if (mantissa >= 10) {
        mantissa /= 10;
        exp += 1;
    } else if (mantissa < 1 and mantissa > 0) {
        mantissa *= 10;
        exp -= 1;
    }

    // Format mantissa
    const int_digit: u8 = @intFromFloat(mantissa);
    buf[pos] = '0' + int_digit;
    pos += 1;

    if (precision > 0) {
        buf[pos] = '.';
        pos += 1;
        var frac = mantissa - @as(f64, @floatFromInt(int_digit));
        for (0..precision) |_| {
            frac *= 10;
            const digit: u8 = @intFromFloat(@mod(frac, 10));
            buf[pos] = '0' + digit;
            pos += 1;
        }
    }

    buf[pos] = if (uppercase) 'E' else 'e';
    pos += 1;

    if (exp >= 0) {
        buf[pos] = '+';
        pos += 1;
    } else {
        buf[pos] = '-';
        pos += 1;
        exp = -exp;
    }

    // Format exponent (at least 2 digits)
    if (exp < 10) {
        buf[pos] = '0';
        pos += 1;
    }
    var exp_buf: [8]u8 = undefined;
    const exp_str = std.fmt.bufPrint(&exp_buf, "{d}", .{@as(u32, @intCast(exp))}) catch return buf[0..0];
    @memcpy(buf[pos .. pos + exp_str.len], exp_str);
    pos += exp_str.len;

    return buf[0..pos];
}

fn formatGeneral(buf: []u8, num: f64, precision: usize, uppercase: bool) []u8 {
    // Choose between f and e based on magnitude
    const abs_num = @abs(num);
    const prec = if (precision == 0) 1 else precision;
    const use_exp = abs_num != 0 and (abs_num < 0.0001 or abs_num >= std.math.pow(f64, 10, @as(f64, @floatFromInt(prec))));

    if (use_exp) {
        return formatExponential(buf, num, if (prec > 0) prec - 1 else 0, uppercase);
    } else {
        return formatDecimal(buf, num, prec, uppercase);
    }
}

fn formatHex(buf: []u8, num: f64, precision: usize, uppercase: bool) []u8 {
    // Hexadecimal floating point (simplified - treat as decimal for now)
    _ = precision;
    _ = uppercase;
    const result = std.fmt.bufPrint(buf, "{x}", .{@as(u64, @bitCast(num))}) catch return buf[0..0];
    return result;
}

fn parseNumber(str: []const u8) !f64 {
    return std.fmt.parseFloat(f64, str);
}

fn getDecimalPrecision(str: []const u8) usize {
    if (std.mem.indexOfScalar(u8, str, '.')) |dot_pos| {
        return str.len - dot_pos - 1;
    }
    return 0;
}

fn getWidthWithPrecision(num: f64, precision: usize) usize {
    var buf: [64]u8 = undefined;
    const slice = formatNumber(&buf, num, precision);
    return slice.len;
}

fn formatNumber(buf: []u8, num: f64, precision: usize) []u8 {
    const int_val: i64 = @intFromFloat(num);
    const diff = num - @as(f64, @floatFromInt(int_val));

    if (@abs(diff) < 0.0000001) {
        if (precision == 0) {
            const result = std.fmt.bufPrint(buf, "{d}", .{int_val}) catch return buf[0..0];
            return result;
        } else {
            // Format with fixed decimal precision
            const result = std.fmt.bufPrint(buf, "{d}", .{int_val}) catch return buf[0..0];
            var pos = result.len;
            buf[pos] = '.';
            pos += 1;
            for (0..precision) |_| {
                buf[pos] = '0';
                pos += 1;
            }
            return buf[0..pos];
        }
    } else {
        const result = std.fmt.bufPrint(buf, "{d:.10}", .{num}) catch return buf[0..0];
        var end = result.len;
        while (end > 0 and result[end - 1] == '0') {
            end -= 1;
        }
        if (end > 0 and result[end - 1] == '.') {
            end -= 1;
        }
        // Ensure minimum precision
        if (precision > 0) {
            // Find current decimal places
            var current_prec: usize = 0;
            if (std.mem.indexOfScalar(u8, buf[0..end], '.')) |dot| {
                current_prec = end - dot - 1;
            } else {
                buf[end] = '.';
                end += 1;
            }
            while (current_prec < precision) {
                buf[end] = '0';
                end += 1;
                current_prec += 1;
            }
        }
        return buf[0..end];
    }
}

fn printNumber(writer: *Writer, num: f64, precision: usize) void {
    var buf: [64]u8 = undefined;
    const slice = formatNumber(&buf, num, precision);
    writer.print("{s}", .{slice});
}

fn printWithWidth(writer: *Writer, num: f64, width: usize, precision: usize) void {
    var buf: [64]u8 = undefined;
    const slice = formatNumber(&buf, num, precision);

    if (slice.len < width) {
        const padding = width - slice.len;
        if (slice.len > 0 and slice[0] == '-') {
            writer.print("-", .{});
            for (0..padding) |_| {
                writer.print("0", .{});
            }
            writer.print("{s}", .{slice[1..]});
        } else {
            for (0..padding) |_| {
                writer.print("0", .{});
            }
            writer.print("{s}", .{slice});
        }
    } else {
        writer.print("{s}", .{slice});
    }
}

fn printHelp(writer: *Writer) void {
    writer.print(
        \\Usage: zseq [OPTION]... LAST
        \\  or:  zseq [OPTION]... FIRST LAST
        \\  or:  zseq [OPTION]... FIRST INCREMENT LAST
        \\
        \\Print numbers from FIRST to LAST, in steps of INCREMENT.
        \\
        \\Options:
        \\  -f, --format=FORMAT     use printf style floating-point FORMAT
        \\  -s, --separator=STRING  use STRING to separate numbers (default: \n)
        \\  -w, --equal-width       equalize width by padding with leading zeros
        \\  -h, --help              display this help and exit
        \\  -V, --version           output version information and exit
        \\
        \\If FIRST or INCREMENT is omitted, it defaults to 1.
        \\The sequence ends when the sum of current and INCREMENT exceeds LAST.
        \\
        \\Examples:
        \\  zseq 5          Print 1 2 3 4 5 (one per line)
        \\  zseq 2 5        Print 2 3 4 5
        \\  zseq 0 2 10     Print 0 2 4 6 8 10
        \\  zseq -w 0 9     Print 0 1 2 ... 9 with equal width (01, 02, ...)
        \\  zseq 5 -1 1     Print 5 4 3 2 1 (descending)
        \\
    , .{});
}
