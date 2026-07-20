const std = @import("std");
const libc = std.c;

const Pattern = struct {
    kind: enum { line_number, regex, skip_regex, repeat },
    value: union {
        line_num: usize,
        regex: struct { pattern: []const u8, offset: i32 },
        repeat_count: ?usize, // null means infinite
    },
    arg: []const u8 = "", // original CLI token, for GNU-style diagnostics
};

const OutputBuffer = struct {
    buf: [4096]u8 = undefined,
    pos: usize = 0,

    fn write(self: *OutputBuffer, data: []const u8) void {
        for (data) |c| self.writeByte(c);
    }

    fn writeByte(self: *OutputBuffer, c: u8) void {
        self.buf[self.pos] = c;
        self.pos += 1;
        if (self.pos == self.buf.len) self.flush();
    }

    fn flush(self: *OutputBuffer) void {
        if (self.pos > 0) {
            writeAll(libc.STDOUT_FILENO, self.buf[0..self.pos]) catch {};
            self.pos = 0;
        }
    }

    fn print(self: *OutputBuffer, comptime fmt: []const u8, args: anytype) void {
        var tmp: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, fmt, args) catch return;
        self.write(s);
    }
};

fn simpleMatch(line: []const u8, pattern: []const u8) bool {
    // Simple substring match (not full regex)
    if (pattern.len == 0) return true;
    if (pattern.len > line.len) return false;

    // Check for anchors
    var pat = pattern;
    var must_start = false;
    var must_end = false;

    if (pat.len > 0 and pat[0] == '^') {
        must_start = true;
        pat = pat[1..];
    }
    if (pat.len > 0 and pat[pat.len - 1] == '$') {
        must_end = true;
        pat = pat[0 .. pat.len - 1];
    }

    if (must_start and must_end) {
        return std.mem.eql(u8, line, pat);
    } else if (must_start) {
        return std.mem.startsWith(u8, line, pat);
    } else if (must_end) {
        return std.mem.endsWith(u8, line, pat);
    } else {
        return std.mem.indexOf(u8, line, pat) != null;
    }
}

// Write the whole slice, retrying on short writes; error on failure. Fixes
// silent truncation / wrong byte counts on ENOSPC or interrupted writes.
fn writeAll(fd: c_int, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const n = libc.write(fd, data.ptr + off, data.len - off);
        if (n < 0) return error.WriteFailed;
        if (n == 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

// Build the sentinel-terminated output filename on the heap. No fixed buffer,
// so large -n/--digits values or long -f/--prefix strings cannot overflow.
fn makeFilename(allocator: std.mem.Allocator, prefix: []const u8, file_num: usize, digits: usize) ![:0]u8 {
    var num_buf: [20]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{file_num}) catch "0";
    const width = @max(digits, num_str.len);
    const name = try allocator.allocSentinel(u8, prefix.len + width, 0);
    @memcpy(name[0..prefix.len], prefix);
    const pad = width - num_str.len;
    for (0..pad) |i| name[prefix.len + i] = '0';
    @memcpy(name[prefix.len + pad ..][0..num_str.len], num_str);
    return name;
}

fn writeFile(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    file_num: usize,
    digits: usize,
    lines: []const []const u8,
    silent: bool,
    out: *OutputBuffer,
    created: *std.ArrayListUnmanaged([:0]u8),
) !usize {
    const name = try makeFilename(allocator, prefix, file_num, digits);
    try created.append(allocator, name);

    // Open file for writing. On failure the caller (writeOrFail) reports and
    // aborts; the just-appended name stays in `created` so it gets cleaned up.
    const fd = libc.open(name.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(libc.mode_t, 0o644));
    if (fd < 0) return error.OpenFailed;
    defer _ = libc.close(fd);

    var total_bytes: usize = 0;
    for (lines) |line| {
        try writeAll(fd, line);
        try writeAll(fd, "\n");
        total_bytes += line.len + 1;
    }

    if (!silent) {
        out.print("{d}\n", .{total_bytes});
    }

    return total_bytes;
}

fn readFile(path: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const is_stdin = std.mem.eql(u8, path, "-");

    var fd: c_int = undefined;
    if (is_stdin) {
        fd = libc.STDIN_FILENO;
    } else {
        var path_buf: [4096]u8 = undefined;
        if (path.len >= path_buf.len) return error.NameTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&path_buf);

        fd = libc.open(path_z, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd < 0) return error.OpenFailed;
    }
    defer if (!is_stdin) {
        _ = libc.close(fd);
    };

    var content = std.ArrayListUnmanaged(u8).empty;
    var buf: [4096]u8 = undefined;

    while (true) {
        const n = libc.read(fd, &buf, buf.len);
        if (n <= 0) break;
        try content.appendSlice(allocator, buf[0..@intCast(n)]);
    }

    return content.toOwnedSlice(allocator);
}

