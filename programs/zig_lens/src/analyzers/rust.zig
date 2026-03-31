const std = @import("std");
const models = @import("../models.zig");

// ============================================================================
// Data Types
// ============================================================================

/// Lexer state for tracking whether we're inside strings, comments, etc.
/// Persists across lines — block comments and raw strings can span lines.
const LexerState = enum {
    code,
    line_comment,
    block_comment,
    string_literal,
    raw_string,
    char_literal,
};

/// Scope kinds for the scope stack.
const ScopeKind = enum {
    module,
    function,
    impl_block,
    trait_block,
    struct_block,
    enum_block,
    block,
    macro_def,
};

/// An entry on the scope stack, pushed when entering a braced block for a declaration.
const ScopeEntry = struct {
    kind: ScopeKind,
    name: []const u8,
    impl_target: []const u8,
    trait_name: []const u8,
    brace_depth_at_open: i32,
    start_line: u32,
    is_unsafe: bool,
};

/// Tracks accumulated outer attributes (#[...]) until consumed by a declaration.
const AttributeState = struct {
    is_test: bool = false,
    is_cfg_test: bool = false,
    derives: []const u8 = "",
    repr: []const u8 = "",
    is_async_trait: bool = false,
    has_serde: bool = false,
    count: u32 = 0,

    fn reset(self: *AttributeState) void {
        self.is_test = false;
        self.is_cfg_test = false;
        self.derives = "";
        self.repr = "";
        self.is_async_trait = false;
        self.has_serde = false;
        self.count = 0;
    }
};

/// Accumulates a multi-line signature until all brackets are balanced and we see `{` or `;`.
const SignatureAccumulator = struct {
    active: bool = false,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    paren_depth: i32 = 0,
    angle_depth: i32 = 0,
    bracket_depth: i32 = 0,
    start_line: u32 = 0,

    fn reset(self: *SignatureAccumulator, allocator: std.mem.Allocator) void {
        self.buf.clearRetainingCapacity();
        _ = allocator;
        self.active = false;
        self.paren_depth = 0;
        self.angle_depth = 0;
        self.bracket_depth = 0;
        self.start_line = 0;
    }

    fn deinit(self: *SignatureAccumulator, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
    }

    fn appendLine(self: *SignatureAccumulator, allocator: std.mem.Allocator, line: []const u8) !void {
        if (self.buf.items.len > 0) {
            try self.buf.append(allocator, ' ');
        }
        try self.buf.appendSlice(allocator, line);
    }

    /// Update bracket depths from code-only characters on the line.
    /// Returns true if the signature is now complete (all balanced + `{` or `;` found).
    fn updateAndCheck(self: *SignatureAccumulator, code_line: []const u8) bool {
        for (code_line) |c| {
            switch (c) {
                '(' => self.paren_depth += 1,
                ')' => self.paren_depth -= 1,
                '<' => self.angle_depth += 1,
                '>' => {
                    if (self.angle_depth > 0) self.angle_depth -= 1;
                },
                '[' => self.bracket_depth += 1,
                ']' => self.bracket_depth -= 1,
                '{', ';' => {
                    if (self.paren_depth <= 0 and self.angle_depth <= 0 and self.bracket_depth <= 0) {
                        return true;
                    }
                },
                else => {},
            }
        }
        return false;
    }

    fn getSignature(self: *const SignatureAccumulator) []const u8 {
        return self.buf.items;
    }
};

/// Main analyzer state that persists across lines.
const AnalyzerState = struct {
    // Lexer
    lexer: LexerState = .code,
    block_comment_depth: i32 = 0,
    raw_string_hashes: u32 = 0,

    // Scope
    scope_stack: std.ArrayListUnmanaged(ScopeEntry) = .empty,
    brace_depth: i32 = 0,

    // Doc comments
    doc_comment: []const u8 = "",
    doc_comment_start: u32 = 0,

    // Attributes
    attrs: AttributeState = .{},

    // Multi-line accumulator
    accum: SignatureAccumulator = .{},

    fn deinit(self: *AnalyzerState, allocator: std.mem.Allocator) void {
        self.scope_stack.deinit(allocator);
        self.accum.deinit(allocator);
    }

    fn clearDoc(self: *AnalyzerState) void {
        self.doc_comment = "";
        self.doc_comment_start = 0;
    }

    fn clearAll(self: *AnalyzerState) void {
        self.clearDoc();
        self.attrs.reset();
    }

    fn currentFn(self: *const AnalyzerState) []const u8 {
        // Walk scope stack backwards to find the enclosing function
        var i = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scope_stack.items[i].kind == .function) {
                return self.scope_stack.items[i].name;
            }
        }
        return "";
    }

    fn currentImplTarget(self: *const AnalyzerState) []const u8 {
        var i = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scope_stack.items[i].kind == .impl_block) {
                return self.scope_stack.items[i].impl_target;
            }
        }
        return "";
    }

    fn inMacroDef(self: *const AnalyzerState) bool {
        for (self.scope_stack.items) |entry| {
            if (entry.kind == .macro_def) return true;
        }
        return false;
    }

    fn pushScope(self: *AnalyzerState, allocator: std.mem.Allocator, entry: ScopeEntry) !void {
        try self.scope_stack.append(allocator, entry);
    }

    fn popScopesAtDepth(self: *AnalyzerState) void {
        while (self.scope_stack.items.len > 0) {
            const top = self.scope_stack.items[self.scope_stack.items.len - 1];
            if (self.brace_depth <= top.brace_depth_at_open) {
                _ = self.scope_stack.pop();
            } else {
                break;
            }
        }
    }
};

// ============================================================================
// Lexer — character-level string/comment awareness
// ============================================================================

/// Process a line through the lexer to extract only "code" characters.
/// Returns a slice of buf containing only characters that are actual code
/// (not inside strings, comments, etc.)
fn processLineForCode(state: *AnalyzerState, line: []const u8, buf: []u8) []const u8 {
    var out_len: usize = 0;
    var i: usize = 0;

    while (i < line.len) {
        switch (state.lexer) {
            .code => {
                // Check for line comment
                if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '/') {
                    // Rest of line is comment
                    break;
                }
                // Check for block comment start
                if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '*') {
                    state.lexer = .block_comment;
                    state.block_comment_depth = 1;
                    i += 2;
                    continue;
                }
                // Check for raw string: r#"..." or r"..."
                if (line[i] == 'r' and i + 1 < line.len) {
                    var hashes: u32 = 0;
                    var j = i + 1;
                    while (j < line.len and line[j] == '#') : (j += 1) {
                        hashes += 1;
                    }
                    if (j < line.len and line[j] == '"') {
                        state.lexer = .raw_string;
                        state.raw_string_hashes = hashes;
                        i = j + 1;
                        continue;
                    }
                }
                // Check for string literal
                if (line[i] == '"') {
                    state.lexer = .string_literal;
                    i += 1;
                    continue;
                }
                // Check for char literal — distinguish from lifetime 'a
                if (line[i] == '\'') {
                    // Lifetime: 'a where a is alphabetic and next is not '
                    if (i + 1 < line.len and std.ascii.isAlphabetic(line[i + 1])) {
                        // Check if this is 'x' (char literal) vs 'a (lifetime)
                        if (i + 2 < line.len and line[i + 2] == '\'') {
                            // char literal like 'x'
                            i += 3;
                            continue;
                        }
                        // Escape sequence char literal like '\n'
                        if (i + 1 < line.len and line[i + 1] == '\\' and i + 3 < line.len and line[i + 3] == '\'') {
                            i += 4;
                            continue;
                        }
                        // Otherwise lifetime — emit the ' as code
                        if (out_len < buf.len) {
                            buf[out_len] = line[i];
                            out_len += 1;
                        }
                        i += 1;
                        continue;
                    }
                    // '\x' escape char literal
                    if (i + 1 < line.len and line[i + 1] == '\\') {
                        // Skip to closing '
                        var k = i + 2;
                        while (k < line.len and line[k] != '\'') : (k += 1) {}
                        i = if (k < line.len) k + 1 else k;
                        continue;
                    }
                    // Single char literal 'x'
                    if (i + 2 < line.len and line[i + 2] == '\'') {
                        i += 3;
                        continue;
                    }
                    // Bare ' — treat as code
                    if (out_len < buf.len) {
                        buf[out_len] = line[i];
                        out_len += 1;
                    }
                    i += 1;
                    continue;
                }
                // Regular code character
                if (out_len < buf.len) {
                    buf[out_len] = line[i];
                    out_len += 1;
                }
                i += 1;
            },
            .block_comment => {
                if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '*') {
                    state.block_comment_depth += 1;
                    i += 2;
                } else if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '/') {
                    state.block_comment_depth -= 1;
                    if (state.block_comment_depth <= 0) {
                        state.lexer = .code;
                        state.block_comment_depth = 0;
                    }
                    i += 2;
                } else {
                    i += 1;
                }
            },
            .string_literal => {
                if (line[i] == '\\' and i + 1 < line.len) {
                    i += 2; // skip escape
                } else if (line[i] == '"') {
                    state.lexer = .code;
                    i += 1;
                } else {
                    i += 1;
                }
            },
            .raw_string => {
                // Look for closing "###
                if (line[i] == '"') {
                    var hashes: u32 = 0;
                    var j = i + 1;
                    while (j < line.len and line[j] == '#') : (j += 1) {
                        hashes += 1;
                    }
                    if (hashes >= state.raw_string_hashes) {
                        state.lexer = .code;
                        i = j;
                        continue;
                    }
                }
                i += 1;
            },
            .char_literal => {
                if (line[i] == '\'') {
                    state.lexer = .code;
                }
                i += 1;
            },
            .line_comment => {
                // Should not happen mid-line, but just consume
                i += 1;
            },
        }
    }

    // At end of line, line_comment resets
    if (state.lexer == .line_comment) {
        state.lexer = .code;
    }

    return buf[0..out_len];
}

