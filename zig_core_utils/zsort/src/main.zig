//! zsort - High-performance line sorting utility
//!
//! Sort lines of text files.
//!
//! Usage: zsort [OPTION]... [FILE]...

const std = @import("std");
const libc = std.c;

extern "c" fn arc4random() u32;

const VERSION = "1.0.0";

const SortKey = struct {
    field: usize = 0, // 0 = entire line
    end_field: usize = 0, // 0 = same as field (or end of line if field is 0)
    start_char: usize = 0,
    end_char: usize = 0, // 0 = end of field
    numeric: bool = false,
    reverse: bool = false,
    ignore_leading_blanks: bool = false,
    dictionary_order: bool = false,
    general_numeric: bool = false,
    ignore_nonprinting: bool = false,
    ignore_case: bool = false,
};

const Config = struct {
    reverse: bool = false,
    numeric: bool = false,
    ignore_case: bool = false,
    ignore_leading_blanks: bool = false,
    dictionary_order: bool = false,
    general_numeric: bool = false,
    ignore_nonprinting: bool = false,
    unique: bool = false,
    stable: bool = false,
    check: bool = false,
    check_quiet: bool = false,
    merge: bool = false,
    random_sort: bool = false,
    version_sort: bool = false,
    month_sort: bool = false,
    human_numeric_sort: bool = false,
    output_file: ?[]const u8 = null,
    field_sep: ?u8 = null,
    zero_terminated: bool = false,
    random_seed: u64 = 0,
    files: std.ArrayListUnmanaged([]const u8) = .empty,
    keys: std.ArrayListUnmanaged(SortKey) = .empty,
};

fn writeStdout(msg: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, msg.ptr, msg.len);
}

fn writeStderr(msg: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zsort [OPTION]... [FILE]...
        \\
        \\Write sorted concatenation of all FILE(s) to standard output.
        \\With no FILE, or when FILE is -, read standard input.
        \\
        \\Options:
        \\  -b, --ignore-leading-blanks  Ignore leading blanks
        \\  -d, --dictionary-order       Consider only blanks and alphanumeric
        \\  -f, --ignore-case            Fold lower case to upper case
        \\  -g, --general-numeric-sort   Compare as general numeric value
        \\  -h, --human-numeric-sort     Compare human readable numbers (e.g., 2K 1G)
        \\  -i, --ignore-nonprinting     Consider only printable characters
        \\  -M, --month-sort             Compare (unknown) < 'JAN' < ... < 'DEC'
        \\  -n, --numeric-sort           Compare as string numerical value
        \\  -r, --reverse                Reverse the result of comparisons
        \\  -R, --random-sort            Shuffle lines randomly
        \\  -V, --version-sort           Natural sort of (version) numbers
        \\  -c, --check                  Check for sorted input; do not sort
        \\  -C, --check=quiet            Like -c, but do not report first bad line
        \\  -m, --merge                  Merge already sorted files
        \\  -o, --output=FILE            Write result to FILE
        \\  -s, --stable                 Stabilize sort by disabling last-resort
        \\  -t, --field-separator=SEP    Use SEP instead of non-blank to blank
        \\  -u, --unique                 Output only first of equal lines
        \\  -z, --zero-terminated        End lines with 0 byte, not newline
        \\  -k, --key=KEYDEF             Sort via a key; KEYDEF is F[.C][OPTS]
        \\      --random-source=FILE     Get random bytes from FILE
        \\      --help                   Display this help and exit
        \\      --version                Output version information and exit
        \\
        \\KEYDEF is F[.C][OPTS], where F is field number and C is character
        \\position in the field (both origin 1). OPTS is one or more of
        \\fnrbdi for field-specific ordering options.
        \\
        \\Examples:
        \\  zsort file.txt                  # Sort alphabetically
        \\  zsort -n numbers.txt            # Numeric sort
        \\  zsort -r file.txt               # Reverse sort
        \\  zsort -R file.txt               # Shuffle randomly
        \\  zsort -V versions.txt           # Version sort (1.2 < 1.10)
        \\  zsort -k2 -t: /etc/passwd       # Sort by second field
        \\  zsort -u file.txt               # Sort and remove duplicates
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zsort " ++ VERSION ++ " - High-performance line sorting\n");
}

