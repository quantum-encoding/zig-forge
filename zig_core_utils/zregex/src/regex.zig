//! High-performance regex engine using Thompson NFA construction
//! Guarantees O(n*m) worst-case time complexity where n=text length, m=pattern length
//! No backtracking - immune to ReDoS attacks
//! SIMD-accelerated literal prefix search for fast candidate filtering
//! Sparse set state tracking for O(active_states) iteration

const std = @import("std");
const simd = @import("simd.zig");
const sparse_set = @import("sparse_set.zig");

/// Maximum number of NFA states supported.
/// Patterns compiling to more than this are rejected with error.InvalidPattern
/// at compile time (see Regex.compile) rather than silently mis-matching: the
/// fixed-size SparseSet(MAX_STATES) drops out-of-range elements, and the u16
/// state index used in the simulation must not overflow. Enforcing the bound up
/// front is what makes both safe. 8192 states = 32KB per sparse set (2 sets).
const MAX_STATES = 8192;

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
        errdefer allocator.free(states);

        // Reject patterns that exceed the NFA-state bound instead of silently
        // dropping the excess (the SparseSet is fixed-size and the simulation
        // uses u16 indices). This turns a wrong-answer bug into a clean error.
        if (states.len > MAX_STATES) return error.InvalidPattern;

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

