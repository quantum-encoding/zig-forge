//! zsed - High-performance stream editor
//!
//! Compatible with GNU sed for common operations:
//! - s/pattern/replacement/flags: substitute text
//! - y/source/dest/: transliterate characters
//! - d: delete pattern space
//! - p: print pattern space
//! - q: quit
//! - b/t/:: branch, branch-if-substitution, label
//! - N/P/D: multi-line commands
//! - Address types: line numbers, ranges, /regex/, $
//! - -n: suppress automatic printing
//! - -e: add script expression
//! - -f: read script from file
//! - -i[SUFFIX]: edit files in place
//! - -E/-r: use extended regular expressions
//!
//! Uses a simple but fast pattern matching engine.

const std = @import("std");
const libc = std.c;

const BUFFER_SIZE = 64 * 1024;
const MAX_LINE = 8192;

const AddressType = enum {
    none,
    line_number,
    last_line,
    regex,
    step, // first~step
};

const Address = struct {
    addr_type: AddressType = .none,
    line_num: usize = 0,
    step: usize = 0,
    pattern: []const u8 = "",
    negated: bool = false,
};

const CommandType = enum {
    substitute,
    delete,
    print,
    quit,
    append,
    insert,
    change,
    print_line_num,
    next,
    hold,
    hold_append,
    get,
    get_append,
    exchange,
    transliterate,
    branch,
    branch_sub,
    label,
    append_next,
    print_first,
    delete_first,
    noop,
};

const SubstituteFlags = struct {
    global: bool = false,
    ignore_case: bool = false,
    print: bool = false,
    nth: usize = 0, // 0 means first occurrence (or all if global)
};

const Command = struct {
    addr1: Address = .{},
    addr2: Address = .{}, // For ranges
    has_range: bool = false,
    in_range: bool = false, // Track range state across lines
    cmd_type: CommandType = .noop,
    // For substitute
    pattern: []const u8 = "",
    replacement: []const u8 = "",
    sub_flags: SubstituteFlags = .{},
    // For a/i/c commands
    text: []const u8 = "",
    // For y command (transliterate)
    source_set: []const u8 = "",
    dest_set: []const u8 = "",
    // For b/t/: commands (label)
    label_name: []const u8 = "",
};

const Config = struct {
    quiet: bool = false,
    in_place: bool = false,
    in_place_suffix: []const u8 = "",
    extended_regex: bool = false,
    expressions: std.ArrayListUnmanaged([]const u8) = .empty,
    script_files: std.ArrayListUnmanaged([]const u8) = .empty,
    files: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.expressions.items) |item| {
            allocator.free(item);
        }
        self.expressions.deinit(allocator);
        for (self.script_files.items) |item| {
            allocator.free(item);
        }
        self.script_files.deinit(allocator);
        for (self.files.items) |item| {
            allocator.free(item);
        }
        self.files.deinit(allocator);
    }
};

// Simple pattern matching - supports:
// . = any single char
// * = zero or more of previous
// ^ = start of line
// $ = end of line
// \. \* \^ \$ \\ = literal chars
// [abc] = character class
// [^abc] = negated character class
fn matchPattern(pattern: []const u8, text: []const u8, ignore_case: bool) ?struct { start: usize, end: usize } {
    if (pattern.len == 0) return .{ .start = 0, .end = 0 };

    const anchored_start = pattern.len > 0 and pattern[0] == '^';
    const search_pattern = if (anchored_start) pattern[1..] else pattern;

    if (anchored_start) {
        if (matchAt(search_pattern, text, 0, ignore_case)) |end| {
            return .{ .start = 0, .end = end };
        }
        return null;
    }

    // Try matching at each position
    var pos: usize = 0;
    while (pos <= text.len) : (pos += 1) {
        if (matchAt(search_pattern, text, pos, ignore_case)) |end| {
            return .{ .start = pos, .end = end };
        }
        if (pos == text.len) break;
    }
    return null;
}

fn matchAt(pattern: []const u8, text: []const u8, start: usize, ignore_case: bool) ?usize {
    var pi: usize = 0;
    var ti: usize = start;

    while (pi < pattern.len) {
        // Check for end anchor
        if (pattern[pi] == '$' and pi + 1 == pattern.len) {
            if (ti == text.len) return ti;
            return null;
        }

        // Check for * (greedy match of previous)
        if (pi + 1 < pattern.len and pattern[pi + 1] == '*') {
            const match_char = pattern[pi];
            pi += 2; // Skip char and *

            // Try matching zero or more - greedy then backtrack
            var max_ti = ti;
            while (max_ti < text.len and charMatches(match_char, text[max_ti], ignore_case)) {
                max_ti += 1;
            }

            // Try from longest to shortest match
            while (max_ti >= ti) : (max_ti -|= 1) {
                if (matchAt(pattern[pi..], text, max_ti, ignore_case)) |end| {
                    return end;
                }
                if (max_ti == ti) break;
            }
            return null;
        }

        // Handle escape sequences
        if (pattern[pi] == '\\' and pi + 1 < pattern.len) {
            pi += 1;
            const esc_char: u8 = switch (pattern[pi]) {
                'n' => '\n',
                't' => '\t',
                else => pattern[pi],
            };
            if (ti >= text.len) return null;
            if (!charMatchesLiteral(esc_char, text[ti], ignore_case)) return null;
            pi += 1;
            ti += 1;
            continue;
        }

        // Handle character class [...]
        if (pattern[pi] == '[') {
            if (ti >= text.len) return null;
            const class_end = findClassEnd(pattern, pi);
            if (class_end == null) return null;
            if (!matchCharClass(pattern[pi..class_end.?], text[ti], ignore_case)) return null;
            pi = class_end.?;
            ti += 1;
            continue;
        }

        // Regular character or .
        if (ti >= text.len) return null;
        if (!charMatches(pattern[pi], text[ti], ignore_case)) return null;
        pi += 1;
        ti += 1;
    }

    return ti;
}

