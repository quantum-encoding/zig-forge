const std = @import("std");
const Ast = std.zig.Ast;

/// Parse a Zig source file. Returns null on read failure.
pub fn parseFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
) !struct { ast: Ast, source: [:0]const u8 } {
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

    var ast = Ast.parse(allocator, source, .zig) catch {
        allocator.free(source);
        return error.ParseFailed;
    };
    _ = &ast;

    return .{ .ast = ast, .source = source };
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
        if (c == '\n' or i == source.len - 1) {
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
    if (source.len > 0 and source[source.len - 1] != '\n') {
        loc += 1; // Account for last line without trailing newline (already counted above)
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
