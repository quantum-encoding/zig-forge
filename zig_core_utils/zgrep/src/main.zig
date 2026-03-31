//! zgrep - High-performance grep with SIMD string search
//!
//! Features:
//! - SIMD-accelerated literal string matching (AVX2/SSE2)
//! - Extended regex support (-E)
//! - Context line printing (-A/-B/-C)
//! - File include/exclude patterns
//! - GNU grep compatible options
//!
//! Options:
//! - -i, --ignore-case: case insensitive matching
//! - -v, --invert-match: select non-matching lines
//! - -c, --count: print only count of matching lines
//! - -n, --line-number: print line numbers
//! - -l, --files-with-matches: print only filenames with matches
//! - -L, --files-without-match: print only filenames without matches
//! - -H, --with-filename: print filename with output
//! - -h, --no-filename: suppress filename prefix
//! - -r, -R, --recursive: search directories recursively
//! - -q, --quiet: suppress all output
//! - -s, --no-messages: suppress error messages
//! - -o, --only-matching: print only matched parts
//! - -e PATTERN, --regexp=PATTERN: use PATTERN (may be repeated)
//! - -f FILE, --file=FILE: obtain patterns from FILE
//! - -F, --fixed-strings: treat pattern as literal string (default)
//! - -E, --extended-regexp: use extended regular expressions
//! - -w, --word-regexp: match whole words only
//! - -A NUM, --after-context=NUM: print NUM lines of trailing context
//! - -B NUM, --before-context=NUM: print NUM lines of leading context
//! - -C NUM, --context=NUM: print NUM lines of context
//! - -m NUM, --max-count=NUM: stop after NUM matches
//! - --color[=WHEN]: highlight matching strings (always/never/auto)
//! - --include=GLOB: search only files matching GLOB
//! - --exclude=GLOB: skip files matching GLOB
//! - --exclude-dir=GLOB: skip directories matching GLOB

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const libc = std.c;
const Io = std.Io;

// SIMD vector types for pattern matching
const Vec32 = @Vector(32, u8);
const Vec16 = @Vector(16, u8);

const BUFFER_SIZE = 256 * 1024; // 256KB read buffer
const MAX_CONTEXT_LINES = 1000; // Maximum context lines to buffer

// Match result for regex searches
const MatchResult = struct {
    start: usize,
    end: usize,
};

