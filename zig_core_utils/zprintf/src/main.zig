//! zprintf - Format and print data
//!
//! High-performance printf implementation in Zig, aiming for GNU `printf`
//! (coreutils) parity. Numeric and floating-point field formatting is
//! delegated to libc `snprintf` so the byte output matches C/GNU exactly;
//! the argument *parsing* (overflow clamping, leading-quote char codes,
//! base detection, diagnostics) is done here to match GNU semantics that
//! plain `snprintf` does not provide.

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

extern "c" fn snprintf(buf: [*]u8, size: usize, fmt: [*:0]const u8, ...) c_int;

/// Process-wide exit status. GNU printf keeps producing output after a
/// recoverable error (e.g. "Result too large") but exits non-zero.
var g_exit_status: u8 = 0;
/// Allocator for transient snprintf scratch buffers, set in main().
var g_alloc: std.mem.Allocator = undefined;

// ---------------------------------------------------------------------------
// Low-level output (handles short writes / EINTR; propagates errors to status)
// ---------------------------------------------------------------------------

fn writeAll(fd: libc.fd_t, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = libc.write(fd, data.ptr + off, data.len - off);
        if (n < 0) {
            const e = libc._errno().*;
            if (e == @intFromEnum(libc.E.INTR)) continue;
            g_exit_status = 1;
            return;
        }
        if (n == 0) {
            g_exit_status = 1;
            return;
        }
        off += @intCast(n);
    }
}

fn writeStdout(data: []const u8) void {
    writeAll(libc.STDOUT_FILENO, data);
}

fn writeStderr(data: []const u8) void {
    writeAll(libc.STDERR_FILENO, data);
}

fn writeChar(c: u8) void {
    const buf = [1]u8{c};
    writeStdout(&buf);
}

/// Emit `printf: '<arg>': <msg>` to stderr and mark the run as failed.
fn reportError(arg: []const u8, msg: []const u8) void {
    writeStderr("printf: '");
    writeStderr(arg);
    writeStderr("': ");
    writeStderr(msg);
    writeStderr("\n");
    g_exit_status = 1;
}

fn reportInvalidSpec(c: u8) void {
    writeStderr("printf: %");
    if (c != 0) {
        const b = [1]u8{c};
        writeStderr(&b);
    }
    writeStderr(": invalid conversion specification\n");
    g_exit_status = 1;
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
        \\Width and precision: %10s, %.5s, %10.5s, %.3f (also dynamic: %*d, %.*f)
        \\Flags: - (left), + (sign), 0 (zero-pad), # (alternate)
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zprintf " ++ VERSION ++ "\n");
}

// ---------------------------------------------------------------------------
// Format-string escape sequences (\n, \t, \0NNN, \xHH ...)
// ---------------------------------------------------------------------------

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
                    val = val *% 8 +% (d - '0');
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
                if (digitVal(d, 16)) |dv| {
                    val = val *% 16 +% dv;
                    pos.* += 1;
                    digits += 1;
                } else break;
            }
            break :blk val;
        },
        else => c,
    };
}

// ---------------------------------------------------------------------------
// Conversion specification parsing
// ---------------------------------------------------------------------------

pub const FormatSpec = struct {
    left_align: bool = false,
    show_sign: bool = false,
    space_sign: bool = false,
    zero_pad: bool = false,
    alternate: bool = false,
    width: usize = 0,
    width_star: bool = false,
    precision: ?usize = null,
    prec_star: bool = false,
    specifier: u8 = 0,
    has_conversion: bool = false,
};

fn parseFormat(fmt: []const u8, pos: *usize) FormatSpec {
    var spec = FormatSpec{};

    // Flags
    while (pos.* < fmt.len) {
        switch (fmt[pos.*]) {
            '-' => spec.left_align = true,
            '+' => spec.show_sign = true,
            ' ' => spec.space_sign = true,
            '0' => spec.zero_pad = true,
            '#' => spec.alternate = true,
            else => break,
        }
        pos.* += 1;
    }

    // Width (numeric or '*')
    if (pos.* < fmt.len and fmt[pos.*] == '*') {
        spec.width_star = true;
        pos.* += 1;
    } else {
        while (pos.* < fmt.len) {
            const c = fmt[pos.*];
            if (c >= '0' and c <= '9') {
                spec.width = spec.width * 10 + (c - '0');
                pos.* += 1;
            } else break;
        }
    }

    // Precision (numeric or '*')
    if (pos.* < fmt.len and fmt[pos.*] == '.') {
        pos.* += 1;
        if (pos.* < fmt.len and fmt[pos.*] == '*') {
            spec.prec_star = true;
            pos.* += 1;
        } else {
            spec.precision = 0;
            while (pos.* < fmt.len) {
                const c = fmt[pos.*];
                if (c >= '0' and c <= '9') {
                    spec.precision = spec.precision.? * 10 + (c - '0');
                    pos.* += 1;
                } else break;
            }
        }
    }

    // Conversion specifier
    if (pos.* < fmt.len) {
        spec.specifier = fmt[pos.*];
        spec.has_conversion = true;
        pos.* += 1;
    }

    return spec;
}

