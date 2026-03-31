const std = @import("std");
const posix = std.posix;
const libc = std.c;
const linux = std.os.linux;
const regex = @import("regex.zig");
const simd = @import("simd.zig");

const OutputBuffer = struct {
    buf: [8192]u8 = undefined,
    pos: usize = 0,

    fn write(self: *OutputBuffer, data: []const u8) void {
        for (data) |c| {
            self.buf[self.pos] = c;
            self.pos += 1;
            if (self.pos >= self.buf.len) self.flush();
        }
    }

    fn flush(self: *OutputBuffer) void {
        if (self.pos > 0) {
            _ = libc.write(libc.STDOUT_FILENO, &self.buf, self.pos);
            self.pos = 0;
        }
    }
};

fn writeStderr(msg: []const u8) void {
    _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
}

fn printUsage() void {
    writeStderr("Usage: zregex [OPTIONS] PATTERN [FILE...]\n");
    writeStderr("Search for PATTERN in FILEs or stdin.\n\n");
    writeStderr("Options:\n");
    writeStderr("  -c, --count           print only count of matching lines\n");
    writeStderr("  -l, --files-with-matches  print only filenames with matches\n");
    writeStderr("  -L, --files-without-match print only filenames without matches\n");
    writeStderr("  -n, --line-number     print line number with output\n");
    writeStderr("  -o, --only-matching   print only the matched parts\n");
    writeStderr("  -v, --invert-match    select non-matching lines\n");
    writeStderr("  -q, --quiet           suppress all output\n");
    writeStderr("  -H, --with-filename   print filename with output\n");
    writeStderr("  -h, --no-filename     suppress filename on output\n");
    writeStderr("  --help                display this help\n");
    writeStderr("\nRegex syntax:\n");
    writeStderr("  .          any character (except newline)\n");
    writeStderr("  ^          start of line\n");
    writeStderr("  $          end of line\n");
    writeStderr("  \\b         word boundary\n");
    writeStderr("  \\B         non-word boundary\n");
    writeStderr("  *          zero or more of previous\n");
    writeStderr("  +          one or more of previous\n");
    writeStderr("  ?          zero or one of previous\n");
    writeStderr("  [abc]      character class\n");
    writeStderr("  [^abc]     negated character class\n");
    writeStderr("  [a-z]      character range\n");
    writeStderr("  \\d \\D     digit / non-digit\n");
    writeStderr("  \\w \\W     word char / non-word char\n");
    writeStderr("  \\s \\S     whitespace / non-whitespace\n");
    writeStderr("  (...)      grouping\n");
    writeStderr("  |          alternation\n");
    writeStderr("\nThis is a high-performance regex engine using Thompson NFA construction.\n");
    writeStderr("Guarantees O(n*m) worst-case - immune to ReDoS attacks.\n");
}

const Options = struct {
    count_only: bool = false,
    files_with_matches: bool = false,
    files_without_match: bool = false,
    line_number: bool = false,
    only_matching: bool = false,
    invert_match: bool = false,
    quiet: bool = false,
    with_filename: bool = false,
    no_filename: bool = false,
    pattern: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !u8 {
    const allocator = std.heap.c_allocator;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip(); // program name

    var opts = Options{};
    var files: std.ArrayListUnmanaged([:0]const u8) = .empty;
    defer files.deinit(allocator);

    // Parse arguments
    while (args.next()) |arg| {
        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--help")) {
                printUsage();
                return 0;
            } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--count")) {
                opts.count_only = true;
            } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--files-with-matches")) {
                opts.files_with_matches = true;
            } else if (std.mem.eql(u8, arg, "-L") or std.mem.eql(u8, arg, "--files-without-match")) {
                opts.files_without_match = true;
            } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--line-number")) {
                opts.line_number = true;
            } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--only-matching")) {
                opts.only_matching = true;
            } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--invert-match")) {
                opts.invert_match = true;
            } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "--silent")) {
                opts.quiet = true;
            } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--with-filename")) {
                opts.with_filename = true;
            } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--no-filename")) {
                opts.no_filename = true;
            } else {
                writeStderr("zregex: unknown option: ");
                writeStderr(arg);
                writeStderr("\n");
                return 2;
            }
        } else if (opts.pattern == null) {
            opts.pattern = arg;
        } else {
            try files.append(allocator, arg);
        }
    }

    if (opts.pattern == null) {
        writeStderr("zregex: missing pattern\n");
        printUsage();
        return 2;
    }

    // Compile regex
    var re = regex.Regex.compile(allocator, opts.pattern.?) catch |err| {
        writeStderr("zregex: invalid pattern: ");
        switch (err) {
            error.InvalidPattern => writeStderr("invalid pattern syntax"),
            error.OutOfMemory => writeStderr("out of memory"),
        }
        writeStderr("\n");
        return 2;
    };
    defer re.deinit();

    // Determine filename display
    const show_filename = if (opts.no_filename) false else if (opts.with_filename) true else files.items.len > 1;

    // Process files
    var any_match = false;

    if (files.items.len == 0) {
        // Read from stdin
        if (try processInput(allocator, &re, posix.STDIN_FILENO, null, show_filename, &opts)) {
            any_match = true;
        }
    } else {
        for (files.items) |filename| {
            // Try mmap first for better performance
            if (processFileMmap(&re, filename, show_filename, &opts)) |has_match| {
                if (has_match) {
                    any_match = true;
                    if (opts.quiet) break;
                }
            } else {
                // mmap failed, fall back to read()
                const fd_result = linux.open(filename.ptr, .{}, 0);
                if (@as(isize, @bitCast(fd_result)) < 0) {
                    if (!opts.quiet) {
                        writeStderr("zregex: ");
                        writeStderr(filename);
                        writeStderr(": No such file or directory\n");
                    }
                    continue;
                }
                const fd: posix.fd_t = @intCast(fd_result);
                defer _ = linux.close(@intCast(fd));

                if (try processInput(allocator, &re, fd, filename, show_filename, &opts)) {
                    any_match = true;
                    if (opts.quiet) break;
                }
            }
        }
    }

    return if (any_match) 0 else 1;
}