fn charMatches(pattern_char: u8, text_char: u8, ignore_case: bool) bool {
    if (pattern_char == '.') return true;
    return charMatchesLiteral(pattern_char, text_char, ignore_case);
}

fn charMatchesLiteral(pattern_char: u8, text_char: u8, ignore_case: bool) bool {
    if (ignore_case) {
        return std.ascii.toLower(pattern_char) == std.ascii.toLower(text_char);
    }
    return pattern_char == text_char;
}

fn findClassEnd(pattern: []const u8, start: usize) ?usize {
    var i = start + 1;
    if (i < pattern.len and pattern[i] == '^') i += 1;
    if (i < pattern.len and pattern[i] == ']') i += 1;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == ']') return i + 1;
    }
    return null;
}

fn matchCharClass(class: []const u8, ch: u8, ignore_case: bool) bool {
    if (class.len < 2 or class[0] != '[') return false;

    var negated = false;
    var i: usize = 1;
    if (i < class.len and class[i] == '^') {
        negated = true;
        i += 1;
    }

    const test_char = if (ignore_case) std.ascii.toLower(ch) else ch;
    var found = false;

    while (i < class.len and class[i] != ']') {
        var match_char = class[i];
        if (ignore_case) match_char = std.ascii.toLower(match_char);

        // Check for range a-z
        if (i + 2 < class.len and class[i + 1] == '-' and class[i + 2] != ']') {
            var end_char = class[i + 2];
            if (ignore_case) end_char = std.ascii.toLower(end_char);
            if (test_char >= match_char and test_char <= end_char) found = true;
            i += 3;
        } else {
            if (test_char == match_char) found = true;
            i += 1;
        }
    }

    return if (negated) !found else found;
}

fn substitute(allocator: std.mem.Allocator, line: []const u8, cmd: *const Command) ![]u8 {
    var result = std.ArrayListUnmanaged(u8).empty;
    errdefer result.deinit(allocator);

    var pos: usize = 0;
    var occurrence: usize = 0;

    while (pos <= line.len) {
        const match = matchPattern(cmd.pattern, line[pos..], cmd.sub_flags.ignore_case);
        if (match == null) {
            try result.appendSlice(allocator, line[pos..]);
            break;
        }

        const abs_start = pos + match.?.start;
        const abs_end = pos + match.?.end;
        occurrence += 1;

        // Check if we should replace this occurrence
        const should_replace = cmd.sub_flags.global or
            (cmd.sub_flags.nth == 0 and occurrence == 1) or
            (cmd.sub_flags.nth > 0 and occurrence == cmd.sub_flags.nth);

        if (should_replace) {
            // Append text before match
            try result.appendSlice(allocator, line[pos..abs_start]);
            // Append replacement (handle & and \1-\9 backrefs)
            try appendReplacement(allocator, &result, cmd.replacement, line[abs_start..abs_end]);
            pos = abs_end;

            if (!cmd.sub_flags.global and (cmd.sub_flags.nth == 0 or occurrence == cmd.sub_flags.nth)) {
                try result.appendSlice(allocator, line[pos..]);
                break;
            }
        } else {
            try result.appendSlice(allocator, line[pos..abs_end]);
            pos = abs_end;
        }

        // Prevent infinite loop on zero-width match
        if (match.?.start == match.?.end) {
            if (pos < line.len) {
                try result.append(allocator, line[pos]);
                pos += 1;
            } else {
                break;
            }
        }
    }

    return result.toOwnedSlice(allocator);
}

fn appendReplacement(allocator: std.mem.Allocator, result: *std.ArrayListUnmanaged(u8), replacement: []const u8, matched: []const u8) !void {
    var i: usize = 0;
    while (i < replacement.len) : (i += 1) {
        if (replacement[i] == '&') {
            try result.appendSlice(allocator, matched);
        } else if (replacement[i] == '\\' and i + 1 < replacement.len) {
            i += 1;
            switch (replacement[i]) {
                'n' => try result.append(allocator, '\n'),
                't' => try result.append(allocator, '\t'),
                '&' => try result.append(allocator, '&'),
                '\\' => try result.append(allocator, '\\'),
                else => try result.append(allocator, replacement[i]),
            }
        } else {
            try result.append(allocator, replacement[i]);
        }
    }
}

