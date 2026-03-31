const std = @import("std");
const posix = std.posix;
const libc = std.c;
const linux = std.os.linux;

const OutputBuffer = struct {
    buf: [8192]u8 = undefined,
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
            _ = libc.write(libc.STDOUT_FILENO, &self.buf, self.pos);
            self.pos = 0;
        }
    }
};

const IndexEntry = struct {
    keyword: []const u8,
    keyword_lower: []const u8,
    left_context: []const u8,
    right_context: []const u8,
    line: []const u8,
};

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_' or c == '\'';
}

fn toLowerStr(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    const result = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        result[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return result;
}

fn isIgnored(word_lower: []const u8, ignore_words: []const []const u8) bool {
    for (ignore_words) |ignore| {
        if (std.mem.eql(u8, word_lower, ignore)) return true;
    }
    return false;
}

fn extractWords(line: []const u8, allocator: std.mem.Allocator, entries: *std.ArrayListUnmanaged(IndexEntry), ignore_words: []const []const u8, fold_case: bool) !void {
    var i: usize = 0;
    while (i < line.len) {
        // Skip non-word chars
        while (i < line.len and !isWordChar(line[i])) : (i += 1) {}
        if (i >= line.len) break;

        const word_start = i;
        while (i < line.len and isWordChar(line[i])) : (i += 1) {}
        const word_end = i;

        const word = line[word_start..word_end];
        const word_lower = try toLowerStr(allocator, word);

        // Check ignore list
        if (isIgnored(word_lower, ignore_words)) {
            allocator.free(word_lower);
            continue;
        }

        const left = line[0..word_start];
        const right = if (word_end < line.len) line[word_end..] else "";

        try entries.append(allocator, .{
            .keyword = try allocator.dupe(u8, word),
            .keyword_lower = if (fold_case) word_lower else try toLowerStr(allocator, word),
            .left_context = try allocator.dupe(u8, left),
            .right_context = try allocator.dupe(u8, right),
            .line = try allocator.dupe(u8, line),
        });

        if (!fold_case) allocator.free(word_lower);
    }
}

fn compareEntries(ctx: void, a: IndexEntry, b: IndexEntry) bool {
    _ = ctx;
    return std.mem.lessThan(u8, a.keyword_lower, b.keyword_lower);
}

fn formatOutput(entries: []IndexEntry, out: *OutputBuffer, width: usize, gap: usize, flag_trunc: []const u8) void {
    const half = (width - gap) / 2;
    const left_width = half;
    const right_width = width - half - gap;

    for (entries) |entry| {
        // Format left context (right-aligned, may truncate from left)
        var left_buf: [256]u8 = undefined;
        var left_len: usize = 0;

        var left = entry.left_context;
        // Trim trailing whitespace from left context
        while (left.len > 0 and (left[left.len - 1] == ' ' or left[left.len - 1] == '\t')) {
            left = left[0 .. left.len - 1];
        }

        var left_truncated = false;
        if (left.len > left_width) {
            left = left[left.len - left_width ..];
            left_truncated = true;
        }

        // Right-align with padding
        const pad_left = left_width - left.len;
        for (0..pad_left) |_| {
            left_buf[left_len] = ' ';
            left_len += 1;
        }
        @memcpy(left_buf[left_len .. left_len + left.len], left);
        left_len += left.len;

        // Format right context (keyword + right, left-aligned, may truncate from right)
        var right_buf: [256]u8 = undefined;
        var right_len: usize = 0;

        // Start with keyword
        const kw = entry.keyword;
        @memcpy(right_buf[right_len .. right_len + kw.len], kw);
        right_len += kw.len;

        // Add right context
        var right = entry.right_context;
        // Trim leading whitespace
        while (right.len > 0 and (right[0] == ' ' or right[0] == '\t')) {
            right = right[1..];
        }

        const space_for_right = if (right_width > right_len) right_width - right_len else 0;
        var right_truncated = false;

        if (right.len > 0) {
            right_buf[right_len] = ' ';
            right_len += 1;

            const copy_len = @min(right.len, space_for_right -| 1);
            if (copy_len > 0) {
                @memcpy(right_buf[right_len .. right_len + copy_len], right[0..copy_len]);
                right_len += copy_len;
            }
            if (right.len > space_for_right -| 1) right_truncated = true;
        }

        // Pad right side
        while (right_len < right_width) {
            right_buf[right_len] = ' ';
            right_len += 1;
        }

        // Output
        out.write(left_buf[0..left_len]);

        // Gap
        for (0..gap) |_| out.writeByte(' ');

        out.write(right_buf[0..right_len]);

        // Truncation flag
        if (right_truncated and flag_trunc.len > 0) {
            out.write(flag_trunc);
        }

        // Show left truncation in traditional spot
        if (left_truncated and flag_trunc.len > 0) {
            // Already shown by context
        }

        out.writeByte('\n');
    }
}

fn readFile(path: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const fd = linux.open(@ptrCast(&path_buf), .{}, 0);
    if (@as(isize, @bitCast(fd)) < 0) return error.OpenFailed;
    defer _ = linux.close(@intCast(fd));

    var content = std.ArrayListUnmanaged(u8).empty;
    var buf: [4096]u8 = undefined;

    while (true) {
        const n = linux.read(@intCast(fd), &buf, buf.len);
        if (@as(isize, @bitCast(n)) <= 0) break;
        try content.appendSlice(allocator, buf[0..n]);
    }

    return content.toOwnedSlice(allocator);
}

fn readStdin(allocator: std.mem.Allocator) ![]const u8 {
    var content = std.ArrayListUnmanaged(u8).empty;
    var buf: [4096]u8 = undefined;

    while (true) {
        const n = linux.read(posix.STDIN_FILENO, &buf, buf.len);
        if (@as(isize, @bitCast(n)) <= 0) break;
        try content.appendSlice(allocator, buf[0..n]);
    }

    return content.toOwnedSlice(allocator);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();

    var width: usize = 72;
    var gap: usize = 3;
    var fold_case = false;
    var flag_trunc: []const u8 = "/";
    var ignore_file: ?[]const u8 = null;
    var files = std.ArrayListUnmanaged([]const u8).empty;
    defer files.deinit(allocator);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            const help =
                \\Usage: zptx [OPTION]... [INPUT]...
                \\Output a permuted index, including context, of the words in the input files.
                \\
                \\  -f, --ignore-case     fold lower case to upper case for sorting
                \\  -g, --gap-size=NUM    gap size in columns between output fields
                \\  -i, --ignore-file=FILE read ignore word list from FILE
                \\  -w, --width=NUM       output width in columns
                \\  -F, --flag-truncation=STR  string for flagging truncation (default '/')
                \\      --help            display this help and exit
                \\
            ;
            _ = libc.write(libc.STDOUT_FILENO, help.ptr, help.len);
            return;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--ignore-case")) {
            fold_case = true;
        } else if (std.mem.startsWith(u8, arg, "-w")) {
            const val = if (arg.len > 2) arg[2..] else args.next() orelse continue;
            width = std.fmt.parseInt(usize, val, 10) catch 72;
        } else if (std.mem.startsWith(u8, arg, "--width=")) {
            width = std.fmt.parseInt(usize, arg[8..], 10) catch 72;
        } else if (std.mem.startsWith(u8, arg, "-g")) {
            const val = if (arg.len > 2) arg[2..] else args.next() orelse continue;
            gap = std.fmt.parseInt(usize, val, 10) catch 3;
        } else if (std.mem.startsWith(u8, arg, "--gap-size=")) {
            gap = std.fmt.parseInt(usize, arg[11..], 10) catch 3;
        } else if (std.mem.startsWith(u8, arg, "-F")) {
            flag_trunc = if (arg.len > 2) arg[2..] else args.next() orelse "/";
        } else if (std.mem.startsWith(u8, arg, "--flag-truncation=")) {
            flag_trunc = arg[18..];
        } else if (std.mem.startsWith(u8, arg, "-i")) {
            ignore_file = if (arg.len > 2) arg[2..] else args.next();
        } else if (std.mem.startsWith(u8, arg, "--ignore-file=")) {
            ignore_file = arg[14..];
        } else if (arg.len > 0 and arg[0] != '-') {
            try files.append(allocator, arg);
        }
    }

    // Load ignore words
    var ignore_words = std.ArrayListUnmanaged([]const u8).empty;
    defer ignore_words.deinit(allocator);

    if (ignore_file) |path| {
        const content = readFile(path, allocator) catch "";
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len > 0) {
                const lower = try toLowerStr(allocator, trimmed);
                try ignore_words.append(allocator, lower);
            }
        }
    }

    // Read input
    var all_content = std.ArrayListUnmanaged(u8).empty;
    defer all_content.deinit(allocator);

    if (files.items.len == 0) {
        const content = try readStdin(allocator);
        try all_content.appendSlice(allocator, content);
    } else {
        for (files.items) |path| {
            if (std.mem.eql(u8, path, "-")) {
                const content = try readStdin(allocator);
                try all_content.appendSlice(allocator, content);
            } else {
                const content = readFile(path, allocator) catch continue;
                try all_content.appendSlice(allocator, content);
            }
        }
    }

    // Process lines and extract index entries
    var entries = std.ArrayListUnmanaged(IndexEntry).empty;
    defer entries.deinit(allocator);

    var lines = std.mem.splitScalar(u8, all_content.items, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try extractWords(line, allocator, &entries, ignore_words.items, fold_case);
    }

    // Sort entries by keyword
    std.mem.sort(IndexEntry, entries.items, {}, compareEntries);

    // Output
    var out = OutputBuffer{};
    formatOutput(entries.items, &out, width, gap, flag_trunc);
    out.flush();
}