/// Build a C printf conversion spec (e.g. "%-+08.3lld") into `out`, returning
/// a null-terminated slice. Flags/width/precision come from `spec`.
pub fn buildCFmt(out: []u8, spec: *const FormatSpec, len_mod: []const u8, conv: u8) [:0]const u8 {
    var i: usize = 0;
    out[i] = '%';
    i += 1;
    if (spec.left_align) {
        out[i] = '-';
        i += 1;
    }
    if (spec.show_sign) {
        out[i] = '+';
        i += 1;
    }
    if (spec.space_sign) {
        out[i] = ' ';
        i += 1;
    }
    if (spec.alternate) {
        out[i] = '#';
        i += 1;
    }
    if (spec.zero_pad) {
        out[i] = '0';
        i += 1;
    }
    if (spec.width > 0) i += writeUintDec(out[i..], spec.width);
    if (spec.precision) |p| {
        out[i] = '.';
        i += 1;
        i += writeUintDec(out[i..], p);
    }
    for (len_mod) |ch| {
        out[i] = ch;
        i += 1;
    }
    out[i] = conv;
    i += 1;
    out[i] = 0;
    return out[0..i :0];
}

pub fn writeUintDec(buf: []u8, val: usize) usize {
    if (val == 0) {
        buf[0] = '0';
        return 1;
    }
    var tmp: [20]u8 = undefined;
    var i: usize = 0;
    var v = val;
    while (v > 0) : (v /= 10) {
        tmp[i] = '0' + @as(u8, @intCast(v % 10));
        i += 1;
    }
    var j: usize = 0;
    while (j < i) : (j += 1) buf[j] = tmp[i - 1 - j];
    return i;
}

// ---------------------------------------------------------------------------
// libc-backed field emission (exact C/GNU byte formatting)
// ---------------------------------------------------------------------------

/// Render `value` with C printf semantics using the flags/width/precision in
/// `spec`. `value` must match `len_mod`+`conv` (e.g. c_longlong for "ll"+'d').
fn emitC(spec: *const FormatSpec, len_mod: []const u8, conv: u8, value: anytype) void {
    // Integer part of a double can be ~309 chars; add generous headroom.
    const size = spec.width + (spec.precision orelse 0) + 1024;
    const buf = g_alloc.alloc(u8, size) catch return;
    defer g_alloc.free(buf);

    var fbuf: [64]u8 = undefined;
    const cf = buildCFmt(&fbuf, spec, len_mod, conv);
    const n = snprintf(buf.ptr, size, cf.ptr, value);
    if (n > 0) {
        const un: usize = @intCast(n);
        writeStdout(buf[0..@min(un, size - 1)]);
    }
}

// ---------------------------------------------------------------------------
// Numeric argument parsing (GNU semantics: quote char-codes, base, overflow)
// ---------------------------------------------------------------------------

pub fn digitVal(c: u8, base: u8) ?u8 {
    const v: u8 = switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => return null,
    };
    if (v >= base) return null;
    return v;
}

/// POSIX/GNU: a numeric argument beginning with ' or " has the value of the
/// numeric code of the following byte. Returns null if not a quote arg.
pub fn quoteCharValue(s: []const u8) ?u64 {
    if (s.len >= 2 and (s[0] == '\'' or s[0] == '"')) {
        if (s.len > 2) {
            // GNU warns (but does not fail) when extra chars follow.
            writeStderr("printf: warning: ");
            writeStderr(s[2..]);
            writeStderr(": character(s) following character constant have been ignored\n");
        }
        return s[1];
    }
    if (s.len == 1 and (s[0] == '\'' or s[0] == '"')) return 0;
    return null;
}

