//! zuniq - Report or omit repeated lines
//!
//! High-performance uniq implementation in Zig.

const std = @import("std");
const libc = std.c;

const VERSION = "1.0.0";

const GroupMethod = enum {
    none,
    prepend,
    append,
    separate,
    both,
};

const AllRepeatedMethod = enum {
    none,
    prepend,
    separate,
};

const Config = struct {
    count: bool = false,
    repeated: bool = false,
    unique: bool = false,
    ignore_case: bool = false,
    skip_fields: usize = 0,
    skip_chars: usize = 0,
    check_chars: usize = 0, // 0 means compare entire line
    input_file: ?[]const u8 = null,
    output_file: ?[]const u8 = null,
    group: ?GroupMethod = null,
    all_repeated: ?AllRepeatedMethod = null,
};

fn writeStdout(data: []const u8) void {
    _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
}

fn writeStderr(data: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, data.ptr, data.len);
}

fn writeFd(fd: c_int, data: []const u8) void {
    _ = libc.write(fd, data.ptr, data.len);
}

fn printUsage() void {
    const usage =
        \\Usage: zuniq [OPTION]... [INPUT [OUTPUT]]
        \\Filter adjacent matching lines from INPUT (or stdin),
        \\writing to OUTPUT (or stdout).
        \\
        \\Options:
        \\  -c, --count           Prefix lines by occurrence count
        \\  -d, --repeated        Only print duplicate lines
        \\  -D, --all-repeated[=METHOD]  Print all duplicate lines
        \\                        METHOD: none (default), prepend, separate
        \\  -u, --unique          Only print unique lines
        \\  -i, --ignore-case     Ignore case when comparing
        \\  -f, --skip-fields=N   Skip first N fields
        \\  -s, --skip-chars=N    Skip first N characters
        \\  -w, --check-chars=N   Compare no more than N characters
        \\      --group[=METHOD]  Show all items, separate groups
        \\                        METHOD: prepend, append, separate (default), both
        \\      --help            Display this help and exit
        \\      --version         Output version information and exit
        \\
        \\A field is a run of blanks followed by non-blank characters.
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("zuniq " ++ VERSION ++ "\n");
}

fn skipFields(line: []const u8, n: usize) []const u8 {
    var remaining = line;
    var fields_skipped: usize = 0;

    while (fields_skipped < n and remaining.len > 0) {
        // Skip leading blanks
        while (remaining.len > 0 and (remaining[0] == ' ' or remaining[0] == '\t')) {
            remaining = remaining[1..];
        }
        // Skip non-blanks
        while (remaining.len > 0 and remaining[0] != ' ' and remaining[0] != '\t') {
            remaining = remaining[1..];
        }
        fields_skipped += 1;
    }

    return remaining;
}

fn getCompareSlice(line: []const u8, cfg: *const Config) []const u8 {
    var result = line;

    // Skip fields first
    if (cfg.skip_fields > 0) {
        result = skipFields(result, cfg.skip_fields);
    }

    // Then skip chars
    if (cfg.skip_chars > 0 and result.len > cfg.skip_chars) {
        result = result[cfg.skip_chars..];
    } else if (cfg.skip_chars > 0) {
        result = "";
    }

    // Limit to check_chars if specified
    if (cfg.check_chars > 0 and result.len > cfg.check_chars) {
        result = result[0..cfg.check_chars];
    }

    return result;
}

fn linesEqual(a: []const u8, b: []const u8, ignore_case: bool) bool {
    if (a.len != b.len) return false;

    if (ignore_case) {
        for (a, b) |ca, cb| {
            const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
            const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
            if (la != lb) return false;
        }
        return true;
    }

    return std.mem.eql(u8, a, b);
}

fn outputLine(out_fd: c_int, line: []const u8, count: u64, cfg: *const Config) void {
    if (cfg.count) {
        var buf: [32]u8 = undefined;
        const count_str = std.fmt.bufPrint(&buf, "{d:>7} ", .{count}) catch return;
        writeFd(out_fd, count_str);
    }
    writeFd(out_fd, line);
    writeFd(out_fd, "\n");
}