// Extended Regular Expression Engine
// Supports: . * + ? | [] [^] ^ $ () and character classes
const CompiledRegex = struct {
    const Op = enum(u8) {
        literal, // Match exact character
        any, // Match any character (.)
        char_class, // Match character class [...]
        neg_char_class, // Match negated class [^...]
        anchor_start, // ^ at start
        anchor_end, // $ at end
        group_start, // ( - start group
        group_end, // ) - end group
        alt_branch, // | - alternation
        star, // * - zero or more
        plus, // + - one or more
        question, // ? - zero or one
        word_boundary, // \b
        non_word_boundary, // \B
        digit, // \d
        non_digit, // \D
        whitespace, // \s
        non_whitespace, // \S
        word_char, // \w
        non_word_char, // \W
    };

    const Instruction = struct {
        op: Op,
        char: u8 = 0, // For literal
        class_start: u16 = 0, // Start index in class_data
        class_len: u16 = 0, // Length in class_data
        alt_jump: u16 = 0, // Jump offset for alternation
    };

    instructions: []Instruction,
    class_data: []u8, // Character class data storage
    alternatives: []*CompiledRegex = &.{}, // For | alternation

    fn deinit(self: *CompiledRegex, allocator: std.mem.Allocator) void {
        for (self.alternatives) |alt| {
            alt.deinit(allocator);
            allocator.destroy(alt);
        }
        if (self.alternatives.len > 0) allocator.free(self.alternatives);
        allocator.free(self.instructions);
        allocator.free(self.class_data);
    }

    fn compile(allocator: std.mem.Allocator, pattern: []const u8) !*CompiledRegex {
        // Check for top-level alternation (| outside [] and ())
        var alt_positions: std.ArrayListUnmanaged(usize) = .empty;
        defer alt_positions.deinit(allocator);
        {
            var ai: usize = 0;
            var in_cls = false;
            var paren_depth: usize = 0;
            while (ai < pattern.len) : (ai += 1) {
                const ach = pattern[ai];
                if (ach == '\\' and ai + 1 < pattern.len) {
                    ai += 1; // skip escaped char
                } else if (ach == '[') {
                    in_cls = true;
                } else if (ach == ']' and in_cls) {
                    in_cls = false;
                } else if (!in_cls and ach == '(') {
                    paren_depth += 1;
                } else if (!in_cls and ach == ')' and paren_depth > 0) {
                    paren_depth -= 1;
                } else if (!in_cls and paren_depth == 0 and ach == '|') {
                    try alt_positions.append(allocator, ai);
                }
            }
        }

        if (alt_positions.items.len > 0) {
            // Split pattern on | and compile each branch
            var branches: std.ArrayListUnmanaged(*CompiledRegex) = .empty;
            var start: usize = 0;
            for (alt_positions.items) |apos| {
                const branch = try compile(allocator, pattern[start..apos]);
                try branches.append(allocator, branch);
                start = apos + 1;
            }
            // Last branch
            const last_branch = try compile(allocator, pattern[start..]);
            try branches.append(allocator, last_branch);

            const regex = try allocator.create(CompiledRegex);
            regex.* = .{
                .instructions = &.{},
                .class_data = &.{},
                .alternatives = try branches.toOwnedSlice(allocator),
            };
            return regex;
        }

        var instructions: std.ArrayListUnmanaged(Instruction) = .empty;
        var class_data: std.ArrayListUnmanaged(u8) = .empty;

        var i: usize = 0;
        var in_class = false;
        var class_negated = false;
        var class_start_idx: usize = 0;

        while (i < pattern.len) {
            const ch = pattern[i];

            if (in_class) {
                if (ch == ']' and class_data.items.len > class_start_idx) {
                    const class_len = class_data.items.len - class_start_idx;
                    try instructions.append(allocator, .{
                        .op = if (class_negated) .neg_char_class else .char_class,
                        .class_start = @intCast(class_start_idx),
                        .class_len = @intCast(class_len),
                    });
                    in_class = false;
                    class_negated = false;
                    i += 1;
                } else if (ch == '-' and i + 1 < pattern.len and pattern[i + 1] != ']' and class_data.items.len > class_start_idx) {
                    // Character range a-z
                    const range_start = class_data.items[class_data.items.len - 1];
                    const range_end = pattern[i + 1];
                    if (range_end > range_start) {
                        var range_ch = range_start + 1;
                        while (range_ch <= range_end) : (range_ch += 1) {
                            try class_data.append(allocator, range_ch);
                        }
                    }
                    i += 2;
                } else {
                    try class_data.append(allocator, ch);
                    i += 1;
                }
                continue;
            }

            switch (ch) {
                '\\' => {
                    if (i + 1 < pattern.len) {
                        i += 1;
                        switch (pattern[i]) {
                            'd' => try instructions.append(allocator, .{ .op = .digit }),
                            'D' => try instructions.append(allocator, .{ .op = .non_digit }),
                            's' => try instructions.append(allocator, .{ .op = .whitespace }),
                            'S' => try instructions.append(allocator, .{ .op = .non_whitespace }),
                            'w' => try instructions.append(allocator, .{ .op = .word_char }),
                            'W' => try instructions.append(allocator, .{ .op = .non_word_char }),
                            'b' => try instructions.append(allocator, .{ .op = .word_boundary }),
                            'B' => try instructions.append(allocator, .{ .op = .non_word_boundary }),
                            'n' => try instructions.append(allocator, .{ .op = .literal, .char = '\n' }),
                            't' => try instructions.append(allocator, .{ .op = .literal, .char = '\t' }),
                            'r' => try instructions.append(allocator, .{ .op = .literal, .char = '\r' }),
                            else => try instructions.append(allocator, .{ .op = .literal, .char = pattern[i] }),
                        }
                    }
                    i += 1;
                },
                '.' => {
                    try instructions.append(allocator, .{ .op = .any });
                    i += 1;
                },
                '*' => {
                    try instructions.append(allocator, .{ .op = .star });
                    i += 1;
                },
                '+' => {
                    try instructions.append(allocator, .{ .op = .plus });
                    i += 1;
                },
                '?' => {
                    try instructions.append(allocator, .{ .op = .question });
                    i += 1;
                },
                '^' => {
                    if (i == 0) {
                        try instructions.append(allocator, .{ .op = .anchor_start });
                    } else {
                        try instructions.append(allocator, .{ .op = .literal, .char = '^' });
                    }
                    i += 1;
                },
                '$' => {
                    if (i == pattern.len - 1) {
                        try instructions.append(allocator, .{ .op = .anchor_end });
                    } else {
                        try instructions.append(allocator, .{ .op = .literal, .char = '$' });
                    }
                    i += 1;
                },
                '[' => {
                    in_class = true;
                    class_start_idx = class_data.items.len;
                    if (i + 1 < pattern.len and pattern[i + 1] == '^') {
                        class_negated = true;
                        i += 2;
                    } else {
                        i += 1;
                    }
                },
                '(' => {
                    try instructions.append(allocator, .{ .op = .group_start });
                    i += 1;
                },
                ')' => {
                    try instructions.append(allocator, .{ .op = .group_end });
                    i += 1;
                },
                '|' => {
                    try instructions.append(allocator, .{ .op = .alt_branch });
                    i += 1;
                },
                else => {
                    try instructions.append(allocator, .{ .op = .literal, .char = ch });
                    i += 1;
                },
            }
        }

        const regex = try allocator.create(CompiledRegex);
        regex.* = .{
            .instructions = try instructions.toOwnedSlice(allocator),
            .class_data = try class_data.toOwnedSlice(allocator),
        };
        return regex;
    }

    fn matchChar(self: *const CompiledRegex, ch: u8, instr: Instruction, ignore_case: bool) bool {
        const char_to_match = if (ignore_case) toLower(ch) else ch;

        switch (instr.op) {
            .literal => {
                const pattern_char = if (ignore_case) toLower(instr.char) else instr.char;
                return char_to_match == pattern_char;
            },
            .any => return ch != '\n',
            .char_class => {
                const class = self.class_data[instr.class_start .. instr.class_start + instr.class_len];
                for (class) |cc| {
                    const class_char = if (ignore_case) toLower(cc) else cc;
                    if (char_to_match == class_char) return true;
                }
                return false;
            },
            .neg_char_class => {
                const class = self.class_data[instr.class_start .. instr.class_start + instr.class_len];
                for (class) |cc| {
                    const class_char = if (ignore_case) toLower(cc) else cc;
                    if (char_to_match == class_char) return false;
                }
                return true;
            },
            .digit => return ch >= '0' and ch <= '9',
            .non_digit => return ch < '0' or ch > '9',
            .whitespace => return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r',
            .non_whitespace => return ch != ' ' and ch != '\t' and ch != '\n' and ch != '\r',
            .word_char => return isWordChar(ch),
            .non_word_char => return !isWordChar(ch),
            else => return false,
        }
    }

    fn matchAt(self: *const CompiledRegex, text: []const u8, start_pos: usize, ignore_case: bool) ?MatchResult {
        if (self.instructions.len == 0) return MatchResult{ .start = start_pos, .end = start_pos };

        // Recursive helper for backtracking
        return self.matchAtRecursive(text, start_pos, 0, ignore_case);
    }

    fn matchAtRecursive(self: *const CompiledRegex, text: []const u8, pos: usize, instr_idx: usize, ignore_case: bool) ?MatchResult {
        var current_pos = pos;
        var current_instr = instr_idx;

        while (current_instr < self.instructions.len) {
            const instr = self.instructions[current_instr];

            // Handle anchor_start
            if (instr.op == .anchor_start) {
                if (current_pos != 0) return null;
                current_instr += 1;
                continue;
            }

            // Handle anchor_end
            if (instr.op == .anchor_end) {
                if (current_pos != text.len) return null;
                current_instr += 1;
                continue;
            }

            // Handle word boundaries (zero-width)
            if (instr.op == .word_boundary) {
                const prev_is_word = if (current_pos > 0) isWordChar(text[current_pos - 1]) else false;
                const curr_is_word = if (current_pos < text.len) isWordChar(text[current_pos]) else false;
                if (prev_is_word == curr_is_word) return null;
                current_instr += 1;
                continue;
            }

            if (instr.op == .non_word_boundary) {
                const prev_is_word = if (current_pos > 0) isWordChar(text[current_pos - 1]) else false;
                const curr_is_word = if (current_pos < text.len) isWordChar(text[current_pos]) else false;
                if (prev_is_word != curr_is_word) return null;
                current_instr += 1;
                continue;
            }

            // Skip group markers for now
            if (instr.op == .group_start or instr.op == .group_end) {
                current_instr += 1;
                continue;
            }

            // Handle alternation - simplified: try current branch
            if (instr.op == .alt_branch) {
                current_instr += 1;
                continue;
            }

            // Look ahead for quantifiers
            var quantifier: ?Op = null;
            if (current_instr + 1 < self.instructions.len) {
                const next_op = self.instructions[current_instr + 1].op;
                if (next_op == .star or next_op == .plus or next_op == .question) {
                    quantifier = next_op;
                }
            }

            if (quantifier) |q| {
                // Handle quantified matches with backtracking
                const min_matches: usize = if (q == .plus) 1 else 0;
                const max_matches: usize = if (q == .question) 1 else text.len - current_pos;

                // Count maximum matches
                var match_count: usize = 0;
                while (match_count < max_matches and current_pos + match_count < text.len) {
                    if (self.matchChar(text[current_pos + match_count], instr, ignore_case)) {
                        match_count += 1;
                    } else {
                        break;
                    }
                }

                if (match_count < min_matches) return null;

                // Greedy: try longest match first, backtrack if needed
                var try_count = match_count;
                while (try_count >= min_matches) : (try_count -|= 1) {
                    // Try to match the rest of the pattern
                    if (self.matchAtRecursive(text, current_pos + try_count, current_instr + 2, ignore_case)) |result| {
                        return MatchResult{ .start = pos, .end = result.end };
                    }
                    if (try_count == 0) break;
                }
                return null;
            }

            // Regular character match
            if (current_pos >= text.len) return null;

            if (!self.matchChar(text[current_pos], instr, ignore_case)) {
                return null;
            }

            current_pos += 1;
            current_instr += 1;
        }

        return MatchResult{ .start = pos, .end = current_pos };
    }

    fn search(self: *const CompiledRegex, text: []const u8, ignore_case: bool) ?MatchResult {
        // If this regex has alternatives, try each branch
        if (self.alternatives.len > 0) {
            var best: ?MatchResult = null;
            for (self.alternatives) |alt| {
                if (alt.search(text, ignore_case)) |result| {
                    if (best == null or result.start < best.?.start) {
                        best = result;
                    }
                }
            }
            return best;
        }

        // If pattern starts with ^, only try at position 0
        if (self.instructions.len > 0 and self.instructions[0].op == .anchor_start) {
            return self.matchAt(text, 0, ignore_case);
        }

        // Try to match at each position
        var start: usize = 0;
        while (start <= text.len) : (start += 1) {
            if (self.matchAt(text, start, ignore_case)) |result| {
                return result;
            }
        }
        return null;
    }
};

const GrepResult = struct {
    matches: usize,
    had_match: bool,
};

const ColorMode = enum {
    never,
    auto,
    always,
};

const PatternEntry = struct {
    text: []const u8,
    compiled_regex: ?*CompiledRegex,
};

const Config = struct {
    ignore_case: bool = false,
    invert_match: bool = false,
    count_only: bool = false,
    line_numbers: bool = false,
    files_with_matches: bool = false,
    files_without_match: bool = false,
    with_filename: bool = false,
    no_filename: bool = false,
    recursive: bool = false,
    quiet: bool = false,
    only_matching: bool = false,
    word_regexp: bool = false,
    line_regexp: bool = false,
    extended_regex: bool = false,
    fixed_strings: bool = false,
    suppress_errors: bool = false,
    after_context: usize = 0,
    before_context: usize = 0,
    max_count: usize = 0, // 0 = unlimited
    pattern: []const u8 = "",
    pattern_lower: []u8 = &.{},
    compiled_regex: ?*CompiledRegex = null,
    files: std.ArrayListUnmanaged([]const u8) = .empty,
    include_patterns: std.ArrayListUnmanaged([]const u8) = .empty,
    exclude_patterns: std.ArrayListUnmanaged([]const u8) = .empty,
    exclude_dir_patterns: std.ArrayListUnmanaged([]const u8) = .empty,
    // Multiple patterns support (-e / -f)
    multi_patterns: std.ArrayListUnmanaged(PatternEntry) = .empty,
    // Color support
    color_mode: ColorMode = .auto,
    use_color: bool = false, // resolved at runtime

    fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.pattern_lower.len > 0) {
            allocator.free(self.pattern_lower);
        }
        if (self.compiled_regex) |regex| {
            regex.deinit(allocator);
            allocator.destroy(regex);
        }
        for (self.multi_patterns.items) |entry| {
            if (entry.compiled_regex) |regex| {
                regex.deinit(allocator);
                allocator.destroy(regex);
            }
            allocator.free(entry.text);
        }
        self.multi_patterns.deinit(allocator);
        for (self.files.items) |item| {
            allocator.free(item);
        }
        self.files.deinit(allocator);
        for (self.include_patterns.items) |item| {
            allocator.free(item);
        }
        self.include_patterns.deinit(allocator);
        for (self.exclude_patterns.items) |item| {
            allocator.free(item);
        }
        self.exclude_patterns.deinit(allocator);
        for (self.exclude_dir_patterns.items) |item| {
            allocator.free(item);
        }
        self.exclude_dir_patterns.deinit(allocator);
    }
};

