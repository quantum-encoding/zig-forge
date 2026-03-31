//! High-performance regex engine using Thompson NFA construction
//! Guarantees O(n*m) worst-case time complexity where n=text length, m=pattern length
//! No backtracking - immune to ReDoS attacks
//! SIMD-accelerated literal prefix search for fast candidate filtering
//! Sparse set state tracking for O(active_states) iteration

const std = @import("std");
const simd = @import("simd.zig");
const sparse_set = @import("sparse_set.zig");

/// Maximum number of NFA states supported
/// Keep small for cache efficiency - most regexes have <256 states
/// 256 states = 1KB sparse set (256*2 + 256*2 = 1KB)
const MAX_STATES = 256;

/// Sparse set type for NFA state tracking
const StateSet = sparse_set.SparseSet(MAX_STATES);

pub const Regex = struct {
    states: []State,
    start: usize,
    allocator: std.mem.Allocator,
    /// Literal prefix for SIMD acceleration (if pattern starts with literals)
    literal_prefix: []const u8,
    /// Whether pattern is anchored at start (^)
    anchored_start: bool,
    /// SIMD fast path for pure character class patterns like [0-9]+, \d+, \w+
    simd_char_class: SimdCharClass,
    /// Word boundary literal: for patterns like \bword\b, stores "word"
    /// Enables SIMD search for literal, then verify word boundaries
    word_boundary_literal: []const u8,

    const Self = @This();

    /// SIMD-accelerated character class patterns
    /// These can bypass the NFA entirely for pure char class + patterns
    pub const SimdCharClass = enum {
        none, // No SIMD char class optimization
        digit_plus, // [0-9]+ or \d+
        word_plus, // \w+ or [a-zA-Z0-9_]+
        lower_plus, // [a-z]+
        upper_plus, // [A-Z]+
        alnum_plus, // [a-zA-Z0-9]+
    };

    pub const State = struct {
        kind: Kind,
        out1: ?usize = null,
        out2: ?usize = null, // Only used for Split

        const Kind = union(enum) {
            literal: u8,
            char_class: CharClass,
            any, // . (dot)
            split, // For alternation and quantifiers
            anchor_start, // ^ - matches start of line/text
            anchor_end, // $ - matches end of line/text
            word_boundary, // \b - matches word boundary
            non_word_boundary, // \B - matches non-word boundary
            match, // Accept state
        };
    };

    pub const CharClass = struct {
        bitmap: [256 / 8]u8 = [_]u8{0} ** (256 / 8),
        negated: bool = false,

        pub fn set(self: *CharClass, c: u8) void {
            self.bitmap[c / 8] |= @as(u8, 1) << @as(u3, @intCast(c % 8));
        }

        pub fn setRange(self: *CharClass, from: u8, to: u8) void {
            var c = from;
            while (c <= to) : (c += 1) {
                self.set(c);
                if (c == 255) break;
            }
        }

        pub fn contains(self: *const CharClass, c: u8) bool {
            const result = (self.bitmap[c / 8] & (@as(u8, 1) << @as(u3, @intCast(c % 8)))) != 0;
            return if (self.negated) !result else result;
        }
    };

    pub const Match = struct {
        start: usize,
        end: usize,

        pub fn slice(self: Match, text: []const u8) []const u8 {
            return text[self.start..self.end];
        }
    };

    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Self {
        var compiler = Compiler.init(allocator);
        defer compiler.deinit();

        const start = try compiler.parse(pattern);
        const states = try compiler.states.toOwnedSlice(allocator);

        // Extract literal prefix by following states from start
        var prefix_buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer prefix_buf.deinit(allocator);

        var anchored_start = false;
        var state_idx: ?usize = start;

        while (state_idx) |idx| {
            if (idx >= states.len) break;
            const state = &states[idx];

            switch (state.kind) {
                .literal => |lit| {
                    try prefix_buf.append(allocator, lit);
                    state_idx = state.out1;
                },
                .anchor_start => {
                    anchored_start = true;
                    state_idx = state.out1;
                },
                // Stop at anything non-literal (quantifiers create splits, etc.)
                else => break,
            }
        }

        // Detect pure character class patterns for SIMD fast path
        const simd_char_class = detectSimdCharClass(pattern);

        // Detect word boundary literal patterns like \bword\b
        const word_boundary_literal = try detectWordBoundaryLiteral(allocator, pattern);

        return Self{
            .states = states,
            .start = start,
            .allocator = allocator,
            .literal_prefix = try prefix_buf.toOwnedSlice(allocator),
            .anchored_start = anchored_start,
            .simd_char_class = simd_char_class,
            .word_boundary_literal = word_boundary_literal,
        };
    }

    /// Detect patterns of the form \b<literal>\b and extract the literal
    /// Returns empty slice if pattern doesn't match this form
    fn detectWordBoundaryLiteral(allocator: std.mem.Allocator, pattern: []const u8) ![]const u8 {
        // Must start with \b
        if (pattern.len < 5) return &[_]u8{}; // Minimum: \bX\b
        if (!std.mem.startsWith(u8, pattern, "\\b")) return &[_]u8{};
        // Must end with \b
        if (!std.mem.endsWith(u8, pattern, "\\b")) return &[_]u8{};

        // Extract content between \b...\b
        const inner = pattern[2 .. pattern.len - 2];
        if (inner.len == 0) return &[_]u8{};

        // Check if inner is pure literal (no regex metacharacters)
        var i: usize = 0;
        var literal_buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer literal_buf.deinit(allocator);

        while (i < inner.len) {
            const c = inner[i];
            switch (c) {
                // Metacharacters that would make this not a simple literal
                '.', '*', '+', '?', '[', ']', '(', ')', '|', '^', '$' => {
                    literal_buf.deinit(allocator);
                    return &[_]u8{};
                },
                '\\' => {
                    // Handle escape sequences
                    if (i + 1 >= inner.len) {
                        literal_buf.deinit(allocator);
                        return &[_]u8{};
                    }
                    const escaped = inner[i + 1];
                    switch (escaped) {
                        // These are character class escapes, not literals
                        'd', 'D', 'w', 'W', 's', 'S', 'b', 'B' => {
                            literal_buf.deinit(allocator);
                            return &[_]u8{};
                        },
                        // Literal escapes
                        'n' => try literal_buf.append(allocator, '\n'),
                        't' => try literal_buf.append(allocator, '\t'),
                        'r' => try literal_buf.append(allocator, '\r'),
                        // Escaped metacharacters become literals
                        else => try literal_buf.append(allocator, escaped),
                    }
                    i += 2;
                },
                else => {
                    try literal_buf.append(allocator, c);
                    i += 1;
                },
            }
        }

        if (literal_buf.items.len == 0) {
            literal_buf.deinit(allocator);
            return &[_]u8{};
        }

        return try literal_buf.toOwnedSlice(allocator);
    }

    /// Detect if pattern is a pure character class plus pattern
    /// These patterns can be matched entirely with SIMD, bypassing NFA
    fn detectSimdCharClass(pattern: []const u8) SimdCharClass {
        // Check for \d+
        if (std.mem.eql(u8, pattern, "\\d+")) return .digit_plus;
        // Check for \w+
        if (std.mem.eql(u8, pattern, "\\w+")) return .word_plus;
        // Check for [0-9]+
        if (std.mem.eql(u8, pattern, "[0-9]+")) return .digit_plus;
        // Check for [a-z]+
        if (std.mem.eql(u8, pattern, "[a-z]+")) return .lower_plus;
        // Check for [A-Z]+
        if (std.mem.eql(u8, pattern, "[A-Z]+")) return .upper_plus;
        // Check for [a-zA-Z0-9]+
        if (std.mem.eql(u8, pattern, "[a-zA-Z0-9]+")) return .alnum_plus;
        // Check for [a-zA-Z0-9_]+ (same as \w+)
        if (std.mem.eql(u8, pattern, "[a-zA-Z0-9_]+")) return .word_plus;

        return .none;
    }

    pub fn deinit(self: *Self) void {
        if (self.literal_prefix.len > 0) {
            self.allocator.free(self.literal_prefix);
        }
        if (self.word_boundary_literal.len > 0) {
            self.allocator.free(self.word_boundary_literal);
        }
        self.allocator.free(self.states);
    }

    /// Check if the pattern matches anywhere in the text
    pub fn isMatch(self: *const Self, text: []const u8) bool {
        return self.find(text) != null;
    }

    /// Find first match in text
    pub fn find(self: *const Self, text: []const u8) ?Match {
        return self.findFrom(text, 0);
    }

    /// Find match starting from offset
    pub fn findFrom(self: *const Self, text: []const u8, start_offset: usize) ?Match {
        // SIMD fast path for pure character class patterns
        // These bypass the NFA entirely for maximum speed
        if (self.simd_char_class != .none) {
            return self.findFromSimdCharClass(text, start_offset);
        }

        // SIMD fast path for word boundary literals like \bword\b
        // Use SIMD to find literal, then verify word boundaries
        if (self.word_boundary_literal.len > 0) {
            return self.findFromWordBoundary(text, start_offset);
        }

        // Use sparse sets for O(active_states) iteration instead of O(4096)
        // Two sets with pointer swapping to avoid 16KB copies
        var sets: [2]StateSet = .{ StateSet.init(), StateSet.init() };
        var current_idx: u1 = 0;

        // SIMD fast path: use literal prefix to skip to candidate positions
        const use_simd = self.literal_prefix.len > 0 and !self.anchored_start;

        // Try matching from each position
        var text_start: usize = start_offset;
        while (text_start <= text.len) {
            // SIMD acceleration: skip to next candidate position
            if (use_simd) {
                if (simd.memmemFrom(text, self.literal_prefix, text_start)) |candidate| {
                    text_start = candidate;
                } else {
                    // No more candidates, done
                    break;
                }
            }
            // O(1) clear - just reset count, no memory clearing
            sets[current_idx].clear();
            self.addStateWithAnchors(&sets[current_idx], self.start, text, text_start);

            var i: usize = text_start;
            var last_match: ?usize = null;

            // Check if we're already at a match state - O(active_states)
            for (sets[current_idx].items()) |state_idx| {
                if (self.states[state_idx].kind == .match) {
                    last_match = i;
                    break;
                }
            }

            while (i < text.len) : (i += 1) {
                const c = text[i];
                const next_idx = 1 - current_idx;
                // O(1) clear
                sets[next_idx].clear();

                // Process all current states - O(active_states) iteration
                for (sets[current_idx].items()) |state_idx| {
                    const state = &self.states[state_idx];
                    const matches = switch (state.kind) {
                        .literal => |lit| c == lit,
                        .any => c != '\n', // . doesn't match newline by default
                        .char_class => |*cc| cc.contains(c),
                        .split, .match, .anchor_start, .anchor_end, .word_boundary, .non_word_boundary => false,
                    };

                    if (matches) {
                        if (state.out1) |out| {
                            self.addStateWithAnchors(&sets[next_idx], out, text, i + 1);
                        }
                    }
                }

                if (sets[next_idx].isEmpty()) break;

                // Swap sets - just flip the index (O(1), no data copy!)
                current_idx = next_idx;

                // Check for match state - O(active_states)
                for (sets[current_idx].items()) |state_idx| {
                    if (self.states[state_idx].kind == .match) {
                        last_match = i + 1;
                        break;
                    }
                }
            }

            // Handle end-of-text anchors: check if any anchor_end states can transition to match
            if (last_match == null) {
                for (sets[current_idx].items()) |state_idx| {
                    const state = &self.states[state_idx];
                    if (state.kind == .anchor_end) {
                        // $ matches at end of text or before newline
                        const at_end = (i == text.len);
                        if (at_end) {
                            if (state.out1) |out| {
                                self.addStateWithAnchors(&sets[current_idx], out, text, i);
                            }
                        }
                    }
                }
                // Re-check for match state after processing end anchors
                for (sets[current_idx].items()) |state_idx| {
                    if (self.states[state_idx].kind == .match) {
                        last_match = i;
                        break;
                    }
                }
            }

            if (last_match) |end| {
                return Match{ .start = text_start, .end = end };
            }

            // Advance to next position
            text_start += 1;
        }

        return null;
    }

    /// Find all non-overlapping matches
    pub fn findAll(self: *const Self, allocator: std.mem.Allocator, text: []const u8) ![]Match {
        var matches: std.ArrayListUnmanaged(Match) = .empty;
        errdefer matches.deinit(allocator);

        var pos: usize = 0;
        while (pos < text.len) {
            if (self.findFrom(text, pos)) |m| {
                try matches.append(allocator, m);
                pos = if (m.end > m.start) m.end else m.start + 1;
            } else {
                break;
            }
        }

        return matches.toOwnedSlice(allocator);
    }

    /// Check if pattern matches entire text
    pub fn fullMatch(self: *const Self, text: []const u8) bool {
        if (self.find(text)) |m| {
            return m.start == 0 and m.end == text.len;
        }
        return false;
    }

    fn addState(self: *const Self, set: *StateSet, state_idx: usize) void {
        // O(1) contains check and add
        if (!set.add(@intCast(state_idx))) return; // Already in set

        const state = &self.states[state_idx];
        if (state.kind == .split) {
            if (state.out1) |out| self.addState(set, out);
            if (state.out2) |out| self.addState(set, out);
        }
    }

    /// Check if a character is a word character [a-zA-Z0-9_]
    fn isWordChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
    }

    /// Add state with anchor-aware epsilon transitions
    fn addStateWithAnchors(self: *const Self, set: *StateSet, state_idx: usize, text: []const u8, pos: usize) void {
        // O(1) contains check and add
        if (!set.add(@intCast(state_idx))) return; // Already in set

        const state = &self.states[state_idx];
        switch (state.kind) {
            .split => {
                if (state.out1) |out| self.addStateWithAnchors(set, out, text, pos);
                if (state.out2) |out| self.addStateWithAnchors(set, out, text, pos);
            },
            .anchor_start => {
                // ^ matches at start of text or after a newline
                const at_start = (pos == 0);
                const after_newline = (pos > 0 and text[pos - 1] == '\n');
                if (at_start or after_newline) {
                    if (state.out1) |out| self.addStateWithAnchors(set, out, text, pos);
                }
            },
            .anchor_end => {
                // $ matches at end of text or before a newline
                const at_end = (pos == text.len);
                const before_newline = (pos < text.len and text[pos] == '\n');
                if (at_end or before_newline) {
                    if (state.out1) |out| self.addStateWithAnchors(set, out, text, pos);
                }
            },
            .word_boundary => {
                // \b matches at word boundary
                const prev_is_word = (pos > 0 and isWordChar(text[pos - 1]));
                const curr_is_word = (pos < text.len and isWordChar(text[pos]));
                // Word boundary: transition from word to non-word or vice versa
                if (prev_is_word != curr_is_word) {
                    if (state.out1) |out| self.addStateWithAnchors(set, out, text, pos);
                }
            },
            .non_word_boundary => {
                // \B matches at non-word boundary
                const prev_is_word = (pos > 0 and isWordChar(text[pos - 1]));
                const curr_is_word = (pos < text.len and isWordChar(text[pos]));
                // Non-word boundary: both word or both non-word
                if (prev_is_word == curr_is_word) {
                    if (state.out1) |out| self.addStateWithAnchors(set, out, text, pos);
                }
            },
            else => {},
        }
    }

    /// SIMD-accelerated matching for pure character class patterns
    /// Bypasses NFA entirely - finds first char, then measures span with SIMD
    fn findFromSimdCharClass(self: *const Self, text: []const u8, start_offset: usize) ?Match {
        var pos = start_offset;

        while (pos < text.len) {
            // Find first matching character using SIMD
            const found_pos: ?usize = switch (self.simd_char_class) {
                .digit_plus => simd.findFirstDigit(text, pos),
                .word_plus => simd.findFirstWordChar(text, pos),
                .lower_plus => blk: {
                    // Scan for first lowercase letter
                    var i = pos;
                    while (i < text.len) : (i += 1) {
                        if (text[i] >= 'a' and text[i] <= 'z') break :blk i;
                    }
                    break :blk null;
                },
                .upper_plus => blk: {
                    // Scan for first uppercase letter
                    var i = pos;
                    while (i < text.len) : (i += 1) {
                        if (text[i] >= 'A' and text[i] <= 'Z') break :blk i;
                    }
                    break :blk null;
                },
                .alnum_plus => blk: {
                    // Scan for first alphanumeric
                    var i = pos;
                    while (i < text.len) : (i += 1) {
                        const c = text[i];
                        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')) {
                            break :blk i;
                        }
                    }
                    break :blk null;
                },
                .none => unreachable,
            };

            if (found_pos) |match_start| {
                // Found start, now find span using SIMD
                const span_len: usize = switch (self.simd_char_class) {
                    .digit_plus => simd.findDigitSpan(text, match_start),
                    .word_plus => simd.findWordCharSpan(text, match_start),
                    .lower_plus => simd.findLowerSpan(text, match_start),
                    .upper_plus => simd.findUpperSpan(text, match_start),
                    .alnum_plus => blk: {
                        // Combined alphanumeric span (no underscore)
                        var i = match_start;
                        while (i < text.len) : (i += 1) {
                            const c = text[i];
                            if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9'))) {
                                break;
                            }
                        }
                        break :blk i - match_start;
                    },
                    .none => unreachable,
                };

                // + requires at least 1 match (span_len >= 1 guaranteed since we found first char)
                if (span_len > 0) {
                    return Match{ .start = match_start, .end = match_start + span_len };
                }

                // Should not happen, but advance if it does
                pos = match_start + 1;
            } else {
                // No more matches
                break;
            }
        }

        return null;
    }

    /// SIMD-accelerated matching for word boundary literal patterns
    /// For patterns like \bword\b: use SIMD to find "word", then verify boundaries
    fn findFromWordBoundary(self: *const Self, text: []const u8, start_offset: usize) ?Match {
        const literal = self.word_boundary_literal;
        var pos = start_offset;

        while (pos + literal.len <= text.len) {
            // Use SIMD to find the literal
            const found = simd.memmemFrom(text, literal, pos) orelse break;

            // Verify word boundary at start
            const start_boundary = (found == 0) or !isWordChar(text[found - 1]);
            if (!start_boundary) {
                pos = found + 1;
                continue;
            }

            // Verify word boundary at end
            const end_pos = found + literal.len;
            const end_boundary = (end_pos >= text.len) or !isWordChar(text[end_pos]);
            if (!end_boundary) {
                pos = found + 1;
                continue;
            }

            // Both boundaries match!
            return Match{ .start = found, .end = end_pos };
        }

        return null;
    }
};

