// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! DeepSeek structured output provider
//!
//! DeepSeek doesn't support strict schema enforcement, so we:
//! 1. Include the JSON schema in the system prompt with examples
//! 2. Use response_format: {"type": "json_object"}
//!
//! This relies on prompt engineering rather than constrained decoding.
//!
//! API: POST https://api.deepseek.com/chat/completions

const std = @import("std");
const http_sentinel = @import("http-sentinel");
const types = @import("../types.zig");

const DEEPSEEK_API_BASE = "https://api.deepseek.com/chat/completions";

pub fn generate(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    request: types.StructuredRequest,
) !types.StructuredResponse {
    const model = request.model orelse types.Provider.deepseek.getDefaultModel();

    // Build request payload
    const payload = try buildPayload(allocator, model, request);
    defer allocator.free(payload);

    // Make HTTP request
    var client = try http_sentinel.HttpClient.init(allocator);
    defer client.deinit();

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = auth_header },
    };

    var response = try client.post(DEEPSEEK_API_BASE, &headers, payload);
    defer response.deinit();

    if (response.status != .ok) {
        return handleErrorResponse(response.status);
    }

    // Parse response
    return parseResponse(allocator, response.body);
}

fn buildPayload(allocator: std.mem.Allocator, model: []const u8, request: types.StructuredRequest) ![]u8 {
    var escaped_prompt: std.ArrayListUnmanaged(u8) = .empty;
    defer escaped_prompt.deinit(allocator);
    try escapeJsonString(allocator, &escaped_prompt, request.prompt);

    // Build system message with schema
    // DeepSeek requires "json" word in the prompt and an example
    var system_content: std.ArrayListUnmanaged(u8) = .empty;
    defer system_content.deinit(allocator);

    // Add user's system prompt if provided
    if (request.system_prompt) |sys| {
        try escapeJsonString(allocator, &system_content, sys);
        try system_content.appendSlice(allocator, "\\n\\n");
    }

    // Add schema instructions
    try system_content.appendSlice(allocator, "You must output valid JSON that matches this schema:\\n");
    try escapeJsonString(allocator, &system_content, request.schema.schema_json);

    // Add description if available
    if (request.schema.description) |desc| {
        try system_content.appendSlice(allocator, "\\n\\nSchema description: ");
        try escapeJsonString(allocator, &system_content, desc);
    }

    // Add instruction to output only JSON
    try system_content.appendSlice(allocator, "\\n\\nIMPORTANT: Output ONLY the JSON object, nothing else. No markdown, no explanation.");

    // Build full payload with response_format
    const full_payload = try std.fmt.allocPrint(allocator,
        \\{{"model":"{s}","messages":[{{"role":"system","content":"{s}"}},{{"role":"user","content":"{s}"}}],"max_tokens":{d},"response_format":{{"type":"json_object"}}}}
    , .{
        model,
        system_content.items,
        escaped_prompt.items,
        request.max_tokens,
    });

    return full_payload;
}

fn escapeJsonString(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    const hex = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try list.appendSlice(allocator, hex);
                } else {
                    try list.append(allocator, c);
                }
            },
        }
    }
}

fn parseResponse(allocator: std.mem.Allocator, body: []const u8) !types.StructuredResponse {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    ) catch return types.StructuredError.ParseError;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return types.StructuredError.InvalidResponse;

    // Check for error
    if (root.object.get("error")) |_| {
        return types.StructuredError.InvalidRequest;
    }

    // Extract choices[0].message.content
    const choices = root.object.get("choices") orelse
        return types.StructuredError.InvalidResponse;
    if (choices != .array or choices.array.items.len == 0)
        return types.StructuredError.InvalidResponse;

    const first_choice = choices.array.items[0];
    if (first_choice != .object) return types.StructuredError.InvalidResponse;

    // Check finish_reason
    if (first_choice.object.get("finish_reason")) |fr| {
        if (fr == .string) {
            if (std.mem.eql(u8, fr.string, "length")) {
                return types.StructuredError.MaxTokensExceeded;
            }
        }
    }

    const message = first_choice.object.get("message") orelse
        return types.StructuredError.InvalidResponse;
    if (message != .object) return types.StructuredError.InvalidResponse;

    const content = message.object.get("content") orelse
        return types.StructuredError.InvalidResponse;

    var json_text: []const u8 = "";
    if (content == .string) {
        json_text = content.string;
    } else if (content == .null) {
        // DeepSeek sometimes returns null content
        return types.StructuredError.InvalidResponse;
    }

    if (json_text.len == 0) return types.StructuredError.InvalidResponse;

    // Extract usage stats
    var usage: ?types.UsageStats = null;
    if (root.object.get("usage")) |usage_obj| {
        if (usage_obj == .object) {
            var stats = types.UsageStats{};
            if (usage_obj.object.get("prompt_tokens")) |pt| {
                if (pt == .integer) stats.input_tokens = @intCast(pt.integer);
            }
            if (usage_obj.object.get("completion_tokens")) |ct| {
                if (ct == .integer) stats.output_tokens = @intCast(ct.integer);
            }
            if (usage_obj.object.get("total_tokens")) |tt| {
                if (tt == .integer) stats.total_tokens = @intCast(tt.integer);
            }
            usage = stats;
        }
    }

    const raw_copy = try allocator.dupe(u8, body);
    errdefer allocator.free(raw_copy);

    const json_output = try allocator.dupe(u8, json_text);
    errdefer allocator.free(json_output);

    return types.StructuredResponse{
        .json_output = json_output,
        .raw_response = raw_copy,
        .usage = usage,
        .allocator = allocator,
    };
}

fn handleErrorResponse(status: std.http.Status) types.StructuredError {
    return switch (status) {
        .unauthorized, .forbidden => types.StructuredError.InvalidApiKey,
        .too_many_requests => types.StructuredError.RateLimitExceeded,
        .bad_request => types.StructuredError.InvalidRequest,
        else => types.StructuredError.ServerError,
    };
}