// SIMD-accelerated search for first byte of pattern
// Returns index of first occurrence or null
fn simdFindFirstByte(haystack: []const u8, needle: u8) ?usize {
    const len = haystack.len;
    var i: usize = 0;

    // Process 32 bytes at a time using AVX2-style vectors
    const needle_vec: Vec32 = @splat(needle);
    while (i + 32 <= len) : (i += 32) {
        const chunk: Vec32 = haystack[i..][0..32].*;
        const matches = chunk == needle_vec;
        const mask = @as(u32, @bitCast(matches));
        if (mask != 0) {
            return i + @ctz(mask);
        }
    }

    // Process remaining 16 bytes
    if (i + 16 <= len) {
        const needle_vec16: Vec16 = @splat(needle);
        const chunk: Vec16 = haystack[i..][0..16].*;
        const matches = chunk == needle_vec16;
        const mask = @as(u16, @bitCast(matches));
        if (mask != 0) {
            return i + @ctz(mask);
        }
        i += 16;
    }

    // Scalar fallback for remaining bytes
    while (i < len) : (i += 1) {
        if (haystack[i] == needle) return i;
    }

    return null;
}

// Case-insensitive SIMD search
fn simdFindFirstByteCaseInsensitive(haystack: []const u8, needle_lower: u8, needle_upper: u8) ?usize {
    const len = haystack.len;
    var i: usize = 0;

    const lower_vec: Vec32 = @splat(needle_lower);
    const upper_vec: Vec32 = @splat(needle_upper);

    while (i + 32 <= len) : (i += 32) {
        const chunk: Vec32 = haystack[i..][0..32].*;
        const matches_lower = chunk == lower_vec;
        const matches_upper = chunk == upper_vec;
        // Combine with bitwise OR on the u32 masks
        const mask_lower = @as(u32, @bitCast(matches_lower));
        const mask_upper = @as(u32, @bitCast(matches_upper));
        const mask = mask_lower | mask_upper;
        if (mask != 0) {
            return i + @ctz(mask);
        }
    }

    // Scalar fallback
    while (i < len) : (i += 1) {
        const ch = haystack[i];
        if (ch == needle_lower or ch == needle_upper) return i;
    }

    return null;
}

// Full pattern search with SIMD first-byte acceleration
fn searchPattern(haystack: []const u8, pattern: []const u8, ignore_case: bool) ?usize {
    if (pattern.len == 0) return 0;
    if (haystack.len < pattern.len) return null;

    const first_byte = pattern[0];
    var offset: usize = 0;

    if (ignore_case) {
        const lower = toLower(first_byte);
        const upper = toUpper(first_byte);

        while (offset + pattern.len <= haystack.len) {
            const remaining = haystack[offset..];
            const pos = simdFindFirstByteCaseInsensitive(remaining, lower, upper) orelse return null;

            if (offset + pos + pattern.len > haystack.len) return null;

            // Check full pattern match
            if (matchPatternAt(haystack, offset + pos, pattern, ignore_case)) {
                return offset + pos;
            }
            offset += pos + 1;
        }
    } else {
        while (offset + pattern.len <= haystack.len) {
            const remaining = haystack[offset..];
            const pos = simdFindFirstByte(remaining, first_byte) orelse return null;

            if (offset + pos + pattern.len > haystack.len) return null;

            // Check full pattern match
            const candidate = haystack[offset + pos ..][0..pattern.len];
            if (std.mem.eql(u8, candidate, pattern)) {
                return offset + pos;
            }
            offset += pos + 1;
        }
    }

    return null;
}

fn matchPatternAt(haystack: []const u8, pos: usize, pattern: []const u8, ignore_case: bool) bool {
    if (pos + pattern.len > haystack.len) return false;

    if (ignore_case) {
        for (pattern, 0..) |p, i| {
            if (toLower(haystack[pos + i]) != toLower(p)) return false;
        }
        return true;
    } else {
        return std.mem.eql(u8, haystack[pos..][0..pattern.len], pattern);
    }
}

fn isWordChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or
        (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or
        ch == '_';
}

fn isWordBoundary(haystack: []const u8, pos: usize, pattern_len: usize) bool {
    // Check start boundary
    if (pos > 0 and isWordChar(haystack[pos - 1])) return false;
    // Check end boundary
    const end = pos + pattern_len;
    if (end < haystack.len and isWordChar(haystack[end])) return false;
    return true;
}

fn toLower(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

fn toUpper(ch: u8) u8 {
    return if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
}

fn lineContainsSinglePattern(line: []const u8, pattern: []const u8, compiled_regex: ?*CompiledRegex, config: *const Config) bool {
    if (compiled_regex) |regex| {
        const result = regex.search(line, config.ignore_case) orelse return false;
        if (config.line_regexp) {
            return result.start == 0 and result.end == line.len;
        }
        if (config.word_regexp) {
            return isWordBoundary(line, result.start, result.end - result.start);
        }
        return true;
    }

    if (config.line_regexp) {
        // For -x with fixed strings: entire line must match
        if (config.ignore_case) {
            if (line.len != pattern.len) return false;
            for (line, pattern) |a, b| {
                if (toLower(a) != toLower(b)) return false;
            }
            return true;
        }
        return std.mem.eql(u8, line, pattern);
    }

    const pos = searchPattern(line, pattern, config.ignore_case) orelse return false;

    if (config.word_regexp) {
        return isWordBoundary(line, pos, pattern.len);
    }
    return true;
}

fn lineContainsPattern(line: []const u8, config: *const Config) bool {
    // If we have multiple patterns (-e / -f), try each one (OR logic)
    if (config.multi_patterns.items.len > 0) {
        for (config.multi_patterns.items) |entry| {
            if (lineContainsSinglePattern(line, entry.text, entry.compiled_regex, config)) {
                return true;
            }
        }
        return false;
    }

    // Single pattern path
    return lineContainsSinglePattern(line, config.pattern, config.compiled_regex, config);
}

// Simple glob pattern matching for --include/--exclude
fn matchGlob(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star_p: ?usize = null;
    var star_t: usize = 0;

    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == text[t] or pattern[p] == '?')) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star_p = p;
            star_t = t;
            p += 1;
        } else if (star_p) |sp| {
            p = sp + 1;
            star_t += 1;
            t = star_t;
        } else {
            return false;
        }
    }

    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

fn shouldIncludeFile(filename: []const u8, config: *const Config) bool {
    // Get basename for pattern matching
    var basename = filename;
    if (std.mem.lastIndexOf(u8, filename, "/")) |idx| {
        basename = filename[idx + 1 ..];
    }

    // Check exclude patterns first
    for (config.exclude_patterns.items) |pattern| {
        if (matchGlob(pattern, basename)) return false;
    }

    // If include patterns specified, must match at least one
    if (config.include_patterns.items.len > 0) {
        for (config.include_patterns.items) |pattern| {
            if (matchGlob(pattern, basename)) return true;
        }
        return false;
    }

    return true;
}

fn shouldExcludeDir(dirname: []const u8, config: *const Config) bool {
    // Get basename of directory
    var basename = dirname;
    if (std.mem.lastIndexOf(u8, dirname, "/")) |idx| {
        if (idx + 1 < dirname.len) {
            basename = dirname[idx + 1 ..];
        }
    }

    for (config.exclude_dir_patterns.items) |pattern| {
        if (matchGlob(pattern, basename)) return true;
    }
    return false;
}