// ============================================================================
// Utility Functions
// ============================================================================

fn extractIdent(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t");
    var end: usize = 0;
    for (trimmed) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            end += 1;
        } else break;
    }
    return trimmed[0..end];
}

/// Skip generic parameters <...> accounting for nested <> and >> being two closes.
fn skipGenericParams(s: []const u8) []const u8 {
    if (s.len == 0 or s[0] != '<') return s;
    var depth: i32 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '<' => depth += 1,
            '>' => {
                depth -= 1;
                if (depth <= 0) return std.mem.trim(u8, s[i + 1 ..], " \t");
            },
            '"' => {
                // Skip string inside generics
                i += 1;
                while (i < s.len and s[i] != '"') {
                    if (s[i] == '\\' and i + 1 < s.len) i += 1;
                    i += 1;
                }
            },
            else => {},
        }
    }
    return s;
}

/// Strip visibility qualifiers: pub, pub(crate), pub(super), pub(in path::to)
fn stripVisibility(line: []const u8) struct { rest: []const u8, is_pub: bool } {
    var rest = line;
    if (std.mem.startsWith(u8, rest, "pub(")) {
        // Find matching )
        if (std.mem.indexOfScalar(u8, rest, ')')) |close| {
            rest = std.mem.trim(u8, rest[close + 1 ..], " \t");
            return .{ .rest = rest, .is_pub = true };
        }
    }
    if (std.mem.startsWith(u8, rest, "pub ")) {
        return .{ .rest = rest[4..], .is_pub = true };
    }
    return .{ .rest = rest, .is_pub = false };
}

/// Strip function qualifiers: unsafe, async, extern "C", const, default
fn stripFnQualifiers(line: []const u8) struct { rest: []const u8, is_unsafe: bool, is_extern: bool } {
    var rest = line;
    var is_unsafe = false;
    var is_extern = false;

    while (true) {
        if (std.mem.startsWith(u8, rest, "unsafe ")) {
            is_unsafe = true;
            rest = rest[7..];
        } else if (std.mem.startsWith(u8, rest, "async ")) {
            rest = rest[6..];
        } else if (std.mem.startsWith(u8, rest, "extern ")) {
            is_extern = true;
            rest = rest[7..];
            // Skip ABI string like "C"
            const trimmed_rest = std.mem.trim(u8, rest, " \t");
            if (trimmed_rest.len > 0 and trimmed_rest[0] == '"') {
                if (std.mem.indexOfScalar(u8, trimmed_rest[1..], '"')) |end| {
                    rest = std.mem.trim(u8, trimmed_rest[end + 2 ..], " \t");
                }
            }
        } else if (std.mem.startsWith(u8, rest, "const ")) {
            rest = rest[6..];
        } else if (std.mem.startsWith(u8, rest, "default ")) {
            rest = rest[8..];
        } else break;
    }
    return .{ .rest = rest, .is_unsafe = is_unsafe, .is_extern = is_extern };
}

fn findMatchingParen(s: []const u8, open_pos: usize) ?usize {
    var depth: i32 = 0;
    for (s[open_pos..], open_pos..) |c, i| {
        if (c == '(') depth += 1;
        if (c == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn findMatchingAngle(s: []const u8, open_pos: usize) ?usize {
    var depth: i32 = 0;
    for (s[open_pos..], open_pos..) |c, i| {
        switch (c) {
            '<' => depth += 1,
            '>' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// Extract return type from text after -> until { or where or ;
fn extractReturnType(after_arrow: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, after_arrow, " \t");
    // Find end: { or where or ;
    var depth: i32 = 0; // track <> depth to avoid stopping at { inside generics
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        switch (trimmed[i]) {
            '<' => depth += 1,
            '>' => {
                if (depth > 0) depth -= 1;
            },
            '{', ';' => {
                if (depth == 0) {
                    return std.mem.trim(u8, trimmed[0..i], " \t");
                }
            },
            'w' => {
                if (depth == 0 and i + 5 <= trimmed.len and std.mem.eql(u8, trimmed[i .. i + 5], "where")) {
                    // Make sure it's a keyword boundary
                    if (i + 5 >= trimmed.len or !std.ascii.isAlphanumeric(trimmed[i + 5])) {
                        return std.mem.trim(u8, trimmed[0..i], " \t");
                    }
                }
            },
            else => {},
        }
    }
    return trimmed;
}

/// Parse an impl header line to extract target type and trait name.
/// Handles "impl Type", "impl Trait for Type", "impl<T> Trait for Type<T>".
fn parseImplHeader(line: []const u8) struct { target: []const u8, trait_name: []const u8 } {
    var rest = line;

    // Strip "unsafe "
    if (std.mem.startsWith(u8, rest, "unsafe ")) rest = rest[7..];

    // Strip "impl"
    if (!std.mem.startsWith(u8, rest, "impl")) return .{ .target = "", .trait_name = "" };
    rest = rest[4..];
    rest = std.mem.trim(u8, rest, " \t");

    // Skip generic params after impl
    if (rest.len > 0 and rest[0] == '<') {
        rest = skipGenericParams(rest);
    }

    // Now we have either "Type {" or "Trait for Type {"
    // Look for " for " keyword
    if (std.mem.indexOf(u8, rest, " for ")) |for_pos| {
        const trait_part = std.mem.trim(u8, rest[0..for_pos], " \t");
        const after_for = std.mem.trim(u8, rest[for_pos + 5 ..], " \t");

        // Extract trait name (strip generics)
        const trait_name = extractIdentOrGeneric(trait_part);
        const target = extractIdentOrGeneric(after_for);

        return .{ .target = target, .trait_name = trait_name };
    }

    // Just "impl Type"
    const target = extractIdentOrGeneric(rest);
    return .{ .target = target, .trait_name = "" };
}

/// Extract an identifier that may be followed by generic params, stripping the generics.
/// E.g. "Foo<T>" -> "Foo", "Foo" -> "Foo", "Foo<T> {" -> "Foo"
fn extractIdentOrGeneric(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t");
    var end: usize = 0;
    // Allow :: in type paths
    var i: usize = 0;
    while (i < trimmed.len) {
        const c = trimmed[i];
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            end = i + 1;
            i += 1;
        } else if (c == ':' and i + 1 < trimmed.len and trimmed[i + 1] == ':') {
            end = i + 2;
            i += 2;
        } else break;
    }
    return trimmed[0..end];
}

// ============================================================================
// String/comment-aware body counters
// ============================================================================

/// Count lines in a brace-delimited body, aware of strings and comments.
fn countBraceBodyAware(all_lines: []const []const u8, start_line_idx: usize) u32 {
    var depth: i32 = 0;
    var started = false;
    var count: u32 = 0;
    var lex = LexerState.code;
    var bc_depth: i32 = 0;
    var raw_hashes: u32 = 0;

    for (all_lines[start_line_idx..]) |line| {
        count += 1;
        var i: usize = 0;
        while (i < line.len) {
            switch (lex) {
                .code => {
                    if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '/') {
                        break; // rest is comment
                    }
                    if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '*') {
                        lex = .block_comment;
                        bc_depth = 1;
                        i += 2;
                        continue;
                    }
                    if (line[i] == 'r' and i + 1 < line.len) {
                        var h: u32 = 0;
                        var j = i + 1;
                        while (j < line.len and line[j] == '#') : (j += 1) h += 1;
                        if (j < line.len and line[j] == '"') {
                            lex = .raw_string;
                            raw_hashes = h;
                            i = j + 1;
                            continue;
                        }
                    }
                    if (line[i] == '"') {
                        lex = .string_literal;
                        i += 1;
                        continue;
                    }
                    if (line[i] == '\'') {
                        // Skip char literals
                        if (i + 2 < line.len and line[i + 2] == '\'') {
                            i += 3;
                            continue;
                        }
                        if (i + 1 < line.len and line[i + 1] == '\\') {
                            var k = i + 2;
                            while (k < line.len and line[k] != '\'') : (k += 1) {}
                            i = if (k < line.len) k + 1 else k;
                            continue;
                        }
                        i += 1;
                        continue;
                    }
                    if (line[i] == '{') {
                        depth += 1;
                        started = true;
                    }
                    if (line[i] == '}') depth -= 1;
                    i += 1;
                },
                .block_comment => {
                    if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '*') {
                        bc_depth += 1;
                        i += 2;
                    } else if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '/') {
                        bc_depth -= 1;
                        if (bc_depth <= 0) {
                            lex = .code;
                            bc_depth = 0;
                        }
                        i += 2;
                    } else {
                        i += 1;
                    }
                },
                .string_literal => {
                    if (line[i] == '\\' and i + 1 < line.len) {
                        i += 2;
                    } else if (line[i] == '"') {
                        lex = .code;
                        i += 1;
                    } else {
                        i += 1;
                    }
                },
                .raw_string => {
                    if (line[i] == '"') {
                        var h: u32 = 0;
                        var j = i + 1;
                        while (j < line.len and line[j] == '#') : (j += 1) h += 1;
                        if (h >= raw_hashes) {
                            lex = .code;
                            i = j;
                            continue;
                        }
                    }
                    i += 1;
                },
                .char_literal => {
                    if (line[i] == '\'') lex = .code;
                    i += 1;
                },
                .line_comment => {
                    i += 1;
                },
            }
        }
        if (lex == .line_comment) lex = .code;
        if (started and depth <= 0) return count;
    }
    return count;
}

