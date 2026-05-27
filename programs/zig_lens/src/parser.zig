const std = @import("std");
const Ast = std.zig.Ast;

/// Maximum AST traversal depth honored by the structural analyzers.
///
/// `std.zig.Ast.parse` is iterative-with-bounds for its own work, so a
/// pathological source can produce a tree that parses successfully but
/// nests arbitrarily deep — `const a = struct { const b = struct { ... } }`
/// or `((((((((...))))))))` deep expressions. Our analyzers (structure,
/// complexity, …) are recursive over those trees: without a guard they
/// blow the worker thread's stack when handed a hostile file. Real Zig
/// code rarely exceeds depth 30; 256 is comfortably above legitimate use
/// while staying well clear of the thread's stack budget.
///
/// Analyzers that respect this cap return early once depth is reached
/// instead of recursing further. The remaining subtree is silently
/// truncated — that is the safe default for a static-analysis tool:
/// better to under-report on a pathological input than to crash.
pub const max_ast_depth: u16 = 256;

/// Maximum bracket-nesting depth a source file may exhibit before
/// `parseFile` refuses to invoke `std.zig.Ast.parse` on it.
///
/// `std.zig.Ast.parse` is itself recursive (each `parseContainerMembers
/// → parseContainerDeclAuto → parseContainerMembers` adds a stack
/// frame, and similarly for expression parens). On adversarial input
/// like 5000 nested `const a = struct { … }` or 5000 unmatched `(`
/// the parser walks off the bottom of the worker thread's stack
/// before our analyzers ever run. The lexical pre-check below counts
/// the maximum `{` / `(` / `[` nesting depth outside of strings and
/// line comments and rejects the file when it exceeds this bound,
/// matching the same `max_ast_depth` our analyzers honour.
pub const max_nesting_depth: u16 = max_ast_depth;

pub const ParseFileError = error{
    FileReadFailed,
    ParseFailed,
    /// Lexical pre-check found bracket nesting beyond
    /// `max_nesting_depth`. The file is refused before the compiler
    /// parser is invoked, so a hostile input cannot exhaust the
    /// worker thread's stack inside `std.zig.Ast.parse`.
    NestingTooDeep,
};

/// Parse a Zig source file. Returns an error on read failure, parse
/// failure, or pathological nesting depth.
pub fn parseFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
) ParseFileError!struct { ast: Ast, source: [:0]const u8 } {
    const source = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        file_path,
        allocator,
        .limited(10 * 1024 * 1024),
        .of(u8),
        0,
    ) catch {
        return error.FileReadFailed;
    };

    // Depth-bomb guard. See `max_nesting_depth` doc.
    if (maxBracketDepth(source) > max_nesting_depth) {
        allocator.free(source);
        return error.NestingTooDeep;
    }

    var ast = Ast.parse(allocator, source, .zig) catch {
        allocator.free(source);
        return error.ParseFailed;
    };
    _ = &ast;

    return .{ .ast = ast, .source = source };
}

/// Scan `source` and return the maximum bracket nesting depth across
/// `{}`, `()`, `[]`. Brackets inside double-quoted string literals
/// (with `\"` escape handling) and `//` line comments are ignored.
/// Multi-line string lines (`\\`) are also skipped wholesale.
///
/// This is a lexical approximation — not a full tokenizer — because
/// we run it *before* `std.zig.Ast.parse` to decide whether the
/// parser is safe to call. Edge cases on `@"..."` identifiers and
/// `'"'` character literals can mis-attribute a bracket as inside
/// versus outside a string, but the bound we compare against
/// (`max_nesting_depth = 256`) is comfortably above legitimate use,
/// so the worst the approximation does is false-positive on an
/// extreme-but-real source — which still parses fine if we let it
/// through; we are protecting against orders-of-magnitude overshoot.
pub fn maxBracketDepth(source: []const u8) u32 {
    var depth: u32 = 0;
    var max_depth: u32 = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        const c = source[i];

        // Line comment: skip to next newline.
        if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            continue;
        }
        // Multi-line string literal line: skip to next newline.
        if (c == '\\' and i + 1 < source.len and source[i + 1] == '\\') {
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            continue;
        }
        // Character literal: skip the contents until the closing '.
        if (c == '\'') {
            i += 1;
            while (i < source.len and source[i] != '\'') : (i += 1) {
                if (source[i] == '\\' and i + 1 < source.len) i += 1; // skip escaped char
            }
            continue;
        }
        // String literal: skip contents until matching unescaped ".
        if (c == '"') {
            i += 1;
            while (i < source.len and source[i] != '"') : (i += 1) {
                if (source[i] == '\\' and i + 1 < source.len) i += 1; // skip escaped char
            }
            continue;
        }

        switch (c) {
            '{', '(', '[' => {
                depth += 1;
                if (depth > max_depth) max_depth = depth;
            },
            '}', ')', ']' => {
                if (depth > 0) depth -= 1;
            },
            else => {},
        }
    }
    return max_depth;
}

