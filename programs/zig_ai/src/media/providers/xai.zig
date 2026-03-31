// xAI Grok Image Generation and Editing Provider
// Supports: Grok-2-Image (generate), Grok-Imagine-Image (edit)

const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;

const types = @import("../types.zig");
const storage = @import("../storage.zig");
const Timer = @import("../../timer.zig").Timer;
const ImageRequest = types.ImageRequest;
const ImageResponse = types.ImageResponse;
const EditRequest = types.EditRequest;
const MediaConfig = types.MediaConfig;
const MediaFormat = types.MediaFormat;

const http_sentinel = @import("http-sentinel");
const HttpClient = http_sentinel.HttpClient;
const base64 = http_sentinel.encoding.base64;

// C file API for reading local files (Zig 0.16 compatible)
const FILE = std.c.FILE;
extern "c" fn fseek(stream: *FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *FILE) c_long;

// ============================================================================
// API Constants
// ============================================================================

const XAI_API_URL = "https://api.x.ai/v1/images/generations";
const XAI_EDIT_API_URL = "https://api.x.ai/v1/images/edits";

// ============================================================================
// Grok-2-Image
// ============================================================================

pub fn generateGrokImage(
    allocator: Allocator,
    request: ImageRequest,
    config: MediaConfig,
) !ImageResponse {
    const api_key = config.xai_api_key orelse return error.MissingApiKey;
    var timer = Timer.start() catch unreachable;

    // Build JSON payload
    const escaped_prompt = try escapeJson(allocator, request.prompt);
    defer allocator.free(escaped_prompt);

    const count = @min(request.count, 10);

    const payload = try std.fmt.allocPrint(allocator,
        \\{{"model":"grok-2-image","prompt":"{s}","n":{d},"response_format":"b64_json"}}
    , .{ escaped_prompt, count });
    defer allocator.free(payload);


    // Make HTTP request
    var client = try HttpClient.init(allocator);
    defer client.deinit();

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    const headers = [_]http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Accept-Encoding", .value = "identity" },
    };

    var http_response = try client.post(XAI_API_URL, &headers, payload);
    defer http_response.deinit();

    if (http_response.status != .ok) {
        std.debug.print("xAI API error ({any}): {s}\n", .{ http_response.status, http_response.body });
        return error.ApiError;
    }

    // Parse response
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, http_response.body, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = parsed.value.object;
    const data_array = root.get("data") orelse return error.InvalidResponse;

    // Extract all images
    var image_data_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (image_data_list.items) |data| {
            allocator.free(data);
        }
        image_data_list.deinit(allocator);
    }

    var revised_prompt: ?[]const u8 = null;
    for (data_array.array.items) |item| {
        const b64_data = item.object.get("b64_json") orelse continue;
        const decoded = try base64.decode(allocator, b64_data.string);
        try image_data_list.append(allocator, decoded);

        // Grok may return revised prompts
        if (revised_prompt == null) {
            if (item.object.get("revised_prompt")) |rp| {
                revised_prompt = try allocator.dupe(u8, rp.string);
            }
        }
    }

    if (image_data_list.items.len == 0) {
        return error.NoImagesGenerated;
    }

    // Generate job ID and build response
    const job_id = try storage.generateJobId(allocator);
    const elapsed_ns = timer.read();

    var result = ImageResponse{
        .job_id = job_id,
        .provider = .grok,
        .original_prompt = try allocator.dupe(u8, request.prompt),
        .revised_prompt = revised_prompt,
        .images = &.{},
        .processing_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
        .model_used = try allocator.dupe(u8, "grok-2-image"),
        .allocator = allocator,
    };

    // Save images
    const resolved = try storage.resolveStorageConfig(allocator, config, request.output_path);
    defer allocator.free(resolved.store_path_owned);
    defer allocator.free(resolved.local_path_owned);

    try storage.saveImages(allocator, &result, image_data_list.items, .png, resolved.config);

    return result;
}

// ============================================================================
// Grok Image Editing
// ============================================================================

