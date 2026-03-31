// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Anthropic Message Batches API client
//! https://docs.anthropic.com/en/api/creating-message-batches
//!
//! Endpoints:
//!   POST   /v1/messages/batches            — Create batch
//!   GET    /v1/messages/batches/{id}       — Get status
//!   GET    /v1/messages/batches/{id}/results — Stream results (JSONL)
//!   POST   /v1/messages/batches/{id}/cancel  — Cancel batch
//!   GET    /v1/messages/batches            — List batches

const std = @import("std");
const http_sentinel = @import("http-sentinel");
const types = @import("types.zig");

const BATCHES_API = "https://api.anthropic.com/v1/messages/batches";
const ANTHROPIC_VERSION = "2023-06-01";

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Create a new message batch. Returns BatchInfo with the batch ID.
pub fn create(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    payload: []const u8,
) !types.BatchInfo {
    var client = try http_sentinel.HttpClient.init(allocator);
    defer client.deinit();

    const headers = makeHeaders(api_key);
    var response = try client.post(BATCHES_API, &headers, payload);
    defer response.deinit();

    if (response.status != .ok) {
        return handleErrorStatus(response.status);
    }

    return parseBatchInfo(allocator, response.body);
}

/// Get the current status of a batch.
pub fn getStatus(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    batch_id: []const u8,
) !types.BatchInfo {
    var client = try http_sentinel.HttpClient.init(allocator);
    defer client.deinit();

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ BATCHES_API, batch_id });
    defer allocator.free(endpoint);

    const headers = makeHeaders(api_key);
    var response = try client.get(endpoint, &headers);
    defer response.deinit();

    if (response.status != .ok) {
        return handleErrorStatus(response.status);
    }

    return parseBatchInfo(allocator, response.body);
}

/// Download batch results. The batch must have status "ended".
/// Results are returned as JSONL — one JSON object per line.
pub fn getResults(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    batch_id: []const u8,
) ![]types.BatchResultItem {
    // First get the batch info to find the results_url
    var info = try getStatus(allocator, api_key, batch_id);
    defer info.deinit();

    if (info.processing_status != .ended) {
        return types.BatchApiError.ResultsNotReady;
    }

    const results_url = info.results_url orelse return types.BatchApiError.ResultsNotReady;

    // Fetch the results JSONL
    var client = try http_sentinel.HttpClient.init(allocator);
    defer client.deinit();

    const headers = makeHeaders(api_key);
    var response = try client.get(results_url, &headers);
    defer response.deinit();

    if (response.status != .ok) {
        return handleErrorStatus(response.status);
    }

    return parseBatchResults(allocator, response.body);
}

/// Cancel an in-progress batch.
pub fn cancel(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    batch_id: []const u8,
) !types.BatchInfo {
    var client = try http_sentinel.HttpClient.init(allocator);
    defer client.deinit();

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/{s}/cancel", .{ BATCHES_API, batch_id });
    defer allocator.free(endpoint);

    const headers = makeHeaders(api_key);
    var response = try client.post(endpoint, &headers, "");
    defer response.deinit();

    if (response.status != .ok) {
        return handleErrorStatus(response.status);
    }

    return parseBatchInfo(allocator, response.body);
}

/// List recent batches.
pub fn listBatches(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    limit: u32,
) ![]types.BatchInfo {
    var client = try http_sentinel.HttpClient.init(allocator);
    defer client.deinit();

    const endpoint = try std.fmt.allocPrint(allocator, "{s}?limit={}", .{ BATCHES_API, limit });
    defer allocator.free(endpoint);

    const headers = makeHeaders(api_key);
    var response = try client.get(endpoint, &headers);
    defer response.deinit();

    if (response.status != .ok) {
        return handleErrorStatus(response.status);
    }

    return parseBatchList(allocator, response.body);
}

// ---------------------------------------------------------------------------
// Payload builder
// ---------------------------------------------------------------------------