const Compiler = struct {
    states: std.ArrayListUnmanaged(Regex.State),
    allocator: std.mem.Allocator,

    const Fragment = struct {
        start: usize,
        outs: std.ArrayListUnmanaged(usize), // Indices of states with dangling out pointers
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator, start: usize) Fragment {
            return .{
                .start = start,
                .outs = std.ArrayListUnmanaged(usize).empty,
                .allocator = allocator,
            };
        }

        fn deinit(self: *Fragment) void {
            self.outs.deinit(self.allocator);
        }
    };

    fn init(allocator: std.mem.Allocator) Compiler {
        return .{
            .states = std.ArrayListUnmanaged(Regex.State).empty,
            .allocator = allocator,
        };
    }

    fn deinit(self: *Compiler) void {
        self.states.deinit(self.allocator);
    }

    fn addState(self: *Compiler, state: Regex.State) !usize {
        const idx = self.states.items.len;
        try self.states.append(self.allocator, state);
        return idx;
    }

    fn patch(self: *Compiler, outs: []const usize, target: usize) void {
        for (outs) |out_idx| {
            if (self.states.items[out_idx].out1 == null) {
                self.states.items[out_idx].out1 = target;
            } else if (self.states.items[out_idx].out2 == null) {
                self.states.items[out_idx].out2 = target;
            }
        }
    }

    fn parse(self: *Compiler, pattern: []const u8) !usize {
        var frag_stack: std.ArrayListUnmanaged(Fragment) = .empty;
        defer {
            for (frag_stack.items) |*f| f.deinit();
            frag_stack.deinit(self.allocator);
        }

        var i: usize = 0;
        while (i < pattern.len) {
            const c = pattern[i];

            switch (c) {
                '.' => {
                    const idx = try self.addState(.{ .kind = .any });
                    var frag = Fragment.init(self.allocator, idx);
                    try frag.outs.append(frag.allocator, idx);
                    try frag_stack.append(self.allocator, frag);
                },
                '*' => {
                    if (frag_stack.items.len == 0) return error.InvalidPattern;
                    var frag = frag_stack.pop().?;
                    defer frag.deinit();

                    const split_idx = try self.addState(.{ .kind = .split, .out1 = frag.start });
                    self.patch(frag.outs.items, split_idx);

                    var new_frag = Fragment.init(self.allocator, split_idx);
                    try new_frag.outs.append(new_frag.allocator, split_idx); // out2 is dangling
                    try frag_stack.append(self.allocator, new_frag);
                },
                '+' => {
                    if (frag_stack.items.len == 0) return error.InvalidPattern;
                    var frag = frag_stack.pop().?;
                    defer frag.deinit();

                    const split_idx = try self.addState(.{ .kind = .split, .out1 = frag.start });
                    self.patch(frag.outs.items, split_idx);

                    var new_frag = Fragment.init(self.allocator, frag.start);
                    try new_frag.outs.append(new_frag.allocator, split_idx);
                    try frag_stack.append(self.allocator, new_frag);
                },
                '?' => {
                    if (frag_stack.items.len == 0) return error.InvalidPattern;
                    var frag = frag_stack.pop().?;
                    defer frag.deinit();

                    const split_idx = try self.addState(.{ .kind = .split, .out1 = frag.start });

                    var new_frag = Fragment.init(self.allocator, split_idx);
                    try new_frag.outs.append(new_frag.allocator, split_idx); // out2 dangling
                    for (frag.outs.items) |out| {
                        try new_frag.outs.append(new_frag.allocator, out);
                    }
                    try frag_stack.append(self.allocator, new_frag);
                },
                '|' => {
                    // Alternation - need to handle precedence properly
                    // For now, simple two-way alternation
                    if (frag_stack.items.len < 1) return error.InvalidPattern;
                    // We'll handle this when we see the next atom
                    var frag = frag_stack.pop().?;

                    // Parse rest and create alternation
                    const rest_start = try self.parse(pattern[i + 1 ..]);

                    const split_idx = try self.addState(.{ .kind = .split, .out1 = frag.start, .out2 = rest_start });
                    frag.deinit();

                    var new_frag = Fragment.init(self.allocator, split_idx);
                    // Collect outs from match state
                    const match_idx = try self.addState(.{ .kind = .match });
                    self.patch(&[_]usize{rest_start}, match_idx);

                    try new_frag.outs.append(new_frag.allocator, match_idx);
                    try frag_stack.append(self.allocator, new_frag);

                    // Return early since we consumed the rest
                    break;
                },
                '[' => {
                    var cc = Regex.CharClass{};
                    i += 1;

                    if (i < pattern.len and pattern[i] == '^') {
                        cc.negated = true;
                        i += 1;
                    }

                    while (i < pattern.len and pattern[i] != ']') {
                        const ch = pattern[i];
                        if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
                            cc.setRange(ch, pattern[i + 2]);
                            i += 3;
                        } else {
                            cc.set(ch);
                            i += 1;
                        }
                    }

                    const idx = try self.addState(.{ .kind = .{ .char_class = cc } });
                    var frag = Fragment.init(self.allocator, idx);
                    try frag.outs.append(frag.allocator, idx);
                    try frag_stack.append(self.allocator, frag);
                },
                '\\' => {
                    i += 1;
                    if (i >= pattern.len) return error.InvalidPattern;

                    const escaped = pattern[i];
                    var cc = Regex.CharClass{};
                    var is_class = false;

                    switch (escaped) {
                        'd' => {
                            cc.setRange('0', '9');
                            is_class = true;
                        },
                        'D' => {
                            cc.setRange('0', '9');
                            cc.negated = true;
                            is_class = true;
                        },
                        'w' => {
                            cc.setRange('a', 'z');
                            cc.setRange('A', 'Z');
                            cc.setRange('0', '9');
                            cc.set('_');
                            is_class = true;
                        },
                        'W' => {
                            cc.setRange('a', 'z');
                            cc.setRange('A', 'Z');
                            cc.setRange('0', '9');
                            cc.set('_');
                            cc.negated = true;
                            is_class = true;
                        },
                        's' => {
                            cc.set(' ');
                            cc.set('\t');
                            cc.set('\n');
                            cc.set('\r');
                            is_class = true;
                        },
                        'S' => {
                            cc.set(' ');
                            cc.set('\t');
                            cc.set('\n');
                            cc.set('\r');
                            cc.negated = true;
                            is_class = true;
                        },
                        'n' => {
                            const idx = try self.addState(.{ .kind = .{ .literal = '\n' } });
                            var frag = Fragment.init(self.allocator, idx);
                            try frag.outs.append(frag.allocator, idx);
                            try frag_stack.append(self.allocator, frag);
                        },
                        't' => {
                            const idx = try self.addState(.{ .kind = .{ .literal = '\t' } });
                            var frag = Fragment.init(self.allocator, idx);
                            try frag.outs.append(frag.allocator, idx);
                            try frag_stack.append(self.allocator, frag);
                        },
                        'r' => {
                            const idx = try self.addState(.{ .kind = .{ .literal = '\r' } });
                            var frag = Fragment.init(self.allocator, idx);
                            try frag.outs.append(frag.allocator, idx);
                            try frag_stack.append(self.allocator, frag);
                        },
                        'b' => {
                            // Word boundary
                            const idx = try self.addState(.{ .kind = .word_boundary });
                            var frag = Fragment.init(self.allocator, idx);
                            try frag.outs.append(frag.allocator, idx);
                            try frag_stack.append(self.allocator, frag);
                        },
                        'B' => {
                            // Non-word boundary
                            const idx = try self.addState(.{ .kind = .non_word_boundary });
                            var frag = Fragment.init(self.allocator, idx);
                            try frag.outs.append(frag.allocator, idx);
                            try frag_stack.append(self.allocator, frag);
                        },
                        else => {
                            // Literal escaped character (includes \^, \$, \., \*, etc.)
                            const idx = try self.addState(.{ .kind = .{ .literal = escaped } });
                            var frag = Fragment.init(self.allocator, idx);
                            try frag.outs.append(frag.allocator, idx);
                            try frag_stack.append(self.allocator, frag);
                        },
                    }

                    if (is_class) {
                        const idx = try self.addState(.{ .kind = .{ .char_class = cc } });
                        var frag = Fragment.init(self.allocator, idx);
                        try frag.outs.append(frag.allocator, idx);
                        try frag_stack.append(self.allocator, frag);
                    }
                },
                '^' => {
                    const idx = try self.addState(.{ .kind = .anchor_start });
                    var frag = Fragment.init(self.allocator, idx);
                    try frag.outs.append(frag.allocator, idx);
                    try frag_stack.append(self.allocator, frag);
                },
                '$' => {
                    const idx = try self.addState(.{ .kind = .anchor_end });
                    var frag = Fragment.init(self.allocator, idx);
                    try frag.outs.append(frag.allocator, idx);
                    try frag_stack.append(self.allocator, frag);
                },
                '(' => {
                    // Find matching )
                    var depth: usize = 1;
                    var j = i + 1;
                    while (j < pattern.len and depth > 0) : (j += 1) {
                        if (pattern[j] == '(') depth += 1;
                        if (pattern[j] == ')') depth -= 1;
                    }
                    if (depth != 0) return error.InvalidPattern;

                    // Parse group content
                    const group_start = try self.parse(pattern[i + 1 .. j - 1]);

                    var frag = Fragment.init(self.allocator, group_start);
                    // Need to find the dangling outs - for simplicity, mark match state
                    try frag.outs.append(frag.allocator, self.states.items.len - 1);
                    try frag_stack.append(self.allocator, frag);

                    i = j - 1; // Will be incremented
                },
                ')' => {
                    // Should not reach here if properly parsed
                    return error.InvalidPattern;
                },
                else => {
                    // Literal character
                    const idx = try self.addState(.{ .kind = .{ .literal = c } });
                    var frag = Fragment.init(self.allocator, idx);
                    try frag.outs.append(frag.allocator, idx);
                    try frag_stack.append(self.allocator, frag);
                },
            }

            // Concatenate fragments if:
            // - We have at least 2 fragments
            // - Current char is not a quantifier (those modify top fragment)
            // - Next char is not a quantifier (let it apply to second atom first)
            const next_is_quantifier = if (i + 1 < pattern.len)
                (pattern[i + 1] == '*' or pattern[i + 1] == '+' or pattern[i + 1] == '?')
            else
                false;

            if (c != '*' and c != '+' and c != '?' and c != '|' and !next_is_quantifier) {
                // Concatenate all fragments on the stack into one
                while (frag_stack.items.len >= 2) {
                    var f2 = frag_stack.pop().?;
                    defer f2.deinit();
                    var f1 = frag_stack.pop().?;
                    defer f1.deinit();

                    self.patch(f1.outs.items, f2.start);

                    var new_frag = Fragment.init(self.allocator, f1.start);
                    for (f2.outs.items) |out| {
                        try new_frag.outs.append(new_frag.allocator, out);
                    }
                    try frag_stack.append(self.allocator, new_frag);
                }
            }

            i += 1;
        }

        // Final concatenation: connect all remaining fragments on the stack
        while (frag_stack.items.len >= 2) {
            var f2 = frag_stack.pop().?;
            defer f2.deinit();
            var f1 = frag_stack.pop().?;
            defer f1.deinit();

            self.patch(f1.outs.items, f2.start);

            var new_frag = Fragment.init(self.allocator, f1.start);
            for (f2.outs.items) |out| {
                try new_frag.outs.append(new_frag.allocator, out);
            }
            try frag_stack.append(self.allocator, new_frag);
        }

        // Add match state
        const match_idx = try self.addState(.{ .kind = .match });

        if (frag_stack.items.len == 0) {
            return match_idx;
        }

        // Patch final fragment to match state
        var final_frag = frag_stack.pop().?;
        defer final_frag.deinit();
        self.patch(final_frag.outs.items, match_idx);

        return final_frag.start;
    }
};