// Context line buffer for -B (before context)
const ContextBuffer = struct {
    lines: [MAX_CONTEXT_LINES][]const u8,
    line_nums: [MAX_CONTEXT_LINES]usize,
    head: usize,
    count: usize,
    capacity: usize,

    fn init(size: usize) ContextBuffer {
        return .{
            .lines = undefined,
            .line_nums = undefined,
            .head = 0,
            .count = 0,
            .capacity = @min(size, MAX_CONTEXT_LINES),
        };
    }

    fn push(self: *ContextBuffer, line: []const u8, line_num: usize) void {
        if (self.capacity == 0) return;
        const idx = (self.head + self.count) % self.capacity;
        self.lines[idx] = line;
        self.line_nums[idx] = line_num;
        if (self.count < self.capacity) {
            self.count += 1;
        } else {
            self.head = (self.head + 1) % self.capacity;
        }
    }

    fn clear(self: *ContextBuffer) void {
        self.count = 0;
        self.head = 0;
    }

    fn get(self: *const ContextBuffer, idx: usize) ?struct { line: []const u8, num: usize } {
        if (idx >= self.count) return null;
        const real_idx = (self.head + idx) % self.capacity;
        return .{ .line = self.lines[real_idx], .num = self.line_nums[real_idx] };
    }
};

const COLOR_MATCH_START = "\x1b[01;31m";
const COLOR_MATCH_END = "\x1b[m";
const COLOR_FILENAME = "\x1b[35m";
const COLOR_LINE_NUM = "\x1b[32m";
const COLOR_SEP = "\x1b[36m";

/// Find the first match in `line` across all configured patterns.
/// Returns the (start, end) of the leftmost match, or null if none found.
fn findFirstMatch(line: []const u8, config: *const Config) ?MatchResult {
    if (config.multi_patterns.items.len > 0) {
        var best: ?MatchResult = null;
        for (config.multi_patterns.items) |entry| {
            const mr = findFirstMatchSingle(line, entry.text, entry.compiled_regex, config) orelse continue;
            if (best == null or mr.start < best.?.start) {
                best = mr;
            }
        }
        return best;
    }
    return findFirstMatchSingle(line, config.pattern, config.compiled_regex, config);
}

fn findFirstMatchSingle(line: []const u8, pattern: []const u8, compiled_regex: ?*CompiledRegex, config: *const Config) ?MatchResult {
    if (compiled_regex) |regex| {
        return regex.search(line, config.ignore_case);
    }
    const pos = searchPattern(line, pattern, config.ignore_case) orelse return null;
    return MatchResult{ .start = pos, .end = pos + pattern.len };
}

fn writeColorizedLine(writer: anytype, line: []const u8, config: *const Config) void {
    // Write line with color highlighting on matched portions
    var offset: usize = 0;
    while (offset < line.len) {
        const remaining = line[offset..];
        const mr = findFirstMatch(remaining, config) orelse {
            // No more matches, write the rest
            writer.interface.writeAll(remaining) catch {};
            break;
        };

        // Write text before match
        if (mr.start > 0) {
            writer.interface.writeAll(remaining[0..mr.start]) catch {};
        }
        // Write colored match
        writer.interface.writeAll(COLOR_MATCH_START) catch {};
        writer.interface.writeAll(remaining[mr.start..mr.end]) catch {};
        writer.interface.writeAll(COLOR_MATCH_END) catch {};
        offset += mr.end;
        if (mr.start == mr.end) {
            // Zero-length match; output one char to avoid infinite loop
            if (offset < line.len) {
                writer.interface.writeAll(line[offset..][0..1]) catch {};
                offset += 1;
            } else {
                break;
            }
        }
    }
}

fn printMatch(
    writer: anytype,
    filename: []const u8,
    line_num: usize,
    line: []const u8,
    config: *const Config,
    multiple_files: bool,
) void {
    // Print filename if needed
    if (config.with_filename or (multiple_files and !config.no_filename)) {
        if (config.use_color) {
            writer.interface.writeAll(COLOR_FILENAME) catch {};
            writer.interface.writeAll(filename) catch {};
            writer.interface.writeAll(COLOR_MATCH_END) catch {};
            writer.interface.writeAll(COLOR_SEP) catch {};
            writer.interface.writeAll(":") catch {};
            writer.interface.writeAll(COLOR_MATCH_END) catch {};
        } else {
            writer.interface.print("{s}:", .{filename}) catch {};
        }
    }

    // Print line number if requested
    if (config.line_numbers) {
        if (config.use_color) {
            writer.interface.writeAll(COLOR_LINE_NUM) catch {};
            writer.interface.print("{d}", .{line_num}) catch {};
            writer.interface.writeAll(COLOR_MATCH_END) catch {};
            writer.interface.writeAll(COLOR_SEP) catch {};
            writer.interface.writeAll(":") catch {};
            writer.interface.writeAll(COLOR_MATCH_END) catch {};
        } else {
            writer.interface.print("{d}:", .{line_num}) catch {};
        }
    }

    // Print the line (or just matching part)
    if (config.only_matching) {
        // Find and print all matches in the line
        var offset: usize = 0;
        if (config.multi_patterns.items.len > 0) {
            while (offset < line.len) {
                const remaining = line[offset..];
                const result = findFirstMatch(remaining, config) orelse break;
                const match_len = result.end - result.start;

                if (config.word_regexp and !isWordBoundary(line, offset + result.start, match_len)) {
                    offset += result.start + 1;
                    continue;
                }

                if (config.use_color) {
                    writer.interface.writeAll(COLOR_MATCH_START) catch {};
                }
                writer.interface.writeAll(remaining[result.start..result.end]) catch {};
                if (config.use_color) {
                    writer.interface.writeAll(COLOR_MATCH_END) catch {};
                }
                writer.interface.writeAll("\n") catch {};
                offset += result.end;
                if (result.start == result.end) offset += 1;
            }
        } else if (config.compiled_regex) |regex| {
            while (offset < line.len) {
                const remaining = line[offset..];
                const result = regex.search(remaining, config.ignore_case) orelse break;
                const match_len = result.end - result.start;

                if (config.word_regexp and !isWordBoundary(line, offset + result.start, match_len)) {
                    offset += result.start + 1;
                    continue;
                }

                if (config.use_color) {
                    writer.interface.writeAll(COLOR_MATCH_START) catch {};
                }
                writer.interface.writeAll(remaining[result.start..result.end]) catch {};
                if (config.use_color) {
                    writer.interface.writeAll(COLOR_MATCH_END) catch {};
                }
                writer.interface.writeAll("\n") catch {};
                offset += result.end;
                if (result.start == result.end) offset += 1; // avoid infinite loop on zero-length match
            }
        } else {
            while (offset < line.len) {
                const remaining = line[offset..];
                const pos = searchPattern(remaining, config.pattern, config.ignore_case) orelse break;

                if (config.word_regexp and !isWordBoundary(line, offset + pos, config.pattern.len)) {
                    offset += pos + 1;
                    continue;
                }

                if (config.use_color) {
                    writer.interface.writeAll(COLOR_MATCH_START) catch {};
                }
                writer.interface.writeAll(remaining[pos..][0..config.pattern.len]) catch {};
                if (config.use_color) {
                    writer.interface.writeAll(COLOR_MATCH_END) catch {};
                }
                writer.interface.writeAll("\n") catch {};
                offset += pos + config.pattern.len;
            }
        }
    } else {
        if (config.use_color) {
            writeColorizedLine(writer, line, config);
        } else {
            writer.interface.writeAll(line) catch {};
        }
        writer.interface.writeAll("\n") catch {};
    }
}

fn printContextLine(
    writer: anytype,
    filename: []const u8,
    line_num: usize,
    line: []const u8,
    config: *const Config,
    multiple_files: bool,
    is_match: bool,
) void {
    const sep_char: []const u8 = if (is_match) ":" else "-";

    // Print filename if needed
    if (config.with_filename or (multiple_files and !config.no_filename)) {
        if (config.use_color) {
            writer.interface.writeAll(COLOR_FILENAME) catch {};
            writer.interface.writeAll(filename) catch {};
            writer.interface.writeAll(COLOR_MATCH_END) catch {};
            writer.interface.writeAll(COLOR_SEP) catch {};
            writer.interface.writeAll(sep_char) catch {};
            writer.interface.writeAll(COLOR_MATCH_END) catch {};
        } else {
            writer.interface.print("{s}", .{filename}) catch {};
            writer.interface.writeAll(sep_char) catch {};
        }
    }

    // Print line number if requested
    if (config.line_numbers) {
        if (config.use_color) {
            writer.interface.writeAll(COLOR_LINE_NUM) catch {};
            writer.interface.print("{d}", .{line_num}) catch {};
            writer.interface.writeAll(COLOR_MATCH_END) catch {};
            writer.interface.writeAll(COLOR_SEP) catch {};
            writer.interface.writeAll(sep_char) catch {};
            writer.interface.writeAll(COLOR_MATCH_END) catch {};
        } else {
            writer.interface.print("{d}", .{line_num}) catch {};
            writer.interface.writeAll(sep_char) catch {};
        }
    }

    // For matching lines, colorize the matched text
    if (is_match and config.use_color) {
        writeColorizedLine(writer, line, config);
    } else {
        writer.interface.writeAll(line) catch {};
    }
    writer.interface.writeAll("\n") catch {};
}

