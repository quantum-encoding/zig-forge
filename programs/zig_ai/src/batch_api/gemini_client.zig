// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Gemini Batch API client
//! https://ai.google.dev/api/generate-content#method:-models.batchgeneratecontent
//!
//! Endpoints:
//!   POST   /v1beta/models/{model}:batchGenerateContent — Create batch
//!   GET    /v1beta/{batch_name}                        — Get status
//!   POST   /v1beta/{batch_name}:cancel                 — Cancel batch
//!   GET    /v1beta/batches                             — List batches

const std = @import("std");
const http_sentinel = @import("http-sentinel");
const types = @import("types.zig");
const client = @import("client.zig");

const GEMINI_API = "https://generativelanguage.googleapis.com/v1beta";
pub const DEFAULT_MODEL = "gemini-2.5-flash";

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Create a new Gemini batch. Returns BatchInfo with the batch name.
pub fn create(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    rows: []const types.BatchInputRow,
    config: types.BatchCreateConfig,
) !types.BatchInfo {
    const payload = try buildBatchPayload(allocator, rows, config, model);
    defer allocator.free(payload);

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/models/{s}:batchGenerateContent", .{ GEMINI_API, model });
    defer allocator.free(endpoint);

    var http_client = try http_sentinel.HttpClient.init(allocator);
    defer http_client.deinit();

    const headers = makeHeaders(api_key);
    var response = try http_client.post(endpoint, &headers, payload);
    defer response.deinit();

    if (response.status != .ok) {
        return client.handleErrorStatus(response.status);
    }

    return parseGeminiBatchInfo(allocator, response.body);
}

/// Create a Gemini batch from a pre-built JSON payload (for FFI use).
/// The payload should already be in Gemini format. The model is extracted
/// from the payload or defaults to gemini-2.5-flash.
pub fn createFromPayload(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    payload: []const u8,
    model: []const u8,
) !types.BatchInfo {
    const effective_model = if (model.len > 0) model else DEFAULT_MODEL;
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/models/{s}:batchGenerateContent", .{ GEMINI_API, effective_model });
    defer allocator.free(endpoint);

    var http_client = try http_sentinel.HttpClient.init(allocator);
    defer http_client.deinit();

    const headers = makeHeaders(api_key);
    var response = try http_client.post(endpoint, &headers, payload);
    defer response.deinit();

    if (response.status != .ok) {
        return client.handleErrorStatus(response.status);
    }

    return parseGeminiBatchInfo(allocator, response.body);
}

/// Get the current status of a Gemini batch.
pub fn getStatus(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    batch_name: []const u8,
) !types.BatchInfo {
    var http_client = try http_sentinel.HttpClient.init(allocator);
    defer http_client.deinit();

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ GEMINI_API, batch_name });
    defer allocator.free(endpoint);

    const headers = makeHeaders(api_key);
    var response = try http_client.get(endpoint, &headers);
    defer response.deinit();

    if (response.status != .ok) {
        return client.handleErrorStatus(response.status);
    }

    return parseGeminiBatchInfo(allocator, response.body);
}

/// Download batch results. Parses inline responses from status response.
pub fn getResults(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    batch_name: []const u8,
) ![]types.BatchResultItem {
    var info = try getStatus(allocator, api_key, batch_name);
    defer info.deinit();

    if (info.processing_status != .ended) {
        return types.BatchApiError.ResultsNotReady;
    }

    // Re-fetch full response to get inlinedResponses
    var http_client = try http_sentinel.HttpClient.init(allocator);
    defer http_client.deinit();

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ GEMINI_API, batch_name });
    defer allocator.free(endpoint);

    const headers = makeHeaders(api_key);
    var response = try http_client.get(endpoint, &headers);
    defer response.deinit();

    if (response.status != .ok) {
        return client.handleErrorStatus(response.status);
    }

    return parseGeminiResults(allocator, response.body);
}

