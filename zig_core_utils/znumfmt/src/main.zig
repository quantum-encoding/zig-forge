//! znumfmt - Convert numbers to/from human-readable format
//!
//! A Zig implementation of numfmt.
//! Reformat numbers with unit suffixes (K, M, G, T, P, E, Z, Y).
//!
//! Usage: znumfmt [OPTIONS] [NUMBER]...

const std = @import("std");

const VERSION = "1.0.0";

const Format = enum {
    none,
    auto,
    si,
    iec,
    iec_i,
};

const Round = enum {
    up,
    down,
    from_zero,
    towards_zero,
    nearest,
};

const InvalidMode = enum {
    abort,
    fail,
    warn,
    ignore,
};

// C functions
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

const c_read = @extern(*const fn (c_int, [*]u8, usize) callconv(.c) isize, .{ .name = "read" });

fn writeStderr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(2, msg.ptr, msg.len);
}

fn writeStdout(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = write(1, msg.ptr, msg.len);
}

fn writeStdoutRaw(data: []const u8) void {
    var written: usize = 0;
    while (written < data.len) {
        const result = write(1, data.ptr + written, data.len - written);
        if (result <= 0) break;
        written += @intCast(result);
    }
}

/// Extract the value of a long option that takes a required argument, accepting
/// both `--opt=VALUE` and `--opt VALUE` (space-separated) forms. Advances `i`
/// past the consumed value for the space form. Returns null when `arg` is not
/// this option. Exits with GNU's status 1 when the space form has no value.
fn optValue(args: []const []const u8, i: *usize, name: []const u8) ?[]const u8 {
    const arg = args[i.*];
    if (!std.mem.startsWith(u8, arg, name)) return null;
    if (arg.len == name.len) {
        // `--opt VALUE`
        if (i.* + 1 >= args.len) {
            writeStderr("znumfmt: option '{s}' requires an argument\n", .{name});
            std.process.exit(1);
        }
        i.* += 1;
        return args[i.*];
    }
    if (arg[name.len] == '=') return arg[name.len + 1 ..];
    return null;
}

fn parseFormat(v: []const u8, opt: []const u8) Format {
    if (std.mem.eql(u8, v, "none")) return .none;
    if (std.mem.eql(u8, v, "auto")) return .auto;
    if (std.mem.eql(u8, v, "si")) return .si;
    if (std.mem.eql(u8, v, "iec")) return .iec;
    if (std.mem.eql(u8, v, "iec-i")) return .iec_i;
    writeStderr("znumfmt: invalid {s} format: '{s}'\n", .{ opt, v });
    std.process.exit(1);
}

fn parseUnit(v: []const u8, opt: []const u8) u64 {
    return std.fmt.parseInt(u64, v, 10) catch {
        writeStderr("znumfmt: invalid {s}: '{s}'\n", .{ opt, v });
        std.process.exit(1);
    };
}

fn parseRound(v: []const u8) Round {
    if (std.mem.eql(u8, v, "up")) return .up;
    if (std.mem.eql(u8, v, "down")) return .down;
    if (std.mem.eql(u8, v, "from-zero")) return .from_zero;
    if (std.mem.eql(u8, v, "towards-zero")) return .towards_zero;
    if (std.mem.eql(u8, v, "nearest")) return .nearest;
    writeStderr("znumfmt: invalid rounding method: '{s}'\n", .{v});
    std.process.exit(1);
}

fn parseInvalid(v: []const u8) InvalidMode {
    if (std.mem.eql(u8, v, "abort")) return .abort;
    if (std.mem.eql(u8, v, "fail")) return .fail;
    if (std.mem.eql(u8, v, "warn")) return .warn;
    if (std.mem.eql(u8, v, "ignore")) return .ignore;
    writeStderr("znumfmt: invalid --invalid mode: '{s}'\n", .{v});
    std.process.exit(1);
}