fn grepFile(allocator: std.mem.Allocator, path: []const u8, config: *const Config, multiple_files: bool) !GrepResult {
    const io_ctx = Io.Threaded.global_single_threaded.io();
    const stdout = Io.File.stdout();
    var out_buf: [4096]u8 = undefined;
    var writer = stdout.writer(io_ctx, &out_buf);

    var matches: usize = 0;
    var had_match = false;
    const has_context = config.before_context > 0 or config.after_context > 0;

    // Open file
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fd_result = linux.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(fd_result)) < 0) {
        if (!config.quiet and !config.suppress_errors) {
            std.debug.print("zgrep: {s}: No such file or directory\n", .{path});
        }
        return error.OpenError;
    }
    const fd: i32 = @intCast(fd_result);
    defer _ = linux.close(fd);

    // Context tracking
    var before_buf = ContextBuffer.init(config.before_context);
    var after_remaining: usize = 0; // Lines remaining to print after a match
    var last_printed_line: usize = 0; // Last line number we printed
    var need_separator = false; // Need to print "--" before next group

    // Line storage for before context - use a simple array of allocations
    var line_storage: [MAX_CONTEXT_LINES][]const u8 = undefined;
    var storage_count: usize = 0;
    defer {
        for (line_storage[0..storage_count]) |s| allocator.free(@constCast(s));
    }

    // Process file
    var line_num: usize = 0;
    var buffer: [BUFFER_SIZE]u8 = undefined;
    var leftover: []u8 = &.{};
    var leftover_buf: [8192]u8 = undefined;

    while (true) {
        const read_result = linux.read(@intCast(fd), &buffer, buffer.len);
        if (@as(isize, @bitCast(read_result)) <= 0) break;
        const bytes_read: usize = @intCast(read_result);
        if (bytes_read == 0) break;

        // Combine leftover with new data
        var data: []const u8 = undefined;
        var combined_buf: [BUFFER_SIZE + 8192]u8 = undefined;
        if (leftover.len > 0) {
            @memcpy(combined_buf[0..leftover.len], leftover);
            @memcpy(combined_buf[leftover.len..][0..bytes_read], buffer[0..bytes_read]);
            data = combined_buf[0 .. leftover.len + bytes_read];
            leftover = &.{};
        } else {
            data = buffer[0..bytes_read];
        }

        // Process lines
        var start: usize = 0;
        for (data, 0..) |ch, idx| {
            if (ch == '\n') {
                const line = data[start..idx];
                line_num += 1;

                const contains = lineContainsPattern(line, config);
                const is_match = if (config.invert_match) !contains else contains;

                if (is_match) {
                    had_match = true;
                    matches += 1;

                    // Check max count
                    if (config.max_count > 0 and matches > config.max_count) {
                        writer.interface.flush() catch {};
                        return .{ .matches = matches - 1, .had_match = true };
                    }

                    if (config.quiet) {
                        writer.interface.flush() catch {};
                        return .{ .matches = matches, .had_match = true };
                    }

                    if (config.files_with_matches) {
                        writer.interface.print("{s}\n", .{path}) catch {};
                        writer.interface.flush() catch {};
                        return .{ .matches = matches, .had_match = true };
                    }

                    if (!config.count_only and !config.files_without_match) {
                        // Print separator if needed (gap between groups)
                        if (has_context and need_separator and last_printed_line > 0 and
                            line_num > last_printed_line + 1)
                        {
                            writer.interface.writeAll("--\n") catch {};
                        }
                        need_separator = true;

                        // Print before context lines
                        if (config.before_context > 0) {
                            var i: usize = 0;
                            while (before_buf.get(i)) |ctx| {
                                if (ctx.num > last_printed_line) {
                                    printContextLine(&writer, path, ctx.num, ctx.line, config, multiple_files, false);
                                    last_printed_line = ctx.num;
                                }
                                i += 1;
                            }
                        }

                        // Print the matching line
                        if (config.only_matching) {
                            printMatch(&writer, path, line_num, line, config, multiple_files);
                        } else {
                            printContextLine(&writer, path, line_num, line, config, multiple_files, true);
                        }
                        last_printed_line = line_num;

                        // Reset after context counter
                        after_remaining = config.after_context;
                    }
                } else if (after_remaining > 0 and !config.count_only and !config.files_without_match and !config.quiet) {
                    // Print after context line
                    printContextLine(&writer, path, line_num, line, config, multiple_files, false);
                    last_printed_line = line_num;
                    after_remaining -= 1;
                }

                // Store line in before context buffer
                if (config.before_context > 0) {
                    // Free old line if buffer is full
                    if (storage_count >= config.before_context and storage_count > 0) {
                        // Rotate: free oldest, shift down
                        if (before_buf.count > 0) {
                            // The oldest stored line can be freed if it's been pushed out
                        }
                    }
                    // Store a copy of this line
                    if (storage_count < MAX_CONTEXT_LINES) {
                        const line_copy = allocator.dupe(u8, line) catch line;
                        if (line_copy.ptr != line.ptr) {
                            line_storage[storage_count] = line_copy;
                            storage_count += 1;
                            before_buf.push(line_copy, line_num);
                        }
                    } else {
                        // Reuse oldest slot
                        const oldest_idx = storage_count % MAX_CONTEXT_LINES;
                        allocator.free(@constCast(line_storage[oldest_idx]));
                        const line_copy = allocator.dupe(u8, line) catch continue;
                        line_storage[oldest_idx] = line_copy;
                        before_buf.push(line_copy, line_num);
                    }
                }

                start = idx + 1;
            }
        }

        // Save leftover (incomplete line)
        if (start < data.len) {
            const remaining = data.len - start;
            if (remaining <= leftover_buf.len) {
                @memcpy(leftover_buf[0..remaining], data[start..]);
                leftover = leftover_buf[0..remaining];
            }
        }
    }

    // Process final leftover (file without trailing newline)
    if (leftover.len > 0) {
        line_num += 1;
        const contains = lineContainsPattern(leftover, config);
        const is_match = if (config.invert_match) !contains else contains;

        if (is_match) {
            had_match = true;
            matches += 1;

            if (!config.quiet and !config.count_only and !config.files_with_matches and !config.files_without_match) {
                if (config.max_count == 0 or matches <= config.max_count) {
                    // Print separator if needed
                    if (has_context and need_separator and last_printed_line > 0 and
                        line_num > last_printed_line + 1)
                    {
                        writer.interface.writeAll("--\n") catch {};
                    }

                    // Print before context
                    if (config.before_context > 0) {
                        var i: usize = 0;
                        while (before_buf.get(i)) |ctx| {
                            if (ctx.num > last_printed_line) {
                                printContextLine(&writer, path, ctx.num, ctx.line, config, multiple_files, false);
                            }
                            i += 1;
                        }
                    }

                    if (config.only_matching) {
                        printMatch(&writer, path, line_num, leftover, config, multiple_files);
                    } else {
                        printContextLine(&writer, path, line_num, leftover, config, multiple_files, true);
                    }
                }
            }
        } else if (after_remaining > 0 and !config.count_only and !config.files_without_match and !config.quiet) {
            printContextLine(&writer, path, line_num, leftover, config, multiple_files, false);
        }
    }

    // Print count if requested
    if (config.count_only and !config.quiet) {
        if (config.with_filename or (multiple_files and !config.no_filename)) {
            writer.interface.print("{s}:{d}\n", .{ path, matches }) catch {};
        } else {
            writer.interface.print("{d}\n", .{matches}) catch {};
        }
    }

    // Print filename for -L
    if (config.files_without_match and !had_match and !config.quiet) {
        writer.interface.print("{s}\n", .{path}) catch {};
    }

    writer.interface.flush() catch {};
    return .{ .matches = matches, .had_match = had_match };
}