/// Build the JSON payload for batch creation from parsed input rows.
pub fn buildBatchPayload(
    allocator: std.mem.Allocator,
    rows: []const types.BatchInputRow,
    config: types.BatchCreateConfig,
) ![]u8 {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);

    try payload.appendSlice(allocator, "{\"requests\":[");

    for (rows, 0..) |row, idx| {
        if (idx > 0) try payload.append(allocator, ',');

        // custom_id
        const custom_id = row.custom_id orelse blk: {
            const generated = try std.fmt.allocPrint(allocator, "req-{}", .{idx + 1});
            break :blk generated;
        };
        const free_custom_id = row.custom_id == null;
        defer if (free_custom_id) allocator.free(custom_id);

        // Model: per-row override > shared config
        const model = row.model orelse config.model;
        const max_tokens = row.max_tokens orelse config.max_tokens;

        // Escape strings for JSON
        var escaped_prompt: std.ArrayListUnmanaged(u8) = .empty;
        defer escaped_prompt.deinit(allocator);
        try escapeJsonString(allocator, &escaped_prompt, row.prompt);

        var escaped_custom_id: std.ArrayListUnmanaged(u8) = .empty;
        defer escaped_custom_id.deinit(allocator);
        try escapeJsonString(allocator, &escaped_custom_id, custom_id);

        var escaped_model: std.ArrayListUnmanaged(u8) = .empty;
        defer escaped_model.deinit(allocator);
        try escapeJsonString(allocator, &escaped_model, model);

        // Build the request object
        try payload.appendSlice(allocator, "{\"custom_id\":\"");
        try payload.appendSlice(allocator, escaped_custom_id.items);
        try payload.appendSlice(allocator, "\",\"params\":{\"model\":\"");
        try payload.appendSlice(allocator, escaped_model.items);
        try payload.appendSlice(allocator, "\",\"max_tokens\":");

        var tok_buf: [16]u8 = undefined;
        const tok_str = std.fmt.bufPrint(&tok_buf, "{}", .{max_tokens}) catch unreachable;
        try payload.appendSlice(allocator, tok_str);

        // Temperature (optional)
        const temp = row.temperature orelse config.temperature;
        if (temp) |t| {
            try payload.appendSlice(allocator, ",\"temperature\":");
            var temp_buf: [32]u8 = undefined;
            const temp_str = std.fmt.bufPrint(&temp_buf, "{d:.2}", .{t}) catch unreachable;
            try payload.appendSlice(allocator, temp_str);
        }

        // System prompt (optional)
        const sys = row.system_prompt orelse config.system_prompt;
        if (sys) |sp| {
            var escaped_sys: std.ArrayListUnmanaged(u8) = .empty;
            defer escaped_sys.deinit(allocator);
            try escapeJsonString(allocator, &escaped_sys, sp);
            try payload.appendSlice(allocator, ",\"system\":\"");
            try payload.appendSlice(allocator, escaped_sys.items);
            try payload.append(allocator, '"');
        }

        // Messages array
        try payload.appendSlice(allocator, ",\"messages\":[{\"role\":\"user\",\"content\":\"");
        try payload.appendSlice(allocator, escaped_prompt.items);
        try payload.appendSlice(allocator, "\"}]}}");
    }

    try payload.appendSlice(allocator, "]}");
    return try allocator.dupe(u8, payload.items);
}

// ---------------------------------------------------------------------------
// Response parsers
// ---------------------------------------------------------------------------

