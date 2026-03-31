const std = @import("std");
const models = @import("../models.zig");

// ============================================================================
// Data Types
// ============================================================================

const LexerState = enum {
    code,
    line_comment,
    block_comment,
    string_literal,
    raw_string, // backtick-delimited, no escapes
    rune_literal,
};

const ScopeKind = enum {
    function,
    struct_block,
    interface_block,
    block,
};

const ScopeEntry = struct {
    kind: ScopeKind,
    name: []const u8,
    brace_depth_at_open: i32,
    start_line: u32,
};

const AnalyzerState = struct {
    // Lexer
    lexer: LexerState = .code,

    // Scope
    scope_stack: std.ArrayListUnmanaged(ScopeEntry) = .empty,
    brace_depth: i32 = 0,

    // Doc comments
    doc_comment: []const u8 = "",
    doc_comment_start: u32 = 0,

    // Paren-block state (import/const/var blocks use () not {})
    in_import_block: bool = false,
    in_const_block: bool = false,
    in_var_block: bool = false,
    paren_block_depth: i32 = 0,

    // Const block tracking (for iota enum detection)
    const_block_has_iota: bool = false,
    const_block_type_name: []const u8 = "",
    const_block_variant_count: u32 = 0,
    const_block_start_line: u32 = 0,
    const_block_doc: []const u8 = "",
    const_block_first_entry: bool = true,

    // Multi-line signature accumulator
    accum: SignatureAccumulator = .{},

    fn deinit(self: *AnalyzerState, allocator: std.mem.Allocator) void {
        self.scope_stack.deinit(allocator);
        self.accum.deinit(allocator);
    }

    fn clearDoc(self: *AnalyzerState) void {
        self.doc_comment = "";
        self.doc_comment_start = 0;
    }

    fn currentFn(self: *const AnalyzerState) []const u8 {
        var i = self.scope_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scope_stack.items[i].kind == .function) {
                return self.scope_stack.items[i].name;
            }
        }
        return "";
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

    fn resetConstBlock(self: *AnalyzerState) void {
        self.in_const_block = false;
        self.const_block_has_iota = false;
        self.const_block_type_name = "";
        self.const_block_variant_count = 0;
        self.const_block_start_line = 0;
        self.const_block_doc = "";
        self.const_block_first_entry = true;
    }
};