/// Round `x` per the selected mode. `@round` matches C `round()` (ties away
/// from zero), which is GNU numfmt's `nearest`.
fn applyRound(x: f64, mode: Round) f64 {
    return switch (mode) {
        .up => @ceil(x),
        .down => @floor(x),
        .towards_zero => @trunc(x),
        .nearest => @round(x),
        .from_zero => if (x < 0) @floor(x) else @ceil(x),
    };
}

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

    // Options
    var from_format: Format = .none;
    var to_format: Format = .none;
    var from_unit: u64 = 1;
    var to_unit: u64 = 1;
    var padding: i32 = 0;
    var grouping = false;
    var round_mode: Round = .from_zero;
    var suffix: ?[]const u8 = null;
    var delimiter: ?u8 = null;
    var field: usize = 1;
    var header_lines: usize = 0;
    var invalid_mode: InvalidMode = .abort;
    var numbers: std.ArrayListUnmanaged([]const u8) = .empty;
    defer numbers.deinit(allocator);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            writeStdout("znumfmt {s}\n", .{VERSION});
            return;
        } else if (optValue(args, &i, "--from")) |v| {
            from_format = parseFormat(v, "--from");
        } else if (optValue(args, &i, "--to")) |v| {
            to_format = parseFormat(v, "--to");
        } else if (optValue(args, &i, "--from-unit")) |v| {
            from_unit = parseUnit(v, "--from-unit");
        } else if (optValue(args, &i, "--to-unit")) |v| {
            to_unit = parseUnit(v, "--to-unit");
        } else if (optValue(args, &i, "--padding")) |v| {
            padding = std.fmt.parseInt(i32, v, 10) catch {
                writeStderr("znumfmt: invalid padding value '{s}'\n", .{v});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--grouping")) {
            grouping = true;
        } else if (optValue(args, &i, "--round")) |v| {
            round_mode = parseRound(v);
        } else if (optValue(args, &i, "--suffix")) |v| {
            suffix = v;
        } else if (std.mem.eql(u8, arg, "-d")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("znumfmt: option requires an argument -- 'd'\n", .{});
                std.process.exit(1);
            }
            if (args[i].len > 0) delimiter = args[i][0];
        } else if (arg.len > 2 and arg[0] == '-' and arg[1] == 'd') {
            // Attached short-option value, e.g. -d,
            delimiter = arg[2];
        } else if (optValue(args, &i, "--delimiter")) |v| {
            if (v.len > 0) delimiter = v[0];
        } else if (optValue(args, &i, "--field")) |v| {
            field = std.fmt.parseInt(usize, v, 10) catch {
                writeStderr("znumfmt: invalid field value '{s}'\n", .{v});
                std.process.exit(1);
            };
            if (field == 0) field = 1;
        } else if (std.mem.startsWith(u8, arg, "--header")) {
            // Optional-argument option: only the `--header` / `--header=N` forms
            // (GNU getopt does not accept a space-separated value here).
            if (std.mem.eql(u8, arg, "--header")) {
                header_lines = 1;
            } else if (std.mem.startsWith(u8, arg, "--header=")) {
                header_lines = std.fmt.parseInt(usize, arg[9..], 10) catch {
                    writeStderr("znumfmt: invalid header value '{s}'\n", .{arg[9..]});
                    std.process.exit(1);
                };
            } else {
                writeStderr("znumfmt: unrecognized option '{s}'\n", .{arg});
                std.process.exit(1);
            }
        } else if (optValue(args, &i, "--invalid")) |v| {
            invalid_mode = parseInvalid(v);
        } else if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                try numbers.append(allocator, args[i]);
            }
        } else if (std.mem.startsWith(u8, arg, "--")) {
            writeStderr("znumfmt: unrecognized option '{s}'\n", .{arg});
            std.process.exit(1);
        } else if (arg.len > 1 and arg[0] == '-') {
            // Short options (bundled). Anything unknown is an invalid option;
            // this is also how GNU rejects a bare negative like `-1000`.
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                writeStderr("znumfmt: invalid option -- '{c}'\n", .{arg[j]});
                std.process.exit(1);
            }
        } else {
            try numbers.append(allocator, arg);
        }
    }

    // --grouping cannot be combined with --to (GNU parity).
    if (grouping and to_format != .none) {
        writeStderr("znumfmt: grouping cannot be combined with --to\n", .{});
        std.process.exit(1);
    }
    // Reject a zero unit size before it can divide-by-zero (GNU parity).
    if (from_unit == 0 or to_unit == 0) {
        writeStderr("znumfmt: invalid unit size: '0'\n", .{});
        std.process.exit(1);
    }

    var exit_code: u8 = 0;

    if (numbers.items.len > 0) {
        // Process command line arguments
        for (numbers.items) |num| {
            processNumber(allocator, num, from_format, to_format, from_unit, to_unit, padding, grouping, round_mode, suffix, invalid_mode, &exit_code) catch |err| {
                if (err == error.InvalidNumber) {
                    // In abort mode we stop immediately with no output; every
                    // other mode passes the original token through to stdout
                    // (GNU parity — avoids silent data loss in pipelines).
                    if (invalid_mode == .abort) std.process.exit(2);
                    writeStdoutRaw(num);
                }
            };
            writeStdout("\n", .{});
        }
    } else {
        // Process stdin
        var buf: [65536]u8 = undefined;
        var line_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer line_buf.deinit(allocator);
        var line_num: usize = 0;

        while (true) {
            const n = c_read(0, &buf, buf.len);
            if (n <= 0) break;

            const data = buf[0..@intCast(n)];
            for (data) |byte| {
                if (byte == '\n') {
                    line_num += 1;

                    // Pass through header lines
                    if (line_num <= header_lines) {
                        writeStdoutRaw(line_buf.items);
                        writeStdout("\n", .{});
                        line_buf.clearRetainingCapacity();
                        continue;
                    }

                    // Process the line
                    processLine(allocator, line_buf.items, from_format, to_format, from_unit, to_unit, padding, grouping, round_mode, suffix, delimiter, field, invalid_mode, &exit_code) catch |err| {
                        if (err == error.InvalidNumber) {
                            if (invalid_mode == .abort) std.process.exit(2);
                        }
                    };
                    line_buf.clearRetainingCapacity();
                } else {
                    line_buf.append(allocator, byte) catch continue;
                }
            }
        }

        // Handle last line without newline
        if (line_buf.items.len > 0) {
            line_num += 1;
            if (line_num <= header_lines) {
                writeStdoutRaw(line_buf.items);
                writeStdout("\n", .{});
            } else {
                processLine(allocator, line_buf.items, from_format, to_format, from_unit, to_unit, padding, grouping, round_mode, suffix, delimiter, field, invalid_mode, &exit_code) catch {};
            }
        }
    }

    if (exit_code != 0) std.process.exit(exit_code);
}

