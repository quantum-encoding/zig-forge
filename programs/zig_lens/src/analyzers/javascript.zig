const std = @import("std");
const models = @import("../models.zig");

/// Analyze JavaScript/TypeScript/Svelte source code using line-based scanning.
/// Extracts functions, classes, interfaces, type aliases, enums (TS), imports,
/// exports, tests, JSDoc comments, constants, and unsafe patterns.
pub fn analyze(allocator: std.mem.Allocator, source: []const u8, report: *models.FileReport) !void {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(allocator);

    var start: usize = 0;
    for (source, 0..) |ch, i| {
        if (ch == '\n') {
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

        // Track JSDoc /** ... */ comments
        if (state.in_jsdoc) {
            if (std.mem.indexOf(u8, trimmed, "*/") != null) {
                state.in_jsdoc = false;
            } else if (state.doc_comment.len == 0) {
                const cleaned = cleanJsdocLine(trimmed);
                if (cleaned.len > 0) {
                    state.doc_comment = cleaned;
                }
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "/**")) {
            state.in_jsdoc = true;
            // Check if closes on same line
            if (std.mem.indexOf(u8, trimmed[3..], "*/") != null) {
                state.in_jsdoc = false;
                const doc = extractInlineJsdoc(trimmed);
                if (doc.len > 0) state.doc_comment = doc;
            } else {
                const after = std.mem.trim(u8, trimmed[3..], " \t*");
                if (after.len > 0 and state.doc_comment.len == 0) {
                    state.doc_comment = after;
                }
            }
            continue;
        }

        // Regular block comments /* ... */
        if (std.mem.startsWith(u8, trimmed, "/*")) {
            if (std.mem.indexOf(u8, trimmed[2..], "*/") == null) {
                // Skip to end of block comment
                line_num = skipUntilEnd(lines.items, line_num, "*/");
            }
            state.clearDoc();
            continue;
        }

        // Single-line comments
        if (std.mem.startsWith(u8, trimmed, "//")) {
            const text = std.mem.trim(u8, trimmed[2..], " \t");
            if (text.len > 0 and state.doc_comment.len == 0) {
                state.doc_comment = text;
            }
            continue;
        }

        if (trimmed.len == 0) {
            state.clearDoc();
            continue;
        }

        // Skip decorators/annotations
        if (trimmed[0] == '@') {
            continue;
        }

        // === Svelte script block detection ===
        if (std.mem.startsWith(u8, trimmed, "<script")) {
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "</script>")) {
            continue;
        }

        // === TypeScript: interface ===
        if (isInterfaceDecl(trimmed)) {
            const body_lines = countBraceBody(lines.items, line_num - 1);
            try analyzeInterface(allocator, trimmed, line_num, lines.items, &state, report);
            if (body_lines > 1) line_num += body_lines - 1;
            state.clearDoc();
            continue;
        }

        // === TypeScript: type alias ===
        if (isTypeAliasDecl(trimmed)) {
            try analyzeTypeAlias(allocator, trimmed, line_num, &state, report);
            state.clearDoc();
            continue;
        }

        // === TypeScript: enum ===
        if (isEnumDecl(trimmed)) {
            const body_lines = countBraceBody(lines.items, line_num - 1);
            try analyzeEnum(allocator, trimmed, line_num, lines.items, &state, report);
            if (body_lines > 1) line_num += body_lines - 1;
            state.clearDoc();
            continue;
        }

        // === Class ===
        if (isClassDecl(trimmed)) {
            const body_lines = countBraceBody(lines.items, line_num - 1);
            try analyzeClass(allocator, trimmed, line_num, lines.items, &state, report);
            if (body_lines > 1) line_num += body_lines - 1;
            state.clearDoc();
            continue;
        }

        // === Function declarations ===
        if (isFunctionDecl(trimmed)) {
            const body_lines = countBraceBody(lines.items, line_num - 1);
            try analyzeFunction(allocator, trimmed, line_num, body_lines, &state, report);
            if (body_lines > 1) line_num += body_lines - 1;
            state.clearDoc();
            continue;
        }

        // === Arrow function / const assignment ===
        if (isArrowFnDecl(trimmed)) {
            const body_lines = countBraceBody(lines.items, line_num - 1);
            try analyzeArrowFn(allocator, trimmed, line_num, body_lines, &state, report);
            if (body_lines > 1) line_num += body_lines - 1;
            state.clearDoc();
            continue;
        }

        // === Import statements ===
        if (isImportDecl(trimmed)) {
            try analyzeImport(allocator, trimmed, line_num, report);
            state.clearDoc();
            continue;
        }

        // === require() calls ===
        if (isRequireDecl(trimmed)) {
            try analyzeRequire(allocator, trimmed, line_num, report);
            state.clearDoc();
            continue;
        }

        // === Test functions: describe/it/test ===
        if (isTestCall(trimmed)) {
            try analyzeTest(allocator, trimmed, line_num, report);
            const body_lines = countBraceBody(lines.items, line_num - 1);
            if (body_lines > 1) line_num += body_lines - 1;
            state.clearDoc();
            continue;
        }

        // Unsafe patterns
        try detectUnsafePatterns(allocator, trimmed, line_num, report);

        state.clearDoc();
    }
}