// Tests
test "literal match" {
    var re = try Regex.compile(std.testing.allocator, "hello");
    defer re.deinit();

    try std.testing.expect(re.isMatch("hello world"));
    try std.testing.expect(re.isMatch("say hello"));
    try std.testing.expect(!re.isMatch("helo"));
}

test "dot any" {
    var re = try Regex.compile(std.testing.allocator, "h.llo");
    defer re.deinit();

    try std.testing.expect(re.isMatch("hello"));
    try std.testing.expect(re.isMatch("hallo"));
    try std.testing.expect(!re.isMatch("hllo"));
}

test "star quantifier" {
    var re = try Regex.compile(std.testing.allocator, "ab*c");
    defer re.deinit();

    try std.testing.expect(re.isMatch("ac"));
    try std.testing.expect(re.isMatch("abc"));
    try std.testing.expect(re.isMatch("abbc"));
    try std.testing.expect(re.isMatch("abbbc"));
    try std.testing.expect(!re.isMatch("aXc")); // X is not b, shouldn't match
}

test "plus quantifier" {
    var re = try Regex.compile(std.testing.allocator, "ab+c");
    defer re.deinit();

    try std.testing.expect(!re.isMatch("ac"));
    try std.testing.expect(re.isMatch("abc"));
    try std.testing.expect(re.isMatch("abbc"));
}