const SignatureAccumulator = struct {
    active: bool = false,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    paren_depth: i32 = 0,
    bracket_depth: i32 = 0,
    start_line: u32 = 0,

    fn reset(self: *SignatureAccumulator, allocator: std.mem.Allocator) void {
        self.buf.clearRetainingCapacity();
        _ = allocator;
        self.active = false;
        self.paren_depth = 0;
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

    fn updateAndCheck(self: *SignatureAccumulator, code_line: []const u8) bool {
        for (code_line) |c| {
            switch (c) {
                '(' => self.paren_depth += 1,
                ')' => self.paren_depth -= 1,
                '[' => self.bracket_depth += 1,
                ']' => self.bracket_depth -= 1,
                '{', ';' => {
                    if (self.paren_depth <= 0 and self.bracket_depth <= 0) {
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

// ============================================================================
// Lexer — character-level string/comment awareness
// ============================================================================

fn processLineForCode(state: *AnalyzerState, line: []const u8, buf: []u8) []const u8 {
    var out_len: usize = 0;
    var i: usize = 0;

    while (i < line.len) {
        switch (state.lexer) {
            .code => {
                // Line comment
                if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '/') {
                    break;
                }
                // Block comment start
                if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '*') {
                    state.lexer = .block_comment;
                    i += 2;
                    continue;
                }
                // String literal
                if (line[i] == '"') {
                    state.lexer = .string_literal;
                    i += 1;
                    continue;
                }
                // Raw string (backtick) — no escapes, ends at next backtick
                if (line[i] == '`') {
                    state.lexer = .raw_string;
                    i += 1;
                    continue;
                }
                // Rune literal
                if (line[i] == '\'') {
                    if (i + 1 < line.len and line[i + 1] == '\\') {
                        // Escape sequence: '\n', '\x00', '\u0000', etc.
                        var k = i + 2;
                        while (k < line.len and line[k] != '\'') : (k += 1) {}
                        i = if (k < line.len) k + 1 else k;
                        continue;
                    }
                    if (i + 2 < line.len and line[i + 2] == '\'') {
                        i += 3; // simple rune 'x'
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
                // Go block comments do NOT nest
                if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '/') {
                    state.lexer = .code;
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
                // Backtick strings end at the next backtick
                if (line[i] == '`') {
                    state.lexer = .code;
                    i += 1;
                } else {
                    i += 1;
                }
            },
            .rune_literal => {
                if (line[i] == '\'') {
                    state.lexer = .code;
                }
                i += 1;
            },
            .line_comment => {
                i += 1;
            },
        }
    }

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

fn isExported(name: []const u8) bool {
    if (name.len == 0) return false;
    return std.ascii.isUpper(name[0]);
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

fn skipBracketParams(s: []const u8) []const u8 {
    if (s.len == 0 or s[0] != '[') return s;
    var depth: i32 = 0;
    for (s, 0..) |c, i| {
        if (c == '[') depth += 1;
        if (c == ']') {
            depth -= 1;
            if (depth == 0) return std.mem.trim(u8, s[i + 1 ..], " \t");
        }
    }
    return s;
}

fn signatureComplete(code_chars: []const u8) bool {
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;

    for (code_chars) |c| {
        switch (c) {
            '(' => paren_depth += 1,
            ')' => paren_depth -= 1,
            '[' => bracket_depth += 1,
            ']' => bracket_depth -= 1,
            '{', ';' => {
                if (paren_depth <= 0 and bracket_depth <= 0) return true;
            },
            else => {},
        }
    }
    return false;
}

fn classifyImport(path: []const u8) models.ImportKind {
    if (path.len == 0) return .std_lib;
    if (path[0] == '.') return .local;
    if (std.mem.indexOfScalar(u8, path, '.') != null) return .package;
    return .std_lib;
}

// ============================================================================
// Body Counters — string/comment-aware
// ============================================================================

/// Count lines in a brace-delimited body.
fn countBraceBodyAware(all_lines: []const []const u8, start_line_idx: usize) u32 {
    var depth: i32 = 0;
    var started = false;
    var count: u32 = 0;
    var lex = LexerState.code;

    for (all_lines[start_line_idx..]) |line| {
        count += 1;
        var i: usize = 0;
        while (i < line.len) {
            switch (lex) {
                .code => {
                    if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '/') break;
                    if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '*') {
                        lex = .block_comment;
                        i += 2;
                        continue;
                    }
                    if (line[i] == '"') {
                        lex = .string_literal;
                        i += 1;
                        continue;
                    }
                    if (line[i] == '`') {
                        lex = .raw_string;
                        i += 1;
                        continue;
                    }
                    if (line[i] == '\'') {
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
                    if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '/') {
                        lex = .code;
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
                    if (line[i] == '`') {
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
        if (started and depth <= 0) return count;
    }
    return count;
}

/// Count non-blank, non-comment code lines at brace depth 1.
/// Used for struct fields and interface methods.
fn countLinesAtDepthOne(all_lines: []const []const u8, start_line_idx: usize) u32 {
    var depth: i32 = 0;
    var started = false;
    var count: u32 = 0;
    var lex = LexerState.code;

    for (all_lines[start_line_idx..]) |line| {
        const depth_at_start = depth;
        var i: usize = 0;
        var line_has_code = false;

        while (i < line.len) {
            switch (lex) {
                .code => {
                    if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '/') break;
                    if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '*') {
                        lex = .block_comment;
                        i += 2;
                        continue;
                    }
                    if (line[i] == '"') {
                        lex = .string_literal;
                        i += 1;
                        continue;
                    }
                    if (line[i] == '`') {
                        lex = .raw_string;
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
                    if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '/') {
                        lex = .code;
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
                    if (line[i] == '`') {
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

        // Count non-empty code lines at depth 1
        if (started and depth_at_start == 1 and line_has_code) {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "//") and
                !std.mem.startsWith(u8, trimmed, "/*") and
                !std.mem.startsWith(u8, trimmed, "}") and
                !std.mem.startsWith(u8, trimmed, "{"))
            {
                count += 1;
            }
        }
    }
    return count;
}

// ============================================================================
// Declaration Detectors
// ============================================================================

fn isFuncDecl(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "func ");
}

fn isTypeDecl(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "type ");
}

fn isImportBlock(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "import (") or std.mem.eql(u8, line, "import(");
}

fn isImportDecl(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "import ");
}

fn isConstBlock(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "const (") or std.mem.eql(u8, line, "const(");
}

fn isConstDecl(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "const ");
}

fn isVarBlock(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "var (") or std.mem.eql(u8, line, "var(");
}

fn isVarDecl(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "var ");
}

fn isPackageDecl(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "package ");
}

// ============================================================================
// Declaration Analyzers
// ============================================================================

fn analyzeFuncDecl(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_num: u32,
    body_lines: u32,
    state: *AnalyzerState,
    report: *models.FileReport,
) !void {
    var rest = line;
    if (!std.mem.startsWith(u8, rest, "func ")) return;
    rest = rest[5..];
    rest = std.mem.trim(u8, rest, " \t");

    // Check for receiver: func (r *Type) Name(...)
    var receiver: []const u8 = "";
    if (rest.len > 0 and rest[0] == '(') {
        if (findMatchingParen(rest, 0)) |close| {
            receiver = rest[1..close];
            rest = std.mem.trim(u8, rest[close + 1 ..], " \t");
        }
    }

    const name = extractIdent(rest);
    if (name.len == 0) return;

    // Extract params — skip generic params [T any] if present
    var param_search = std.mem.trim(u8, rest[name.len..], " \t");
    param_search = skipBracketParams(param_search);

    var params: []const u8 = "";
    if (param_search.len > 0 and param_search[0] == '(') {
        if (findMatchingParen(param_search, 0)) |close| {
            params = param_search[1..close];
        }
    }

    // Build full params (receiver shown in params)
    var full_params: []const u8 = undefined;
    if (receiver.len > 0 and params.len > 0) {
        full_params = try std.fmt.allocPrint(allocator, "({s}) {s}", .{ receiver, params });
    } else if (receiver.len > 0) {
        full_params = try std.fmt.allocPrint(allocator, "({s})", .{receiver});
    } else {
        full_params = try allocator.dupe(u8, params);
    }

    // Extract return type: after closing paren of params, before {
    var ret_type: []const u8 = "";
    if (param_search.len > 0 and param_search[0] == '(') {
        if (findMatchingParen(param_search, 0)) |close| {
            var after_params = std.mem.trim(u8, param_search[close + 1 ..], " \t");
            if (after_params.len > 0 and after_params[0] != '{') {
                var end: usize = after_params.len;
                for (after_params, 0..) |c, idx| {
                    if (c == '{') {
                        end = idx;
                        break;
                    }
                }
                ret_type = std.mem.trim(u8, after_params[0..end], " \t");
            }
        }
    }

    // Test/Benchmark detection
    if (std.mem.startsWith(u8, name, "Test") and params.len > 0 and
        std.mem.indexOf(u8, params, "*testing.T") != null)
    {
        try report.tests.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .line = line_num,
        });
    } else if (std.mem.startsWith(u8, name, "Benchmark") and params.len > 0 and
        std.mem.indexOf(u8, params, "*testing.B") != null)
    {
        try report.tests.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .line = line_num,
        });
    }

    try report.functions.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .end_line = if (body_lines > 0) line_num + body_lines - 1 else line_num,
        .body_lines = body_lines,
        .params = full_params,
        .return_type = try allocator.dupe(u8, ret_type),
        .is_pub = isExported(name),
        .is_extern = false,
        .is_export = false,
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });

    // Push function scope
    try state.pushScope(allocator, .{
        .kind = .function,
        .name = name,
        .brace_depth_at_open = state.brace_depth,
        .start_line = line_num,
    });
}

