const std = @import("std");
const models = @import("../models.zig");

/// Analyze C source code using line-based token scanning.
/// Extracts functions, structs, enums, unions, includes, defines,
/// unsafe patterns, doc comments, and test functions.
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
    var line_num: u32 = 0;

    while (line_num < lines.items.len) {
        const line = lines.items[line_num];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        line_num += 1; // 1-based

        // Track multi-line /** ... */ doc comments
        if (std.mem.startsWith(u8, trimmed, "/**")) {
            state.in_doc_comment = true;
            const doc_text = extractDocFromLine(trimmed[3..]);
            if (doc_text.len > 0 and state.doc_comment.len == 0) {
                state.doc_comment = doc_text;
            }
            if (containsEnd(trimmed[3..], "*/")) {
                state.in_doc_comment = false;
            }
            continue;
        }

        if (state.in_doc_comment) {
            if (containsEnd(trimmed, "*/")) {
                state.in_doc_comment = false;
            } else if (state.doc_comment.len == 0) {
                // Grab first meaningful line of doc comment
                const cleaned = cleanDocLine(trimmed);
                if (cleaned.len > 0) {
                    state.doc_comment = cleaned;
                }
            }
            continue;
        }

        // Single-line // doc comment before declaration
        if (std.mem.startsWith(u8, trimmed, "//")) {
            const doc_text = std.mem.trim(u8, trimmed[2..], " \t");
            if (doc_text.len > 0 and state.doc_comment.len == 0) {
                state.doc_comment = doc_text;
            }
            continue;
        }

        // Regular /* ... */ comments (non-doc)
        if (std.mem.startsWith(u8, trimmed, "/*")) {
            state.clearDoc();
            if (!containsEnd(trimmed[2..], "*/")) {
                line_num = skipUntilEnd(lines.items, line_num, "*/");
            }
            continue;
        }

        // Empty lines clear doc comment
        if (trimmed.len == 0) {
            state.clearDoc();
            continue;
        }

        // === Preprocessor directives ===

        if (trimmed[0] == '#') {
            if (std.mem.startsWith(u8, trimmed, "#include")) {
                try analyzeInclude(allocator, trimmed, line_num, report);
            } else if (std.mem.startsWith(u8, trimmed, "#define")) {
                try analyzeDefine(allocator, trimmed, line_num, &state, report);
            }
            state.clearDoc();
            continue;
        }

        // === Type declarations ===

        // typedef struct
        if (std.mem.startsWith(u8, trimmed, "typedef struct")) {
            try analyzeTypedefStruct(allocator, trimmed, line_num, lines.items, &state, report);
            const body_lines = countBraceBody(lines.items, line_num - 1);
            if (body_lines > 1) {
                line_num += body_lines - 1;
            }
            state.clearDoc();
            continue;
        }

        // typedef enum
        if (std.mem.startsWith(u8, trimmed, "typedef enum")) {
            try analyzeTypedefEnum(allocator, trimmed, line_num, lines.items, &state, report);
            const body_lines = countBraceBody(lines.items, line_num - 1);
            if (body_lines > 1) {
                line_num += body_lines - 1;
            }
            state.clearDoc();
            continue;
        }

        // typedef union
        if (std.mem.startsWith(u8, trimmed, "typedef union")) {
            try analyzeTypedefUnion(allocator, trimmed, line_num, lines.items, &state, report);
            const body_lines = countBraceBody(lines.items, line_num - 1);
            if (body_lines > 1) {
                line_num += body_lines - 1;
            }
            state.clearDoc();
            continue;
        }

        // struct name {
        if (isStructDecl(trimmed)) {
            try analyzeStructDecl(allocator, trimmed, line_num, lines.items, &state, report);
            const body_lines = countBraceBody(lines.items, line_num - 1);
            if (body_lines > 1) {
                line_num += body_lines - 1;
            }
            state.clearDoc();
            continue;
        }

        // enum name {
        if (isEnumDecl(trimmed)) {
            try analyzeEnumDecl(allocator, trimmed, line_num, lines.items, &state, report);
            const body_lines = countBraceBody(lines.items, line_num - 1);
            if (body_lines > 1) {
                line_num += body_lines - 1;
            }
            state.clearDoc();
            continue;
        }

        // union name {
        if (isUnionDecl(trimmed)) {
            try analyzeUnionDecl(allocator, trimmed, line_num, lines.items, &state, report);
            const body_lines = countBraceBody(lines.items, line_num - 1);
            if (body_lines > 1) {
                line_num += body_lines - 1;
            }
            state.clearDoc();
            continue;
        }

        // === Function declarations ===
        if (isFunctionDecl(trimmed, lines.items, line_num - 1)) {
            const body_lines = countBraceBody(lines.items, line_num - 1);
            try analyzeFunctionDecl(allocator, trimmed, line_num, body_lines, &state, report);
            if (body_lines > 1) {
                line_num += body_lines - 1;
            }
            state.clearDoc();
            continue;
        }

        // Detect unsafe patterns on any line
        try detectUnsafePatterns(allocator, trimmed, line_num, report);

        state.clearDoc();
    }
}

