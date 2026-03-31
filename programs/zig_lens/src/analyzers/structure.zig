const std = @import("std");
const Ast = std.zig.Ast;
const models = @import("../models.zig");
const parser = @import("../parser.zig");

/// Analyze a parsed AST and populate a FileReport with structural information.
pub fn analyze(allocator: std.mem.Allocator, ast: *const Ast, report: *models.FileReport) !void {
    for (ast.rootDecls()) |decl_idx| {
        try analyzeDecl(allocator, ast, decl_idx, report, false);
    }
}

const AnalyzeError = error{OutOfMemory};

fn analyzeDecl(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    node_idx: Ast.Node.Index,
    report: *models.FileReport,
    parent_is_pub: bool,
) AnalyzeError!void {
    const idx = @intFromEnum(node_idx);
    if (idx == 0) return;

    const tags = ast.nodes.items(.tag);
    const tag = tags[idx];
    const main_token = ast.nodes.items(.main_token)[idx];

    switch (tag) {
        .fn_decl => {
            try analyzeFnDecl(allocator, ast, node_idx, report);
        },
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto,
        => {
            // extern fn or fn prototype (no body)
            try analyzeFnProto(allocator, ast, node_idx, report);
        },
        .simple_var_decl => {
            try analyzeVarDecl(allocator, ast, node_idx, report);
        },
        .test_decl => {
            const token_tags = ast.tokens.items(.tag);
            const name_token = main_token + 1;
            const name = if (name_token < ast.tokens.len and token_tags[name_token] == .string_literal) blk: {
                const raw = ast.tokenSlice(name_token);
                break :blk if (raw.len >= 2) raw[1 .. raw.len - 1] else "anonymous";
            } else "anonymous";

            try report.tests.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .line = parser.tokenLine(ast, main_token),
            });
        },
        else => {},
    }
    _ = parent_is_pub;
}

fn analyzeFnDecl(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    node_idx: Ast.Node.Index,
    report: *models.FileReport,
) AnalyzeError!void {
    const idx = @intFromEnum(node_idx);
    const main_token = ast.nodes.items(.main_token)[idx];
    const token_tags = ast.tokens.items(.tag);

    // fn_decl: data = (fn_proto, body)
    const data = ast.nodeData(node_idx);
    const body_node = data.node_and_node[1];

    // Get function name
    const name_token = main_token + 1;
    if (name_token >= ast.tokens.len) return;
    if (token_tags[name_token] != .identifier) return;
    const name = ast.tokenSlice(name_token);
    if (name.len == 0) return;

    const start_line = parser.tokenLine(ast, main_token);
    const end_token = ast.lastToken(body_node);
    const end_line = parser.tokenLine(ast, end_token);
    const body_lines = if (end_line > start_line) end_line - start_line else 1;

    // Extract params and return type from the fn proto
    const proto_node = data.node_and_node[0];
    const params = try extractParams(allocator, ast, proto_node);
    const ret_type = try extractReturnType(allocator, ast, proto_node);

    const is_pub = parser.isPublic(ast, node_idx);
    const is_extern = checkExtern(ast, main_token);
    const is_export = checkExport(ast, main_token);
    const doc = parser.extractDocComment(ast, node_idx);

    try report.functions.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = start_line,
        .end_line = end_line,
        .body_lines = body_lines,
        .params = params,
        .return_type = ret_type,
        .is_pub = is_pub,
        .is_extern = is_extern,
        .is_export = is_export,
        .doc_comment = try allocator.dupe(u8, doc),
    });
}

fn analyzeFnProto(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    node_idx: Ast.Node.Index,
    report: *models.FileReport,
) AnalyzeError!void {
    const name = parser.getDeclName(ast, node_idx) orelse return;
    const idx = @intFromEnum(node_idx);
    const main_token = ast.nodes.items(.main_token)[idx];
    const line = parser.tokenLine(ast, main_token);
    const is_pub = parser.isPublic(ast, node_idx);
    const is_extern = checkExtern(ast, main_token);
    const doc = parser.extractDocComment(ast, node_idx);

    try report.functions.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .line = line,
        .end_line = line,
        .body_lines = 0,
        .params = try allocator.dupe(u8, ""),
        .return_type = try allocator.dupe(u8, ""),
        .is_pub = is_pub,
        .is_extern = is_extern,
        .is_export = false,
        .doc_comment = try allocator.dupe(u8, doc),
    });
}