fn parseArgs(args: []const []const u8, allocator: std.mem.Allocator) !Config {
    var config = Config{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            if (arg[1] != '-') {
                // Short options
                var j: usize = 1;
                while (j < arg.len) : (j += 1) {
                    switch (arg[j]) {
                        'r' => config.reverse = true,
                        'n' => config.numeric = true,
                        'f' => config.ignore_case = true,
                        'b' => config.ignore_leading_blanks = true,
                        'd' => config.dictionary_order = true,
                        'g' => config.general_numeric = true,
                        'i' => config.ignore_nonprinting = true,
                        'u' => config.unique = true,
                        's' => config.stable = true,
                        'c' => config.check = true,
                        'C' => {
                            config.check = true;
                            config.check_quiet = true;
                        },
                        'm' => config.merge = true,
                        'z' => config.zero_terminated = true,
                        'M' => config.month_sort = true,
                        'h' => config.human_numeric_sort = true,
                        'R' => config.random_sort = true,
                        'V' => config.version_sort = true,
                        'o' => {
                            if (j + 1 < arg.len) {
                                config.output_file = arg[j + 1 ..];
                                break;
                            } else if (i + 1 < args.len) {
                                i += 1;
                                config.output_file = args[i];
                            }
                        },
                        't' => {
                            if (j + 1 < arg.len) {
                                config.field_sep = arg[j + 1];
                                break;
                            } else if (i + 1 < args.len) {
                                i += 1;
                                if (args[i].len > 0) {
                                    config.field_sep = args[i][0];
                                }
                            }
                        },
                        'k' => {
                            if (j + 1 < arg.len) {
                                try parseKey(arg[j + 1 ..], &config.keys, allocator);
                                break;
                            } else if (i + 1 < args.len) {
                                i += 1;
                                try parseKey(args[i], &config.keys, allocator);
                            }
                        },
                        else => {},
                    }
                }
            } else {
                // Long options
                if (std.mem.eql(u8, arg, "--help")) {
                    printUsage();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--version")) {
                    printVersion();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--reverse")) {
                    config.reverse = true;
                } else if (std.mem.eql(u8, arg, "--numeric-sort")) {
                    config.numeric = true;
                } else if (std.mem.eql(u8, arg, "--ignore-case")) {
                    config.ignore_case = true;
                } else if (std.mem.eql(u8, arg, "--ignore-leading-blanks")) {
                    config.ignore_leading_blanks = true;
                } else if (std.mem.eql(u8, arg, "--dictionary-order")) {
                    config.dictionary_order = true;
                } else if (std.mem.eql(u8, arg, "--general-numeric-sort")) {
                    config.general_numeric = true;
                } else if (std.mem.eql(u8, arg, "--ignore-nonprinting")) {
                    config.ignore_nonprinting = true;
                } else if (std.mem.eql(u8, arg, "--unique")) {
                    config.unique = true;
                } else if (std.mem.eql(u8, arg, "--stable")) {
                    config.stable = true;
                } else if (std.mem.eql(u8, arg, "--check")) {
                    config.check = true;
                } else if (std.mem.eql(u8, arg, "--merge")) {
                    config.merge = true;
                } else if (std.mem.eql(u8, arg, "--zero-terminated")) {
                    config.zero_terminated = true;
                } else if (std.mem.eql(u8, arg, "--month-sort")) {
                    config.month_sort = true;
                } else if (std.mem.eql(u8, arg, "--human-numeric-sort")) {
                    config.human_numeric_sort = true;
                } else if (std.mem.eql(u8, arg, "--random-sort")) {
                    config.random_sort = true;
                } else if (std.mem.eql(u8, arg, "--version-sort")) {
                    config.version_sort = true;
                } else if (std.mem.startsWith(u8, arg, "--output=")) {
                    config.output_file = arg[9..];
                } else if (std.mem.startsWith(u8, arg, "--field-separator=")) {
                    if (arg.len > 18) config.field_sep = arg[18];
                } else if (std.mem.startsWith(u8, arg, "--key=")) {
                    try parseKey(arg[6..], &config.keys, allocator);
                }
            }
        } else {
            try config.files.append(allocator, arg);
        }
    }

    if (config.files.items.len == 0) {
        try config.files.append(allocator, "-");
    }

    return config;
}

