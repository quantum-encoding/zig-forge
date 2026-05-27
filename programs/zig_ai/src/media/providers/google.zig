// Google Image Generation Providers
// Supports: Imagen (GenAI), Imagen (Vertex), Gemini Flash, Gemini Pro

const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;

const types = @import("../types.zig");
const storage = @import("../storage.zig");
const Timer = @import("../../timer.zig").Timer;
const ImageRequest = types.ImageRequest;
const ImageResponse = types.ImageResponse;
const MediaConfig = types.MediaConfig;
const MediaFormat = types.MediaFormat;

const http_sentinel = @import("http-sentinel");
const HttpClient = http_sentinel.HttpClient;
const base64 = http_sentinel.encoding.base64;

// ============================================================================
// API Constants
// ============================================================================

const IMAGEN_GENAI_URL = "https://generativelanguage.googleapis.com/v1beta/models/imagen-4.0-generate-001:predict";
const GEMINI_FLASH_URL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image:generateContent";
const GEMINI_PRO_URL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-pro-image-preview:generateContent";

// ============================================================================
// Imagen (GenAI API)
// ============================================================================

pub fn generateImagenGenAI(
    allocator: Allocator,
    request: ImageRequest,
    config: MediaConfig,
) !ImageResponse {
    const api_key = config.genai_api_key orelse return error.MissingApiKey;
    var timer = try Timer.start();

    // Build URL with API key
    const url = try std.fmt.allocPrint(allocator, "{s}?key={s}", .{ IMAGEN_GENAI_URL, api_key });
    defer allocator.free(url);

    // Build JSON payload via structured Stringify.
    const count = @min(request.count, 4);
    var payload_buf: std.Io.Writer.Allocating = .init(allocator);
    defer payload_buf.deinit();
    var jw: std.json.Stringify = .{ .writer = &payload_buf.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("instances");
    try jw.beginArray();
    try jw.write(.{ .prompt = request.prompt });
    try jw.endArray();
    try jw.objectField("parameters");
    try jw.beginObject();
    try jw.objectField("sampleCount");
    try jw.write(count);
    if (request.aspect_ratio) |ar| {
        try jw.objectField("aspectRatio");
        try jw.write(ar);
    }
    try jw.endObject();
    try jw.endObject();
    const payload = payload_buf.written();

    // Make HTTP request
    var client = try HttpClient.init(allocator);
    defer client.deinit();

    const headers = [_]http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept-Encoding", .value = "identity" },
    };

    var http_response = try client.post(url, &headers, payload);
    defer http_response.deinit();

    if (http_response.status != .ok) {
        std.debug.print("Imagen API error ({any}): {s}\n", .{ http_response.status, http_response.body });
        return error.ApiError;
    }

    // Parse response
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, http_response.body, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = parsed.value.object;
    const predictions = root.get("predictions") orelse return error.InvalidResponse;

    // Extract all images
    var image_data_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (image_data_list.items) |data| {
            allocator.free(data);
        }
        image_data_list.deinit(allocator);
    }

    for (predictions.array.items) |item| {
        const b64_data = item.object.get("bytesBase64Encoded") orelse continue;
        const decoded = try base64.decode(allocator, b64_data.string);
        try image_data_list.append(allocator, decoded);
    }

    if (image_data_list.items.len == 0) {
        return error.NoImagesGenerated;
    }

    // Generate job ID and build response
    const job_id = try storage.generateJobId(allocator);
    const elapsed_ns = timer.read();

    var result = ImageResponse{
        .job_id = job_id,
        .provider = .imagen_genai,
        .original_prompt = try allocator.dupe(u8, request.prompt),
        .revised_prompt = null,
        .images = &.{},
        .processing_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
        .model_used = try allocator.dupe(u8, "imagen-4.0-generate-001"),
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
// Imagen (Vertex AI)
// ============================================================================

pub fn generateImagenVertex(
    allocator: Allocator,
    request: ImageRequest,
    config: MediaConfig,
) !ImageResponse {
    const project_id = config.vertex_project_id orelse return error.MissingApiKey;
    const location = config.vertex_location;
    var timer = try Timer.start();

    // Build Vertex AI URL
    const url = try std.fmt.allocPrint(
        allocator,
        "https://{s}-aiplatform.googleapis.com/v1/projects/{s}/locations/{s}/publishers/google/models/imagen-4.0-ultra-generate-001:predict",
        .{ location, project_id, location },
    );
    defer allocator.free(url);

    // Get access token via gcloud
    const access_token = try getGcloudAccessToken(allocator);
    defer allocator.free(access_token);

    // Build JSON payload via structured Stringify.
    const count = @min(request.count, 4);
    var payload_buf: std.Io.Writer.Allocating = .init(allocator);
    defer payload_buf.deinit();
    var jw: std.json.Stringify = .{ .writer = &payload_buf.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("instances");
    try jw.beginArray();
    try jw.write(.{ .prompt = request.prompt });
    try jw.endArray();
    try jw.objectField("parameters");
    try jw.beginObject();
    try jw.objectField("sampleCount");
    try jw.write(count);
    if (request.aspect_ratio) |ar| {
        try jw.objectField("aspectRatio");
        try jw.write(ar);
    }
    try jw.endObject();
    try jw.endObject();
    const payload = payload_buf.written();

    // Make HTTP request
    var client = try HttpClient.init(allocator);
    defer client.deinit();

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
    defer allocator.free(auth_header);

    const headers = [_]http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Accept-Encoding", .value = "identity" },
    };

    var http_response = try client.post(url, &headers, payload);
    defer http_response.deinit();

    if (http_response.status != .ok) {
        std.debug.print("Vertex AI error ({any}): {s}\n", .{ http_response.status, http_response.body });
        return error.ApiError;
    }

    // Parse response (same format as GenAI)
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, http_response.body, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = parsed.value.object;
    const predictions = root.get("predictions") orelse return error.InvalidResponse;

    var image_data_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (image_data_list.items) |data| {
            allocator.free(data);
        }
        image_data_list.deinit(allocator);
    }

    for (predictions.array.items) |item| {
        const b64_data = item.object.get("bytesBase64Encoded") orelse continue;
        const decoded = try base64.decode(allocator, b64_data.string);
        try image_data_list.append(allocator, decoded);
    }

    if (image_data_list.items.len == 0) {
        return error.NoImagesGenerated;
    }

    const job_id = try storage.generateJobId(allocator);
    const elapsed_ns = timer.read();

    var result = ImageResponse{
        .job_id = job_id,
        .provider = .imagen_vertex,
        .original_prompt = try allocator.dupe(u8, request.prompt),
        .revised_prompt = null,
        .images = &.{},
        .processing_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
        .model_used = try allocator.dupe(u8, "imagen-4.0-ultra-generate-001"),
        .allocator = allocator,
    };

    const resolved = try storage.resolveStorageConfig(allocator, config, request.output_path);
    defer allocator.free(resolved.store_path_owned);
    defer allocator.free(resolved.local_path_owned);

    try storage.saveImages(allocator, &result, image_data_list.items, .png, resolved.config);

    return result;
}

