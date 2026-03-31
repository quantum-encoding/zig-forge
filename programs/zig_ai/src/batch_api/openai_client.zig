// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! OpenAI Batch API client (text + image)
//! https://platform.openai.com/docs/guides/batch
//!
//! Workflow (two-step creation):
//!   1. Upload JSONL file via POST /v1/files (multipart, purpose=batch)
//!   2. Create batch via POST /v1/batches with {input_file_id, endpoint, completion_window}
//!
//! Endpoints:
//!   POST   /v1/files                      — Upload batch input file
//!   POST   /v1/batches                    — Create batch
//!   GET    /v1/batches/{batch_id}         — Get status
//!   POST   /v1/batches/{batch_id}/cancel  — Cancel batch
//!   GET    /v1/batches?limit=N            — List batches
//!   GET    /v1/files/{file_id}/content    — Download results

const std = @import("std");
const http_sentinel = @import("http-sentinel");
const types = @import("types.zig");
const client = @import("client.zig");

const OPENAI_API = "https://api.openai.com/v1";
const FILES_API = OPENAI_API ++ "/files";
const BATCHES_API = OPENAI_API ++ "/batches";
pub const DEFAULT_MODEL = "gpt-4.1-mini";

const MULTIPART_BOUNDARY = "----ZigBatchUpload9X2kR7mN";

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Create a new OpenAI batch from input rows. Internally uploads JSONL file
/// then creates the batch. Returns BatchInfo with the batch ID.
pub fn create(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    rows: []const types.BatchInputRow,
    config: types.BatchCreateConfig,
) !types.BatchInfo {
    const effective_model = if (model.len > 0) model else DEFAULT_MODEL;

    // Step 1: Build JSONL payload
    const jsonl = try buildJsonlPayload(allocator, rows, config, effective_model);
    defer allocator.free(jsonl);

    // Step 2: Upload file
    const file_id = try uploadFile(allocator, api_key, jsonl);
    defer allocator.free(file_id);

    // Step 3: Create batch
    const endpoint_url = detectEndpoint(effective_model);
    const batch_payload = try std.fmt.allocPrint(allocator,
        "{{\"input_file_id\":\"{s}\",\"endpoint\":\"{s}\",\"completion_window\":\"24h\"}}",
        .{ file_id, endpoint_url },
    );
    defer allocator.free(batch_payload);

    var http_client = try http_sentinel.HttpClient.init(allocator);
    defer http_client.deinit();

    var auth = try makeJsonHeaders(allocator, api_key);
    defer auth.deinit(allocator);
    var response = try http_client.post(BATCHES_API, &auth.headers, batch_payload);
    defer response.deinit();

    if (response.status != .ok and response.status != .created) {
        return handleOpenAIError(response.status, response.body);
    }

    return parseOpenAIBatchInfo(allocator, response.body);
}

/// Create an OpenAI batch from a pre-built JSONL payload (for FFI use).
/// Uploads the JSONL file and creates the batch.
pub fn createFromPayload(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    payload: []const u8,
    model: []const u8,
) !types.BatchInfo {
    const effective_model = if (model.len > 0) model else DEFAULT_MODEL;

    // Upload file
    const file_id = try uploadFile(allocator, api_key, payload);
    defer allocator.free(file_id);

    // Create batch
    const endpoint_url = detectEndpoint(effective_model);
    const batch_payload = try std.fmt.allocPrint(allocator,
        "{{\"input_file_id\":\"{s}\",\"endpoint\":\"{s}\",\"completion_window\":\"24h\"}}",
        .{ file_id, endpoint_url },
    );
    defer allocator.free(batch_payload);

    var http_client = try http_sentinel.HttpClient.init(allocator);
    defer http_client.deinit();

    var auth = try makeJsonHeaders(allocator, api_key);
    defer auth.deinit(allocator);
    var response = try http_client.post(BATCHES_API, &auth.headers, batch_payload);
    defer response.deinit();

    if (response.status != .ok and response.status != .created) {
        return handleOpenAIError(response.status, response.body);
    }

    return parseOpenAIBatchInfo(allocator, response.body);
}

/// Get the current status of an OpenAI batch.
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
        return handleOpenAIError(response.status, response.body);
    }

    return parseOpenAIBatchInfo(allocator, response.body);
}