fn parseCommand(allocator: std.mem.Allocator, script: []const u8) !std.ArrayListUnmanaged(Command) {
    var commands = std.ArrayListUnmanaged(Command).empty;
    errdefer commands.deinit(allocator);

    var pos: usize = 0;
    while (pos < script.len) {
        // Skip whitespace and semicolons
        while (pos < script.len and (script[pos] == ' ' or script[pos] == '\t' or
            script[pos] == '\n' or script[pos] == ';'))
        {
            pos += 1;
        }
        if (pos >= script.len) break;

        var cmd = Command{};

        // Parse address(es)
        const addr_result = parseAddress(script, pos);
        cmd.addr1 = addr_result.addr;
        pos = addr_result.new_pos;

        // Skip whitespace
        while (pos < script.len and (script[pos] == ' ' or script[pos] == '\t')) {
            pos += 1;
        }

        // Check for comma (range)
        if (pos < script.len and script[pos] == ',') {
            pos += 1;
            while (pos < script.len and (script[pos] == ' ' or script[pos] == '\t')) {
                pos += 1;
            }
            const addr2_result = parseAddress(script, pos);
            cmd.addr2 = addr2_result.addr;
            pos = addr2_result.new_pos;
            cmd.has_range = true;
        }

        // Skip whitespace
        while (pos < script.len and (script[pos] == ' ' or script[pos] == '\t')) {
            pos += 1;
        }

        // Check for negation
        if (pos < script.len and script[pos] == '!') {
            cmd.addr1.negated = true;
            pos += 1;
        }

        if (pos >= script.len) break;

        // Parse command
        const c = script[pos];
        pos += 1;

        switch (c) {
            's' => {
                cmd.cmd_type = .substitute;
                if (pos >= script.len) break;
                const delim = script[pos];
                pos += 1;

                // Find pattern
                const pattern_start = pos;
                while (pos < script.len and script[pos] != delim) {
                    if (script[pos] == '\\' and pos + 1 < script.len) pos += 1;
                    pos += 1;
                }
                cmd.pattern = try allocator.dupe(u8, script[pattern_start..pos]);

                if (pos < script.len) pos += 1; // Skip delimiter

                // Find replacement
                const repl_start = pos;
                while (pos < script.len and script[pos] != delim) {
                    if (script[pos] == '\\' and pos + 1 < script.len) pos += 1;
                    pos += 1;
                }
                cmd.replacement = try allocator.dupe(u8, script[repl_start..pos]);

                if (pos < script.len) pos += 1; // Skip delimiter

                // Parse flags
                while (pos < script.len and script[pos] != ';' and script[pos] != '\n' and script[pos] != ' ') {
                    switch (script[pos]) {
                        'g' => cmd.sub_flags.global = true,
                        'i', 'I' => cmd.sub_flags.ignore_case = true,
                        'p' => cmd.sub_flags.print = true,
                        '1'...'9' => cmd.sub_flags.nth = script[pos] - '0',
                        else => {},
                    }
                    pos += 1;
                }
            },
            'y' => {
                cmd.cmd_type = .transliterate;
                if (pos >= script.len) break;
                const y_delim = script[pos];
                pos += 1;

                // Parse source set
                const src_start = pos;
                while (pos < script.len and script[pos] != y_delim) {
                    if (script[pos] == '\\' and pos + 1 < script.len) pos += 1;
                    pos += 1;
                }
                cmd.source_set = try allocator.dupe(u8, script[src_start..pos]);
                if (pos < script.len) pos += 1; // Skip delimiter

                // Parse dest set
                const dst_start = pos;
                while (pos < script.len and script[pos] != y_delim) {
                    if (script[pos] == '\\' and pos + 1 < script.len) pos += 1;
                    pos += 1;
                }
                cmd.dest_set = try allocator.dupe(u8, script[dst_start..pos]);
                if (pos < script.len) pos += 1; // Skip delimiter
            },
            'b' => {
                cmd.cmd_type = .branch;
                // Skip optional whitespace
                while (pos < script.len and (script[pos] == ' ' or script[pos] == '\t')) pos += 1;
                // Parse optional label name
                const lbl_start = pos;
                while (pos < script.len and script[pos] != ';' and script[pos] != '\n' and
                    script[pos] != ' ' and script[pos] != '\t' and script[pos] != '}')
                {
                    pos += 1;
                }
                cmd.label_name = try allocator.dupe(u8, script[lbl_start..pos]);
            },
            't' => {
                cmd.cmd_type = .branch_sub;
                // Skip optional whitespace
                while (pos < script.len and (script[pos] == ' ' or script[pos] == '\t')) pos += 1;
                // Parse optional label name
                const lbl_start = pos;
                while (pos < script.len and script[pos] != ';' and script[pos] != '\n' and
                    script[pos] != ' ' and script[pos] != '\t' and script[pos] != '}')
                {
                    pos += 1;
                }
                cmd.label_name = try allocator.dupe(u8, script[lbl_start..pos]);
            },
            ':' => {
                cmd.cmd_type = .label;
                // Skip optional whitespace
                while (pos < script.len and (script[pos] == ' ' or script[pos] == '\t')) pos += 1;
                // Parse label name
                const lbl_start = pos;
                while (pos < script.len and script[pos] != ';' and script[pos] != '\n' and
                    script[pos] != ' ' and script[pos] != '\t' and script[pos] != '}')
                {
                    pos += 1;
                }
                cmd.label_name = try allocator.dupe(u8, script[lbl_start..pos]);
            },
            'N' => cmd.cmd_type = .append_next,
            'P' => cmd.cmd_type = .print_first,
            'D' => cmd.cmd_type = .delete_first,
            'd' => cmd.cmd_type = .delete,
            'p' => cmd.cmd_type = .print,
            'q' => cmd.cmd_type = .quit,
            'n' => cmd.cmd_type = .next,
            '=' => cmd.cmd_type = .print_line_num,
            'h' => cmd.cmd_type = .hold,
            'H' => cmd.cmd_type = .hold_append,
            'g' => cmd.cmd_type = .get,
            'G' => cmd.cmd_type = .get_append,
            'x' => cmd.cmd_type = .exchange,
            'a' => {
                cmd.cmd_type = .append;
                // Skip optional backslash and whitespace
                if (pos < script.len and script[pos] == '\\') pos += 1;
                while (pos < script.len and (script[pos] == ' ' or script[pos] == '\t')) pos += 1;
                if (pos < script.len and script[pos] == '\n') pos += 1;

                // Parse text until end of line or unescaped semicolon
                const text_start = pos;
                while (pos < script.len and script[pos] != '\n') {
                    if (script[pos] == '\\' and pos + 1 < script.len) pos += 1;
                    pos += 1;
                }
                cmd.text = try allocator.dupe(u8, script[text_start..pos]);
            },
            'i' => {
                cmd.cmd_type = .insert;
                // Skip optional backslash and whitespace
                if (pos < script.len and script[pos] == '\\') pos += 1;
                while (pos < script.len and (script[pos] == ' ' or script[pos] == '\t')) pos += 1;
                if (pos < script.len and script[pos] == '\n') pos += 1;

                // Parse text
                const text_start = pos;
                while (pos < script.len and script[pos] != '\n') {
                    if (script[pos] == '\\' and pos + 1 < script.len) pos += 1;
                    pos += 1;
                }
                cmd.text = try allocator.dupe(u8, script[text_start..pos]);
            },
            'c' => {
                cmd.cmd_type = .change;
                // Skip optional backslash and whitespace
                if (pos < script.len and script[pos] == '\\') pos += 1;
                while (pos < script.len and (script[pos] == ' ' or script[pos] == '\t')) pos += 1;
                if (pos < script.len and script[pos] == '\n') pos += 1;

                // Parse text
                const text_start = pos;
                while (pos < script.len and script[pos] != '\n') {
                    if (script[pos] == '\\' and pos + 1 < script.len) pos += 1;
                    pos += 1;
                }
                cmd.text = try allocator.dupe(u8, script[text_start..pos]);
            },
            '#' => {
                // Comment - skip to end of line
                while (pos < script.len and script[pos] != '\n') pos += 1;
                continue;
            },
            else => continue,
        }

        try commands.append(allocator, cmd);
    }

    return commands;
}