fn grepRecursive(allocator: std.mem.Allocator, path: []const u8, config: *const Config, results: *GrepResult) void {
    const path_z = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(path_z);

    const dir = libc.opendir(path_z.ptr) orelse {
        // Not a directory, try as file
        if (!shouldIncludeFile(path, config)) return;
        const result = grepFile(allocator, path, config, true) catch return;
        results.matches += result.matches;
        if (result.had_match) results.had_match = true;
        return;
    };
    defer _ = libc.closedir(dir);

    while (true) {
        const entry = libc.readdir(dir) orelse break;

        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.span(name_ptr);

        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, name }) catch continue;
        defer allocator.free(full_path);

        // Check if directory
        const full_path_z = allocator.dupeZ(u8, full_path) catch continue;
        defer allocator.free(full_path_z);

        var statx_buf: linux.Statx = undefined;
        const stat_result = linux.statx(linux.AT.FDCWD, full_path_z.ptr, 0, linux.STATX{ .MODE = true }, &statx_buf);

        if (stat_result == 0) {
            const is_dir = (statx_buf.mode & 0o170000) == 0o40000;
            if (is_dir) {
                // Check exclude-dir patterns
                if (!shouldExcludeDir(full_path, config)) {
                    grepRecursive(allocator, full_path, config, results);
                }
            } else {
                // Check include/exclude patterns
                if (shouldIncludeFile(full_path, config)) {
                    const result = grepFile(allocator, full_path, config, true) catch continue;
                    results.matches += result.matches;
                    if (result.had_match) results.had_match = true;
                }
            }
        }
    }
}

fn parseNumArg(args: []const []const u8, i: *usize) ?usize {
    if (i.* + 1 < args.len) {
        i.* += 1;
        return std.fmt.parseInt(usize, args[i.*], 10) catch null;
    }
    return null;
}

fn addPatternEntry(allocator: std.mem.Allocator, config: *Config, pat: []const u8) !void {
    const text = try allocator.dupe(u8, pat);
    var compiled: ?*CompiledRegex = null;
    if (!config.fixed_strings) {
        compiled = CompiledRegex.compile(allocator, pat) catch {
            std.debug.print("zgrep: invalid regular expression\n", .{});
            std.process.exit(2);
        };
    }
    try config.multi_patterns.append(allocator, .{
        .text = text,
        .compiled_regex = compiled,
    });
}

fn loadPatternsFromFile(allocator: std.mem.Allocator, config: *Config, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fd_result = linux.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(fd_result)) < 0) {
        std.debug.print("zgrep: {s}: No such file or directory\n", .{path});
        std.process.exit(2);
    }
    const fd: i32 = @intCast(fd_result);
    defer _ = linux.close(fd);

    // Read the whole file (pattern files are typically small)
    var buf: [65536]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const read_result = linux.read(fd, buf[total..].ptr, buf.len - total);
        const n: isize = @bitCast(read_result);
        if (n <= 0) break;
        total += @intCast(read_result);
    }

    const data = buf[0..total];
    var start: usize = 0;
    for (data, 0..) |ch, idx| {
        if (ch == '\n') {
            const line = data[start..idx];
            try addPatternEntry(allocator, config, line);
            start = idx + 1;
        }
    }
    // Handle last line without trailing newline
    if (start < data.len) {
        const line = data[start..];
        try addPatternEntry(allocator, config, line);
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
    var pattern_found = false;
    var has_e_flag = false; // Whether -e was used (changes arg parsing)

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // When -e is used, all non-option args are files (no positional pattern).
        // Options are recognized as long as the arg starts with '-'.
        const is_option = arg.len > 0 and arg[0] == '-' and arg.len > 1;

        if (is_option) {
            if (arg.len > 1 and arg[1] == '-') {
                if (std.mem.eql(u8, arg, "--")) {
                    // End of options, rest are files
                    i += 1;
                    while (i < args.len) : (i += 1) {
                        if (!pattern_found and !has_e_flag) {
                            config.pattern = try allocator.dupe(u8, args[i]);
                            pattern_found = true;
                        } else {
                            try config.files.append(allocator, try allocator.dupe(u8, args[i]));
                        }
                    }
                    break;
                } else if (std.mem.eql(u8, arg, "--help")) {
                    printHelp();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--version")) {
                    printVersion();
                    std.process.exit(0);
                } else if (std.mem.eql(u8, arg, "--ignore-case")) {
                    config.ignore_case = true;
                } else if (std.mem.eql(u8, arg, "--invert-match")) {
                    config.invert_match = true;
                } else if (std.mem.eql(u8, arg, "--count")) {
                    config.count_only = true;
                } else if (std.mem.eql(u8, arg, "--line-number")) {
                    config.line_numbers = true;
                } else if (std.mem.eql(u8, arg, "--files-with-matches")) {
                    config.files_with_matches = true;
                } else if (std.mem.eql(u8, arg, "--files-without-match")) {
                    config.files_without_match = true;
                } else if (std.mem.eql(u8, arg, "--with-filename")) {
                    config.with_filename = true;
                } else if (std.mem.eql(u8, arg, "--no-filename")) {
                    config.no_filename = true;
                } else if (std.mem.eql(u8, arg, "--recursive")) {
                    config.recursive = true;
                } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "--silent")) {
                    config.quiet = true;
                } else if (std.mem.eql(u8, arg, "--only-matching")) {
                    config.only_matching = true;
                } else if (std.mem.eql(u8, arg, "--fixed-strings")) {
                    config.fixed_strings = true;
                } else if (std.mem.eql(u8, arg, "--extended-regexp")) {
                    config.extended_regex = true;
                } else if (std.mem.eql(u8, arg, "--word-regexp")) {
                    config.word_regexp = true;
                } else if (std.mem.eql(u8, arg, "--line-regexp")) {
                    config.line_regexp = true;
                } else if (std.mem.eql(u8, arg, "--no-messages")) {
                    config.suppress_errors = true;
                } else if (std.mem.startsWith(u8, arg, "--after-context=")) {
                    config.after_context = std.fmt.parseInt(usize, arg[16..], 10) catch 0;
                } else if (std.mem.startsWith(u8, arg, "--before-context=")) {
                    config.before_context = std.fmt.parseInt(usize, arg[17..], 10) catch 0;
                } else if (std.mem.startsWith(u8, arg, "--context=")) {
                    const ctx = std.fmt.parseInt(usize, arg[10..], 10) catch 0;
                    config.before_context = ctx;
                    config.after_context = ctx;
                } else if (std.mem.startsWith(u8, arg, "--max-count=")) {
                    config.max_count = std.fmt.parseInt(usize, arg[12..], 10) catch 0;
                } else if (std.mem.startsWith(u8, arg, "--include=")) {
                    try config.include_patterns.append(allocator, try allocator.dupe(u8, arg[10..]));
                } else if (std.mem.startsWith(u8, arg, "--exclude=")) {
                    try config.exclude_patterns.append(allocator, try allocator.dupe(u8, arg[10..]));
                } else if (std.mem.startsWith(u8, arg, "--exclude-dir=")) {
                    try config.exclude_dir_patterns.append(allocator, try allocator.dupe(u8, arg[14..]));
                } else if (std.mem.eql(u8, arg, "--color") or std.mem.eql(u8, arg, "--colour")) {
                    config.color_mode = .always;
                } else if (std.mem.startsWith(u8, arg, "--color=") or std.mem.startsWith(u8, arg, "--colour=")) {
                    const eq_pos = std.mem.indexOfScalar(u8, arg, '=').?;
                    const val = arg[eq_pos + 1 ..];
                    if (std.mem.eql(u8, val, "always")) {
                        config.color_mode = .always;
                    } else if (std.mem.eql(u8, val, "never")) {
                        config.color_mode = .never;
                    } else if (std.mem.eql(u8, val, "auto")) {
                        config.color_mode = .auto;
                    }
                } else if (std.mem.startsWith(u8, arg, "--regexp=")) {
                    const pat = arg[9..];
                    try addPatternEntry(allocator, &config, pat);
                    has_e_flag = true;
                    pattern_found = true;
                } else {
                    std.debug.print("zgrep: unrecognized option '{s}'\n", .{arg});
                    std.process.exit(2);
                }
            } else {
                // Handle short options, some need arguments
                var j: usize = 1;
                while (j < arg.len) : (j += 1) {
                    const ch = arg[j];
                    switch (ch) {
                        'i' => config.ignore_case = true,
                        'v' => config.invert_match = true,
                        'c' => config.count_only = true,
                        'n' => config.line_numbers = true,
                        'l' => config.files_with_matches = true,
                        'L' => config.files_without_match = true,
                        'H' => config.with_filename = true,
                        'h' => config.no_filename = true,
                        'r', 'R' => config.recursive = true,
                        'q' => config.quiet = true,
                        'o' => config.only_matching = true,
                        'F' => config.fixed_strings = true,
                        'E' => config.extended_regex = true,
                        'w' => config.word_regexp = true,
                        'x' => config.line_regexp = true,
                        's' => config.suppress_errors = true,
                        'e' => {
                            // -e PATTERN or -ePATTERN
                            var pat: []const u8 = undefined;
                            if (j + 1 < arg.len) {
                                pat = arg[j + 1 ..];
                            } else if (i + 1 < args.len) {
                                i += 1;
                                pat = args[i];
                            } else {
                                std.debug.print("zgrep: option requires an argument -- 'e'\n", .{});
                                std.process.exit(2);
                            }
                            try addPatternEntry(allocator, &config, pat);
                            has_e_flag = true;
                            pattern_found = true;
                            break; // consumed rest of short opt cluster
                        },
                        'f' => {
                            // -f FILE or -fFILE
                            var file_path: []const u8 = undefined;
                            if (j + 1 < arg.len) {
                                file_path = arg[j + 1 ..];
                            } else if (i + 1 < args.len) {
                                i += 1;
                                file_path = args[i];
                            } else {
                                std.debug.print("zgrep: option requires an argument -- 'f'\n", .{});
                                std.process.exit(2);
                            }
                            try loadPatternsFromFile(allocator, &config, file_path);
                            has_e_flag = true; // treat like -e: remaining positional args are files
                            pattern_found = true;
                            break;
                        },
                        'A' => {
                            // -A NUM or -ANUM
                            if (j + 1 < arg.len) {
                                config.after_context = std.fmt.parseInt(usize, arg[j + 1 ..], 10) catch 0;
                                break;
                            } else if (parseNumArg(args, &i)) |num| {
                                config.after_context = num;
                            }
                        },
                        'B' => {
                            if (j + 1 < arg.len) {
                                config.before_context = std.fmt.parseInt(usize, arg[j + 1 ..], 10) catch 0;
                                break;
                            } else if (parseNumArg(args, &i)) |num| {
                                config.before_context = num;
                            }
                        },
                        'C' => {
                            if (j + 1 < arg.len) {
                                const ctx = std.fmt.parseInt(usize, arg[j + 1 ..], 10) catch 0;
                                config.before_context = ctx;
                                config.after_context = ctx;
                                break;
                            } else if (parseNumArg(args, &i)) |num| {
                                config.before_context = num;
                                config.after_context = num;
                            }
                        },
                        'm' => {
                            if (j + 1 < arg.len) {
                                config.max_count = std.fmt.parseInt(usize, arg[j + 1 ..], 10) catch 0;
                                break;
                            } else if (parseNumArg(args, &i)) |num| {
                                config.max_count = num;
                            }
                        },
                        else => {
                            std.debug.print("zgrep: invalid option -- '{c}'\n", .{ch});
                            std.process.exit(2);
                        },
                    }
                }
            }
        } else if (!pattern_found) {
            config.pattern = try allocator.dupe(u8, arg);
            pattern_found = true;

            // Pre-compute lowercase pattern for case-insensitive matching
            if (config.ignore_case) {
                config.pattern_lower = try allocator.alloc(u8, arg.len);
                for (arg, 0..) |ch, idx| {
                    config.pattern_lower[idx] = toLower(ch);
                }
            }

            // Compile regex unless -F (fixed strings) specified
            if (!config.fixed_strings) {
                config.compiled_regex = CompiledRegex.compile(allocator, arg) catch {
                    std.debug.print("zgrep: invalid regular expression\n", .{});
                    std.process.exit(2);
                };
            }
        } else {
            try config.files.append(allocator, try allocator.dupe(u8, arg));
        }
    }

    if (!pattern_found) {
        std.debug.print("zgrep: missing pattern\n", .{});
        std.debug.print("Try 'zgrep --help' for more information.\n", .{});
        std.process.exit(2);
    }

    // Default to stdin if no files
    if (config.files.items.len == 0 and !config.recursive) {
        try config.files.append(allocator, try allocator.dupe(u8, "-"));
    }

    // Resolve color: check if stdout is a tty
    switch (config.color_mode) {
        .always => config.use_color = true,
        .never => config.use_color = false,
        .auto => {
            // Check if stdout is a tty using isatty
            config.use_color = (libc.isatty(1) != 0);
        },
    }
    // Disable color for modes that don't print lines
    if (config.count_only or config.files_with_matches or config.files_without_match or config.quiet) {
        config.use_color = false;
    }

    return config;
}