fn analyzeVarDecl(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    node_idx: Ast.Node.Index,
    report: *models.FileReport,
) AnalyzeError!void {
    const name = parser.getDeclName(ast, node_idx) orelse return;
    const idx = @intFromEnum(node_idx);
    const main_token = ast.nodes.items(.main_token)[idx];
    const line = parser.tokenLine(ast, main_token);
    const is_pub = parser.isPublic(ast, node_idx);
    const doc = parser.extractDocComment(ast, node_idx);

    // Check if the init expression is a container (struct/enum/union)
    const decl = ast.fullVarDecl(node_idx) orelse {
        try report.constants.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .line = line,
            .is_pub = is_pub,
            .type_name = try allocator.dupe(u8, ""),
            .doc_comment = try allocator.dupe(u8, doc),
        });
        return;
    };

    if (decl.ast.init_node == .none) {
        try report.constants.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .line = line,
            .is_pub = is_pub,
            .type_name = try allocator.dupe(u8, ""),
            .doc_comment = try allocator.dupe(u8, doc),
        });
        return;
    }

    const init_node = decl.ast.init_node.unwrap() orelse {
        try report.constants.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .line = line,
            .is_pub = is_pub,
            .type_name = try allocator.dupe(u8, ""),
            .doc_comment = try allocator.dupe(u8, doc),
        });
        return;
    };

    const init_idx = @intFromEnum(init_node);
    const init_tag = ast.nodes.items(.tag)[init_idx];

    switch (init_tag) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        => {
            try analyzeContainer(allocator, ast, init_node, name, line, is_pub, doc, report);
        },
        else => {
            // Regular constant
            const type_name = extractTypeName(ast, decl) orelse "";
            try report.constants.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .line = line,
                .is_pub = is_pub,
                .type_name = try allocator.dupe(u8, type_name),
                .doc_comment = try allocator.dupe(u8, doc),
            });
        },
    }
}

fn analyzeContainer(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    container_node: Ast.Node.Index,
    name: []const u8,
    line: u32,
    is_pub: bool,
    doc: []const u8,
    report: *models.FileReport,
) AnalyzeError!void {
    var buf: [2]Ast.Node.Index = undefined;
    const container = ast.fullContainerDecl(&buf, container_node) orelse return;

    // Determine container kind from keyword token
    const container_idx = @intFromEnum(container_node);
    const container_main = ast.nodes.items(.main_token)[container_idx];
    const keyword = ast.tokenSlice(container_main);

    var fields: u32 = 0;
    var methods: u32 = 0;
    var variants: u32 = 0;

    // Count members
    for (container.ast.members) |member_idx| {
        const member_i = @intFromEnum(member_idx);
        const member_tag = ast.nodes.items(.tag)[member_i];
        switch (member_tag) {
            .fn_decl => methods += 1,
            .fn_proto_simple,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto,
            => methods += 1,
            .container_field_init,
            .container_field,
            => {
                if (std.mem.eql(u8, keyword, "enum")) {
                    variants += 1;
                } else {
                    fields += 1;
                }
            },
            else => {},
        }
    }

    // Check for tag type
    const has_tag = container.ast.arg != .none;

    if (std.mem.eql(u8, keyword, "enum")) {
        try report.enums.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .line = line,
            .variants_count = variants,
            .has_tag_type = has_tag,
            .methods_count = methods,
            .is_pub = is_pub,
            .doc_comment = try allocator.dupe(u8, doc),
        });
    } else if (std.mem.eql(u8, keyword, "union")) {
        try report.unions.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .line = line,
            .fields_count = fields,
            .has_tag_type = has_tag,
            .methods_count = methods,
            .is_pub = is_pub,
            .doc_comment = try allocator.dupe(u8, doc),
        });
    } else {
        // struct (regular, packed, extern)
        const kind = classifyStruct(ast, container_main);
        try report.structs.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .line = line,
            .kind = kind,
            .fields_count = fields,
            .methods_count = methods,
            .is_pub = is_pub,
            .doc_comment = try allocator.dupe(u8, doc),
        });
    }

    // Recurse into container members for nested declarations
    for (container.ast.members) |member_idx| {
        const member_i = @intFromEnum(member_idx);
        const member_tag = ast.nodes.items(.tag)[member_i];
        switch (member_tag) {
            .fn_decl,
            .simple_var_decl,
            .test_decl,
            => try analyzeDecl(allocator, ast, member_idx, report, is_pub),
            else => {},
        }
    }
}