fn processInput(
    allocator: std.mem.Allocator,
    re: *const regex.Regex,
    fd: posix.fd_t,
    filename: ?[:0]const u8,
    show_filename: bool,
    opts: *const Options,
) !bool {
    var out = OutputBuffer{};
    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(allocator);

    var read_buf: [65536]u8 = undefined;
    var line_num: usize = 0;
    var match_count: usize = 0;
    var file_has_match = false;

    while (true) {
        const bytes_read = linux.read(@intCast(fd), &read_buf, read_buf.len);
        if (@as(isize, @bitCast(bytes_read)) <= 0) break;

        const data = read_buf[0..bytes_read];
        var start: usize = 0;

        for (data, 0..) |c, i| {
            if (c == '\n') {
                try line_buf.appendSlice(allocator, data[start..i]);
                const line = line_buf.items;
                line_num += 1;

                const has_match = re.isMatch(line);
                const should_output = if (opts.invert_match) !has_match else has_match;

                if (should_output) {
                    file_has_match = true;
                    match_count += 1;

                    if (opts.quiet) {
                        out.flush();
                        return true;
                    }

                    if (!opts.count_only and !opts.files_with_matches and !opts.files_without_match) {
                        if (opts.only_matching and !opts.invert_match) {
                            // Print only matched parts
                            var pos: usize = 0;
                            while (pos < line.len) {
                                if (re.findFrom(line, pos)) |m| {
                                    if (show_filename) {
                                        if (filename) |f| {
                                            out.write(f);
                                            out.write(":");
                                        }
                                    }
                                    if (opts.line_number) {
                                        var num_buf: [20]u8 = undefined;
                                        const num_str = formatInt(&num_buf, line_num);
                                        out.write(num_str);
                                        out.write(":");
                                    }
                                    out.write(m.slice(line));
                                    out.write("\n");
                                    pos = if (m.end > m.start) m.end else m.start + 1;
                                } else {
                                    break;
                                }
                            }
                        } else {
                            if (show_filename) {
                                if (filename) |f| {
                                    out.write(f);
                                    out.write(":");
                                }
                            }
                            if (opts.line_number) {
                                var num_buf: [20]u8 = undefined;
                                const num_str = formatInt(&num_buf, line_num);
                                out.write(num_str);
                                out.write(":");
                            }
                            out.write(line);
                            out.write("\n");
                        }
                    }
                }

                line_buf.clearRetainingCapacity();
                start = i + 1;
            }
        }

        if (start < data.len) {
            try line_buf.appendSlice(allocator, data[start..]);
        }
    }

    // Handle last line without newline
    if (line_buf.items.len > 0) {
        const line = line_buf.items;
        line_num += 1;

        const has_match = re.isMatch(line);
        const should_output = if (opts.invert_match) !has_match else has_match;

        if (should_output) {
            file_has_match = true;
            match_count += 1;

            if (!opts.quiet and !opts.count_only and !opts.files_with_matches and !opts.files_without_match) {
                if (show_filename) {
                    if (filename) |f| {
                        out.write(f);
                        out.write(":");
                    }
                }
                if (opts.line_number) {
                    var num_buf: [20]u8 = undefined;
                    const num_str = formatInt(&num_buf, line_num);
                    out.write(num_str);
                    out.write(":");
                }
                out.write(line);
                out.write("\n");
            }
        }
    }

    // Handle count/files modes
    if (!opts.quiet) {
        if (opts.files_with_matches and file_has_match) {
            if (filename) |f| {
                out.write(f);
                out.write("\n");
            }
        } else if (opts.files_without_match and !file_has_match) {
            if (filename) |f| {
                out.write(f);
                out.write("\n");
            }
        } else if (opts.count_only) {
            if (show_filename) {
                if (filename) |f| {
                    out.write(f);
                    out.write(":");
                }
            }
            var num_buf: [20]u8 = undefined;
            const num_str = formatInt(&num_buf, match_count);
            out.write(num_str);
            out.write("\n");
        }
    }

    out.flush();
    return file_has_match;
}