/// Parse a signed integer argument, clamping to i64 range like GNU strtoimax
/// (emitting "Result too large" on overflow) and honoring leading-quote codes.
pub fn parseSigned(arg: []const u8) i64 {
    if (quoteCharValue(arg)) |v| return @intCast(v);

    var i: usize = 0;
    while (i < arg.len and (arg[i] == ' ' or arg[i] == '\t')) i += 1; // strtoimax skips leading ws
    var negative = false;
    if (i < arg.len and arg[i] == '-') {
        negative = true;
        i += 1;
    } else if (i < arg.len and arg[i] == '+') {
        i += 1;
    }

    var base: u8 = 10;
    if (i + 1 < arg.len and arg[i] == '0' and (arg[i + 1] == 'x' or arg[i + 1] == 'X')) {
        base = 16;
        i += 2;
    } else if (i < arg.len and arg[i] == '0') {
        base = 8; // keep the leading '0' as a digit
    }

    const digits_start = i;
    var mag: u64 = 0;
    var overflow = false;
    while (i < arg.len) : (i += 1) {
        const d = digitVal(arg[i], base) orelse break;
        const m = @mulWithOverflow(mag, base);
        const a = @addWithOverflow(m[0], @as(u64, d));
        if (m[1] != 0 or a[1] != 0) {
            overflow = true;
        } else {
            mag = a[0];
        }
    }

    if (i == digits_start and arg.len != 0) {
        reportError(arg, "expected a numeric value");
        return 0;
    }
    if (i < arg.len) {
        reportError(arg, "value not completely converted");
    }

    const i64_min_mag: u64 = @as(u64, 1) << 63;
    if (negative) {
        if (overflow or mag > i64_min_mag) {
            reportError(arg, "Result too large");
            return std.math.minInt(i64);
        }
        if (mag == i64_min_mag) return std.math.minInt(i64);
        return -@as(i64, @intCast(mag));
    } else {
        if (overflow or mag > std.math.maxInt(i64)) {
            reportError(arg, "Result too large");
            return std.math.maxInt(i64);
        }
        return @intCast(mag);
    }
}

/// Parse an unsigned integer argument, clamping to u64 range; negative inputs
/// wrap two's-complement like GNU strtoumax.
pub fn parseUnsigned(arg: []const u8) u64 {
    if (quoteCharValue(arg)) |v| return v;

    var i: usize = 0;
    while (i < arg.len and (arg[i] == ' ' or arg[i] == '\t')) i += 1; // strtoumax skips leading ws
    var negative = false;
    if (i < arg.len and arg[i] == '-') {
        negative = true;
        i += 1;
    } else if (i < arg.len and arg[i] == '+') {
        i += 1;
    }

    var base: u8 = 10;
    if (i + 1 < arg.len and arg[i] == '0' and (arg[i + 1] == 'x' or arg[i + 1] == 'X')) {
        base = 16;
        i += 2;
    } else if (i < arg.len and arg[i] == '0') {
        base = 8;
    }

    const digits_start = i;
    var mag: u64 = 0;
    var overflow = false;
    while (i < arg.len) : (i += 1) {
        const d = digitVal(arg[i], base) orelse break;
        const m = @mulWithOverflow(mag, base);
        const a = @addWithOverflow(m[0], @as(u64, d));
        if (m[1] != 0 or a[1] != 0) {
            overflow = true;
        } else {
            mag = a[0];
        }
    }

    if (i == digits_start and arg.len != 0) {
        reportError(arg, "expected a numeric value");
        return 0;
    }
    if (i < arg.len) {
        reportError(arg, "value not completely converted");
    }
    if (overflow) {
        reportError(arg, "Result too large");
        return std.math.maxInt(u64);
    }

    return if (negative) 0 -% mag else mag;
}

fn parseFloat(arg: []const u8) f64 {
    if (quoteCharValue(arg)) |v| return @floatFromInt(v);
    var s = arg;
    while (s.len > 0 and (s[0] == ' ' or s[0] == '\t')) s = s[1..]; // skip leading ws
    if (s.len == 0) return 0.0;
    return std.fmt.parseFloat(f64, s) catch {
        reportError(arg, "expected a numeric value");
        return 0.0;
    };
}