/// Count fields in a struct body (lines with `:` at brace depth 1), string/comment-aware.
fn countFieldsAware(all_lines: []const []const u8, start_line_idx: usize) u32 {
    var depth: i32 = 0;
    var started = false;
    var fields: u32 = 0;
    var lex = LexerState.code;
    var bc_depth: i32 = 0;
    var raw_hashes: u32 = 0;

    for (all_lines[start_line_idx..]) |line| {
        const depth_at_start = depth;
        var i: usize = 0;
        var line_has_code = false;

        while (i < line.len) {
            switch (lex) {
                .code => {
                    // Detect raw strings
                    if (line[i] == 'r' and i + 1 < line.len) {
                        var h: u32 = 0;
                        var j = i + 1;
                        while (j < line.len and line[j] == '#') : (j += 1) h += 1;
                        if (j < line.len and line[j] == '"') {
                            lex = .raw_string;
                            raw_hashes = h;
                            i = j + 1;
                            continue;
                        }
                    }
                    if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '/') break;
                    if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '*') {
                        lex = .block_comment;
                        bc_depth = 1;
                        i += 2;
                        continue;
                    }
                    if (line[i] == '"') {
                        lex = .string_literal;
                        i += 1;
                        continue;
                    }
                    if (line[i] == '{') {
                        depth += 1;
                        started = true;
                    }
                    if (line[i] == '}') depth -= 1;
                    line_has_code = true;
                    i += 1;
                },
                .block_comment => {
                    if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '*') {
                        bc_depth += 1;
                        i += 2;
                    } else if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '/') {
                        bc_depth -= 1;
                        if (bc_depth <= 0) {
                            lex = .code;
                            bc_depth = 0;
                        }
                        i += 2;
                    } else {
                        i += 1;
                    }
                },
                .string_literal => {
                    if (line[i] == '\\' and i + 1 < line.len) {
                        i += 2;
                    } else if (line[i] == '"') {
                        lex = .code;
                        i += 1;
                    } else {
                        i += 1;
                    }
                },
                .raw_string => {
                    if (line[i] == '"') {
                        var h: u32 = 0;
                        var j = i + 1;
                        while (j < line.len and line[j] == '#') : (j += 1) h += 1;
                        if (h >= raw_hashes) {
                            lex = .code;
                            i = j;
                            continue;
                        }
                    }
                    i += 1;
                },
                else => {
                    i += 1;
                },
            }
        }
        if (lex == .line_comment) lex = .code;

        if (started and depth <= 0) break;

        // At depth 1 (using depth at line start), count field lines
        if (started and depth_at_start == 1 and line_has_code) {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "//") and
                !std.mem.startsWith(u8, trimmed, "#") and
                !std.mem.startsWith(u8, trimmed, "}") and
                !std.mem.startsWith(u8, trimmed, "{"))
            {
                // Field if contains ':'
                if (std.mem.indexOfScalar(u8, trimmed, ':') != null) {
                    fields += 1;
                }
            }
        }
    }
    return fields;
}

/// Count enum variants at brace depth 1, string/comment-aware.
fn countVariantsAware(all_lines: []const []const u8, start_line_idx: usize) struct { variants: u32, has_methods: bool } {
    var depth: i32 = 0;
    var started = false;
    var variants: u32 = 0;
    var has_methods = false;
    var lex = LexerState.code;
    var bc_depth: i32 = 0;

    for (all_lines[start_line_idx..]) |line| {
        const depth_at_start = depth;
        var i: usize = 0;
        while (i < line.len) {
            switch (lex) {
                .code => {
                    if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '/') break;
                    if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '*') {
                        lex = .block_comment;
                        bc_depth = 1;
                        i += 2;
                        continue;
                    }
                    if (line[i] == '"') {
                        lex = .string_literal;
                        i += 1;
                        continue;
                    }
                    if (line[i] == '{') {
                        depth += 1;
                        started = true;
                    }
                    if (line[i] == '}') depth -= 1;
                    i += 1;
                },
                .block_comment => {
                    if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '*') {
                        bc_depth += 1;
                        i += 2;
                    } else if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '/') {
                        bc_depth -= 1;
                        if (bc_depth <= 0) {
                            lex = .code;
                            bc_depth = 0;
                        }
                        i += 2;
                    } else {
                        i += 1;
                    }
                },
                .string_literal => {
                    if (line[i] == '\\' and i + 1 < line.len) {
                        i += 2;
                    } else if (line[i] == '"') {
                        lex = .code;
                        i += 1;
                    } else {
                        i += 1;
                    }
                },
                else => {
                    i += 1;
                },
            }
        }
        if (lex == .line_comment) lex = .code;
        if (started and depth <= 0) break;

        if (started and depth_at_start == 1) {
            const vtrimmed = std.mem.trim(u8, line, " \t\r");
            if (vtrimmed.len == 0 or std.mem.startsWith(u8, vtrimmed, "//") or
                std.mem.startsWith(u8, vtrimmed, "#") or
                std.mem.eql(u8, vtrimmed, "}") or std.mem.eql(u8, vtrimmed, "{"))
            {
                continue;
            }
            if (isFnDecl(vtrimmed)) {
                has_methods = true;
            } else {
                variants += 1;
            }
        }
    }
    return .{ .variants = variants, .has_methods = has_methods };
}