fn classifyStruct(ast: *const Ast, main_token: u32) models.ContainerKind {
    // Check token before 'struct' keyword for 'packed' or 'extern'
    if (main_token > 0) {
        const prev = ast.tokenSlice(main_token - 1);
        if (std.mem.eql(u8, prev, "packed")) return .packed_struct;
        if (std.mem.eql(u8, prev, "extern")) return .extern_struct;
    }
    return .@"struct";
}

fn checkExtern(ast: *const Ast, main_token: u32) bool {
    if (main_token == 0) return false;
    const prev = ast.tokenSlice(main_token - 1);
    if (std.mem.eql(u8, prev, "extern")) return true;
    // pub extern fn
    if (main_token >= 2) {
        const prev2 = ast.tokenSlice(main_token - 2);
        if (std.mem.eql(u8, prev, "extern") or std.mem.eql(u8, prev2, "extern")) return true;
    }
    return false;
}

fn checkExport(ast: *const Ast, main_token: u32) bool {
    if (main_token == 0) return false;
    const prev = ast.tokenSlice(main_token - 1);
    if (std.mem.eql(u8, prev, "export")) return true;
    if (main_token >= 2) {
        const prev2 = ast.tokenSlice(main_token - 2);
        if (std.mem.eql(u8, prev2, "export")) return true;
    }
    return false;
}

fn extractParams(allocator: std.mem.Allocator, ast: *const Ast, proto_node: Ast.Node.Index) AnalyzeError![]const u8 {
    var buf: [1]Ast.Node.Index = undefined;
    const proto = ast.fullFnProto(&buf, proto_node) orelse return try allocator.dupe(u8, "");

    var params_buf: std.ArrayListUnmanaged(u8) = .empty;
    var first = true;

    var it = proto.iterate(ast);
    while (it.next()) |param| {
        if (!first) try params_buf.appendSlice(allocator, ", ");
        first = false;

        if (param.name_token) |n| {
            const name_str = ast.tokenSlice(n);
            try params_buf.appendSlice(allocator, name_str);
            try params_buf.appendSlice(allocator, ": ");
        }

        if (param.type_expr) |type_n| {
            const type_tok = ast.nodes.items(.main_token)[@intFromEnum(type_n)];
            try params_buf.appendSlice(allocator, ast.tokenSlice(type_tok));
        } else if (param.anytype_ellipsis3 != null) {
            try params_buf.appendSlice(allocator, "anytype");
        }
    }

    if (params_buf.items.len == 0) return try allocator.dupe(u8, "");
    return params_buf.items;
}

fn extractReturnType(allocator: std.mem.Allocator, ast: *const Ast, proto_node: Ast.Node.Index) AnalyzeError![]const u8 {
    var buf: [1]Ast.Node.Index = undefined;
    const proto = ast.fullFnProto(&buf, proto_node) orelse return try allocator.dupe(u8, "");

    const ret_node = proto.ast.return_type.unwrap() orelse return try allocator.dupe(u8, "");
    const ret_idx = @intFromEnum(ret_node);
    const ret_tok = ast.nodes.items(.main_token)[ret_idx];
    return try allocator.dupe(u8, ast.tokenSlice(ret_tok));
}

fn extractTypeName(ast: *const Ast, decl: Ast.full.VarDecl) ?[]const u8 {
    if (decl.ast.type_node != .none) {
        const type_node = decl.ast.type_node.unwrap() orelse return null;
        const type_idx = @intFromEnum(type_node);
        const type_tok = ast.nodes.items(.main_token)[type_idx];
        return ast.tokenSlice(type_tok);
    }
    return null;
}