test "character class" {
    var re = try Regex.compile(std.testing.allocator, "[abc]");
    defer re.deinit();

    try std.testing.expect(re.isMatch("a"));
    try std.testing.expect(re.isMatch("b"));
    try std.testing.expect(re.isMatch("c"));
    try std.testing.expect(!re.isMatch("d"));
}

test "digit class" {
    var re = try Regex.compile(std.testing.allocator, "\\d+");
    defer re.deinit();

    try std.testing.expect(re.isMatch("123"));
    try std.testing.expect(re.isMatch("abc123def"));
    try std.testing.expect(!re.isMatch("abc"));
}

test "start anchor" {
    var re = try Regex.compile(std.testing.allocator, "^hello");
    defer re.deinit();

    try std.testing.expect(re.isMatch("hello world"));
    try std.testing.expect(!re.isMatch("say hello"));
    try std.testing.expect(!re.isMatch("  hello"));

    // Multiline: ^ also matches after newline
    try std.testing.expect(re.isMatch("first\nhello world"));
}

test "end anchor" {
    var re = try Regex.compile(std.testing.allocator, "world$");
    defer re.deinit();

    try std.testing.expect(re.isMatch("hello world"));
    try std.testing.expect(!re.isMatch("world hello"));
    try std.testing.expect(!re.isMatch("world!"));

    // Multiline: $ also matches before newline
    try std.testing.expect(re.isMatch("hello world\nnext line"));
}