fn parsePattern(arg: []const u8) ?Pattern {
    if (arg.len == 0) return null;

    // {N} or {*} repeat pattern
    if (arg[0] == '{' and arg[arg.len - 1] == '}') {
        const inner = arg[1 .. arg.len - 1];
        if (std.mem.eql(u8, inner, "*")) {
            return Pattern{ .kind = .repeat, .value = .{ .repeat_count = null }, .arg = arg };
        }
        if (std.fmt.parseInt(usize, inner, 10)) |n| {
            return Pattern{ .kind = .repeat, .value = .{ .repeat_count = n }, .arg = arg };
        } else |_| {}
        return null;
    }

    // /REGEXP/[OFFSET] - split at match
    if (arg[0] == '/') {
        if (std.mem.lastIndexOf(u8, arg[1..], "/")) |end| {
            const pattern = arg[1 .. end + 1];
            var offset: i32 = 0;
            if (end + 2 < arg.len) {
                const offset_str = arg[end + 2 ..];
                offset = std.fmt.parseInt(i32, offset_str, 10) catch 0;
            }
            return Pattern{ .kind = .regex, .value = .{ .regex = .{ .pattern = pattern, .offset = offset } }, .arg = arg };
        }
    }

    // %REGEXP%[OFFSET] - skip to match
    if (arg[0] == '%') {
        if (std.mem.lastIndexOf(u8, arg[1..], "%")) |end| {
            const pattern = arg[1 .. end + 1];
            var offset: i32 = 0;
            if (end + 2 < arg.len) {
                const offset_str = arg[end + 2 ..];
                offset = std.fmt.parseInt(i32, offset_str, 10) catch 0;
            }
            return Pattern{ .kind = .skip_regex, .value = .{ .regex = .{ .pattern = pattern, .offset = offset } }, .arg = arg };
        }
    }

    // Line number
    if (std.fmt.parseInt(usize, arg, 10)) |n| {
        return Pattern{ .kind = .line_number, .value = .{ .line_num = n }, .arg = arg };
    } else |_| {}

    return null;
}

// Remove output files created so far (GNU deletes them on error unless -k).
fn cleanup(created: []const [:0]u8, keep: bool) void {
    if (keep) return;
    for (created) |name| _ = libc.unlink(name.ptr);
}

// Emit a GNU-style diagnostic naming the offending argument, delete created
// output files, and exit 1 — matching `csplit` on match-not-found / range errors.
fn fail(created: []const [:0]u8, keep: bool, arg: []const u8, reason: []const u8) noreturn {
    cleanup(created, keep);
    var b: [1024]u8 = undefined;
    const m = std.fmt.bufPrint(&b, "zcsplit: '{s}': {s}\n", .{ arg, reason }) catch "zcsplit: error\n";
    _ = libc.write(libc.STDERR_FILENO, m.ptr, m.len);
    std.process.exit(1);
}