// ============================================================================
// Gemini Flash (Image Generation)
// ============================================================================

pub fn generateGeminiFlash(
    allocator: Allocator,
    request: ImageRequest,
    config: MediaConfig,
) !ImageResponse {
    return generateGeminiInternal(allocator, request, config, GEMINI_FLASH_URL, "gemini-2.5-flash-image", .gemini_flash);
}

// ============================================================================
// Gemini Pro (Image Generation)
// ============================================================================

pub fn generateGeminiPro(
    allocator: Allocator,
    request: ImageRequest,
    config: MediaConfig,
) !ImageResponse {
    return generateGeminiInternal(allocator, request, config, GEMINI_PRO_URL, "gemini-3-pro-image-preview", .gemini_pro);
}

fn generateGeminiInternal(
    allocator: Allocator,
    request: ImageRequest,
    config: MediaConfig,
    base_url: []const u8,
    model_name: []const u8,
    provider: types.ImageProvider,
) !ImageResponse {
    const api_key = config.genai_api_key orelse return error.MissingApiKey;
    var timer = try Timer.start();

    const url = try std.fmt.allocPrint(allocator, "{s}?key={s}", .{ base_url, api_key });
    defer allocator.free(url);

    // Build JSON payload via structured Stringify.
    var prompt_buf: std.Io.Writer.Allocating = .init(allocator);
    defer prompt_buf.deinit();
    try prompt_buf.writer.writeAll("Generate an image: ");
    try prompt_buf.writer.writeAll(request.prompt);

    var payload_buf: std.Io.Writer.Allocating = .init(allocator);
    defer payload_buf.deinit();
    var jw: std.json.Stringify = .{ .writer = &payload_buf.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("contents");
    try jw.beginArray();
    try jw.beginObject();
    try jw.objectField("parts");
    try jw.beginArray();
    try jw.write(.{ .text = prompt_buf.written() });
    try jw.endArray();
    try jw.endObject();
    try jw.endArray();
    try jw.objectField("generationConfig");
    try jw.beginObject();
    try jw.objectField("responseModalities");
    try jw.beginArray();
    try jw.write("IMAGE");
    try jw.write("TEXT");
    try jw.endArray();
    if (request.aspect_ratio) |ar| {
        try jw.objectField("aspectRatio");
        try jw.write(ar);
    }
    try jw.endObject();
    try jw.endObject();
    const payload = payload_buf.written();

    // Make HTTP request
    var client = try HttpClient.init(allocator);
    defer client.deinit();

    const headers = [_]http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept-Encoding", .value = "identity" },
    };

    var http_response = try client.post(url, &headers, payload);
    defer http_response.deinit();

    if (http_response.status != .ok) {
        std.debug.print("Gemini API error ({any}): {s}\n", .{ http_response.status, http_response.body });
        return error.ApiError;
    }

    // Parse response
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, http_response.body, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = parsed.value.object;
    const candidates = root.get("candidates") orelse return error.InvalidResponse;

    var image_data_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (image_data_list.items) |data| {
            allocator.free(data);
        }
        image_data_list.deinit(allocator);
    }

    // Extract images from Gemini response
    for (candidates.array.items) |candidate| {
        const content = candidate.object.get("content") orelse continue;
        const parts = content.object.get("parts") orelse continue;

        for (parts.array.items) |part| {
            if (part.object.get("inlineData")) |inline_data| {
                const data = inline_data.object.get("data") orelse continue;
                const decoded = try base64.decode(allocator, data.string);
                try image_data_list.append(allocator, decoded);
            }
        }
    }

    if (image_data_list.items.len == 0) {
        return error.NoImagesGenerated;
    }

    const job_id = try storage.generateJobId(allocator);
    const elapsed_ns = timer.read();

    var result = ImageResponse{
        .job_id = job_id,
        .provider = provider,
        .original_prompt = try allocator.dupe(u8, request.prompt),
        .revised_prompt = null,
        .images = &.{},
        .processing_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
        .model_used = try allocator.dupe(u8, model_name),
        .allocator = allocator,
    };

    const resolved = try storage.resolveStorageConfig(allocator, config, request.output_path);
    defer allocator.free(resolved.store_path_owned);
    defer allocator.free(resolved.local_path_owned);

    try storage.saveImages(allocator, &result, image_data_list.items, .png, resolved.config);

    return result;
}

// ============================================================================
// Helpers
// ============================================================================

/// Get gcloud access token for Vertex AI
/// Requires GOOGLE_ACCESS_TOKEN env var (use `gcloud auth print-access-token` to get it)
fn getGcloudAccessToken(allocator: Allocator) ![]u8 {
    // Require env var - user can set it via: export GOOGLE_ACCESS_TOKEN=$(gcloud auth print-access-token)
    if (getEnv("GOOGLE_ACCESS_TOKEN")) |token| {
        return allocator.dupe(u8, std.mem.span(token));
    }
    return error.MissingAccessToken;
}

/// Get environment variable (Zig 0.16 compatible)
fn getEnv(name: [*:0]const u8) ?[*:0]const u8 {
    const ptr = std.c.getenv(name);
    if (ptr) |p| {
        return p;
    }
    return null;
}