/// Count methods in a body at brace depth 1 (for impl/trait blocks), string/comment-aware.
fn countMethodsAware(all_lines: []const []const u8, start_line_idx: usize) u32 {
    var depth: i32 = 0;
    var started = false;
    var methods: u32 = 0;
    var lex = LexerState.code;
    var bc_depth: i32 = 0;

    for (all_lines[start_line_idx..]) |line| {
        const depth_at_start = depth;
        var i: usize = 0;
        while (i < line.len) {
            switch (lex) {
                .code => {
                    if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '/') break;
                    if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '*') {
                        lex = .block_comment;
                        bc_depth = 1;
                        i += 2;
                        continue;
                    }
                    if (line[i] == '"') {
                        lex = .string_literal;
                        i += 1;
                        continue;
                    }
                    if (line[i] == '{') {
                        depth += 1;
                        started = true;
                    }
                    if (line[i] == '}') depth -= 1;
                    i += 1;
                },
                .block_comment => {
                    if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '*') {
                        bc_depth += 1;
                        i += 2;
                    } else if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '/') {
                        bc_depth -= 1;
                        if (bc_depth <= 0) {
                            lex = .code;
                            bc_depth = 0;
                        }
                        i += 2;
                    } else {
                        i += 1;
                    }
                },
                .string_literal => {
                    if (line[i] == '\\' and i + 1 < line.len) {
                        i += 2;
                    } else if (line[i] == '"') {
                        lex = .code;
                        i += 1;
                    } else {
                        i += 1;
                    }
                },
                else => {
                    i += 1;
                },
            }
        }
        if (lex == .line_comment) lex = .code;
        if (started and depth <= 0) break;

        if (started and depth_at_start == 1) {
            const mtrimmed = std.mem.trim(u8, line, " \t\r");
            if (isFnDecl(mtrimmed)) {
                methods += 1;
            }
        }
    }
    return methods;
}

// ============================================================================
// Declaration Detectors
// ============================================================================

fn isFnDecl(line: []const u8) bool {
    const vis = stripVisibility(line);
    const quals = stripFnQualifiers(vis.rest);
    return std.mem.startsWith(u8, quals.rest, "fn ") or std.mem.startsWith(u8, quals.rest, "fn(");
}

fn isStructDecl(line: []const u8) bool {
    const vis = stripVisibility(line);
    return std.mem.startsWith(u8, vis.rest, "struct ");
}

fn isEnumDecl(line: []const u8) bool {
    const vis = stripVisibility(line);
    return std.mem.startsWith(u8, vis.rest, "enum ");
}

fn isUnionDecl(line: []const u8) bool {
    const vis = stripVisibility(line);
    return std.mem.startsWith(u8, vis.rest, "union ");
}

fn isTraitDecl(line: []const u8) bool {
    const vis = stripVisibility(line);
    var rest = vis.rest;
    if (std.mem.startsWith(u8, rest, "unsafe ")) rest = rest[7..];
    if (std.mem.startsWith(u8, rest, "auto ")) rest = rest[5..];
    return std.mem.startsWith(u8, rest, "trait ");
}

fn isImplDecl(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "impl ") or std.mem.startsWith(u8, line, "impl<")) return true;
    if (std.mem.startsWith(u8, line, "unsafe impl")) return true;
    return false;
}

fn isConstOrStatic(line: []const u8) bool {
    const vis = stripVisibility(line);
    var rest = vis.rest;
    if (std.mem.startsWith(u8, rest, "const ")) {
        const after = rest[6..];
        // Don't match "const fn" — that's a function
        if (std.mem.startsWith(u8, after, "fn ")) return false;
        // Check that name is followed by ':'
        const ident = extractIdent(after);
        if (ident.len == 0) return false;
        const post_ident = std.mem.trim(u8, after[ident.len..], " \t");
        return post_ident.len > 0 and post_ident[0] == ':';
    }
    if (std.mem.startsWith(u8, rest, "static ")) return true;
    return false;
}

fn isTypeAlias(line: []const u8) bool {
    const vis = stripVisibility(line);
    return std.mem.startsWith(u8, vis.rest, "type ");
}

fn isMacroRules(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "macro_rules!");
}

fn isModDecl(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "mod ")) return true;
    if (std.mem.startsWith(u8, line, "pub mod ")) return true;
    const vis = stripVisibility(line);
    return std.mem.startsWith(u8, vis.rest, "mod ");
}

fn isUseDecl(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "use ")) return true;
    if (std.mem.startsWith(u8, line, "pub use ")) return true;
    const vis = stripVisibility(line);
    return std.mem.startsWith(u8, vis.rest, "use ");
}

// ============================================================================
// Declaration Analyzers
// ============================================================================

fn analyzeFnDecl(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_num: u32,
    body_lines: u32,
    state: *AnalyzerState,
    report: *models.FileReport,
) !void {
    const vis = stripVisibility(line);
    const quals = stripFnQualifiers(vis.rest);

    var rest = quals.rest;
    // Now should start with "fn "
    if (std.mem.startsWith(u8, rest, "fn ")) {
        rest = rest[3..];
    } else if (std.mem.startsWith(u8, rest, "fn(")) {
        rest = rest[2..]; // keep the (
    } else return;

    const name = extractIdent(rest);
    if (name.len == 0) return;

    // Extract params
    var params: []const u8 = "";
    // Find the opening paren, skipping generic params
    var param_search = rest[name.len..];
    param_search = std.mem.trim(u8, param_search, " \t");
    if (param_search.len > 0 and param_search[0] == '<') {
        param_search = skipGenericParams(param_search);
    }
    if (param_search.len > 0 and param_search[0] == '(') {
        if (findMatchingParen(param_search, 0)) |close| {
            params = param_search[1..close];
        }
    }

    // Extract return type
    var ret_type: []const u8 = "";
    if (std.mem.indexOf(u8, rest, "->")) |arrow| {
        ret_type = extractReturnType(rest[arrow + 2 ..]);
    }

    // Test detection
    if (state.attrs.is_test) {
        try report.tests.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .line = line_num,
        });
    }

    // Unsafe fn detection
    if (quals.is_unsafe) {
        try report.unsafe_ops.append(allocator, .{
            .line = line_num,
            .operation = "unsafe fn",
            .context_fn = try allocator.dupe(u8, name),
            .risk_level = .high,
        });
    }

    try report.functions.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .end_line = if (body_lines > 0) line_num + body_lines - 1 else line_num,
        .body_lines = body_lines,
        .params = try allocator.dupe(u8, params),
        .return_type = try allocator.dupe(u8, ret_type),
        .is_pub = vis.is_pub,
        .is_extern = quals.is_extern,
        .is_export = false,
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });

    // Push function scope
    try state.pushScope(allocator, .{
        .kind = .function,
        .name = name,
        .impl_target = state.currentImplTarget(),
        .trait_name = "",
        .brace_depth_at_open = state.brace_depth,
        .start_line = line_num,
        .is_unsafe = quals.is_unsafe,
    });
}

fn analyzeStructDecl(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_num: u32,
    all_lines: []const []const u8,
    state: *AnalyzerState,
    report: *models.FileReport,
) !void {
    const vis = stripVisibility(line);
    var rest = vis.rest;

    if (!std.mem.startsWith(u8, rest, "struct ")) return;
    rest = rest[7..];

    const name = extractIdent(rest);
    if (name.len == 0) return;

    // Determine struct kind based on attributes
    var kind: models.ContainerKind = .@"struct";
    if (state.attrs.repr.len > 0) {
        if (std.mem.eql(u8, state.attrs.repr, "C") or std.mem.eql(u8, state.attrs.repr, "transparent")) {
            kind = .extern_struct;
        } else if (std.mem.eql(u8, state.attrs.repr, "packed")) {
            kind = .packed_struct;
        }
    }

    // Check for tuple struct: struct Name(...)
    const after_name = std.mem.trim(u8, rest[name.len..], " \t");

    // Check for unit struct: struct Name; or struct Name where...;
    if (after_name.len > 0 and after_name[0] == ';') {
        try report.structs.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .line = line_num,
            .kind = kind,
            .fields_count = 0,
            .methods_count = 0,
            .is_pub = vis.is_pub,
            .doc_comment = try allocator.dupe(u8, state.doc_comment),
        });
        return;
    }

    // Tuple struct: struct Name(Type, Type);
    if (after_name.len > 0 and after_name[0] == '(') {
        var tuple_fields: u32 = 0;
        if (findMatchingParen(after_name, 0)) |close| {
            const inner = after_name[1..close];
            if (inner.len > 0) {
                // Count comma-separated fields
                tuple_fields = 1;
                for (inner) |c| {
                    if (c == ',') tuple_fields += 1;
                }
            }
        }
        try report.structs.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .line = line_num,
            .kind = kind,
            .fields_count = tuple_fields,
            .methods_count = 0,
            .is_pub = vis.is_pub,
            .doc_comment = try allocator.dupe(u8, state.doc_comment),
        });
        return;
    }

    // Regular struct with braces
    const fields = countFieldsAware(all_lines, line_num - 1);

    try report.structs.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .kind = kind,
        .fields_count = fields,
        .methods_count = 0,
        .is_pub = vis.is_pub,
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });

    // Push struct scope
    try state.pushScope(allocator, .{
        .kind = .struct_block,
        .name = name,
        .impl_target = "",
        .trait_name = "",
        .brace_depth_at_open = state.brace_depth,
        .start_line = line_num,
        .is_unsafe = false,
    });
}