/// Cancel an in-progress Gemini batch.
pub fn cancel(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    batch_name: []const u8,
) !types.BatchInfo {
    var http_client = try http_sentinel.HttpClient.init(allocator);
    defer http_client.deinit();

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/{s}:cancel", .{ GEMINI_API, batch_name });
    defer allocator.free(endpoint);

    const headers = makeHeaders(api_key);
    var response = try http_client.post(endpoint, &headers, "");
    defer response.deinit();

    if (response.status != .ok) {
        return client.handleErrorStatus(response.status);
    }

    return parseGeminiBatchInfo(allocator, response.body);
}

/// List recent Gemini batches.
pub fn listBatches(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    limit: u32,
) ![]types.BatchInfo {
    var http_client = try http_sentinel.HttpClient.init(allocator);
    defer http_client.deinit();

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/batches?pageSize={}", .{ GEMINI_API, limit });
    defer allocator.free(endpoint);

    const headers = makeHeaders(api_key);
    var response = try http_client.get(endpoint, &headers);
    defer response.deinit();

    if (response.status != .ok) {
        return client.handleErrorStatus(response.status);
    }

    return parseGeminiBatchList(allocator, response.body);
}

// ---------------------------------------------------------------------------
// Payload builder
// ---------------------------------------------------------------------------

/// Build the JSON payload for Gemini batch creation from parsed input rows.
pub fn buildBatchPayload(
    allocator: std.mem.Allocator,
    rows: []const types.BatchInputRow,
    config: types.BatchCreateConfig,
    model: []const u8,
) ![]u8 {
    _ = model; // model is in the endpoint URL, not the payload

    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);

    try payload.appendSlice(allocator, "{\"batch\":{\"displayName\":\"zig-ai-batch\",\"inputConfig\":{\"requests\":{\"requests\":[");

    for (rows, 0..) |row, idx| {
        if (idx > 0) try payload.append(allocator, ',');

        // custom_id for metadata.key
        const custom_id = row.custom_id orelse blk: {
            const generated = try std.fmt.allocPrint(allocator, "req-{}", .{idx + 1});
            break :blk generated;
        };
        const free_custom_id = row.custom_id == null;
        defer if (free_custom_id) allocator.free(custom_id);

        // Escape strings
        var escaped_prompt: std.ArrayListUnmanaged(u8) = .empty;
        defer escaped_prompt.deinit(allocator);
        try client.escapeJsonString(allocator, &escaped_prompt, row.prompt);

        var escaped_id: std.ArrayListUnmanaged(u8) = .empty;
        defer escaped_id.deinit(allocator);
        try client.escapeJsonString(allocator, &escaped_id, custom_id);

        // Build request object: {"request": {"contents": [...]}, "metadata": {"key": "..."}}
        try payload.appendSlice(allocator, "{\"request\":{\"contents\":[{\"parts\":[{\"text\":\"");
        try payload.appendSlice(allocator, escaped_prompt.items);
        try payload.appendSlice(allocator, "\"}]}]");

        // System instruction (optional, Gemini format)
        const sys = row.system_prompt orelse config.system_prompt;
        if (sys) |sp| {
            var escaped_sys: std.ArrayListUnmanaged(u8) = .empty;
            defer escaped_sys.deinit(allocator);
            try client.escapeJsonString(allocator, &escaped_sys, sp);
            try payload.appendSlice(allocator, ",\"systemInstruction\":{\"parts\":[{\"text\":\"");
            try payload.appendSlice(allocator, escaped_sys.items);
            try payload.appendSlice(allocator, "\"}]}");
        }

        // Generation config (optional)
        const max_tokens = row.max_tokens orelse config.max_tokens;
        const temp = row.temperature orelse config.temperature;
        if (max_tokens != 64000 or temp != null) {
            try payload.appendSlice(allocator, ",\"generationConfig\":{");
            var has_field = false;

            if (max_tokens != 64000) {
                var tok_buf: [16]u8 = undefined;
                const tok_str = std.fmt.bufPrint(&tok_buf, "\"maxOutputTokens\":{}", .{max_tokens}) catch unreachable;
                try payload.appendSlice(allocator, tok_str);
                has_field = true;
            }

            if (temp) |t| {
                if (has_field) try payload.append(allocator, ',');
                try payload.appendSlice(allocator, "\"temperature\":");
                var temp_buf: [32]u8 = undefined;
                const temp_str = std.fmt.bufPrint(&temp_buf, "{d:.2}", .{t}) catch unreachable;
                try payload.appendSlice(allocator, temp_str);
            }

            try payload.append(allocator, '}');
        }

        try payload.appendSlice(allocator, "},\"metadata\":{\"key\":\"");
        try payload.appendSlice(allocator, escaped_id.items);
        try payload.appendSlice(allocator, "\"}}");
    }

    try payload.appendSlice(allocator, "]}}}}");
    return try allocator.dupe(u8, payload.items);
}