fn processLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    from_format: Format,
    to_format: Format,
    from_unit: u64,
    to_unit: u64,
    padding: i32,
    grouping: bool,
    round_mode: Round,
    suffix: ?[]const u8,
    delimiter: ?u8,
    field_num: usize,
    invalid_mode: InvalidMode,
    exit_code: *u8,
) !void {
    const delim = delimiter orelse ' ';
    var field_idx: usize = 0;
    var in_field = false;
    var field_start: usize = 0;
    var field_end: usize = 0;

    // Find the specified field
    var idx: usize = 0;
    while (idx <= line.len) : (idx += 1) {
        const is_delim = idx == line.len or line[idx] == delim;

        if (!in_field and !is_delim) {
            in_field = true;
            field_idx += 1;
            field_start = idx;
        } else if (in_field and is_delim) {
            in_field = false;
            field_end = idx;

            if (field_idx == field_num) {
                // Output before the field
                writeStdoutRaw(line[0..field_start]);

                // Process and output the field
                const field_text = line[field_start..field_end];
                processNumber(allocator, field_text, from_format, to_format, from_unit, to_unit, padding, grouping, round_mode, suffix, invalid_mode, exit_code) catch |err| {
                    if (err == error.InvalidNumber) {
                        // abort: stop with no further output; other modes pass
                        // the original field text through unchanged.
                        if (invalid_mode == .abort) return err;
                        writeStdoutRaw(field_text);
                    }
                    // Output after the field
                    writeStdoutRaw(line[field_end..]);
                    writeStdout("\n", .{});
                    return err;
                };

                // Output after the field
                writeStdoutRaw(line[field_end..]);
                writeStdout("\n", .{});
                return;
            }
        }
    }

    // Field not found, output line as-is
    writeStdoutRaw(line);
    writeStdout("\n", .{});
}