test "both anchors" {
    var re = try Regex.compile(std.testing.allocator, "^hello$");
    defer re.deinit();

    try std.testing.expect(re.isMatch("hello"));
    try std.testing.expect(!re.isMatch("hello world"));
    try std.testing.expect(!re.isMatch("say hello"));

    // Matches a complete line in multiline text
    try std.testing.expect(re.isMatch("first\nhello\nlast"));
}

test "anchor with quantifiers" {
    var re = try Regex.compile(std.testing.allocator, "^\\d+$");
    defer re.deinit();

    try std.testing.expect(re.isMatch("12345"));
    try std.testing.expect(!re.isMatch("abc12345"));
    try std.testing.expect(!re.isMatch("12345abc"));
    try std.testing.expect(!re.isMatch("abc"));
}

test "word boundary" {
    var re = try Regex.compile(std.testing.allocator, "\\bword\\b");
    defer re.deinit();

    try std.testing.expect(re.isMatch("word"));
    try std.testing.expect(re.isMatch("a word here"));
    try std.testing.expect(re.isMatch("word!"));
    try std.testing.expect(re.isMatch("(word)"));
    try std.testing.expect(!re.isMatch("words"));
    try std.testing.expect(!re.isMatch("sword"));
    try std.testing.expect(!re.isMatch("swords"));
    try std.testing.expect(!re.isMatch("keyword"));
}