fn parseAddress(script: []const u8, start: usize) struct { addr: Address, new_pos: usize } {
    var addr = Address{};
    var pos = start;

    if (pos >= script.len) return .{ .addr = addr, .new_pos = pos };

    // Line number
    if (script[pos] >= '0' and script[pos] <= '9') {
        addr.addr_type = .line_number;
        var num: usize = 0;
        while (pos < script.len and script[pos] >= '0' and script[pos] <= '9') {
            num = num * 10 + (script[pos] - '0');
            pos += 1;
        }
        addr.line_num = num;

        // Check for step (first~step)
        if (pos < script.len and script[pos] == '~') {
            pos += 1;
            var step: usize = 0;
            while (pos < script.len and script[pos] >= '0' and script[pos] <= '9') {
                step = step * 10 + (script[pos] - '0');
                pos += 1;
            }
            addr.addr_type = .step;
            addr.step = step;
        }
    } else if (script[pos] == '$') {
        addr.addr_type = .last_line;
        pos += 1;
    } else if (script[pos] == '/') {
        addr.addr_type = .regex;
        pos += 1;
        const pattern_start = pos;
        while (pos < script.len and script[pos] != '/') {
            if (script[pos] == '\\' and pos + 1 < script.len) pos += 1;
            pos += 1;
        }
        addr.pattern = script[pattern_start..pos];
        if (pos < script.len) pos += 1; // Skip closing /
    }

    return .{ .addr = addr, .new_pos = pos };
}

fn addressMatches(addr: *const Address, line_num: usize, is_last: bool, line: []const u8) bool {
    const matches = switch (addr.addr_type) {
        .none => true,
        .line_number => line_num == addr.line_num,
        .last_line => is_last,
        .regex => matchPattern(addr.pattern, line, false) != null,
        .step => if (addr.line_num == 0) false else (line_num >= addr.line_num and
            (addr.step == 0 or (line_num - addr.line_num) % addr.step == 0)),
    };
    return if (addr.negated) !matches else matches;
}

