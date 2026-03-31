// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Web Search via Gemini generateContent with Google Search grounding
//!
//! Uses tools: [{ google_search: {} }] to enable real-time web search.
//! The model autonomously searches the web and returns grounded results
//! with citations from groundingMetadata.groundingChunks.
//!
//! API: POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent

const std = @import("std");
const http_sentinel = @import("http-sentinel");
const types = @import("types.zig");

const GEMINI_API_BASE = "https://generativelanguage.googleapis.com/v1beta/models";
const DEFAULT_MODEL = "gemini-2.5-flash";

pub fn search(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    request: types.ResearchRequest,
) !types.ResearchResponse {
    const model = request.model orelse DEFAULT_MODEL;

    const payload = try buildPayload(allocator, model, request);
    defer allocator.free(payload);

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

    return parseResponse(allocator, response.body);
}

fn buildPayload(allocator: std.mem.Allocator, model: []const u8, request: types.ResearchRequest) ![]u8 {
    var escaped_query: std.ArrayListUnmanaged(u8) = .empty;
    defer escaped_query.deinit(allocator);
    try escapeJsonString(allocator, &escaped_query, request.query);

    // System instruction (optional)
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

    // Thinking config — model-family dependent:
    //   Gemini 3 Pro:   thinkingLevel — only "low" and "high" supported
    //   Gemini 3 Flash: thinkingLevel — "minimal", "low", "medium", "high" all supported
    //   Gemini 2.5:     thinkingBudget (0=off, -1=dynamic, 128..32768)
    //   Other models:   omit entirely
    var thinking_part: []const u8 = "";
    var thinking_part_owned: ?[]u8 = null;
    if (std.mem.startsWith(u8, model, "gemini-3")) {
        // Gemini 3 — use thinkingLevel
        // Pro only supports "low" and "high"; Flash supports all four
        const is_pro = std.mem.indexOf(u8, model, "pro") != null;
        const level_str = if (is_pro) switch (request.thinking) {
            .off => "low", // Pro doesn't support "minimal", lowest is "low"
            .low => "low",
            .medium => "low", // Pro doesn't support "medium", fall back to "low"
            .high => "high",
        } else switch (request.thinking) {
            .off => "minimal", // Flash: "minimal" ≈ off (may still think on complex tasks)
            .low => "low",
            .medium => "medium",
            .high => "high",
        };
        thinking_part_owned = try std.fmt.allocPrint(allocator,
            \\,"thinkingConfig":{{"thinkingLevel":"{s}"}}
        , .{level_str});
        thinking_part = thinking_part_owned.?;
    } else if (std.mem.startsWith(u8, model, "gemini-2.5")) {
        // Gemini 2.5 — use thinkingBudget
        const budget: i32 = switch (request.thinking) {
            .off => 0,
            .low => 1024,
            .medium => 8192,
            .high => -1, // dynamic
        };
        thinking_part_owned = try std.fmt.allocPrint(allocator,
            \\,"thinkingConfig":{{"thinkingBudget":{d}}}
        , .{budget});
        thinking_part = thinking_part_owned.?;
    }
    defer if (thinking_part_owned) |s| allocator.free(s);

    const full_payload = try std.fmt.allocPrint(allocator,
        \\{{"contents":[{{"parts":[{{"text":"{s}"}}]}}],"tools":[{{"google_search":{{}}}}],"generationConfig":{{"maxOutputTokens":{d}{s}}}{s}}}
    , .{
        escaped_query.items,
        request.max_tokens,
        thinking_part,
        system_part,
    });

    return full_payload;
}

fn parseResponse(allocator: std.mem.Allocator, body: []const u8) !types.ResearchResponse {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    ) catch return types.ResearchError.ParseError;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return types.ResearchError.InvalidResponse;

    // Check for error
    if (root.object.get("error")) |_| {
        return types.ResearchError.InvalidRequest;
    }

    // Extract candidates[0]
    const candidates = root.object.get("candidates") orelse
        return types.ResearchError.InvalidResponse;
    if (candidates != .array or candidates.array.items.len == 0)
        return types.ResearchError.InvalidResponse;

    const first_candidate = candidates.array.items[0];
    if (first_candidate != .object) return types.ResearchError.InvalidResponse;

    // Extract content.parts — concatenate all text parts
    const content = first_candidate.object.get("content") orelse
        return types.ResearchError.InvalidResponse;
    if (content != .object) return types.ResearchError.InvalidResponse;

    const parts = content.object.get("parts") orelse
        return types.ResearchError.InvalidResponse;
    if (parts != .array or parts.array.items.len == 0)
        return types.ResearchError.InvalidResponse;

    var text_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer text_buf.deinit(allocator);

    for (parts.array.items) |part| {
        if (part == .object) {
            if (part.object.get("text")) |t| {
                if (t == .string) {
                    try text_buf.appendSlice(allocator, t.string);
                }
            }
        }
    }

    if (text_buf.items.len == 0) return types.ResearchError.InvalidResponse;

    // Extract grounding sources from groundingMetadata.groundingChunks
    const sources = try extractSources(allocator, first_candidate);
    errdefer {
        for (sources) |*src| src.deinit();
        allocator.free(sources);
    }

    // Extract usage stats
    var input_tokens: u32 = 0;
    var output_tokens: u32 = 0;
    if (root.object.get("usageMetadata")) |usage_obj| {
        if (usage_obj == .object) {
            if (usage_obj.object.get("promptTokenCount")) |pt| {
                if (pt == .integer) input_tokens = @intCast(pt.integer);
            }
            if (usage_obj.object.get("candidatesTokenCount")) |ct| {
                if (ct == .integer) output_tokens = @intCast(ct.integer);
            }
        }
    }

    const content_copy = try allocator.dupe(u8, text_buf.items);

    return types.ResearchResponse{
        .content = content_copy,
        .sources = sources,
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
        .allocator = allocator,
    };
}

fn extractSources(allocator: std.mem.Allocator, candidate: std.json.Value) ![]types.Source {
    if (candidate != .object) return try allocator.alloc(types.Source, 0);

    const grounding = candidate.object.get("groundingMetadata") orelse
        return try allocator.alloc(types.Source, 0);
    if (grounding != .object) return try allocator.alloc(types.Source, 0);

    const chunks = grounding.object.get("groundingChunks") orelse
        return try allocator.alloc(types.Source, 0);
    if (chunks != .array) return try allocator.alloc(types.Source, 0);

    var source_list: std.ArrayListUnmanaged(types.Source) = .empty;
    errdefer {
        for (source_list.items) |*src| src.deinit();
        source_list.deinit(allocator);
    }

    for (chunks.array.items) |chunk| {
        if (chunk != .object) continue;
        const web = chunk.object.get("web") orelse continue;
        if (web != .object) continue;

        const title_val = web.object.get("title");
        const uri_val = web.object.get("uri");

        const title = if (title_val) |t| (if (t == .string) t.string else "") else "";
        const uri = if (uri_val) |u| (if (u == .string) u.string else "") else "";

        if (uri.len == 0) continue;

        try source_list.append(allocator, .{
            .title = try allocator.dupe(u8, title),
            .uri = try allocator.dupe(u8, uri),
            .allocator = allocator,
        });
    }

    return source_list.toOwnedSlice(allocator);
}

fn handleErrorResponse(status: std.http.Status) types.ResearchError {
    return switch (status) {
        .unauthorized, .forbidden => types.ResearchError.InvalidApiKey,
        .too_many_requests => types.ResearchError.RateLimitExceeded,
        .bad_request => types.ResearchError.InvalidRequest,
        else => types.ResearchError.ServerError,
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