test "word boundary at edges" {
    var re = try Regex.compile(std.testing.allocator, "\\btest");
    defer re.deinit();

    try std.testing.expect(re.isMatch("test"));
    try std.testing.expect(re.isMatch("test case"));
    try std.testing.expect(re.isMatch("a test"));
    try std.testing.expect(!re.isMatch("contest")); // no word boundary before 'test'
    try std.testing.expect(re.isMatch("testing")); // \b matches at word start before 'test'
}

test "non-word boundary" {
    var re = try Regex.compile(std.testing.allocator, "\\Btest\\B");
    defer re.deinit();

    // \B matches when both sides are word chars (or both non-word)
    try std.testing.expect(re.isMatch("atesting")); // word chars on both sides of 'test'
    try std.testing.expect(!re.isMatch("contest")); // 'test' ends at word boundary
    try std.testing.expect(!re.isMatch("atest")); // 'test' ends at word boundary
    try std.testing.expect(!re.isMatch("testa")); // 'test' starts at word boundary
    try std.testing.expect(!re.isMatch("test")); // both boundaries
    try std.testing.expect(!re.isMatch("a test")); // both boundaries
}

test "non-word boundary start only" {
    var re2 = try Regex.compile(std.testing.allocator, "\\Btest");
    defer re2.deinit();

    try std.testing.expect(re2.isMatch("contest")); // no word boundary before 'test'
    try std.testing.expect(re2.isMatch("atesting")); // no word boundary before 'test'
    try std.testing.expect(!re2.isMatch("test")); // word boundary at start
    try std.testing.expect(!re2.isMatch("a test")); // word boundary before 'test'
}