const AnalyzerState = struct {
    doc_comment: []const u8 = "",
    in_doc_comment: bool = false,

    fn clearDoc(self: *AnalyzerState) void {
        self.doc_comment = "";
        self.in_doc_comment = false;
    }
};

fn analyzeInclude(allocator: std.mem.Allocator, line: []const u8, line_num: u32, report: *models.FileReport) !void {
    // #include "local.h" or #include <system.h>
    const rest = std.mem.trim(u8, line[8..], " \t");

    if (rest.len < 2) return;

    var path: []const u8 = "";
    var kind: models.ImportKind = .std_lib;

    if (rest[0] == '"') {
        // Local include
        if (std.mem.indexOfScalar(u8, rest[1..], '"')) |end| {
            path = rest[1 .. end + 1];
            kind = .local;
        }
    } else if (rest[0] == '<') {
        // System include
        if (std.mem.indexOfScalar(u8, rest[1..], '>')) |end| {
            path = rest[1 .. end + 1];
            kind = .std_lib;
        }
    }

    if (path.len == 0) return;

    try report.imports.append(allocator, .{
        .path = try allocator.dupe(u8, path),
        .kind = kind,
        .binding_name = "",
        .line = line_num,
    });
}

fn analyzeDefine(allocator: std.mem.Allocator, line: []const u8, line_num: u32, state: *AnalyzerState, report: *models.FileReport) !void {
    // #define NAME ... or #define NAME(x) ...
    const rest = std.mem.trim(u8, line[7..], " \t");
    const name = extractIdent(rest);
    if (name.len == 0) return;

    // Skip include guards (common pattern: NAME_H, _NAME_H_, __NAME_H__)
    if (std.mem.endsWith(u8, name, "_H") or std.mem.endsWith(u8, name, "_H_") or std.mem.endsWith(u8, name, "_H__")) {
        return;
    }

    try report.constants.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .is_pub = true, // defines are always "public" in their translation unit
        .type_name = "#define",
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });
}

fn analyzeTypedefStruct(allocator: std.mem.Allocator, line: []const u8, line_num: u32, all_lines: []const []const u8, state: *AnalyzerState, report: *models.FileReport) !void {
    // typedef struct { ... } Name;
    // typedef struct Tag { ... } Name;
    var name: []const u8 = "";
    const fields = countFieldsInBraces(all_lines, line_num - 1);

    // Try to find name after closing brace: } Name;
    const closing_line = findClosingBraceLine(all_lines, line_num - 1);
    if (closing_line) |cl| {
        if (cl < all_lines.len) {
            const ctrimmed = std.mem.trim(u8, all_lines[cl], " \t\r");
            if (std.mem.startsWith(u8, ctrimmed, "}")) {
                const after_brace = std.mem.trim(u8, ctrimmed[1..], " \t;");
                // Skip __attribute__ annotations
                const clean = stripAttribute(after_brace);
                if (clean.len > 0) {
                    name = extractIdent(clean);
                }
            }
        }
    }

    // Fallback: try tag name from "typedef struct Tag"
    if (name.len == 0) {
        const rest = std.mem.trim(u8, line[14..], " \t"); // after "typedef struct"
        const tag = extractIdent(rest);
        if (tag.len > 0 and !std.mem.eql(u8, tag, "{")) {
            name = tag;
        }
    }

    if (name.len == 0) name = "<anonymous>";

    try report.structs.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .kind = .@"struct",
        .fields_count = fields,
        .methods_count = 0,
        .is_pub = true,
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });
}