fn analyzeTypeDecl(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_num: u32,
    all_lines: []const []const u8,
    state: *AnalyzerState,
    report: *models.FileReport,
) !void {
    var rest = line;
    if (!std.mem.startsWith(u8, rest, "type ")) return;
    rest = rest[5..];
    rest = std.mem.trim(u8, rest, " \t");

    const name = extractIdent(rest);
    if (name.len == 0) return;

    var after_name = std.mem.trim(u8, rest[name.len..], " \t");
    // Skip generic params [T any]
    after_name = skipBracketParams(after_name);

    if (std.mem.startsWith(u8, after_name, "struct")) {
        const fields = countLinesAtDepthOne(all_lines, line_num - 1);
        try report.structs.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .line = line_num,
            .kind = .@"struct",
            .fields_count = fields,
            .methods_count = 0,
            .is_pub = isExported(name),
            .doc_comment = try allocator.dupe(u8, state.doc_comment),
        });
        try state.pushScope(allocator, .{
            .kind = .struct_block,
            .name = name,
            .brace_depth_at_open = state.brace_depth,
            .start_line = line_num,
        });
    } else if (std.mem.startsWith(u8, after_name, "interface")) {
        const methods = countLinesAtDepthOne(all_lines, line_num - 1);
        try report.structs.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .line = line_num,
            .kind = .interface,
            .fields_count = 0,
            .methods_count = methods,
            .is_pub = isExported(name),
            .doc_comment = try allocator.dupe(u8, state.doc_comment),
        });
        try state.pushScope(allocator, .{
            .kind = .interface_block,
            .name = name,
            .brace_depth_at_open = state.brace_depth,
            .start_line = line_num,
        });
    } else if (std.mem.startsWith(u8, after_name, "=")) {
        // Type alias: type Name = Other
        try report.structs.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .line = line_num,
            .kind = .type_alias,
            .fields_count = 0,
            .methods_count = 0,
            .is_pub = isExported(name),
            .doc_comment = try allocator.dupe(u8, state.doc_comment),
        });
    } else {
        // Type definition: type Name OtherType (e.g., type MyInt int)
        try report.structs.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .line = line_num,
            .kind = .type_alias,
            .fields_count = 0,
            .methods_count = 0,
            .is_pub = isExported(name),
            .doc_comment = try allocator.dupe(u8, state.doc_comment),
        });
    }
}

