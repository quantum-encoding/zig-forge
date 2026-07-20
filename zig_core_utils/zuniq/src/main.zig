//! zuniq - Report or omit repeated lines
//!
//! High-performance uniq implementation in Zig.

const std = @import("std");
const libc = std.c;

const VERSION = "1.0.0";

extern "c" fn strerror(errnum: c_int) [*:0]const u8;

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
    delimiter: u8 = '\n',
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

/// Emit a diagnostic to stderr and terminate with GNU's failure status (1).
fn fatal(parts: []const []const u8) noreturn {
    writeStderr("zuniq: ");
    for (parts) |p| writeStderr(p);
    writeStderr("\n");
    std.process.exit(1);
}

fn printUsage(fd: c_int) void {
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
        \\  -z, --zero-terminated Line delimiter is NUL, not newline
        \\      --group[=METHOD]  Show all items, separate groups
        \\                        METHOD: prepend, append, separate (default), both
        \\      --help            Display this help and exit
        \\      --version         Output version information and exit
        \\
        \\A field is a run of blanks followed by non-blank characters.
        \\
    ;
    writeFd(fd, usage);
}

fn printVersion(fd: c_int) void {
    writeFd(fd, "zuniq " ++ VERSION ++ "\n");
}

/// Parse an unsigned decimal argument for -f/-s/-w, exiting like GNU on garbage.
fn parseCount(value: []const u8, kind: []const u8) usize {
    return std.fmt.parseInt(usize, value, 10) catch {
        fatal(&.{ value, ": invalid number of ", kind });
    };
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
    writeFd(out_fd, &[_]u8{cfg.delimiter});
}

