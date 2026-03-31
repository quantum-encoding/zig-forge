// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! xAI Batch API client (Grok models)
//! https://docs.x.ai/docs/guides/batch
//!
//! Workflow (two-step REST creation):
//!   1. Create batch: POST /v1/batches with {"name":"..."}
//!   2. Add requests: POST /v1/batches/{id}/requests with {"batch_requests":[...]}
//!   3. Poll status:  GET /v1/batches/{id}
//!   4. Get results:  GET /v1/batches/{id}/results (paginated)
//!   5. Cancel:       POST /v1/batches/{id}:cancel (colon syntax!)
//!   6. List:         GET /v1/batches?limit=N

const std = @import("std");
const http_sentinel = @import("http-sentinel");
const types = @import("types.zig");
const client = @import("client.zig");

const XAI_API = "https://api.x.ai/v1";
const BATCHES_API = XAI_API ++ "/batches";
pub const DEFAULT_MODEL = "grok-4-1-fast-non-reasoning";

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Create a new xAI batch from input rows. Internally creates an empty batch
/// by name, then adds all requests. Returns BatchInfo with the batch ID.
pub fn create(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    rows: []const types.BatchInputRow,
    config: types.BatchCreateConfig,
) !types.BatchInfo {
    const effective_model = if (model.len > 0) model else DEFAULT_MODEL;

    // Step 1: Create empty batch with a generated name
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const batch_name = try std.fmt.allocPrint(allocator, "zig-ai-batch-{d}", .{ts.sec});
    defer allocator.free(batch_name);

    const create_body = try std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\"}}", .{batch_name});
    defer allocator.free(create_body);

    var http_client = try http_sentinel.HttpClient.init(allocator);
    defer http_client.deinit();

    var auth = try makeJsonHeaders(allocator, api_key);
    defer auth.deinit(allocator);

    var create_response = try http_client.post(BATCHES_API, &auth.headers, create_body);
    defer create_response.deinit();

    if (create_response.status != .ok and create_response.status != .created) {
        return handleXaiError(create_response.status, create_response.body);
    }

    // Parse batch_id from response
    const parsed_create = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        create_response.body,
        .{ .allocate = .alloc_always },
    ) catch return types.BatchApiError.ParseError;
    defer parsed_create.deinit();

    const batch_id_str = try client.getJsonString(parsed_create.value, "batch_id") orelse
        return types.BatchApiError.ParseError;
    const batch_id = try allocator.dupe(u8, batch_id_str);
    defer allocator.free(batch_id);

    // Step 2: Build and add requests
    const requests_body = try buildBatchRequests(allocator, rows, config, effective_model);
    defer allocator.free(requests_body);

    const requests_url = try std.fmt.allocPrint(allocator, "{s}/{s}/requests", .{ BATCHES_API, batch_id });
    defer allocator.free(requests_url);

    var add_response = try http_client.post(requests_url, &auth.headers, requests_body);
    defer add_response.deinit();

    if (add_response.status != .ok and add_response.status != .created) {
        return handleXaiError(add_response.status, add_response.body);
    }

    // Step 3: Get current status to return
    return getStatus(allocator, api_key, batch_id);
}