const AnalyzerState = struct {
    doc_comment: []const u8 = "",
    in_jsdoc: bool = false,

    fn clearDoc(self: *AnalyzerState) void {
        self.doc_comment = "";
    }
};

fn analyzeFunction(allocator: std.mem.Allocator, line: []const u8, line_num: u32, body_lines: u32, state: *AnalyzerState, report: *models.FileReport) !void {
    var rest = line;
    var is_pub = false;
    var is_export = false;

    if (std.mem.startsWith(u8, rest, "export ")) {
        is_pub = true;
        is_export = true;
        rest = rest[7..];
        if (std.mem.startsWith(u8, rest, "default ")) rest = rest[8..];
    }

    if (std.mem.startsWith(u8, rest, "async ")) rest = rest[6..];

    if (!std.mem.startsWith(u8, rest, "function")) return;
    rest = rest[8..];
    if (rest.len > 0 and rest[0] == '*') rest = rest[1..]; // generator
    rest = std.mem.trim(u8, rest, " \t");

    const name = extractIdent(rest);
    if (name.len == 0) return; // anonymous

    var params: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '(')) |paren| {
        if (findMatchingParen(rest, paren)) |close| {
            params = rest[paren + 1 .. close];
        }
    }

    var ret_type: []const u8 = "";
    if (std.mem.indexOf(u8, rest, "):")) |idx| {
        const after = std.mem.trim(u8, rest[idx + 2 ..], " \t");
        if (std.mem.indexOfScalar(u8, after, '{')) |brace| {
            ret_type = std.mem.trim(u8, after[0..brace], " \t");
        } else {
            ret_type = after;
        }
    }

    try report.functions.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .end_line = line_num + body_lines,
        .body_lines = body_lines,
        .params = try allocator.dupe(u8, params),
        .return_type = try allocator.dupe(u8, ret_type),
        .is_pub = is_pub,
        .is_extern = false,
        .is_export = is_export,
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });
}

fn analyzeArrowFn(allocator: std.mem.Allocator, line: []const u8, line_num: u32, body_lines: u32, state: *AnalyzerState, report: *models.FileReport) !void {
    var rest = line;
    var is_pub = false;
    var is_export = false;

    if (std.mem.startsWith(u8, rest, "export ")) {
        is_pub = true;
        is_export = true;
        rest = rest[7..];
        if (std.mem.startsWith(u8, rest, "default ")) rest = rest[8..];
    }

    // const name = ... => or const name = async ... =>
    if (!std.mem.startsWith(u8, rest, "const ") and !std.mem.startsWith(u8, rest, "let ")) return;
    rest = rest[std.mem.indexOf(u8, rest, " ").? + 1 ..];
    rest = std.mem.trim(u8, rest, " \t");

    const name = extractIdent(rest);
    if (name.len == 0) return;

    // Extract params from (...) =>
    var params: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '(')) |paren| {
        if (findMatchingParen(rest, paren)) |close| {
            params = rest[paren + 1 .. close];
        }
    }

    try report.functions.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .end_line = line_num + body_lines,
        .body_lines = body_lines,
        .params = try allocator.dupe(u8, params),
        .return_type = "",
        .is_pub = is_pub,
        .is_extern = false,
        .is_export = is_export,
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });
}

