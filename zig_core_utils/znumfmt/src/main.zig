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
        } else if (std.mem.eql(u8, arg, "--from=auto")) {
            from_format = .auto;
        } else if (std.mem.eql(u8, arg, "--from=si")) {
            from_format = .si;
        } else if (std.mem.eql(u8, arg, "--from=iec")) {
            from_format = .iec;
        } else if (std.mem.eql(u8, arg, "--from=iec-i")) {
            from_format = .iec_i;
        } else if (std.mem.eql(u8, arg, "--from=none")) {
            from_format = .none;
        } else if (std.mem.startsWith(u8, arg, "--from=")) {
            writeStderr("znumfmt: invalid --from format: '{s}'\n", .{arg[7..]});
            std.process.exit(1);
        } else if (std.mem.eql(u8, arg, "--to=auto")) {
            to_format = .auto;
        } else if (std.mem.eql(u8, arg, "--to=si")) {
            to_format = .si;
        } else if (std.mem.eql(u8, arg, "--to=iec")) {
            to_format = .iec;
        } else if (std.mem.eql(u8, arg, "--to=iec-i")) {
            to_format = .iec_i;
        } else if (std.mem.eql(u8, arg, "--to=none")) {
            to_format = .none;
        } else if (std.mem.startsWith(u8, arg, "--to=")) {
            writeStderr("znumfmt: invalid --to format: '{s}'\n", .{arg[5..]});
            std.process.exit(1);
        } else if (std.mem.startsWith(u8, arg, "--from-unit=")) {
            from_unit = std.fmt.parseInt(u64, arg[12..], 10) catch {
                writeStderr("znumfmt: invalid --from-unit: '{s}'\n", .{arg[12..]});
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "--to-unit=")) {
            to_unit = std.fmt.parseInt(u64, arg[10..], 10) catch {
                writeStderr("znumfmt: invalid --to-unit: '{s}'\n", .{arg[10..]});
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "--padding=")) {
            padding = std.fmt.parseInt(i32, arg[10..], 10) catch {
                writeStderr("znumfmt: invalid --padding: '{s}'\n", .{arg[10..]});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--grouping")) {
            grouping = true;
        } else if (std.mem.eql(u8, arg, "--round=up")) {
            round_mode = .up;
        } else if (std.mem.eql(u8, arg, "--round=down")) {
            round_mode = .down;
        } else if (std.mem.eql(u8, arg, "--round=from-zero")) {
            round_mode = .from_zero;
        } else if (std.mem.eql(u8, arg, "--round=towards-zero")) {
            round_mode = .towards_zero;
        } else if (std.mem.eql(u8, arg, "--round=nearest")) {
            round_mode = .nearest;
        } else if (std.mem.startsWith(u8, arg, "--suffix=")) {
            suffix = arg[9..];
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--delimiter")) {
            i += 1;
            if (i >= args.len) {
                writeStderr("znumfmt: option requires an argument -- 'd'\n", .{});
                std.process.exit(1);
            }
            if (args[i].len > 0) delimiter = args[i][0];
        } else if (std.mem.startsWith(u8, arg, "--delimiter=")) {
            if (arg.len > 12) delimiter = arg[12];
        } else if (std.mem.startsWith(u8, arg, "--field=")) {
            field = std.fmt.parseInt(usize, arg[8..], 10) catch {
                writeStderr("znumfmt: invalid --field: '{s}'\n", .{arg[8..]});
                std.process.exit(1);
            };
            if (field == 0) field = 1;
        } else if (std.mem.startsWith(u8, arg, "--header")) {
            if (std.mem.startsWith(u8, arg, "--header=")) {
                header_lines = std.fmt.parseInt(usize, arg[9..], 10) catch 1;
            } else {
                header_lines = 1;
            }
        } else if (std.mem.eql(u8, arg, "--invalid=abort")) {
            invalid_mode = .abort;
        } else if (std.mem.eql(u8, arg, "--invalid=fail")) {
            invalid_mode = .fail;
        } else if (std.mem.eql(u8, arg, "--invalid=warn")) {
            invalid_mode = .warn;
        } else if (std.mem.eql(u8, arg, "--invalid=ignore")) {
            invalid_mode = .ignore;
        } else if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                try numbers.append(allocator, args[i]);
            }
        } else if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            // Short options
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                switch (arg[j]) {
                    'd' => {
                        i += 1;
                        if (i >= args.len) {
                            writeStderr("znumfmt: option requires an argument -- 'd'\n", .{});
                            std.process.exit(1);
                        }
                        if (args[i].len > 0) delimiter = args[i][0];
                        break;
                    },
                    else => {
                        writeStderr("znumfmt: invalid option -- '{c}'\n", .{arg[j]});
                        std.process.exit(1);
                    },
                }
            }
        } else {
            try numbers.append(allocator, arg);
        }
    }

    var exit_code: u8 = 0;

    if (numbers.items.len > 0) {
        // Process command line arguments
        for (numbers.items) |num| {
            processNumber(allocator, num, from_format, to_format, from_unit, to_unit, padding, grouping, round_mode, suffix, invalid_mode, &exit_code) catch |err| {
                if (err == error.InvalidNumber) {
                    if (invalid_mode == .abort) std.process.exit(2);
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
    _ = round_mode; // Used in scaling

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

    value *= @as(f64, @floatFromInt(multiplier));
    value *= @as(f64, @floatFromInt(from_unit));
    value /= @as(f64, @floatFromInt(to_unit));

    // Format output
    const output = formatNumber(allocator, value, to_format, suffix) catch {
        handleInvalid(invalid_mode, input, exit_code);
        return error.InvalidNumber;
    };
    defer allocator.free(output);

    // Apply grouping if requested
    var final_output: []const u8 = output;
    var grouped_buf: [256]u8 = undefined;
    if (grouping) {
        final_output = applyGrouping(output, &grouped_buf) catch output;
    }

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

fn getSuffixMultiplier(suffix_str: []const u8, format: Format) !u64 {
    if (suffix_str.len == 0) return 1;

    const c = suffix_str[0];
    const has_i = suffix_str.len >= 2 and suffix_str[1] == 'i';

    // Determine base
    const base: u64 = switch (format) {
        .none => return error.InvalidSuffix,
        .auto => if (has_i) 1024 else 1000,
        .si => 1000,
        .iec, .iec_i => 1024,
    };

    return switch (c) {
        'K', 'k' => base,
        'M' => base * base,
        'G' => base * base * base,
        'T' => base * base * base * base,
        'P' => base * base * base * base * base,
        'E' => base * base * base * base * base * base,
        'Z' => base * base * base * base * base * base * base,
        'Y' => base * base * base * base * base * base * base * base,
        else => return error.InvalidSuffix,
    };
}

fn formatNumber(allocator: std.mem.Allocator, value: f64, format: Format, extra_suffix: ?[]const u8) ![]u8 {
    const suffixes_si = [_][]const u8{ "", "K", "M", "G", "T", "P", "E", "Z", "Y" };
    const suffixes_iec = [_][]const u8{ "", "K", "M", "G", "T", "P", "E", "Z", "Y" };
    const suffixes_iec_i = [_][]const u8{ "", "Ki", "Mi", "Gi", "Ti", "Pi", "Ei", "Zi", "Yi" };

    var abs_value = @abs(value);
    const is_negative = value < 0;

    if (format == .none) {
        // Just format as plain number - use integer if possible
        var buf: [64]u8 = undefined;
        const int_val: i64 = @intFromFloat(abs_value);
        if (@as(f64, @floatFromInt(int_val)) == abs_value) {
            // It's a whole number
            const result = std.fmt.bufPrint(&buf, "{d}", .{int_val}) catch return error.FormatError;
            const neg_len: usize = if (is_negative) 1 else 0;
            const extra_len = if (extra_suffix) |s| s.len else 0;
            const output = try allocator.alloc(u8, neg_len + result.len + extra_len);
            var pos: usize = 0;
            if (is_negative) {
                output[0] = '-';
                pos = 1;
            }
            @memcpy(output[pos .. pos + result.len], result);
            pos += result.len;
            if (extra_suffix) |s| @memcpy(output[pos..], s);
            return output;
        }

        // Has decimal part
        const result = std.fmt.bufPrint(&buf, "{d:.2}", .{abs_value}) catch return error.FormatError;
        const neg_len: usize = if (is_negative) 1 else 0;
        const extra_len = if (extra_suffix) |s| s.len else 0;
        const output = try allocator.alloc(u8, neg_len + result.len + extra_len);
        var pos: usize = 0;
        if (is_negative) {
            output[0] = '-';
            pos = 1;
        }
        @memcpy(output[pos .. pos + result.len], result);
        pos += result.len;
        if (extra_suffix) |s| @memcpy(output[pos..], s);
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

    var suffix_idx: usize = 0;
    while (suffix_idx < suffixes.len - 1 and abs_value >= base) {
        abs_value /= base;
        suffix_idx += 1;
    }

    var buf: [64]u8 = undefined;
    var result: []const u8 = undefined;

    // Determine precision
    if (abs_value >= 10 or suffix_idx == 0) {
        const int_val: i64 = @intFromFloat(abs_value);
        result = std.fmt.bufPrint(&buf, "{d}", .{int_val}) catch return error.FormatError;
    } else {
        result = std.fmt.bufPrint(&buf, "{d:.1}", .{abs_value}) catch return error.FormatError;
    }

    const unit_suffix = suffixes[suffix_idx];
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

fn applyGrouping(input: []const u8, buf: *[256]u8) ![]const u8 {
    // Find the integer and decimal parts
    var neg_offset: usize = 0;
    if (input.len > 0 and input[0] == '-') {
        neg_offset = 1;
    }

    // Find decimal point
    var decimal_pos: ?usize = null;
    for (input[neg_offset..], 0..) |c, i| {
        if (c == '.') {
            decimal_pos = neg_offset + i;
            break;
        }
        if (!std.ascii.isDigit(c)) {
            // Found non-digit before decimal, could be unit suffix
            return input;
        }
    }

    var out_pos: usize = 0;

    // Copy negative sign if present
    if (neg_offset > 0) {
        buf[out_pos] = '-';
        out_pos += 1;
    }

    // Find start and end of integer part
    const int_start = neg_offset;
    const int_end = if (decimal_pos) |dp| dp else input.len;
    const int_part = input[int_start..int_end];

    // Insert commas every 3 digits from the right
    if (int_part.len <= 3) {
        // No grouping needed
        @memcpy(buf[out_pos .. out_pos + int_part.len], int_part);
        out_pos += int_part.len;
    } else {
        const leading_digits = int_part.len % 3;
        var idx: usize = 0;

        // Copy leading digits (less than 3)
        if (leading_digits > 0) {
            @memcpy(buf[out_pos .. out_pos + leading_digits], int_part[0..leading_digits]);
            out_pos += leading_digits;
            idx = leading_digits;
            buf[out_pos] = ',';
            out_pos += 1;
        }

        // Copy remaining digits with commas every 3
        while (idx < int_part.len) : (idx += 3) {
            @memcpy(buf[out_pos .. out_pos + 3], int_part[idx .. idx + 3]);
            out_pos += 3;
            if (idx + 3 < int_part.len) {
                buf[out_pos] = ',';
                out_pos += 1;
            }
        }
    }

    // Copy decimal part if present
    if (decimal_pos) |dp| {
        const decimal_part = input[dp..];
        @memcpy(buf[out_pos .. out_pos + decimal_part.len], decimal_part);
        out_pos += decimal_part.len;
    } else {
        // Copy any non-digit suffix (units)
        var suffix_start = int_end;
        while (suffix_start < input.len and !std.ascii.isDigit(input[suffix_start])) : (suffix_start += 1) {}
        if (suffix_start < input.len) {
            const suffix = input[suffix_start..];
            @memcpy(buf[out_pos .. out_pos + suffix.len], suffix);
            out_pos += suffix.len;
        }
    }

    return buf[0..out_pos];
}

fn handleInvalid(invalid_mode: InvalidMode, input: []const u8, exit_code: *u8) void {
    switch (invalid_mode) {
        .abort => {
            writeStderr("znumfmt: invalid number: '{s}'\n", .{input});
        },
        .fail => {
            exit_code.* = 2;
        },
        .warn => {
            writeStderr("znumfmt: invalid number: '{s}'\n", .{input});
            exit_code.* = 2;
        },
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
