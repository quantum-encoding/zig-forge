// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Gemini structured output provider
//!
//! Uses generateContent API with:
//! - responseMimeType: "application/json"
//! - responseJsonSchema: { ... }
//!
//! API: POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent

const std = @import("std");
const http_sentinel = @import("http-sentinel");
const types = @import("../types.zig");

const GEMINI_API_BASE = "https://generativelanguage.googleapis.com/v1beta/models";

pub fn generate(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    request: types.StructuredRequest,
) !types.StructuredResponse {
    const model = request.model orelse types.Provider.gemini.getDefaultModel();

    // Build request payload
    const payload = try buildPayload(allocator, request);
    defer allocator.free(payload);

    // Make HTTP request
    var client = try http_sentinel.HttpClient.init(allocator);
    defer client.deinit();

    const endpoint = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}:generateContent?key={s}",
        .{ GEMINI_API_BASE, model, api_key },
    );
    defer allocator.free(endpoint);

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };

    var response = try client.post(endpoint, &headers, payload);
    defer response.deinit();

    if (response.status != .ok) {
        return handleErrorResponse(response.status);
    }

    // Parse response
    return parseResponse(allocator, response.body);
}

fn buildPayload(allocator: std.mem.Allocator, request: types.StructuredRequest) ![]u8 {
    // Escape prompt
    var escaped_prompt: std.ArrayListUnmanaged(u8) = .empty;
    defer escaped_prompt.deinit(allocator);
    try escapeJsonString(allocator, &escaped_prompt, request.prompt);

    // Build system instruction if provided
    var system_part: []const u8 = "";
    var system_part_owned: ?[]u8 = null;
    if (request.system_prompt) |sys| {
        var escaped_sys: std.ArrayListUnmanaged(u8) = .empty;
        defer escaped_sys.deinit(allocator);
        try escapeJsonString(allocator, &escaped_sys, sys);

        system_part_owned = try std.fmt.allocPrint(allocator,
            \\,"systemInstruction":{{"parts":[{{"text":"{s}"}}]}}
        , .{escaped_sys.items});
        system_part = system_part_owned.?;
    }
    defer if (system_part_owned) |s| allocator.free(s);

    // Build full payload with schema
    const full_payload = try std.fmt.allocPrint(allocator,
        \\{{"contents":[{{"parts":[{{"text":"{s}"}}]}}],"generationConfig":{{"responseMimeType":"application/json","responseJsonSchema":{s},"maxOutputTokens":{d}}}{s}}}
    , .{
        escaped_prompt.items,
        request.schema.schema_json,
        request.max_tokens,
        system_part,
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

    // Extract candidates[0].content.parts[0].text
    const candidates = root.object.get("candidates") orelse
        return types.StructuredError.InvalidResponse;
    if (candidates != .array or candidates.array.items.len == 0)
        return types.StructuredError.InvalidResponse;

    const first_candidate = candidates.array.items[0];
    if (first_candidate != .object) return types.StructuredError.InvalidResponse;

    const content = first_candidate.object.get("content") orelse
        return types.StructuredError.InvalidResponse;
    if (content != .object) return types.StructuredError.InvalidResponse;

    const parts = content.object.get("parts") orelse
        return types.StructuredError.InvalidResponse;
    if (parts != .array or parts.array.items.len == 0)
        return types.StructuredError.InvalidResponse;

    const first_part = parts.array.items[0];
    if (first_part != .object) return types.StructuredError.InvalidResponse;

    const text = first_part.object.get("text") orelse
        return types.StructuredError.InvalidResponse;
    if (text != .string) return types.StructuredError.InvalidResponse;

    // Extract usage stats if available
    var usage: ?types.UsageStats = null;
    if (root.object.get("usageMetadata")) |usage_obj| {
        if (usage_obj == .object) {
            var stats = types.UsageStats{};
            if (usage_obj.object.get("promptTokenCount")) |pt| {
                if (pt == .integer) stats.input_tokens = @intCast(pt.integer);
            }
            if (usage_obj.object.get("candidatesTokenCount")) |ct| {
                if (ct == .integer) stats.output_tokens = @intCast(ct.integer);
            }
            if (usage_obj.object.get("totalTokenCount")) |tt| {
                if (tt == .integer) stats.total_tokens = @intCast(tt.integer);
            }
            usage = stats;
        }
    }

    // Copy raw response for debugging
    const raw_copy = try allocator.dupe(u8, body);
    errdefer allocator.free(raw_copy);

    // Copy the JSON output
    const json_output = try allocator.dupe(u8, text.string);
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