fn parseKey(spec: []const u8, keys: *std.ArrayListUnmanaged(SortKey), allocator: std.mem.Allocator) !void {
    var key = SortKey{};

    // Parse field number
    var idx: usize = 0;
    while (idx < spec.len and spec[idx] >= '0' and spec[idx] <= '9') : (idx += 1) {}
    if (idx > 0) {
        key.field = std.fmt.parseInt(usize, spec[0..idx], 10) catch 1;
    }

    // Check for .C (character position)
    if (idx < spec.len and spec[idx] == '.') {
        idx += 1;
        const char_start = idx;
        while (idx < spec.len and spec[idx] >= '0' and spec[idx] <= '9') : (idx += 1) {}
        if (idx > char_start) {
            key.start_char = std.fmt.parseInt(usize, spec[char_start..idx], 10) catch 0;
        }
    }

    // Parse start-field options (fnrbdgi)
    while (idx < spec.len) : (idx += 1) {
        switch (spec[idx]) {
            'n' => key.numeric = true,
            'r' => key.reverse = true,
            'b' => key.ignore_leading_blanks = true,
            'd' => key.dictionary_order = true,
            'g' => key.general_numeric = true,
            'i' => key.ignore_nonprinting = true,
            'f' => key.ignore_case = true,
            ',' => {
                idx += 1; // skip comma
                break;
            },
            else => {},
        }
    }

    // Parse end field spec after comma: F[.C][OPTS]
    if (idx < spec.len) {
        const end_start = idx;
        while (idx < spec.len and spec[idx] >= '0' and spec[idx] <= '9') : (idx += 1) {}
        if (idx > end_start) {
            key.end_field = std.fmt.parseInt(usize, spec[end_start..idx], 10) catch 0;
        }

        // Check for .C (end character position)
        if (idx < spec.len and spec[idx] == '.') {
            idx += 1;
            const char_start = idx;
            while (idx < spec.len and spec[idx] >= '0' and spec[idx] <= '9') : (idx += 1) {}
            if (idx > char_start) {
                key.end_char = std.fmt.parseInt(usize, spec[char_start..idx], 10) catch 0;
            }
        }

        // Parse end-field options (apply to whole key)
        while (idx < spec.len) : (idx += 1) {
            switch (spec[idx]) {
                'n' => key.numeric = true,
                'r' => key.reverse = true,
                'b' => key.ignore_leading_blanks = true,
                'd' => key.dictionary_order = true,
                'g' => key.general_numeric = true,
                'i' => key.ignore_nonprinting = true,
                'f' => key.ignore_case = true,
                else => {},
            }
        }
    }

    try keys.append(allocator, key);
}

fn readLines(path: []const u8, config: *const Config, allocator: std.mem.Allocator) !std.ArrayListUnmanaged([]const u8) {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    const is_stdin = std.mem.eql(u8, path, "-");

    var fd: c_int = 0;
    if (!is_stdin) {
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return lines;
        fd = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd < 0) return lines;
    }
    defer {
        if (!is_stdin) _ = libc.close(fd);
    }

    var read_buf: [65536]u8 = undefined;
    var line_buf = std.ArrayListUnmanaged(u8).empty;
    defer line_buf.deinit(allocator);

    const terminator: u8 = if (config.zero_terminated) 0 else '\n';

    while (true) {
        const n_raw = libc.read(fd, &read_buf, read_buf.len);
        if (n_raw <= 0) break;
        const bytes_read: usize = @intCast(n_raw);

        for (read_buf[0..bytes_read]) |c| {
            if (c == terminator) {
                const line_copy = try allocator.dupe(u8, line_buf.items);
                try lines.append(allocator, line_copy);
                line_buf.clearRetainingCapacity();
            } else {
                try line_buf.append(allocator, c);
            }
        }
    }

    // Handle last line without terminator
    if (line_buf.items.len > 0) {
        const line_copy = try allocator.dupe(u8, line_buf.items);
        try lines.append(allocator, line_copy);
    }

    return lines;
}