fn analyzeTypedefEnum(allocator: std.mem.Allocator, line: []const u8, line_num: u32, all_lines: []const []const u8, state: *AnalyzerState, report: *models.FileReport) !void {
    var name: []const u8 = "";
    const variants = countFieldsInBraces(all_lines, line_num - 1);

    const closing_line = findClosingBraceLine(all_lines, line_num - 1);
    if (closing_line) |cl| {
        if (cl < all_lines.len) {
            const ctrimmed = std.mem.trim(u8, all_lines[cl], " \t\r");
            if (std.mem.startsWith(u8, ctrimmed, "}")) {
                const after_brace = std.mem.trim(u8, ctrimmed[1..], " \t;");
                if (after_brace.len > 0) {
                    name = extractIdent(after_brace);
                }
            }
        }
    }

    if (name.len == 0) {
        const rest = std.mem.trim(u8, line[12..], " \t");
        const tag = extractIdent(rest);
        if (tag.len > 0 and !std.mem.eql(u8, tag, "{")) {
            name = tag;
        }
    }

    if (name.len == 0) name = "<anonymous>";

    try report.enums.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .variants_count = variants,
        .has_tag_type = false,
        .methods_count = 0,
        .is_pub = true,
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });
}

fn analyzeTypedefUnion(allocator: std.mem.Allocator, line: []const u8, line_num: u32, all_lines: []const []const u8, state: *AnalyzerState, report: *models.FileReport) !void {
    var name: []const u8 = "";
    const fields = countFieldsInBraces(all_lines, line_num - 1);

    const closing_line = findClosingBraceLine(all_lines, line_num - 1);
    if (closing_line) |cl| {
        if (cl < all_lines.len) {
            const ctrimmed = std.mem.trim(u8, all_lines[cl], " \t\r");
            if (std.mem.startsWith(u8, ctrimmed, "}")) {
                const after_brace = std.mem.trim(u8, ctrimmed[1..], " \t;");
                if (after_brace.len > 0) {
                    name = extractIdent(after_brace);
                }
            }
        }
    }

    if (name.len == 0) {
        const rest = std.mem.trim(u8, line[13..], " \t");
        const tag = extractIdent(rest);
        if (tag.len > 0 and !std.mem.eql(u8, tag, "{")) {
            name = tag;
        }
    }

    if (name.len == 0) name = "<anonymous>";

    try report.unions.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .fields_count = fields,
        .has_tag_type = false,
        .methods_count = 0,
        .is_pub = true,
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });
}

fn analyzeStructDecl(allocator: std.mem.Allocator, line: []const u8, line_num: u32, all_lines: []const []const u8, state: *AnalyzerState, report: *models.FileReport) !void {
    // "struct name {" at top level
    const rest = std.mem.trim(u8, line[6..], " \t"); // after "struct"
    const name = extractIdent(rest);
    if (name.len == 0) return;

    const fields = countFieldsInBraces(all_lines, line_num - 1);

    try report.structs.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .kind = .@"struct",
        .fields_count = fields,
        .methods_count = 0,
        .is_pub = true,
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });
}

