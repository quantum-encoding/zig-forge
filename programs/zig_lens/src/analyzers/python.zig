const std = @import("std");
const models = @import("../models.zig");

/// Analyze Python source code using line-based scanning.
/// Extracts functions, classes, imports, decorators, docstrings,
/// test functions, constants, and unsafe patterns.
/// Python uses indentation for scope — body counting tracks indent level.
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

        // Track triple-quote docstrings
        if (state.in_docstring) {
            if (containsTripleQuote(trimmed, state.docstring_char)) {
                state.in_docstring = false;
            }
            continue;
        }

        // Detect opening triple-quote docstrings (standalone)
        if (isTripleQuoteStart(trimmed)) |quote_char| {
            // Check if it closes on the same line
            if (closesOnSameLine(trimmed, quote_char)) {
                // Single-line docstring — extract content
                const doc = extractSingleLineDocstring(trimmed);
                if (doc.len > 0 and state.doc_comment.len == 0) {
                    state.doc_comment = doc;
                }
            } else {
                state.in_docstring = true;
                state.docstring_char = quote_char;
                // Extract first line of multi-line docstring
                const after = afterTripleQuote(trimmed, quote_char);
                if (after.len > 0 and state.doc_comment.len == 0) {
                    state.doc_comment = after;
                }
            }
            continue;
        }

        // Regular comments
        if (std.mem.startsWith(u8, trimmed, "#")) {
            const comment_text = std.mem.trim(u8, trimmed[1..], " \t");
            if (comment_text.len > 0 and state.doc_comment.len == 0) {
                state.doc_comment = comment_text;
            }
            continue;
        }

        // Empty lines clear doc state
        if (trimmed.len == 0) {
            state.clearDoc();
            continue;
        }

        // Decorators
        if (trimmed[0] == '@') {
            state.has_decorator = true;
            if (std.mem.startsWith(u8, trimmed, "@property")) {
                state.is_property = true;
            } else if (std.mem.startsWith(u8, trimmed, "@staticmethod")) {
                state.is_static = true;
            } else if (std.mem.startsWith(u8, trimmed, "@classmethod")) {
                state.is_classmethod = true;
            }
            continue;
        }

        // === Declaration detection ===
        const indent = getIndent(line);

        // Function/method: def name(...): or async def name(...):
        if (isDefDecl(trimmed) or isAsyncDefDecl(trimmed)) {
            const body_lines = countIndentBody(lines.items, line_num - 1, indent);
            try analyzeDef(allocator, trimmed, line_num, body_lines, indent, &state, report);
            state.clearAll();
            continue;
        }

        // Class: class Name: or class Name(Base):
        if (isClassDecl(trimmed)) {
            try analyzeClass(allocator, trimmed, line_num, lines.items, indent, &state, report);
            state.clearAll();
            // Don't skip body — we want to analyze methods inside
            continue;
        }

        // Imports
        if (std.mem.startsWith(u8, trimmed, "import ") or std.mem.startsWith(u8, trimmed, "from ")) {
            try analyzeImport(allocator, trimmed, line_num, report);
            state.clearDoc();
            continue;
        }

        // Module-level constants: ALL_CAPS = value (at indent 0)
        if (indent == 0 and isConstantAssignment(trimmed)) {
            try analyzeConstant(allocator, trimmed, line_num, &state, report);
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
    in_docstring: bool = false,
    docstring_char: u8 = '"',
    has_decorator: bool = false,
    is_property: bool = false,
    is_static: bool = false,
    is_classmethod: bool = false,

    fn clearDoc(self: *AnalyzerState) void {
        self.doc_comment = "";
    }

    fn clearAll(self: *AnalyzerState) void {
        self.doc_comment = "";
        self.has_decorator = false;
        self.is_property = false;
        self.is_static = false;
        self.is_classmethod = false;
    }
};

