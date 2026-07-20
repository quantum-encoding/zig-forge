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

// Upper bound on a printf field width / precision parsed from `-f`. Bounds the
// accumulation (no usize overflow) and the size of every formatting buffer, so
// a hostile format string cannot panic or force an unbounded output loop.
const MAX_FIELD: usize = 4096;
// Buffer large enough to hold any single formatted number at MAX_FIELD digits
// plus sign, radix point, exponent and hex prefix.
const FMT_BUF = MAX_FIELD + 64;

// Zig 0.16 Writer abstraction.
//
// A single File.Writer is constructed once (in main) and its `interface` is
// wrapped here. Constructing a fresh File.Writer per print — the previous
// design — reset a seekable fd's position to 0 on every call, so every write
// to a regular file clobbered the previous one at offset 0 (`zseq 5 > f`
// produced a 1-byte file). The writer must be built ONCE and flushed ONCE.
const Writer = struct {
    w: *std.Io.Writer,
    // stderr stays effectively unbuffered (flush after each message) so that
    // diagnostics survive the std.process.exit() calls that follow them;
    // stdout is buffered and flushed exactly once at the end of main.
    flush_each: bool = false,

    pub fn print(self: *Writer, comptime fmt: []const u8, args: anytype) void {
        self.w.print(fmt, args) catch return;
        if (self.flush_each) self.w.flush() catch {};
    }

    pub fn flush(self: *Writer) void {
        self.w.flush() catch {};
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

    // One buffered stdout writer for the whole run (flushed once at the end);
    // an effectively line-flushed stderr writer for diagnostics.
    const io = std.Io.Threaded.global_single_threaded.io();
    var out_buf: [8192]u8 = undefined;
    var out_fw = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var out = Writer{ .w = &out_fw.interface, .flush_each = false };

    var err_buf: [4096]u8 = undefined;
    var err_fw = std.Io.File.stderr().writerStreaming(io, &err_buf);
    var err = Writer{ .w = &err_fw.interface, .flush_each = true };

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
            } else if (std.mem.eql(u8, arg, "--help")) {
                // GNU writes --help to stdout and exits 0 (GNU seq has no -h).
                printHelp(&out);
                out.flush();
                return;
            } else if (std.mem.eql(u8, arg, "--version")) {
                // GNU writes --version to stdout and exits 0 (GNU seq has no -V).
                out.print("zseq {s}\n", .{VERSION});
                out.flush();
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
            last = parseOperand(&err, positional_args.items[0]);
            max_precision = getDecimalPrecision(positional_args.items[0]);
        },
        2 => {
            first = parseOperand(&err, positional_args.items[0]);
            last = parseOperand(&err, positional_args.items[1]);
            max_precision = @max(getDecimalPrecision(positional_args.items[0]), getDecimalPrecision(positional_args.items[1]));
        },
        3 => {
            first = parseOperand(&err, positional_args.items[0]);
            increment = parseOperand(&err, positional_args.items[1]);
            last = parseOperand(&err, positional_args.items[2]);
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

            // No-progress guard: when |current| is so large that adding the
            // increment leaves the f64 value unchanged (e.g. `zseq 1e19 1e19`),
            // accumulation would loop forever. GNU seq stops here too, emitting
            // the single value it managed to produce.
            const prev = current;
            current += increment;
            if (current == prev) break;
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

            const prev = current;
            current += increment;
            if (current == prev) break;
        }
    }

    // Print final newline, then flush the single buffered stdout writer once.
    if (!is_first_output) {
        out.print("\n", .{});
    }
    out.flush();
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

            // Parse width. Cap the accumulation so a pathological format like
            // "%99999999999999999999f" can neither overflow usize (a Debug
            // panic) nor drive an unbounded padding loop.
            var width: ?usize = null;
            if (j < fmt.len and fmt[j] >= '1' and fmt[j] <= '9') {
                var w: usize = 0;
                while (j < fmt.len and fmt[j] >= '0' and fmt[j] <= '9') {
                    if (w <= MAX_FIELD) w = w * 10 + (fmt[j] - '0');
                    j += 1;
                }
                width = @min(w, MAX_FIELD);
            }

            // Parse precision (same bound as width).
            var precision: ?usize = null;
            if (j < fmt.len and fmt[j] == '.') {
                j += 1;
                var p: usize = 0;
                while (j < fmt.len and fmt[j] >= '0' and fmt[j] <= '9') {
                    if (p <= MAX_FIELD) p = p * 10 + (fmt[j] - '0');
                    j += 1;
                }
                precision = @min(p, MAX_FIELD);
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
    var buf: [FMT_BUF]u8 = undefined;
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

// %f / %F — fixed-point. Delegated to std.fmt, which rounds correctly (half to
// even, like C printf) and handles the full f64 magnitude range. The previous
// hand-rolled version truncated the final digit and panicked via @intFromFloat
// on |value| > ~9.2e18 (beyond i64 range).
fn formatDecimal(buf: []u8, num: f64, precision: usize, uppercase: bool) []u8 {
    _ = uppercase;
    return std.fmt.bufPrint(buf, "{[v]d:.[p]}", .{ .v = num, .p = precision }) catch return buf[0..0];
}

// %e / %E — scientific notation with a C/printf-style exponent (sign + at least
// two digits, e.g. `1.500000e+06`). std.fmt's `{e}` rounds the mantissa but
// prints the exponent as `e6` / `e-5`, so we reformat only the exponent tail.
fn formatExponential(buf: []u8, num: f64, precision: usize, uppercase: bool) []u8 {
    var tmp: [FMT_BUF]u8 = undefined;
    const z = std.fmt.bufPrint(&tmp, "{[v]e:.[p]}", .{ .v = num, .p = precision }) catch return buf[0..0];
    const epos = std.mem.indexOfScalar(u8, z, 'e') orelse return buf[0..0];
    const mant = z[0..epos];
    const exp_val = std.fmt.parseInt(i32, z[epos + 1 ..], 10) catch 0;

    var pos: usize = 0;
    if (mant.len > buf.len) return buf[0..0];
    @memcpy(buf[0..mant.len], mant);
    pos = mant.len;
    buf[pos] = if (uppercase) 'E' else 'e';
    pos += 1;

    var e = exp_val;
    if (e < 0) {
        buf[pos] = '-';
        pos += 1;
        e = -e;
    } else {
        buf[pos] = '+';
        pos += 1;
    }
    var eb: [12]u8 = undefined;
    const es = std.fmt.bufPrint(&eb, "{d}", .{@as(u32, @intCast(e))}) catch return buf[0..0];
    if (es.len < 2) {
        buf[pos] = '0';
        pos += 1;
    }
    @memcpy(buf[pos .. pos + es.len], es);
    pos += es.len;
    return buf[0..pos];
}

// %g / %G — the C rule: precision is the number of *significant* digits (min 1);
// choose %e when the decimal exponent X < -4 or X >= precision, otherwise %f;
// then strip trailing zeros and a dangling radix point.
fn formatGeneral(buf: []u8, num: f64, precision: usize, uppercase: bool) []u8 {
    const P: usize = if (precision == 0) 1 else precision;

    // Determine the post-rounding decimal exponent X via an %e formatting.
    var etmp: [FMT_BUF]u8 = undefined;
    const es = std.fmt.bufPrint(&etmp, "{[v]e:.[p]}", .{ .v = num, .p = P - 1 }) catch return buf[0..0];
    const epos = std.mem.indexOfScalar(u8, es, 'e') orelse return buf[0..0];
    const x: i32 = std.fmt.parseInt(i32, es[epos + 1 ..], 10) catch 0;

    var raw: [FMT_BUF]u8 = undefined;
    var s: []u8 = undefined;
    var exp_style = false;
    if (x >= -4 and x < @as(i32, @intCast(P))) {
        // %f with precision P-1-X (X may be negative, widening the precision).
        const fprec: usize = @intCast(@as(i32, @intCast(P)) - 1 - x);
        s = formatDecimal(&raw, num, fprec, uppercase);
    } else {
        s = formatExponential(&raw, num, P - 1, uppercase);
        exp_style = true;
    }
    return stripTrailingZeros(buf, s, exp_style);
}

// Remove trailing fractional zeros (and a trailing '.') from a formatted value.
// For exponential style, the fractional part precedes the 'e'/'E' exponent tail.
fn stripTrailingZeros(buf: []u8, s: []const u8, exp_style: bool) []u8 {
    var mant_end = s.len;
    var tail: []const u8 = s[s.len..];
    if (exp_style) {
        const epos = std.mem.indexOfAny(u8, s, "eE") orelse s.len;
        mant_end = epos;
        tail = s[epos..];
    }
    if (std.mem.indexOfScalar(u8, s[0..mant_end], '.') != null) {
        while (mant_end > 0 and s[mant_end - 1] == '0') mant_end -= 1;
        if (mant_end > 0 and s[mant_end - 1] == '.') mant_end -= 1;
    }
    const total = mant_end + tail.len;
    if (total > buf.len) return buf[0..0];
    @memcpy(buf[0..mant_end], s[0..mant_end]);
    @memcpy(buf[mant_end..total], tail);
    return buf[0..total];
}

// %a / %A — C99 hexadecimal float. std.fmt's `{x}` produces a valid hex-float
// but omits the '+' on a non-negative binary exponent (`0x1p0` vs C's
// `0x1p+0`); insert it. Explicit precision on %a is not honored (best effort);
// the previous stub printed the raw IEEE-754 bit pattern, which was invalid.
fn formatHex(buf: []u8, num: f64, precision: usize, uppercase: bool) []u8 {
    _ = precision;
    var tmp: [FMT_BUF]u8 = undefined;
    const z = std.fmt.bufPrint(&tmp, "{x}", .{num}) catch return buf[0..0];
    const ppos = std.mem.indexOfScalar(u8, z, 'p') orelse return buf[0..0];

    var pos: usize = 0;
    @memcpy(buf[0..ppos], z[0..ppos]);
    pos = ppos;
    buf[pos] = 'p';
    pos += 1;
    // Insert '+' if the exponent has no explicit sign.
    if (ppos + 1 < z.len and z[ppos + 1] != '-' and z[ppos + 1] != '+') {
        buf[pos] = '+';
        pos += 1;
    }
    const rest = z[ppos + 1 ..];
    @memcpy(buf[pos .. pos + rest.len], rest);
    pos += rest.len;

    const out = buf[0..pos];
    if (uppercase) {
        for (out) |*c| c.* = std.ascii.toUpper(c.*);
    }
    return out;
}

fn parseNumber(str: []const u8) !f64 {
    return std.fmt.parseFloat(f64, str);
}

/// Parse an operand, rejecting NaN the way GNU seq does. std.fmt.parseFloat
/// (like strtold) accepts the spellings "nan"/"inf"; GNU seq rejects NaN with
/// a dedicated diagnostic and exit status 1, but accepts infinities (an
/// infinite bound simply yields an empty or unbounded sequence).
fn parseOperand(err: *Writer, str: []const u8) f64 {
    const v = parseNumber(str) catch {
        err.print("zseq: invalid floating point argument: '{s}'\n", .{str});
        std.process.exit(1);
    };
    if (std.math.isNan(v)) {
        err.print("zseq: invalid 'not-a-number' argument: '{s}'\n", .{str});
        std.process.exit(1);
    }
    return v;
}

fn getDecimalPrecision(str: []const u8) usize {
    if (std.mem.indexOfScalar(u8, str, '.')) |dot_pos| {
        return str.len - dot_pos - 1;
    }
    return 0;
}

fn getWidthWithPrecision(num: f64, precision: usize) usize {
    var buf: [FMT_BUF]u8 = undefined;
    const slice = formatNumber(&buf, num, precision);
    return slice.len;
}

// Default (no -f) rendering: GNU seq prints every value with a *fixed* number
// of fractional digits equal to the largest decimal precision among the
// operands (`%.<prec>f`). Delegating to std.fmt rounds correctly and handles
// the full f64 magnitude range; the previous @intFromFloat split panicked for
// |value| beyond i64 (e.g. `zseq -w 1e19 1e19`).
fn formatNumber(buf: []u8, num: f64, precision: usize) []u8 {
    return std.fmt.bufPrint(buf, "{[v]d:.[p]}", .{ .v = num, .p = precision }) catch return buf[0..0];
}

fn printNumber(writer: *Writer, num: f64, precision: usize) void {
    var buf: [FMT_BUF]u8 = undefined;
    const slice = formatNumber(&buf, num, precision);
    writer.print("{s}", .{slice});
}

fn printWithWidth(writer: *Writer, num: f64, width: usize, precision: usize) void {
    var buf: [FMT_BUF]u8 = undefined;
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
        \\      --help              display this help and exit
        \\      --version           output version information and exit
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
