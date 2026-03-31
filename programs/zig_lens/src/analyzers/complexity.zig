const std = @import("std");
const Ast = std.zig.Ast;
const models = @import("../models.zig");
const parser = @import("../parser.zig");

pub const ComplexityInfo = struct {
    name: []const u8,
    file: []const u8,
    line: u32,
    cyclomatic: u32,
    body_lines: u32,
    max_nesting: u32,
    param_count: u32,
};

pub fn analyzeFunction(
    ast: *const Ast,
    fn_node: Ast.Node.Index,
    file_path: []const u8,
    fn_info: *const models.FunctionInfo,
) ComplexityInfo {
    // Count branching constructs in the function body
    const data = ast.nodeData(fn_node);
    const body_node = data.node_and_node[1];

    var complexity: u32 = 1; // Base complexity
    countComplexity(ast, body_node, &complexity);

    return .{
        .name = fn_info.name,
        .file = file_path,
        .line = fn_info.line,
        .cyclomatic = complexity,
        .body_lines = fn_info.body_lines,
        .max_nesting = 0, // Would require depth tracking — skip for now
        .param_count = countCommas(fn_info.params) + @as(u32, if (fn_info.params.len > 0) 1 else 0),
    };
}

fn countComplexity(ast: *const Ast, node_idx: Ast.Node.Index, complexity: *u32) void {
    const idx = @intFromEnum(node_idx);
    if (idx == 0) return;

    const tags = ast.nodes.items(.tag);
    const tag = tags[idx];

    // Each branching construct adds 1 to cyclomatic complexity
    switch (tag) {
        .@"if",
        .if_simple,
        => complexity.* += 1,

        .@"switch",
        .switch_comma,
        => {
            // Each switch prong adds a path (minus 1 for the switch itself)
            complexity.* += 1;
        },

        .@"while",
        .while_simple,
        .while_cont,
        => complexity.* += 1,

        .@"for",
        .for_simple,
        .for_range,
        => complexity.* += 1,

        .@"catch" => complexity.* += 1,

        .@"orelse" => complexity.* += 1,

        .@"try" => complexity.* += 1,

        .bool_and => complexity.* += 1,
        .bool_or => complexity.* += 1,

        else => {},
    }

    // Recurse into children
    const data = ast.nodeData(node_idx);
    // nodeData returns a tagged union — try the common patterns
    switch (tag) {
        .block_two,
        .block_two_semicolon,
        => {
            const children = data.opt_node_and_opt_node;
            if (children[0].unwrap()) |c| countComplexity(ast, c, complexity);
            if (children[1].unwrap()) |c| countComplexity(ast, c, complexity);
        },
        .block,
        .block_semicolon,
        => {
            var buf: [2]Ast.Node.Index = undefined;
            if (ast.blockStatements(&buf, node_idx)) |stmts| {
                for (stmts) |stmt| {
                    countComplexity(ast, stmt, complexity);
                }
            }
        },
        .@"if",
        .if_simple,
        => {
            if (ast.fullIf(node_idx)) |full_if| {
                countComplexity(ast, full_if.ast.cond_expr, complexity);
                countComplexity(ast, full_if.ast.then_expr, complexity);
                if (full_if.ast.else_expr.unwrap()) |else_expr| {
                    countComplexity(ast, else_expr, complexity);
                }
            }
        },
        .@"while",
        .while_simple,
        .while_cont,
        => {
            if (ast.fullWhile(node_idx)) |full_while| {
                countComplexity(ast, full_while.ast.cond_expr, complexity);
                countComplexity(ast, full_while.ast.then_expr, complexity);
                if (full_while.ast.else_expr.unwrap()) |else_expr| {
                    countComplexity(ast, else_expr, complexity);
                }
            }
        },
        .@"for",
        .for_simple,
        .for_range,
        => {
            if (ast.fullFor(node_idx)) |full_for| {
                countComplexity(ast, full_for.ast.then_expr, complexity);
                if (full_for.ast.else_expr.unwrap()) |else_expr| {
                    countComplexity(ast, else_expr, complexity);
                }
            }
        },
        else => {
            // Generic: try to recurse into data fields
            const children = data.node_and_node;
            const c0 = @intFromEnum(children[0]);
            const c1 = @intFromEnum(children[1]);
            if (c0 != 0 and c0 < tags.len) countComplexity(ast, children[0], complexity);
            if (c1 != 0 and c1 < tags.len) countComplexity(ast, children[1], complexity);
        },
    }
}

fn countCommas(s: []const u8) u32 {
    var count: u32 = 0;
    for (s) |c| {
        if (c == ',') count += 1;
    }
    return count;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "countCommas empty string" {
    const result = countCommas("");
    try std.testing.expectEqual(result, 0);
}

test "countCommas no commas" {
    const result = countCommas("a b c");
    try std.testing.expectEqual(result, 0);
}

test "countCommas single comma" {
    const result = countCommas("a, b");
    try std.testing.expectEqual(result, 1);
}

test "countCommas multiple commas" {
    const result = countCommas("a, b, c, d");
    try std.testing.expectEqual(result, 3);
}