fn analyzeSingleImport(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_num: u32,
    report: *models.FileReport,
) !void {
    var rest = line;
    if (!std.mem.startsWith(u8, rest, "import ")) return;
    rest = rest[7..];
    rest = std.mem.trim(u8, rest, " \t");

    // Check for block
    if (rest.len > 0 and rest[0] == '(') return;

    // Find the quoted path
    const quote_pos = std.mem.indexOfScalar(u8, rest, '"') orelse return;
    const alias = std.mem.trim(u8, rest[0..quote_pos], " \t");
    const after_quote = rest[quote_pos + 1 ..];
    const close_quote = std.mem.indexOfScalar(u8, after_quote, '"') orelse return;
    const path = after_quote[0..close_quote];

    // Check for unsafe imports
    if (std.mem.eql(u8, path, "C")) {
        try report.unsafe_ops.append(allocator, .{
            .line = line_num,
            .operation = "cgo import",
            .context_fn = "",
            .risk_level = .high,
        });
    } else if (std.mem.eql(u8, path, "unsafe")) {
        try report.unsafe_ops.append(allocator, .{
            .line = line_num,
            .operation = "unsafe import",
            .context_fn = "",
            .risk_level = .high,
        });
    }

    try report.imports.append(allocator, .{
        .path = try allocator.dupe(u8, path),
        .kind = classifyImport(path),
        .binding_name = try allocator.dupe(u8, alias),
        .line = line_num,
    });
}

fn analyzeImportLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_num: u32,
    report: *models.FileReport,
) !void {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//") or
        std.mem.startsWith(u8, trimmed, "/*"))
    {
        return;
    }

    // Find the quoted path
    const quote_pos = std.mem.indexOfScalar(u8, trimmed, '"') orelse return;
    const alias = std.mem.trim(u8, trimmed[0..quote_pos], " \t");
    const after_quote = trimmed[quote_pos + 1 ..];
    const close_quote = std.mem.indexOfScalar(u8, after_quote, '"') orelse return;
    const path = after_quote[0..close_quote];

    // Check for unsafe imports
    if (std.mem.eql(u8, path, "C")) {
        try report.unsafe_ops.append(allocator, .{
            .line = line_num,
            .operation = "cgo import",
            .context_fn = "",
            .risk_level = .high,
        });
    } else if (std.mem.eql(u8, path, "unsafe")) {
        try report.unsafe_ops.append(allocator, .{
            .line = line_num,
            .operation = "unsafe import",
            .context_fn = "",
            .risk_level = .high,
        });
    }

    if (path.len > 0) {
        try report.imports.append(allocator, .{
            .path = try allocator.dupe(u8, path),
            .kind = classifyImport(path),
            .binding_name = try allocator.dupe(u8, alias),
            .line = line_num,
        });
    }
}

fn analyzeConstBlockEntry(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_num: u32,
    state: *AnalyzerState,
    report: *models.FileReport,
) !void {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//") or
        std.mem.startsWith(u8, trimmed, "/*") or trimmed[0] == ')')
    {
        return;
    }

    const name = extractIdent(trimmed);
    if (name.len == 0) return;

    var after_name = std.mem.trim(u8, trimmed[name.len..], " \t");

    // Check for iota on this line
    if (std.mem.indexOf(u8, after_name, "iota") != null) {
        state.const_block_has_iota = true;
        // Extract type name: between name and = sign
        if (std.mem.indexOfScalar(u8, after_name, '=')) |eq_pos| {
            const before_eq = std.mem.trim(u8, after_name[0..eq_pos], " \t");
            if (before_eq.len > 0) {
                state.const_block_type_name = before_eq;
            }
        }
    }

    if (state.const_block_first_entry) {
        state.const_block_first_entry = false;
        state.const_block_start_line = line_num;
    }

    if (state.const_block_has_iota) {
        state.const_block_variant_count += 1;
    } else {
        // Not iota — create individual ConstInfo
        var type_name: []const u8 = "";
        if (std.mem.indexOfScalar(u8, after_name, '=')) |eq_pos| {
            const before_eq = std.mem.trim(u8, after_name[0..eq_pos], " \t");
            if (before_eq.len > 0) {
                type_name = before_eq;
            }
        } else if (after_name.len > 0) {
            type_name = extractIdent(after_name);
        }

        try report.constants.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .line = line_num,
            .is_pub = isExported(name),
            .type_name = try allocator.dupe(u8, type_name),
            .doc_comment = try allocator.dupe(u8, ""),
        });
    }
}

fn finalizeConstBlock(
    allocator: std.mem.Allocator,
    state: *AnalyzerState,
    report: *models.FileReport,
) !void {
    if (state.const_block_has_iota and state.const_block_variant_count > 0) {
        const enum_name = if (state.const_block_type_name.len > 0)
            state.const_block_type_name
        else
            "const_group";

        try report.enums.append(allocator, .{
            .name = try allocator.dupe(u8, enum_name),
            .line = state.const_block_start_line,
            .variants_count = state.const_block_variant_count,
            .has_tag_type = false,
            .methods_count = 0,
            .is_pub = isExported(enum_name),
            .doc_comment = try allocator.dupe(u8, state.const_block_doc),
        });
    }
    state.resetConstBlock();
}