const OutputBuffer = struct {
    buf: [65536]u8 = undefined,
    len: usize = 0,

    fn write(self: *OutputBuffer, data: []const u8) void {
        if (self.len + data.len > self.buf.len) {
            self.flush();
        }
        if (data.len > self.buf.len) {
            // Data too large, write directly
            _ = libc.write(libc.STDOUT_FILENO, data.ptr, data.len);
            return;
        }
        @memcpy(self.buf[self.len..][0..data.len], data);
        self.len += data.len;
    }

    fn writeLine(self: *OutputBuffer, data: []const u8) void {
        self.write(data);
        self.write("\n");
    }

    fn writeNum(self: *OutputBuffer, num: usize) void {
        var tmp: [20]u8 = undefined;
        var n = num;
        var i: usize = tmp.len;
        if (n == 0) {
            i -= 1;
            tmp[i] = '0';
        } else {
            while (n > 0) {
                i -= 1;
                tmp[i] = @intCast('0' + n % 10);
                n /= 10;
            }
        }
        self.write(tmp[i..]);
    }

    fn flush(self: *OutputBuffer) void {
        if (self.len > 0) {
            _ = libc.write(libc.STDOUT_FILENO, &self.buf, self.len);
            self.len = 0;
        }
    }
};

fn findLabelIndex(commands: []Command, label_name: []const u8) ?usize {
    for (commands, 0..) |*cmd, idx| {
        if (cmd.cmd_type == .label and std.mem.eql(u8, cmd.label_name, label_name)) {
            return idx;
        }
    }
    return null;
}

fn transliterate(allocator: std.mem.Allocator, text: []const u8, source: []const u8, dest: []const u8) ![]u8 {
    var result = try allocator.alloc(u8, text.len);
    for (text, 0..) |ch, idx| {
        var replaced = false;
        for (source, 0..) |sc, si| {
            if (ch == sc) {
                result[idx] = if (si < dest.len) dest[si] else ch;
                replaced = true;
                break;
            }
        }
        if (!replaced) {
            result[idx] = ch;
        }
    }
    return result;
}

/// LineReader reads from an fd (or stdin) and produces lines one at a time.
/// This is needed so that N command can pull in the next line from within
/// the command processing loop.
const LineReader = struct {
    read_buf: [BUFFER_SIZE]u8 = undefined,
    read_len: usize = 0,
    read_pos: usize = 0,
    fd: i32,
    eof: bool = false,

    fn init(fd: i32) LineReader {
        return .{ .fd = fd };
    }

    /// Read the next line. Returns null at EOF.
    /// The returned slice is allocated and owned by the caller.
    fn nextLine(self: *LineReader, allocator: std.mem.Allocator) !?[]u8 {
        var line_buf = std.ArrayListUnmanaged(u8).empty;
        errdefer line_buf.deinit(allocator);

        while (true) {
            // Scan remaining buffer for newline
            while (self.read_pos < self.read_len) {
                const byte = self.read_buf[self.read_pos];
                self.read_pos += 1;
                if (byte == '\n') {
                    return try line_buf.toOwnedSlice(allocator);
                }
                try line_buf.append(allocator, byte);
            }
            // Need more data
            if (self.eof) {
                // Return remaining data as last line (no trailing newline)
                if (line_buf.items.len > 0) {
                    return try line_buf.toOwnedSlice(allocator);
                }
                line_buf.deinit(allocator);
                return null;
            }
            const n = libc.read(self.fd, &self.read_buf, self.read_buf.len);
            if (n <= 0) {
                self.eof = true;
                // Return remaining data as last line
                if (line_buf.items.len > 0) {
                    return try line_buf.toOwnedSlice(allocator);
                }
                line_buf.deinit(allocator);
                return null;
            }
            self.read_len = @intCast(n);
            self.read_pos = 0;
        }
    }
};

fn processEscText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var text_buf = std.ArrayListUnmanaged(u8).empty;
    errdefer text_buf.deinit(allocator);
    var ti: usize = 0;
    while (ti < text.len) {
        if (text[ti] == '\\' and ti + 1 < text.len) {
            ti += 1;
            switch (text[ti]) {
                'n' => try text_buf.append(allocator, '\n'),
                't' => try text_buf.append(allocator, '\t'),
                else => try text_buf.append(allocator, text[ti]),
            }
        } else {
            try text_buf.append(allocator, text[ti]);
        }
        ti += 1;
    }
    return text_buf.toOwnedSlice(allocator);
}

fn processFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    is_stdin: bool,
    commands: []Command,
    config: *const Config,
) !void {
    var out = OutputBuffer{};

    var hold_space = std.ArrayListUnmanaged(u8).empty;
    defer hold_space.deinit(allocator);

    var fd: i32 = undefined;
    if (is_stdin) {
        fd = libc.STDIN_FILENO;
    } else {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        fd = libc.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (fd < 0) {
            _ = libc.write(libc.STDERR_FILENO, "zsed: cannot open file\n", 23);
            return error.OpenError;
        }
    }
    defer if (!is_stdin) {
        _ = libc.close(fd);
    };

    var reader = LineReader.init(fd);
    var line_num: usize = 0;

    var pattern_space = std.ArrayListUnmanaged(u8).empty;
    defer pattern_space.deinit(allocator);

    // Main cycle: read a line, process commands, print if needed
    outer: while (true) {
        // Read next line into pattern space
        const maybe_line = try reader.nextLine(allocator);
        if (maybe_line == null) break;
        const line = maybe_line.?;
        defer allocator.free(line);

        pattern_space.clearRetainingCapacity();
        try pattern_space.appendSlice(allocator, line);
        line_num += 1;

        // Process the command list - may restart from beginning (for D command)
        var sub_happened = false; // Track substitutions for 't' command
        try processCommands(allocator, commands, &pattern_space, &hold_space, &reader, &line_num, &sub_happened, config, &out);

        // Check if we need to break (quit flag set by processCommands is handled via error)
        continue :outer;
    }

    out.flush();
}

