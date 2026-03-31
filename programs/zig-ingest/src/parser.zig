//! AST Parsing
//!
//! Parses Zig source files using std.zig.Ast, extracts function declarations
//! and call graphs. Requires std.Io for file reading.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const types = @import("types.zig");
const FunctionInfo = types.FunctionInfo;
const CallEdge = types.CallEdge;

const FunctionList = std.ArrayList(FunctionInfo);
const CallList = std.ArrayList(CallEdge);

/// Read and parse a single Zig source file, extracting functions and calls.
pub fn parseFile(
    allocator: Allocator,
    io: std.Io,
    file_path: []const u8,
    relative_path: []const u8,
    verbose: bool,
) !types.ParseResult {
    // Read file contents using Io API with sentinel for AST parser
    const source = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        file_path,
        allocator,
        .limited(50 * 1024 * 1024),
        .of(u8),
        0,
    ) catch |err| {
        if (verbose) {
            std.debug.print("  Failed to read {s}: {s}\n", .{ file_path, @errorName(err) });
        }
        return error.FileReadFailed;
    };
    defer allocator.free(source);

    // Parse AST
    var ast = Ast.parse(allocator, source, .zig) catch |err| {
        if (verbose) {
            std.debug.print("  Parse error in {s}: {s}\n", .{ file_path, @errorName(err) });
        }
        return error.ParseFailed;
    };
    defer ast.deinit(allocator);

    var functions: FunctionList = .empty;
    var calls: CallList = .empty;

    // Extract functions from root declarations
    for (ast.rootDecls()) |decl_idx| {
        try extractFunctions(allocator, &ast, source, relative_path, decl_idx, &functions, &calls, null);
    }

    return .{ .functions = functions, .calls = calls, .allocator = allocator };
}

pub fn extractFunctions(
    allocator: Allocator,
    ast: *const Ast,
    source: []const u8,
    file_path: []const u8,
    node_idx: Ast.Node.Index,
    functions: *FunctionList,
    calls: *CallList,
    parent_fn: ?[]const u8,
) !void {
    const idx = @intFromEnum(node_idx);
    const tags = ast.nodes.items(.tag);
    const tag = tags[idx];

    switch (tag) {
        .fn_decl => {
            const fn_info = try extractFnDecl(allocator, ast, source, file_path, node_idx);
            if (fn_info) |info| {
                try functions.append(allocator, info);

                // Extract calls from function body
                const data = ast.nodeData(node_idx);
                const body_node = data.node_and_node[1];
                try extractCalls(allocator, ast, info.qualified_id, info.name, body_node, calls);
            }
        },
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        => {
            var buf: [2]Ast.Node.Index = undefined;
            const container = ast.fullContainerDecl(&buf, node_idx) orelse return;
            for (container.ast.members) |member_idx| {
                try extractFunctions(allocator, ast, source, file_path, member_idx, functions, calls, parent_fn);
            }
        },
        else => {},
    }
}

fn extractFnDecl(
    allocator: Allocator,
    ast: *const Ast,
    source: []const u8,
    file_path: []const u8,
    node_idx: Ast.Node.Index,
) !?FunctionInfo {
    const idx = @intFromEnum(node_idx);
    const token_tags = ast.tokens.items(.tag);
    const main_tokens = ast.nodes.items(.main_token);
    const main_token = main_tokens[idx];

    // Get function name
    const name_token = main_token + 1;
    if (name_token >= ast.tokens.len) return null;
    if (token_tags[name_token] != .identifier) return null;

    const name = ast.tokenSlice(name_token);

    // Skip anonymous/generated functions
    if (name.len == 0 or name[0] == '@') return null;

    // Get line numbers
    const start_loc = ast.tokenLocation(0, main_token);
    const line_start = start_loc.line + 1;

    // Get end line from fn_decl body
    const token_starts = ast.tokens.items(.start);
    const data = ast.nodeData(node_idx);
    const body_node = data.node_and_node[1];
    const end_token = ast.lastToken(body_node);
    const end_loc = ast.tokenLocation(0, end_token);
    const line_end = end_loc.line + 1;
    const node_start = token_starts[main_token];
    const node_end = token_starts[end_token];

    // Extract code snippet (first 500 chars)
    const code_start = node_start;
    const code_end = @min(node_end + 100, source.len);
    const code_len = @min(code_end - code_start, 500);
    const code = try allocator.dupe(u8, source[code_start..][0..code_len]);

    const qualified_id = try types.makeQualifiedId(allocator, file_path, name);

    return FunctionInfo{
        .name = try allocator.dupe(u8, name),
        .file = try allocator.dupe(u8, file_path),
        .qualified_id = qualified_id,
        .line_start = line_start,
        .line_end = line_end,
        .code = code,
    };
}

