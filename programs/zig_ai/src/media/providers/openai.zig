// OpenAI Image Generation Provider
// Supports: DALL-E 3, DALL-E 2, GPT-Image 1, GPT-Image 1.5

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
const Quality = types.Quality;
const Style = types.Style;

const http_sentinel = @import("http-sentinel");
const HttpClient = http_sentinel.HttpClient;
const base64 = http_sentinel.encoding.base64;

// ============================================================================
// API Constants
// ============================================================================

const OPENAI_API_URL = "https://api.openai.com/v1/images/generations";
const OPENAI_EDIT_URL = "https://api.openai.com/v1/images/edits";
const MULTIPART_BOUNDARY = "----ZigImageEditBoundary9X2kR7mN";

// ============================================================================
// DALL-E 3
// ============================================================================

pub fn generateDalle3(
    allocator: Allocator,
    request: ImageRequest,
    config: MediaConfig,
) !ImageResponse {
    const api_key = config.openai_api_key orelse return error.MissingApiKey;
    var timer = Timer.start() catch unreachable;

    // Build JSON payload
    const escaped_prompt = try escapeJson(allocator, request.prompt);
    defer allocator.free(escaped_prompt);

    const size = request.size orelse "1024x1024";
    const quality_str = if (request.quality) |q| q.toString() else "standard";
    const style_str = if (request.style) |s| s.toString() else "vivid";

    const payload = try std.fmt.allocPrint(allocator,
        \\{{"model":"dall-e-3","prompt":"{s}","n":1,"size":"{s}","quality":"{s}","style":"{s}","response_format":"b64_json"}}
    , .{ escaped_prompt, size, quality_str, style_str });
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

    var response = try client.post(OPENAI_API_URL, &headers, payload);
    defer response.deinit();

    if (response.status != .ok) {
        std.debug.print("OpenAI API error: {s}\n", .{response.body});
        return error.ApiError;
    }

    // Parse response
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = parsed.value.object;
    const data_array = root.get("data") orelse return error.InvalidResponse;

    // Extract image data
    const first_item = data_array.array.items[0].object;
    const b64_data = first_item.get("b64_json") orelse return error.InvalidResponse;
    const revised_prompt = first_item.get("revised_prompt");

    // Decode base64 image
    const image_data = try base64.decode(allocator, b64_data.string);
    defer allocator.free(image_data);

    // Generate job ID and build response
    const job_id = try storage.generateJobId(allocator);
    const elapsed_ns = timer.read();

    var result = ImageResponse{
        .job_id = job_id,
        .provider = .dalle3,
        .original_prompt = try allocator.dupe(u8, request.prompt),
        .revised_prompt = if (revised_prompt) |rp| try allocator.dupe(u8, rp.string) else null,
        .images = &.{},
        .processing_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
        .model_used = try allocator.dupe(u8, "dall-e-3"),
        .allocator = allocator,
    };

    // Save images
    const resolved = try storage.resolveStorageConfig(allocator, config, request.output_path);
    defer allocator.free(resolved.store_path_owned);
    defer allocator.free(resolved.local_path_owned);

    try storage.saveImage(allocator, &result, image_data, .png, resolved.config);

    return result;
}

// ============================================================================
// DALL-E 2
// ============================================================================

