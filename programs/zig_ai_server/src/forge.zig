// Forge — provider-agnostic tool normalization layer.
//
// Transforms canonical tool definitions into provider-specific formats.
// Handles all the quirks so clients never have to:
//
//   Anthropic: inject additionalProperties:false recursively, drop strict:true
//              if >20 tools, disable thinking when tool_choice forces use
//   Gemini:    separate tools from system_instruction when caching,
//              set includeServerSideToolInvocations for mixed built-in+custom,
//              preserve raw thought_signature parts verbatim
//   OpenAI:    wrap in {"type":"function","function":{...}} envelope
//
// The forge is the API's core value — clients send canonical tools, the server
// handles all provider-specific reshaping.

const std = @import("std");
const hs = @import("http-sentinel");
const ToolDefinition = hs.ai.common.ToolDefinition;

/// Provider target for normalization
pub const Provider = enum {
    anthropic,
    deepseek,
    openai,
    gemini,
    grok,
    vertex,

    pub fn fromModel(model: []const u8) Provider {
        if (std.mem.startsWith(u8, model, "claude")) return .anthropic;
        if (std.mem.startsWith(u8, model, "deepseek")) return .deepseek; // uses Anthropic format
        if (std.mem.startsWith(u8, model, "gemini")) return .gemini;
        if (std.mem.startsWith(u8, model, "grok")) return .grok;
        if (std.mem.startsWith(u8, model, "gpt") or std.mem.startsWith(u8, model, "o1") or
            std.mem.startsWith(u8, model, "o3") or std.mem.startsWith(u8, model, "o4")) return .openai;
        // Vertex MaaS models
        if (std.mem.startsWith(u8, model, "xai/") or std.mem.startsWith(u8, model, "zai-org/") or
            std.mem.startsWith(u8, model, "qwen/") or std.mem.startsWith(u8, model, "deepseek-ai/")) return .vertex;
        return .openai; // safe default
    }
};

/// Forge config for a single request
pub const ForgeConfig = struct {
    provider: Provider,
    tool_count: usize = 0,
    thinking_enabled: bool = false,
    tool_choice_forces_use: bool = false, // .required or .function
};

// ── Schema Normalization ───────────────────────────────────────

/// Normalize a tool's input_schema for a specific provider.
/// Returns a new JSON string (caller owns) or null if no changes needed.
///
/// Anthropic: inject "additionalProperties":false at every object node
/// Others: pass through unchanged (for now)
pub fn normalizeSchema(
    allocator: std.mem.Allocator,
    schema_json: []const u8,
    provider: Provider,
) !?[]u8 {
    switch (provider) {
        .anthropic, .deepseek => {
            // Parse, walk, inject additionalProperties:false, re-serialize
            return injectAdditionalProperties(allocator, schema_json);
        },
        else => return null, // No transformation needed
    }
}

/// Walk a JSON Schema and inject "additionalProperties":false at every
/// object node that has "properties" or "type":"object". Recursive.
fn injectAdditionalProperties(allocator: std.mem.Allocator, json: []const u8) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch
        return null; // Unparseable schema — pass through unchanged
    defer parsed.deinit();

    if (parsed.value != .object) return null;

    var modified = false;
    var mutable_value = parsed.value;
    walkAndInject(allocator, &mutable_value, &modified);

    if (!modified) return null;

    // Re-serialize
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    serializeValue(allocator, &buf, mutable_value) catch return null;
    const slice = buf.toOwnedSlice(allocator) catch return null;
    return @as(?[]u8, slice);
}

/// Recursively walk a JSON value and inject additionalProperties:false
/// at every object node that has "type":"object" or "properties".
fn walkAndInject(allocator: std.mem.Allocator, value: *std.json.Value, modified: *bool) void {
    switch (value.*) {
        .object => |*obj| {
            // Check if this is a schema object (has "type":"object" or "properties")
            const is_object_schema = blk: {
                if (obj.get("type")) |t| {
                    if (t == .string and std.mem.eql(u8, t.string, "object")) break :blk true;
                }
                if (obj.get("properties") != null) break :blk true;
                break :blk false;
            };

            if (is_object_schema) {
                // Inject additionalProperties:false if not already present
                if (obj.get("additionalProperties") == null) {
                    obj.put(allocator, "additionalProperties", .{ .bool = false }) catch {};
                    modified.* = true;
                }
            }

            // Recurse into all values
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                walkAndInject(allocator, entry.value_ptr, modified);
            }
        },
        .array => |*arr| {
            for (arr.items) |*item| {
                walkAndInject(allocator, item, modified);
            }
        },
        else => {},
    }
}