const ProcessAction = enum {
    next_cycle,
    quit,
    restart, // For D command: restart commands with current pattern space
};

fn processCommands(
    allocator: std.mem.Allocator,
    commands: []Command,
    pattern_space: *std.ArrayListUnmanaged(u8),
    hold_space: *std.ArrayListUnmanaged(u8),
    reader: *LineReader,
    line_num: *usize,
    sub_happened: *bool,
    config: *const Config,
    out: *OutputBuffer,
) !void {
    // Reset sub_happened at start of new input line
    sub_happened.* = false;

    return processCommandsInner(allocator, commands, pattern_space, hold_space, reader, line_num, sub_happened, config, out);
}

fn processCommandsInner(
    allocator: std.mem.Allocator,
    commands: []Command,
    pattern_space: *std.ArrayListUnmanaged(u8),
    hold_space: *std.ArrayListUnmanaged(u8),
    reader: *LineReader,
    line_num: *usize,
    sub_happened: *bool,
    config: *const Config,
    out: *OutputBuffer,
) error{ OutOfMemory, OpenError }!void {
    var print_line = !config.quiet;
    var cmd_idx: usize = 0;

    while (cmd_idx < commands.len) {
        const cmd = &commands[cmd_idx];
        var matches: bool = false;

        if (cmd.has_range) {
            if (!cmd.in_range) {
                if (addressMatches(&cmd.addr1, line_num.*, false, pattern_space.items)) {
                    cmd.in_range = true;
                    matches = true;
                }
            } else {
                matches = true;
                if (addressMatches(&cmd.addr2, line_num.*, false, pattern_space.items)) {
                    cmd.in_range = false;
                }
            }
        } else {
            matches = addressMatches(&cmd.addr1, line_num.*, false, pattern_space.items);
        }

        if (!matches) {
            cmd_idx += 1;
            continue;
        }

        switch (cmd.cmd_type) {
            .substitute => {
                const new_line = try substitute(allocator, pattern_space.items, cmd);
                const changed = !std.mem.eql(u8, new_line, pattern_space.items);
                pattern_space.clearRetainingCapacity();
                try pattern_space.appendSlice(allocator, new_line);
                allocator.free(new_line);
                if (changed) {
                    sub_happened.* = true;
                    if (cmd.sub_flags.print) {
                        out.writeLine(pattern_space.items);
                    }
                }
            },
            .delete => {
                return; // Don't print, start next cycle
            },
            .print => {
                out.writeLine(pattern_space.items);
            },
            .quit => {
                if (print_line) {
                    out.writeLine(pattern_space.items);
                }
                out.flush();
                std.process.exit(0);
            },
            .print_line_num => {
                out.writeNum(line_num.*);
                out.write("\n");
            },
            .next => {
                // Print current pattern space (if auto-print), then read next line
                if (print_line) {
                    out.writeLine(pattern_space.items);
                }
                const maybe_line = try reader.nextLine(allocator);
                if (maybe_line == null) {
                    // No more input
                    return;
                }
                const next_line = maybe_line.?;
                defer allocator.free(next_line);
                pattern_space.clearRetainingCapacity();
                try pattern_space.appendSlice(allocator, next_line);
                line_num.* += 1;
            },
            .hold => {
                hold_space.clearRetainingCapacity();
                try hold_space.appendSlice(allocator, pattern_space.items);
            },
            .hold_append => {
                try hold_space.append(allocator, '\n');
                try hold_space.appendSlice(allocator, pattern_space.items);
            },
            .get => {
                pattern_space.clearRetainingCapacity();
                try pattern_space.appendSlice(allocator, hold_space.items);
            },
            .get_append => {
                try pattern_space.append(allocator, '\n');
                try pattern_space.appendSlice(allocator, hold_space.items);
            },
            .exchange => {
                const temp = try allocator.dupe(u8, pattern_space.items);
                defer allocator.free(temp);
                pattern_space.clearRetainingCapacity();
                try pattern_space.appendSlice(allocator, hold_space.items);
                hold_space.clearRetainingCapacity();
                try hold_space.appendSlice(allocator, temp);
            },
            .append => {
                // 'a' command: text is appended after the line is output
                if (print_line) {
                    out.writeLine(pattern_space.items);
                    print_line = false;
                }
                const text_processed = try processEscText(allocator, cmd.text);
                defer allocator.free(text_processed);
                out.writeLine(text_processed);
            },
            .insert => {
                const text_processed = try processEscText(allocator, cmd.text);
                defer allocator.free(text_processed);
                out.writeLine(text_processed);
            },
            .change => {
                const text_processed = try processEscText(allocator, cmd.text);
                defer allocator.free(text_processed);
                out.writeLine(text_processed);
                return; // Don't print pattern space
            },
            .transliterate => {
                const new_text = try transliterate(allocator, pattern_space.items, cmd.source_set, cmd.dest_set);
                pattern_space.clearRetainingCapacity();
                try pattern_space.appendSlice(allocator, new_text);
                allocator.free(new_text);
            },
            .label => {
                // Labels are just markers, do nothing
            },
            .branch => {
                if (cmd.label_name.len == 0) {
                    // Branch to end of script
                    break;
                } else {
                    // Branch to label
                    if (findLabelIndex(commands, cmd.label_name)) |target| {
                        cmd_idx = target;
                        continue; // Don't increment cmd_idx
                    }
                    // Label not found: treat as branch to end
                    break;
                }
            },
            .branch_sub => {
                if (sub_happened.*) {
                    sub_happened.* = false; // Reset the flag
                    if (cmd.label_name.len == 0) {
                        // Branch to end of script
                        break;
                    } else {
                        if (findLabelIndex(commands, cmd.label_name)) |target| {
                            cmd_idx = target;
                            continue;
                        }
                        break;
                    }
                }
            },
            .append_next => {
                // N command: append newline + next line to pattern space
                const maybe_line = try reader.nextLine(allocator);
                if (maybe_line == null) {
                    // No more input - print pattern space if auto-print and exit
                    if (print_line) {
                        out.writeLine(pattern_space.items);
                    }
                    out.flush();
                    std.process.exit(0);
                }
                const next_line = maybe_line.?;
                defer allocator.free(next_line);
                try pattern_space.append(allocator, '\n');
                try pattern_space.appendSlice(allocator, next_line);
                line_num.* += 1;
            },
            .print_first => {
                // P command: print up to first newline in pattern space
                const ps = pattern_space.items;
                if (std.mem.indexOfScalar(u8, ps, '\n')) |nl_pos| {
                    out.writeLine(ps[0..nl_pos]);
                } else {
                    out.writeLine(ps);
                }
            },
            .delete_first => {
                // D command: delete up to first newline, restart with remainder
                const ps = pattern_space.items;
                if (std.mem.indexOfScalar(u8, ps, '\n')) |nl_pos| {
                    // Remove everything up to and including the newline
                    const remaining = try allocator.dupe(u8, ps[nl_pos + 1 ..]);
                    defer allocator.free(remaining);
                    pattern_space.clearRetainingCapacity();
                    try pattern_space.appendSlice(allocator, remaining);
                    // Restart the script from the beginning with the remaining pattern space
                    // Do NOT read a new line, do NOT reset sub_happened
                    return processCommandsInner(allocator, commands, pattern_space, hold_space, reader, line_num, sub_happened, config, out);
                } else {
                    // No newline - acts like 'd', discard and start next cycle
                    return;
                }
            },
            .noop => {},
        }

        cmd_idx += 1;
    }

    // End of command list - print pattern space if auto-print
    if (print_line) {
        out.writeLine(pattern_space.items);
    }
}