fn getField(line: []const u8, field_num: usize, sep: ?u8) []const u8 {
    return getFieldRange(line, field_num, 0, sep);
}

fn getFieldRange(line: []const u8, start_field: usize, end_field: usize, sep: ?u8) []const u8 {
    if (start_field == 0) return line;

    const separator = sep orelse ' ';
    var field_idx: usize = 0;
    var start: usize = 0;
    var field_start: usize = 0;
    var found_start = false;
    const actual_end = if (end_field == 0) start_field else end_field;

    for (line, 0..) |c, i| {
        if (c == separator) {
            field_idx += 1;
            if (field_idx == start_field and !found_start) {
                field_start = start;
                found_start = true;
            }
            if (field_idx == actual_end and found_start) {
                return line[field_start..i];
            }
            start = i + 1;
        }
    }

    // Handle last field
    if (!found_start and field_idx + 1 == start_field) {
        field_start = start;
        found_start = true;
    }
    if (found_start) {
        return line[field_start..];
    }

    return "";
}

// Strip leading blanks (spaces and tabs)
fn stripLeadingBlanks(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    return s[i..];
}

// Check if character is valid for dictionary order (blank or alphanumeric)
fn isDictChar(c: u8) bool {
    return c == ' ' or c == '\t' or std.ascii.isAlphanumeric(c);
}

// Check if character is printable
fn isPrintable(c: u8) bool {
    return c >= 0x20 and c < 0x7F;
}

// Parse general numeric value (handles scientific notation, leading whitespace, etc.)
fn parseGeneralNumeric(s: []const u8) f64 {
    // Skip leading whitespace
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) : (start += 1) {}
    if (start >= s.len) return -std.math.inf(f64);

    // Check for NaN, Inf, -Inf
    const trimmed = s[start..];
    if (trimmed.len >= 3) {
        const lower = blk: {
            var buf: [4]u8 = undefined;
            const len = @min(trimmed.len, 4);
            for (0..len) |i| {
                buf[i] = std.ascii.toLower(trimmed[i]);
            }
            break :blk buf[0..len];
        };
        if (std.mem.startsWith(u8, lower, "nan")) return std.math.nan(f64);
        if (std.mem.startsWith(u8, lower, "inf")) return std.math.inf(f64);
        if (std.mem.startsWith(u8, lower, "-inf")) return -std.math.inf(f64);
    }

    // Try to parse as float (handles scientific notation)
    return std.fmt.parseFloat(f64, trimmed) catch -std.math.inf(f64);
}

// Compare two values with given options
fn compareWithOptions(
    cmp_a: []const u8,
    cmp_b: []const u8,
    reverse: bool,
    ignore_case: bool,
    ignore_blanks: bool,
    dict_order: bool,
    ignore_nonprint: bool,
) std.math.Order {
    var a = cmp_a;
    var b = cmp_b;

    // Strip leading blanks if requested
    if (ignore_blanks) {
        a = stripLeadingBlanks(a);
        b = stripLeadingBlanks(b);
    }

    // Compare character by character with filtering
    var ia: usize = 0;
    var ib: usize = 0;

    while (true) {
        // Skip non-matching characters based on options
        if (dict_order) {
            while (ia < a.len and !isDictChar(a[ia])) : (ia += 1) {}
            while (ib < b.len and !isDictChar(b[ib])) : (ib += 1) {}
        } else if (ignore_nonprint) {
            while (ia < a.len and !isPrintable(a[ia])) : (ia += 1) {}
            while (ib < b.len and !isPrintable(b[ib])) : (ib += 1) {}
        }

        if (ia >= a.len and ib >= b.len) return .eq;
        if (ia >= a.len) return if (reverse) .gt else .lt;
        if (ib >= b.len) return if (reverse) .lt else .gt;

        var ca = a[ia];
        var cb = b[ib];

        if (ignore_case) {
            ca = std.ascii.toLower(ca);
            cb = std.ascii.toLower(cb);
        }

        if (ca != cb) {
            if (reverse) {
                return if (ca > cb) .lt else .gt;
            } else {
                return if (ca < cb) .lt else .gt;
            }
        }

        ia += 1;
        ib += 1;
    }
}

