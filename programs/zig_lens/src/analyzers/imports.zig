const std = @import("std");
const Ast = std.zig.Ast;
const models = @import("../models.zig");
const parser = @import("../parser.zig");

/// Analyze imports in a parsed AST.
pub fn analyze(allocator: std.mem.Allocator, ast: *const Ast, report: *models.FileReport) !void {
    for (ast.rootDecls()) |decl_idx| {
        try analyzeNode(allocator, ast, decl_idx, report);
    }
}

fn analyzeNode(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    node_idx: Ast.Node.Index,
    report: *models.FileReport,
) !void {
    const idx = @intFromEnum(node_idx);
    if (idx == 0) return;

    const tags = ast.nodes.items(.tag);
    const tag = tags[idx];

    switch (tag) {
        .simple_var_decl => {
            // const foo = @import("bar.zig")
            const decl = ast.fullVarDecl(node_idx) orelse return;
            if (decl.ast.init_node == .none) return;
            const init_node = decl.ast.init_node.unwrap() orelse return;

            const import_path = parser.extractImportPath(ast, init_node) orelse return;
            const binding = parser.getDeclName(ast, node_idx) orelse "";
            const main_token = ast.nodes.items(.main_token)[idx];
            const line = parser.tokenLine(ast, main_token);

            try report.imports.append(allocator, .{
                .path = try allocator.dupe(u8, import_path),
                .kind = classifyImport(import_path),
                .binding_name = try allocator.dupe(u8, binding),
                .line = line,
            });
        },
        else => {},
    }
}

fn classifyImport(path: []const u8) models.ImportKind {
    if (std.mem.eql(u8, path, "std") or std.mem.eql(u8, path, "builtin")) {
        return .std_lib;
    }
    if (std.mem.endsWith(u8, path, ".zig") or std.mem.startsWith(u8, path, "./") or std.mem.startsWith(u8, path, "../")) {
        return .local;
    }
    return .package;
}
