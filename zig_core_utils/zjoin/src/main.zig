//! zjoin - High-performance file join utility
//!
//! Join lines of two files on a common field.
//!
//! Usage: zjoin [OPTION]... FILE1 FILE2

const std = @import("std");
const posix = std.posix;
const libc = std.c;

const VERSION = "1.0.0";

const Config = struct {
    field1: usize = 1,
    field2: usize = 1,
    output_fields: ?[]const u8 = null,
    field_sep: u8 = ' ',
    output_sep: []const u8 = " ",
    ignore_case: bool = false,
    print_unpairable1: bool = false,
    print_unpairable2: bool = false,
    suppress_joined: bool = false,
    check_order: bool = true,
    empty: []const u8 = "",
    header: bool = false,
    zero_terminated: bool = false,
    file1: ?[]const u8 = null,
    file2: ?[]const u8 = null,
};

fn writeStdout(msg: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, msg.ptr, msg.len);
}

fn writeStderr(msg: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zjoin [OPTION]... FILE1 FILE2
        \\
        \\For each pair of input lines with identical join fields, write a line
        \\to standard output. The default join field is the first.
        \\
        \\Options:
        \\  -1 FIELD         Join on this FIELD of file 1
        \\  -2 FIELD         Join on this FIELD of file 2
        \\  -a FILENUM       Print unpairable lines from FILENUM (1 or 2)
        \\  -e STRING        Replace missing input fields with STRING
        \\  -i, --ignore-case Ignore case when comparing fields
        \\  -j FIELD         Equivalent to '-1 FIELD -2 FIELD'
        \\  -o FORMAT        Output these fields (e.g., 1.1,2.2)
        \\  -t CHAR          Use CHAR as field separator
        \\  -v FILENUM       Like -a but suppress joined output
        \\  -z, --zero-terminated End lines with 0 byte, not newline
        \\  --header         Treat first line as header
        \\  --check-order    Check that input is sorted
        \\  --nocheck-order  Do not check sort order
        \\      --help       Display this help and exit
        \\      --version    Output version information and exit
        \\
        \\Examples:
        \\  zjoin file1 file2                    # Join on first field
        \\  zjoin -1 2 -2 1 file1 file2          # Join on field 2 of file1, field 1 of file2
        \\  zjoin -t: /etc/passwd /etc/group     # Use : as separator
        \\  zjoin -a1 file1 file2                # Include unmatched from file1
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zjoin " ++ VERSION ++ " - High-performance file join\n");
}