fn analyzeSingleConst(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_num: u32,
    state: *AnalyzerState,
    report: *models.FileReport,
) !void {
    var rest = line;
    if (!std.mem.startsWith(u8, rest, "const ")) return;
    rest = rest[6..];
    rest = std.mem.trim(u8, rest, " \t");
    if (rest.len > 0 and rest[0] == '(') return;

    const name = extractIdent(rest);
    if (name.len == 0) return;

    var type_name: []const u8 = "";
    var after_name = std.mem.trim(u8, rest[name.len..], " \t");
    if (std.mem.indexOfScalar(u8, after_name, '=')) |eq_pos| {
        const before_eq = std.mem.trim(u8, after_name[0..eq_pos], " \t");
        if (before_eq.len > 0) type_name = before_eq;
    } else if (after_name.len > 0) {
        type_name = extractIdent(after_name);
    }

    try report.constants.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .is_pub = isExported(name),
        .type_name = try allocator.dupe(u8, type_name),
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });
}

fn analyzeSingleVar(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_num: u32,
    state: *AnalyzerState,
    report: *models.FileReport,
) !void {
    var rest = line;
    if (!std.mem.startsWith(u8, rest, "var ")) return;
    rest = rest[4..];
    rest = std.mem.trim(u8, rest, " \t");
    if (rest.len > 0 and rest[0] == '(') return;

    const name = extractIdent(rest);
    if (name.len == 0) return;

    var type_name: []const u8 = "";
    var after_name = std.mem.trim(u8, rest[name.len..], " \t");
    if (std.mem.indexOfScalar(u8, after_name, '=')) |eq_pos| {
        const before_eq = std.mem.trim(u8, after_name[0..eq_pos], " \t");
        if (before_eq.len > 0) type_name = before_eq;
    } else if (after_name.len > 0) {
        type_name = extractIdent(after_name);
    }

    try report.constants.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .is_pub = isExported(name),
        .type_name = try allocator.dupe(u8, type_name),
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });
}

fn analyzeVarLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_num: u32,
    report: *models.FileReport,
) !void {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//") or
        std.mem.startsWith(u8, trimmed, "/*") or trimmed[0] == ')')
    {
        return;
    }

    const name = extractIdent(trimmed);
    if (name.len == 0) return;

    var type_name: []const u8 = "";
    var after_name = std.mem.trim(u8, trimmed[name.len..], " \t");
    if (std.mem.indexOfScalar(u8, after_name, '=')) |eq_pos| {
        const before_eq = std.mem.trim(u8, after_name[0..eq_pos], " \t");
        if (before_eq.len > 0) type_name = before_eq;
    } else if (after_name.len > 0) {
        type_name = extractIdent(after_name);
    }

    try report.constants.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .is_pub = isExported(name),
        .type_name = try allocator.dupe(u8, type_name),
        .doc_comment = try allocator.dupe(u8, ""),
    });
}

// ============================================================================
// Unsafe Detection
// ============================================================================

fn detectUnsafeOps(
    allocator: std.mem.Allocator,
    trimmed: []const u8,
    line_num: u32,
    state: *AnalyzerState,
    report: *models.FileReport,
) !void {
    // unsafe.Pointer — critical risk
    if (std.mem.indexOf(u8, trimmed, "unsafe.Pointer") != null) {
        try report.unsafe_ops.append(allocator, .{
            .line = line_num,
            .operation = "unsafe.Pointer",
            .context_fn = try allocator.dupe(u8, state.currentFn()),
            .risk_level = .critical,
        });
    }

    // Other unsafe operations — high risk
    if (std.mem.indexOf(u8, trimmed, "unsafe.Sizeof") != null or
        std.mem.indexOf(u8, trimmed, "unsafe.Offsetof") != null or
        std.mem.indexOf(u8, trimmed, "unsafe.Alignof") != null or
        std.mem.indexOf(u8, trimmed, "unsafe.Slice") != null or
        std.mem.indexOf(u8, trimmed, "unsafe.String") != null)
    {
        try report.unsafe_ops.append(allocator, .{
            .line = line_num,
            .operation = "unsafe operation",
            .context_fn = try allocator.dupe(u8, state.currentFn()),
            .risk_level = .high,
        });
    }

    // Goroutine detection — low risk (for visibility)
    if (std.mem.startsWith(u8, trimmed, "go ") and !std.mem.startsWith(u8, trimmed, "goto ")) {
        const after_go = std.mem.trim(u8, trimmed[3..], " \t");
        if (after_go.len > 0 and (std.ascii.isAlphabetic(after_go[0]) or
            after_go[0] == '_' or std.mem.startsWith(u8, after_go, "func")))
        {
            try report.unsafe_ops.append(allocator, .{
                .line = line_num,
                .operation = "goroutine",
                .context_fn = try allocator.dupe(u8, state.currentFn()),
                .risk_level = .low,
            });
        }
    }
}

