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

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn isSentenceEnd(c: u8) bool {
    return c == '.' or c == '!' or c == '?';
}

fn getIndent(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and isSpace(line[i])) : (i += 1) {}
    return i;
}

fn formatParagraph(
    lines: []const []const u8,
    out: *OutputBuffer,
    width: usize,
    goal: usize,
    split_only: bool,
    uniform: bool,
    prefix: ?[]const u8,
    crown_margin: bool,
    tagged_paragraph: bool,
) void {
    if (lines.len == 0) return;

    // Get the indentation from first line
    const first_indent = getIndent(lines[0]);
    var indent_str: [256]u8 = undefined;
    if (first_indent > 0 and first_indent < indent_str.len) {
        @memcpy(indent_str[0..first_indent], lines[0][0..first_indent]);
    }

    // Determine continuation indent for crown/tagged modes
    var cont_indent: usize = first_indent;
    var cont_indent_str: [256]u8 = undefined;
    if ((crown_margin or tagged_paragraph) and lines.len >= 2) {
        const second_indent = getIndent(lines[1]);
        if (tagged_paragraph and second_indent == first_indent) {
            // Tagged paragraph requires different indents; if same, treat as normal
            // (output as-is basically)
        } else {
            cont_indent = second_indent;
        }
        if (cont_indent > 0 and cont_indent < cont_indent_str.len) {
            @memcpy(cont_indent_str[0..cont_indent], lines[1][0..cont_indent]);
        }
    }

    // Collect all words from the paragraph
    var words: [4096][]const u8 = undefined;
    var word_count: usize = 0;
    var after_sentence: [4096]bool = undefined;

    for (lines) |line| {
        var text = line;

        // Strip prefix if present
        if (prefix) |p| {
            if (std.mem.startsWith(u8, text, p)) {
                text = text[p.len..];
            }
        }

        // Skip leading whitespace
        var i: usize = 0;
        while (i < text.len and isSpace(text[i])) : (i += 1) {}

        while (i < text.len) {
            // Skip spaces
            while (i < text.len and isSpace(text[i])) : (i += 1) {}
            if (i >= text.len) break;

            // Find word end
            const word_start = i;
            while (i < text.len and !isSpace(text[i])) : (i += 1) {}

            if (word_count < words.len) {
                words[word_count] = text[word_start..i];
                // Check if previous word ended a sentence
                if (word_count > 0) {
                    const prev_word = words[word_count - 1];
                    after_sentence[word_count] = prev_word.len > 0 and isSentenceEnd(prev_word[prev_word.len - 1]);
                } else {
                    after_sentence[word_count] = false;
                }
                word_count += 1;
            }
        }
    }

    if (word_count == 0) return;

    // Use goal width for line-break decisions (but never exceed max width)
    const effective_goal = if (goal < width) goal else width;

    // Output words with wrapping
    var col: usize = 0;
    var first_word = true;
    var is_first_line = true;

    // Output prefix/indent for first line
    if (prefix) |p| {
        out.write(p);
        col += p.len;
    } else if (first_indent > 0) {
        out.write(indent_str[0..first_indent]);
        col += first_indent;
    }

    for (0..word_count) |wi| {
        const word = words[wi];
        const spaces_needed: usize = if (first_word) 0 else if (uniform and after_sentence[wi]) 2 else 1;

        if (split_only) {
            // Split only mode - just break long lines
            if (!first_word) {
                if (col + spaces_needed + word.len > width) {
                    out.writeByte('\n');
                    is_first_line = false;
                    if (prefix) |p| {
                        out.write(p);
                        col = p.len;
                    } else if ((crown_margin or tagged_paragraph) and cont_indent > 0) {
                        out.write(cont_indent_str[0..cont_indent]);
                        col = cont_indent;
                    } else {
                        col = 0;
                    }
                } else {
                    for (0..spaces_needed) |_| out.writeByte(' ');
                    col += spaces_needed;
                }
            }
        } else {
            // Normal mode - reflow
            // Break if adding this word would exceed goal width (or hard max)
            const should_break = !first_word and blk: {
                const new_col = col + spaces_needed + word.len;
                if (new_col > width) break :blk true;
                // Use goal-based breaking: if we're already past goal, break
                if (new_col > effective_goal) {
                    // Check if current line is closer to goal by breaking vs not breaking
                    const dist_no_break = new_col -| effective_goal;
                    const dist_break = effective_goal -| col;
                    break :blk dist_no_break > dist_break;
                }
                break :blk false;
            };

            if (should_break) {
                out.writeByte('\n');
                is_first_line = false;
                if (prefix) |p| {
                    out.write(p);
                    col = p.len;
                } else if ((crown_margin or tagged_paragraph) and !is_first_line and cont_indent > 0) {
                    out.write(cont_indent_str[0..cont_indent]);
                    col = cont_indent;
                } else {
                    col = 0;
                }
            } else if (!first_word) {
                for (0..spaces_needed) |_| out.writeByte(' ');
                col += spaces_needed;
            }
        }

        out.write(word);
        col += word.len;
        first_word = false;
    }

    out.writeByte('\n');
}