fn processNumber(
    allocator: std.mem.Allocator,
    input: []const u8,
    from_format: Format,
    to_format: Format,
    from_unit: u64,
    to_unit: u64,
    padding: i32,
    grouping: bool,
    round_mode: Round,
    suffix: ?[]const u8,
    invalid_mode: InvalidMode,
    exit_code: *u8,
) !void {
    _ = grouping; // C-locale grouping inserts no separators (GNU parity)

    // Parse the input number
    const trimmed = std.mem.trim(u8, input, " \t");
    if (trimmed.len == 0) {
        handleInvalid(invalid_mode, input, exit_code);
        return error.InvalidNumber;
    }

    // Check for negative
    var is_negative = false;
    var num_start: usize = 0;
    if (trimmed[0] == '-') {
        is_negative = true;
        num_start = 1;
    } else if (trimmed[0] == '+') {
        num_start = 1;
    }

    // Parse number and suffix
    var num_end = num_start;

    while (num_end < trimmed.len) : (num_end += 1) {
        const c = trimmed[num_end];
        if (c >= '0' and c <= '9') continue;
        if (c == '.') continue;
        break;
    }

    if (num_end == num_start) {
        handleInvalid(invalid_mode, input, exit_code);
        return error.InvalidNumber;
    }

    // Parse the numeric part
    const num_str = trimmed[num_start..num_end];
    var value: f64 = std.fmt.parseFloat(f64, num_str) catch {
        handleInvalid(invalid_mode, input, exit_code);
        return error.InvalidNumber;
    };

    if (is_negative) value = -value;

    // Parse suffix and apply from_format multiplier
    const suffix_str = trimmed[num_end..];
    const multiplier = getSuffixMultiplier(suffix_str, from_format) catch {
        handleInvalid(invalid_mode, input, exit_code);
        return error.InvalidNumber;
    };

    value *= multiplier;
    value *= @as(f64, @floatFromInt(from_unit));
    value /= @as(f64, @floatFromInt(to_unit));

    // Format output
    const output = formatNumber(allocator, value, to_format, round_mode, suffix) catch |err| {
        if (err == error.ValueTooLarge) {
            handleValueTooLarge(invalid_mode, value, exit_code);
        } else {
            handleInvalid(invalid_mode, input, exit_code);
        }
        return error.InvalidNumber;
    };
    defer allocator.free(output);

    const final_output: []const u8 = output;

    // Apply padding
    if (padding != 0) {
        const pad_width: usize = @intCast(if (padding < 0) -padding else padding);
        if (final_output.len < pad_width) {
            const pad_count = pad_width - final_output.len;
            if (padding < 0) {
                // Left align
                writeStdoutRaw(final_output);
                var p: usize = 0;
                while (p < pad_count) : (p += 1) {
                    writeStdout(" ", .{});
                }
            } else {
                // Right align
                var p: usize = 0;
                while (p < pad_count) : (p += 1) {
                    writeStdout(" ", .{});
                }
                writeStdoutRaw(final_output);
            }
            return;
        }
    }

    writeStdoutRaw(final_output);
}

fn getSuffixMultiplier(suffix_str: []const u8, format: Format) !f64 {
    if (suffix_str.len == 0) return 1;

    const power: u32 = switch (suffix_str[0]) {
        'K', 'k' => 1,
        'M' => 2,
        'G' => 3,
        'T' => 4,
        'P' => 5,
        'E' => 6,
        'Z' => 7,
        'Y' => 8,
        else => return error.InvalidSuffix,
    };

    // Validate the trailing characters and pick the base. The `i` marker is
    // required for iec-i, forbidden for si/iec, and optional for auto.
    const trailing = suffix_str[1..];
    const has_i = trailing.len == 1 and trailing[0] == 'i';
    const base: f64 = switch (format) {
        .none => return error.InvalidSuffix,
        .si => blk: {
            if (trailing.len != 0) return error.InvalidSuffix;
            break :blk 1000.0;
        },
        .iec => blk: {
            if (trailing.len != 0) return error.InvalidSuffix;
            break :blk 1024.0;
        },
        .iec_i => blk: {
            if (!has_i) return error.InvalidSuffix;
            break :blk 1024.0;
        },
        .auto => blk: {
            if (trailing.len != 0 and !has_i) return error.InvalidSuffix;
            break :blk if (has_i) 1024.0 else 1000.0;
        },
    };

    // base^power computed in f64 — never overflows (Z/Y are representable).
    var mult: f64 = 1;
    var p: u32 = 0;
    while (p < power) : (p += 1) mult *= base;
    return mult;
}

