// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! OpenAI structured output provider
//!
//! Uses Responses API with:
//! - text.format.type: "json_schema"
//! - text.format.schema: { ... }
//! - text.format.strict: true
//!
//! API: POST https://api.openai.com/v1/responses

const std = @import("std");
const http_sentinel = @import("http-sentinel");
const types = @import("../types.zig");

const OPENAI_API_BASE = "https://api.openai.com/v1/responses";

pub fn generate(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    request: types.StructuredRequest,
) !types.StructuredResponse {
    const model = request.model orelse types.Provider.openai.getDefaultModel();

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

    var response = try client.post(OPENAI_API_BASE, &headers, payload);
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

    // Build full payload
    const full_payload = try std.fmt.allocPrint(allocator,
        \\{{"model":"{s}","input":[{s}],"max_output_tokens":{d},"text":{{"format":{{"type":"json_schema","name":"{s}","schema":{s},"strict":true}}}}}}
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

    // Check for error (not null)
    if (root.object.get("error")) |err| {
        if (err != .null) {
            return types.StructuredError.InvalidRequest;
        }
    }

    // Check status
    if (root.object.get("status")) |status| {
        if (status == .string and std.mem.eql(u8, status.string, "incomplete")) {
            // Check reason
            if (root.object.get("incomplete_details")) |details| {
                if (details == .object) {
                    if (details.object.get("reason")) |reason| {
                        if (reason == .string and std.mem.eql(u8, reason.string, "max_output_tokens")) {
                            return types.StructuredError.MaxTokensExceeded;
                        }
                    }
                }
            }
        }
    }

    // Extract output[0].content[0].text or output_text
    var json_text: []const u8 = "";

    if (root.object.get("output_text")) |text| {
        if (text == .string) {
            json_text = text.string;
        }
    }

    if (json_text.len == 0) {
        if (root.object.get("output")) |output| {
            if (output == .array and output.array.items.len > 0) {
                const first_output = output.array.items[0];
                if (first_output == .object) {
                    if (first_output.object.get("content")) |content| {
                        if (content == .array and content.array.items.len > 0) {
                            const first_content = content.array.items[0];
                            if (first_content == .object) {
                                // Check for refusal
                                if (first_content.object.get("type")) |typ| {
                                    if (typ == .string and std.mem.eql(u8, typ.string, "refusal")) {
                                        return types.StructuredError.RefusalError;
                                    }
                                }
                                if (first_content.object.get("text")) |text| {
                                    if (text == .string) {
                                        json_text = text.string;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (json_text.len == 0) return types.StructuredError.InvalidResponse;

    // Extract usage stats
    var usage: ?types.UsageStats = null;
    if (root.object.get("usage")) |usage_obj| {
        if (usage_obj == .object) {
            var stats = types.UsageStats{};
            if (usage_obj.object.get("input_tokens")) |it| {
                if (it == .integer) stats.input_tokens = @intCast(it.integer);
            }
            if (usage_obj.object.get("output_tokens")) |ot| {
                if (ot == .integer) stats.output_tokens = @intCast(ot.integer);
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
