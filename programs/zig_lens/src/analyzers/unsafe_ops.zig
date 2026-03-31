const std = @import("std");
const Ast = std.zig.Ast;
const models = @import("../models.zig");
const parser = @import("../parser.zig");

const UnsafeBuiltin = struct {
    name: []const u8,
    risk: models.RiskLevel,
};

const unsafe_builtins = [_]UnsafeBuiltin{
    .{ .name = "@ptrCast", .risk = .high },
    .{ .name = "@intFromPtr", .risk = .high },
    .{ .name = "@ptrFromInt", .risk = .high },
    .{ .name = "@alignCast", .risk = .medium },
    .{ .name = "@bitCast", .risk = .medium },
    .{ .name = "@intCast", .risk = .medium },
    .{ .name = "@truncate", .risk = .medium },
    .{ .name = "@setRuntimeSafety", .risk = .critical },
    .{ .name = "@cImport", .risk = .low },
    .{ .name = "@cInclude", .risk = .low },
};

pub fn analyze(allocator: std.mem.Allocator, ast: *const Ast, report: *models.FileReport) !void {
    // Walk all nodes looking for builtin calls and asm expressions
    const tags = ast.nodes.items(.tag);
    const main_tokens = ast.nodes.items(.main_token);

    for (0..tags.len) |i| {
        const tag = tags[i];

        switch (tag) {
            .builtin_call_two,
            .builtin_call_two_comma,
            .builtin_call,
            .builtin_call_comma,
            => {
                const main_token = main_tokens[i];
                const builtin_name = ast.tokenSlice(main_token);

                for (&unsafe_builtins) |ub| {
                    if (std.mem.eql(u8, builtin_name, ub.name)) {
                        const line = parser.tokenLine(ast, main_token);
                        try report.unsafe_ops.append(allocator, .{
                            .line = line,
                            .operation = ub.name,
                            .context_fn = findEnclosingFn(ast, @intCast(i)),
                            .risk_level = ub.risk,
                        });
                        break;
                    }
                }
            },
            .asm_simple, .@"asm" => {
                const main_token = main_tokens[i];
                const line = parser.tokenLine(ast, main_token);
                try report.unsafe_ops.append(allocator, .{
                    .line = line,
                    .operation = "asm",
                    .context_fn = findEnclosingFn(ast, @intCast(i)),
                    .risk_level = .critical,
                });
            },
            else => {},
        }
    }
}

fn findEnclosingFn(ast: *const Ast, _: u32) []const u8 {
    // Simple heuristic: we don't walk parent nodes here (AST is flat, no parent pointers)
    // Instead, we could scan root decls to find enclosing fn by line range
    // For now, return empty — the file context is sufficient
    _ = ast;
    return "";
}

// ============================================================================
// Unit Tests
// ============================================================================

test "unsafe builtins list has expected entries" {
    // Verify that @ptrCast is in the unsafe list
    var found_ptr_cast = false;
    var found_int_to_ptr = false;
    for (&unsafe_builtins) |ub| {
        if (std.mem.eql(u8, ub.name, "@ptrCast")) {
            found_ptr_cast = true;
            try std.testing.expectEqual(ub.risk, models.RiskLevel.high);
        }
        if (std.mem.eql(u8, ub.name, "@ptrFromInt")) {
            found_int_to_ptr = true;
        }
    }
    try std.testing.expect(found_ptr_cast);
    try std.testing.expect(found_int_to_ptr);
}

test "unsafe builtins has correct risk levels" {
    // Verify that @setRuntimeSafety is critical
    var found_critical = false;
    for (&unsafe_builtins) |ub| {
        if (std.mem.eql(u8, ub.name, "@setRuntimeSafety")) {
            found_critical = true;
            try std.testing.expectEqual(ub.risk, models.RiskLevel.critical);
        }
    }
    try std.testing.expect(found_critical);
}