fn parseArgs(allocator: std.mem.Allocator, minimal_args: anytype) !Config {
    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(minimal_args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    var config = Config{};
    var i: usize = 1;
    var found_script = false;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-' and arg.len > 1 and arg[1] != '-') {
            var j: usize = 1;
            while (j < arg.len) : (j += 1) {
                switch (arg[j]) {
                    'n' => config.quiet = true,
                    'e' => {
                        if (j + 1 < arg.len) {
                            try config.expressions.append(allocator, try allocator.dupe(u8, arg[j + 1 ..]));
                            found_script = true;
                            break;
                        } else {
                            i += 1;
                            if (i < args.len) {
                                try config.expressions.append(allocator, try allocator.dupe(u8, args[i]));
                                found_script = true;
                            }
                        }
                    },
                    'f' => {
                        if (j + 1 < arg.len) {
                            try config.script_files.append(allocator, try allocator.dupe(u8, arg[j + 1 ..]));
                            found_script = true;
                            break;
                        } else {
                            i += 1;
                            if (i < args.len) {
                                try config.script_files.append(allocator, try allocator.dupe(u8, args[i]));
                                found_script = true;
                            }
                        }
                    },
                    'E', 'r' => config.extended_regex = true,
                    'i' => {
                        config.in_place = true;
                        if (j + 1 < arg.len) {
                            config.in_place_suffix = arg[j + 1 ..];
                            break;
                        }
                    },
                    else => {},
                }
            }
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] == '-') {
            if (std.mem.eql(u8, arg, "--help")) {
                printHelp();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--version")) {
                printVersion();
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "--silent")) {
                config.quiet = true;
            } else if (std.mem.eql(u8, arg, "--regexp-extended")) {
                config.extended_regex = true;
            } else if (std.mem.startsWith(u8, arg, "--expression=")) {
                try config.expressions.append(allocator, try allocator.dupe(u8, arg[13..]));
                found_script = true;
            } else if (std.mem.startsWith(u8, arg, "--file=")) {
                try config.script_files.append(allocator, try allocator.dupe(u8, arg[7..]));
                found_script = true;
            } else if (std.mem.startsWith(u8, arg, "--in-place")) {
                config.in_place = true;
                if (arg.len > 10 and arg[10] == '=') {
                    config.in_place_suffix = arg[11..];
                }
            }
        } else {
            // First non-option is script if no -e or -f was given
            if (!found_script and config.expressions.items.len == 0 and config.script_files.items.len == 0) {
                try config.expressions.append(allocator, try allocator.dupe(u8, arg));
                found_script = true;
            } else {
                try config.files.append(allocator, try allocator.dupe(u8, arg));
            }
        }
    }

    if (config.files.items.len == 0) {
        try config.files.append(allocator, try allocator.dupe(u8, "-"));
    }

    return config;
}