fn processInput(
    content: []const u8,
    out: *OutputBuffer,
    width: usize,
    goal: usize,
    split_only: bool,
    uniform: bool,
    prefix: ?[]const u8,
    crown_margin: bool,
    tagged_paragraph: bool,
) void {
    var para_lines: [1024][]const u8 = undefined;
    var para_count: usize = 0;

    var line_iter = std.mem.splitScalar(u8, content, '\n');

    while (line_iter.next()) |line| {
        // Check if line is empty (paragraph break)
        var is_empty = true;
        for (line) |c| {
            if (!isSpace(c)) {
                is_empty = false;
                break;
            }
        }

        // Check prefix if specified
        var matches_prefix = true;
        if (prefix) |p| {
            if (!std.mem.startsWith(u8, line, p) and !is_empty) {
                matches_prefix = false;
            }
        }

        // For tagged paragraph mode, detect indent change as paragraph break
        if (tagged_paragraph and para_count > 0 and !is_empty) {
            const cur_indent = getIndent(line);
            const first_line_indent = getIndent(para_lines[0]);
            // If this line has same indent as first line, it's a new paragraph
            if (cur_indent == first_line_indent and para_count >= 2) {
                formatParagraph(para_lines[0..para_count], out, width, goal, split_only, uniform, prefix, crown_margin, tagged_paragraph);
                para_count = 0;
            }
        }

        if (is_empty) {
            // End of paragraph
            if (para_count > 0) {
                formatParagraph(para_lines[0..para_count], out, width, goal, split_only, uniform, prefix, crown_margin, tagged_paragraph);
                para_count = 0;
            }
            out.writeByte('\n');
        } else if (!matches_prefix) {
            // Line doesn't match prefix - output as-is
            if (para_count > 0) {
                formatParagraph(para_lines[0..para_count], out, width, goal, split_only, uniform, prefix, crown_margin, tagged_paragraph);
                para_count = 0;
            }
            out.write(line);
            out.writeByte('\n');
        } else {
            // Add to current paragraph
            if (para_count < para_lines.len) {
                para_lines[para_count] = line;
                para_count += 1;
            }
        }
    }

    // Handle final paragraph
    if (para_count > 0) {
        formatParagraph(para_lines[0..para_count], out, width, goal, split_only, uniform, prefix, crown_margin, tagged_paragraph);
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

    var width: usize = 75;
    var goal: usize = 0; // 0 means use default (93% of width)
    var goal_explicitly_set = false;
    var split_only = false;
    var uniform = false;
    var crown_margin = false;
    var tagged_paragraph = false;
    var prefix: ?[]const u8 = null;
    var files = std.ArrayListUnmanaged([]const u8).empty;
    defer files.deinit(allocator);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            const help =
                \\Usage: zfmt [-WIDTH] [OPTION]... [FILE]...
                \\Reformat each paragraph in the FILE(s), writing to standard output.
                \\
                \\  -c, --crown-margin     preserve indent of first two lines
                \\  -g, --goal=WIDTH       goal width (default: 93% of width)
                \\  -p, --prefix=STRING    reformat only lines beginning with STRING
                \\  -s, --split-only       split long lines, but do not refill
                \\  -t, --tagged-paragraph like -c, but first/second indent must differ
                \\  -u, --uniform-spacing  one space between words, two after sentences
                \\  -w, --width=WIDTH      maximum line width (default 75)
                \\      --help             display this help and exit
                \\
            ;
            _ = libc.write(libc.STDOUT_FILENO, help.ptr, help.len);
            return;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--crown-margin")) {
            crown_margin = true;
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--tagged-paragraph")) {
            tagged_paragraph = true;
            crown_margin = true; // tagged implies crown behavior
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--split-only")) {
            split_only = true;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--uniform-spacing")) {
            uniform = true;
        } else if (std.mem.startsWith(u8, arg, "-g")) {
            const val = if (arg.len > 2) arg[2..] else args.next() orelse "0";
            goal = std.fmt.parseInt(usize, val, 10) catch 0;
            goal_explicitly_set = true;
        } else if (std.mem.startsWith(u8, arg, "--goal=")) {
            goal = std.fmt.parseInt(usize, arg[7..], 10) catch 0;
            goal_explicitly_set = true;
        } else if (std.mem.startsWith(u8, arg, "-w")) {
            const val = if (arg.len > 2) arg[2..] else args.next() orelse "75";
            width = std.fmt.parseInt(usize, val, 10) catch 75;
        } else if (std.mem.startsWith(u8, arg, "--width=")) {
            width = std.fmt.parseInt(usize, arg[8..], 10) catch 75;
        } else if (std.mem.startsWith(u8, arg, "-p")) {
            prefix = if (arg.len > 2) arg[2..] else args.next();
        } else if (std.mem.startsWith(u8, arg, "--prefix=")) {
            prefix = arg[9..];
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] >= '0' and arg[1] <= '9') {
            // -WIDTH shorthand
            width = std.fmt.parseInt(usize, arg[1..], 10) catch 75;
        } else if (arg.len > 0 and arg[0] != '-') {
            try files.append(allocator, arg);
        }
    }

    // Set default goal if not explicitly set
    if (!goal_explicitly_set) {
        goal = (width * 93) / 100;
    }
    // Goal must not exceed width
    if (goal > width) goal = width;

    var out = OutputBuffer{};

    if (files.items.len == 0) {
        const content = try readStdin(allocator);
        defer allocator.free(content);
        processInput(content, &out, width, goal, split_only, uniform, prefix, crown_margin, tagged_paragraph);
    } else {
        for (files.items) |path| {
            if (std.mem.eql(u8, path, "-")) {
                const content = try readStdin(allocator);
                defer allocator.free(content);
                processInput(content, &out, width, goal, split_only, uniform, prefix, crown_margin, tagged_paragraph);
            } else {
                const content = readFile(path, allocator) catch continue;
                defer allocator.free(content);
                processInput(content, &out, width, goal, split_only, uniform, prefix, crown_margin, tagged_paragraph);
            }
        }
    }

    out.flush();
}