/// Create an xAI batch from a pre-built requests payload (for FFI use).
/// payload should be a JSON object with "batch_requests" array.
pub fn createFromPayload(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    payload: []const u8,
    model: []const u8,
) !types.BatchInfo {
    _ = model; // Model is embedded in each request

    // Step 1: Create empty batch
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const batch_name = try std.fmt.allocPrint(allocator, "zig-ai-batch-{d}", .{ts.sec});
    defer allocator.free(batch_name);

    const create_body = try std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\"}}", .{batch_name});
    defer allocator.free(create_body);

    var http_client = try http_sentinel.HttpClient.init(allocator);
    defer http_client.deinit();

    var auth = try makeJsonHeaders(allocator, api_key);
    defer auth.deinit(allocator);

    var create_response = try http_client.post(BATCHES_API, &auth.headers, create_body);
    defer create_response.deinit();

    if (create_response.status != .ok and create_response.status != .created) {
        return handleXaiError(create_response.status, create_response.body);
    }

    const parsed_create = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        create_response.body,
        .{ .allocate = .alloc_always },
    ) catch return types.BatchApiError.ParseError;
    defer parsed_create.deinit();

    const batch_id_str = try client.getJsonString(parsed_create.value, "batch_id") orelse
        return types.BatchApiError.ParseError;
    const batch_id = try allocator.dupe(u8, batch_id_str);
    defer allocator.free(batch_id);

    // Step 2: Add requests (payload is already the batch_requests JSON)
    const requests_url = try std.fmt.allocPrint(allocator, "{s}/{s}/requests", .{ BATCHES_API, batch_id });
    defer allocator.free(requests_url);

    var add_response = try http_client.post(requests_url, &auth.headers, payload);
    defer add_response.deinit();

    if (add_response.status != .ok and add_response.status != .created) {
        return handleXaiError(add_response.status, add_response.body);
    }

    return getStatus(allocator, api_key, batch_id);
}

/// Get the current status of an xAI batch.
pub fn getStatus(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    batch_id: []const u8,
) !types.BatchInfo {
    var http_client = try http_sentinel.HttpClient.init(allocator);
    defer http_client.deinit();

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ BATCHES_API, batch_id });
    defer allocator.free(endpoint);

    var auth = try makeJsonHeaders(allocator, api_key);
    defer auth.deinit(allocator);
    var response = try http_client.get(endpoint, &auth.headers);
    defer response.deinit();

    if (response.status != .ok) {
        return handleXaiError(response.status, response.body);
    }

    return parseXaiBatchInfo(allocator, response.body);
}

/// Download batch results. Paginates through all result pages.
pub fn getResults(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    batch_id: []const u8,
) ![]types.BatchResultItem {
    var http_client = try http_sentinel.HttpClient.init(allocator);
    defer http_client.deinit();

    var auth = try makeJsonHeaders(allocator, api_key);
    defer auth.deinit(allocator);

    var all_results: std.ArrayListUnmanaged(types.BatchResultItem) = .empty;
    errdefer {
        for (all_results.items) |*r| r.deinit();
        all_results.deinit(allocator);
    }

    var pagination_token: ?[]u8 = null;
    defer if (pagination_token) |pt| allocator.free(pt);

    while (true) {
        // Build URL with pagination
        const endpoint = if (pagination_token) |pt|
            try std.fmt.allocPrint(allocator, "{s}/{s}/results?limit=1000&pagination_token={s}", .{ BATCHES_API, batch_id, pt })
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}/results?limit=1000", .{ BATCHES_API, batch_id });
        defer allocator.free(endpoint);

        var response = try http_client.get(endpoint, &auth.headers);
        defer response.deinit();

        if (response.status != .ok) {
            return handleXaiError(response.status, response.body);
        }

        // Parse this page
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            response.body,
            .{ .allocate = .alloc_always },
        ) catch return types.BatchApiError.ParseError;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return types.BatchApiError.ParseError;

        // Parse results array
        if (root.object.get("results")) |results_arr| {
            if (results_arr == .array) {
                for (results_arr.array.items) |item| {
                    if (parseXaiResultItem(allocator, item)) |result_item| {
                        try all_results.append(allocator, result_item);
                    } else |_| continue;
                }
            }
        }

        // Check for next page
        if (pagination_token) |pt| allocator.free(pt);
        pagination_token = null;

        if (root.object.get("pagination_token")) |pt_val| {
            if (pt_val == .string and pt_val.string.len > 0) {
                pagination_token = try allocator.dupe(u8, pt_val.string);
            } else break;
        } else break;
    }

    return all_results.toOwnedSlice(allocator);
}