pub fn editGrokImage(
    allocator: Allocator,
    request: EditRequest,
    config: MediaConfig,
) !ImageResponse {
    const api_key = config.xai_api_key orelse return error.MissingApiKey;
    var timer = Timer.start() catch unreachable;

    // Read the first input image and encode as base64 data URI
    if (request.image_paths.len == 0) return error.InvalidResponse;
    const image_path = request.image_paths[0];

    const image_data_uri = try readFileAsDataUri(allocator, image_path);
    defer allocator.free(image_data_uri);

    // Build JSON payload
    const escaped_prompt = try escapeJson(allocator, request.prompt);
    defer allocator.free(escaped_prompt);

    const count = @min(request.count, 10);

    const payload = try std.fmt.allocPrint(allocator,
        \\{{"model":"grok-imagine-image","prompt":"{s}","n":{d},"response_format":"b64_json","image":{{"url":"{s}","type":"image_url"}}}}
    , .{ escaped_prompt, count, image_data_uri });
    defer allocator.free(payload);

    // Make HTTP request
    var client = try HttpClient.init(allocator);
    defer client.deinit();

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    const headers = [_]http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Accept-Encoding", .value = "identity" },
    };

    var http_response = try client.post(XAI_EDIT_API_URL, &headers, payload);
    defer http_response.deinit();

    if (http_response.status != .ok) {
        std.debug.print("xAI Edit API error ({any}): {s}\n", .{ http_response.status, http_response.body });
        return error.ApiError;
    }

    // Parse response — same format as generation: {"data": [{"b64_json": "..."} | {"url": "..."}]}
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, http_response.body, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = parsed.value.object;
    const data_array = root.get("data") orelse return error.InvalidResponse;

    // Extract all images
    var image_data_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (image_data_list.items) |data| {
            allocator.free(data);
        }
        image_data_list.deinit(allocator);
    }

    var revised_prompt: ?[]const u8 = null;
    for (data_array.array.items) |item| {
        // Try b64_json first, fall back to URL download
        if (item.object.get("b64_json")) |b64_data| {
            const decoded = try base64.decode(allocator, b64_data.string);
            try image_data_list.append(allocator, decoded);
        } else if (item.object.get("url")) |url_val| {
            // Download from URL
            const downloaded = try downloadImageFromUrl(allocator, api_key, url_val.string);
            try image_data_list.append(allocator, downloaded);
        } else continue;

        if (revised_prompt == null) {
            if (item.object.get("revised_prompt")) |rp| {
                revised_prompt = try allocator.dupe(u8, rp.string);
            }
        }
    }

    if (image_data_list.items.len == 0) {
        return error.NoImagesGenerated;
    }

    // Build response
    const job_id = try storage.generateJobId(allocator);
    const elapsed_ns = timer.read();

    var result = ImageResponse{
        .job_id = job_id,
        .provider = .grok,
        .original_prompt = try allocator.dupe(u8, request.prompt),
        .revised_prompt = revised_prompt,
        .images = &.{},
        .processing_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
        .model_used = try allocator.dupe(u8, "grok-imagine-image"),
        .allocator = allocator,
    };

    // Save images
    const resolved = try storage.resolveStorageConfig(allocator, config, request.output_path);
    defer allocator.free(resolved.store_path_owned);
    defer allocator.free(resolved.local_path_owned);

    try storage.saveImages(allocator, &result, image_data_list.items, .png, resolved.config);

    return result;
}

/// Read a local file and encode it as a base64 data URI (data:image/<ext>;base64,<data>)
fn readFileAsDataUri(allocator: Allocator, path: []const u8) ![]u8 {
    // Determine MIME type from extension
    const mime_type: []const u8 = if (std.mem.endsWith(u8, path, ".png"))
        "image/png"
    else if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg"))
        "image/jpeg"
    else if (std.mem.endsWith(u8, path, ".webp"))
        "image/webp"
    else if (std.mem.endsWith(u8, path, ".gif"))
        "image/gif"
    else
        "image/png"; // default

    // Read file using C API (Zig 0.16 compatible)
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const fp = std.c.fopen(path_z.ptr, "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(fp);

    // Get file size
    _ = fseek(fp, 0, 2); // SEEK_END
    const file_size = ftell(fp);
    if (file_size <= 0) return error.InvalidResponse;
    _ = fseek(fp, 0, 0); // SEEK_SET

    const size: usize = @intCast(file_size);
    const file_buf = try allocator.alloc(u8, size);
    defer allocator.free(file_buf);

    const bytes_read = std.c.fread(file_buf.ptr, 1, size, fp);
    if (bytes_read != size) return error.InvalidResponse;

    // Encode to base64
    const b64_data = try base64.encode(allocator, file_buf);
    defer allocator.free(b64_data);

    // Build data URI: data:<mime>;base64,<data>
    return std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ mime_type, b64_data });
}

/// Download an image from a URL (with Bearer auth)
fn downloadImageFromUrl(allocator: Allocator, api_key: []const u8, url: []const u8) ![]u8 {
    var client = try HttpClient.init(allocator);
    defer client.deinit();

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    const headers = [_]http.Header{
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Accept-Encoding", .value = "identity" },
    };

    var response = try client.get(url, &headers);
    defer response.deinit();

    if (response.status != .ok) {
        return error.DownloadFailed;
    }

    return allocator.dupe(u8, response.body);
}

// ============================================================================
// Helpers
// ============================================================================

/// Escape a string for JSON (allocates new string)
fn escapeJson(allocator: Allocator, s: []const u8) ![]u8 {
    // Count how much space we need
    var extra: usize = 0;
    for (s) |c| {
        switch (c) {
            '"', '\\', '\n', '\r', '\t' => extra += 1,
            else => if (c < 0x20) {
                extra += 5; // \u00XX
            },
        }
    }

    const result = try allocator.alloc(u8, s.len + extra);
    var i: usize = 0;

    for (s) |c| {
        switch (c) {
            '"' => {
                result[i] = '\\';
                result[i + 1] = '"';
                i += 2;
            },
            '\\' => {
                result[i] = '\\';
                result[i + 1] = '\\';
                i += 2;
            },
            '\n' => {
                result[i] = '\\';
                result[i + 1] = 'n';
                i += 2;
            },
            '\r' => {
                result[i] = '\\';
                result[i + 1] = 'r';
                i += 2;
            },
            '\t' => {
                result[i] = '\\';
                result[i + 1] = 't';
                i += 2;
            },
            else => {
                if (c < 0x20) {
                    _ = std.fmt.bufPrint(result[i .. i + 6], "\\u{x:0>4}", .{c}) catch unreachable;
                    i += 6;
                } else {
                    result[i] = c;
                    i += 1;
                }
            },
        }
    }

    return result[0..i];
}