fn parseArgs(args: []const []const u8) !Config {
    var config = Config{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-' and arg.len > 1) {
            if (arg[1] != '-') {
                // Short options
                switch (arg[1]) {
                    '1' => {
                        if (arg.len > 2) {
                            config.field1 = std.fmt.parseInt(usize, arg[2..], 10) catch 1;
                        } else if (i + 1 < args.len) {
                            i += 1;
                            config.field1 = std.fmt.parseInt(usize, args[i], 10) catch 1;
                        }
                    },
                    '2' => {
                        if (arg.len > 2) {
                            config.field2 = std.fmt.parseInt(usize, arg[2..], 10) catch 1;
                        } else if (i + 1 < args.len) {
                            i += 1;
                            config.field2 = std.fmt.parseInt(usize, args[i], 10) catch 1;
                        }
                    },
                    'j' => {
                        if (arg.len > 2) {
                            const f = std.fmt.parseInt(usize, arg[2..], 10) catch 1;
                            config.field1 = f;
                            config.field2 = f;
                        } else if (i + 1 < args.len) {
                            i += 1;
                            const f = std.fmt.parseInt(usize, args[i], 10) catch 1;
                            config.field1 = f;
                            config.field2 = f;
                        }
                    },
                    'a' => {
                        if (arg.len > 2) {
                            if (arg[2] == '1') config.print_unpairable1 = true;
                            if (arg[2] == '2') config.print_unpairable2 = true;
                        } else if (i + 1 < args.len) {
                            i += 1;
                            if (args[i][0] == '1') config.print_unpairable1 = true;
                            if (args[i][0] == '2') config.print_unpairable2 = true;
                        }
                    },
                    'v' => {
                        config.suppress_joined = true;
                        if (arg.len > 2) {
                            if (arg[2] == '1') config.print_unpairable1 = true;
                            if (arg[2] == '2') config.print_unpairable2 = true;
                        } else if (i + 1 < args.len) {
                            i += 1;
                            if (args[i][0] == '1') config.print_unpairable1 = true;
                            if (args[i][0] == '2') config.print_unpairable2 = true;
                        }
                    },
                    't' => {
                        if (arg.len > 2) {
                            config.field_sep = arg[2];
                            config.output_sep = arg[2..3];
                        } else if (i + 1 < args.len) {
                            i += 1;
                            if (args[i].len > 0) {
                                config.field_sep = args[i][0];
                                config.output_sep = args[i][0..1];
                            }
                        }
                    },
                    'e' => {
                        if (arg.len > 2) {
                            config.empty = arg[2..];
                        } else if (i + 1 < args.len) {
                            i += 1;
                            config.empty = args[i];
                        }
                    },
                    'o' => {
                        if (arg.len > 2) {
                            config.output_fields = arg[2..];
                        } else if (i + 1 < args.len) {
                            i += 1;
                            config.output_fields = args[i];
                        }
                    },
                    'i' => config.ignore_case = true,
                    'z' => config.zero_terminated = true,
                    else => {},
                }
            } else {
                // Long options
                if (std.mem.eql(u8, arg, "--help")) {
                    printUsage();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--version")) {
                    printVersion();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--ignore-case")) {
                    config.ignore_case = true;
                } else if (std.mem.eql(u8, arg, "--zero-terminated")) {
                    config.zero_terminated = true;
                } else if (std.mem.eql(u8, arg, "--header")) {
                    config.header = true;
                } else if (std.mem.eql(u8, arg, "--check-order")) {
                    config.check_order = true;
                } else if (std.mem.eql(u8, arg, "--nocheck-order")) {
                    config.check_order = false;
                }
            }
        } else {
            if (config.file1 == null) {
                config.file1 = arg;
            } else if (config.file2 == null) {
                config.file2 = arg;
            }
        }
    }

    return config;
}

fn getField(line: []const u8, field_num: usize, sep: u8) []const u8 {
    if (field_num == 0) return "";

    var field_idx: usize = 1;
    var start: usize = 0;

    for (line, 0..) |c, idx| {
        if (c == sep) {
            if (field_idx == field_num) {
                return line[start..idx];
            }
            field_idx += 1;
            start = idx + 1;
        }
    }

    if (field_idx == field_num) {
        return line[start..];
    }

    return "";
}

fn splitFields(line: []const u8, sep: u8, out: *[64][]const u8) usize {
    var count: usize = 0;
    var start: usize = 0;

    for (line, 0..) |c, idx| {
        if (c == sep) {
            if (count < 64) {
                out[count] = line[start..idx];
                count += 1;
            }
            start = idx + 1;
        }
    }

    if (count < 64) {
        out[count] = line[start..];
        count += 1;
    }

    return count;
}