fn analyzeEnumDecl(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_num: u32,
    all_lines: []const []const u8,
    state: *AnalyzerState,
    report: *models.FileReport,
) !void {
    const vis = stripVisibility(line);
    var rest = vis.rest;

    if (!std.mem.startsWith(u8, rest, "enum ")) return;
    rest = rest[5..];

    const name = extractIdent(rest);
    if (name.len == 0) return;

    // Check for tag type from #[repr(u8)] etc.
    var has_tag = false;
    if (state.attrs.repr.len > 0) {
        const r = state.attrs.repr;
        if (std.mem.eql(u8, r, "u8") or std.mem.eql(u8, r, "u16") or
            std.mem.eql(u8, r, "u32") or std.mem.eql(u8, r, "u64") or
            std.mem.eql(u8, r, "i8") or std.mem.eql(u8, r, "i16") or
            std.mem.eql(u8, r, "i32") or std.mem.eql(u8, r, "i64") or
            std.mem.eql(u8, r, "isize") or std.mem.eql(u8, r, "usize"))
        {
            has_tag = true;
        }
    }

    const result = countVariantsAware(all_lines, line_num - 1);

    try report.enums.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .variants_count = result.variants,
        .has_tag_type = has_tag,
        .methods_count = 0,
        .is_pub = vis.is_pub,
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });

    try state.pushScope(allocator, .{
        .kind = .enum_block,
        .name = name,
        .impl_target = "",
        .trait_name = "",
        .brace_depth_at_open = state.brace_depth,
        .start_line = line_num,
        .is_unsafe = false,
    });
}

fn analyzeUnionDecl(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_num: u32,
    all_lines: []const []const u8,
    state: *AnalyzerState,
    report: *models.FileReport,
) !void {
    const vis = stripVisibility(line);
    var rest = vis.rest;

    if (!std.mem.startsWith(u8, rest, "union ")) return;
    rest = rest[6..];

    const name = extractIdent(rest);
    if (name.len == 0) return;

    var has_tag = false;
    var kind: models.ContainerKind = .@"union";
    if (state.attrs.repr.len > 0) {
        if (std.mem.eql(u8, state.attrs.repr, "C")) {
            kind = .@"union";
        }
    }
    // A tagged union if it has repr(u*) or repr(i*)
    if (state.attrs.repr.len > 0) {
        const r = state.attrs.repr;
        if (std.mem.eql(u8, r, "u8") or std.mem.eql(u8, r, "u16") or
            std.mem.eql(u8, r, "u32") or std.mem.eql(u8, r, "u64") or
            std.mem.eql(u8, r, "i8") or std.mem.eql(u8, r, "i16") or
            std.mem.eql(u8, r, "i32") or std.mem.eql(u8, r, "i64"))
        {
            has_tag = true;
            kind = .tagged_union;
        }
    }

    const fields = countFieldsAware(all_lines, line_num - 1);

    try report.unions.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .fields_count = fields,
        .has_tag_type = has_tag,
        .methods_count = 0,
        .is_pub = vis.is_pub,
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });

}

fn analyzeTraitDecl(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_num: u32,
    all_lines: []const []const u8,
    state: *AnalyzerState,
    report: *models.FileReport,
) !void {
    const vis = stripVisibility(line);
    var rest = vis.rest;

    var is_unsafe = false;
    if (std.mem.startsWith(u8, rest, "unsafe ")) {
        is_unsafe = true;
        rest = rest[7..];
    }
    if (std.mem.startsWith(u8, rest, "auto ")) {
        rest = rest[5..];
    }
    if (!std.mem.startsWith(u8, rest, "trait ")) return;
    rest = rest[6..];

    const name = extractIdent(rest);
    if (name.len == 0) return;

    if (is_unsafe) {
        try report.unsafe_ops.append(allocator, .{
            .line = line_num,
            .operation = "unsafe trait",
            .context_fn = "",
            .risk_level = .medium,
        });
    }

    const methods = countMethodsAware(all_lines, line_num - 1);

    try report.structs.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .kind = .trait,
        .fields_count = 0,
        .methods_count = methods,
        .is_pub = vis.is_pub,
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });

    try state.pushScope(allocator, .{
        .kind = .trait_block,
        .name = name,
        .impl_target = "",
        .trait_name = name,
        .brace_depth_at_open = state.brace_depth,
        .start_line = line_num,
        .is_unsafe = is_unsafe,
    });
}

fn analyzeImplBlock(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_num: u32,
    all_lines: []const []const u8,
    state: *AnalyzerState,
    report: *models.FileReport,
) !void {
    const header = parseImplHeader(line);

    if (std.mem.startsWith(u8, line, "unsafe ")) {
        try report.unsafe_ops.append(allocator, .{
            .line = line_num,
            .operation = "unsafe impl",
            .context_fn = "",
            .risk_level = .high,
        });
    }

    const methods = countMethodsAware(all_lines, line_num - 1);

    // Store impl block as a struct with impl_block kind
    var impl_name_buf: [256]u8 = undefined;
    var impl_name: []const u8 = "";
    if (header.trait_name.len > 0 and header.target.len > 0) {
        // "impl Trait for Type" -> "Type::Trait"
        const needed = header.target.len + 2 + header.trait_name.len;
        if (needed <= impl_name_buf.len) {
            @memcpy(impl_name_buf[0..header.target.len], header.target);
            impl_name_buf[header.target.len] = ':';
            impl_name_buf[header.target.len + 1] = ':';
            @memcpy(impl_name_buf[header.target.len + 2 ..][0..header.trait_name.len], header.trait_name);
            impl_name = impl_name_buf[0..needed];
        } else {
            impl_name = header.target;
        }
    } else {
        impl_name = header.target;
    }

    if (impl_name.len > 0) {
        try report.structs.append(allocator, .{
            .name = try allocator.dupe(u8, impl_name),
            .line = line_num,
            .kind = .impl_block,
            .fields_count = 0,
            .methods_count = methods,
            .is_pub = false,
            .doc_comment = try allocator.dupe(u8, state.doc_comment),
        });
    }

    try state.pushScope(allocator, .{
        .kind = .impl_block,
        .name = header.target,
        .impl_target = header.target,
        .trait_name = header.trait_name,
        .brace_depth_at_open = state.brace_depth,
        .start_line = line_num,
        .is_unsafe = std.mem.startsWith(u8, line, "unsafe "),
    });
}

fn analyzeUseStmt(allocator: std.mem.Allocator, line: []const u8, line_num: u32, report: *models.FileReport) !void {
    const vis = stripVisibility(line);
    var rest = vis.rest;

    if (std.mem.startsWith(u8, rest, "use ")) {
        rest = rest[4..];
    } else return;

    const path_raw = std.mem.trim(u8, rest, " \t;");

    const kind: models.ImportKind = if (std.mem.startsWith(u8, path_raw, "std::") or
        std.mem.startsWith(u8, path_raw, "core::") or
        std.mem.startsWith(u8, path_raw, "alloc::"))
        .std_lib
    else if (std.mem.startsWith(u8, path_raw, "crate::") or
        std.mem.startsWith(u8, path_raw, "super::") or
        std.mem.startsWith(u8, path_raw, "self::"))
        .local
    else
        .package;

    try report.imports.append(allocator, .{
        .path = try allocator.dupe(u8, path_raw),
        .kind = kind,
        .binding_name = "",
        .line = line_num,
    });
}

fn analyzeModStmt(allocator: std.mem.Allocator, line: []const u8, line_num: u32, report: *models.FileReport) !void {
    const vis = stripVisibility(line);
    var rest = vis.rest;

    if (std.mem.startsWith(u8, rest, "mod ")) {
        rest = rest[4..];
    } else return;

    const name = extractIdent(rest);
    if (name.len == 0) return;

    try report.imports.append(allocator, .{
        .path = try allocator.dupe(u8, name),
        .kind = .local,
        .binding_name = try allocator.dupe(u8, name),
        .line = line_num,
    });
}