fn extractCalls(
    allocator: Allocator,
    ast: *const Ast,
    caller_id: []const u8,
    caller_name: []const u8,
    node_idx: Ast.Node.Index,
    calls: *CallList,
) !void {
    if (@intFromEnum(node_idx) == 0) return;

    const idx = @intFromEnum(node_idx);
    const tags = ast.nodes.items(.tag);
    const tag = tags[idx];

    switch (tag) {
        .call,
        .call_comma,
        .call_one,
        .call_one_comma,
        => {
            var buf: [1]Ast.Node.Index = undefined;
            const call = ast.fullCall(&buf, node_idx) orelse return;
            const callee_name = getCallTargetName(ast, call.ast.fn_expr);
            if (callee_name) |cname| {
                if (cname.len > 0 and cname[0] != '@') {
                    try calls.append(allocator, .{
                        .caller_id = try allocator.dupe(u8, caller_id),
                        .caller_name = try allocator.dupe(u8, caller_name),
                        .callee = try allocator.dupe(u8, cname),
                    });
                }
            }

            // Recurse into arguments
            for (call.ast.params) |param| {
                try extractCalls(allocator, ast, caller_id, caller_name, param, calls);
            }
        },
        .block,
        .block_semicolon,
        .block_two,
        .block_two_semicolon,
        => {
            var buf: [2]Ast.Node.Index = undefined;
            const stmts = ast.blockStatements(&buf, node_idx);
            if (stmts) |statements| {
                for (statements) |stmt| {
                    try extractCalls(allocator, ast, caller_id, caller_name, stmt, calls);
                }
            }
        },
        .@"if",
        .if_simple,
        => {
            const full_if = ast.fullIf(node_idx) orelse return;
            try extractCalls(allocator, ast, caller_id, caller_name, full_if.ast.cond_expr, calls);
            try extractCalls(allocator, ast, caller_id, caller_name, full_if.ast.then_expr, calls);
            if (full_if.ast.else_expr != .none) {
                try extractCalls(allocator, ast, caller_id, caller_name, full_if.ast.else_expr.unwrap().?, calls);
            }
        },
        .@"while",
        .while_simple,
        .while_cont,
        => {
            const full_while = ast.fullWhile(node_idx) orelse return;
            try extractCalls(allocator, ast, caller_id, caller_name, full_while.ast.cond_expr, calls);
            try extractCalls(allocator, ast, caller_id, caller_name, full_while.ast.then_expr, calls);
            if (full_while.ast.else_expr != .none) {
                try extractCalls(allocator, ast, caller_id, caller_name, full_while.ast.else_expr.unwrap().?, calls);
            }
        },
        .@"for",
        .for_simple,
        => {
            const full_for = ast.fullFor(node_idx) orelse return;
            try extractCalls(allocator, ast, caller_id, caller_name, full_for.ast.then_expr, calls);
            if (full_for.ast.else_expr != .none) {
                try extractCalls(allocator, ast, caller_id, caller_name, full_for.ast.else_expr.unwrap().?, calls);
            }
        },
        .assign,
        .assign_add,
        .assign_sub,
        .assign_mul,
        .assign_div,
        => {
            const data = ast.nodeData(node_idx);
            const parts = data.node_and_node;
            try extractCalls(allocator, ast, caller_id, caller_name, parts[0], calls);
            try extractCalls(allocator, ast, caller_id, caller_name, parts[1], calls);
        },
        .simple_var_decl => {
            const decl = ast.fullVarDecl(node_idx) orelse return;
            if (decl.ast.init_node != .none) {
                try extractCalls(allocator, ast, caller_id, caller_name, decl.ast.init_node.unwrap().?, calls);
            }
        },
        else => {},
    }
}

fn getCallTargetName(ast: *const Ast, node_idx: Ast.Node.Index) ?[]const u8 {
    if (@intFromEnum(node_idx) == 0) return null;

    const idx = @intFromEnum(node_idx);
    const tags = ast.nodes.items(.tag);
    const tag = tags[idx];

    switch (tag) {
        .identifier => {
            const main_tokens = ast.nodes.items(.main_token);
            return ast.tokenSlice(main_tokens[idx]);
        },
        .field_access => {
            const data = ast.nodeData(node_idx);
            const field_token = data.node_and_token[1];
            const token_tags = ast.tokens.items(.tag);
            if (field_token < ast.tokens.len and token_tags[field_token] == .identifier) {
                return ast.tokenSlice(field_token);
            }
            return null;
        },
        else => return null,
    }
}