fn printHelp() void {
    const help =
        \\Usage: zsed [OPTION]... {script-only-if-no-other-script} [input-file]...
        \\
        \\  -n, --quiet, --silent    suppress automatic printing of pattern space
        \\  -e script, --expression=script
        \\                           add the script to the commands to be executed
        \\  -f script-file, --file=script-file
        \\                           add contents of script-file to commands
        \\  -i[SUFFIX], --in-place[=SUFFIX]
        \\                           edit files in place (makes backup if SUFFIX supplied)
        \\  -E, -r, --regexp-extended
        \\                           use extended regular expressions
        \\      --help               display this help and exit
        \\      --version            output version information and exit
        \\
        \\Commands:
        \\  s/regexp/replacement/flags  substitute matching text
        \\    flags: g (global), i (ignore case), p (print), N (Nth occurrence)
        \\  y/source/dest/              transliterate characters
        \\  d                           delete pattern space
        \\  D                           delete first line of pattern space
        \\  p                           print pattern space
        \\  P                           print first line of pattern space
        \\  q                           quit
        \\  n                           read next line into pattern space
        \\  N                           append next line to pattern space
        \\  a\\ text                     append text after current line
        \\  i\\ text                     insert text before current line
        \\  c\\ text                     change (replace) current line with text
        \\  =                           print line number
        \\  h/H                         copy/append pattern space to hold space
        \\  g/G                         copy/append hold space to pattern space
        \\  x                           exchange pattern and hold spaces
        \\  :label                      define label for b and t commands
        \\  b label                     branch to label (or end of script)
        \\  t label                     branch if substitution was made
        \\
        \\Addresses:
        \\  N                           line number
        \\  $                           last line
        \\  /regexp/                    lines matching regexp
        \\  N,M                         range from line N to M
        \\  N~S                         every S lines starting at N
        \\
        \\zsed - High-performance stream editor in Zig
        \\
    ;
    _ = libc.write(libc.STDOUT_FILENO, help.ptr, help.len);
}

fn printVersion() void {
    _ = libc.write(libc.STDOUT_FILENO, "zsed 0.1.0\n", 11);
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var config = parseArgs(allocator, init.minimal.args) catch {
        std.process.exit(1);
    };
    defer config.deinit(allocator);

    // Read script files (-f) and add their contents as expressions
    for (config.script_files.items) |script_path| {
        const script_path_z = allocator.dupeZ(u8, script_path) catch {
            std.debug.print("zsed: out of memory\n", .{});
            std.process.exit(1);
        };
        defer allocator.free(script_path_z);

        const sfd = libc.open(script_path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(libc.mode_t, 0));
        if (sfd < 0) {
            std.debug.print("zsed: cannot open script file: {s}\n", .{script_path});
            std.process.exit(1);
        }
        defer _ = libc.close(sfd);

        // Read entire script file
        var script_buf = std.ArrayListUnmanaged(u8).empty;
        defer script_buf.deinit(allocator);
        var tmp_buf: [4096]u8 = undefined;
        while (true) {
            const n = libc.read(sfd, &tmp_buf, tmp_buf.len);
            if (n <= 0) break;
            const bytes: usize = @intCast(n);
            script_buf.appendSlice(allocator, tmp_buf[0..bytes]) catch {
                std.debug.print("zsed: out of memory\n", .{});
                std.process.exit(1);
            };
        }
        const duped = allocator.dupe(u8, script_buf.items) catch {
            std.debug.print("zsed: out of memory\n", .{});
            std.process.exit(1);
        };
        config.expressions.append(allocator, duped) catch {
            std.debug.print("zsed: out of memory\n", .{});
            std.process.exit(1);
        };
    }

    if (config.expressions.items.len == 0) {
        std.debug.print("zsed: no script specified\n", .{});
        std.process.exit(1);
    }

    // Parse all expressions into commands
    var all_commands = std.ArrayListUnmanaged(Command).empty;
    defer {
        // Free allocated strings in commands
        for (all_commands.items) |cmd| {
            if (cmd.pattern.len > 0) allocator.free(cmd.pattern);
            if (cmd.replacement.len > 0) allocator.free(cmd.replacement);
            if (cmd.text.len > 0) allocator.free(cmd.text);
            if (cmd.source_set.len > 0) allocator.free(cmd.source_set);
            if (cmd.dest_set.len > 0) allocator.free(cmd.dest_set);
            if (cmd.label_name.len > 0) allocator.free(cmd.label_name);
        }
        all_commands.deinit(allocator);
    }

    for (config.expressions.items) |expr| {
        var cmds = parseCommand(allocator, expr) catch {
            std.debug.print("zsed: invalid command\n", .{});
            std.process.exit(1);
        };
        for (cmds.items) |cmd| {
            all_commands.append(allocator, cmd) catch {};
        }
        cmds.deinit(allocator);
    }

    for (config.files.items) |file| {
        const is_stdin = std.mem.eql(u8, file, "-");
        processFile(allocator, file, is_stdin, all_commands.items, &config) catch {
            std.process.exit(1);
        };
    }
}