fn analyzeDef(allocator: std.mem.Allocator, line: []const u8, line_num: u32, body_lines: u32, indent: u32, state: *AnalyzerState, report: *models.FileReport) !void {
    var rest = line;
    const is_async = std.mem.startsWith(u8, rest, "async ");
    if (is_async) rest = rest[6..];

    if (!std.mem.startsWith(u8, rest, "def ")) return;
    rest = rest[4..];

    const name = extractIdent(rest);
    if (name.len == 0) return;

    // Extract params
    var params: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '(')) |paren_start| {
        if (findMatchingParen(rest, paren_start)) |paren_end| {
            params = rest[paren_start + 1 .. paren_end];
        }
    }

    // Extract return type annotation (-> Type:)
    var ret_type: []const u8 = "";
    if (std.mem.indexOf(u8, rest, "->")) |arrow| {
        const after_arrow = std.mem.trim(u8, rest[arrow + 2 ..], " \t");
        // Ends at ':'
        if (std.mem.indexOfScalar(u8, after_arrow, ':')) |colon| {
            ret_type = std.mem.trim(u8, after_arrow[0..colon], " \t");
        }
    }

    // Is it a test?
    const is_test = std.mem.startsWith(u8, name, "test_") or std.mem.startsWith(u8, name, "test ");
    if (is_test) {
        try report.tests.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .line = line_num,
        });
    }

    // pub = not underscore-prefixed, not nested (indent 0 or 4 for methods)
    const is_pub = name[0] != '_';

    try report.functions.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .end_line = line_num + body_lines,
        .body_lines = body_lines,
        .params = try allocator.dupe(u8, params),
        .return_type = try allocator.dupe(u8, ret_type),
        .is_pub = is_pub,
        .is_extern = false,
        .is_export = false,
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });
    _ = indent;
}

fn analyzeClass(allocator: std.mem.Allocator, line: []const u8, line_num: u32, all_lines: []const []const u8, indent: u32, state: *AnalyzerState, report: *models.FileReport) !void {
    var rest = line;
    if (!std.mem.startsWith(u8, rest, "class ")) return;
    rest = rest[6..];

    const name = extractIdent(rest);
    if (name.len == 0) return;

    // Count methods and fields inside the class body
    var methods: u32 = 0;
    var fields: u32 = 0;
    const start_idx = line_num; // 0-based index of next line
    const class_indent = indent;

    if (start_idx < all_lines.len) {
        for (all_lines[start_idx..]) |bline| {
            const btrimmed = std.mem.trim(u8, bline, " \t\r");
            if (btrimmed.len == 0) continue;

            const bind = getIndent(bline);
            // If we're back to same or lower indent, class body ended
            if (bind <= class_indent and btrimmed.len > 0 and btrimmed[0] != '#') break;

            if (isDefDecl(btrimmed) or isAsyncDefDecl(btrimmed)) {
                methods += 1;
            }
            // self.field = ... pattern in __init__
            if (std.mem.startsWith(u8, btrimmed, "self.") and std.mem.indexOfScalar(u8, btrimmed, '=') != null) {
                fields += 1;
            }
        }
    }

    const is_pub = name[0] != '_';

    // Check for Test class pattern
    if (std.mem.startsWith(u8, name, "Test")) {
        try report.tests.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .line = line_num,
        });
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

fn analyzeImport(allocator: std.mem.Allocator, line: []const u8, line_num: u32, report: *models.FileReport) !void {
    if (std.mem.startsWith(u8, line, "from ")) {
        // from package import name
        const rest = line[5..];
        // Module path ends at " import"
        const import_idx = std.mem.indexOf(u8, rest, " import ") orelse {
            // "from X import" with no space after — just take X
            const module = extractDottedPath(rest);
            if (module.len > 0) {
                try report.imports.append(allocator, .{
                    .path = try allocator.dupe(u8, module),
                    .kind = classifyPythonImport(module),
                    .binding_name = "",
                    .line = line_num,
                });
            }
            return;
        };
        const module = std.mem.trim(u8, rest[0..import_idx], " \t");
        if (module.len > 0) {
            try report.imports.append(allocator, .{
                .path = try allocator.dupe(u8, module),
                .kind = classifyPythonImport(module),
                .binding_name = try allocator.dupe(u8, std.mem.trim(u8, rest[import_idx + 8 ..], " \t")),
                .line = line_num,
            });
        }
    } else if (std.mem.startsWith(u8, line, "import ")) {
        // import package or import package as alias
        const rest = line[7..];
        const module = extractDottedPath(rest);
        if (module.len > 0) {
            try report.imports.append(allocator, .{
                .path = try allocator.dupe(u8, module),
                .kind = classifyPythonImport(module),
                .binding_name = "",
                .line = line_num,
            });
        }
    }
}