fn printHelp() void {
    const io_ctx = Io.Threaded.global_single_threaded.io();
    const stdout = Io.File.stdout();
    var buf: [4096]u8 = undefined;
    var writer = stdout.writer(io_ctx, &buf);
    writer.interface.writeAll(
        \\Usage: zgrep [OPTION]... PATTERN [FILE]...
        \\Search for PATTERN in each FILE.
        \\
        \\Pattern selection:
        \\  -E, --extended-regexp  PATTERN is an extended regular expression
        \\  -F, --fixed-strings    PATTERN is a literal string (default)
        \\  -e, --regexp=PATTERN   use PATTERN for matching (may be repeated)
        \\  -f, --file=FILE        obtain patterns from FILE, one per line
        \\  -i, --ignore-case      ignore case distinctions
        \\  -w, --word-regexp      match whole words only
        \\
        \\Matching control:
        \\  -v, --invert-match     select non-matching lines
        \\  -m, --max-count=NUM    stop after NUM matches
        \\
        \\Output control:
        \\  -c, --count            print only count of matching lines
        \\  -n, --line-number      print line number with output
        \\  -H, --with-filename    print filename with output
        \\  -h, --no-filename      suppress filename prefix
        \\  -l, --files-with-matches  print only filenames with matches
        \\  -L, --files-without-match print only filenames without matches
        \\  -o, --only-matching    print only the matched parts
        \\  -q, --quiet            suppress all output
        \\  -s, --no-messages      suppress error messages
        \\      --color[=WHEN]     use markers to highlight matching strings
        \\                         WHEN is 'always', 'never', or 'auto'
        \\
        \\Context control:
        \\  -A, --after-context=NUM   print NUM lines of trailing context
        \\  -B, --before-context=NUM  print NUM lines of leading context
        \\  -C, --context=NUM         print NUM lines of context
        \\
        \\File and directory selection:
        \\  -r, -R, --recursive    search directories recursively
        \\  --include=GLOB         search only files matching GLOB
        \\  --exclude=GLOB         skip files matching GLOB
        \\  --exclude-dir=GLOB     skip directories matching GLOB
        \\
        \\      --help             display this help
        \\      --version          output version information
        \\
        \\Regex syntax (-E): . * + ? | [] [^] ^ $ \d \w \s \b
        \\
        \\Exit status: 0 if match found, 1 if no match, 2 if error.
        \\
        \\zgrep - High-performance grep with SIMD string search
        \\
    ) catch {};
    writer.interface.flush() catch {};
}

fn printVersion() void {
    const io_ctx = Io.Threaded.global_single_threaded.io();
    const stdout = Io.File.stdout();
    var buf: [64]u8 = undefined;
    var writer = stdout.writer(io_ctx, &buf);
    writer.interface.writeAll("zgrep 0.1.0\n") catch {};
    writer.interface.flush() catch {};
}