// Compare version strings naturally (e.g., "1.2" < "1.10")
fn compareVersionStrings(a: []const u8, b: []const u8) std.math.Order {
    var ia: usize = 0;
    var ib: usize = 0;

    while (ia < a.len or ib < b.len) {
        // Skip leading zeros within numeric segments (but keep at least one digit)
        // Compare non-digit prefixes first
        const start_a = ia;
        const start_b = ib;
        while (ia < a.len and !std.ascii.isDigit(a[ia])) : (ia += 1) {}
        while (ib < b.len and !std.ascii.isDigit(b[ib])) : (ib += 1) {}

        // Compare non-digit parts
        const non_digit_a = a[start_a..ia];
        const non_digit_b = b[start_b..ib];
        const nd_order = std.mem.order(u8, non_digit_a, non_digit_b);
        if (nd_order != .eq) return nd_order;

        // Now compare numeric parts
        const num_start_a = ia;
        const num_start_b = ib;
        while (ia < a.len and std.ascii.isDigit(a[ia])) : (ia += 1) {}
        while (ib < b.len and std.ascii.isDigit(b[ib])) : (ib += 1) {}

        const num_a = a[num_start_a..ia];
        const num_b = b[num_start_b..ib];

        if (num_a.len == 0 and num_b.len == 0) continue;
        if (num_a.len == 0) return .lt;
        if (num_b.len == 0) return .gt;

        // Compare as numbers: first by length (longer = larger), then lexically
        // Skip leading zeros for comparison
        var skip_a: usize = 0;
        while (skip_a < num_a.len - 1 and num_a[skip_a] == '0') : (skip_a += 1) {}
        var skip_b: usize = 0;
        while (skip_b < num_b.len - 1 and num_b[skip_b] == '0') : (skip_b += 1) {}

        const eff_a = num_a[skip_a..];
        const eff_b = num_b[skip_b..];

        if (eff_a.len != eff_b.len) {
            return if (eff_a.len < eff_b.len) .lt else .gt;
        }

        const lex_order = std.mem.order(u8, eff_a, eff_b);
        if (lex_order != .eq) return lex_order;
    }

    return .eq;
}

/// Parse a 3-letter month abbreviation from the beginning of a string (after
/// skipping leading blanks). Returns 1..12 for JAN..DEC, 0 for unknown.
fn parseMonth(s: []const u8) u8 {
    const months = [_][]const u8{
        "jan", "feb", "mar", "apr", "may", "jun",
        "jul", "aug", "sep", "oct", "nov", "dec",
    };

    // Skip leading blanks
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) : (start += 1) {}
    if (start + 3 > s.len) return 0;

    var buf: [3]u8 = undefined;
    for (0..3) |i| {
        buf[i] = std.ascii.toLower(s[start + i]);
    }

    for (months, 0..) |m, idx| {
        if (std.mem.eql(u8, &buf, m)) return @intCast(idx + 1);
    }
    return 0;
}