fn analyzeEnumDecl(allocator: std.mem.Allocator, line: []const u8, line_num: u32, all_lines: []const []const u8, state: *AnalyzerState, report: *models.FileReport) !void {
    const rest = std.mem.trim(u8, line[4..], " \t"); // after "enum"
    const name = extractIdent(rest);
    if (name.len == 0) return;

    const variants = countFieldsInBraces(all_lines, line_num - 1);

    try report.enums.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .variants_count = variants,
        .has_tag_type = false,
        .methods_count = 0,
        .is_pub = true,
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });
}

fn analyzeUnionDecl(allocator: std.mem.Allocator, line: []const u8, line_num: u32, all_lines: []const []const u8, state: *AnalyzerState, report: *models.FileReport) !void {
    const rest = std.mem.trim(u8, line[5..], " \t"); // after "union"
    const name = extractIdent(rest);
    if (name.len == 0) return;

    const fields = countFieldsInBraces(all_lines, line_num - 1);

    try report.unions.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .fields_count = fields,
        .has_tag_type = false,
        .methods_count = 0,
        .is_pub = true,
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });
}

fn analyzeFunctionDecl(allocator: std.mem.Allocator, line: []const u8, line_num: u32, body_lines: u32, state: *AnalyzerState, report: *models.FileReport) !void {
    var is_static = false;
    var is_extern = false;
    var rest = line;

    // Strip leading qualifiers
    if (std.mem.startsWith(u8, rest, "static ")) {
        is_static = true;
        rest = rest[7..];
    }
    if (std.mem.startsWith(u8, rest, "extern ")) {
        is_extern = true;
        rest = rest[7..];
        // Skip optional "C" or ABI string
        if (rest.len > 0 and rest[0] == '"') {
            if (std.mem.indexOfScalar(u8, rest[1..], '"')) |end| {
                rest = std.mem.trim(u8, rest[end + 2 ..], " ");
            }
        }
    }
    if (std.mem.startsWith(u8, rest, "inline ")) {
        rest = rest[7..];
    }
    if (std.mem.startsWith(u8, rest, "static inline ")) {
        is_static = true;
        rest = rest[14..];
    }

    // Find function name: last identifier before '('
    const paren_pos = std.mem.indexOfScalar(u8, rest, '(') orelse return;
    const before_paren = trimRight(u8, rest[0..paren_pos], " \t");
    if (before_paren.len == 0) return;

    // Walk backwards to find the function name
    const name_end = before_paren.len;
    var name_start = name_end;
    while (name_start > 0) {
        const c = before_paren[name_start - 1];
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            name_start -= 1;
        } else break;
    }

    const name = before_paren[name_start..name_end];
    if (name.len == 0) return;

    // Return type is everything before the name
    const ret_type = std.mem.trim(u8, before_paren[0..name_start], " \t*");

    // Params: text between ( and )
    var params: []const u8 = "";
    if (findMatchingParen(rest, paren_pos)) |close_paren| {
        params = rest[paren_pos + 1 .. close_paren];
    }

    // Detect test functions: test_* or *_test
    const is_test = std.mem.startsWith(u8, name, "test_") or std.mem.endsWith(u8, name, "_test");
    if (is_test) {
        try report.tests.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .line = line_num,
        });
    }

    try report.functions.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .end_line = line_num + body_lines,
        .body_lines = body_lines,
        .params = try allocator.dupe(u8, params),
        .return_type = try allocator.dupe(u8, ret_type),
        .is_pub = !is_static,
        .is_extern = is_extern,
        .is_export = false,
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });
}