fn analyzeClass(allocator: std.mem.Allocator, line: []const u8, line_num: u32, all_lines: []const []const u8, state: *AnalyzerState, report: *models.FileReport) !void {
    var rest = line;
    var is_pub = false;

    if (std.mem.startsWith(u8, rest, "export ")) {
        is_pub = true;
        rest = rest[7..];
        if (std.mem.startsWith(u8, rest, "default ")) rest = rest[8..];
    }
    if (std.mem.startsWith(u8, rest, "abstract ")) rest = rest[9..];

    if (!std.mem.startsWith(u8, rest, "class ")) return;
    rest = rest[6..];

    const name = extractIdent(rest);
    if (name.len == 0) return;

    // Count methods and fields inside braces
    var methods: u32 = 0;
    var fields: u32 = 0;
    var depth: i32 = 0;
    var started = false;

    const start_idx = line_num - 1;
    for (all_lines[start_idx..]) |bline| {
        for (bline) |ch| {
            if (ch == '{') { depth += 1; started = true; }
            if (ch == '}') depth -= 1;
        }
        if (started and depth <= 0) break;

        if (started and depth == 1) {
            const btrimmed = std.mem.trim(u8, bline, " \t\r");
            if (btrimmed.len == 0 or std.mem.startsWith(u8, btrimmed, "//") or std.mem.startsWith(u8, btrimmed, "/*") or std.mem.startsWith(u8, btrimmed, "*")) continue;
            if (isMethodDecl(btrimmed)) {
                methods += 1;
            } else if (isFieldDecl(btrimmed)) {
                fields += 1;
            }
        }
    }

    try report.structs.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .kind = .class,
        .fields_count = fields,
        .methods_count = methods,
        .is_pub = is_pub,
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });
}

fn analyzeInterface(allocator: std.mem.Allocator, line: []const u8, line_num: u32, all_lines: []const []const u8, state: *AnalyzerState, report: *models.FileReport) !void {
    var rest = line;
    var is_pub = false;

    if (std.mem.startsWith(u8, rest, "export ")) {
        is_pub = true;
        rest = rest[7..];
    }

    if (!std.mem.startsWith(u8, rest, "interface ")) return;
    rest = rest[10..];

    const name = extractIdent(rest);
    if (name.len == 0) return;

    // Count fields (lines with : inside braces)
    var fields: u32 = 0;
    var methods: u32 = 0;
    var depth: i32 = 0;
    var started = false;

    const start_idx = line_num - 1;
    for (all_lines[start_idx..]) |bline| {
        for (bline) |ch| {
            if (ch == '{') { depth += 1; started = true; }
            if (ch == '}') depth -= 1;
        }
        if (started and depth <= 0) break;

        if (started and depth == 1) {
            const btrimmed = std.mem.trim(u8, bline, " \t\r");
            if (btrimmed.len == 0 or std.mem.startsWith(u8, btrimmed, "//") or std.mem.startsWith(u8, btrimmed, "/*") or std.mem.startsWith(u8, btrimmed, "*")) continue;
            // Method signature: name(...)
            if (std.mem.indexOfScalar(u8, btrimmed, '(') != null) {
                methods += 1;
            } else if (std.mem.indexOfScalar(u8, btrimmed, ':') != null) {
                fields += 1;
            }
        }
    }

    try report.structs.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .kind = .interface,
        .fields_count = fields,
        .methods_count = methods,
        .is_pub = is_pub,
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });
}

fn analyzeTypeAlias(allocator: std.mem.Allocator, line: []const u8, line_num: u32, state: *AnalyzerState, report: *models.FileReport) !void {
    var rest = line;
    var is_pub = false;

    if (std.mem.startsWith(u8, rest, "export ")) {
        is_pub = true;
        rest = rest[7..];
    }

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
        .is_pub = is_pub,
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });
}