/// Parse a human-readable numeric value with SI suffix (K, M, G, T, P, E).
/// Returns a comparable f64 value.
fn parseHumanNumeric(s: []const u8) f64 {
    // Skip leading blanks
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) : (start += 1) {}
    if (start >= s.len) return 0;

    const trimmed = s[start..];

    // Find the end of the numeric part (including sign and decimal point)
    var num_end: usize = 0;
    if (num_end < trimmed.len and (trimmed[num_end] == '-' or trimmed[num_end] == '+')) {
        num_end += 1;
    }
    var has_dot = false;
    while (num_end < trimmed.len) {
        if (trimmed[num_end] >= '0' and trimmed[num_end] <= '9') {
            num_end += 1;
        } else if (trimmed[num_end] == '.' and !has_dot) {
            has_dot = true;
            num_end += 1;
        } else break;
    }

    if (num_end == 0) return 0;

    const base_val = std.fmt.parseFloat(f64, trimmed[0..num_end]) catch return 0;

    // Check for suffix
    if (num_end < trimmed.len) {
        const suffix = std.ascii.toUpper(trimmed[num_end]);
        const multiplier: f64 = switch (suffix) {
            'K' => 1024.0,
            'M' => 1024.0 * 1024.0,
            'G' => 1024.0 * 1024.0 * 1024.0,
            'T' => 1024.0 * 1024.0 * 1024.0 * 1024.0,
            'P' => 1024.0 * 1024.0 * 1024.0 * 1024.0 * 1024.0,
            'E' => 1024.0 * 1024.0 * 1024.0 * 1024.0 * 1024.0 * 1024.0,
            else => 1.0,
        };
        return base_val * multiplier;
    }

    return base_val;
}

fn compareLines(config: *const Config, a: []const u8, b: []const u8) bool {
    // Get comparison strings (possibly field-specific)
    var cmp_a = a;
    var cmp_b = b;

    // Determine effective options (from key or global config)
    var reverse = config.reverse;
    var numeric = config.numeric;
    var ignore_case = config.ignore_case;
    var ignore_blanks = config.ignore_leading_blanks;
    var dict_order = config.dictionary_order;
    var general_numeric = config.general_numeric;
    var ignore_nonprint = config.ignore_nonprinting;

    if (config.keys.items.len > 0) {
        const key = config.keys.items[0];
        cmp_a = getFieldRange(a, key.field, key.end_field, config.field_sep);
        cmp_b = getFieldRange(b, key.field, key.end_field, config.field_sep);

        // Apply character offset if specified
        if (key.start_char > 0) {
            const offset = key.start_char - 1; // 1-indexed
            if (offset < cmp_a.len) cmp_a = cmp_a[offset..] else cmp_a = "";
            if (offset < cmp_b.len) cmp_b = cmp_b[offset..] else cmp_b = "";
        }

        // Apply end character position
        if (key.end_char > 0) {
            if (key.end_char < cmp_a.len) cmp_a = cmp_a[0..key.end_char];
            if (key.end_char < cmp_b.len) cmp_b = cmp_b[0..key.end_char];
        }

        // Key-specific options override global
        if (key.reverse) reverse = true;
        if (key.numeric) numeric = true;
        if (key.ignore_case) ignore_case = true;
        if (key.ignore_leading_blanks) ignore_blanks = true;
        if (key.dictionary_order) dict_order = true;
        if (key.general_numeric) general_numeric = true;
        if (key.ignore_nonprinting) ignore_nonprint = true;
    }

    // Month sort
    if (config.month_sort) {
        const ma = parseMonth(cmp_a);
        const mb = parseMonth(cmp_b);
        if (ma != mb) {
            return if (reverse) ma > mb else ma < mb;
        }
        // Fall through to last-resort comparison
        return std.mem.order(u8, a, b) == .lt;
    }

    // Human-readable numeric sort
    if (config.human_numeric_sort) {
        const ha = parseHumanNumeric(cmp_a);
        const hb = parseHumanNumeric(cmp_b);
        if (ha != hb) {
            return if (reverse) ha > hb else ha < hb;
        }
        // Fall through to last-resort comparison
        return std.mem.order(u8, a, b) == .lt;
    }

    // Version sort (natural sorting of version numbers)
    if (config.version_sort) {
        const ver_order = compareVersionStrings(cmp_a, cmp_b);
        return if (reverse) ver_order == .gt else ver_order == .lt;
    }

    // General numeric sort (handles scientific notation, NaN, Inf)
    if (general_numeric) {
        const num_a = parseGeneralNumeric(cmp_a);
        const num_b = parseGeneralNumeric(cmp_b);
        // Handle NaN: NaN values sort after all others
        const a_nan = std.math.isNan(num_a);
        const b_nan = std.math.isNan(num_b);
        if (a_nan and b_nan) return false; // Equal
        if (a_nan) return reverse; // NaN goes last (or first if reverse)
        if (b_nan) return !reverse;
        return if (reverse) num_a > num_b else num_a < num_b;
    }

    // Numeric sort
    if (numeric) {
        var parse_a = cmp_a;
        var parse_b = cmp_b;
        if (ignore_blanks) {
            parse_a = stripLeadingBlanks(parse_a);
            parse_b = stripLeadingBlanks(parse_b);
        }
        const num_a = std.fmt.parseFloat(f64, parse_a) catch 0;
        const num_b = std.fmt.parseFloat(f64, parse_b) catch 0;
        if (num_a != num_b) {
            return if (reverse) num_a > num_b else num_a < num_b;
        }
        // Fall through to last-resort comparison
        return std.mem.order(u8, a, b) == .lt;
    }

    // String comparison with options
    const order = compareWithOptions(cmp_a, cmp_b, reverse, ignore_case, ignore_blanks, dict_order, ignore_nonprint);
    if (order != .eq) return order == .lt;

    // Last-resort: compare full lines for stable ordering
    return std.mem.order(u8, a, b) == .lt;
}