fn detectUnsafePatterns(allocator: std.mem.Allocator, line: []const u8, line_num: u32, report: *models.FileReport) !void {
    // Detect common unsafe C patterns
    const patterns = [_]struct { needle: []const u8, op: []const u8, risk: models.RiskLevel }{
        .{ .needle = "malloc(", .op = "malloc", .risk = .medium },
        .{ .needle = "calloc(", .op = "calloc", .risk = .medium },
        .{ .needle = "realloc(", .op = "realloc", .risk = .medium },
        .{ .needle = "free(", .op = "free", .risk = .medium },
        .{ .needle = "memcpy(", .op = "memcpy", .risk = .medium },
        .{ .needle = "memmove(", .op = "memmove", .risk = .medium },
        .{ .needle = "strcpy(", .op = "strcpy", .risk = .high },
        .{ .needle = "strcat(", .op = "strcat", .risk = .high },
        .{ .needle = "sprintf(", .op = "sprintf", .risk = .high },
        .{ .needle = "gets(", .op = "gets", .risk = .critical },
    };

    for (&patterns) |p| {
        if (std.mem.indexOf(u8, line, p.needle) != null) {
            try report.unsafe_ops.append(allocator, .{
                .line = line_num,
                .operation = p.op,
                .context_fn = "",
                .risk_level = p.risk,
            });
        }
    }

    // Detect void* casts: (void *)
    if (std.mem.indexOf(u8, line, "(void *)") != null or std.mem.indexOf(u8, line, "(void*)") != null) {
        try report.unsafe_ops.append(allocator, .{
            .line = line_num,
            .operation = "void* cast",
            .context_fn = "",
            .risk_level = .medium,
        });
    }
}

// === Detection helpers ===

fn isFunctionDecl(line: []const u8, all_lines: []const []const u8, line_idx: usize) bool {
    // A C function declaration at file scope:
    // - Contains '(' but not '#' (preprocessor)
    // - Not typedef, struct, enum, union keyword at start
    // - Has a '{' on this line or the next few lines (function body)
    // - Not just a prototype (ends with ;)

    if (line.len == 0) return false;
    if (line[0] == '#') return false;

    // Skip if starts with common non-function keywords
    if (std.mem.startsWith(u8, line, "typedef ")) return false;
    if (std.mem.startsWith(u8, line, "struct ")) return false;
    if (std.mem.startsWith(u8, line, "enum ")) return false;
    if (std.mem.startsWith(u8, line, "union ")) return false;
    if (std.mem.startsWith(u8, line, "return ")) return false;
    if (std.mem.startsWith(u8, line, "if ") or std.mem.startsWith(u8, line, "if(")) return false;
    if (std.mem.startsWith(u8, line, "for ") or std.mem.startsWith(u8, line, "for(")) return false;
    if (std.mem.startsWith(u8, line, "while ") or std.mem.startsWith(u8, line, "while(")) return false;
    if (std.mem.startsWith(u8, line, "switch ") or std.mem.startsWith(u8, line, "switch(")) return false;
    if (std.mem.startsWith(u8, line, "{") or std.mem.startsWith(u8, line, "}")) return false;

    // Must contain '('
    const paren_pos = std.mem.indexOfScalar(u8, line, '(') orelse return false;

    // Check there's an identifier before the paren (function name)
    if (paren_pos == 0) return false;
    const before_paren = trimRight(u8, line[0..paren_pos], " \t");
    if (before_paren.len == 0) return false;
    const last_char = before_paren[before_paren.len - 1];
    if (!std.ascii.isAlphanumeric(last_char) and last_char != '_') return false;

    // Check for function body: '{' on this line or next few lines
    // (prototypes end with ';')
    if (std.mem.indexOfScalar(u8, line, '{') != null) return true;
    if (std.mem.endsWith(u8, std.mem.trim(u8, line, " \t\r"), ";")) return false;

    // Check next 2 lines for opening brace (K&R style)
    var look = line_idx + 1;
    while (look < all_lines.len and look < line_idx + 3) : (look += 1) {
        const next = std.mem.trim(u8, all_lines[look], " \t\r");
        if (next.len > 0 and next[0] == '{') return true;
        if (std.mem.endsWith(u8, next, ";")) return false;
    }

    return false;
}

fn isStructDecl(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "struct ")) return false;
    // Must have name and brace, not just "struct foo;"
    return std.mem.indexOfScalar(u8, line, '{') != null or
        (!std.mem.endsWith(u8, trimRight(u8, line, " \t\r"), ";"));
}

