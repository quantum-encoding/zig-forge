//! ztr - High-performance character translation utility
//!
//! Translate, squeeze, and/or delete characters from standard input.
//!
//! Usage: ztr [OPTION]... SET1 [SET2]

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

const Config = struct {
    delete: bool = false,
    squeeze: bool = false,
    complement: bool = false,
    truncate_set1: bool = false,
    set1: ?[]const u8 = null,
    set2: ?[]const u8 = null,
};

fn writeStdout(msg: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, msg.ptr, msg.len);
}

fn writeStderr(msg: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
}

fn printUsage() void {
    const usage =
        \\Usage: ztr [OPTION]... SET1 [SET2]
        \\
        \\Translate, squeeze, and/or delete characters from standard input,
        \\writing to standard output.
        \\
        \\Options:
        \\  -c, --complement      Use complement of SET1
        \\  -d, --delete          Delete characters in SET1, do not translate
        \\  -s, --squeeze-repeats Replace each sequence of repeated characters
        \\                        with single occurrence of that character
        \\  -t, --truncate-set1   First truncate SET1 to length of SET2
        \\      --help            Display this help and exit
        \\      --version         Output version information and exit
        \\
        \\SETs are specified as strings of characters. Character classes:
        \\  [:alnum:]   Alphanumeric characters
        \\  [:alpha:]   Alphabetic characters
        \\  [:blank:]   Horizontal whitespace
        \\  [:cntrl:]   Control characters
        \\  [:digit:]   Digits
        \\  [:graph:]   Printable characters (not space)
        \\  [:lower:]   Lowercase letters
        \\  [:print:]   Printable characters (including space)
        \\  [:punct:]   Punctuation characters
        \\  [:space:]   Whitespace characters
        \\  [:upper:]   Uppercase letters
        \\  [:xdigit:]  Hexadecimal digits
        \\
        \\Escape sequences:
        \\  \\n   newline         \\r   carriage return
        \\  \\t   tab             \\\\   backslash
        \\  \\0   null            \\NNN octal value (1-3 digits)
        \\
        \\Examples:
        \\  echo "hello" | ztr 'a-z' 'A-Z'     # Uppercase
        \\  echo "hello" | ztr -d 'aeiou'      # Delete vowels
        \\  echo "hello   world" | ztr -s ' '  # Squeeze spaces
        \\  echo "hello" | ztr '[:lower:]' '[:upper:]'
        \\  echo "hello" | ztr -t 'abcd' 'xy'  # Only translate a->x, b->y
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("ztr " ++ VERSION ++ " - High-performance character translation\n");
}

fn parseArgs(args: []const []const u8) !Config {
    var config = Config{};
    var positional_idx: usize = 0;

    for (args) |arg| {
        if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--complement")) {
                config.complement = true;
            } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--delete")) {
                config.delete = true;
            } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--squeeze-repeats")) {
                config.squeeze = true;
            } else if (std.mem.eql(u8, arg, "-cd") or std.mem.eql(u8, arg, "-dc")) {
                config.complement = true;
                config.delete = true;
            } else if (std.mem.eql(u8, arg, "-cs") or std.mem.eql(u8, arg, "-sc")) {
                config.complement = true;
                config.squeeze = true;
            } else if (std.mem.eql(u8, arg, "-ds") or std.mem.eql(u8, arg, "-sd")) {
                config.delete = true;
                config.squeeze = true;
            } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--truncate-set1")) {
                config.truncate_set1 = true;
            } else if (std.mem.eql(u8, arg, "-ct") or std.mem.eql(u8, arg, "-tc")) {
                config.complement = true;
                config.truncate_set1 = true;
            } else if (std.mem.eql(u8, arg, "-st") or std.mem.eql(u8, arg, "-ts")) {
                config.squeeze = true;
                config.truncate_set1 = true;
            } else if (std.mem.eql(u8, arg, "--help")) {
                printUsage();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                std.process.exit(0);
            } else {
                var err_buf: [256]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "ztr: invalid option '{s}'\n", .{arg}) catch "ztr: invalid option\n";
                writeStderr(err_msg);
                return error.InvalidOption;
            }
        } else {
            if (positional_idx == 0) {
                config.set1 = arg;
            } else if (positional_idx == 1) {
                config.set2 = arg;
            }
            positional_idx += 1;
        }
    }

    if (config.set1 == null) {
        writeStderr("ztr: missing operand\n");
        return error.MissingOperand;
    }

    if (!config.delete and !config.squeeze and config.set2 == null) {
        writeStderr("ztr: missing operand after SET1\n");
        return error.MissingOperand;
    }

    return config;
}

