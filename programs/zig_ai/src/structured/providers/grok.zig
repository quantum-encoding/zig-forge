// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Grok structured output provider
//!
//! Uses OpenAI-compatible API with:
//! - response_format.type: "json_schema"
//! - response_format.json_schema: { name, schema, strict }
//!
//! API: POST https://api.x.ai/v1/chat/completions

const std = @import("std");
const http_sentinel = @import("http-sentinel");
const types = @import("../types.zig");

const GROK_API_BASE = "https://api.x.ai/v1/chat/completions";

pub fn generate(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    request: types.StructuredRequest,
) !types.StructuredResponse {
    const model = request.model orelse types.Provider.grok.getDefaultModel();

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

    var response = try client.post(GROK_API_BASE, &headers, payload);
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

    // Build messages array
    var messages: std.ArrayListUnmanaged(u8) = .empty;
    defer messages.deinit(allocator);

    // System message if provided
    if (request.system_prompt) |sys| {
        var escaped_sys: std.ArrayListUnmanaged(u8) = .empty;
        defer escaped_sys.deinit(allocator);
        try escapeJsonString(allocator, &escaped_sys, sys);
        try messages.appendSlice(allocator, "{\"role\":\"system\",\"content\":\"");
        try messages.appendSlice(allocator, escaped_sys.items);
        try messages.appendSlice(allocator, "\"},");
    }

    // User message
    try messages.appendSlice(allocator, "{\"role\":\"user\",\"content\":\"");
    try messages.appendSlice(allocator, escaped_prompt.items);
    try messages.appendSlice(allocator, "\"}");

    // Build full payload with response_format
    const full_payload = try std.fmt.allocPrint(allocator,
        \\{{"model":"{s}","messages":[{s}],"max_tokens":{d},"response_format":{{"type":"json_schema","json_schema":{{"name":"{s}","schema":{s},"strict":true}}}}}}
    , .{
        model,
        messages.items,
        request.max_tokens,
        request.schema.name,
        request.schema.schema_json,
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
    if (content != .string) return types.StructuredError.InvalidResponse;

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

    const json_output = try allocator.dupe(u8, content.string);
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