/// Check if a declaration node has the `pub` keyword before it.
pub fn isPublic(ast: *const Ast, node_idx: Ast.Node.Index) bool {
    const idx = @intFromEnum(node_idx);
    const main_token = ast.nodes.items(.main_token)[idx];
    if (main_token == 0) return false;
    const token_tags = ast.tokens.items(.tag);
    return token_tags[main_token - 1] == .keyword_pub;
}

/// Get the name of a declaration (function name, var/const name).
pub fn getDeclName(ast: *const Ast, node_idx: Ast.Node.Index) ?[]const u8 {
    const idx = @intFromEnum(node_idx);
    const tags = ast.nodes.items(.tag);
    const tag = tags[idx];
    const main_token = ast.nodes.items(.main_token)[idx];
    const token_tags = ast.tokens.items(.tag);

    switch (tag) {
        .fn_decl => {
            // fn_decl: main_token is `fn`, name is next token
            const name_token = main_token + 1;
            if (name_token >= ast.tokens.len) return null;
            if (token_tags[name_token] != .identifier) return null;
            return ast.tokenSlice(name_token);
        },
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto,
        => {
            const name_token = main_token + 1;
            if (name_token >= ast.tokens.len) return null;
            if (token_tags[name_token] != .identifier) return null;
            return ast.tokenSlice(name_token);
        },
        .simple_var_decl => {
            // simple_var_decl: main_token is `const`/`var`, name is next
            const name_token = main_token + 1;
            if (name_token >= ast.tokens.len) return null;
            if (token_tags[name_token] != .identifier) return null;
            return ast.tokenSlice(name_token);
        },
        else => return null,
    }
}

/// Extract doc comment lines (///) before a declaration.
pub fn extractDocComment(ast: *const Ast, node_idx: Ast.Node.Index) []const u8 {
    const idx = @intFromEnum(node_idx);
    var first_token = ast.nodes.items(.main_token)[idx];

    // Check for pub keyword
    if (first_token > 0 and ast.tokens.items(.tag)[first_token - 1] == .keyword_pub) {
        first_token = first_token - 1;
    }

    // Walk backwards from first_token to find doc_comment tokens
    const token_tags = ast.tokens.items(.tag);
    if (first_token == 0) return "";

    var tok = first_token - 1;
    while (tok > 0 and token_tags[tok] == .doc_comment) : (tok -= 1) {}
    if (token_tags[tok] != .doc_comment) tok += 1;

    if (tok >= first_token) return "";

    // Return the text of the first doc comment line (stripped)
    const text = ast.tokenSlice(tok);
    if (text.len > 3) {
        return std.mem.trim(u8, text[3..], " ");
    }
    return "";
}

/// Get source location (line number, 1-based) of a token.
pub fn tokenLine(ast: *const Ast, token_idx: u32) u32 {
    const loc = ast.tokenLocation(0, token_idx);
    return @intCast(loc.line + 1);
}