// Expand character set string into actual bytes
fn expandSet(set_str: []const u8, output: *[256]bool) void {
    @memset(output, false);

    var i: usize = 0;
    while (i < set_str.len) {
        // Check for character classes
        if (i + 2 < set_str.len and set_str[i] == '[' and set_str[i + 1] == ':') {
            if (std.mem.indexOf(u8, set_str[i..], ":]")) |end| {
                const class = set_str[i + 2 .. i + end];
                expandClass(class, output);
                i += end + 2;
                continue;
            }
        }

        // Check for escape sequences
        if (set_str[i] == '\\' and i + 1 < set_str.len) {
            const next = set_str[i + 1];
            // Check for octal escape \NNN
            if (next >= '0' and next <= '7') {
                const octal = parseOctalEscape(set_str[i + 1 ..]);
                output[octal.value] = true;
                i += 1 + octal.consumed;
                continue;
            }
            const c: u8 = switch (next) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '\\' => '\\',
                else => next,
            };
            output[c] = true;
            i += 2;
            continue;
        }

        // Check for range (a-z)
        if (i + 2 < set_str.len and set_str[i + 1] == '-') {
            const start = set_str[i];
            const end = set_str[i + 2];
            if (start <= end) {
                var c = start;
                while (c <= end) : (c += 1) {
                    output[c] = true;
                }
            }
            i += 3;
            continue;
        }

        // Single character
        output[set_str[i]] = true;
        i += 1;
    }
}

fn expandClass(class: []const u8, output: *[256]bool) void {
    if (std.mem.eql(u8, class, "alnum")) {
        for (0..256) |i| {
            const c: u8 = @intCast(i);
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')) {
                output[c] = true;
            }
        }
    } else if (std.mem.eql(u8, class, "alpha")) {
        for (0..256) |i| {
            const c: u8 = @intCast(i);
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) {
                output[c] = true;
            }
        }
    } else if (std.mem.eql(u8, class, "blank")) {
        output[' '] = true;
        output['\t'] = true;
    } else if (std.mem.eql(u8, class, "cntrl")) {
        for (0..32) |i| {
            output[i] = true;
        }
        output[127] = true;
    } else if (std.mem.eql(u8, class, "digit")) {
        for ('0'..'9' + 1) |i| {
            output[i] = true;
        }
    } else if (std.mem.eql(u8, class, "graph")) {
        for (33..127) |i| {
            output[i] = true;
        }
    } else if (std.mem.eql(u8, class, "lower")) {
        for ('a'..'z' + 1) |i| {
            output[i] = true;
        }
    } else if (std.mem.eql(u8, class, "print")) {
        for (32..127) |i| {
            output[i] = true;
        }
    } else if (std.mem.eql(u8, class, "punct")) {
        const punct = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~";
        for (punct) |c| {
            output[c] = true;
        }
    } else if (std.mem.eql(u8, class, "space")) {
        output[' '] = true;
        output['\t'] = true;
        output['\n'] = true;
        output['\r'] = true;
        output[11] = true; // vertical tab
        output[12] = true; // form feed
    } else if (std.mem.eql(u8, class, "upper")) {
        for ('A'..'Z' + 1) |i| {
            output[i] = true;
        }
    } else if (std.mem.eql(u8, class, "xdigit")) {
        for ('0'..'9' + 1) |i| {
            output[i] = true;
        }
        for ('a'..'f' + 1) |i| {
            output[i] = true;
        }
        for ('A'..'F' + 1) |i| {
            output[i] = true;
        }
    }
}