fn parseBatchInfo(allocator: std.mem.Allocator, body: []const u8) !types.BatchInfo {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    ) catch return types.BatchApiError.ParseError;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return types.BatchApiError.ParseError;

    // Check for API error response
    if (root.object.get("error")) |err_obj| {
        if (err_obj == .object) {
            if (err_obj.object.get("type")) |t| {
                if (t == .string) {
                    if (std.mem.eql(u8, t.string, "not_found_error")) return types.BatchApiError.BatchNotFound;
                    if (std.mem.eql(u8, t.string, "authentication_error")) return types.BatchApiError.InvalidApiKey;
                    if (std.mem.eql(u8, t.string, "rate_limit_error")) return types.BatchApiError.RateLimitExceeded;
                    if (std.mem.eql(u8, t.string, "invalid_request_error")) return types.BatchApiError.InvalidRequest;
                }
            }
        }
        return types.BatchApiError.ServerError;
    }

    const id = try getJsonString(root, "id") orelse return types.BatchApiError.ParseError;
    const status_str = try getJsonString(root, "processing_status") orelse return types.BatchApiError.ParseError;
    const created_at = try getJsonString(root, "created_at") orelse return types.BatchApiError.ParseError;
    const expires_at = try getJsonString(root, "expires_at") orelse return types.BatchApiError.ParseError;

    const processing_status = types.BatchStatus.fromString(status_str) orelse return types.BatchApiError.ParseError;

    var counts = types.RequestCounts{};
    if (root.object.get("request_counts")) |rc| {
        if (rc == .object) {
            counts.processing = getJsonU32(rc, "processing");
            counts.succeeded = getJsonU32(rc, "succeeded");
            counts.errored = getJsonU32(rc, "errored");
            counts.canceled = getJsonU32(rc, "canceled");
            counts.expired = getJsonU32(rc, "expired");
        }
    }

    return types.BatchInfo{
        .id = try allocator.dupe(u8, id),
        .processing_status = processing_status,
        .request_counts = counts,
        .created_at = try allocator.dupe(u8, created_at),
        .ended_at = if (try getJsonString(root, "ended_at")) |ea| try allocator.dupe(u8, ea) else null,
        .expires_at = try allocator.dupe(u8, expires_at),
        .results_url = if (try getJsonString(root, "results_url")) |ru| try allocator.dupe(u8, ru) else null,
        .allocator = allocator,
    };
}

fn parseBatchResults(allocator: std.mem.Allocator, body: []const u8) ![]types.BatchResultItem {
    var results: std.ArrayListUnmanaged(types.BatchResultItem) = .empty;
    errdefer {
        for (results.items) |*r| r.deinit();
        results.deinit(allocator);
    }

    var line_iter = std.mem.splitScalar(u8, body, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        const item = parseResultLine(allocator, trimmed) catch |err| {
            std.debug.print("Warning: Failed to parse result line: {}\n", .{err});
            continue;
        };
        try results.append(allocator, item);
    }

    return results.toOwnedSlice(allocator);
}