/// Extract the import path from a builtin_call node that is @import("...").
pub fn extractImportPath(ast: *const Ast, node_idx: Ast.Node.Index) ?[]const u8 {
    const idx = @intFromEnum(node_idx);
    const tags = ast.nodes.items(.tag);
    const tag = tags[idx];

    // @import is a builtin_call or builtin_call_two
    if (tag != .builtin_call_two and
        tag != .builtin_call_two_comma and
        tag != .builtin_call and
        tag != .builtin_call_comma) return null;

    const main_token = ast.nodes.items(.main_token)[idx];
    const builtin_name = ast.tokenSlice(main_token);
    if (!std.mem.eql(u8, builtin_name, "@import")) return null;

    // Use builtinCallParams to safely get arguments
    var buf: [2]Ast.Node.Index = undefined;
    const params = ast.builtinCallParams(&buf, node_idx) orelse return null;
    if (params.len == 0) return null;

    const arg_node = params[0];
    const arg_idx = @intFromEnum(arg_node);
    if (arg_idx == 0) return null;

    const arg_tag = tags[arg_idx];
    if (arg_tag != .string_literal) return null;

    const raw = ast.tokenSlice(ast.nodes.items(.main_token)[arg_idx]);
    if (raw.len < 2) return null;
    // Strip quotes
    return raw[1 .. raw.len - 1];
}

/// Count lines, blank lines, and comment lines in source.
pub fn countLines(source: []const u8) struct { loc: u32, blank: u32, comments: u32 } {
    var loc: u32 = 0;
    var blank: u32 = 0;
    var comments: u32 = 0;
    var start: usize = 0;

    for (source, 0..) |c, i| {
        if (c == '\n') {
            const line = source[start..i];
            const trimmed = std.mem.trim(u8, line, " \t\r");
            loc += 1;
            if (trimmed.len == 0) {
                blank += 1;
            } else if (std.mem.startsWith(u8, trimmed, "//")) {
                comments += 1;
            }
            start = i + 1;
        }
    }
    // Trailing partial line (no terminating newline): count it once.
    // Previously the loop's `or i == source.len - 1` branch counted
    // this line *and* the post-loop block counted it again, so
    // `const x = 5;` reported loc=2.
    if (start < source.len) {
        const line = source[start..source.len];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        loc += 1;
        if (trimmed.len == 0) {
            blank += 1;
        } else if (std.mem.startsWith(u8, trimmed, "//")) {
            comments += 1;
        }
    }

    return .{ .loc = loc, .blank = blank, .comments = comments };
}

// ============================================================================
// Unit Tests
// ============================================================================

test "countLines empty source" {
    const result = countLines("");
    try std.testing.expectEqual(result.loc, 0);
    try std.testing.expectEqual(result.blank, 0);
    try std.testing.expectEqual(result.comments, 0);
}

test "countLines single line no newline" {
    const result = countLines("const x = 5;");
    try std.testing.expectEqual(result.loc, 1);
    try std.testing.expectEqual(result.blank, 0);
    try std.testing.expectEqual(result.comments, 0);
}

test "countLines single line with newline" {
    const result = countLines("const x = 5;\n");
    try std.testing.expectEqual(result.loc, 1);
    try std.testing.expectEqual(result.blank, 0);
    try std.testing.expectEqual(result.comments, 0);
}

test "countLines multiple lines" {
    const source = "fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n";
    const result = countLines(source);
    try std.testing.expectEqual(result.loc, 3);
    try std.testing.expectEqual(result.blank, 0);
    try std.testing.expectEqual(result.comments, 0);
}

test "countLines with blank lines" {
    const source = "fn add(a: i32, b: i32) i32 {\n\n    return a + b;\n}\n";
    const result = countLines(source);
    try std.testing.expectEqual(result.loc, 4);
    try std.testing.expectEqual(result.blank, 1);
    try std.testing.expectEqual(result.comments, 0);
}

test "countLines with single-line comments" {
    const source = "// Comment\nconst x = 5;\n";
    const result = countLines(source);
    try std.testing.expectEqual(result.loc, 2);
    try std.testing.expectEqual(result.blank, 0);
    try std.testing.expectEqual(result.comments, 1);
}

test "countLines with multiple comments" {
    const source = "// Comment 1\n// Comment 2\nconst x = 5;\n";
    const result = countLines(source);
    try std.testing.expectEqual(result.loc, 3);
    try std.testing.expectEqual(result.blank, 0);
    try std.testing.expectEqual(result.comments, 2);
}