fn analyzeConstant(allocator: std.mem.Allocator, line: []const u8, line_num: u32, state: *AnalyzerState, report: *models.FileReport) !void {
    const name = extractIdent(line);
    if (name.len == 0) return;

    // Extract type hint if present: NAME: Type = value
    var type_name: []const u8 = "";
    const after_name = line[name.len..];
    const trimmed_after = std.mem.trim(u8, after_name, " \t");
    if (trimmed_after.len > 0 and trimmed_after[0] == ':') {
        const type_rest = std.mem.trim(u8, trimmed_after[1..], " \t");
        if (std.mem.indexOfScalar(u8, type_rest, '=')) |eq| {
            type_name = std.mem.trim(u8, type_rest[0..eq], " \t");
        }
    }

    try report.constants.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line_num,
        .is_pub = name[0] != '_',
        .type_name = try allocator.dupe(u8, type_name),
        .doc_comment = try allocator.dupe(u8, state.doc_comment),
    });
}

fn detectUnsafePatterns(allocator: std.mem.Allocator, line: []const u8, line_num: u32, report: *models.FileReport) !void {
    const patterns = [_]struct { needle: []const u8, op: []const u8, risk: models.RiskLevel }{
        .{ .needle = "eval(", .op = "eval", .risk = .critical },
        .{ .needle = "exec(", .op = "exec", .risk = .critical },
        .{ .needle = "os.system(", .op = "os.system", .risk = .high },
        .{ .needle = "os.popen(", .op = "os.popen", .risk = .high },
        .{ .needle = "subprocess.call(", .op = "subprocess.call", .risk = .high },
        .{ .needle = "subprocess.Popen(", .op = "subprocess.Popen", .risk = .medium },
        .{ .needle = "pickle.load(", .op = "pickle.load", .risk = .high },
        .{ .needle = "pickle.loads(", .op = "pickle.loads", .risk = .high },
        .{ .needle = "__import__(", .op = "__import__", .risk = .medium },
        .{ .needle = "shell=True", .op = "shell=True", .risk = .high },
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
}

// === Detection helpers ===

fn isDefDecl(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "def ");
}

fn isAsyncDefDecl(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "async def ");
}

fn isClassDecl(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "class ");
}

fn isConstantAssignment(line: []const u8) bool {
    // ALL_CAPS_NAME = value or ALL_CAPS_NAME: Type = value
    const name = extractIdent(line);
    if (name.len == 0) return false;

    // Check it's ALL_CAPS (with underscores)
    var has_letter = false;
    for (name) |ch| {
        if (std.ascii.isLower(ch)) return false;
        if (std.ascii.isUpper(ch)) has_letter = true;
    }
    if (!has_letter) return false;

    // Must be followed by = or :
    const after = std.mem.trim(u8, line[name.len..], " \t");
    return after.len > 0 and (after[0] == '=' or after[0] == ':');
}

fn classifyPythonImport(module: []const u8) models.ImportKind {
    // Relative imports start with .
    if (module.len > 0 and module[0] == '.') return .local;

    // Standard library modules (common ones)
    const stdlib = [_][]const u8{
        "os",      "sys",       "re",        "io",      "abc",
        "ast",     "json",      "csv",       "math",    "time",
        "typing",  "pathlib",   "datetime",  "logging", "functools",
        "itertools", "collections", "copy",  "enum",    "dataclasses",
        "unittest", "argparse", "subprocess", "threading", "multiprocessing",
        "socket",  "http",      "urllib",    "hashlib", "hmac",
        "struct",  "ctypes",    "warnings",  "traceback", "inspect",
        "textwrap", "string",   "shutil",    "glob",    "fnmatch",
        "tempfile", "pickle",   "shelve",    "sqlite3", "configparser",
        "contextlib", "signal", "pprint",    "decimal", "fractions",
        "random",  "statistics", "secrets",  "base64",  "binascii",
        "codecs",  "locale",    "gettext",   "platform", "importlib",
    };
    for (&stdlib) |s| {
        if (std.mem.eql(u8, module, s)) return .std_lib;
        // Check prefix: "os.path", "typing.Dict" etc.
        if (module.len > s.len and std.mem.startsWith(u8, module, s) and module[s.len] == '.') return .std_lib;
    }

    return .package;
}