fn checkSorted(lines: []const []const u8, config: *const Config) bool {
    if (lines.len < 2) return true;

    for (1..lines.len) |i| {
        if (compareLines(config, lines[i], lines[i - 1])) {
            if (!config.check_quiet) {
                var err_buf: [256]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "zsort: disorder: {s}\n", .{lines[i]}) catch "zsort: disorder\n";
                writeStderr(err_msg);
            }
            return false;
        }
    }
    return true;
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

    var config = parseArgs(args[1..], allocator) catch {
        std.process.exit(1);
    };
    defer config.files.deinit(allocator);
    defer config.keys.deinit(allocator);

    // Read all lines
    var all_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (all_lines.items) |line| {
            allocator.free(line);
        }
        all_lines.deinit(allocator);
    }

    for (config.files.items) |path| {
        var file_lines = try readLines(path, &config, allocator);
        defer file_lines.deinit(allocator);
        for (file_lines.items) |line| {
            try all_lines.append(allocator, line);
        }
    }

    // Check mode
    if (config.check) {
        const is_sorted = checkSorted(all_lines.items, &config);
        std.process.exit(if (is_sorted) 0 else 1);
    }

    // Sort or shuffle
    if (config.random_sort) {
        // Fisher-Yates shuffle
        var prng = std.Random.DefaultPrng.init(blk: {
            // Use arc4random for seed
            const low: u64 = arc4random();
            const high: u64 = arc4random();
            break :blk (high << 32) | low;
        });
        const rand = prng.random();

        var i = all_lines.items.len;
        while (i > 1) {
            i -= 1;
            const j = rand.intRangeAtMost(usize, 0, i);
            const tmp = all_lines.items[i];
            all_lines.items[i] = all_lines.items[j];
            all_lines.items[j] = tmp;
        }
    } else {
        const SortContext = struct {
            cfg: *const Config,

            pub fn lessThan(ctx: @This(), a: []const u8, b: []const u8) bool {
                return compareLines(ctx.cfg, a, b);
            }
        };

        std.mem.sortUnstable([]const u8, all_lines.items, SortContext{ .cfg = &config }, SortContext.lessThan);
    }

    // Output
    const terminator: []const u8 = if (config.zero_terminated) "\x00" else "\n";
    var prev_line: ?[]const u8 = null;

    for (all_lines.items) |line| {
        if (config.unique) {
            if (prev_line) |prev| {
                if (std.mem.eql(u8, line, prev)) continue;
            }
        }
        writeStdout(line);
        writeStdout(terminator);
        prev_line = line;
    }
}