fn analyzeConstStmt(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_num: u32,
    state: *AnalyzerState,
    report: *models.FileReport,
) !void {
    const vis = stripVisibility(line);
    var rest = vis.rest;

    var is_static = false;
    if (std.mem.startsWith(u8, rest, "const ")) {
        rest = rest[6..];
    } else if (std.mem.startsWith(u8, rest, "static ")) {
        rest = rest[7..];
        is_static = true;
    } else return;

    // Handle "mut " after static
    if (is_static and std.mem.startsWith(u8, rest, "mut ")) {
        rest = rest[4..];
    }

    const name = extractIdent(rest);
    if (name.len == 0) return;

    // Extract type after ":"
    var type_name: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, ':')) |colon| {
        const after_colon = std.mem.trim(u8, rest[colon + 1 ..], " \t");
        if (std.mem.indexOfAny(u8, after_colon, "=;")) |end| {
            type_name = std.mem.trim(u8, after_colon[0..end], " \t");
        } else {
            type_name = after_colon;
        }
    }

    try report.constants.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .is_pub = vis.is_pub,
        .type_name = try allocator.dupe(u8, type_name),
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });
}

fn analyzeTypeAlias(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_num: u32,
    state: *AnalyzerState,
    report: *models.FileReport,
) !void {
    const vis = stripVisibility(line);
    var rest = vis.rest;

    if (!std.mem.startsWith(u8, rest, "type ")) return;
    rest = rest[5..];

    const name = extractIdent(rest);
    if (name.len == 0) return;

    try report.structs.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .kind = .type_alias,
        .fields_count = 0,
        .methods_count = 0,
        .is_pub = vis.is_pub,
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });
}

/// Detect unsafe operations inside function bodies.
fn detectUnsafeOp(
    allocator: std.mem.Allocator,
    trimmed: []const u8,
    line_num: u32,
    state: *AnalyzerState,
    report: *models.FileReport,
) !void {
    // unsafe { ... }
    if (std.mem.startsWith(u8, trimmed, "unsafe {") or std.mem.startsWith(u8, trimmed, "unsafe{") or
        std.mem.startsWith(u8, trimmed, "unsafe {") or std.mem.indexOf(u8, trimmed, "unsafe {") != null or
        std.mem.indexOf(u8, trimmed, "unsafe{") != null)
    {
        // Avoid double-counting unsafe fn / unsafe impl / unsafe trait
        if (!std.mem.startsWith(u8, trimmed, "unsafe fn") and
            !std.mem.startsWith(u8, trimmed, "unsafe impl") and
            !std.mem.startsWith(u8, trimmed, "unsafe trait"))
        {
            try report.unsafe_ops.append(allocator, .{
                .line = line_num,
                .operation = "unsafe block",
                .context_fn = try allocator.dupe(u8, state.currentFn()),
                .risk_level = .high,
            });
        }
    }

    // Detect specific unsafe operations
    if (std.mem.indexOf(u8, trimmed, "std::ptr::") != null or
        std.mem.indexOf(u8, trimmed, "ptr::null") != null or
        std.mem.indexOf(u8, trimmed, ".as_ptr()") != null)
    {
        try report.unsafe_ops.append(allocator, .{
            .line = line_num,
            .operation = "pointer operation",
            .context_fn = try allocator.dupe(u8, state.currentFn()),
            .risk_level = .medium,
        });
    }
}

// ============================================================================
// Attribute Parsing
// ============================================================================

fn parseAttribute(trimmed: []const u8, attrs: *AttributeState) void {
    // Must start with #[
    if (!std.mem.startsWith(u8, trimmed, "#[")) return;

    const inner = blk: {
        // Find the matching ]
        if (std.mem.lastIndexOfScalar(u8, trimmed, ']')) |close| {
            break :blk trimmed[2..close];
        }
        break :blk trimmed[2..];
    };

    attrs.count += 1;

    if (std.mem.eql(u8, inner, "test")) {
        attrs.is_test = true;
    } else if (std.mem.startsWith(u8, inner, "cfg(test)")) {
        attrs.is_cfg_test = true;
    } else if (std.mem.startsWith(u8, inner, "derive(")) {
        // Extract derive list
        if (std.mem.indexOfScalar(u8, inner, '(')) |open| {
            if (std.mem.lastIndexOfScalar(u8, inner, ')')) |close| {
                attrs.derives = inner[open + 1 .. close];
            }
        }
    } else if (std.mem.startsWith(u8, inner, "repr(")) {
        if (std.mem.indexOfScalar(u8, inner, '(')) |open| {
            if (std.mem.lastIndexOfScalar(u8, inner, ')')) |close| {
                attrs.repr = inner[open + 1 .. close];
            }
        }
    } else if (std.mem.eql(u8, inner, "async_trait")) {
        attrs.is_async_trait = true;
    } else if (std.mem.startsWith(u8, inner, "serde")) {
        attrs.has_serde = true;
    }
}

// ============================================================================
// Main Analyze Function
// ============================================================================