fn parseResultLine(allocator: std.mem.Allocator, line: []const u8) !types.BatchResultItem {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        line,
        .{ .allocate = .alloc_always },
    ) catch return types.BatchApiError.ParseError;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return types.BatchApiError.ParseError;

    const custom_id = try getJsonString(root, "custom_id") orelse return types.BatchApiError.ParseError;

    var item = types.BatchResultItem{
        .custom_id = try allocator.dupe(u8, custom_id),
        .result_type = .errored,
        .allocator = allocator,
    };
    errdefer item.deinit();

    const result_obj = root.object.get("result") orelse return types.BatchApiError.ParseError;
    if (result_obj != .object) return types.BatchApiError.ParseError;

    // Result type
    if (try getJsonString(result_obj, "type")) |type_str| {
        item.result_type = types.ResultType.fromString(type_str) orelse .errored;
    }

    switch (item.result_type) {
        .succeeded => {
            // Extract message content
            if (result_obj.object.get("message")) |msg| {
                if (msg == .object) {
                    // model
                    if (try getJsonString(msg, "model")) |m| {
                        item.model = try allocator.dupe(u8, m);
                    }
                    // stop_reason
                    if (try getJsonString(msg, "stop_reason")) |sr| {
                        item.stop_reason = try allocator.dupe(u8, sr);
                    }
                    // usage
                    if (msg.object.get("usage")) |usage| {
                        if (usage == .object) {
                            item.input_tokens = getJsonU32(usage, "input_tokens");
                            item.output_tokens = getJsonU32(usage, "output_tokens");
                        }
                    }
                    // content — array of content blocks
                    if (msg.object.get("content")) |content_arr| {
                        if (content_arr == .array) {
                            var text_buf: std.ArrayListUnmanaged(u8) = .empty;
                            defer text_buf.deinit(allocator);
                            for (content_arr.array.items) |block| {
                                if (block == .object) {
                                    if (try getJsonString(block, "text")) |text| {
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
        },
        .errored => {
            if (result_obj.object.get("error")) |err_obj| {
                if (err_obj == .object) {
                    if (err_obj.object.get("error")) |inner_err| {
                        if (inner_err == .object) {
                            if (try getJsonString(inner_err, "type")) |et| {
                                item.error_type = try allocator.dupe(u8, et);
                            }
                            if (try getJsonString(inner_err, "message")) |em| {
                                item.error_message = try allocator.dupe(u8, em);
                            }
                        }
                    }
                    // Also check top-level error type/message
                    if (item.error_type == null) {
                        if (try getJsonString(err_obj, "type")) |et| {
                            item.error_type = try allocator.dupe(u8, et);
                        }
                    }
                    if (item.error_message == null) {
                        if (try getJsonString(err_obj, "message")) |em| {
                            item.error_message = try allocator.dupe(u8, em);
                        }
                    }
                }
            }
        },
        .canceled, .expired => {},
    }

    return item;
}

fn parseBatchList(allocator: std.mem.Allocator, body: []const u8) ![]types.BatchInfo {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    ) catch return types.BatchApiError.ParseError;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return types.BatchApiError.ParseError;

    const data = root.object.get("data") orelse return types.BatchApiError.ParseError;
    if (data != .array) return types.BatchApiError.ParseError;

    var infos: std.ArrayListUnmanaged(types.BatchInfo) = .empty;
    errdefer {
        for (infos.items) |*info| info.deinit();
        infos.deinit(allocator);
    }

    for (data.array.items) |item| {
        if (item != .object) continue;

        const id = try getJsonString(item, "id") orelse continue;
        const status_str = try getJsonString(item, "processing_status") orelse continue;
        const created_at = try getJsonString(item, "created_at") orelse continue;
        const expires_at = try getJsonString(item, "expires_at") orelse continue;

        const processing_status = types.BatchStatus.fromString(status_str) orelse continue;

        var counts = types.RequestCounts{};
        if (item.object.get("request_counts")) |rc| {
            if (rc == .object) {
                counts.processing = getJsonU32(rc, "processing");
                counts.succeeded = getJsonU32(rc, "succeeded");
                counts.errored = getJsonU32(rc, "errored");
                counts.canceled = getJsonU32(rc, "canceled");
                counts.expired = getJsonU32(rc, "expired");
            }
        }

        try infos.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .processing_status = processing_status,
            .request_counts = counts,
            .created_at = try allocator.dupe(u8, created_at),
            .ended_at = if (try getJsonString(item, "ended_at")) |ea| try allocator.dupe(u8, ea) else null,
            .expires_at = try allocator.dupe(u8, expires_at),
            .results_url = if (try getJsonString(item, "results_url")) |ru| try allocator.dupe(u8, ru) else null,
            .allocator = allocator,
        });
    }

    return infos.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn makeHeaders(api_key: []const u8) [3]std.http.Header {
    return .{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "x-api-key", .value = api_key },
        .{ .name = "anthropic-version", .value = ANTHROPIC_VERSION },
    };
}

pub fn handleErrorStatus(status: std.http.Status) types.BatchApiError {
    return switch (status) {
        .unauthorized, .forbidden => types.BatchApiError.InvalidApiKey,
        .too_many_requests => types.BatchApiError.RateLimitExceeded,
        .bad_request => types.BatchApiError.InvalidRequest,
        .not_found => types.BatchApiError.BatchNotFound,
        .payload_too_large => types.BatchApiError.BatchTooLarge,
        else => types.BatchApiError.ServerError,
    };
}

pub fn getJsonString(obj: std.json.Value, key: []const u8) !?[]const u8 {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    if (val == .string) return val.string;
    if (val == .null) return null;
    return null;
}

pub fn getJsonU32(obj: std.json.Value, key: []const u8) u32 {
    if (obj != .object) return 0;
    const val = obj.object.get(key) orelse return 0;
    if (val == .integer) {
        if (val.integer < 0) return 0;
        return @intCast(@min(val.integer, std.math.maxInt(u32)));
    }
    return 0;
}

pub fn escapeJsonString(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
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