/// Sub-NFA with a single entry (`start`) and a set of dangling out-pointers
/// (`outs`, state indices whose out1/out2 is null and awaits patching).
const Fragment = struct {
    start: usize,
    outs: std.ArrayListUnmanaged(usize),
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

const Compiler = struct {
    states: std.ArrayListUnmanaged(Regex.State),
    allocator: std.mem.Allocator,

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

    /// Entry point: compile the full pattern into an NFA rooted at the returned
    /// start-state index, terminated by exactly one `.match` accept state.
    ///
    /// Grammar (POSIX ERE subset, recursive descent):
    ///   alternation  := concatenation ('|' concatenation)*
    ///   concatenation := quantified*
    ///   quantified   := atom ('*' | '+' | '?' | '{' interval '}')*
    ///   atom         := '(' alternation ')' | '[' class ']' | '\' escape
    ///                  | '.' | '^' | '$' | literal
    fn parse(self: *Compiler, pattern: []const u8) !usize {
        var p = Parser{ .c = self, .pattern = pattern, .pos = 0 };
        var frag = try p.parseAlt();
        defer frag.deinit();
        // Any leftover (e.g. a stray ')') is a syntax error.
        if (p.pos != pattern.len) return error.InvalidPattern;

        const match_idx = try self.addState(.{ .kind = .match });
        self.patch(frag.outs.items, match_idx);
        return frag.start;
    }
};

/// Recursive-descent Thompson-construction parser.
///
/// Every builder returns a `Fragment` (a sub-NFA with a single entry `start`
/// and a set of dangling `outs`). Fragments are patched together by later
/// operators; NO fragment ever synthesizes its own `.match` accept node — the
/// single accept state is added once, at the top level, in `Compiler.parse`.
/// (The previous stack-based parser emitted `.match` nodes mid-parse, which is
/// exactly why alternation dropped its left branch and groups accepted early.)
const Parser = struct {
    c: *Compiler,
    pattern: []const u8,
    pos: usize,

    const Interval = struct { min: usize, max: ?usize };

    // Explicit error set: the parser is mutually recursive
    // (parseAlt -> parseConcat -> parseAtom -> parseAlt), so an inferred error
    // set would form a dependency loop. Naming it breaks the cycle.
    const Error = error{ InvalidPattern, OutOfMemory };

    fn peek(self: *const Parser) ?u8 {
        if (self.pos < self.pattern.len) return self.pattern[self.pos];
        return null;
    }

    fn single(self: *Parser, state: Regex.State) !Fragment {
        const idx = try self.c.addState(state);
        var f = Fragment.init(self.c.allocator, idx);
        try f.outs.append(f.allocator, idx);
        return f;
    }

    /// An epsilon fragment (matches the empty string) implemented as a
    /// pass-through split whose out1 is dangling.
    fn emptyFrag(self: *Parser) !Fragment {
        const idx = try self.c.addState(.{ .kind = .split });
        var f = Fragment.init(self.c.allocator, idx);
        try f.outs.append(f.allocator, idx);
        return f;
    }

    /// f1 f2 : patch f1's outs into f2's entry; result inherits f2's outs.
    fn concat(self: *Parser, f1: *Fragment, f2: *Fragment) !Fragment {
        self.c.patch(f1.outs.items, f2.start);
        var f = Fragment.init(self.c.allocator, f1.start);
        for (f2.outs.items) |o| try f.outs.append(f.allocator, o);
        return f;
    }

    /// f1 | f2 : new split branching to both entries; result collects BOTH
    /// branches' dangling outs (this is the fix for the dropped-left-branch bug).
    fn alternate(self: *Parser, f1: *Fragment, f2: *Fragment) !Fragment {
        const split_idx = try self.c.addState(.{ .kind = .split, .out1 = f1.start, .out2 = f2.start });
        var f = Fragment.init(self.c.allocator, split_idx);
        for (f1.outs.items) |o| try f.outs.append(f.allocator, o);
        for (f2.outs.items) |o| try f.outs.append(f.allocator, o);
        return f;
    }

    /// f* : zero or more.
    fn star(self: *Parser, frag: *Fragment) !Fragment {
        const split_idx = try self.c.addState(.{ .kind = .split, .out1 = frag.start });
        self.c.patch(frag.outs.items, split_idx);
        var f = Fragment.init(self.c.allocator, split_idx);
        try f.outs.append(f.allocator, split_idx); // out2 dangling
        return f;
    }

    /// f+ : one or more.
    fn plus(self: *Parser, frag: *Fragment) !Fragment {
        const split_idx = try self.c.addState(.{ .kind = .split, .out1 = frag.start });
        self.c.patch(frag.outs.items, split_idx);
        var f = Fragment.init(self.c.allocator, frag.start);
        try f.outs.append(f.allocator, split_idx); // out2 dangling
        return f;
    }

    /// f? : zero or one.
    fn quest(self: *Parser, frag: *Fragment) !Fragment {
        const split_idx = try self.c.addState(.{ .kind = .split, .out1 = frag.start });
        var f = Fragment.init(self.c.allocator, split_idx);
        try f.outs.append(f.allocator, split_idx); // out2 dangling
        for (frag.outs.items) |o| try f.outs.append(f.allocator, o);
        return f;
    }

    fn parseAlt(self: *Parser) Error!Fragment {
        var left = try self.parseConcat();
        errdefer left.deinit();
        while (self.peek() == '|') {
            self.pos += 1; // consume '|'
            var right = try self.parseConcat();
            defer right.deinit();
            const combined = try self.alternate(&left, &right);
            left.deinit();
            left = combined;
        }
        return left;
    }

    fn parseConcat(self: *Parser) Error!Fragment {
        var result: ?Fragment = null;
        errdefer if (result) |*r| r.deinit();

        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;

            const atom_start = self.pos;
            var atom = try self.parseAtom();
            const atom_src = self.pattern[atom_start..self.pos];
            atom = self.applyQuantifiers(atom, atom_src) catch |e| {
                atom.deinit();
                return e;
            };

            if (result) |*r| {
                const combined = self.concat(r, &atom) catch |e| {
                    atom.deinit();
                    return e;
                };
                r.deinit();
                atom.deinit();
                result = combined;
            } else {
                result = atom;
            }
        }

        if (result) |r| return r;
        return try self.emptyFrag(); // empty concatenation == epsilon
    }

    /// Apply any trailing quantifiers to `frag`. `src` is the raw source text of
    /// the just-parsed atom (excluding the quantifier), used to expand `{n,m}`
    /// intervals by re-parsing the atom the required number of times.
    fn applyQuantifiers(self: *Parser, frag_in: Fragment, src: []const u8) Error!Fragment {
        var frag = frag_in;
        while (self.peek()) |q| {
            switch (q) {
                '*' => {
                    const n = try self.star(&frag);
                    frag.deinit();
                    frag = n;
                    self.pos += 1;
                },
                '+' => {
                    const n = try self.plus(&frag);
                    frag.deinit();
                    frag = n;
                    self.pos += 1;
                },
                '?' => {
                    const n = try self.quest(&frag);
                    frag.deinit();
                    frag = n;
                    self.pos += 1;
                },
                '{' => {
                    const saved = self.pos;
                    if (try self.parseInterval()) |iv| {
                        const n = try self.buildInterval(src, iv.min, iv.max);
                        frag.deinit();
                        frag = n;
                    } else {
                        // Not a valid interval: treat '{' as a literal, stop.
                        self.pos = saved;
                        break;
                    }
                },
                else => break,
            }
        }
        return frag;
    }

    /// Parse `{n}`, `{n,}` or `{n,m}` starting at the current '{'.
    /// On success advances past '}' and returns the bounds; on a malformed brace
    /// expression returns null (caller treats '{' as a literal). Counts beyond
    /// MAX_STATES, or min>max, are hard syntax errors.
    fn parseInterval(self: *Parser) !?Interval {
        const p = self.pattern;
        var i = self.pos + 1; // skip '{'

        var min: usize = 0;
        var have_min = false;
        while (i < p.len and p[i] >= '0' and p[i] <= '9') : (i += 1) {
            have_min = true;
            min = min * 10 + (p[i] - '0');
            if (min > MAX_STATES) return error.InvalidPattern;
        }
        if (!have_min) return null;

        var max: ?usize = min;
        if (i < p.len and p[i] == ',') {
            i += 1;
            if (i < p.len and p[i] >= '0' and p[i] <= '9') {
                var m: usize = 0;
                while (i < p.len and p[i] >= '0' and p[i] <= '9') : (i += 1) {
                    m = m * 10 + (p[i] - '0');
                    if (m > MAX_STATES) return error.InvalidPattern;
                }
                max = m;
            } else {
                max = null; // {n,}
            }
        }

        if (i >= p.len or p[i] != '}') return null;
        if (max) |mx| {
            if (min > mx) return error.InvalidPattern;
        }
        self.pos = i + 1; // consume '}'
        return Interval{ .min = min, .max = max };
    }

    /// Expand an interval by re-parsing `src` (the atom source) the required
    /// number of times: `min` mandatory copies, then either a starred copy
    /// ({n,}) or `(max-min)` optional copies ({n,m}).
    fn buildInterval(self: *Parser, src: []const u8, min: usize, max_opt: ?usize) Error!Fragment {
        var result: ?Fragment = null;
        errdefer if (result) |*r| r.deinit();

        var k: usize = 0;
        while (k < min) : (k += 1) {
            var copy = try self.parseSub(src);
            const next = try self.appendFrag(result, &copy);
            copy.deinit();
            result = next;
        }

        if (max_opt) |max| {
            var j: usize = min;
            while (j < max) : (j += 1) {
                var copy = try self.parseSub(src);
                var q = self.quest(&copy) catch |e| {
                    copy.deinit();
                    return e;
                };
                copy.deinit();
                const next = try self.appendFrag(result, &q);
                q.deinit();
                result = next;
            }
        } else {
            var copy = try self.parseSub(src);
            var s = self.star(&copy) catch |e| {
                copy.deinit();
                return e;
            };
            copy.deinit();
            const next = try self.appendFrag(result, &s);
            s.deinit();
            result = next;
        }

        if (result) |r| return r;
        return try self.emptyFrag(); // {0} == epsilon
    }

    /// Concatenate `next` onto the running `result`. When `result` is null,
    /// returns an independent copy of `next` (caller still owns/deinits `next`).
    fn appendFrag(self: *Parser, result_opt: ?Fragment, next: *Fragment) !Fragment {
        if (result_opt) |result| {
            var r = result;
            const combined = self.concat(&r, next) catch |e| {
                r.deinit();
                return e;
            };
            r.deinit();
            return combined;
        }
        var f = Fragment.init(self.c.allocator, next.start);
        for (next.outs.items) |o| try f.outs.append(f.allocator, o);
        return f;
    }

    /// Re-parse an atom's source text into a fresh fragment (used to clone an
    /// atom for interval expansion). Shares the same Compiler state array.
    fn parseSub(self: *Parser, src: []const u8) Error!Fragment {
        var sub = Parser{ .c = self.c, .pattern = src, .pos = 0 };
        var f = try sub.parseAlt();
        if (sub.pos != src.len) {
            f.deinit();
            return error.InvalidPattern;
        }
        return f;
    }

    fn parseAtom(self: *Parser) Error!Fragment {
        const c = self.pattern[self.pos]; // caller guarantees pos<len, c not '|'/')'
        switch (c) {
            '(' => {
                self.pos += 1; // consume '('
                var inner = try self.parseAlt();
                if (self.peek() != ')') {
                    inner.deinit();
                    return error.InvalidPattern;
                }
                self.pos += 1; // consume ')'
                return inner;
            },
            '[' => return try self.parseClass(),
            '\\' => return try self.parseEscape(),
            '.' => {
                self.pos += 1;
                return try self.single(.{ .kind = .any });
            },
            '^' => {
                self.pos += 1;
                return try self.single(.{ .kind = .anchor_start });
            },
            '$' => {
                self.pos += 1;
                return try self.single(.{ .kind = .anchor_end });
            },
            // A quantifier with nothing to quantify is a syntax error.
            '*', '+', '?' => return error.InvalidPattern,
            else => {
                self.pos += 1;
                return try self.single(.{ .kind = .{ .literal = c } });
            },
        }
    }

    fn parseClass(self: *Parser) !Fragment {
        const p = self.pattern;
        var i = self.pos + 1; // skip '['
        var cc = Regex.CharClass{};

        if (i < p.len and p[i] == '^') {
            cc.negated = true;
            i += 1;
        }

        // POSIX: a ']' as the FIRST class member is a literal ']'.
        var first = true;
        var closed = false;
        while (i < p.len) {
            const ch = p[i];
            if (ch == ']' and !first) {
                closed = true;
                i += 1;
                break;
            }
            first = false;

            if (i + 2 < p.len and p[i + 1] == '-' and p[i + 2] != ']') {
                const lo = ch;
                const hi = p[i + 2];
                if (lo > hi) return error.InvalidPattern; // invalid range e.g. [z-a]
                cc.setRange(lo, hi);
                i += 3;
            } else {
                cc.set(ch);
                i += 1;
            }
        }

        if (!closed) return error.InvalidPattern; // unterminated '['
        self.pos = i;
        return try self.single(.{ .kind = .{ .char_class = cc } });
    }

    fn parseEscape(self: *Parser) !Fragment {
        self.pos += 1; // consume '\'
        if (self.pos >= self.pattern.len) return error.InvalidPattern;
        const escaped = self.pattern[self.pos];
        self.pos += 1;

        var cc = Regex.CharClass{};
        switch (escaped) {
            'd' => {
                cc.setRange('0', '9');
                return try self.single(.{ .kind = .{ .char_class = cc } });
            },
            'D' => {
                cc.setRange('0', '9');
                cc.negated = true;
                return try self.single(.{ .kind = .{ .char_class = cc } });
            },
            'w' => {
                cc.setRange('a', 'z');
                cc.setRange('A', 'Z');
                cc.setRange('0', '9');
                cc.set('_');
                return try self.single(.{ .kind = .{ .char_class = cc } });
            },
            'W' => {
                cc.setRange('a', 'z');
                cc.setRange('A', 'Z');
                cc.setRange('0', '9');
                cc.set('_');
                cc.negated = true;
                return try self.single(.{ .kind = .{ .char_class = cc } });
            },
            's' => {
                cc.set(' ');
                cc.set('\t');
                cc.set('\n');
                cc.set('\r');
                return try self.single(.{ .kind = .{ .char_class = cc } });
            },
            'S' => {
                cc.set(' ');
                cc.set('\t');
                cc.set('\n');
                cc.set('\r');
                cc.negated = true;
                return try self.single(.{ .kind = .{ .char_class = cc } });
            },
            'n' => return try self.single(.{ .kind = .{ .literal = '\n' } }),
            't' => return try self.single(.{ .kind = .{ .literal = '\t' } }),
            'r' => return try self.single(.{ .kind = .{ .literal = '\r' } }),
            'b' => return try self.single(.{ .kind = .word_boundary }),
            'B' => return try self.single(.{ .kind = .non_word_boundary }),
            // Escaped metacharacter (\., \*, \\, …) becomes a literal.
            else => return try self.single(.{ .kind = .{ .literal = escaped } }),
        }
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