/// Analyze Rust source code using a lexer-aware line-based scanner.
/// Extracts functions, structs, enums, unions, traits, impls, imports, tests,
/// unsafe blocks, doc comments, constants, and type aliases.
pub fn analyze(allocator: std.mem.Allocator, source: []const u8, report: *models.FileReport) !void {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(allocator);

    // Split source into lines
    var start: usize = 0;
    for (source, 0..) |c, i| {
        if (c == '\n') {
            try lines.append(allocator, source[start..i]);
            start = i + 1;
        }
    }
    if (start < source.len) {
        try lines.append(allocator, source[start..]);
    }

    var state = AnalyzerState{};
    defer state.deinit(allocator);

    var code_buf: [8192]u8 = undefined;
    var line_num: u32 = 0;

    while (line_num < lines.items.len) {
        const line = lines.items[line_num];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        line_num += 1; // 1-based from here

        // === Phase A: Lexer continuation ===
        // If we're still in a block comment or string from previous line,
        // process this line through the lexer to find where code resumes.
        if (state.lexer == .block_comment or state.lexer == .raw_string or state.lexer == .string_literal) {
            const code_chars = processLineForCode(&state, line, &code_buf);
            if (state.lexer != .code) {
                // Entire line was non-code, skip declaration detection
                // But still update brace depth from any code chars found before entering non-code
                for (code_chars) |c| {
                    if (c == '{') state.brace_depth += 1;
                    if (c == '}') {
                        state.brace_depth -= 1;
                        state.popScopesAtDepth();
                    }
                }
                continue;
            }
            // We're back to code — fall through to process this line
            for (code_chars) |c| {
                if (c == '{') state.brace_depth += 1;
                if (c == '}') {
                    state.brace_depth -= 1;
                    state.popScopesAtDepth();
                }
            }
            continue;
        }

        // === Phase B: Accumulator continuation ===
        if (state.accum.active) {
            try state.accum.appendLine(allocator, trimmed);
            const code_chars = processLineForCode(&state, trimmed, &code_buf);
            if (state.accum.updateAndCheck(code_chars)) {
                // Signature complete — dispatch
                const sig = state.accum.getSignature();
                const sig_trimmed = std.mem.trim(u8, sig, " \t\r");
                if (isFnDecl(sig_trimmed)) {
                    const body = countBraceBodyAware(lines.items, state.accum.start_line - 1);
                    try analyzeFnDecl(allocator, sig_trimmed, state.accum.start_line, body, &state, report);
                } else if (isStructDecl(sig_trimmed)) {
                    try analyzeStructDecl(allocator, sig_trimmed, state.accum.start_line, lines.items, &state, report);
                } else if (isEnumDecl(sig_trimmed)) {
                    try analyzeEnumDecl(allocator, sig_trimmed, state.accum.start_line, lines.items, &state, report);
                } else if (isTraitDecl(sig_trimmed)) {
                    try analyzeTraitDecl(allocator, sig_trimmed, state.accum.start_line, lines.items, &state, report);
                } else if (isImplDecl(sig_trimmed)) {
                    try analyzeImplBlock(allocator, sig_trimmed, state.accum.start_line, lines.items, &state, report);
                } else if (isUnionDecl(sig_trimmed)) {
                    try analyzeUnionDecl(allocator, sig_trimmed, state.accum.start_line, lines.items, &state, report);
                }
                state.accum.reset(allocator);
                state.clearAll();
            }
            // Update brace depth from code chars
            const code_chars2 = processLineForCode(&state, line, &code_buf);
            for (code_chars2) |c| {
                if (c == '{') state.brace_depth += 1;
                if (c == '}') {
                    state.brace_depth -= 1;
                    state.popScopesAtDepth();
                }
            }
            continue;
        }

        // === Phase C: Doc comment tracking (///) ===
        if (std.mem.startsWith(u8, trimmed, "///")) {
            if (state.doc_comment_start == 0) {
                state.doc_comment_start = line_num;
            }
            const doc_text = std.mem.trim(u8, trimmed[3..], " ");
            if (state.doc_comment.len == 0) {
                state.doc_comment = doc_text;
            }
            continue;
        }

        // Module doc comments
        if (std.mem.startsWith(u8, trimmed, "//!")) {
            continue;
        }

        // Regular comments
        if (trimmed.len > 0 and std.mem.startsWith(u8, trimmed, "//")) {
            // Non-doc comment clears doc state but not attributes
            state.clearDoc();
            continue;
        }

        // Empty lines clear doc but not attributes
        if (trimmed.len == 0) {
            state.clearDoc();
            continue;
        }

        // Process line through lexer to get code-only characters
        const code_chars = processLineForCode(&state, line, &code_buf);

        // If the whole line was consumed by a string/comment that started on this line, skip
        if (state.lexer != .code) {
            continue;
        }

        // Skip if inside macro_rules! body
        if (state.inMacroDef()) {
            // Still need to track braces for scope popping
            for (code_chars) |c| {
                if (c == '{') state.brace_depth += 1;
                if (c == '}') {
                    state.brace_depth -= 1;
                    state.popScopesAtDepth();
                }
            }
            continue;
        }

        // === Phase D: Attribute tracking (#[...]) ===
        if (trimmed.len > 0 and trimmed[0] == '#' and trimmed.len > 1 and trimmed[1] == '[') {
            parseAttribute(trimmed, &state.attrs);
            continue;
        }

        // === Phase E: Declaration detection cascade ===

        // use declarations
        if (isUseDecl(trimmed)) {
            try analyzeUseStmt(allocator, trimmed, line_num, report);
            state.clearAll();
            // Update brace depth
            for (code_chars) |c| {
                if (c == '{') state.brace_depth += 1;
                if (c == '}') {
                    state.brace_depth -= 1;
                    state.popScopesAtDepth();
                }
            }
            continue;
        }

        // mod declarations
        if (isModDecl(trimmed)) {
            try analyzeModStmt(allocator, trimmed, line_num, report);
            state.clearAll();
            for (code_chars) |c| {
                if (c == '{') state.brace_depth += 1;
                if (c == '}') {
                    state.brace_depth -= 1;
                    state.popScopesAtDepth();
                }
            }
            continue;
        }

        // const / static
        if (isConstOrStatic(trimmed)) {
            try analyzeConstStmt(allocator, trimmed, line_num, &state, report);
            state.clearAll();
            for (code_chars) |c| {
                if (c == '{') state.brace_depth += 1;
                if (c == '}') {
                    state.brace_depth -= 1;
                    state.popScopesAtDepth();
                }
            }
            continue;
        }

        // macro_rules!
        if (isMacroRules(trimmed)) {
            try state.pushScope(allocator, .{
                .kind = .macro_def,
                .name = blk: {
                    const after = trimmed[13..]; // after "macro_rules! "
                    break :blk extractIdent(std.mem.trim(u8, after, " \t"));
                },
                .impl_target = "",
                .trait_name = "",
                .brace_depth_at_open = state.brace_depth,
                .start_line = line_num,
                .is_unsafe = false,
            });
            state.clearAll();
            for (code_chars) |c| {
                if (c == '{') state.brace_depth += 1;
                if (c == '}') {
                    state.brace_depth -= 1;
                    state.popScopesAtDepth();
                }
            }
            continue;
        }

        // Function detection — check if signature is complete on this line
        if (isFnDecl(trimmed)) {
            // Check if the signature completes on this line (has balanced parens and { or ;)
            if (signatureComplete(code_chars)) {
                const body = countBraceBodyAware(lines.items, line_num - 1);
                try analyzeFnDecl(allocator, trimmed, line_num, body, &state, report);
                state.clearAll();
            } else {
                // Start multi-line accumulator
                state.accum.active = true;
                state.accum.start_line = line_num;
                state.accum.paren_depth = 0;
                state.accum.angle_depth = 0;
                state.accum.bracket_depth = 0;
                try state.accum.appendLine(allocator, trimmed);
                _ = state.accum.updateAndCheck(code_chars);
            }
            for (code_chars) |c| {
                if (c == '{') state.brace_depth += 1;
                if (c == '}') {
                    state.brace_depth -= 1;
                    state.popScopesAtDepth();
                }
            }
            continue;
        }

        // struct detection
        if (isStructDecl(trimmed)) {
            if (signatureComplete(code_chars)) {
                try analyzeStructDecl(allocator, trimmed, line_num, lines.items, &state, report);
                state.clearAll();
            } else {
                state.accum.active = true;
                state.accum.start_line = line_num;
                try state.accum.appendLine(allocator, trimmed);
                _ = state.accum.updateAndCheck(code_chars);
            }
            for (code_chars) |c| {
                if (c == '{') state.brace_depth += 1;
                if (c == '}') {
                    state.brace_depth -= 1;
                    state.popScopesAtDepth();
                }
            }
            continue;
        }

        // enum detection
        if (isEnumDecl(trimmed)) {
            if (signatureComplete(code_chars)) {
                try analyzeEnumDecl(allocator, trimmed, line_num, lines.items, &state, report);
                state.clearAll();
            } else {
                state.accum.active = true;
                state.accum.start_line = line_num;
                try state.accum.appendLine(allocator, trimmed);
                _ = state.accum.updateAndCheck(code_chars);
            }
            for (code_chars) |c| {
                if (c == '{') state.brace_depth += 1;
                if (c == '}') {
                    state.brace_depth -= 1;
                    state.popScopesAtDepth();
                }
            }
            continue;
        }

        // union detection
        if (isUnionDecl(trimmed)) {
            if (signatureComplete(code_chars)) {
                try analyzeUnionDecl(allocator, trimmed, line_num, lines.items, &state, report);
                state.clearAll();
            } else {
                state.accum.active = true;
                state.accum.start_line = line_num;
                try state.accum.appendLine(allocator, trimmed);
                _ = state.accum.updateAndCheck(code_chars);
            }
            for (code_chars) |c| {
                if (c == '{') state.brace_depth += 1;
                if (c == '}') {
                    state.brace_depth -= 1;
                    state.popScopesAtDepth();
                }
            }
            continue;
        }

        // trait detection
        if (isTraitDecl(trimmed)) {
            if (signatureComplete(code_chars)) {
                try analyzeTraitDecl(allocator, trimmed, line_num, lines.items, &state, report);
                state.clearAll();
            } else {
                state.accum.active = true;
                state.accum.start_line = line_num;
                try state.accum.appendLine(allocator, trimmed);
                _ = state.accum.updateAndCheck(code_chars);
            }
            for (code_chars) |c| {
                if (c == '{') state.brace_depth += 1;
                if (c == '}') {
                    state.brace_depth -= 1;
                    state.popScopesAtDepth();
                }
            }
            continue;
        }

        // impl detection
        if (isImplDecl(trimmed)) {
            if (signatureComplete(code_chars)) {
                try analyzeImplBlock(allocator, trimmed, line_num, lines.items, &state, report);
                state.clearAll();
            } else {
                state.accum.active = true;
                state.accum.start_line = line_num;
                try state.accum.appendLine(allocator, trimmed);
                _ = state.accum.updateAndCheck(code_chars);
            }
            for (code_chars) |c| {
                if (c == '{') state.brace_depth += 1;
                if (c == '}') {
                    state.brace_depth -= 1;
                    state.popScopesAtDepth();
                }
            }
            continue;
        }

        // type alias
        if (isTypeAlias(trimmed)) {
            try analyzeTypeAlias(allocator, trimmed, line_num, &state, report);
            state.clearAll();
            for (code_chars) |c| {
                if (c == '{') state.brace_depth += 1;
                if (c == '}') {
                    state.brace_depth -= 1;
                    state.popScopesAtDepth();
                }
            }
            continue;
        }

        // Unsafe block detection (standalone "unsafe {" in code)
        try detectUnsafeOp(allocator, trimmed, line_num, &state, report);

        // Clear doc/attrs for non-declaration lines
        state.clearAll();

        // === Phase F: Brace depth + scope stack management ===
        for (code_chars) |c| {
            if (c == '{') state.brace_depth += 1;
            if (c == '}') {
                state.brace_depth -= 1;
                state.popScopesAtDepth();
            }
        }
    }
}

