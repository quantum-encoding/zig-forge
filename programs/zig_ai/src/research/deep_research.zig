// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Deep Research via Gemini Interactions API
//!
//! Starts an autonomous research agent that searches, reads, and synthesizes
//! a comprehensive report. Takes 5-20 minutes. Supports polling for completion.
//!
//! Start: POST https://generativelanguage.googleapis.com/v1beta/interactions
//! Poll:  GET  https://generativelanguage.googleapis.com/v1beta/interactions/{id}

const std = @import("std");
const http_sentinel = @import("http-sentinel");
const types = @import("types.zig");

extern "c" fn usleep(usec: c_uint) c_int;

const INTERACTIONS_API = "https://generativelanguage.googleapis.com/v1beta/interactions";
pub const DEEP_RESEARCH_AGENT = "deep-research-pro-preview-12-2025";

const POLL_INTERVAL_MS: u64 = 10_000; // 10 seconds
const MAX_POLL_ATTEMPTS: u32 = 180; // 30 minutes

pub fn research(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    request: types.ResearchRequest,
) !types.ResearchResponse {
    const agent = request.agent orelse DEEP_RESEARCH_AGENT;

    // Start the research interaction
    const interaction_id = try startResearch(allocator, api_key, request.query, agent);
    defer allocator.free(interaction_id);

    std.debug.print("Deep research started (ID: {s})\n", .{interaction_id});
    std.debug.print("This may take 5-20 minutes...\n\n", .{});

    // Poll for completion
    return pollForCompletion(allocator, api_key, interaction_id);
}

/// Start a deep research interaction. Returns the interaction ID.
pub fn startResearch(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    query: []const u8,
    agent: []const u8,
) ![]u8 {
    var escaped_query: std.ArrayListUnmanaged(u8) = .empty;
    defer escaped_query.deinit(allocator);
    try escapeJsonString(allocator, &escaped_query, query);

    var escaped_agent: std.ArrayListUnmanaged(u8) = .empty;
    defer escaped_agent.deinit(allocator);
    try escapeJsonString(allocator, &escaped_agent, agent);

    const payload = try std.fmt.allocPrint(allocator,
        \\{{"input":"{s}","agent":"{s}","background":true}}
    , .{ escaped_query.items, escaped_agent.items });
    defer allocator.free(payload);

    var client = try http_sentinel.HttpClient.init(allocator);
    defer client.deinit();

    const endpoint = try std.fmt.allocPrint(allocator,
        "{s}?key={s}",
        .{ INTERACTIONS_API, api_key },
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

    // Parse interaction ID from response
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        response.body,
        .{ .allocate = .alloc_always },
    ) catch return types.ResearchError.ParseError;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return types.ResearchError.InvalidResponse;

    // Check for error
    if (root.object.get("error")) |_| {
        return types.ResearchError.InvalidRequest;
    }

    // Extract interaction name/id
    const name = root.object.get("name") orelse
        return types.ResearchError.InvalidResponse;
    if (name != .string) return types.ResearchError.InvalidResponse;

    return try allocator.dupe(u8, name.string);
}

/// Poll a deep research interaction until completion or timeout.
pub fn pollForCompletion(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    interaction_id: []const u8,
) !types.ResearchResponse {
    var attempt: u32 = 0;
    while (attempt < MAX_POLL_ATTEMPTS) : (attempt += 1) {
        // Sleep between polls
        if (attempt > 0) {
            _ = usleep(@intCast(POLL_INTERVAL_MS * 1000)); // ms to us
        }

        const elapsed_s = attempt * @as(u32, @intCast(POLL_INTERVAL_MS / 1000));
        if (elapsed_s > 0) {
            const mins = elapsed_s / 60;
            const secs = elapsed_s % 60;
            if (mins > 0) {
                std.debug.print("\rResearching... [{d}m {d}s]  ", .{ mins, secs });
            } else {
                std.debug.print("\rResearching... [{d}s]  ", .{secs});
            }
        }

        const result = try pollOnce(allocator, api_key, interaction_id);
        switch (result) {
            .completed => |resp| {
                std.debug.print("\rResearch complete!                    \n", .{});
                return resp;
            },
            .processing => continue,
            .failed => return types.ResearchError.ResearchFailed,
        }
    }

    std.debug.print("\n", .{});
    return types.ResearchError.ResearchTimeout;
}

const PollResult = union(enum) {
    completed: types.ResearchResponse,
    processing: void,
    failed: void,
};