fn analyzeEnum(allocator: std.mem.Allocator, line: []const u8, line_num: u32, all_lines: []const []const u8, state: *AnalyzerState, report: *models.FileReport) !void {
    var rest = line;
    var is_pub = false;

    if (std.mem.startsWith(u8, rest, "export ")) {
        is_pub = true;
        rest = rest[7..];
    }
    if (std.mem.startsWith(u8, rest, "const ")) rest = rest[6..];

    if (!std.mem.startsWith(u8, rest, "enum ")) return;
    rest = rest[5..];

    const name = extractIdent(rest);
    if (name.len == 0) return;

    // Count variants
    var variants: u32 = 0;
    var depth: i32 = 0;
    var started = false;

    const start_idx = line_num - 1;
    for (all_lines[start_idx..]) |bline| {
        for (bline) |ch| {
            if (ch == '{') { depth += 1; started = true; }
            if (ch == '}') depth -= 1;
        }
        if (started and depth <= 0) break;

        if (started and depth == 1) {
            const btrimmed = std.mem.trim(u8, bline, " \t\r");
            if (btrimmed.len == 0 or std.mem.startsWith(u8, btrimmed, "//")) continue;
            if (btrimmed.len > 0 and btrimmed[0] != '{' and btrimmed[0] != '}') {
                variants += 1;
            }
        }
    }

    try report.enums.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .variants_count = variants,
        .has_tag_type = false,
        .methods_count = 0,
        .is_pub = is_pub,
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });
}

fn analyzeImport(allocator: std.mem.Allocator, line: []const u8, line_num: u32, report: *models.FileReport) !void {
    // import ... from 'path' or import 'path'
    var path: []const u8 = "";
    var binding: []const u8 = "";

    if (std.mem.indexOf(u8, line, " from ")) |from_idx| {
        // Extract path from after "from"
        const after_from = std.mem.trim(u8, line[from_idx + 6 ..], " \t;");
        path = stripQuotes(after_from);

        // Extract binding (between "import" and "from")
        const import_start = if (std.mem.startsWith(u8, line, "import ")) @as(usize, 7) else 0;
        binding = std.mem.trim(u8, line[import_start..from_idx], " \t{}");
    } else {
        // import 'path' (side-effect import)
        const rest = if (std.mem.startsWith(u8, line, "import ")) line[7..] else line;
        path = stripQuotes(std.mem.trim(u8, rest, " \t;"));
    }

    if (path.len == 0) return;

    try report.imports.append(allocator, .{
        .path = try allocator.dupe(u8, path),
        .kind = classifyJsImport(path),
        .binding_name = try allocator.dupe(u8, binding),
        .line = line_num,
    });
}

fn analyzeRequire(allocator: std.mem.Allocator, line: []const u8, line_num: u32, report: *models.FileReport) !void {
    // const x = require('path')
    if (std.mem.indexOf(u8, line, "require(")) |req_idx| {
        const after = line[req_idx + 8 ..];
        if (std.mem.indexOfScalar(u8, after, ')')) |close| {
            const path = stripQuotes(std.mem.trim(u8, after[0..close], " \t"));
            if (path.len > 0) {
                try report.imports.append(allocator, .{
                    .path = try allocator.dupe(u8, path),
                    .kind = classifyJsImport(path),
                    .binding_name = "",
                    .line = line_num,
                });
            }
        }
    }
}

fn analyzeTest(allocator: std.mem.Allocator, line: []const u8, line_num: u32, report: *models.FileReport) !void {
    // Extract test name from describe('name' / it('name' / test('name'
    var rest = line;
    if (std.mem.startsWith(u8, rest, "describe(") or std.mem.startsWith(u8, rest, "describe.")) {
        rest = rest[9..];
    } else if (std.mem.startsWith(u8, rest, "it(") or std.mem.startsWith(u8, rest, "it.")) {
        rest = rest[3..];
    } else if (std.mem.startsWith(u8, rest, "test(") or std.mem.startsWith(u8, rest, "test.")) {
        rest = rest[5..];
    } else return;

    const name = extractStringLiteral(rest);
    try report.tests.append(allocator, .{
        .name = try allocator.dupe(u8, if (name.len > 0) name else "anonymous"),
        .line = line_num,
    });
}

fn detectUnsafePatterns(allocator: std.mem.Allocator, line: []const u8, line_num: u32, report: *models.FileReport) !void {
    const patterns = [_]struct { needle: []const u8, op: []const u8, risk: models.RiskLevel }{
        .{ .needle = "eval(", .op = "eval", .risk = .critical },
        .{ .needle = "new Function(", .op = "new Function", .risk = .critical },
        .{ .needle = "innerHTML", .op = "innerHTML", .risk = .high },
        .{ .needle = "outerHTML", .op = "outerHTML", .risk = .high },
        .{ .needle = "dangerouslySetInnerHTML", .op = "dangerouslySetInnerHTML", .risk = .high },
        .{ .needle = "document.write(", .op = "document.write", .risk = .high },
        .{ .needle = ".exec(", .op = "RegExp.exec", .risk = .low },
    };

    for (&patterns) |p| {
        if (std.mem.indexOf(u8, line, p.needle) != null) {
            // Skip .exec() for regex — only flag eval()
            if (std.mem.eql(u8, p.op, "RegExp.exec")) continue;
            try report.unsafe_ops.append(allocator, .{
                .line = line_num,
                .operation = p.op,
                .context_fn = "",
                .risk_level = p.risk,
            });
        }
    }
}