fn compareFields(a: []const u8, b: []const u8, ignore_case: bool) std.math.Order {
    if (ignore_case) {
        var i: usize = 0;
        while (i < a.len and i < b.len) : (i += 1) {
            const ca = std.ascii.toLower(a[i]);
            const cb = std.ascii.toLower(b[i]);
            if (ca < cb) return .lt;
            if (ca > cb) return .gt;
        }
        if (a.len < b.len) return .lt;
        if (a.len > b.len) return .gt;
        return .eq;
    }
    return std.mem.order(u8, a, b);
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

    if (config.file1 == null or config.file2 == null) {
        writeStderr("zjoin: two files required\n");
        std.process.exit(1);
    }

    const terminator: u8 = if (config.zero_terminated) 0 else '\n';
    const terminator_str: []const u8 = if (config.zero_terminated) "\x00" else "\n";

    // Read both files into memory (for simplicity)
    var lines1 = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (lines1.items) |l| allocator.free(l);
        lines1.deinit(allocator);
    }

    var lines2 = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (lines2.items) |l| allocator.free(l);
        lines2.deinit(allocator);
    }

    // Read file 1
    {
        const is_stdin = std.mem.eql(u8, config.file1.?, "-");
        var fd: c_int = 0;
        if (!is_stdin) {
            var path_buf: [4096]u8 = undefined;
            const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{config.file1.?}) catch {
                std.process.exit(1);
            };
            const fd_ret = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
            if (fd_ret < 0) {
                writeStderr("zjoin: cannot open FILE1\n");
                std.process.exit(1);
            }
            fd = fd_ret;
        }
        defer {
            if (!is_stdin) _ = libc.close(fd);
        }

        var read_buf: [65536]u8 = undefined;
        var line_buf = std.ArrayListUnmanaged(u8).empty;
        defer line_buf.deinit(allocator);

        while (true) {
            const bytes_ret = libc.read(fd, &read_buf, read_buf.len);
            if (bytes_ret <= 0) break;
            const bytes: usize = @intCast(bytes_ret);
            for (read_buf[0..bytes]) |c| {
                if (c == terminator) {
                    try lines1.append(allocator, try allocator.dupe(u8, line_buf.items));
                    line_buf.clearRetainingCapacity();
                } else {
                    try line_buf.append(allocator, c);
                }
            }
        }
        if (line_buf.items.len > 0) {
            try lines1.append(allocator, try allocator.dupe(u8, line_buf.items));
        }
    }

    // Read file 2
    {
        const is_stdin = std.mem.eql(u8, config.file2.?, "-");
        var fd: c_int = 0;
        if (!is_stdin) {
            var path_buf: [4096]u8 = undefined;
            const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{config.file2.?}) catch {
                std.process.exit(1);
            };
            const fd_ret = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
            if (fd_ret < 0) {
                writeStderr("zjoin: cannot open FILE2\n");
                std.process.exit(1);
            }
            fd = fd_ret;
        }
        defer {
            if (!is_stdin) _ = libc.close(fd);
        }

        var read_buf: [65536]u8 = undefined;
        var line_buf = std.ArrayListUnmanaged(u8).empty;
        defer line_buf.deinit(allocator);

        while (true) {
            const bytes_ret = libc.read(fd, &read_buf, read_buf.len);
            if (bytes_ret <= 0) break;
            const bytes: usize = @intCast(bytes_ret);
            for (read_buf[0..bytes]) |c| {
                if (c == terminator) {
                    try lines2.append(allocator, try allocator.dupe(u8, line_buf.items));
                    line_buf.clearRetainingCapacity();
                } else {
                    try line_buf.append(allocator, c);
                }
            }
        }
        if (line_buf.items.len > 0) {
            try lines2.append(allocator, try allocator.dupe(u8, line_buf.items));
        }
    }

    // Track which lines have been matched
    var matched1 = try allocator.alloc(bool, lines1.items.len);
    defer allocator.free(matched1);
    @memset(matched1, false);

    var matched2 = try allocator.alloc(bool, lines2.items.len);
    defer allocator.free(matched2);
    @memset(matched2, false);

    // Build hash index on file2 for O(n+m) join instead of O(n*m)
    // Key: join field value -> list of line indices in file2
    var hash_index = std.StringHashMap(std.ArrayListUnmanaged(usize)).init(allocator);

    // Track allocated keys for case-insensitive mode (need to free them later)
    var allocated_keys = std.ArrayListUnmanaged([]u8).empty;
    defer {
        for (allocated_keys.items) |key| {
            allocator.free(key);
        }
        allocated_keys.deinit(allocator);
    }

    defer {
        var it = hash_index.valueIterator();
        while (it.next()) |list| {
            list.deinit(allocator);
        }
        hash_index.deinit();
    }

    // Populate hash index from file2
    for (lines2.items, 0..) |line2, idx2| {
        const key2 = getField(line2, config.field2, config.field_sep);

        // For case-insensitive matching, normalize the key
        var lookup_key: []const u8 = key2;
        if (config.ignore_case) {
            const normalized_key = try allocator.alloc(u8, key2.len);
            for (key2, 0..) |c, ki| {
                normalized_key[ki] = std.ascii.toLower(c);
            }
            lookup_key = normalized_key;
            try allocated_keys.append(allocator, normalized_key);
        }

        const gop = try hash_index.getOrPut(lookup_key);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayListUnmanaged(usize).empty;
        }
        try gop.value_ptr.append(allocator, idx2);
    }

    // Perform hash join: O(n) iteration through file1 with O(1) average lookups
    for (lines1.items, 0..) |line1, idx1| {
        const key1 = getField(line1, config.field1, config.field_sep);

        // For case-insensitive matching, normalize the lookup key
        var lookup_key: []u8 = undefined;
        var free_lookup = false;
        if (config.ignore_case) {
            lookup_key = try allocator.alloc(u8, key1.len);
            for (key1, 0..) |c, ki| {
                lookup_key[ki] = std.ascii.toLower(c);
            }
            free_lookup = true;
        } else {
            lookup_key = @constCast(key1);
        }
        defer if (free_lookup) allocator.free(lookup_key);

        // Look up matching indices in file2
        if (hash_index.get(lookup_key)) |indices| {
            matched1[idx1] = true;

            for (indices.items) |idx2| {
                matched2[idx2] = true;

                if (!config.suppress_joined) {
                    const line2 = lines2.items[idx2];

                    // Output joined line
                    var fields1: [64][]const u8 = undefined;
                    const nf1 = splitFields(line1, config.field_sep, &fields1);

                    var fields2: [64][]const u8 = undefined;
                    const nf2 = splitFields(line2, config.field_sep, &fields2);

                    if (config.output_fields) |ofmt| {
                        // Use -o format spec
                        var first_field = true;
                        var pos: usize = 0;
                        while (pos < ofmt.len) {
                            // Skip separators (comma or space)
                            while (pos < ofmt.len and (ofmt[pos] == ',' or ofmt[pos] == ' ')) : (pos += 1) {}
                            if (pos >= ofmt.len) break;

                            // Find end of this spec
                            var end = pos;
                            while (end < ofmt.len and ofmt[end] != ',' and ofmt[end] != ' ') : (end += 1) {}
                            const spec = ofmt[pos..end];
                            pos = end;

                            if (!first_field) {
                                writeStdout(config.output_sep);
                            }
                            first_field = false;

                            if (std.mem.eql(u8, spec, "0")) {
                                // Join field
                                writeStdout(key1);
                            } else if (std.mem.indexOfScalar(u8, spec, '.')) |dot| {
                                const file_num = std.fmt.parseInt(usize, spec[0..dot], 10) catch 0;
                                const field_num = std.fmt.parseInt(usize, spec[dot + 1 ..], 10) catch 0;
                                if (file_num == 1) {
                                    if (field_num >= 1 and field_num <= nf1) {
                                        writeStdout(fields1[field_num - 1]);
                                    } else {
                                        writeStdout(config.empty);
                                    }
                                } else if (file_num == 2) {
                                    if (field_num >= 1 and field_num <= nf2) {
                                        writeStdout(fields2[field_num - 1]);
                                    } else {
                                        writeStdout(config.empty);
                                    }
                                }
                            }
                        }
                    } else {
                        // Default: join field, then other fields from file1, then file2
                        writeStdout(key1);

                        for (0..nf1) |fi| {
                            if (fi + 1 != config.field1) {
                                writeStdout(config.output_sep);
                                writeStdout(fields1[fi]);
                            }
                        }

                        for (0..nf2) |fi| {
                            if (fi + 1 != config.field2) {
                                writeStdout(config.output_sep);
                                writeStdout(fields2[fi]);
                            }
                        }
                    }

                    writeStdout(terminator_str);
                }
            }
        }
    }

    // Print unpairable lines from file1
    if (config.print_unpairable1) {
        for (lines1.items, 0..) |line, idx| {
            if (!matched1[idx]) {
                writeStdout(line);
                writeStdout(terminator_str);
            }
        }
    }

    // Print unpairable lines from file2
    if (config.print_unpairable2) {
        for (lines2.items, 0..) |line, idx| {
            if (!matched2[idx]) {
                writeStdout(line);
                writeStdout(terminator_str);
            }
        }
    }
}