/// Download batch results. Gets status to find output_file_id, then downloads
/// the output file via the Files API and parses the JSONL.
pub fn getResults(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    batch_id: []const u8,
) ![]types.BatchResultItem {
    // Get status to find output_file_id
    var info = try getStatus(allocator, api_key, batch_id);
    defer info.deinit();

    if (info.processing_status != .ended) {
        return types.BatchApiError.ResultsNotReady;
    }

    const output_file_id = info.output_file_id orelse {
        return types.BatchApiError.ResultsNotReady;
    };

    // Download the output file
    var http_client = try http_sentinel.HttpClient.init(allocator);
    defer http_client.deinit();

    const file_url = try std.fmt.allocPrint(allocator, "{s}/{s}/content", .{ FILES_API, output_file_id });
    defer allocator.free(file_url);

    var auth = try makeJsonHeaders(allocator, api_key);
    defer auth.deinit(allocator);
    var response = try http_client.get(file_url, &auth.headers);
    defer response.deinit();

    if (response.status != .ok) {
        return handleOpenAIError(response.status, response.body);
    }

    return parseOpenAIResults(allocator, response.body);
}

/// Cancel an in-progress OpenAI batch.
pub fn cancel(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    batch_id: []const u8,
) !types.BatchInfo {
    var http_client = try http_sentinel.HttpClient.init(allocator);
    defer http_client.deinit();

    const endpoint = try std.fmt.allocPrint(allocator, "{s}/{s}/cancel", .{ BATCHES_API, batch_id });
    defer allocator.free(endpoint);

    var auth = try makeJsonHeaders(allocator, api_key);
    defer auth.deinit(allocator);
    var response = try http_client.post(endpoint, &auth.headers, "");
    defer response.deinit();

    if (response.status != .ok) {
        return handleOpenAIError(response.status, response.body);
    }

    return parseOpenAIBatchInfo(allocator, response.body);
}

/// List recent OpenAI batches.
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
        return handleOpenAIError(response.status, response.body);
    }

    return parseOpenAIBatchList(allocator, response.body);
}

// ---------------------------------------------------------------------------
// JSONL payload builder
// ---------------------------------------------------------------------------