/// Process file using mmap for zero-copy I/O
/// Returns null if mmap fails (caller should fall back to read())
fn processFileMmap(
    re: *const regex.Regex,
    filename: [:0]const u8,
    show_filename: bool,
    opts: *const Options,
) ?bool {
    // Open the file
    const fd_result = linux.open(filename.ptr, .{}, 0);
    if (@as(isize, @bitCast(fd_result)) < 0) return null;
    const fd: posix.fd_t = @intCast(fd_result);
    defer _ = linux.close(@intCast(fd));

    // Get file size using statx
    var statx_buf: linux.Statx = undefined;
    const statx_result = linux.statx(
        fd,
        "",
        linux.AT.EMPTY_PATH,
        .{ .SIZE = true },
        &statx_buf,
    );
    if (@as(isize, @bitCast(statx_result)) < 0) return null;

    const file_size: usize = statx_buf.size;
    if (file_size == 0) return false; // Empty file

    // mmap the file
    const file_data = posix.mmap(
        null,
        file_size,
        .{ .READ = true },
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    ) catch return null;
    defer posix.munmap(file_data);

    // Process the memory-mapped file
    var out = OutputBuffer{};
    var line_num: usize = 0;
    var match_count: usize = 0;
    var file_has_match = false;

    // Process line by line using SIMD newline search
    var line_start: usize = 0;
    while (line_start < file_data.len) {
        // Find next newline using SIMD
        const newline_pos = simd.memchrFrom(file_data, '\n', line_start) orelse file_data.len;
        const line = file_data[line_start..newline_pos];
        line_num += 1;

        const has_match = re.isMatch(line);
        const should_output = if (opts.invert_match) !has_match else has_match;

        if (should_output) {
            file_has_match = true;
            match_count += 1;

            if (opts.quiet) {
                out.flush();
                return true;
            }

            if (!opts.count_only and !opts.files_with_matches and !opts.files_without_match) {
                if (opts.only_matching and !opts.invert_match) {
                    // Print only matched parts
                    var pos: usize = 0;
                    while (pos < line.len) {
                        if (re.findFrom(line, pos)) |m| {
                            if (show_filename) {
                                out.write(filename);
                                out.write(":");
                            }
                            if (opts.line_number) {
                                var num_buf: [20]u8 = undefined;
                                const num_str = formatInt(&num_buf, line_num);
                                out.write(num_str);
                                out.write(":");
                            }
                            out.write(m.slice(line));
                            out.write("\n");
                            pos = if (m.end > m.start) m.end else m.start + 1;
                        } else {
                            break;
                        }
                    }
                } else {
                    if (show_filename) {
                        out.write(filename);
                        out.write(":");
                    }
                    if (opts.line_number) {
                        var num_buf: [20]u8 = undefined;
                        const num_str = formatInt(&num_buf, line_num);
                        out.write(num_str);
                        out.write(":");
                    }
                    out.write(line);
                    out.write("\n");
                }
            }
        }

        line_start = newline_pos + 1;
    }

    // Handle output modes
    if (!opts.quiet) {
        if (opts.files_with_matches and file_has_match) {
            out.write(filename);
            out.write("\n");
        } else if (opts.files_without_match and !file_has_match) {
            out.write(filename);
            out.write("\n");
        } else if (opts.count_only) {
            if (show_filename) {
                out.write(filename);
                out.write(":");
            }
            var num_buf: [20]u8 = undefined;
            const num_str = formatInt(&num_buf, match_count);
            out.write(num_str);
            out.write("\n");
        }
    }

    out.flush();
    return file_has_match;
}

fn formatInt(buf: []u8, value: usize) []const u8 {
    var v = value;
    var i: usize = buf.len;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
    } else {
        while (v > 0) {
            i -= 1;
            buf[i] = @intCast('0' + (v % 10));
            v /= 10;
        }
    }
    return buf[i..];
}