// Build translation table
fn buildTranslationTable(set1_str: []const u8, set2_str: []const u8, table: *[256]u8, truncate_set1: bool) void {
    // Initialize to identity mapping
    for (0..256) |i| {
        table[i] = @intCast(i);
    }

    // Build lists of characters from each set
    var set1_chars: [256]u8 = undefined;
    var set1_len: usize = 0;
    var set2_chars: [256]u8 = undefined;
    var set2_len: usize = 0;

    expandSetToList(set1_str, &set1_chars, &set1_len);
    expandSetToList(set2_str, &set2_chars, &set2_len);

    // With -t: truncate SET1 to length of SET2
    const effective_set1_len = if (truncate_set1) @min(set1_len, set2_len) else set1_len;

    // Map characters
    for (0..effective_set1_len) |i| {
        const src = set1_chars[i];
        // Use last char of set2 if set2 is shorter (only applies when not truncating)
        const dst_idx = if (i < set2_len) i else set2_len - 1;
        const dst = if (set2_len > 0) set2_chars[dst_idx] else src;
        table[src] = dst;
    }
}

// Parse octal escape sequence, returns (value, bytes_consumed)
fn parseOctalEscape(str: []const u8) struct { value: u8, consumed: usize } {
    var value: u16 = 0;
    var consumed: usize = 0;

    while (consumed < 3 and consumed < str.len) {
        const c = str[consumed];
        if (c >= '0' and c <= '7') {
            value = value * 8 + (c - '0');
            consumed += 1;
        } else {
            break;
        }
    }

    // Clamp to 255 max
    if (value > 255) value = 255;
    return .{ .value = @intCast(value), .consumed = consumed };
}

fn expandSetToList(set_str: []const u8, output: *[256]u8, len: *usize) void {
    len.* = 0;

    var i: usize = 0;
    while (i < set_str.len) {
        // Check for character classes
        if (i + 2 < set_str.len and set_str[i] == '[' and set_str[i + 1] == ':') {
            if (std.mem.indexOf(u8, set_str[i..], ":]")) |end| {
                const class = set_str[i + 2 .. i + end];
                expandClassToList(class, output, len);
                i += end + 2;
                continue;
            }
        }

        // Check for escape sequences
        if (set_str[i] == '\\' and i + 1 < set_str.len) {
            const next = set_str[i + 1];
            // Check for octal escape \NNN
            if (next >= '0' and next <= '7') {
                const octal = parseOctalEscape(set_str[i + 1 ..]);
                if (len.* < 256) {
                    output[len.*] = octal.value;
                    len.* += 1;
                }
                i += 1 + octal.consumed;
                continue;
            }
            const c: u8 = switch (next) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '\\' => '\\',
                else => next,
            };
            if (len.* < 256) {
                output[len.*] = c;
                len.* += 1;
            }
            i += 2;
            continue;
        }

        // Check for range (a-z)
        if (i + 2 < set_str.len and set_str[i + 1] == '-') {
            const start = set_str[i];
            const range_end = set_str[i + 2];
            if (start <= range_end) {
                var c = start;
                while (c <= range_end) : (c += 1) {
                    if (len.* < 256) {
                        output[len.*] = c;
                        len.* += 1;
                    }
                }
            }
            i += 3;
            continue;
        }

        // Single character
        if (len.* < 256) {
            output[len.*] = set_str[i];
            len.* += 1;
        }
        i += 1;
    }
}