/// Cancel an in-progress xAI batch.
/// Note: xAI uses colon syntax: POST /v1/batches/{id}:cancel
pub fn cancel(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    batch_id: []const u8,
) !types.BatchInfo {
    var http_client = try http_sentinel.HttpClient.init(allocator);
    defer http_client.deinit();

    // xAI cancel uses colon syntax, not /cancel
    const endpoint = try std.fmt.allocPrint(allocator, "{s}/{s}:cancel", .{ BATCHES_API, batch_id });
    defer allocator.free(endpoint);

    var auth = try makeJsonHeaders(allocator, api_key);
    defer auth.deinit(allocator);
    var response = try http_client.post(endpoint, &auth.headers, "");
    defer response.deinit();

    if (response.status != .ok) {
        return handleXaiError(response.status, response.body);
    }

    return parseXaiBatchInfo(allocator, response.body);
}

/// List recent xAI batches.
pub fn listBatches(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    limit: u32,
) ![]types.BatchInfo {
    var http_client = try http_sentinel.HttpClient.init(allocator);
    defer http_client.deinit();

    const endpoint = try std.fmt.allocPrint(allocator, "{s}?limit={}", .{ BATCHES_API, limit });
    defer allocator.free(endpoint);

    var auth = try makeJsonHeaders(allocator, api_key);
    defer auth.deinit(allocator);
    var response = try http_client.get(endpoint, &auth.headers);
    defer response.deinit();

    if (response.status != .ok) {
        return handleXaiError(response.status, response.body);
    }

    return parseXaiBatchList(allocator, response.body);
}

// ---------------------------------------------------------------------------
// Request builder
// ---------------------------------------------------------------------------

/// Build the batch_requests JSON body from CSV rows.
/// Each request wraps the prompt in xAI's chat_get_completion format.
fn buildBatchRequests(
    allocator: std.mem.Allocator,
    rows: []const types.BatchInputRow,
    config: types.BatchCreateConfig,
    model: []const u8,
) ![]u8 {
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);

    try payload.appendSlice(allocator, "{\"batch_requests\":[");

    for (rows, 0..) |row, idx| {
        if (idx > 0) try payload.append(allocator, ',');

        const effective_model = row.model orelse model;

        // batch_request_id
        const custom_id = row.custom_id orelse blk: {
            break :blk try std.fmt.allocPrint(allocator, "req-{}", .{idx + 1});
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

        // Build request object
        try payload.appendSlice(allocator, "{\"batch_request_id\":\"");
        try payload.appendSlice(allocator, escaped_id.items);
        try payload.appendSlice(allocator, "\",\"batch_request\":{\"chat_get_completion\":{\"model\":\"");
        try payload.appendSlice(allocator, effective_model);
        try payload.appendSlice(allocator, "\",\"messages\":[");

        // System prompt (optional)
        const sys = row.system_prompt orelse config.system_prompt;
        if (sys) |sp| {
            var escaped_sys: std.ArrayListUnmanaged(u8) = .empty;
            defer escaped_sys.deinit(allocator);
            try client.escapeJsonString(allocator, &escaped_sys, sp);
            try payload.appendSlice(allocator, "{\"role\":\"system\",\"content\":\"");
            try payload.appendSlice(allocator, escaped_sys.items);
            try payload.appendSlice(allocator, "\"},");
        }

        try payload.appendSlice(allocator, "{\"role\":\"user\",\"content\":\"");
        try payload.appendSlice(allocator, escaped_prompt.items);
        try payload.appendSlice(allocator, "\"}]");

        // max_tokens (optional in xAI — only add if specified)
        const max_tokens = row.max_tokens orelse config.max_tokens;
        if (max_tokens != 64000) { // Only add if non-default
            var tok_buf: [32]u8 = undefined;
            const tok_str = std.fmt.bufPrint(&tok_buf, ",\"max_tokens\":{}", .{max_tokens}) catch unreachable;
            try payload.appendSlice(allocator, tok_str);
        }

        // temperature (optional)
        const temp = row.temperature orelse config.temperature;
        if (temp) |t| {
            try payload.appendSlice(allocator, ",\"temperature\":");
            var temp_buf: [32]u8 = undefined;
            const temp_str = std.fmt.bufPrint(&temp_buf, "{d:.2}", .{t}) catch unreachable;
            try payload.appendSlice(allocator, temp_str);
        }

        try payload.appendSlice(allocator, "}}}"); // close chat_get_completion, batch_request, item
    }

    try payload.appendSlice(allocator, "]}"); // close batch_requests array and root
    return try allocator.dupe(u8, payload.items);
}