// writeFile wrapper: a write/open failure (e.g. ENOSPC) aborts with exit 1 and
// deletes partial output, instead of silently truncating with a wrong byte count.
fn writeOrFail(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    file_num: usize,
    digits: usize,
    lines: []const []const u8,
    silent: bool,
    out: *OutputBuffer,
    created: *std.ArrayListUnmanaged([:0]u8),
    keep_files: bool,
) void {
    _ = writeFile(allocator, prefix, file_num, digits, lines, silent, out, created) catch {
        out.flush();
        cleanup(created.items, keep_files);
        const msg = "zcsplit: cannot create output file\n";
        _ = libc.write(libc.STDERR_FILENO, msg.ptr, msg.len);
        std.process.exit(1);
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();

    var prefix: []const u8 = "xx";
    var digits: usize = 2;
    var silent = false;
    var elide_empty = false;
    var keep_files = false;
    var input_file: ?[]const u8 = null;
    var patterns = std.ArrayListUnmanaged(Pattern).empty;
    defer patterns.deinit(allocator);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            const help =
                \\Usage: zcsplit [OPTION]... FILE PATTERN...
                \\Output pieces of FILE separated by PATTERN(s) to files 'xx00', 'xx01', ...
                \\
                \\  -f, --prefix=PREFIX   use PREFIX instead of 'xx'
                \\  -k, --keep-files      do not remove output files on errors
                \\  -n, --digits=DIGITS   use specified number of digits instead of 2
                \\  -s, --quiet, --silent do not print counts of output file sizes
                \\  -z, --elide-empty-files suppress empty output files
                \\      --help            display this help and exit
                \\      --version         output version information and exit
                \\
                \\Each PATTERN may be:
                \\  INTEGER            copy up to but not including specified line number
                \\  /REGEXP/[OFFSET]   copy up to but not including a matching line
                \\  %REGEXP%[OFFSET]   skip to, but not including a matching line
                \\  {INTEGER}          repeat the previous pattern specified number of times
                \\  {*}                repeat the previous pattern as many times as possible
                \\
                \\Note: REGEXP is matched as a literal substring with optional ^/$
                \\anchors, NOT as a POSIX basic regular expression (unlike GNU csplit).
                \\
            ;
            _ = libc.write(libc.STDOUT_FILENO, help.ptr, help.len);
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            const ver = "zcsplit (zig_core_utils) csplit-compatible\n";
            _ = libc.write(libc.STDOUT_FILENO, ver.ptr, ver.len);
            return;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "--silent")) {
            silent = true;
        } else if (std.mem.eql(u8, arg, "-z") or std.mem.eql(u8, arg, "--elide-empty-files")) {
            elide_empty = true;
        } else if (std.mem.eql(u8, arg, "-k") or std.mem.eql(u8, arg, "--keep-files")) {
            keep_files = true;
        } else if (std.mem.startsWith(u8, arg, "-f")) {
            prefix = if (arg.len > 2) arg[2..] else args.next() orelse "xx";
        } else if (std.mem.startsWith(u8, arg, "--prefix=")) {
            prefix = arg[9..];
        } else if (std.mem.startsWith(u8, arg, "-n")) {
            const val = if (arg.len > 2) arg[2..] else args.next() orelse "2";
            digits = std.fmt.parseInt(usize, val, 10) catch 2;
        } else if (std.mem.startsWith(u8, arg, "--digits=")) {
            digits = std.fmt.parseInt(usize, arg[9..], 10) catch 2;
        } else if (input_file == null and (arg.len == 0 or arg[0] != '-' or std.mem.eql(u8, arg, "-"))) {
            input_file = arg;
        } else if (parsePattern(arg)) |pat| {
            // GNU rejects a zero line number up front, before any output.
            if (pat.kind == .line_number and pat.value.line_num == 0) {
                fail(&.{}, keep_files, arg, "line number must be greater than zero");
            }
            try patterns.append(allocator, pat);
        } else {
            // GNU names the specific offending argument instead of silently dropping it.
            fail(&.{}, keep_files, arg, "invalid pattern");
        }
    }

    if (input_file == null) {
        _ = libc.write(libc.STDERR_FILENO, "zcsplit: missing operand\n", 25);
        std.process.exit(1);
    }

    if (patterns.items.len == 0) {
        _ = libc.write(libc.STDERR_FILENO, "zcsplit: missing pattern\n", 25);
        std.process.exit(1);
    }

    // Read input file
    const content = readFile(input_file.?, allocator) catch {
        _ = libc.write(libc.STDERR_FILENO, "zcsplit: cannot open input file\n", 33);
        std.process.exit(1);
    };
    // The `lines` slices point into `content`; free after the split loop.
    defer allocator.free(content);

    // Split into lines
    var lines = std.ArrayListUnmanaged([]const u8).empty;
    defer lines.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        // Don't add trailing empty line
        if (line.len > 0 or line_iter.peek() != null) {
            try lines.append(allocator, line);
        }
    }

    var out = OutputBuffer{};
    var file_num: usize = 0;
    var current_line: usize = 0;
    var pattern_idx: usize = 0;

    // Output filenames created so far, deleted on error unless -k/--keep-files.
    var created = std.ArrayListUnmanaged([:0]u8).empty;
    defer {
        for (created.items) |name| allocator.free(name);
        created.deinit(allocator);
    }

    while (pattern_idx < patterns.items.len and current_line < lines.items.len) {
        const pat = patterns.items[pattern_idx];
        var split_line: usize = lines.items.len;

        switch (pat.kind) {
            .line_number => {
                // GNU: a line number past EOF is an error (exit 1), not a whole-file dump.
                if (pat.value.line_num > lines.items.len) {
                    out.flush();
                    fail(created.items, keep_files, pat.arg, "line number out of range");
                }
                // Split before this line number (1-indexed)
                if (pat.value.line_num > current_line) {
                    split_line = pat.value.line_num - 1;
                }
            },
            .regex => {
                // Find matching line
                var matched = false;
                for (current_line..lines.items.len) |i| {
                    if (simpleMatch(lines.items[i], pat.value.regex.pattern)) {
                        matched = true;
                        const target: i64 = @as(i64, @intCast(i)) + pat.value.regex.offset;
                        if (target >= @as(i64, @intCast(current_line))) {
                            split_line = @intCast(target);
                        }
                        break;
                    }
                }
                // GNU: a regex that never matches is an error (exit 1), not a whole-file dump.
                if (!matched) {
                    out.flush();
                    fail(created.items, keep_files, pat.arg, "match not found");
                }
            },
            .skip_regex => {
                // Skip to matching line (don't output)
                for (current_line..lines.items.len) |i| {
                    if (simpleMatch(lines.items[i], pat.value.regex.pattern)) {
                        const target: i64 = @as(i64, @intCast(i)) + pat.value.regex.offset;
                        if (target >= @as(i64, @intCast(current_line))) {
                            current_line = @intCast(target);
                        }
                        break;
                    }
                }
                pattern_idx += 1;
                continue;
            },
            .repeat => {
                // Repeat previous pattern
                if (pattern_idx > 0) {
                    const repeat_count = pat.value.repeat_count;
                    const prev_pat = patterns.items[pattern_idx - 1];
                    var repeats: usize = 0;

                    while (repeat_count == null or repeats < repeat_count.?) {
                        var found = false;
                        var next_split: usize = lines.items.len;

                        if (prev_pat.kind == .line_number) {
                            // For line numbers, advance by same amount
                            const advance = prev_pat.value.line_num - 1;
                            if (current_line + advance < lines.items.len) {
                                next_split = current_line + advance;
                                found = true;
                            }
                        } else if (prev_pat.kind == .regex) {
                            // Search from current_line+1 to find NEXT match (skip current split point)
                            const search_start = if (current_line + 1 < lines.items.len) current_line + 1 else lines.items.len;
                            for (search_start..lines.items.len) |i| {
                                if (simpleMatch(lines.items[i], prev_pat.value.regex.pattern)) {
                                    const target: i64 = @as(i64, @intCast(i)) + prev_pat.value.regex.offset;
                                    if (target >= @as(i64, @intCast(current_line))) {
                                        next_split = @intCast(target);
                                        found = true;
                                    }
                                    break;
                                }
                            }
                        }

                        if (!found or next_split >= lines.items.len) break;
                        if (next_split <= current_line) break; // No progress, avoid infinite loop

                        if (next_split > current_line or !elide_empty) {
                            _ = writeFile(allocator, prefix, file_num, digits, lines.items[current_line..next_split], silent, &out, &created) catch {};
                            file_num += 1;
                        }
                        current_line = next_split;
                        repeats += 1;
                    }
                }
                pattern_idx += 1;
                continue;
            },
        }

        // Write output file
        if (split_line > current_line or !elide_empty) {
            const end = @min(split_line, lines.items.len);
            writeOrFail(allocator, prefix, file_num, digits, lines.items[current_line..end], silent, &out, &created, keep_files);
            file_num += 1;
        }
        current_line = split_line;
        pattern_idx += 1;
    }

    // Write remaining lines
    if (current_line < lines.items.len) {
        writeOrFail(allocator, prefix, file_num, digits, lines.items[current_line..], silent, &out, &created, keep_files);
    }

    out.flush();
}