/// Build JSONL payload for OpenAI batch. Each line is a complete request.
/// Auto-detects endpoint from model name (text vs image vs responses API).
pub fn buildJsonlPayload(
    allocator: std.mem.Allocator,
    rows: []const types.BatchInputRow,
    config: types.BatchCreateConfig,
    model: []const u8,
) ![]u8 {
    const endpoint_url = detectEndpoint(model);
    const is_image = isImageEndpoint(endpoint_url);
    const is_responses = isResponsesEndpoint(endpoint_url);

    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);

    for (rows, 0..) |row, idx| {
        if (idx > 0) try payload.append(allocator, '\n');

        const effective_model = row.model orelse model;

        // custom_id
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

        // Line header: {"custom_id":"...","method":"POST","url":"...","body":
        try payload.appendSlice(allocator, "{\"custom_id\":\"");
        try payload.appendSlice(allocator, escaped_id.items);
        try payload.appendSlice(allocator, "\",\"method\":\"POST\",\"url\":\"");
        try payload.appendSlice(allocator, endpoint_url);
        try payload.appendSlice(allocator, "\",\"body\":{\"model\":\"");
        try payload.appendSlice(allocator, effective_model);
        try payload.appendSlice(allocator, "\"");

        if (is_image) {
            // Image generation body: prompt, n, size, quality, response_format
            try payload.appendSlice(allocator, ",\"prompt\":\"");
            try payload.appendSlice(allocator, escaped_prompt.items);
            try payload.appendSlice(allocator, "\",\"response_format\":\"b64_json\"");

            // n (number of images)
            const n = row.n orelse config.image_count;
            if (n != 1) {
                var n_buf: [8]u8 = undefined;
                const n_str = std.fmt.bufPrint(&n_buf, ",\"n\":{}", .{n}) catch unreachable;
                try payload.appendSlice(allocator, n_str);
            }

            // size
            const size = row.size orelse config.image_size;
            if (size) |sz| {
                try payload.appendSlice(allocator, ",\"size\":\"");
                try payload.appendSlice(allocator, sz);
                try payload.appendSlice(allocator, "\"");
            }

            // quality
            const quality = row.quality orelse config.image_quality;
            if (quality) |q| {
                try payload.appendSlice(allocator, ",\"quality\":\"");
                try payload.appendSlice(allocator, q);
                try payload.appendSlice(allocator, "\"");
            }
        } else if (is_responses) {
            // Responses API body (GPT-5.2+): input, instructions, max_output_tokens
            try payload.appendSlice(allocator, ",\"input\":\"");
            try payload.appendSlice(allocator, escaped_prompt.items);
            try payload.appendSlice(allocator, "\"");

            // System prompt as instructions
            const sys = row.system_prompt orelse config.system_prompt;
            if (sys) |sp| {
                var escaped_sys: std.ArrayListUnmanaged(u8) = .empty;
                defer escaped_sys.deinit(allocator);
                try client.escapeJsonString(allocator, &escaped_sys, sp);
                try payload.appendSlice(allocator, ",\"instructions\":\"");
                try payload.appendSlice(allocator, escaped_sys.items);
                try payload.appendSlice(allocator, "\"");
            }

            // max_output_tokens (Responses API uses this, not max_tokens)
            const max_tokens = row.max_tokens orelse config.max_tokens;
            var tok_buf: [32]u8 = undefined;
            const tok_str = std.fmt.bufPrint(&tok_buf, ",\"max_output_tokens\":{}", .{max_tokens}) catch unreachable;
            try payload.appendSlice(allocator, tok_str);
        } else {
            // Chat Completions body: messages, max_tokens, temperature
            try payload.appendSlice(allocator, ",\"messages\":[");

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

            // max_tokens
            const max_tokens = row.max_tokens orelse config.max_tokens;
            var tok_buf: [32]u8 = undefined;
            const tok_str = std.fmt.bufPrint(&tok_buf, ",\"max_tokens\":{}", .{max_tokens}) catch unreachable;
            try payload.appendSlice(allocator, tok_str);

            // temperature (optional)
            const temp = row.temperature orelse config.temperature;
            if (temp) |t| {
                try payload.appendSlice(allocator, ",\"temperature\":");
                var temp_buf: [32]u8 = undefined;
                const temp_str = std.fmt.bufPrint(&temp_buf, "{d:.2}", .{t}) catch unreachable;
                try payload.appendSlice(allocator, temp_str);
            }
        }

        try payload.appendSlice(allocator, "}}"); // close body and line
    }

    return try allocator.dupe(u8, payload.items);
}

// ---------------------------------------------------------------------------
// File upload (multipart/form-data)
// ---------------------------------------------------------------------------

/// Upload a JSONL file to OpenAI Files API. Returns the file ID.
fn uploadFile(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    jsonl_content: []const u8,
) ![]u8 {
    // Build multipart body
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);

    // Field: purpose
    try body.appendSlice(allocator, "--" ++ MULTIPART_BOUNDARY ++ "\r\n");
    try body.appendSlice(allocator, "Content-Disposition: form-data; name=\"purpose\"\r\n\r\n");
    try body.appendSlice(allocator, "batch\r\n");

    // Field: file
    try body.appendSlice(allocator, "--" ++ MULTIPART_BOUNDARY ++ "\r\n");
    try body.appendSlice(allocator, "Content-Disposition: form-data; name=\"file\"; filename=\"batch_input.jsonl\"\r\n");
    try body.appendSlice(allocator, "Content-Type: application/jsonl\r\n\r\n");
    try body.appendSlice(allocator, jsonl_content);
    try body.appendSlice(allocator, "\r\n");

    // Closing boundary
    try body.appendSlice(allocator, "--" ++ MULTIPART_BOUNDARY ++ "--\r\n");

    const multipart_body = try allocator.dupe(u8, body.items);
    defer allocator.free(multipart_body);

    // Headers: Authorization + Content-Type with boundary
    const content_type = "multipart/form-data; boundary=" ++ MULTIPART_BOUNDARY;
    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = content_type },
        .{ .name = "Authorization", .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key}) },
    };
    defer allocator.free(@constCast(headers[1].value));

    var http_client = try http_sentinel.HttpClient.init(allocator);
    defer http_client.deinit();

    var response = try http_client.post(FILES_API, &headers, multipart_body);
    defer response.deinit();

    if (response.status != .ok and response.status != .created) {
        return types.BatchApiError.FileUploadFailed;
    }

    // Parse file ID from response
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        response.body,
        .{ .allocate = .alloc_always },
    ) catch return types.BatchApiError.ParseError;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return types.BatchApiError.ParseError;

    const file_id = try client.getJsonString(root, "id") orelse return types.BatchApiError.ParseError;
    return try allocator.dupe(u8, file_id);
}

