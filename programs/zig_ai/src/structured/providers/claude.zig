// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Claude structured output provider
//!
//! Uses Messages API with output_config.format:
//! - output_config.format.type: "json_schema"
//! - output_config.format.schema: { ... }
//!
//! API: POST https://api.anthropic.com/v1/messages

const std = @import("std");
const http_sentinel = @import("http-sentinel");
const types = @import("../types.zig");

const CLAUDE_API_BASE = "https://api.anthropic.com/v1/messages";
pub fn generate(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    request: types.StructuredRequest,
) !types.StructuredResponse {
    const model = request.model orelse types.Provider.claude.getDefaultModel();

    // Build request payload
    const payload = try buildPayload(allocator, model, request);
    defer allocator.free(payload);

    // Make HTTP request
    var client = try http_sentinel.HttpClient.init(allocator);
    defer client.deinit();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "x-api-key", .value = api_key },
        .{ .name = "anthropic-version", .value = "2023-06-01" },
    };

    var response = try client.post(CLAUDE_API_BASE, &headers, payload);
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

    // Build system part if provided
    var system_part: []const u8 = "";
    var system_part_owned: ?[]u8 = null;
    if (request.system_prompt) |sys| {
        var escaped_sys: std.ArrayListUnmanaged(u8) = .empty;
        defer escaped_sys.deinit(allocator);
        try escapeJsonString(allocator, &escaped_sys, sys);

        system_part_owned = try std.fmt.allocPrint(allocator,
            \\,"system":"{s}"
        , .{escaped_sys.items});
        system_part = system_part_owned.?;
    }
    defer if (system_part_owned) |s| allocator.free(s);

    // Build full payload with output_config.format (Opus 4.6+)
    const full_payload = try std.fmt.allocPrint(allocator,
        \\{{"model":"{s}","max_tokens":{d},"messages":[{{"role":"user","content":"{s}"}}],"output_config":{{"format":{{"type":"json_schema","schema":{s}}}}}{s}}}
    , .{
        model,
        request.max_tokens,
        escaped_prompt.items,
        request.schema.schema_json,
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

    // Check stop_reason for refusal / context window exceeded (4.5+) / max_tokens
    if (root.object.get("stop_reason")) |stop| {
        if (stop == .string and std.mem.eql(u8, stop.string, "refusal")) {
            return types.StructuredError.RefusalError;
        }
        if (stop == .string and std.mem.eql(u8, stop.string, "model_context_window_exceeded")) {
            return types.StructuredError.MaxTokensExceeded;
        }
        if (stop == .string and std.mem.eql(u8, stop.string, "max_tokens")) {
            return types.StructuredError.MaxTokensExceeded;
        }
    }

    // Extract content[0].text
    const content = root.object.get("content") orelse
        return types.StructuredError.InvalidResponse;
    if (content != .array or content.array.items.len == 0)
        return types.StructuredError.InvalidResponse;

    const first_content = content.array.items[0];
    if (first_content != .object) return types.StructuredError.InvalidResponse;

    const text = first_content.object.get("text") orelse
        return types.StructuredError.InvalidResponse;
    if (text != .string) return types.StructuredError.InvalidResponse;

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
            stats.total_tokens = stats.input_tokens + stats.output_tokens;
            usage = stats;
        }
    }

    const raw_copy = try allocator.dupe(u8, body);
    errdefer allocator.free(raw_copy);

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