/// Check if a signature line is complete: has balanced parens/angles and contains `{` or `;`.
fn signatureComplete(code_chars: []const u8) bool {
    var paren_depth: i32 = 0;
    var angle_depth: i32 = 0;

    for (code_chars) |c| {
        switch (c) {
            '(' => paren_depth += 1,
            ')' => paren_depth -= 1,
            '<' => angle_depth += 1,
            '>' => {
                if (angle_depth > 0) angle_depth -= 1;
            },
            '{', ';' => {
                if (paren_depth <= 0 and angle_depth <= 0) return true;
            },
            else => {},
        }
    }
    return false;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "lexer handles strings with braces" {
    const source =
        \\fn foo() {
        \\    let s = "{ not a brace }";
        \\    let x = 1;
        \\}
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer {
        for (report.functions.items) |f| {
            std.testing.allocator.free(f.name);
            std.testing.allocator.free(f.params);
            std.testing.allocator.free(f.return_type);
            std.testing.allocator.free(f.doc_comment);
        }
        report.functions.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), report.functions.items.len);
    try std.testing.expectEqualStrings("foo", report.functions.items[0].name);
}

test "lexer handles block comments with braces" {
    const source =
        \\fn bar() {
        \\    /* { this is a comment } */
        \\    let x = 1;
        \\}
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer {
        for (report.functions.items) |f| {
            std.testing.allocator.free(f.name);
            std.testing.allocator.free(f.params);
            std.testing.allocator.free(f.return_type);
            std.testing.allocator.free(f.doc_comment);
        }
        report.functions.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), report.functions.items.len);
    try std.testing.expectEqualStrings("bar", report.functions.items[0].name);
}

test "detects struct with derive attribute" {
    const source =
        \\#[derive(Debug, Clone)]
        \\pub struct MyStruct {
        \\    field1: u32,
        \\    field2: String,
        \\}
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer {
        for (report.structs.items) |s| {
            std.testing.allocator.free(s.name);
            std.testing.allocator.free(s.doc_comment);
        }
        report.structs.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), report.structs.items.len);
    try std.testing.expectEqualStrings("MyStruct", report.structs.items[0].name);
    try std.testing.expect(report.structs.items[0].is_pub);
    try std.testing.expectEqual(@as(u32, 2), report.structs.items[0].fields_count);
}

test "detects enum with repr attribute" {
    const source =
        \\#[repr(u8)]
        \\pub enum Color {
        \\    Red,
        \\    Green,
        \\    Blue,
        \\}
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer {
        for (report.enums.items) |e| {
            std.testing.allocator.free(e.name);
            std.testing.allocator.free(e.doc_comment);
        }
        report.enums.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), report.enums.items.len);
    try std.testing.expectEqualStrings("Color", report.enums.items[0].name);
    try std.testing.expect(report.enums.items[0].has_tag_type);
    try std.testing.expectEqual(@as(u32, 3), report.enums.items[0].variants_count);
}

test "detects test functions" {
    const source =
        \\#[test]
        \\fn test_something() {
        \\    assert!(true);
        \\}
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer {
        for (report.functions.items) |f| {
            std.testing.allocator.free(f.name);
            std.testing.allocator.free(f.params);
            std.testing.allocator.free(f.return_type);
            std.testing.allocator.free(f.doc_comment);
        }
        report.functions.deinit(std.testing.allocator);
        for (report.tests.items) |t| {
            std.testing.allocator.free(t.name);
        }
        report.tests.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), report.tests.items.len);
    try std.testing.expectEqualStrings("test_something", report.tests.items[0].name);
}

test "detects use statements" {
    const source =
        \\use std::collections::HashMap;
        \\use crate::models::Config;
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer {
        for (report.imports.items) |im| {
            std.testing.allocator.free(im.path);
            std.testing.allocator.free(im.binding_name);
        }
        report.imports.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 2), report.imports.items.len);
    try std.testing.expectEqual(models.ImportKind.std_lib, report.imports.items[0].kind);
    try std.testing.expectEqual(models.ImportKind.local, report.imports.items[1].kind);
}

test "detects type aliases" {
    const source =
        \\pub type Result<T> = std::result::Result<T, Error>;
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer {
        for (report.structs.items) |s| {
            std.testing.allocator.free(s.name);
            std.testing.allocator.free(s.doc_comment);
        }
        report.structs.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), report.structs.items.len);
    try std.testing.expectEqualStrings("Result", report.structs.items[0].name);
    try std.testing.expectEqual(models.ContainerKind.type_alias, report.structs.items[0].kind);
}

test "detects unsafe fn" {
    const source =
        \\pub unsafe fn dangerous() {
        \\    let ptr = std::ptr::null();
        \\}
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer {
        for (report.functions.items) |f| {
            std.testing.allocator.free(f.name);
            std.testing.allocator.free(f.params);
            std.testing.allocator.free(f.return_type);
            std.testing.allocator.free(f.doc_comment);
        }
        report.functions.deinit(std.testing.allocator);
        for (report.unsafe_ops.items) |u| {
            std.testing.allocator.free(u.context_fn);
        }
        report.unsafe_ops.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), report.functions.items.len);
    try std.testing.expect(report.unsafe_ops.items.len >= 1);
}

test "detects impl block" {
    const source =
        \\impl MyStruct {
        \\    fn new() -> Self {
        \\        Self {}
        \\    }
        \\    pub fn method(&self) -> u32 {
        \\        42
        \\    }
        \\}
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer {
        for (report.structs.items) |s| {
            std.testing.allocator.free(s.name);
            std.testing.allocator.free(s.doc_comment);
        }
        report.structs.deinit(std.testing.allocator);
        for (report.functions.items) |f| {
            std.testing.allocator.free(f.name);
            std.testing.allocator.free(f.params);
            std.testing.allocator.free(f.return_type);
            std.testing.allocator.free(f.doc_comment);
        }
        report.functions.deinit(std.testing.allocator);
    }
    // Should have impl block entry
    var found_impl = false;
    for (report.structs.items) |s| {
        if (s.kind == .impl_block and std.mem.eql(u8, s.name, "MyStruct")) {
            found_impl = true;
            try std.testing.expectEqual(@as(u32, 2), s.methods_count);
        }
    }
    try std.testing.expect(found_impl);
}

test "detects constants" {
    const source =
        \\pub const MAX_SIZE: usize = 1024;
        \\static mut COUNTER: u32 = 0;
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer {
        for (report.constants.items) |c| {
            std.testing.allocator.free(c.name);
            std.testing.allocator.free(c.type_name);
            std.testing.allocator.free(c.doc_comment);
        }
        report.constants.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 2), report.constants.items.len);
}

test "unit struct detection" {
    const source =
        \\pub struct Marker;
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer {
        for (report.structs.items) |s| {
            std.testing.allocator.free(s.name);
            std.testing.allocator.free(s.doc_comment);
        }
        report.structs.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), report.structs.items.len);
    try std.testing.expectEqualStrings("Marker", report.structs.items[0].name);
    try std.testing.expectEqual(@as(u32, 0), report.structs.items[0].fields_count);
}

test "tuple struct detection" {
    const source =
        \\pub struct Wrapper(u32, String);
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer {
        for (report.structs.items) |s| {
            std.testing.allocator.free(s.name);
            std.testing.allocator.free(s.doc_comment);
        }
        report.structs.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), report.structs.items.len);
    try std.testing.expectEqualStrings("Wrapper", report.structs.items[0].name);
    try std.testing.expectEqual(@as(u32, 2), report.structs.items[0].fields_count);
}

test "union detection" {
    const source =
        \\pub union Data {
        \\    int_val: i32,
        \\    float_val: f32,
        \\}
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer {
        for (report.unions.items) |u| {
            std.testing.allocator.free(u.name);
            std.testing.allocator.free(u.doc_comment);
        }
        report.unions.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), report.unions.items.len);
    try std.testing.expectEqualStrings("Data", report.unions.items[0].name);
    try std.testing.expectEqual(@as(u32, 2), report.unions.items[0].fields_count);
}