fn formatNumber(allocator: std.mem.Allocator, value: f64, format: Format, round_mode: Round, extra_suffix: ?[]const u8) ![]u8 {
    // SI uses a lowercase kilo suffix; M/G/T… stay uppercase.
    const suffixes_si = [_][]const u8{ "", "k", "M", "G", "T", "P", "E", "Z", "Y" };
    const suffixes_iec = [_][]const u8{ "", "K", "M", "G", "T", "P", "E", "Z", "Y" };
    const suffixes_iec_i = [_][]const u8{ "", "Ki", "Mi", "Gi", "Ti", "Pi", "Ei", "Zi", "Yi" };

    var abs_value = @abs(value);
    const is_negative = value < 0;

    if (!std.math.isFinite(value)) return error.ValueTooLarge;

    if (format == .none) {
        // No scaling: print the value as-is. GNU rejects values >= 10^16
        // (they exceed printable long-double integer precision).
        if (abs_value >= 1e16) return error.ValueTooLarge;

        // Snap values that are within rounding noise of an integer (e.g. a
        // from-scaled 1.1K -> 1100.0000000000002) back to the integer, so the
        // shortest-float printer emits "1100" like GNU rather than the noise.
        const rounded = @round(value);
        const print_val: f64 = if (@abs(value - rounded) < 1e-6 * @max(@as(f64, 1), abs_value)) rounded else value;

        var buf: [64]u8 = undefined;
        const result = std.fmt.bufPrint(&buf, "{d}", .{print_val}) catch return error.FormatError;
        const extra_len = if (extra_suffix) |s| s.len else 0;
        const output = try allocator.alloc(u8, result.len + extra_len);
        @memcpy(output[0..result.len], result);
        if (extra_suffix) |s| @memcpy(output[result.len..], s);
        return output;
    }

    const base: f64 = switch (format) {
        .si => 1000.0,
        .iec, .iec_i, .auto => 1024.0,
        .none => unreachable,
    };

    const suffixes: []const []const u8 = switch (format) {
        .si => &suffixes_si,
        .iec, .auto => &suffixes_iec,
        .iec_i => &suffixes_iec_i,
        .none => unreachable,
    };

    // Scale down until the mantissa is below the base (capped at the largest
    // suffix), tracking the power. This mirrors GNU's double_to_human.
    var power: usize = 0;
    while (power < suffixes.len - 1 and abs_value >= base) {
        abs_value /= base;
        power += 1;
    }

    // GNU keeps one fraction digit only when scaled and the mantissa is < 10.
    const scaled_prec: f64 = if (abs_value < 10 and power != 0) 10 else 1;
    abs_value = applyRound(abs_value * scaled_prec, round_mode) / scaled_prec;

    // Rounding may have pushed the mantissa back up to the base (e.g. 999.6k
    // -> 1000 -> 1.0M); rescale once more.
    if (abs_value >= base and power < suffixes.len - 1) {
        abs_value /= base;
        power += 1;
    }

    // Final display precision is recomputed from the rounded mantissa, so that
    // e.g. 9.95k rounds to 10 (integer) and prints "10k", not "10.0k".
    const one_decimal = abs_value < 10 and power != 0;

    var buf: [64]u8 = undefined;
    var result: []const u8 = undefined;
    if (one_decimal) {
        result = std.fmt.bufPrint(&buf, "{d:.1}", .{abs_value}) catch return error.FormatError;
    } else {
        const int_val: i64 = @intFromFloat(abs_value);
        result = std.fmt.bufPrint(&buf, "{d}", .{int_val}) catch return error.FormatError;
    }

    const unit_suffix = suffixes[power];
    const extra_len = if (extra_suffix) |s| s.len else 0;
    const neg_len: usize = if (is_negative) 1 else 0;

    const output = try allocator.alloc(u8, neg_len + result.len + unit_suffix.len + extra_len);
    var pos: usize = 0;

    if (is_negative) {
        output[pos] = '-';
        pos += 1;
    }
    @memcpy(output[pos .. pos + result.len], result);
    pos += result.len;
    @memcpy(output[pos .. pos + unit_suffix.len], unit_suffix);
    pos += unit_suffix.len;
    if (extra_suffix) |s| {
        @memcpy(output[pos .. pos + s.len], s);
    }

    return output;
}