// ---------------------------------------------------------------------------
// Response parsers
// ---------------------------------------------------------------------------

fn parseXaiBatchInfo(allocator: std.mem.Allocator, body: []const u8) !types.BatchInfo {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    ) catch return types.BatchApiError.ParseError;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return types.BatchApiError.ParseError;

    // Batch ID
    const id = try client.getJsonString(root, "batch_id") orelse return types.BatchApiError.ParseError;

    // Timestamps (xAI uses date strings)
    const created_at = try client.getJsonString(root, "create_time") orelse "unknown";
    const expires_at = try client.getJsonString(root, "expire_time") orelse "unknown";
    const cancel_time = try client.getJsonString(root, "cancel_time");
    const has_cancel_time = cancel_time != null;

    // Request counts from state object
    var counts = types.RequestCounts{};
    var num_requests: u32 = 0;
    var num_pending: u32 = 0;
    if (root.object.get("state")) |state| {
        if (state == .object) {
            num_requests = client.getJsonU32(state, "num_requests");
            num_pending = client.getJsonU32(state, "num_pending");
            counts.succeeded = client.getJsonU32(state, "num_success");
            counts.errored = client.getJsonU32(state, "num_error");
            counts.canceled = client.getJsonU32(state, "num_cancelled");
            counts.processing = num_pending;
        }
    }

    // Derive status from counts + cancel_time
    var processing_status: types.BatchStatus = .in_progress;
    var raw_status: []const u8 = "created";

    if (has_cancel_time and num_pending > 0) {
        processing_status = .canceling;
        raw_status = "cancelling";
    } else if (has_cancel_time and num_pending == 0) {
        processing_status = .ended;
        raw_status = "cancelled";
    } else if (num_pending > 0) {
        processing_status = .in_progress;
        raw_status = "in_progress";
    } else if (num_pending == 0 and num_requests > 0) {
        processing_status = .ended;
        raw_status = "completed";
    }

    // Batch name (for display in results_url field)
    const batch_name = try client.getJsonString(root, "name");

    return types.BatchInfo{
        .id = try allocator.dupe(u8, id),
        .processing_status = processing_status,
        .request_counts = counts,
        .created_at = try allocator.dupe(u8, created_at),
        .ended_at = null,
        .expires_at = try allocator.dupe(u8, expires_at),
        .results_url = if (batch_name) |name| try allocator.dupe(u8, name) else null,
        .provider = .xai,
        .raw_status = try allocator.dupe(u8, raw_status),
        .output_file_id = null,
        .allocator = allocator,
    };
}

/// Parse a single result item from the xAI results array.
fn parseXaiResultItem(allocator: std.mem.Allocator, item: std.json.Value) !types.BatchResultItem {
    if (item != .object) return types.BatchApiError.ParseError;

    var result = types.BatchResultItem{
        .custom_id = try allocator.dupe(u8, "unknown"),
        .result_type = .errored,
        .allocator = allocator,
    };
    errdefer result.deinit();

    // batch_request_id → custom_id
    if (try client.getJsonString(item, "batch_request_id")) |rid| {
        allocator.free(result.custom_id);
        result.custom_id = try allocator.dupe(u8, rid);
    }

    // Navigate: batch_result → response → chat_get_completion
    const batch_result = item.object.get("batch_result") orelse return result;
    if (batch_result != .object) return result;

    const response_obj = batch_result.object.get("response") orelse return result;
    if (response_obj != .object) return result;

    const completion = response_obj.object.get("chat_get_completion") orelse return result;
    if (completion != .object) return result;

    // Standard Chat Completions format inside
    result.result_type = .succeeded;

    // choices[0].message.content
    if (completion.object.get("choices")) |choices| {
        if (choices == .array and choices.array.items.len > 0) {
            const choice = choices.array.items[0];
            if (choice == .object) {
                if (choice.object.get("message")) |msg| {
                    if (msg == .object) {
                        if (try client.getJsonString(msg, "content")) |content| {
                            result.content = try allocator.dupe(u8, content);
                        }
                    }
                }
                if (try client.getJsonString(choice, "finish_reason")) |fr| {
                    result.stop_reason = try allocator.dupe(u8, fr);
                }
            }
        }
    }

    // usage
    if (completion.object.get("usage")) |usage| {
        if (usage == .object) {
            result.input_tokens = client.getJsonU32(usage, "prompt_tokens");
            result.output_tokens = client.getJsonU32(usage, "completion_tokens");
        }
    }

    // model
    if (try client.getJsonString(completion, "model")) |m| {
        result.model = try allocator.dupe(u8, m);
    }

    return result;
}