/// Serialize a JSON value back to a string (compact, no whitespace).
fn serializeValue(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), value: std.json.Value) !void {
    switch (value) {
        .null => try buf.appendSlice(allocator, "null"),
        .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{i});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .float => |f| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{f});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .string => |s| {
            try buf.append(allocator, '"');
            // Escape the string
            for (s) |c| {
                switch (c) {
                    '"' => try buf.appendSlice(allocator, "\\\""),
                    '\\' => try buf.appendSlice(allocator, "\\\\"),
                    '\n' => try buf.appendSlice(allocator, "\\n"),
                    '\r' => try buf.appendSlice(allocator, "\\r"),
                    '\t' => try buf.appendSlice(allocator, "\\t"),
                    else => {
                        if (c < 0x20) {
                            const hex = "0123456789abcdef";
                            try buf.appendSlice(allocator, "\\u00");
                            try buf.append(allocator, hex[c >> 4]);
                            try buf.append(allocator, hex[c & 0x0f]);
                        } else {
                            try buf.append(allocator, c);
                        }
                    },
                }
            }
            try buf.append(allocator, '"');
        },
        .number_string => |s| try buf.appendSlice(allocator, s),
        .array => |arr| {
            try buf.append(allocator, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try buf.append(allocator, ',');
                try serializeValue(allocator, buf, item);
            }
            try buf.append(allocator, ']');
        },
        .object => |obj| {
            try buf.append(allocator, '{');
            var first = true;
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                if (!first) try buf.append(allocator, ',');
                first = false;
                try buf.append(allocator, '"');
                try buf.appendSlice(allocator, entry.key_ptr.*);
                try buf.append(allocator, '"');
                try buf.append(allocator, ':');
                try serializeValue(allocator, buf, entry.value_ptr.*);
            }
            try buf.append(allocator, '}');
        },
    }
}

// ── Tool Array Normalization ───────────────────────────────────

/// Normalize an array of tool definitions for a specific provider.
/// Returns a new array with provider-specific schema transformations applied.
/// Caller owns the returned array and each tool's input_schema.
pub fn normalizeTools(
    allocator: std.mem.Allocator,
    tools: []const ToolDefinition,
    config: ForgeConfig,
) ![]ToolDefinition {
    var result: std.ArrayListUnmanaged(ToolDefinition) = .empty;
    errdefer {
        for (result.items) |t| {
            if (t.input_schema.ptr != tools[0].input_schema.ptr) // don't free originals
                allocator.free(t.input_schema);
        }
        result.deinit(allocator);
    }

    for (tools) |tool| {
        var normalized_tool = tool;

        // Normalize schema per provider
        if (normalizeSchema(allocator, tool.input_schema, config.provider) catch null) |new_schema| {
            normalized_tool.input_schema = new_schema;
        }

        try result.append(allocator, normalized_tool);
    }

    return result.toOwnedSlice(allocator);
}

/// Check if thinking should be disabled for this request.
/// Anthropic: thinking and tool_choice:"any"/"tool" are mutually exclusive.
pub fn shouldDisableThinking(config: ForgeConfig) bool {
    if (!config.thinking_enabled) return false;
    return switch (config.provider) {
        .anthropic, .deepseek => config.tool_choice_forces_use,
        else => false,
    };
}

/// Check if strict:true should be dropped from tool definitions.
/// Anthropic has a 20-tool limit when strict is enabled.
pub fn shouldDropStrict(config: ForgeConfig) bool {
    return switch (config.provider) {
        .anthropic, .deepseek => config.tool_count > 20,
        else => false,
    };
}

// ── Tests ──────────────────────────────────────────────────────

test "forge: Anthropic schema gets additionalProperties injected" {
    const allocator = std.testing.allocator;
    const schema =
        \\{"type":"object","properties":{"name":{"type":"string"}}}
    ;

    const result = try normalizeSchema(allocator, schema, .anthropic);
    try std.testing.expect(result != null);
    defer allocator.free(result.?);

    // Must contain additionalProperties:false
    try std.testing.expect(std.mem.indexOf(u8, result.?, "additionalProperties") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "false") != null);
}