// ---------------------------------------------------------------------------
// Response parsers
// ---------------------------------------------------------------------------

fn parseGeminiBatchInfo(allocator: std.mem.Allocator, body: []const u8) !types.BatchInfo {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    ) catch return types.BatchApiError.ParseError;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return types.BatchApiError.ParseError;

    // Check for error response
    if (root.object.get("error")) |err_obj| {
        if (err_obj == .object) {
            if (err_obj.object.get("code")) |code| {
                if (code == .integer) {
                    if (code.integer == 401 or code.integer == 403) return types.BatchApiError.InvalidApiKey;
                    if (code.integer == 404) return types.BatchApiError.BatchNotFound;
                    if (code.integer == 429) return types.BatchApiError.RateLimitExceeded;
                    if (code.integer == 400) return types.BatchApiError.InvalidRequest;
                }
            }
        }
        return types.BatchApiError.ServerError;
    }

    // Batch name (e.g., "batches/123456")
    const name = try client.getJsonString(root, "name") orelse return types.BatchApiError.ParseError;

    // State from metadata.state or top-level state
    var raw_state: []const u8 = "JOB_STATE_PENDING";
    var processing_status: types.BatchStatus = .in_progress;
    var counts = types.RequestCounts{};

    if (root.object.get("metadata")) |meta| {
        if (meta == .object) {
            if (try client.getJsonString(meta, "state")) |state| {
                raw_state = state;
                processing_status = mapGeminiState(state);
                // Count total requests if available
                counts.processing = client.getJsonU32(meta, "totalRequestCount");
            }
        }
    }

    // Also check top-level state field
    if (try client.getJsonString(root, "state")) |state| {
        raw_state = state;
        processing_status = mapGeminiState(state);
    }

    // Check "done" field
    if (root.object.get("done")) |done_val| {
        if (done_val == .bool and done_val.bool) {
            processing_status = .ended;
        }
    }

    // Map terminal states to appropriate counts
    if (processing_status == .ended) {
        if (std.mem.eql(u8, raw_state, "JOB_STATE_SUCCEEDED")) {
            counts.succeeded = if (counts.processing > 0) counts.processing else 1;
            counts.processing = 0;
        } else if (std.mem.eql(u8, raw_state, "JOB_STATE_FAILED")) {
            counts.errored = if (counts.processing > 0) counts.processing else 1;
            counts.processing = 0;
        } else if (std.mem.eql(u8, raw_state, "JOB_STATE_CANCELLED")) {
            counts.canceled = if (counts.processing > 0) counts.processing else 1;
            counts.processing = 0;
        } else if (std.mem.eql(u8, raw_state, "JOB_STATE_EXPIRED")) {
            counts.expired = if (counts.processing > 0) counts.processing else 1;
            counts.processing = 0;
        }
    }

    // Timestamps
    const created_at = try client.getJsonString(root, "createTime") orelse "unknown";
    const expires_at = try client.getJsonString(root, "expireTime") orelse "unknown";
    const ended_at = try client.getJsonString(root, "updateTime");

    return types.BatchInfo{
        .id = try allocator.dupe(u8, name),
        .processing_status = processing_status,
        .request_counts = counts,
        .created_at = try allocator.dupe(u8, created_at),
        .ended_at = if (ended_at) |ea| try allocator.dupe(u8, ea) else null,
        .expires_at = try allocator.dupe(u8, expires_at),
        .results_url = null,
        .provider = .gemini,
        .raw_status = try allocator.dupe(u8, raw_state),
        .allocator = allocator,
    };
}