// === Utility functions ===

fn extractIdent(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t");
    var end: usize = 0;
    for (trimmed) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_') {
            end += 1;
        } else break;
    }
    return trimmed[0..end];
}

fn extractDottedPath(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t");
    var end: usize = 0;
    for (trimmed) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.') {
            end += 1;
        } else break;
    }
    return trimmed[0..end];
}

fn getIndent(line: []const u8) u32 {
    var count: u32 = 0;
    for (line) |ch| {
        if (ch == ' ') {
            count += 1;
        } else if (ch == '\t') {
            count += 4;
        } else break;
    }
    return count;
}

fn countIndentBody(all_lines: []const []const u8, start_line_idx: usize, decl_indent: u32) u32 {
    // Python body = all following lines with indent > decl_indent
    var count: u32 = 0;
    const start = start_line_idx + 1;
    if (start >= all_lines.len) return 0;

    for (all_lines[start..]) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) {
            count += 1; // blank lines inside body
            continue;
        }
        const ind = getIndent(line);
        if (ind <= decl_indent) break;
        count += 1;
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

fn isTripleQuoteStart(line: []const u8) ?u8 {
    if (line.len >= 3) {
        if (line[0] == '"' and line[1] == '"' and line[2] == '"') return '"';
        if (line[0] == '\'' and line[1] == '\'' and line[2] == '\'') return '\'';
    }
    // Also match r""", f""", b""" prefixes
    if (line.len >= 4) {
        if ((line[0] == 'r' or line[0] == 'f' or line[0] == 'b') and
            line[1] == '"' and line[2] == '"' and line[3] == '"') return '"';
        if ((line[0] == 'r' or line[0] == 'f' or line[0] == 'b') and
            line[1] == '\'' and line[2] == '\'' and line[3] == '\'') return '\'';
    }
    return null;
}

fn containsTripleQuote(line: []const u8, quote_char: u8) bool {
    if (line.len < 3) return false;
    var i: usize = 0;
    while (i + 2 < line.len) : (i += 1) {
        if (line[i] == quote_char and line[i + 1] == quote_char and line[i + 2] == quote_char) {
            return true;
        }
    }
    return false;
}

fn closesOnSameLine(line: []const u8, quote_char: u8) bool {
    // Find opening triple quote, then look for closing
    var i: usize = 0;
    // Skip prefix (r, f, b)
    if (i < line.len and (line[i] == 'r' or line[i] == 'f' or line[i] == 'b')) i += 1;
    if (i + 2 >= line.len) return false;
    if (line[i] != quote_char) return false;
    i += 3; // skip opening """
    // Search for closing """
    while (i + 2 < line.len) : (i += 1) {
        if (line[i] == quote_char and line[i + 1] == quote_char and line[i + 2] == quote_char) {
            return true;
        }
    }
    return false;
}

fn extractSingleLineDocstring(line: []const u8) []const u8 {
    var start: usize = 0;
    // Skip prefix
    if (start < line.len and (line[start] == 'r' or line[start] == 'f' or line[start] == 'b')) start += 1;
    start += 3; // skip opening """

    // Find closing """
    var end = start;
    while (end + 2 < line.len) : (end += 1) {
        if (line[end] == '"' and line[end + 1] == '"' and line[end + 2] == '"') break;
        if (line[end] == '\'' and line[end + 1] == '\'' and line[end + 2] == '\'') break;
    }
    return std.mem.trim(u8, line[start..end], " \t");
}

fn afterTripleQuote(line: []const u8, quote_char: u8) []const u8 {
    var i: usize = 0;
    if (i < line.len and (line[i] == 'r' or line[i] == 'f' or line[i] == 'b')) i += 1;
    if (i + 2 >= line.len) return "";
    if (line[i] != quote_char) return "";
    return std.mem.trim(u8, line[i + 3 ..], " \t");
}