pub fn generateDalle2(
    allocator: Allocator,
    request: ImageRequest,
    config: MediaConfig,
) !ImageResponse {
    const api_key = config.openai_api_key orelse return error.MissingApiKey;
    var timer = Timer.start() catch unreachable;

    // Build JSON payload
    const escaped_prompt = try escapeJson(allocator, request.prompt);
    defer allocator.free(escaped_prompt);

    const size = request.size orelse "1024x1024";
    const count = @min(request.count, 10);

    const payload = try std.fmt.allocPrint(allocator,
        \\{{"model":"dall-e-2","prompt":"{s}","n":{d},"size":"{s}","response_format":"b64_json"}}
    , .{ escaped_prompt, count, size });
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

    var http_response = try client.post(OPENAI_API_URL, &headers, payload);
    defer http_response.deinit();

    if (http_response.status != .ok) {
        std.debug.print("OpenAI API error: {s}\n", .{http_response.body});
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

    for (data_array.array.items) |item| {
        const b64_data = item.object.get("b64_json") orelse continue;
        const decoded = try base64.decode(allocator, b64_data.string);
        try image_data_list.append(allocator, decoded);
    }

    // Generate job ID and build response
    const job_id = try storage.generateJobId(allocator);
    const elapsed_ns = timer.read();

    var result = ImageResponse{
        .job_id = job_id,
        .provider = .dalle2,
        .original_prompt = try allocator.dupe(u8, request.prompt),
        .revised_prompt = null,
        .images = &.{},
        .processing_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
        .model_used = try allocator.dupe(u8, "dall-e-2"),
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
// GPT-Image 1
// ============================================================================

pub fn generateGptImage(
    allocator: Allocator,
    request: ImageRequest,
    config: MediaConfig,
) !ImageResponse {
    return generateGptImageInternal(allocator, request, config, "gpt-image-1", .gpt_image);
}

// ============================================================================
// GPT-Image 1.5
// ============================================================================

pub fn generateGptImage15(
    allocator: Allocator,
    request: ImageRequest,
    config: MediaConfig,
) !ImageResponse {
    return generateGptImageInternal(allocator, request, config, "gpt-image-1.5", .gpt_image_15);
}

fn generateGptImageInternal(
    allocator: Allocator,
    request: ImageRequest,
    config: MediaConfig,
    model: []const u8,
    provider: types.ImageProvider,
) !ImageResponse {
    const api_key = config.openai_api_key orelse return error.MissingApiKey;
    var timer = Timer.start() catch unreachable;

    // Build JSON payload
    const escaped_prompt = try escapeJson(allocator, request.prompt);
    defer allocator.free(escaped_prompt);

    const size = request.size orelse "1024x1024";
    const count = @min(request.count, 10);
    const quality_str = if (request.quality) |q| q.toString() else "auto";

    // GPT-Image models use output_format instead of response_format
    const payload = if (request.background) |bg|
        try std.fmt.allocPrint(allocator,
            \\{{"model":"{s}","prompt":"{s}","n":{d},"size":"{s}","quality":"{s}","output_format":"png","background":"{s}"}}
        , .{ model, escaped_prompt, count, size, quality_str, bg.toString() })
    else
        try std.fmt.allocPrint(allocator,
            \\{{"model":"{s}","prompt":"{s}","n":{d},"size":"{s}","quality":"{s}","output_format":"png"}}
        , .{ model, escaped_prompt, count, size, quality_str });
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

    var http_response = try client.post(OPENAI_API_URL, &headers, payload);
    defer http_response.deinit();

    if (http_response.status != .ok) {
        std.debug.print("OpenAI API error: {s}\n", .{http_response.body});
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

        if (revised_prompt == null) {
            if (item.object.get("revised_prompt")) |rp| {
                revised_prompt = try allocator.dupe(u8, rp.string);
            }
        }
    }

    // Generate job ID and build response
    const job_id = try storage.generateJobId(allocator);
    const elapsed_ns = timer.read();

    var result = ImageResponse{
        .job_id = job_id,
        .provider = provider,
        .original_prompt = try allocator.dupe(u8, request.prompt),
        .revised_prompt = revised_prompt,
        .images = &.{},
        .processing_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
        .model_used = try allocator.dupe(u8, model),
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
// GPT-Image Edit (multipart form data)
// ============================================================================

pub fn editGptImage(
    allocator: Allocator,
    request: EditRequest,
    config: MediaConfig,
) !ImageResponse {
    const api_key = config.openai_api_key orelse return error.MissingApiKey;
    var timer = Timer.start() catch unreachable;

    // Read all input image files
    var image_data_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (image_data_list.items) |data| {
            allocator.free(data);
        }
        image_data_list.deinit(allocator);
    }

    for (request.image_paths) |path| {
        const data = storage.readFile(allocator, path) catch |err| {
            std.debug.print("Failed to read image: {s} ({any})\n", .{ path, err });
            return error.FileReadFailed;
        };
        try image_data_list.append(allocator, data);
    }

    if (image_data_list.items.len == 0) return error.NoInputImages;

    // Build multipart form body
    const body = try buildEditMultipartBody(allocator, request, image_data_list.items);
    defer allocator.free(body);

    // Make HTTP request
    var client = try HttpClient.init(allocator);
    defer client.deinit();

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    const content_type = "multipart/form-data; boundary=" ++ MULTIPART_BOUNDARY;

    const headers = [_]http.Header{
        .{ .name = "Content-Type", .value = content_type },
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Accept-Encoding", .value = "identity" },
    };

    var http_response = try client.post(OPENAI_EDIT_URL, &headers, body);
    defer http_response.deinit();

    if (http_response.status != .ok) {
        std.debug.print("OpenAI Edit API error: {s}\n", .{http_response.body});
        return error.ApiError;
    }

    // Parse response (same format as generations: data[].b64_json)
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, http_response.body, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = parsed.value.object;
    const data_array = root.get("data") orelse return error.InvalidResponse;

    // Extract all images
    var result_images: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (result_images.items) |data| {
            allocator.free(data);
        }
        result_images.deinit(allocator);
    }

    var revised_prompt: ?[]const u8 = null;
    for (data_array.array.items) |item| {
        const b64_data = item.object.get("b64_json") orelse continue;
        const decoded = try base64.decode(allocator, b64_data.string);
        try result_images.append(allocator, decoded);

        if (revised_prompt == null) {
            if (item.object.get("revised_prompt")) |rp| {
                revised_prompt = try allocator.dupe(u8, rp.string);
            }
        }
    }

    // Generate job ID and build response
    const job_id = try storage.generateJobId(allocator);
    const elapsed_ns = timer.read();

    var result = ImageResponse{
        .job_id = job_id,
        .provider = .gpt_image_15,
        .original_prompt = try allocator.dupe(u8, request.prompt),
        .revised_prompt = revised_prompt,
        .images = &.{},
        .processing_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
        .model_used = try allocator.dupe(u8, request.model),
        .allocator = allocator,
    };

    // Save images
    const resolved = try storage.resolveStorageConfig(allocator, config, request.output_path);
    defer allocator.free(resolved.store_path_owned);
    defer allocator.free(resolved.local_path_owned);

    try storage.saveImages(allocator, &result, result_images.items, .png, resolved.config);

    return result;
}

/// Build multipart form data body for the edit endpoint
fn buildEditMultipartBody(
    allocator: Allocator,
    request: EditRequest,
    images: []const []const u8,
) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    // Image file fields (image[] for multi-image)
    for (images, 0..) |img_data, idx| {
        try body.appendSlice(allocator, "--");
        try body.appendSlice(allocator, MULTIPART_BOUNDARY);
        try body.appendSlice(allocator, "\r\n");

        const file_header = try std.fmt.allocPrint(allocator,
            "Content-Disposition: form-data; name=\"image[]\"; filename=\"image{d}.png\"\r\n" ++
            "Content-Type: image/png\r\n\r\n",
            .{idx},
        );
        defer allocator.free(file_header);
        try body.appendSlice(allocator, file_header);
        try body.appendSlice(allocator, img_data);
        try body.appendSlice(allocator, "\r\n");
    }

    // Model field
    try appendTextField(&body, allocator, "model", request.model);

    // Prompt field
    try appendTextField(&body, allocator, "prompt", request.prompt);

    // Count field
    var count_buf: [4]u8 = undefined;
    const count_str = std.fmt.bufPrint(&count_buf, "{d}", .{@min(request.count, 10)}) catch "1";
    try appendTextField(&body, allocator, "n", count_str);

    // Output format
    try appendTextField(&body, allocator, "output_format", "png");

    // Optional fields
    if (request.size) |sz| {
        try appendTextField(&body, allocator, "size", sz);
    }

    if (request.quality) |q| {
        try appendTextField(&body, allocator, "quality", q.toString());
    }

    if (request.input_fidelity) |fid| {
        try appendTextField(&body, allocator, "input_fidelity", fid.toString());
    }

    if (request.background) |bg| {
        try appendTextField(&body, allocator, "background", bg.toString());
    }

    // End boundary
    try body.appendSlice(allocator, "--");
    try body.appendSlice(allocator, MULTIPART_BOUNDARY);
    try body.appendSlice(allocator, "--\r\n");

    return try body.toOwnedSlice(allocator);
}

/// Append a text field to the multipart body
fn appendTextField(body: *std.ArrayList(u8), allocator: Allocator, name: []const u8, value: []const u8) !void {
    try body.appendSlice(allocator, "--");
    try body.appendSlice(allocator, MULTIPART_BOUNDARY);
    try body.appendSlice(allocator, "\r\n");

    const header = try std.fmt.allocPrint(allocator,
        "Content-Disposition: form-data; name=\"{s}\"\r\n\r\n",
        .{name},
    );
    defer allocator.free(header);
    try body.appendSlice(allocator, header);
    try body.appendSlice(allocator, value);
    try body.appendSlice(allocator, "\r\n");
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

// ============================================================================
// Tests
// ============================================================================

test "escapeJson" {
    const allocator = std.testing.allocator;

    const escaped = try escapeJson(allocator, "Hello \"World\"\nNew line");
    defer allocator.free(escaped);

    try std.testing.expectEqualStrings("Hello \\\"World\\\"\\nNew line", escaped);
}