// === Detection helpers ===

fn isFunctionDecl(line: []const u8) bool {
    var rest = line;
    if (std.mem.startsWith(u8, rest, "export ")) rest = rest[7..];
    if (std.mem.startsWith(u8, rest, "default ")) rest = rest[8..];
    if (std.mem.startsWith(u8, rest, "async ")) rest = rest[6..];
    if (std.mem.startsWith(u8, rest, "function")) {
        if (rest.len > 8 and (rest[8] == ' ' or rest[8] == '*' or rest[8] == '(')) return true;
    }
    return false;
}

fn isArrowFnDecl(line: []const u8) bool {
    var rest = line;
    if (std.mem.startsWith(u8, rest, "export ")) rest = rest[7..];
    if (std.mem.startsWith(u8, rest, "default ")) rest = rest[8..];
    if (!std.mem.startsWith(u8, rest, "const ") and !std.mem.startsWith(u8, rest, "let ")) return false;
    // Must contain => somewhere
    return std.mem.indexOf(u8, rest, "=>") != null;
}

fn isClassDecl(line: []const u8) bool {
    var rest = line;
    if (std.mem.startsWith(u8, rest, "export ")) rest = rest[7..];
    if (std.mem.startsWith(u8, rest, "default ")) rest = rest[8..];
    if (std.mem.startsWith(u8, rest, "abstract ")) rest = rest[9..];
    return std.mem.startsWith(u8, rest, "class ");
}

fn isInterfaceDecl(line: []const u8) bool {
    var rest = line;
    if (std.mem.startsWith(u8, rest, "export ")) rest = rest[7..];
    return std.mem.startsWith(u8, rest, "interface ");
}

fn isTypeAliasDecl(line: []const u8) bool {
    var rest = line;
    if (std.mem.startsWith(u8, rest, "export ")) rest = rest[7..];
    if (!std.mem.startsWith(u8, rest, "type ")) return false;
    // Must have = (not "type guard" like "type is Foo")
    return std.mem.indexOfScalar(u8, rest, '=') != null;
}

fn isEnumDecl(line: []const u8) bool {
    var rest = line;
    if (std.mem.startsWith(u8, rest, "export ")) rest = rest[7..];
    if (std.mem.startsWith(u8, rest, "const ")) rest = rest[6..];
    return std.mem.startsWith(u8, rest, "enum ");
}

fn isImportDecl(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "import ");
}

fn isRequireDecl(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "require(") != null and
        (std.mem.startsWith(u8, line, "const ") or std.mem.startsWith(u8, line, "let ") or std.mem.startsWith(u8, line, "var "));
}

fn isTestCall(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "describe(") or
        std.mem.startsWith(u8, line, "describe.") or
        std.mem.startsWith(u8, line, "it(") or
        std.mem.startsWith(u8, line, "it.") or
        std.mem.startsWith(u8, line, "test(") or
        std.mem.startsWith(u8, line, "test.");
}

fn isMethodDecl(line: []const u8) bool {
    // Class method patterns:
    // methodName(...) {
    // async methodName(...) {
    // get/set name(...) {
    // static name(...) {
    // private/public/protected name
    var rest = line;
    if (std.mem.startsWith(u8, rest, "async ")) rest = rest[6..];
    if (std.mem.startsWith(u8, rest, "static ")) rest = rest[7..];
    if (std.mem.startsWith(u8, rest, "private ")) rest = rest[8..];
    if (std.mem.startsWith(u8, rest, "public ")) rest = rest[7..];
    if (std.mem.startsWith(u8, rest, "protected ")) rest = rest[10..];
    if (std.mem.startsWith(u8, rest, "get ")) rest = rest[4..];
    if (std.mem.startsWith(u8, rest, "set ")) rest = rest[4..];
    if (std.mem.startsWith(u8, rest, "readonly ")) rest = rest[9..];

    // Must start with identifier then (
    const ident = extractIdent(rest);
    if (ident.len == 0) return false;
    const after = std.mem.trim(u8, rest[ident.len..], " \t");
    return after.len > 0 and (after[0] == '(' or after[0] == '<');
}