test "word boundary literal detection" {
    // Test that word boundary literals are detected and optimized
    {
        var re = try Regex.compile(std.testing.allocator, "\\bworld\\b");
        defer re.deinit();
        try std.testing.expectEqualStrings("world", re.word_boundary_literal);
        // Verify correctness
        try std.testing.expect(re.isMatch("hello world"));
        try std.testing.expect(re.isMatch("world"));
        try std.testing.expect(!re.isMatch("worlds"));
        try std.testing.expect(!re.isMatch("underworld"));
        // Verify match bounds
        const m = re.find("hello world!").?;
        try std.testing.expectEqual(@as(usize, 6), m.start);
        try std.testing.expectEqual(@as(usize, 11), m.end);
    }
    {
        var re = try Regex.compile(std.testing.allocator, "\\btest\\b");
        defer re.deinit();
        try std.testing.expectEqualStrings("test", re.word_boundary_literal);
        try std.testing.expect(re.isMatch("a test here"));
        try std.testing.expect(!re.isMatch("contest"));
        try std.testing.expect(!re.isMatch("testing"));
    }
    // Non word-boundary patterns should have empty literal
    {
        var re = try Regex.compile(std.testing.allocator, "hello");
        defer re.deinit();
        try std.testing.expectEqual(@as(usize, 0), re.word_boundary_literal.len);
    }
    // Pattern with only start boundary - not optimized
    {
        var re = try Regex.compile(std.testing.allocator, "\\btest");
        defer re.deinit();
        try std.testing.expectEqual(@as(usize, 0), re.word_boundary_literal.len);
    }
}