pub fn main(init: std.process.Init) !void {
    var cfg = Config{};

    // Parse arguments
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name
    var positional: usize = 0;

    // Track if we need next arg for -f, -s, -w options
    var expect_skip_fields = false;
    var expect_skip_chars = false;
    var expect_check_chars = false;

    while (args_iter.next()) |arg| {
        if (expect_skip_fields) {
            cfg.skip_fields = std.fmt.parseInt(usize, arg, 10) catch 0;
            expect_skip_fields = false;
            continue;
        }
        if (expect_skip_chars) {
            cfg.skip_chars = std.fmt.parseInt(usize, arg, 10) catch 0;
            expect_skip_chars = false;
            continue;
        }
        if (expect_check_chars) {
            cfg.check_chars = std.fmt.parseInt(usize, arg, 10) catch 0;
            expect_check_chars = false;
            continue;
        }

        if (std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            return;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
            cfg.count = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--repeated")) {
            cfg.repeated = true;
        } else if (std.mem.eql(u8, arg, "-D") or std.mem.eql(u8, arg, "--all-repeated")) {
            cfg.all_repeated = .none;
        } else if (std.mem.startsWith(u8, arg, "--all-repeated=")) {
            const method = arg[15..];
            if (std.mem.eql(u8, method, "none")) {
                cfg.all_repeated = .none;
            } else if (std.mem.eql(u8, method, "prepend")) {
                cfg.all_repeated = .prepend;
            } else if (std.mem.eql(u8, method, "separate")) {
                cfg.all_repeated = .separate;
            } else {
                cfg.all_repeated = .none;
            }
        } else if (std.mem.eql(u8, arg, "--group")) {
            cfg.group = .separate;
        } else if (std.mem.startsWith(u8, arg, "--group=")) {
            const method = arg[8..];
            if (std.mem.eql(u8, method, "prepend")) {
                cfg.group = .prepend;
            } else if (std.mem.eql(u8, method, "append")) {
                cfg.group = .append;
            } else if (std.mem.eql(u8, method, "separate")) {
                cfg.group = .separate;
            } else if (std.mem.eql(u8, method, "both")) {
                cfg.group = .both;
            } else {
                cfg.group = .separate;
            }
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--unique")) {
            cfg.unique = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case")) {
            cfg.ignore_case = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--skip-fields")) {
            expect_skip_fields = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--skip-chars")) {
            expect_skip_chars = true;
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--check-chars")) {
            expect_check_chars = true;
        } else if (std.mem.startsWith(u8, arg, "--check-chars=")) {
            cfg.check_chars = std.fmt.parseInt(usize, arg[14..], 10) catch 0;
        } else if (std.mem.startsWith(u8, arg, "-w") and arg.len > 2) {
            // Handle -wN form (value attached to flag)
            cfg.check_chars = std.fmt.parseInt(usize, arg[2..], 10) catch 0;
        } else if (arg.len > 0 and arg[0] != '-') {
            if (positional == 0) {
                cfg.input_file = arg;
            } else if (positional == 1) {
                cfg.output_file = arg;
            }
            positional += 1;
        }
    }

    // Open input
    const in_fd: c_int = if (cfg.input_file) |path| blk: {
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch {
            writeStderr("zuniq: path too long\n");
            return;
        };
        const fd = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd < 0) {
            writeStderr("zuniq: cannot open input file\n");
            return;
        }
        break :blk fd;
    } else 0;
    defer {
        if (cfg.input_file != null) _ = libc.close(in_fd);
    }

    // Open output
    const out_fd: c_int = if (cfg.output_file) |path| blk: {
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch {
            writeStderr("zuniq: path too long\n");
            return;
        };
        const fd = libc.open(path_z.ptr, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
        }, @as(libc.mode_t, 0o644));
        if (fd < 0) {
            writeStderr("zuniq: cannot open output file\n");
            return;
        }
        break :blk fd;
    } else 1;
    defer {
        if (cfg.output_file != null) _ = libc.close(out_fd);
    }

    // Read entire input
    var buf: [4 * 1024 * 1024]u8 = undefined; // 4MB max
    var total: usize = 0;
    while (total < buf.len) {
        const n_raw = libc.read(in_fd, @ptrCast(&buf[total]), buf.len - total);
        if (n_raw <= 0) break;
        total += @intCast(n_raw);
    }

    const data = buf[0..total];

    // For --group and --all-repeated, we need to collect groups of lines
    const allocator = std.heap.c_allocator;

    // Collect all lines with their compare slices
    var all_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer all_lines.deinit(allocator);

    var lines_iter = std.mem.splitScalar(u8, data, '\n');
    while (lines_iter.next()) |line| {
        if (line.len == 0 and lines_iter.peek() == null) continue;
        all_lines.append(allocator, line) catch continue;
    }

    if (all_lines.items.len == 0) return;

    // Process with --group mode
    if (cfg.group) |group_method| {
        var group_start: usize = 0;
        var is_first_group = true;

        while (group_start < all_lines.items.len) {
            // Find end of current group
            var group_end = group_start + 1;
            const first_compare = getCompareSlice(all_lines.items[group_start], &cfg);
            while (group_end < all_lines.items.len) {
                const compare = getCompareSlice(all_lines.items[group_end], &cfg);
                if (!linesEqual(compare, first_compare, cfg.ignore_case)) break;
                group_end += 1;
            }

            // Output group separator before
            if (group_method == .prepend or group_method == .both) {
                writeFd(out_fd, "\n");
            } else if (group_method == .separate and !is_first_group) {
                writeFd(out_fd, "\n");
            }

            // Output all lines in group
            for (all_lines.items[group_start..group_end]) |line| {
                writeFd(out_fd, line);
                writeFd(out_fd, "\n");
            }

            // Output group separator after
            if (group_method == .append or group_method == .both) {
                writeFd(out_fd, "\n");
            }

            is_first_group = false;
            group_start = group_end;
        }
        return;
    }

    // Process with --all-repeated mode
    if (cfg.all_repeated) |all_rep_method| {
        var group_start: usize = 0;
        var is_first_group = true;

        while (group_start < all_lines.items.len) {
            // Find end of current group
            var group_end = group_start + 1;
            const first_compare = getCompareSlice(all_lines.items[group_start], &cfg);
            while (group_end < all_lines.items.len) {
                const compare = getCompareSlice(all_lines.items[group_end], &cfg);
                if (!linesEqual(compare, first_compare, cfg.ignore_case)) break;
                group_end += 1;
            }

            const group_size = group_end - group_start;

            // Only output if duplicate (more than one line)
            if (group_size > 1) {
                // Output separator
                if (all_rep_method == .prepend) {
                    writeFd(out_fd, "\n");
                } else if (all_rep_method == .separate and !is_first_group) {
                    writeFd(out_fd, "\n");
                }

                // Output all lines in group
                for (all_lines.items[group_start..group_end]) |line| {
                    writeFd(out_fd, line);
                    writeFd(out_fd, "\n");
                }

                is_first_group = false;
            }

            group_start = group_end;
        }
        return;
    }

    // Standard processing (original behavior)
    var prev_line: ?[]const u8 = null;
    var prev_compare: ?[]const u8 = null;
    var count: u64 = 0;

    for (all_lines.items) |line| {
        const compare = getCompareSlice(line, &cfg);

        if (prev_compare) |prev| {
            if (linesEqual(compare, prev, cfg.ignore_case)) {
                count += 1;
            } else {
                // Output previous line
                const is_duplicate = count > 1;
                if ((!cfg.repeated and !cfg.unique) or
                    (cfg.repeated and is_duplicate) or
                    (cfg.unique and !is_duplicate))
                {
                    outputLine(out_fd, prev_line.?, count, &cfg);
                }
                prev_line = line;
                prev_compare = compare;
                count = 1;
            }
        } else {
            prev_line = line;
            prev_compare = compare;
            count = 1;
        }
    }

    // Output last line
    if (prev_line) |line| {
        const is_duplicate = count > 1;
        if ((!cfg.repeated and !cfg.unique) or
            (cfg.repeated and is_duplicate) or
            (cfg.unique and !is_duplicate))
        {
            outputLine(out_fd, line, count, &cfg);
        }
    }
}
