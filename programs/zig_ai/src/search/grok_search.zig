// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Grok Search — Web Search and X Search via xAI Responses API
//!
//! Endpoint: POST https://api.x.ai/v1/responses
//! Auth: Bearer token via XAI_API_KEY
//!
//! Web Search: tools: [{"type": "web_search", ...}]
//! X Search:   tools: [{"type": "x_search", ...}]
//!
//! Server-side tool call output types (Responses API):
//!   "web_search_call"       — server handled web search
//!   "x_search_call"         — server handled X search
//!   "code_interpreter_call" — server handled code execution
//!   "file_search_call"      — server handled collections search
//!   "mcp_call"              — server handled MCP tool
//!   "function_call"         — client-side tool (requires local execution)
//!
//! Note: `instructions` parameter is NOT supported by xAI.
//! System prompts go as {"role":"system","content":"..."} in the input array.

const std = @import("std");
const http_sentinel = @import("http-sentinel");
const types = @import("types.zig");

const XAI_RESPONSES_API = "https://api.x.ai/v1/responses";
const DEFAULT_MODEL = "grok-4-1-fast-reasoning";

pub fn search(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    request: types.SearchRequest,
) !types.SearchResponse {
    const payload = try buildPayload(allocator, request);
    defer allocator.free(payload);

    var client = try http_sentinel.HttpClient.init(allocator);
    defer client.deinit();

    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(bearer);

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = bearer },
    };

    var response = try client.post(XAI_RESPONSES_API, &headers, payload);
    defer response.deinit();

    if (response.status != .ok) {
        return handleErrorResponse(response.status);
    }

    return parseResponse(allocator, response.body);
}

fn buildPayload(allocator: std.mem.Allocator, request: types.SearchRequest) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    const model = request.model orelse DEFAULT_MODEL;

    // Opening + model
    try buf.appendSlice(allocator, "{\"model\":\"");
    try buf.appendSlice(allocator, model);

    // Input array — system prompt (if any) + user message
    // xAI does NOT support `instructions` — system prompts go in the input array
    try buf.appendSlice(allocator, "\",\"input\":[");

    if (request.instructions) |instr| {
        try buf.appendSlice(allocator, "{\"role\":\"system\",\"content\":\"");
        try escapeJsonString(allocator, &buf, instr);
        try buf.appendSlice(allocator, "\"},");
    }

    try buf.appendSlice(allocator, "{\"role\":\"user\",\"content\":\"");
    try escapeJsonString(allocator, &buf, request.query);
    try buf.appendSlice(allocator, "\"}]");

    // Tools array
    try buf.appendSlice(allocator, ",\"tools\":[{\"type\":\"");
    try buf.appendSlice(allocator, request.mode.toolType());
    try buf.append(allocator, '"');

    // Tool-specific optional fields
    switch (request.mode) {
        .web_search => {
            if (request.allowed_domains) |domains| {
                try buf.appendSlice(allocator, ",\"allowed_domains\":[");
                for (domains, 0..) |d, i| {
                    if (i > 0) try buf.append(allocator, ',');
                    try buf.append(allocator, '"');
                    try escapeJsonString(allocator, &buf, d);
                    try buf.append(allocator, '"');
                }
                try buf.append(allocator, ']');
            }
            if (request.excluded_domains) |domains| {
                try buf.appendSlice(allocator, ",\"excluded_domains\":[");
                for (domains, 0..) |d, i| {
                    if (i > 0) try buf.append(allocator, ',');
                    try buf.append(allocator, '"');
                    try escapeJsonString(allocator, &buf, d);
                    try buf.append(allocator, '"');
                }
                try buf.append(allocator, ']');
            }
            if (request.enable_image_understanding) {
                try buf.appendSlice(allocator, ",\"enable_image_understanding\":true");
            } else {
                try buf.appendSlice(allocator, ",\"enable_image_understanding\":false");
            }
        },
        .x_search => {
            if (request.allowed_x_handles) |handles| {
                try buf.appendSlice(allocator, ",\"allowed_x_handles\":[");
                for (handles, 0..) |h, i| {
                    if (i > 0) try buf.append(allocator, ',');
                    try buf.append(allocator, '"');
                    try escapeJsonString(allocator, &buf, h);
                    try buf.append(allocator, '"');
                }
                try buf.append(allocator, ']');
            }
            if (request.excluded_x_handles) |handles| {
                try buf.appendSlice(allocator, ",\"excluded_x_handles\":[");
                for (handles, 0..) |h, i| {
                    if (i > 0) try buf.append(allocator, ',');
                    try buf.append(allocator, '"');
                    try escapeJsonString(allocator, &buf, h);
                    try buf.append(allocator, '"');
                }
                try buf.append(allocator, ']');
            }
            if (request.from_date) |fd| {
                try buf.appendSlice(allocator, ",\"from_date\":\"");
                try buf.appendSlice(allocator, fd);
                try buf.append(allocator, '"');
            }
            if (request.to_date) |td| {
                try buf.appendSlice(allocator, ",\"to_date\":\"");
                try buf.appendSlice(allocator, td);
                try buf.append(allocator, '"');
            }
            if (request.enable_image_understanding) {
                try buf.appendSlice(allocator, ",\"enable_image_understanding\":true");
            } else {
                try buf.appendSlice(allocator, ",\"enable_image_understanding\":false");
            }
            if (request.enable_video_understanding) {
                try buf.appendSlice(allocator, ",\"enable_video_understanding\":true");
            } else {
                try buf.appendSlice(allocator, ",\"enable_video_understanding\":false");
            }
        },
    }

    try buf.appendSlice(allocator, "}]"); // close tools array

    // max_output_tokens
    const max_tok = try std.fmt.allocPrint(allocator, ",\"max_output_tokens\":{d}", .{request.max_output_tokens});
    defer allocator.free(max_tok);
    try buf.appendSlice(allocator, max_tok);

    // max_turns — limit agentic loop turns (optional)
    if (request.max_turns) |mt| {
        const mt_str = try std.fmt.allocPrint(allocator, ",\"max_turns\":{d}", .{mt});
        defer allocator.free(mt_str);
        try buf.appendSlice(allocator, mt_str);
    }

    try buf.append(allocator, '}'); // close root object

    return buf.toOwnedSlice(allocator);
}