fn parseGeminiResults(allocator: std.mem.Allocator, body: []const u8) ![]types.BatchResultItem {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    ) catch return types.BatchApiError.ParseError;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return types.BatchApiError.ParseError;

    var results: std.ArrayListUnmanaged(types.BatchResultItem) = .empty;
    errdefer {
        for (results.items) |*r| r.deinit();
        results.deinit(allocator);
    }

    // Check response.inlinedResponses
    const response_obj = root.object.get("response") orelse {
        // No response field yet — might be in a different format. Try direct inlinedResponses.
        if (root.object.get("inlinedResponses")) |inline_arr| {
            return parseInlinedResponses(allocator, &results, inline_arr);
        }
        return types.BatchApiError.ResultsNotReady;
    };

    if (response_obj == .object) {
        if (response_obj.object.get("inlinedResponses")) |inline_arr| {
            return parseInlinedResponses(allocator, &results, inline_arr);
        }
    }

    // If no inline responses, check for responses array at top level
    if (root.object.get("responses")) |resp_arr| {
        return parseInlinedResponses(allocator, &results, resp_arr);
    }

    return results.toOwnedSlice(allocator);
}

fn parseInlinedResponses(
    allocator: std.mem.Allocator,
    results: *std.ArrayListUnmanaged(types.BatchResultItem),
    inline_arr: std.json.Value,
) ![]types.BatchResultItem {
    if (inline_arr != .array) return types.BatchApiError.ParseError;

    for (inline_arr.array.items) |entry| {
        if (entry != .object) continue;

        var item = types.BatchResultItem{
            .custom_id = try allocator.dupe(u8, "unknown"),
            .result_type = .errored,
            .allocator = allocator,
        };
        errdefer item.deinit();

        // metadata.key → custom_id
        if (entry.object.get("metadata")) |meta| {
            if (meta == .object) {
                if (try client.getJsonString(meta, "key")) |key| {
                    allocator.free(item.custom_id);
                    item.custom_id = try allocator.dupe(u8, key);
                }
            }
        }

        // response.candidates[0].content.parts[0].text → content
        if (entry.object.get("response")) |resp| {
            if (resp == .object) {
                item.result_type = .succeeded;

                if (resp.object.get("candidates")) |candidates| {
                    if (candidates == .array and candidates.array.items.len > 0) {
                        const candidate = candidates.array.items[0];
                        if (candidate == .object) {
                            if (candidate.object.get("content")) |content| {
                                if (content == .object) {
                                    if (content.object.get("parts")) |parts| {
                                        if (parts == .array) {
                                            var text_buf: std.ArrayListUnmanaged(u8) = .empty;
                                            defer text_buf.deinit(allocator);
                                            for (parts.array.items) |part| {
                                                if (part == .object) {
                                                    if (try client.getJsonString(part, "text")) |text| {
                                                        if (text_buf.items.len > 0) {
                                                            try text_buf.append(allocator, '\n');
                                                        }
                                                        try text_buf.appendSlice(allocator, text);
                                                    }
                                                }
                                            }
                                            if (text_buf.items.len > 0) {
                                                item.content = try allocator.dupe(u8, text_buf.items);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // usageMetadata → token counts
                if (resp.object.get("usageMetadata")) |usage| {
                    if (usage == .object) {
                        item.input_tokens = client.getJsonU32(usage, "promptTokenCount");
                        item.output_tokens = client.getJsonU32(usage, "candidatesTokenCount");
                    }
                }

                // modelVersion → model
                if (try client.getJsonString(resp, "modelVersion")) |mv| {
                    item.model = try allocator.dupe(u8, mv);
                }
            }
        }

        // Check for error in the entry
        if (entry.object.get("error")) |err_obj| {
            if (err_obj == .object) {
                item.result_type = .errored;
                if (try client.getJsonString(err_obj, "message")) |em| {
                    item.error_message = try allocator.dupe(u8, em);
                }
                if (err_obj.object.get("code")) |code| {
                    if (code == .integer) {
                        var code_buf: [16]u8 = undefined;
                        const code_str = std.fmt.bufPrint(&code_buf, "{}", .{code.integer}) catch "error";
                        item.error_type = try allocator.dupe(u8, code_str);
                    }
                }
            }
        }

        try results.append(allocator, item);
    }

    return results.toOwnedSlice(allocator);
}

fn parseGeminiBatchList(allocator: std.mem.Allocator, body: []const u8) ![]types.BatchInfo {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    ) catch return types.BatchApiError.ParseError;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return types.BatchApiError.ParseError;

    const batches_arr = root.object.get("batches") orelse {
        // Empty list
        var empty: std.ArrayListUnmanaged(types.BatchInfo) = .empty;
        return empty.toOwnedSlice(allocator);
    };
    if (batches_arr != .array) return types.BatchApiError.ParseError;

    var infos: std.ArrayListUnmanaged(types.BatchInfo) = .empty;
    errdefer {
        for (infos.items) |*info| info.deinit();
        infos.deinit(allocator);
    }

    for (batches_arr.array.items) |item| {
        if (item != .object) continue;

        const name = try client.getJsonString(item, "name") orelse continue;

        var raw_state: []const u8 = "JOB_STATE_PENDING";
        var processing_status: types.BatchStatus = .in_progress;

        if (try client.getJsonString(item, "state")) |state| {
            raw_state = state;
            processing_status = mapGeminiState(state);
        }

        if (item.object.get("done")) |done_val| {
            if (done_val == .bool and done_val.bool) {
                processing_status = .ended;
            }
        }

        const created_at = try client.getJsonString(item, "createTime") orelse "unknown";
        const expires_at = try client.getJsonString(item, "expireTime") orelse "unknown";

        try infos.append(allocator, .{
            .id = try allocator.dupe(u8, name),
            .processing_status = processing_status,
            .request_counts = .{},
            .created_at = try allocator.dupe(u8, created_at),
            .ended_at = if (try client.getJsonString(item, "updateTime")) |ea| try allocator.dupe(u8, ea) else null,
            .expires_at = try allocator.dupe(u8, expires_at),
            .results_url = null,
            .provider = .gemini,
            .raw_status = try allocator.dupe(u8, raw_state),
            .allocator = allocator,
        });
    }

    return infos.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn makeHeaders(api_key: []const u8) [2]std.http.Header {
    return .{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "x-goog-api-key", .value = api_key },
    };
}

/// Map Gemini job states to unified BatchStatus.
fn mapGeminiState(state: []const u8) types.BatchStatus {
    if (std.mem.eql(u8, state, "JOB_STATE_PENDING")) return .in_progress;
    if (std.mem.eql(u8, state, "JOB_STATE_RUNNING")) return .in_progress;
    if (std.mem.eql(u8, state, "JOB_STATE_SUCCEEDED")) return .ended;
    if (std.mem.eql(u8, state, "JOB_STATE_FAILED")) return .ended;
    if (std.mem.eql(u8, state, "JOB_STATE_CANCELLED")) return .ended;
    if (std.mem.eql(u8, state, "JOB_STATE_CANCELLING")) return .canceling;
    if (std.mem.eql(u8, state, "JOB_STATE_EXPIRED")) return .ended;
    return .in_progress;
}