fn detectDirective(
    allocator: std.mem.Allocator,
    trimmed: []const u8,
    line_num: u32,
    report: *models.FileReport,
) !void {
    if (std.mem.startsWith(u8, trimmed, "//go:linkname")) {
        try report.unsafe_ops.append(allocator, .{
            .line = line_num,
            .operation = "go:linkname",
            .context_fn = try allocator.dupe(u8, ""),
            .risk_level = .critical,
        });
    }
    if (std.mem.startsWith(u8, trimmed, "//go:nosplit")) {
        try report.unsafe_ops.append(allocator, .{
            .line = line_num,
            .operation = "go:nosplit",
            .context_fn = try allocator.dupe(u8, ""),
            .risk_level = .medium,
        });
    }
    if (std.mem.startsWith(u8, trimmed, "//go:noescape")) {
        try report.unsafe_ops.append(allocator, .{
            .line = line_num,
            .operation = "go:noescape",
            .context_fn = try allocator.dupe(u8, ""),
            .risk_level = .medium,
        });
    }
}

// ============================================================================
// Main Analyze Function
// ============================================================================

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
        if (state.lexer == .block_comment or state.lexer == .raw_string or state.lexer == .string_literal) {
            const code_chars = processLineForCode(&state, line, &code_buf);
            // Update brace depth from any code found
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
                const sig = state.accum.getSignature();
                const sig_trimmed = std.mem.trim(u8, sig, " \t\r");
                if (isFuncDecl(sig_trimmed)) {
                    const body = countBraceBodyAware(lines.items, state.accum.start_line - 1);
                    try analyzeFuncDecl(allocator, sig_trimmed, state.accum.start_line, body, &state, report);
                } else if (isTypeDecl(sig_trimmed)) {
                    try analyzeTypeDecl(allocator, sig_trimmed, state.accum.start_line, lines.items, &state, report);
                }
                state.accum.reset(allocator);
                state.clearDoc();
            }
            // Update brace depth
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

        // === Phase C: Empty lines ===
        if (trimmed.len == 0) {
            state.clearDoc();
            continue;
        }

        // === Phase D: Comments and directives ===
        if (std.mem.startsWith(u8, trimmed, "//")) {
            // Go compiler directives
            if (std.mem.startsWith(u8, trimmed, "//go:")) {
                try detectDirective(allocator, trimmed, line_num, report);
                state.clearDoc();
            } else {
                // Potential doc comment
                if (state.doc_comment_start == 0) {
                    state.doc_comment_start = line_num;
                }
                const doc_text = std.mem.trim(u8, trimmed[2..], " ");
                if (state.doc_comment.len == 0) {
                    state.doc_comment = doc_text;
                }
            }
            continue;
        }

        // Process line through lexer to get code-only characters
        const code_chars = processLineForCode(&state, line, &code_buf);
        // If the line started a multi-line string/comment, skip declaration detection
        if (state.lexer != .code) {
            continue;
        }

        // === Phase E: Paren-block handling ===
        if (state.in_import_block or state.in_const_block or state.in_var_block) {
            // Check if block closes on this line
            if (trimmed[0] == ')') {
                if (state.in_const_block) {
                    try finalizeConstBlock(allocator, &state, report);
                }
                state.in_import_block = false;
                state.in_const_block = false;
                state.in_var_block = false;
                state.paren_block_depth = 0;
            } else {
                // Process entry
                if (state.in_import_block) {
                    try analyzeImportLine(allocator, trimmed, line_num, report);
                } else if (state.in_const_block) {
                    try analyzeConstBlockEntry(allocator, trimmed, line_num, &state, report);
                } else if (state.in_var_block) {
                    try analyzeVarLine(allocator, trimmed, line_num, report);
                }
            }

            // Brace tracking
            for (code_chars) |c| {
                if (c == '{') state.brace_depth += 1;
                if (c == '}') {
                    state.brace_depth -= 1;
                    state.popScopesAtDepth();
                }
            }
            state.clearDoc();
            continue;
        }

        // === Phase F: Declaration detection cascade ===

        // package declaration — skip
        if (isPackageDecl(trimmed)) {
            state.clearDoc();
            continue;
        }

        // import block
        if (isImportBlock(trimmed)) {
            state.in_import_block = true;
            state.paren_block_depth = 1;
            state.clearDoc();
            continue;
        }

        // import single
        if (isImportDecl(trimmed)) {
            try analyzeSingleImport(allocator, trimmed, line_num, report);
            state.clearDoc();
            continue;
        }

        // const block
        if (isConstBlock(trimmed)) {
            state.in_const_block = true;
            state.paren_block_depth = 1;
            state.const_block_doc = state.doc_comment;
            state.clearDoc();
            continue;
        }

        // const single
        if (isConstDecl(trimmed)) {
            try analyzeSingleConst(allocator, trimmed, line_num, &state, report);
            state.clearDoc();
            for (code_chars) |c| {
                if (c == '{') state.brace_depth += 1;
                if (c == '}') {
                    state.brace_depth -= 1;
                    state.popScopesAtDepth();
                }
            }
            continue;
        }

        // var block
        if (isVarBlock(trimmed)) {
            state.in_var_block = true;
            state.paren_block_depth = 1;
            state.clearDoc();
            continue;
        }

        // var single
        if (isVarDecl(trimmed)) {
            try analyzeSingleVar(allocator, trimmed, line_num, &state, report);
            state.clearDoc();
            for (code_chars) |c| {
                if (c == '{') state.brace_depth += 1;
                if (c == '}') {
                    state.brace_depth -= 1;
                    state.popScopesAtDepth();
                }
            }
            continue;
        }

        // func declaration
        if (isFuncDecl(trimmed)) {
            if (signatureComplete(code_chars)) {
                const body = countBraceBodyAware(lines.items, line_num - 1);
                try analyzeFuncDecl(allocator, trimmed, line_num, body, &state, report);
                state.clearDoc();
            } else {
                // Start multi-line accumulator
                state.accum.active = true;
                state.accum.start_line = line_num;
                state.accum.paren_depth = 0;
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

        // type declaration
        if (isTypeDecl(trimmed)) {
            // Simple type defs (type X Y, type X = Y) have no braces;
            // only struct/interface declarations need multi-line accumulation
            const has_brace = std.mem.indexOfScalar(u8, code_chars, '{') != null;
            const is_compound = std.mem.indexOf(u8, trimmed, " struct") != null or
                std.mem.indexOf(u8, trimmed, " interface") != null;
            if (has_brace or !is_compound) {
                try analyzeTypeDecl(allocator, trimmed, line_num, lines.items, &state, report);
                state.clearDoc();
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

        // === Phase G: Unsafe/goroutine detection ===
        try detectUnsafeOps(allocator, trimmed, line_num, &state, report);

        // Clear doc for non-declaration lines
        state.clearDoc();

        // === Phase H: Brace depth + scope management ===
        for (code_chars) |c| {
            if (c == '{') state.brace_depth += 1;
            if (c == '}') {
                state.brace_depth -= 1;
                state.popScopesAtDepth();
            }
        }
    }
}

// ============================================================================
// Test Utilities
// ============================================================================

fn freeTestReport(report: *models.FileReport) void {
    const a = std.testing.allocator;
    for (report.functions.items) |f| {
        a.free(f.name);
        a.free(f.params);
        a.free(f.return_type);
        a.free(f.doc_comment);
    }
    report.functions.deinit(a);
    for (report.structs.items) |s| {
        a.free(s.name);
        a.free(s.doc_comment);
    }
    report.structs.deinit(a);
    for (report.enums.items) |e| {
        a.free(e.name);
        a.free(e.doc_comment);
    }
    report.enums.deinit(a);
    for (report.constants.items) |c| {
        a.free(c.name);
        a.free(c.type_name);
        a.free(c.doc_comment);
    }
    report.constants.deinit(a);
    for (report.imports.items) |im| {
        a.free(im.path);
        a.free(im.binding_name);
    }
    report.imports.deinit(a);
    for (report.tests.items) |t| {
        a.free(t.name);
    }
    report.tests.deinit(a);
    for (report.unsafe_ops.items) |u| {
        a.free(u.context_fn);
    }
    report.unsafe_ops.deinit(a);
}

// ============================================================================
// Unit Tests
// ============================================================================

test "simple function" {
    const source =
        \\package main
        \\
        \\func main() {
        \\    fmt.Println("hello")
        \\}
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer freeTestReport(&report);
    try std.testing.expectEqual(@as(usize, 1), report.functions.items.len);
    try std.testing.expectEqualStrings("main", report.functions.items[0].name);
    try std.testing.expect(!report.functions.items[0].is_pub);
}

test "exported method with receiver" {
    const source =
        \\func (c *Client) Connect(ctx context.Context) error {
        \\    return nil
        \\}
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer freeTestReport(&report);
    try std.testing.expectEqual(@as(usize, 1), report.functions.items.len);
    try std.testing.expectEqualStrings("Connect", report.functions.items[0].name);
    try std.testing.expect(report.functions.items[0].is_pub);
    // Params should include receiver
    try std.testing.expect(std.mem.indexOf(u8, report.functions.items[0].params, "c *Client") != null);
}

test "struct with fields" {
    const source =
        \\type Point struct {
        \\    X int
        \\    Y int
        \\    Z int
        \\}
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer freeTestReport(&report);
    try std.testing.expectEqual(@as(usize, 1), report.structs.items.len);
    try std.testing.expectEqualStrings("Point", report.structs.items[0].name);
    try std.testing.expectEqual(models.ContainerKind.@"struct", report.structs.items[0].kind);
    try std.testing.expectEqual(@as(u32, 3), report.structs.items[0].fields_count);
    try std.testing.expect(report.structs.items[0].is_pub);
}

test "interface with methods" {
    const source =
        \\type Reader interface {
        \\    Read(p []byte) (int, error)
        \\    Close() error
        \\}
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer freeTestReport(&report);
    try std.testing.expectEqual(@as(usize, 1), report.structs.items.len);
    try std.testing.expectEqualStrings("Reader", report.structs.items[0].name);
    try std.testing.expectEqual(models.ContainerKind.interface, report.structs.items[0].kind);
    try std.testing.expectEqual(@as(u32, 2), report.structs.items[0].methods_count);
}

test "iota enum pattern" {
    const source =
        \\type Color int
        \\
        \\const (
        \\    Red Color = iota
        \\    Green
        \\    Blue
        \\)
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer freeTestReport(&report);
    try std.testing.expectEqual(@as(usize, 1), report.enums.items.len);
    try std.testing.expectEqualStrings("Color", report.enums.items[0].name);
    try std.testing.expectEqual(@as(u32, 3), report.enums.items[0].variants_count);
}

test "import block" {
    const source =
        \\import (
        \\    "fmt"
        \\    "os"
        \\    "github.com/pkg/errors"
        \\)
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer freeTestReport(&report);
    try std.testing.expectEqual(@as(usize, 3), report.imports.items.len);
    try std.testing.expectEqual(models.ImportKind.std_lib, report.imports.items[0].kind);
    try std.testing.expectEqual(models.ImportKind.std_lib, report.imports.items[1].kind);
    try std.testing.expectEqual(models.ImportKind.package, report.imports.items[2].kind);
}

test "constants" {
    const source =
        \\const MaxRetries = 3
        \\const Timeout int = 30
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer freeTestReport(&report);
    try std.testing.expectEqual(@as(usize, 2), report.constants.items.len);
    try std.testing.expectEqualStrings("MaxRetries", report.constants.items[0].name);
    try std.testing.expectEqualStrings("Timeout", report.constants.items[1].name);
    try std.testing.expect(report.constants.items[0].is_pub);
    try std.testing.expect(report.constants.items[1].is_pub);
}

test "backtick strings with braces" {
    const source =
        \\func render() string {
        \\    return `<div>{not a brace}</div>`
        \\}
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer freeTestReport(&report);
    try std.testing.expectEqual(@as(usize, 1), report.functions.items.len);
    try std.testing.expectEqualStrings("render", report.functions.items[0].name);
}

test "test functions" {
    const source =
        \\func TestAdd(t *testing.T) {
        \\    if add(1, 2) != 3 {
        \\        t.Fatal("bad")
        \\    }
        \\}
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer freeTestReport(&report);
    try std.testing.expectEqual(@as(usize, 1), report.tests.items.len);
    try std.testing.expectEqualStrings("TestAdd", report.tests.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), report.functions.items.len);
}

test "unsafe operations" {
    const source =
        \\import "unsafe"
        \\
        \\func convert(p *int) unsafe.Pointer {
        \\    return unsafe.Pointer(p)
        \\}
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer freeTestReport(&report);
    // Should detect: unsafe import + unsafe.Pointer usage
    try std.testing.expect(report.unsafe_ops.items.len >= 2);
}

test "const block with string values" {
    const source =
        \\package protocol
        \\
        \\import "time"
        \\
        \\// Version represents the C-ELP protocol version
        \\type Version string
        \\
        \\const (
        \\    VersionV1   Version = "v1.0"
        \\    VersionV2   Version = "v2.0"
        \\    VersionV3   Version = "v3.0"
        \\    VersionV4   Version = "v4.0" // Self-Decrypting AI Cipher
        \\    VersionV4_5 Version = "v4.5" // Quantum-Resistant
        \\)
    ;
    var report = models.FileReport.init();
    try analyze(std.testing.allocator, source, &report);
    defer freeTestReport(&report);
    // Should detect 5 constants from the const block
    try std.testing.expectEqual(@as(usize, 5), report.constants.items.len);
    try std.testing.expectEqualStrings("VersionV1", report.constants.items[0].name);
    try std.testing.expectEqualStrings("Version", report.constants.items[0].type_name);
    // Should detect 1 type definition (Version)
    try std.testing.expectEqual(@as(usize, 1), report.structs.items.len);
    // Should detect 1 import (time)
    try std.testing.expectEqual(@as(usize, 1), report.imports.items.len);
}