fn handleInvalid(invalid_mode: InvalidMode, input: []const u8, exit_code: *u8) void {
    switch (invalid_mode) {
        // abort: caller stops with exit 2 right after this.
        .abort => writeStderr("znumfmt: invalid number: '{s}'\n", .{input}),
        // fail: diagnose and set a non-zero final exit.
        .fail => {
            writeStderr("znumfmt: invalid number: '{s}'\n", .{input});
            exit_code.* = 2;
        },
        // warn: diagnose but exit 0 (GNU parity).
        .warn => writeStderr("znumfmt: invalid number: '{s}'\n", .{input}),
        // ignore: silent.
        .ignore => {},
    }
}

fn handleValueTooLarge(invalid_mode: InvalidMode, value: f64, exit_code: *u8) void {
    switch (invalid_mode) {
        .abort => writeStderr("znumfmt: value too large to be printed: '{e}' (consider using --to)\n", .{value}),
        .fail => {
            writeStderr("znumfmt: value too large to be printed: '{e}' (consider using --to)\n", .{value});
            exit_code.* = 2;
        },
        .warn => writeStderr("znumfmt: value too large to be printed: '{e}' (consider using --to)\n", .{value}),
        .ignore => {},
    }
}

fn printHelp() void {
    writeStdout(
        \\Usage: znumfmt [OPTION]... [NUMBER]...
        \\Reformat NUMBER(s), or numbers from stdin.
        \\
        \\Options:
        \\  -d, --delimiter=X    use X as field delimiter
        \\      --field=N        process Nth field (default 1)
        \\      --from=UNIT      auto-scale input UNITs
        \\      --from-unit=N    specify input unit size (default 1)
        \\      --to=UNIT        auto-scale output UNITs
        \\      --to-unit=N      specify output unit size (default 1)
        \\      --grouping       use locale-defined digit grouping
        \\      --header[=N]     print first N header lines without conversion
        \\      --padding=N      pad output to N characters
        \\      --round=METHOD   use METHOD for rounding
        \\      --suffix=SUFFIX  add SUFFIX to output numbers
        \\      --invalid=MODE   failure mode for invalid numbers
        \\      --help           display this help and exit
        \\      --version        output version information and exit
        \\
        \\UNIT options:
        \\  none     no auto-scaling (default)
        \\  auto     accept SI or IEC suffixes
        \\  si       accept SI suffixes:  K=1000, M=1000^2, ...
        \\  iec      accept IEC suffixes: K=1024, M=1024^2, ...
        \\  iec-i    accept IEC suffixes: Ki=1024, Mi=1024^2, ...
        \\
        \\ROUND options:
        \\  up         round towards +infinity
        \\  down       round towards -infinity
        \\  from-zero  round away from zero (default)
        \\  towards-zero  round towards zero
        \\  nearest    round to nearest
        \\
        \\INVALID options:
        \\  abort   stop on first invalid number (default)
        \\  fail    continue, exit with error
        \\  warn    warn on invalid, exit with error
        \\  ignore  silently ignore invalid
        \\
        \\Examples:
        \\  znumfmt --to=si 1000              Output: 1.0K
        \\  znumfmt --to=iec 1024             Output: 1.0K
        \\  znumfmt --to=iec-i 1048576        Output: 1.0Mi
        \\  znumfmt --from=si 1K              Output: 1000
        \\  znumfmt --from=iec --to=si 1K     Output: 1.0K (1024 -> 1.0K)
        \\  echo 1K | znumfmt --from=si       Output: 1000
        \\  df -B1 | znumfmt --header --field 2 --to=iec
        \\
    , .{});
}