test "forge: nested objects get additionalProperties recursively" {
    const allocator = std.testing.allocator;
    const schema =
        \\{"type":"object","properties":{"address":{"type":"object","properties":{"street":{"type":"string"}}}}}
    ;

    const result = try normalizeSchema(allocator, schema, .anthropic);
    try std.testing.expect(result != null);
    defer allocator.free(result.?);

    // Count occurrences of additionalProperties — should be 2 (root + nested)
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, result.?, pos, "additionalProperties")) |idx| {
        count += 1;
        pos = idx + 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "forge: non-object schema passes through unchanged" {
    const allocator = std.testing.allocator;
    const schema =
        \\{"type":"string"}
    ;

    const result = try normalizeSchema(allocator, schema, .anthropic);
    // No object nodes → no modification needed
    try std.testing.expect(result == null);
}

test "forge: OpenAI/Gemini schemas pass through unchanged" {
    const allocator = std.testing.allocator;
    const schema =
        \\{"type":"object","properties":{"x":{"type":"string"}}}
    ;

    const result_openai = try normalizeSchema(allocator, schema, .openai);
    try std.testing.expect(result_openai == null);

    const result_gemini = try normalizeSchema(allocator, schema, .gemini);
    try std.testing.expect(result_gemini == null);
}

test "forge: existing additionalProperties not duplicated" {
    const allocator = std.testing.allocator;
    const schema =
        \\{"type":"object","properties":{"x":{"type":"string"}},"additionalProperties":false}
    ;

    const result = try normalizeSchema(allocator, schema, .anthropic);
    // Already has it → no modification
    try std.testing.expect(result == null);
}

test "forge: shouldDisableThinking for Anthropic with forced tool_choice" {
    try std.testing.expect(shouldDisableThinking(.{
        .provider = .anthropic,
        .thinking_enabled = true,
        .tool_choice_forces_use = true,
    }));
}

test "forge: shouldDisableThinking false when not forcing tool use" {
    try std.testing.expect(!shouldDisableThinking(.{
        .provider = .anthropic,
        .thinking_enabled = true,
        .tool_choice_forces_use = false,
    }));
}

test "forge: shouldDropStrict for Anthropic with >20 tools" {
    try std.testing.expect(shouldDropStrict(.{ .provider = .anthropic, .tool_count = 21 }));
    try std.testing.expect(!shouldDropStrict(.{ .provider = .anthropic, .tool_count = 20 }));
    try std.testing.expect(!shouldDropStrict(.{ .provider = .openai, .tool_count = 100 }));
}

test "forge: Provider.fromModel resolves correctly" {
    try std.testing.expectEqual(Provider.anthropic, Provider.fromModel("claude-sonnet-4-6"));
    try std.testing.expectEqual(Provider.deepseek, Provider.fromModel("deepseek-chat"));
    try std.testing.expectEqual(Provider.gemini, Provider.fromModel("gemini-2.5-flash"));
    try std.testing.expectEqual(Provider.grok, Provider.fromModel("grok-4.20-non-reasoning"));
    try std.testing.expectEqual(Provider.openai, Provider.fromModel("gpt-5.4"));
    try std.testing.expectEqual(Provider.vertex, Provider.fromModel("xai/grok-4.20-non-reasoning"));
    try std.testing.expectEqual(Provider.vertex, Provider.fromModel("zai-org/glm-5-maas"));
}

test "forge: normalizeTools transforms all schemas" {
    const allocator = std.testing.allocator;
    const tools = [_]ToolDefinition{
        .{
            .name = "read_file",
            .description = "read a file",
            .input_schema =
            \\{"type":"object","properties":{"path":{"type":"string"}}}
            ,
        },
        .{
            .name = "write_file",
            .description = "write a file",
            .input_schema =
            \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}}}
            ,
        },
    };

    const normalized = try normalizeTools(allocator, &tools, .{ .provider = .anthropic, .tool_count = 2 });
    defer {
        for (normalized) |t| {
            if (t.input_schema.ptr != tools[0].input_schema.ptr and
                t.input_schema.ptr != tools[1].input_schema.ptr)
                allocator.free(@constCast(t.input_schema));
        }
        allocator.free(normalized);
    }

    try std.testing.expectEqual(@as(usize, 2), normalized.len);
    // Both should have additionalProperties injected
    for (normalized) |t| {
        try std.testing.expect(std.mem.indexOf(u8, t.input_schema, "additionalProperties") != null);
    }
}