pub fn main(init: std.process.Init) !void {
    var cfg = Config{};

    // Parse arguments
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip program name
    var positional: usize = 0;
    var end_of_opts = false;

    while (args_iter.next()) |arg| {
        if (!end_of_opts and std.mem.eql(u8, arg, "--")) {
            end_of_opts = true;
            continue;
        }

        // Long options
        if (!end_of_opts and arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            if (std.mem.eql(u8, arg, "--help")) {
                printUsage(libc.STDOUT_FILENO);
                return;
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion(libc.STDOUT_FILENO);
                return;
            } else if (std.mem.eql(u8, arg, "--count")) {
                cfg.count = true;
            } else if (std.mem.eql(u8, arg, "--repeated")) {
                cfg.repeated = true;
            } else if (std.mem.eql(u8, arg, "--unique")) {
                cfg.unique = true;
            } else if (std.mem.eql(u8, arg, "--ignore-case")) {
                cfg.ignore_case = true;
            } else if (std.mem.eql(u8, arg, "--zero-terminated")) {
                cfg.delimiter = 0;
            } else if (std.mem.eql(u8, arg, "--all-repeated")) {
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
                    fatal(&.{ "invalid argument '", method, "' for '--all-repeated'" });
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
                    fatal(&.{ "invalid argument '", method, "' for '--group'" });
                }
            } else if (std.mem.eql(u8, arg, "--skip-fields")) {
                const v = args_iter.next() orelse fatal(&.{"option '--skip-fields' requires an argument"});
                cfg.skip_fields = parseCount(v, "fields to skip");
            } else if (std.mem.startsWith(u8, arg, "--skip-fields=")) {
                cfg.skip_fields = parseCount(arg[14..], "fields to skip");
            } else if (std.mem.eql(u8, arg, "--skip-chars")) {
                const v = args_iter.next() orelse fatal(&.{"option '--skip-chars' requires an argument"});
                cfg.skip_chars = parseCount(v, "bytes to skip");
            } else if (std.mem.startsWith(u8, arg, "--skip-chars=")) {
                cfg.skip_chars = parseCount(arg[13..], "bytes to skip");
            } else if (std.mem.eql(u8, arg, "--check-chars")) {
                const v = args_iter.next() orelse fatal(&.{"option '--check-chars' requires an argument"});
                cfg.check_chars = parseCount(v, "bytes to compare");
            } else if (std.mem.startsWith(u8, arg, "--check-chars=")) {
                cfg.check_chars = parseCount(arg[14..], "bytes to compare");
            } else {
                fatal(&.{ "unrecognized option '", arg, "'" });
            }
            continue;
        }

        // Short option clusters (e.g. -c, -dc, -f1, -cf 1)
        if (!end_of_opts and arg.len >= 2 and arg[0] == '-') {
            var i: usize = 1;
            while (i < arg.len) : (i += 1) {
                const ch = arg[i];
                switch (ch) {
                    'c' => cfg.count = true,
                    'd' => cfg.repeated = true,
                    'u' => cfg.unique = true,
                    'i' => cfg.ignore_case = true,
                    'D' => cfg.all_repeated = .none,
                    'z' => cfg.delimiter = 0,
                    'f', 's', 'w' => {
                        // Value is the rest of this token, or the next argument.
                        const rest = arg[i + 1 ..];
                        const kind: []const u8 = switch (ch) {
                            'f' => "fields to skip",
                            's' => "bytes to skip",
                            else => "bytes to compare",
                        };
                        const value = if (rest.len > 0)
                            rest
                        else
                            (args_iter.next() orelse fatal(&.{ "option requires an argument -- '", arg[i .. i + 1], "'" }));
                        const n = parseCount(value, kind);
                        switch (ch) {
                            'f' => cfg.skip_fields = n,
                            's' => cfg.skip_chars = n,
                            else => cfg.check_chars = n,
                        }
                        i = arg.len; // consumed the remainder of the token
                        break;
                    },
                    else => fatal(&.{ "invalid option -- '", arg[i .. i + 1], "'" }),
                }
            }
            continue;
        }

        // Positional argument ("-" means stdin/stdout).
        if (positional == 0) {
            if (!std.mem.eql(u8, arg, "-")) cfg.input_file = arg;
        } else if (positional == 1) {
            if (!std.mem.eql(u8, arg, "-")) cfg.output_file = arg;
        } else {
            fatal(&.{ "extra operand '", arg, "'" });
        }
        positional += 1;
    }

    // Reject mutually-exclusive combinations, matching GNU's diagnostics.
    if (cfg.all_repeated != null and cfg.count) {
        fatal(&.{"printing all duplicated lines and repeat counts is meaningless"});
    }
    if (cfg.group != null and (cfg.count or cfg.repeated or cfg.unique or cfg.all_repeated != null)) {
        fatal(&.{"--group is mutually exclusive with -c/-d/-D/-u"});
    }

    const allocator = std.heap.c_allocator;

    // Open input
    const in_fd: c_int = if (cfg.input_file) |path| blk: {
        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch {
            fatal(&.{ path, ": File name too long" });
        };
        const fd = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd < 0) {
            fatal(&.{ path, ": ", errnoString() });
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
            fatal(&.{ path, ": File name too long" });
        };
        const fd = libc.open(path_z.ptr, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .TRUNC = true,
        }, @as(libc.mode_t, 0o644));
        if (fd < 0) {
            fatal(&.{ path, ": ", errnoString() });
        }
        break :blk fd;
    } else 1;
    defer {
        if (cfg.output_file != null) _ = libc.close(out_fd);
    }

    // Read the entire input into a growable heap buffer (no fixed cap).
    var contents: std.ArrayListUnmanaged(u8) = .empty;
    defer contents.deinit(allocator);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n_raw = libc.read(in_fd, @ptrCast(&chunk), chunk.len);
        if (n_raw < 0) {
            fatal(&.{ "read error: ", errnoString() });
        }
        if (n_raw == 0) break;
        contents.appendSlice(allocator, chunk[0..@intCast(n_raw)]) catch {
            fatal(&.{"memory exhausted"});
        };
    }

    const data = contents.items;

    // Collect all lines with their compare slices
    var all_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer all_lines.deinit(allocator);

    var lines_iter = std.mem.splitScalar(u8, data, cfg.delimiter);
    while (lines_iter.next()) |line| {
        if (line.len == 0 and lines_iter.peek() == null) continue;
        all_lines.append(allocator, line) catch continue;
    }

    if (all_lines.items.len == 0) return;

    const term = [_]u8{cfg.delimiter};

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

            // Output group separator before.
            // prepend/both: before every group. separate: between groups only.
            if (group_method == .prepend or group_method == .both) {
                writeFd(out_fd, &term);
            } else if (group_method == .separate and !is_first_group) {
                writeFd(out_fd, &term);
            }

            // Output all lines in group
            for (all_lines.items[group_start..group_end]) |line| {
                writeFd(out_fd, line);
                writeFd(out_fd, &term);
            }

            // Output group separator after (append: after every group).
            if (group_method == .append) {
                writeFd(out_fd, &term);
            }

            is_first_group = false;
            group_start = group_end;
        }

        // `both` emits a single trailing separator after the final group
        // (matching GNU: a delimiter before every group plus one at the end).
        if (group_method == .both) {
            writeFd(out_fd, &term);
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
                    writeFd(out_fd, &term);
                } else if (all_rep_method == .separate and !is_first_group) {
                    writeFd(out_fd, &term);
                }

                // Output all lines in group
                for (all_lines.items[group_start..group_end]) |line| {
                    writeFd(out_fd, line);
                    writeFd(out_fd, &term);
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
                if ((!cfg.repeated or is_duplicate) and (!cfg.unique or !is_duplicate)) {
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
        if ((!cfg.repeated or is_duplicate) and (!cfg.unique or !is_duplicate)) {
            outputLine(out_fd, line, count, &cfg);
        }
    }
}

/// Human-readable message for the current C errno.
fn errnoString() []const u8 {
    const e = libc._errno().*;
    const ptr = strerror(e);
    return std.mem.sliceTo(ptr, 0);
}