// ---------------------------------------------------------------------------
// %b (backslash-escape interpretation) and %q (shell quoting)
// ---------------------------------------------------------------------------

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
                        val = val *% 8 +% (arg[pos] - '0');
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
                        if (digitVal(arg[pos], 16)) |dv| {
                            val = val *% 16 +% dv;
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

// ---------------------------------------------------------------------------
// String field emission (%s) — width + precision, matching GNU.
// ---------------------------------------------------------------------------

fn printString(data: []const u8, spec: *const FormatSpec) void {
    var output = data;
    if (spec.precision) |prec| {
        if (output.len > prec) output = output[0..prec];
    }

    const pad_len = if (spec.width > output.len) spec.width - output.len else 0;
    if (!spec.left_align) {
        var p: usize = 0;
        while (p < pad_len) : (p += 1) writeChar(' ');
    }
    writeStdout(output);
    if (spec.left_align) {
        var p: usize = 0;
        while (p < pad_len) : (p += 1) writeChar(' ');
    }
}

// ---------------------------------------------------------------------------
// Core format loop
// ---------------------------------------------------------------------------

fn doFormat(fmt: []const u8, arguments: []const []const u8) void {
    var arg_idx: usize = 0;

    // Reuse the format string while arguments remain (GNU behavior).
    var first_pass = true;
    while (first_pass or arg_idx < arguments.len) {
        first_pass = false;
        var pos: usize = 0;
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
                    // Trailing bare '%' is an error in GNU.
                    reportInvalidSpec(0);
                    return;
                }

                if (fmt[pos] == '%') {
                    writeChar('%');
                    pos += 1;
                    continue;
                }

                var spec = parseFormat(fmt, &pos);
                if (!spec.has_conversion) {
                    reportInvalidSpec(0);
                    return;
                }

                // Resolve dynamic width/precision ('*'): consumes arguments.
                if (spec.width_star) {
                    const wv = parseSigned(if (arg_idx < arguments.len) arguments[arg_idx] else "");
                    if (arguments.len > 0) arg_idx += 1;
                    used_arg_this_pass = true;
                    if (wv < 0) {
                        spec.left_align = true;
                        spec.width = @intCast(-wv);
                    } else {
                        spec.width = @intCast(wv);
                    }
                }
                if (spec.prec_star) {
                    const pv = parseSigned(if (arg_idx < arguments.len) arguments[arg_idx] else "");
                    if (arguments.len > 0) arg_idx += 1;
                    used_arg_this_pass = true;
                    // Negative precision means "as if omitted" (C semantics).
                    spec.precision = if (pv < 0) null else @intCast(pv);
                }

                const arg = if (arg_idx < arguments.len) arguments[arg_idx] else "";
                used_arg_this_pass = true;

                switch (spec.specifier) {
                    's' => printString(arg, &spec),
                    'b' => {
                        const result = processBackslashEscapes(arg);
                        if (result.stop) return;
                    },
                    'q' => shellQuote(arg),
                    'd', 'i' => emitC(&spec, "ll", 'd', @as(c_longlong, parseSigned(arg))),
                    'u' => emitC(&spec, "ll", 'u', @as(c_ulonglong, parseUnsigned(arg))),
                    'o' => emitC(&spec, "ll", 'o', @as(c_ulonglong, parseUnsigned(arg))),
                    'x' => emitC(&spec, "ll", 'x', @as(c_ulonglong, parseUnsigned(arg))),
                    'X' => emitC(&spec, "ll", 'X', @as(c_ulonglong, parseUnsigned(arg))),
                    'c' => {
                        var cspec = spec;
                        cspec.precision = null;
                        cspec.zero_pad = false;
                        const ch: c_int = if (arg.len > 0) arg[0] else 0;
                        emitC(&cspec, "", 'c', ch);
                    },
                    'f', 'F', 'e', 'E', 'g', 'G', 'a', 'A' => {
                        emitC(&spec, "", spec.specifier, parseFloat(arg));
                    },
                    else => {
                        reportInvalidSpec(spec.specifier);
                        return;
                    },
                }

                if (arguments.len > 0) arg_idx += 1;
            } else {
                writeChar(c);
                pos += 1;
            }
        } // end inner while (format string)

        // No format specifier consumed an arg this pass -> stop (avoid loop).
        if (!used_arg_this_pass) break;
    } // end outer while (reuse format for remaining args)
}

pub fn main(init: std.process.Init) void {
    g_alloc = init.gpa;

    // Collect args dynamically (no arbitrary 64-arg cap).
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(g_alloc);

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        args_list.append(g_alloc, arg) catch {
            writeStderr("printf: out of memory\n");
            std.process.exit(1);
        };
    }
    const args_arr = args_list.items;

    if (args_arr.len < 2) {
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

    const format = first_arg;
    const arguments = args_arr[2..];

    doFormat(format, arguments);

    if (g_exit_status != 0) std.process.exit(g_exit_status);
}