// ---------------------------------------------------------------------------
// Response parsers
// ---------------------------------------------------------------------------

fn parseOpenAIBatchInfo(allocator: std.mem.Allocator, body: []const u8) !types.BatchInfo {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    ) catch return types.BatchApiError.ParseError;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return types.BatchApiError.ParseError;

    // Check for error
    if (root.object.get("error")) |err_obj| {
        if (err_obj == .object) {
            if (try client.getJsonString(err_obj, "type")) |err_type| {
                if (std.mem.eql(u8, err_type, "invalid_api_key")) return types.BatchApiError.InvalidApiKey;
                if (std.mem.eql(u8, err_type, "not_found_error")) return types.BatchApiError.BatchNotFound;
            }
        }
        return types.BatchApiError.ServerError;
    }

    // Batch ID
    const id = try client.getJsonString(root, "id") orelse return types.BatchApiError.ParseError;

    // Status
    const status_str = try client.getJsonString(root, "status") orelse "validating";
    const processing_status = mapOpenAIStatus(status_str);

    // Request counts: {total, completed, failed}
    var counts = types.RequestCounts{};
    if (root.object.get("request_counts")) |rc| {
        if (rc == .object) {
            const total = client.getJsonU32(rc, "total");
            const completed = client.getJsonU32(rc, "completed");
            const failed = client.getJsonU32(rc, "failed");

            counts.succeeded = completed;
            counts.errored = failed;
            if (total > completed + failed) {
                counts.processing = total - completed - failed;
            }
        }
    }

    // Map terminal statuses to appropriate counts
    if (processing_status == .ended and counts.succeeded == 0 and counts.errored == 0 and counts.processing > 0) {
        if (std.mem.eql(u8, status_str, "expired")) {
            counts.expired = counts.processing;
            counts.processing = 0;
        } else if (std.mem.eql(u8, status_str, "cancelled")) {
            counts.canceled = counts.processing;
            counts.processing = 0;
        } else if (std.mem.eql(u8, status_str, "failed")) {
            counts.errored = counts.processing;
            counts.processing = 0;
        }
    }

    // Timestamps (OpenAI uses unix timestamps)
    const created_at = formatTimestamp(allocator, root, "created_at");
    const expires_at = formatTimestamp(allocator, root, "expires_at");
    const ended_at = formatTimestamp(allocator, root, "completed_at");

    // Output file ID (for downloading results)
    const output_file_id = try client.getJsonString(root, "output_file_id");

    // Endpoint (for display)
    const endpoint_str = try client.getJsonString(root, "endpoint");

    return types.BatchInfo{
        .id = try allocator.dupe(u8, id),
        .processing_status = processing_status,
        .request_counts = counts,
        .created_at = created_at orelse try allocator.dupe(u8, "unknown"),
        .ended_at = ended_at,
        .expires_at = expires_at orelse try allocator.dupe(u8, "unknown"),
        .results_url = if (endpoint_str) |ep| try allocator.dupe(u8, ep) else null,
        .provider = .openai,
        .raw_status = try allocator.dupe(u8, status_str),
        .output_file_id = if (output_file_id) |ofi| try allocator.dupe(u8, ofi) else null,
        .allocator = allocator,
    };
}