fn parseXaiBatchList(allocator: std.mem.Allocator, body: []const u8) ![]types.BatchInfo {
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

        const id = try client.getJsonString(item, "batch_id") orelse continue;
        const created_at = try client.getJsonString(item, "create_time") orelse "unknown";
        const expires_at = try client.getJsonString(item, "expire_time") orelse "unknown";
        const cancel_time = try client.getJsonString(item, "cancel_time");
        const has_cancel_time = cancel_time != null;
        const batch_name = try client.getJsonString(item, "name");

        var counts = types.RequestCounts{};
        var num_requests: u32 = 0;
        var num_pending: u32 = 0;
        if (item.object.get("state")) |state| {
            if (state == .object) {
                num_requests = client.getJsonU32(state, "num_requests");
                num_pending = client.getJsonU32(state, "num_pending");
                counts.succeeded = client.getJsonU32(state, "num_success");
                counts.errored = client.getJsonU32(state, "num_error");
                counts.canceled = client.getJsonU32(state, "num_cancelled");
                counts.processing = num_pending;
            }
        }

        var processing_status: types.BatchStatus = .in_progress;
        var raw_status: []const u8 = "created";

        if (has_cancel_time and num_pending > 0) {
            processing_status = .canceling;
            raw_status = "cancelling";
        } else if (has_cancel_time and num_pending == 0) {
            processing_status = .ended;
            raw_status = "cancelled";
        } else if (num_pending > 0) {
            processing_status = .in_progress;
            raw_status = "in_progress";
        } else if (num_pending == 0 and num_requests > 0) {
            processing_status = .ended;
            raw_status = "completed";
        }

        try infos.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .processing_status = processing_status,
            .request_counts = counts,
            .created_at = try allocator.dupe(u8, created_at),
            .ended_at = null,
            .expires_at = try allocator.dupe(u8, expires_at),
            .results_url = if (batch_name) |name| try allocator.dupe(u8, name) else null,
            .provider = .xai,
            .raw_status = try allocator.dupe(u8, raw_status),
            .output_file_id = null,
            .allocator = allocator,
        });
    }

    return infos.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const JsonHeaders = struct {
    headers: [2]std.http.Header,
    bearer_alloc: []u8,

    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.bearer_alloc);
    }
};

fn makeJsonHeaders(allocator: std.mem.Allocator, api_key: []const u8) !JsonHeaders {
    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    return .{
        .headers = .{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = bearer },
        },
        .bearer_alloc = bearer,
    };
}

/// Handle xAI HTTP error status codes.
fn handleXaiError(status: std.http.Status, body: []const u8) types.BatchApiError {
    _ = body;
    return switch (status) {
        .unauthorized => types.BatchApiError.InvalidApiKey,
        .forbidden => types.BatchApiError.InvalidApiKey,
        .not_found => types.BatchApiError.BatchNotFound,
        .too_many_requests => types.BatchApiError.RateLimitExceeded,
        .bad_request => types.BatchApiError.InvalidRequest,
        .payload_too_large => types.BatchApiError.BatchTooLarge,
        else => types.BatchApiError.ServerError,
    };
}