/// Poll the interaction once. Returns the result state.
pub fn pollOnce(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    interaction_id: []const u8,
) !PollResult {
    var client = try http_sentinel.HttpClient.init(allocator);
    defer client.deinit();

    // The interaction_id from start may be a full resource name like "interactions/xxx"
    // or just the ID. Build the URL accordingly.
    const endpoint = if (std.mem.startsWith(u8, interaction_id, "interactions/"))
        try std.fmt.allocPrint(allocator,
            "https://generativelanguage.googleapis.com/v1beta/{s}?key={s}",
            .{ interaction_id, api_key },
        )
    else
        try std.fmt.allocPrint(allocator,
            "{s}/{s}?key={s}",
            .{ INTERACTIONS_API, interaction_id, api_key },
        );
    defer allocator.free(endpoint);

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    };

    var response = try client.get(endpoint, &headers);
    defer response.deinit();

    if (response.status != .ok) {
        return handleErrorResponsePoll(response.status);
    }

    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        response.body,
        .{ .allocate = .alloc_always },
    ) catch return types.ResearchError.ParseError;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return types.ResearchError.InvalidResponse;

    // Check status field
    if (root.object.get("status")) |status_val| {
        if (status_val == .string) {
            if (std.mem.eql(u8, status_val.string, "PROCESSING")) {
                return PollResult{ .processing = {} };
            }
            if (std.mem.eql(u8, status_val.string, "FAILED")) {
                return PollResult{ .failed = {} };
            }
        }
    }

    // Check done field (alternative completion indicator)
    if (root.object.get("done")) |done_val| {
        if (done_val == .bool and !done_val.bool) {
            return PollResult{ .processing = {} };
        }
    }

    // If we get here, assume completed — extract the report
    const resp = try extractReport(allocator, root);
    return PollResult{ .completed = resp };
}

fn extractReport(allocator: std.mem.Allocator, root: std.json.Value) !types.ResearchResponse {
    if (root != .object) return types.ResearchError.InvalidResponse;

    var text_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer text_buf.deinit(allocator);

    // Try output.text first (primary location)
    if (root.object.get("output")) |output| {
        if (output == .object) {
            if (output.object.get("text")) |t| {
                if (t == .string and t.string.len > 0) {
                    try text_buf.appendSlice(allocator, t.string);
                }
            }
        }
    }

    // Fallback: response.text
    if (text_buf.items.len == 0) {
        if (root.object.get("response")) |resp| {
            if (resp == .object) {
                if (resp.object.get("text")) |t| {
                    if (t == .string and t.string.len > 0) {
                        try text_buf.appendSlice(allocator, t.string);
                    }
                }
            }
        }
    }

    // Fallback: content.parts concatenation
    if (text_buf.items.len == 0) {
        if (root.object.get("content")) |content_val| {
            if (content_val == .object) {
                if (content_val.object.get("parts")) |parts| {
                    if (parts == .array) {
                        for (parts.array.items) |part| {
                            if (part == .object) {
                                if (part.object.get("text")) |t| {
                                    if (t == .string) {
                                        try text_buf.appendSlice(allocator, t.string);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Fallback: candidates[0].content.parts (generateContent-style)
    if (text_buf.items.len == 0) {
        if (root.object.get("candidates")) |candidates| {
            if (candidates == .array and candidates.array.items.len > 0) {
                const first = candidates.array.items[0];
                if (first == .object) {
                    if (first.object.get("content")) |c| {
                        if (c == .object) {
                            if (c.object.get("parts")) |parts| {
                                if (parts == .array) {
                                    for (parts.array.items) |part| {
                                        if (part == .object) {
                                            if (part.object.get("text")) |t| {
                                                if (t == .string) {
                                                    try text_buf.appendSlice(allocator, t.string);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if (text_buf.items.len == 0) return types.ResearchError.InvalidResponse;

    // Extract sources from various possible locations
    const sources = try extractDeepSources(allocator, root);
    errdefer {
        for (sources) |*src| src.deinit();
        allocator.free(sources);
    }

    const content_copy = try allocator.dupe(u8, text_buf.items);

    return types.ResearchResponse{
        .content = content_copy,
        .sources = sources,
        .input_tokens = 0,
        .output_tokens = 0,
        .allocator = allocator,
    };
}

fn extractDeepSources(allocator: std.mem.Allocator, root: std.json.Value) ![]types.Source {
    if (root != .object) return try allocator.alloc(types.Source, 0);

    // Try: groundingMetadata.groundingChunks
    if (root.object.get("groundingMetadata")) |gm| {
        const result = try extractGroundingChunks(allocator, gm);
        if (result.len > 0) return result;
        allocator.free(result);
    }

    // Try: output.groundingMetadata.groundingChunks
    if (root.object.get("output")) |output| {
        if (output == .object) {
            if (output.object.get("groundingMetadata")) |gm| {
                const result = try extractGroundingChunks(allocator, gm);
                if (result.len > 0) return result;
                allocator.free(result);
            }
        }
    }

    // Try: candidates[0].groundingMetadata
    if (root.object.get("candidates")) |candidates| {
        if (candidates == .array and candidates.array.items.len > 0) {
            const first = candidates.array.items[0];
            if (first == .object) {
                if (first.object.get("groundingMetadata")) |gm| {
                    const result = try extractGroundingChunks(allocator, gm);
                    if (result.len > 0) return result;
                    allocator.free(result);
                }
            }
        }
    }

    return try allocator.alloc(types.Source, 0);
}

fn extractGroundingChunks(allocator: std.mem.Allocator, grounding: std.json.Value) ![]types.Source {
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

fn handleErrorResponsePoll(status: std.http.Status) !PollResult {
    return switch (status) {
        .unauthorized, .forbidden => types.ResearchError.InvalidApiKey,
        .too_many_requests => types.ResearchError.RateLimitExceeded,
        .not_found => types.ResearchError.InvalidResponse,
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