fn parseOpenAIResults(allocator: std.mem.Allocator, body: []const u8) ![]types.BatchResultItem {
    var results: std.ArrayListUnmanaged(types.BatchResultItem) = .empty;
    errdefer {
        for (results.items) |*r| r.deinit();
        results.deinit(allocator);
    }

    // Body is JSONL — split by newlines
    var line_iter = std.mem.splitScalar(u8, body, '\n');
    while (line_iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            trimmed,
            .{ .allocate = .alloc_always },
        ) catch continue;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) continue;

        var item = types.BatchResultItem{
            .custom_id = try allocator.dupe(u8, "unknown"),
            .result_type = .errored,
            .allocator = allocator,
        };
        errdefer item.deinit();

        // custom_id
        if (try client.getJsonString(root, "custom_id")) |cid| {
            allocator.free(item.custom_id);
            item.custom_id = try allocator.dupe(u8, cid);
        }

        // Check for error
        if (root.object.get("error")) |err_val| {
            if (err_val == .object) {
                if (try client.getJsonString(err_val, "code")) |code| {
                    item.error_type = try allocator.dupe(u8, code);
                }
                if (try client.getJsonString(err_val, "message")) |msg| {
                    item.error_message = try allocator.dupe(u8, msg);
                }
                item.result_type = .errored;
                try results.append(allocator, item);
                continue;
            }
            // null error means success path
        }

        // Parse response
        if (root.object.get("response")) |resp| {
            if (resp != .object) {
                try results.append(allocator, item);
                continue;
            }

            // Check status_code
            const status_code = client.getJsonU32(resp, "status_code");
            if (status_code != 200 and status_code != 0) {
                item.result_type = .errored;
                var code_buf: [16]u8 = undefined;
                const code_str = std.fmt.bufPrint(&code_buf, "{}", .{status_code}) catch "error";
                item.error_type = try allocator.dupe(u8, code_str);
                try results.append(allocator, item);
                continue;
            }

            // Parse body
            if (resp.object.get("body")) |resp_body| {
                if (resp_body == .object) {
                    item.result_type = .succeeded;

                    // Text results: choices[0].message.content
                    if (resp_body.object.get("choices")) |choices| {
                        if (choices == .array and choices.array.items.len > 0) {
                            const choice = choices.array.items[0];
                            if (choice == .object) {
                                if (choice.object.get("message")) |msg| {
                                    if (msg == .object) {
                                        if (try client.getJsonString(msg, "content")) |content| {
                                            item.content = try allocator.dupe(u8, content);
                                        }
                                    }
                                }
                                // finish_reason → stop_reason
                                if (try client.getJsonString(choice, "finish_reason")) |fr| {
                                    item.stop_reason = try allocator.dupe(u8, fr);
                                }
                            }
                        }
                    }

                    // Responses API: output[0].content[0].text
                    if (item.content == null) {
                        if (resp_body.object.get("output")) |output| {
                            if (output == .array and output.array.items.len > 0) {
                                const out_item = output.array.items[0];
                                if (out_item == .object) {
                                    if (out_item.object.get("content")) |content_arr| {
                                        if (content_arr == .array and content_arr.array.items.len > 0) {
                                            const content_item = content_arr.array.items[0];
                                            if (content_item == .object) {
                                                if (try client.getJsonString(content_item, "text")) |text| {
                                                    item.content = try allocator.dupe(u8, text);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Image results: data[0].b64_json
                    if (item.content == null) {
                        if (resp_body.object.get("data")) |data| {
                            if (data == .array and data.array.items.len > 0) {
                                const data_item = data.array.items[0];
                                if (data_item == .object) {
                                    if (try client.getJsonString(data_item, "b64_json")) |b64| {
                                        // Store base64 data as content with [IMAGE] prefix
                                        item.content = try std.fmt.allocPrint(allocator, "[IMAGE:{d}bytes]", .{b64.len});
                                        item.image_path = try allocator.dupe(u8, b64);
                                    }
                                }
                            }
                        }
                    }

                    // Usage tokens
                    if (resp_body.object.get("usage")) |usage| {
                        if (usage == .object) {
                            item.input_tokens = client.getJsonU32(usage, "prompt_tokens");
                            item.output_tokens = client.getJsonU32(usage, "completion_tokens");
                            // Also check total_tokens variants
                            if (item.output_tokens == 0) {
                                item.output_tokens = client.getJsonU32(usage, "total_tokens");
                            }
                        }
                    }

                    // Model
                    if (try client.getJsonString(resp_body, "model")) |m| {
                        item.model = try allocator.dupe(u8, m);
                    }
                }
            }
        }

        try results.append(allocator, item);
    }

    return results.toOwnedSlice(allocator);
}

fn parseOpenAIBatchList(allocator: std.mem.Allocator, body: []const u8) ![]types.BatchInfo {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    ) catch return types.BatchApiError.ParseError;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return types.BatchApiError.ParseError;

    const data_arr = root.object.get("data") orelse {
        var empty: std.ArrayListUnmanaged(types.BatchInfo) = .empty;
        return empty.toOwnedSlice(allocator);
    };
    if (data_arr != .array) return types.BatchApiError.ParseError;

    var infos: std.ArrayListUnmanaged(types.BatchInfo) = .empty;
    errdefer {
        for (infos.items) |*info| info.deinit();
        infos.deinit(allocator);
    }

    for (data_arr.array.items) |item| {
        if (item != .object) continue;

        const id = try client.getJsonString(item, "id") orelse continue;
        const status_str = try client.getJsonString(item, "status") orelse "validating";
        const processing_status = mapOpenAIStatus(status_str);

        var counts = types.RequestCounts{};
        if (item.object.get("request_counts")) |rc| {
            if (rc == .object) {
                const total = client.getJsonU32(rc, "total");
                const completed = client.getJsonU32(rc, "completed");
                const failed = client.getJsonU32(rc, "failed");
                counts.succeeded = completed;
                counts.errored = failed;
                if (total > completed + failed) {
                    counts.processing = total - completed - failed;
                }
            }
        }

        const created_at = formatTimestamp(allocator, item, "created_at");
        const expires_at = formatTimestamp(allocator, item, "expires_at");
        const ended_at = formatTimestamp(allocator, item, "completed_at");
        const output_file_id = try client.getJsonString(item, "output_file_id");

        try infos.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .processing_status = processing_status,
            .request_counts = counts,
            .created_at = created_at orelse try allocator.dupe(u8, "unknown"),
            .ended_at = ended_at,
            .expires_at = expires_at orelse try allocator.dupe(u8, "unknown"),
            .results_url = null,
            .provider = .openai,
            .raw_status = try allocator.dupe(u8, status_str),
            .output_file_id = if (output_file_id) |ofi| try allocator.dupe(u8, ofi) else null,
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

/// Auto-detect the batch endpoint from the model name.
pub fn detectEndpoint(model: []const u8) []const u8 {
    // Image models
    if (std.mem.startsWith(u8, model, "gpt-image")) return "/v1/images/generations";
    if (std.mem.startsWith(u8, model, "chatgpt-image")) return "/v1/images/generations";
    if (std.mem.startsWith(u8, model, "dall-e")) return "/v1/images/generations";

    // Responses API for GPT-5.2+ (uses different format)
    if (std.mem.startsWith(u8, model, "gpt-5.2")) return "/v1/responses";

    // Default: Chat Completions
    return "/v1/chat/completions";
}

fn isImageEndpoint(endpoint: []const u8) bool {
    return std.mem.eql(u8, endpoint, "/v1/images/generations");
}

fn isResponsesEndpoint(endpoint: []const u8) bool {
    return std.mem.eql(u8, endpoint, "/v1/responses");
}

/// Map OpenAI batch status strings to unified BatchStatus.
fn mapOpenAIStatus(status: []const u8) types.BatchStatus {
    if (std.mem.eql(u8, status, "validating")) return .in_progress;
    if (std.mem.eql(u8, status, "in_progress")) return .in_progress;
    if (std.mem.eql(u8, status, "finalizing")) return .in_progress;
    if (std.mem.eql(u8, status, "completed")) return .ended;
    if (std.mem.eql(u8, status, "failed")) return .ended;
    if (std.mem.eql(u8, status, "expired")) return .ended;
    if (std.mem.eql(u8, status, "cancelled")) return .ended;
    if (std.mem.eql(u8, status, "cancelling")) return .canceling;
    return .in_progress;
}

/// Format a unix timestamp integer field to a string.
fn formatTimestamp(allocator: std.mem.Allocator, obj: std.json.Value, key: []const u8) ?[]u8 {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    if (val == .integer) {
        return std.fmt.allocPrint(allocator, "{}", .{val.integer}) catch null;
    }
    if (val == .float) {
        const int_val: i64 = @intFromFloat(val.float);
        return std.fmt.allocPrint(allocator, "{}", .{int_val}) catch null;
    }
    return null;
}

/// Handle OpenAI HTTP error status codes.
fn handleOpenAIError(status: std.http.Status, body: []const u8) types.BatchApiError {
    _ = body;
    return switch (status) {
        .unauthorized => types.BatchApiError.InvalidApiKey,
        .forbidden => types.BatchApiError.InvalidApiKey,
        .not_found => types.BatchApiError.BatchNotFound,
        .too_many_requests => types.BatchApiError.RateLimitExceeded,
        .bad_request => types.BatchApiError.InvalidRequest,
        else => types.BatchApiError.ServerError,
    };
}