fn isEnumDecl(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "enum ")) return false;
    return std.mem.indexOfScalar(u8, line, '{') != null;
}

fn isUnionDecl(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "union ")) return false;
    return std.mem.indexOfScalar(u8, line, '{') != null;
}

// === Utility functions ===

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

fn countBraceBody(all_lines: []const []const u8, start_line_idx: usize) u32 {
    var depth: i32 = 0;
    var started = false;
    var count: u32 = 0;

    for (all_lines[start_line_idx..]) |line| {
        count += 1;
        for (line) |c| {
            if (c == '{') {
                depth += 1;
                started = true;
            }
            if (c == '}') depth -= 1;
        }
        if (started and depth <= 0) return count;
    }
    return count;
}

fn countFieldsInBraces(all_lines: []const []const u8, start_line_idx: usize) u32 {
    var depth: i32 = 0;
    var started = false;
    var fields: u32 = 0;

    for (all_lines[start_line_idx..]) |line| {
        for (line) |c| {
            if (c == '{') {
                depth += 1;
                started = true;
            }
            if (c == '}') depth -= 1;
        }
        if (started and depth <= 0) break;

        if (started and depth == 1) {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (std.mem.startsWith(u8, trimmed, "//")) continue;
            if (std.mem.startsWith(u8, trimmed, "/*")) continue;
            if (std.mem.startsWith(u8, trimmed, "*")) continue;
            if (std.mem.startsWith(u8, trimmed, "#")) continue;
            if (std.mem.startsWith(u8, trimmed, "{") or std.mem.startsWith(u8, trimmed, "}")) continue;
            // Count lines that look like declarations (contain ; or ,)
            if (std.mem.indexOfScalar(u8, trimmed, ';') != null or std.mem.indexOfScalar(u8, trimmed, ',') != null) {
                fields += 1;
            }
        }
    }
    return fields;
}

fn findClosingBraceLine(all_lines: []const []const u8, start_line_idx: usize) ?usize {
    var depth: i32 = 0;
    var started = false;

    for (all_lines[start_line_idx..], start_line_idx..) |line, idx| {
        for (line) |c| {
            if (c == '{') {
                depth += 1;
                started = true;
            }
            if (c == '}') depth -= 1;
        }
        if (started and depth <= 0) return idx;
    }
    return null;
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

fn containsEnd(line: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, line, needle) != null;
}

fn skipUntilEnd(all_lines: []const []const u8, start_line_num: u32, needle: []const u8) u32 {
    var idx = start_line_num;
    while (idx < all_lines.len) : (idx += 1) {
        if (std.mem.indexOf(u8, all_lines[idx], needle) != null) {
            return idx + 1;
        }
    }
    return idx;
}

fn extractDocFromLine(s: []const u8) []const u8 {
    var text = std.mem.trim(u8, s, " \t*");
    if (std.mem.endsWith(u8, text, "*/")) {
        text = trimRight(u8, text[0 .. text.len - 2], " \t*");
    }
    return text;
}

fn cleanDocLine(s: []const u8) []const u8 {
    var text = std.mem.trim(u8, s, " \t*");
    if (text.len > 0 and text[0] == '*') {
        text = std.mem.trim(u8, text[1..], " \t");
    }
    return text;
}

fn stripAttribute(s: []const u8) []const u8 {
    if (std.mem.indexOf(u8, s, "__attribute__")) |idx| {
        return std.mem.trim(u8, s[0..idx], " \t");
    }
    return s;
}

/// Trim trailing characters from a slice (Zig 0.16 doesn't have std.mem.trimRight).
fn trimRight(comptime T: type, s: []const T, values: []const T) []const T {
    var end = s.len;
    while (end > 0) {
        var found = false;
        for (values) |v| {
            if (s[end - 1] == v) {
                found = true;
                break;
            }
        }
        if (!found) break;
        end -= 1;
    }
    return s[0..end];
}