test "countLines with inline comments" {
    const source = "const x = 5; // inline comment\n";
    const result = countLines(source);
    try std.testing.expectEqual(result.loc, 1);
    try std.testing.expectEqual(result.blank, 0);
    try std.testing.expectEqual(result.comments, 0); // inline comments don't count as comment lines
}

test "countLines with whitespace-only lines" {
    const source = "const x = 5;\n   \nconst y = 10;\n";
    const result = countLines(source);
    try std.testing.expectEqual(result.loc, 3);
    try std.testing.expectEqual(result.blank, 1);
    try std.testing.expectEqual(result.comments, 0);
}

// ============================================================================
// Recursion-safety tests for the depth-bomb defense
// ============================================================================

test "maxBracketDepth: empty source" {
    try std.testing.expectEqual(@as(u32, 0), maxBracketDepth(""));
}

test "maxBracketDepth: flat source" {
    // `fn x() void {}` — `()` and `{}` open and close back-to-back,
    // so the max depth seen is 1, not 2.
    try std.testing.expectEqual(@as(u32, 1), maxBracketDepth("fn x() void {}"));
}

test "maxBracketDepth: nested calls reach depth 2" {
    // `foo(bar())` — `(` opens to depth 1, `(` opens to depth 2,
    // then both close. Max depth seen is 2.
    try std.testing.expectEqual(@as(u32, 2), maxBracketDepth("foo(bar())"));
}

test "maxBracketDepth: nested structs" {
    // `const a = struct { const b = struct { const c = u8; }; };` → depth 2
    try std.testing.expectEqual(
        @as(u32, 2),
        maxBracketDepth("const a = struct { const b = struct { const c = u8; }; };"),
    );
}

test "maxBracketDepth: ignores brackets inside string literals" {
    // The source-level brackets are zero — the `{` and `}` inside
    // the string literal are content, not structure.
    try std.testing.expectEqual(@as(u32, 0), maxBracketDepth("const s = \"{{{{{{{{{{}}}}}}}}}}\";"));
}

test "maxBracketDepth: ignores brackets inside line comments" {
    try std.testing.expectEqual(@as(u32, 0), maxBracketDepth("// (((((((((((((((\n"));
}

test "maxBracketDepth: ignores brackets in multi-line string lines" {
    // \\ lines are multi-line string content in Zig.
    try std.testing.expectEqual(@as(u32, 0), maxBracketDepth("\\\\(((((((\n"));
}

test "maxBracketDepth: catches depth-bomb input" {
    // 1000 nested `const aN = struct { …` produces depth 1000. The
    // pre-parse guard in `parseFile` compares against
    // max_nesting_depth (256), so this would be refused.
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    var i: usize = 0;
    while (i < 1000) : (i += 1) try buf.appendSlice(allocator, "const a = struct { ");
    try buf.appendSlice(allocator, "const inner: u8 = 0;");
    i = 0;
    while (i < 1000) : (i += 1) try buf.appendSlice(allocator, " };");
    const depth = maxBracketDepth(buf.items);
    try std.testing.expectEqual(@as(u32, 1000), depth);
    try std.testing.expect(depth > max_nesting_depth);
}

test "parseFile: refuses depth-bomb file before std.zig.Ast.parse" {
    const allocator = std.testing.allocator;

    // Build a depth-bomb source in a temp file. Without the pre-parse
    // guard, std.zig.Ast.parse would recurse off the worker thread's
    // stack on this input (verified empirically against the unguarded
    // build at 5000 nests). With the guard, parseFile returns
    // error.NestingTooDeep cleanly.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    var i: usize = 0;
    while (i < 1000) : (i += 1) try buf.appendSlice(allocator, "const a = struct { ");
    try buf.appendSlice(allocator, "const inner: u8 = 0;");
    i = 0;
    while (i < 1000) : (i += 1) try buf.appendSlice(allocator, " };");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bomb.zig", .data = buf.items });

    // Resolve the file's absolute path so parseFile (which uses
    // Dir.cwd()) can find it.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPathFile(std.testing.io, "bomb.zig", &path_buf);
    const abs_path = path_buf[0..path_len];

    const result = parseFile(allocator, std.testing.io, abs_path);
    try std.testing.expectError(error.NestingTooDeep, result);
}