fn parseResponse(allocator: std.mem.Allocator, body: []const u8) !types.SearchResponse {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    ) catch return types.SearchError.ParseError;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return types.SearchError.InvalidResponse;

    // Check for error
    if (root.object.get("error")) |_| {
        return types.SearchError.InvalidRequest;
    }

    // Extract response_id
    var response_id: ?[]u8 = null;
    if (root.object.get("id")) |id_val| {
        if (id_val == .string) {
            response_id = try allocator.dupe(u8, id_val.string);
        }
    }
    errdefer if (response_id) |rid| allocator.free(rid);

    // Extract content from output[] items
    var text_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer text_buf.deinit(allocator);

    // Collect sources from url_citation items
    var source_list: std.ArrayListUnmanaged(types.Source) = .empty;
    errdefer {
        for (source_list.items) |*src| src.deinit();
        source_list.deinit(allocator);
    }

    if (root.object.get("output")) |output_arr| {
        if (output_arr == .array) {
            for (output_arr.array.items) |output_item| {
                if (output_item != .object) continue;

                const item_type_val = output_item.object.get("type");

                // Handle "message" type — contains the final text response
                if (output_item.object.get("content")) |content_arr| {
                    if (content_arr == .array) {
                        for (content_arr.array.items) |content_item| {
                            if (content_item != .object) continue;

                            const type_val = content_item.object.get("type") orelse continue;
                            if (type_val != .string) continue;

                            if (std.mem.eql(u8, type_val.string, "output_text")) {
                                if (content_item.object.get("text")) |t| {
                                    if (t == .string) {
                                        try text_buf.appendSlice(allocator, t.string);
                                    }
                                }
                            }

                            // Extract url_citation sources
                            if (std.mem.eql(u8, type_val.string, "url_citation")) {
                                const url_val = content_item.object.get("url") orelse continue;
                                if (url_val != .string) continue;
                                const title_val = content_item.object.get("title");
                                const title_str = if (title_val) |tv| (if (tv == .string) tv.string else "") else "";
                                try source_list.append(allocator, .{
                                    .title = try allocator.dupe(u8, title_str),
                                    .uri = try allocator.dupe(u8, url_val.string),
                                    .allocator = allocator,
                                });
                            }
                        }
                    }
                }

                // Handle direct output_text item (flat output array)
                if (item_type_val) |itv| {
                    if (itv == .string and std.mem.eql(u8, itv.string, "output_text")) {
                        if (output_item.object.get("text")) |t| {
                            if (t == .string) {
                                try text_buf.appendSlice(allocator, t.string);
                            }
                        }
                    }
                }

                // Server-side tool calls (web_search_call, x_search_call, etc.)
                // are handled by xAI internally — we skip them but could log for debug
            }
        }
    }

    if (text_buf.items.len == 0) return types.SearchError.InvalidResponse;

    // Extract usage stats
    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;
    var reasoning_tokens: u32 = 0;
    var cached_tokens: u32 = 0;
    if (root.object.get("usage")) |usage_obj| {
        if (usage_obj == .object) {
            if (usage_obj.object.get("input_tokens")) |it| {
                if (it == .integer) input_tokens = @intCast(it.integer);
            }
            if (usage_obj.object.get("output_tokens")) |ot| {
                if (ot == .integer) output_tokens = @intCast(ot.integer);
            }
            if (usage_obj.object.get("reasoning_tokens")) |rt| {
                if (rt == .integer) reasoning_tokens = @intCast(rt.integer);
            }
            if (usage_obj.object.get("cached_prompt_text_tokens")) |ct| {
                if (ct == .integer) cached_tokens = @intCast(ct.integer);
            }
        }
    }

    // Extract server_side_tool_usage (billable tool executions)
    var tool_usage: types.ServerSideToolUsage = .{};
    if (root.object.get("server_side_tool_usage")) |stu_obj| {
        if (stu_obj == .object) {
            if (stu_obj.object.get("SERVER_SIDE_TOOL_WEB_SEARCH")) |v| {
                if (v == .integer) tool_usage.web_search_calls = @intCast(v.integer);
            }
            if (stu_obj.object.get("SERVER_SIDE_TOOL_X_SEARCH")) |v| {
                if (v == .integer) tool_usage.x_search_calls = @intCast(v.integer);
            }
            if (stu_obj.object.get("SERVER_SIDE_TOOL_CODE_EXECUTION")) |v| {
                if (v == .integer) tool_usage.code_execution_calls = @intCast(v.integer);
            }
            if (stu_obj.object.get("SERVER_SIDE_TOOL_VIEW_IMAGE")) |v| {
                if (v == .integer) tool_usage.view_image_calls = @intCast(v.integer);
            }
            if (stu_obj.object.get("SERVER_SIDE_TOOL_VIEW_X_VIDEO")) |v| {
                if (v == .integer) tool_usage.view_x_video_calls = @intCast(v.integer);
            }
            if (stu_obj.object.get("SERVER_SIDE_TOOL_COLLECTIONS_SEARCH")) |v| {
                if (v == .integer) tool_usage.collections_search_calls = @intCast(v.integer);
            }
            if (stu_obj.object.get("SERVER_SIDE_TOOL_MCP")) |v| {
                if (v == .integer) tool_usage.mcp_calls = @intCast(v.integer);
            }
        }
    }

    const content_copy = try allocator.dupe(u8, text_buf.items);
    errdefer allocator.free(content_copy);

    const sources = try source_list.toOwnedSlice(allocator);

    return types.SearchResponse{
        .content = content_copy,
        .sources = sources,
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
        .reasoning_tokens = reasoning_tokens,
        .cached_tokens = cached_tokens,
        .tool_usage = tool_usage,
        .response_id = response_id,
        .allocator = allocator,
    };
}

fn handleErrorResponse(status: std.http.Status) types.SearchError {
    return switch (status) {
        .unauthorized, .forbidden => types.SearchError.InvalidApiKey,
        .too_many_requests => types.SearchError.RateLimitExceeded,
        .bad_request => types.SearchError.InvalidRequest,
        else => types.SearchError.ServerError,
    };
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
                    var hex_buf: [6]u8 = undefined;
                    const hex = std.fmt.bufPrint(&hex_buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try list.appendSlice(allocator, hex);
                } else {
                    try list.append(allocator, c);
                }
            },
        }
    }
}