fn expandClassToList(class: []const u8, output: *[256]u8, len: *usize) void {
    if (std.mem.eql(u8, class, "lower")) {
        for ('a'..'z' + 1) |i| {
            if (len.* < 256) {
                output[len.*] = @intCast(i);
                len.* += 1;
            }
        }
    } else if (std.mem.eql(u8, class, "upper")) {
        for ('A'..'Z' + 1) |i| {
            if (len.* < 256) {
                output[len.*] = @intCast(i);
                len.* += 1;
            }
        }
    } else if (std.mem.eql(u8, class, "digit")) {
        for ('0'..'9' + 1) |i| {
            if (len.* < 256) {
                output[len.*] = @intCast(i);
                len.* += 1;
            }
        }
    } else if (std.mem.eql(u8, class, "alpha")) {
        for ('a'..'z' + 1) |i| {
            if (len.* < 256) {
                output[len.*] = @intCast(i);
                len.* += 1;
            }
        }
        for ('A'..'Z' + 1) |i| {
            if (len.* < 256) {
                output[len.*] = @intCast(i);
                len.* += 1;
            }
        }
    } else if (std.mem.eql(u8, class, "space")) {
        const spaces = " \t\n\r";
        for (spaces) |c| {
            if (len.* < 256) {
                output[len.*] = c;
                len.* += 1;
            }
        }
    }
    // Add more classes as needed
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

    const config = parseArgs(args[1..]) catch {
        std.process.exit(1);
    };

    // Build character sets
    var set1_mask: [256]bool = undefined;
    expandSet(config.set1.?, &set1_mask);

    if (config.complement) {
        for (0..256) |i| {
            set1_mask[i] = !set1_mask[i];
        }
    }

    // Build translation table
    var trans_table: [256]u8 = undefined;
    if (!config.delete and config.set2 != null) {
        buildTranslationTable(config.set1.?, config.set2.?, &trans_table, config.truncate_set1);
        if (config.complement) {
            // For complement translation, swap behavior
            var complement_table: [256]u8 = undefined;
            for (0..256) |i| {
                complement_table[i] = @intCast(i);
            }
            // Get last char of set2
            var set2_chars: [256]u8 = undefined;
            var set2_len: usize = 0;
            expandSetToList(config.set2.?, &set2_chars, &set2_len);
            const replace_char = if (set2_len > 0) set2_chars[set2_len - 1] else 0;

            for (0..256) |i| {
                if (!set1_mask[i]) {
                    // Not in complement = in original SET1, translate
                    complement_table[i] = trans_table[i];
                } else {
                    // In complement = not in original SET1, replace with last char
                    complement_table[i] = replace_char;
                }
            }
            trans_table = complement_table;
        }
    } else {
        for (0..256) |i| {
            trans_table[i] = @intCast(i);
        }
    }

    // Squeeze set (for -s option)
    var squeeze_mask: [256]bool = undefined;
    if (config.squeeze) {
        if (config.delete and config.set2 != null) {
            // -ds: squeeze characters in SET2
            expandSet(config.set2.?, &squeeze_mask);
        } else if (config.set2 != null) {
            // -s with translation: squeeze characters in SET2
            expandSet(config.set2.?, &squeeze_mask);
        } else {
            // -s alone: squeeze characters in SET1
            squeeze_mask = set1_mask;
        }
    } else {
        @memset(&squeeze_mask, false);
    }

    // Process stdin
    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var write_pos: usize = 0;
    var last_char: u8 = 0;
    var have_last: bool = false;

    while (true) {
        const bytes_read = posix.read(0, &read_buf) catch break;
        if (bytes_read == 0) break;

        for (read_buf[0..bytes_read]) |c| {
            // Delete mode
            if (config.delete and set1_mask[c]) {
                continue;
            }

            // Translate
            const out_char = trans_table[c];

            // Squeeze
            if (config.squeeze and squeeze_mask[out_char]) {
                if (have_last and last_char == out_char) {
                    continue;
                }
            }

            // Output
            write_buf[write_pos] = out_char;
            write_pos += 1;
            last_char = out_char;
            have_last = true;

            if (write_pos >= write_buf.len) {
                writeStdout(&write_buf);
                write_pos = 0;
            }
        }
    }

    // Flush remaining
    if (write_pos > 0) {
        writeStdout(write_buf[0..write_pos]);
    }
}