fn grepStdin(allocator: std.mem.Allocator, config: *const Config) !GrepResult {
    const io_ctx = Io.Threaded.global_single_threaded.io();
    const stdout = Io.File.stdout();
    var out_buf: [4096]u8 = undefined;
    var writer = stdout.writer(io_ctx, &out_buf);

    var matches: usize = 0;
    var had_match = false;
    var line_num: usize = 0;

    // Context tracking
    const has_context = config.before_context > 0 or config.after_context > 0;
    var before_buf = ContextBuffer.init(config.before_context);
    var after_remaining: usize = 0;
    var last_printed_line: usize = 0;
    var need_separator = false;

    // Line storage for before context
    var line_storage: [MAX_CONTEXT_LINES][]const u8 = undefined;
    var storage_count: usize = 0;
    defer {
        for (line_storage[0..storage_count]) |s| allocator.free(@constCast(s));
    }

    var buffer: [BUFFER_SIZE]u8 = undefined;
    var leftover: []u8 = &.{};
    var leftover_buf: [8192]u8 = undefined;

    while (true) {
        const read_result = linux.read(linux.STDIN_FILENO, &buffer, buffer.len);
        if (@as(isize, @bitCast(read_result)) <= 0) break;
        const bytes_read: usize = @intCast(read_result);
        if (bytes_read == 0) break;

        // Combine leftover with new data
        var data: []const u8 = undefined;
        var combined_buf: [BUFFER_SIZE + 8192]u8 = undefined;
        if (leftover.len > 0) {
            @memcpy(combined_buf[0..leftover.len], leftover);
            @memcpy(combined_buf[leftover.len..][0..bytes_read], buffer[0..bytes_read]);
            data = combined_buf[0 .. leftover.len + bytes_read];
            leftover = &.{};
        } else {
            data = buffer[0..bytes_read];
        }

        // Process lines
        var start: usize = 0;
        for (data, 0..) |ch, i| {
            if (ch == '\n') {
                const line = data[start..i];
                line_num += 1;

                const contains = lineContainsPattern(line, config);
                const is_match = if (config.invert_match) !contains else contains;

                if (is_match) {
                    had_match = true;
                    matches += 1;

                    if (config.quiet) {
                        writer.interface.flush() catch {};
                        return .{ .matches = matches, .had_match = true };
                    }

                    if (!config.count_only) {
                        // Print separator if needed (gap between groups)
                        if (has_context and need_separator and last_printed_line > 0 and
                            line_num > last_printed_line + 1)
                        {
                            writer.interface.writeAll("--\n") catch {};
                        }
                        need_separator = true;

                        // Print before context lines
                        if (config.before_context > 0) {
                            var ctx_i: usize = 0;
                            while (before_buf.get(ctx_i)) |ctx| {
                                if (ctx.num > last_printed_line) {
                                    if (config.line_numbers) {
                                        if (config.use_color) {
                                            writer.interface.writeAll(COLOR_LINE_NUM) catch {};
                                            writer.interface.print("{d}", .{ctx.num}) catch {};
                                            writer.interface.writeAll(COLOR_MATCH_END) catch {};
                                            writer.interface.writeAll(COLOR_SEP) catch {};
                                            writer.interface.writeAll("-") catch {};
                                            writer.interface.writeAll(COLOR_MATCH_END) catch {};
                                        } else {
                                            writer.interface.print("{d}-", .{ctx.num}) catch {};
                                        }
                                    }
                                    writer.interface.writeAll(ctx.line) catch {};
                                    writer.interface.writeAll("\n") catch {};
                                    last_printed_line = ctx.num;
                                }
                                ctx_i += 1;
                            }
                        }

                        // Print the matching line (or just matched parts for -o)
                        if (config.only_matching) {
                            var mo: usize = 0;
                            while (mo < line.len) {
                                const rem = line[mo..];
                                const mresult = findFirstMatch(rem, config) orelse break;
                                if (config.line_numbers) {
                                    if (config.use_color) {
                                        writer.interface.writeAll(COLOR_LINE_NUM) catch {};
                                        writer.interface.print("{d}", .{line_num}) catch {};
                                        writer.interface.writeAll(COLOR_MATCH_END) catch {};
                                        writer.interface.writeAll(COLOR_SEP) catch {};
                                        writer.interface.writeAll(":") catch {};
                                        writer.interface.writeAll(COLOR_MATCH_END) catch {};
                                    } else {
                                        writer.interface.print("{d}:", .{line_num}) catch {};
                                    }
                                }
                                if (config.use_color) {
                                    writer.interface.writeAll(COLOR_MATCH_START) catch {};
                                }
                                writer.interface.writeAll(rem[mresult.start..mresult.end]) catch {};
                                if (config.use_color) {
                                    writer.interface.writeAll(COLOR_MATCH_END) catch {};
                                }
                                writer.interface.writeAll("\n") catch {};
                                mo += mresult.end;
                                if (mresult.start == mresult.end) mo += 1;
                            }
                        } else {
                            if (config.line_numbers) {
                                if (config.use_color) {
                                    writer.interface.writeAll(COLOR_LINE_NUM) catch {};
                                    writer.interface.print("{d}", .{line_num}) catch {};
                                    writer.interface.writeAll(COLOR_MATCH_END) catch {};
                                    writer.interface.writeAll(COLOR_SEP) catch {};
                                    writer.interface.writeAll(":") catch {};
                                    writer.interface.writeAll(COLOR_MATCH_END) catch {};
                                } else {
                                    writer.interface.print("{d}:", .{line_num}) catch {};
                                }
                            }
                            if (config.use_color) {
                                writeColorizedLine(&writer, line, config);
                            } else {
                                writer.interface.writeAll(line) catch {};
                            }
                            writer.interface.writeAll("\n") catch {};
                        }
                        last_printed_line = line_num;

                        // Reset after context counter
                        after_remaining = config.after_context;
                    }
                } else if (after_remaining > 0 and !config.count_only and !config.quiet) {
                    // Print after context line
                    if (config.line_numbers) {
                        if (config.use_color) {
                            writer.interface.writeAll(COLOR_LINE_NUM) catch {};
                            writer.interface.print("{d}", .{line_num}) catch {};
                            writer.interface.writeAll(COLOR_MATCH_END) catch {};
                            writer.interface.writeAll(COLOR_SEP) catch {};
                            writer.interface.writeAll("-") catch {};
                            writer.interface.writeAll(COLOR_MATCH_END) catch {};
                        } else {
                            writer.interface.print("{d}-", .{line_num}) catch {};
                        }
                    }
                    writer.interface.writeAll(line) catch {};
                    writer.interface.writeAll("\n") catch {};
                    last_printed_line = line_num;
                    after_remaining -= 1;
                }

                // Store line in before context buffer
                if (config.before_context > 0) {
                    if (storage_count < MAX_CONTEXT_LINES) {
                        const line_copy = allocator.dupe(u8, line) catch line;
                        if (line_copy.ptr != line.ptr) {
                            line_storage[storage_count] = line_copy;
                            storage_count += 1;
                            before_buf.push(line_copy, line_num);
                        }
                    } else {
                        // Reuse oldest slot
                        const oldest_idx = storage_count % MAX_CONTEXT_LINES;
                        allocator.free(@constCast(line_storage[oldest_idx]));
                        const line_copy = allocator.dupe(u8, line) catch {
                            start = i + 1;
                            continue;
                        };
                        line_storage[oldest_idx] = line_copy;
                        before_buf.push(line_copy, line_num);
                    }
                }

                start = i + 1;
            }
        }

        // Save leftover
        if (start < data.len) {
            const remaining = data.len - start;
            if (remaining <= leftover_buf.len) {
                @memcpy(leftover_buf[0..remaining], data[start..]);
                leftover = leftover_buf[0..remaining];
            }
        }
    }

    if (config.count_only and !config.quiet) {
        writer.interface.print("{d}\n", .{matches}) catch {};
    }

    writer.interface.flush() catch {};
    return .{ .matches = matches, .had_match = had_match };
}

pub fn main(init: std.process.Init) void {
    const allocator = init.gpa;

    var config = parseArgs(allocator, init.minimal.args) catch {
        std.process.exit(2);
    };
    defer config.deinit(allocator);

    var total_matches: usize = 0;
    var had_any_match = false;
    var had_error = false;
    const multiple_files = config.files.items.len > 1 or config.recursive;

    if (config.recursive and config.files.items.len == 0) {
        // Search current directory
        var results = GrepResult{ .matches = 0, .had_match = false };
        grepRecursive(allocator, ".", &config, &results);
        total_matches = results.matches;
        had_any_match = results.had_match;
    } else {
        for (config.files.items) |file| {
            if (std.mem.eql(u8, file, "-")) {
                const result = grepStdin(allocator, &config) catch continue;
                total_matches += result.matches;
                if (result.had_match) had_any_match = true;
            } else if (config.recursive) {
                var results = GrepResult{ .matches = 0, .had_match = false };
                grepRecursive(allocator, file, &config, &results);
                total_matches += results.matches;
                if (results.had_match) had_any_match = true;
            } else {
                const result = grepFile(allocator, file, &config, multiple_files) catch {
                    had_error = true;
                    continue;
                };
                total_matches += result.matches;
                if (result.had_match) had_any_match = true;
            }
        }
    }

    // Exit status: 0 if match, 1 if no match, 2 if error
    if (had_error and !had_any_match) {
        std.process.exit(2);
    } else if (had_any_match) {
        std.process.exit(0);
    } else {
        std.process.exit(1);
    }
}