fn isFieldDecl(line: []const u8) bool {
    // name: Type; or name = value; or private name: ...
    var rest = line;
    if (std.mem.startsWith(u8, rest, "private ")) rest = rest[8..];
    if (std.mem.startsWith(u8, rest, "public ")) rest = rest[7..];
    if (std.mem.startsWith(u8, rest, "protected ")) rest = rest[10..];
    if (std.mem.startsWith(u8, rest, "readonly ")) rest = rest[9..];
    if (std.mem.startsWith(u8, rest, "static ")) rest = rest[7..];

    const ident = extractIdent(rest);
    if (ident.len == 0) return false;
    const after = std.mem.trim(u8, rest[ident.len..], " \t");
    if (after.len == 0) return false;
    // Field if followed by : or = or ? or !
    return after[0] == ':' or after[0] == '=' or after[0] == '?' or after[0] == '!';
}

// === Utility functions ===

fn extractIdent(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t");
    var end: usize = 0;
    for (trimmed) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$') {
            end += 1;
        } else break;
    }
    return trimmed[0..end];
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len < 2) return s;
    if ((s[0] == '\'' or s[0] == '"' or s[0] == '`') and s[s.len - 1] == s[0]) {
        return s[1 .. s.len - 1];
    }
    return s;
}

fn extractStringLiteral(s: []const u8) []const u8 {
    // Find first quote, extract content until matching close
    for (s, 0..) |ch, i| {
        if (ch == '\'' or ch == '"' or ch == '`') {
            if (std.mem.indexOfScalar(u8, s[i + 1 ..], ch)) |close| {
                return s[i + 1 .. i + 1 + close];
            }
        }
    }
    return "";
}

fn classifyJsImport(path: []const u8) models.ImportKind {
    if (path.len == 0) return .package;
    // Relative paths
    if (path[0] == '.' or path[0] == '/') return .local;
    // SvelteKit $ aliases
    if (path[0] == '$') return .local;
    // @ aliases (like @/config, @sveltejs)
    if (path[0] == '@') return .package;
    // Node built-ins
    if (std.mem.startsWith(u8, path, "node:")) return .std_lib;
    const builtins = [_][]const u8{
        "fs", "path", "os", "http", "https", "url", "util", "events",
        "stream", "crypto", "buffer", "child_process", "cluster",
        "net", "dns", "tls", "readline", "zlib", "assert", "querystring",
    };
    for (&builtins) |b| {
        if (std.mem.eql(u8, path, b)) return .std_lib;
        if (path.len > b.len and std.mem.startsWith(u8, path, b) and path[b.len] == '/') return .std_lib;
    }
    return .package;
}

fn countBraceBody(all_lines: []const []const u8, start_line_idx: usize) u32 {
    var depth: i32 = 0;
    var started = false;
    var count: u32 = 0;

    for (all_lines[start_line_idx..]) |line| {
        count += 1;
        for (line) |ch| {
            if (ch == '{') { depth += 1; started = true; }
            if (ch == '}') depth -= 1;
        }
        if (started and depth <= 0) return count;
    }
    return count;
}

fn findMatchingParen(s: []const u8, open_pos: usize) ?usize {
    var depth: i32 = 0;
    for (s[open_pos..], open_pos..) |ch, i| {
        if (ch == '(') depth += 1;
        if (ch == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
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

fn cleanJsdocLine(s: []const u8) []const u8 {
    const text = std.mem.trim(u8, s, " \t*");
    // Skip @param, @returns etc — use description lines
    if (text.len > 0 and text[0] == '@') return "";
    return text;
}

fn extractInlineJsdoc(s: []const u8) []const u8 {
    // /** text */
    if (s.len < 7) return "";
    var text = s[3..]; // skip /**
    if (std.mem.indexOf(u8, text, "*/")) |end| {
        text = text[0..end];
    }
    return std.mem.trim(u8, text, " \t*");
}