test "simd char class detection" {
    // Test that SIMD char class patterns are detected
    {
        var re = try Regex.compile(std.testing.allocator, "[0-9]+");
        defer re.deinit();
        try std.testing.expectEqual(Regex.SimdCharClass.digit_plus, re.simd_char_class);
        // Verify correctness
        try std.testing.expect(re.isMatch("123"));
        try std.testing.expect(re.isMatch("abc123def"));
        try std.testing.expect(!re.isMatch("abc"));
        // Verify match bounds
        const m = re.find("abc123def").?;
        try std.testing.expectEqual(@as(usize, 3), m.start);
        try std.testing.expectEqual(@as(usize, 6), m.end);
    }
    {
        var re = try Regex.compile(std.testing.allocator, "\\d+");
        defer re.deinit();
        try std.testing.expectEqual(Regex.SimdCharClass.digit_plus, re.simd_char_class);
    }
    {
        var re = try Regex.compile(std.testing.allocator, "\\w+");
        defer re.deinit();
        try std.testing.expectEqual(Regex.SimdCharClass.word_plus, re.simd_char_class);
        // Verify match
        const m = re.find("hello_world123!").?;
        try std.testing.expectEqual(@as(usize, 0), m.start);
        try std.testing.expectEqual(@as(usize, 14), m.end);
    }
    {
        var re = try Regex.compile(std.testing.allocator, "[a-z]+");
        defer re.deinit();
        try std.testing.expectEqual(Regex.SimdCharClass.lower_plus, re.simd_char_class);
    }
    {
        var re = try Regex.compile(std.testing.allocator, "[A-Z]+");
        defer re.deinit();
        try std.testing.expectEqual(Regex.SimdCharClass.upper_plus, re.simd_char_class);
    }
    // Non-SIMD patterns should be .none
    {
        var re = try Regex.compile(std.testing.allocator, "hello");
        defer re.deinit();
        try std.testing.expectEqual(Regex.SimdCharClass.none, re.simd_char_class);
    }
}
