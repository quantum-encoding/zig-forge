// FFI Image Generation - C bindings for image generation with AI providers

const std = @import("std");
const types = @import("types.zig");
const media_types = @import("../media/types.zig");
const providers = @import("../media/providers/mod.zig");
const storage = @import("../media/storage.zig");

const CString = types.CString;
const CBuffer = types.CBuffer;
const CImageProvider = types.CImageProvider;
const CImageRequest = types.CImageRequest;
const CEditRequest = types.CEditRequest;
const CImageResponse = types.CImageResponse;
const CMediaConfig = types.CMediaConfig;
const CMediaArray = types.CMediaArray;
const CGeneratedMedia = types.CGeneratedMedia;
const CQuality = types.CQuality;
const CStyle = types.CStyle;
const CBackground = types.CBackground;
const CInputFidelity = types.CInputFidelity;
const CMediaFormat = types.CMediaFormat;
const ErrorCode = types.ErrorCode;

// Global allocator for FFI
const allocator = std.heap.c_allocator;

// ============================================================================
// Image Generation
// ============================================================================

/// Generate images using the specified provider
export fn zig_ai_image_generate(
    request: *const CImageRequest,
    config: *const CMediaConfig,
    response_out: *CImageResponse,
) void {
    response_out.* = std.mem.zeroes(CImageResponse);

    const prompt = request.prompt.toSlice();
    if (prompt.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Prompt is empty");
        return;
    }

    // Map C types to Zig types
    const zig_provider = mapProvider(request.provider);
    const zig_quality = mapQuality(request.quality);
    const zig_style = mapStyle(request.style);

    const zig_request = media_types.ImageRequest{
        .prompt = prompt,
        .provider = zig_provider,
        .count = request.count,
        .size = if (request.size.len > 0) request.size.toSlice() else null,
        .aspect_ratio = if (request.aspect_ratio.len > 0) request.aspect_ratio.toSlice() else null,
        .quality = zig_quality,
        .style = zig_style,
        .output_path = if (request.output_path.len > 0) request.output_path.toSlice() else null,
        .background = mapBackground(request.background),
    };

    const zig_config = mapConfig(config);

    // Check provider availability
    if (!providers.isProviderAvailable(zig_provider, zig_config)) {
        response_out.success = false;
        response_out.error_code = ErrorCode.PROVIDER_NOT_AVAILABLE;
        response_out.error_message = makeErrorString("Provider not available - check API key");
        return;
    }

    // Generate images
    const result = providers.generateImage(allocator, zig_request, zig_config) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };

    // Build response
    response_out.success = true;
    response_out.error_code = ErrorCode.SUCCESS;
    response_out.job_id = CString.fromSlice(allocator.dupe(u8, result.job_id) catch "");
    response_out.provider = request.provider;
    response_out.original_prompt = CString.fromSlice(allocator.dupe(u8, result.original_prompt) catch "");
    response_out.revised_prompt = if (result.revised_prompt) |rp|
        CString.fromSlice(allocator.dupe(u8, rp) catch "")
    else
        .{ .ptr = null, .len = 0 };
    response_out.processing_time_ms = result.processing_time_ms;
    response_out.model_used = CString.fromSlice(allocator.dupe(u8, result.model_used) catch "");

    // Copy images
    if (result.images.len > 0) {
        const c_images = allocator.alloc(CGeneratedMedia, result.images.len) catch {
            response_out.success = false;
            response_out.error_code = ErrorCode.OUT_OF_MEMORY;
            return;
        };

        for (result.images, 0..) |img, i| {
            c_images[i] = .{
                .data = .{
                    .ptr = (allocator.dupe(u8, img.data) catch &[_]u8{}).ptr,
                    .len = img.data.len,
                },
                .format = mapFormatToC(img.format),
                .local_path = CString.fromSlice(allocator.dupe(u8, img.local_path) catch ""),
                .store_path = CString.fromSlice(allocator.dupe(u8, img.store_path) catch ""),
                .revised_prompt = if (img.revised_prompt) |rp|
                    CString.fromSlice(allocator.dupe(u8, rp) catch "")
                else
                    .{ .ptr = null, .len = 0 },
            };
        }

        response_out.images = .{
            .items = c_images.ptr,
            .count = c_images.len,
        };
    }
}

/// Generate images with a specific provider (convenience function)
export fn zig_ai_image_dalle3(
    prompt: CString,
    size: CString,
    quality: CQuality,
    api_key: CString,
    response_out: *CImageResponse,
) void {
    var request = CImageRequest{
        .prompt = prompt,
        .provider = .dalle3,
        .count = 1,
        .size = size,
        .aspect_ratio = .{ .ptr = null, .len = 0 },
        .quality = quality,
        .style = .vivid,
        .output_path = .{ .ptr = null, .len = 0 },
        .background = .@"opaque",
    };

    var config = CMediaConfig{
        .openai_api_key = api_key,
        .xai_api_key = .{ .ptr = null, .len = 0 },
        .genai_api_key = .{ .ptr = null, .len = 0 },
        .vertex_project_id = .{ .ptr = null, .len = 0 },
        .vertex_location = .{ .ptr = null, .len = 0 },
        .media_store_path = .{ .ptr = null, .len = 0 },
        .output_dir = .{ .ptr = null, .len = 0 },
        .disable_central_store = false,
    };

    zig_ai_image_generate(&request, &config, response_out);
}

/// Generate images with Grok
export fn zig_ai_image_grok(
    prompt: CString,
    count: u8,
    api_key: CString,
    response_out: *CImageResponse,
) void {
    var request = CImageRequest{
        .prompt = prompt,
        .provider = .grok,
        .count = count,
        .size = .{ .ptr = null, .len = 0 },
        .aspect_ratio = .{ .ptr = null, .len = 0 },
        .quality = .auto,
        .style = .vivid,
        .output_path = .{ .ptr = null, .len = 0 },
        .background = .@"opaque",
    };

    var config = CMediaConfig{
        .openai_api_key = .{ .ptr = null, .len = 0 },
        .xai_api_key = api_key,
        .genai_api_key = .{ .ptr = null, .len = 0 },
        .vertex_project_id = .{ .ptr = null, .len = 0 },
        .vertex_location = .{ .ptr = null, .len = 0 },
        .media_store_path = .{ .ptr = null, .len = 0 },
        .output_dir = .{ .ptr = null, .len = 0 },
        .disable_central_store = false,
    };

    zig_ai_image_generate(&request, &config, response_out);
}

/// Generate images with Google Imagen
export fn zig_ai_image_imagen(
    prompt: CString,
    count: u8,
    aspect_ratio: CString,
    api_key: CString,
    response_out: *CImageResponse,
) void {
    var request = CImageRequest{
        .prompt = prompt,
        .provider = .imagen_genai,
        .count = count,
        .size = .{ .ptr = null, .len = 0 },
        .aspect_ratio = aspect_ratio,
        .quality = .auto,
        .style = .vivid,
        .output_path = .{ .ptr = null, .len = 0 },
        .background = .@"opaque",
    };

    var config = CMediaConfig{
        .openai_api_key = .{ .ptr = null, .len = 0 },
        .xai_api_key = .{ .ptr = null, .len = 0 },
        .genai_api_key = api_key,
        .vertex_project_id = .{ .ptr = null, .len = 0 },
        .vertex_location = .{ .ptr = null, .len = 0 },
        .media_store_path = .{ .ptr = null, .len = 0 },
        .output_dir = .{ .ptr = null, .len = 0 },
        .disable_central_store = false,
    };

    zig_ai_image_generate(&request, &config, response_out);
}

// ============================================================================
// Provider Information
// ============================================================================

/// Check if an image provider is available
export fn zig_ai_image_provider_available(provider: CImageProvider, config: *const CMediaConfig) bool {
    const zig_provider = mapProvider(provider);
    const zig_config = mapConfig(config);
    return providers.isProviderAvailable(zig_provider, zig_config);
}

/// Get provider name
export fn zig_ai_image_provider_name(provider: CImageProvider) CString {
    const zig_provider = mapProvider(provider);
    return CString.fromSlice(zig_provider.getName());
}

/// Get environment variable name for provider
export fn zig_ai_image_provider_env_var(provider: CImageProvider) CString {
    const zig_provider = mapProvider(provider);
    return CString.fromSlice(zig_provider.getEnvVar());
}

// ============================================================================
// Memory Management
// ============================================================================

/// Free an image response
export fn zig_ai_image_response_free(response: *CImageResponse) void {
    freeString(response.job_id);
    freeString(response.original_prompt);
    freeString(response.revised_prompt);
    freeString(response.error_message);
    freeString(response.model_used);

    if (response.images.items) |items| {
        for (items[0..response.images.count]) |*img| {
            if (img.data.ptr) |p| allocator.free(p[0..img.data.len]);
            freeString(img.local_path);
            freeString(img.store_path);
            freeString(img.revised_prompt);
        }
        allocator.free(items[0..response.images.count]);
    }

    response.* = std.mem.zeroes(CImageResponse);
}

// ============================================================================
// Image Editing
// ============================================================================

/// Edit images using GPT-Image model (multipart upload)
export fn zig_ai_image_edit(
    request: *const CEditRequest,
    config: *const CMediaConfig,
    response_out: *CImageResponse,
) void {
    response_out.* = std.mem.zeroes(CImageResponse);

    const prompt = request.prompt.toSlice();
    if (prompt.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Prompt is empty");
        return;
    }

    if (request.image_count == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("At least one image path is required");
        return;
    }

    // Convert CString array to slices
    var path_buf: [16][]const u8 = undefined;
    const count = @min(request.image_count, 16);
    for (0..count) |i| {
        path_buf[i] = request.image_paths[i].toSlice();
    }

    const zig_request = media_types.EditRequest{
        .prompt = prompt,
        .image_paths = path_buf[0..count],
        .model = if (request.model.len > 0) request.model.toSlice() else "gpt-image-1.5",
        .quality = mapQuality(request.quality),
        .size = if (request.size.len > 0) request.size.toSlice() else null,
        .count = if (request.count > 0) request.count else 1,
        .input_fidelity = mapInputFidelity(request.input_fidelity),
        .background = mapBackground(request.background),
        .output_path = if (request.output_path.len > 0) request.output_path.toSlice() else null,
    };

    const zig_config = mapConfig(config);

    // Edit images via OpenAI provider
    const result = providers.editImage(allocator, zig_request, zig_config) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };

    // Build response (same format as generate)
    response_out.success = true;
    response_out.error_code = ErrorCode.SUCCESS;
    response_out.job_id = CString.fromSlice(allocator.dupe(u8, result.job_id) catch "");
    response_out.original_prompt = CString.fromSlice(allocator.dupe(u8, result.original_prompt) catch "");
    response_out.revised_prompt = if (result.revised_prompt) |rp|
        CString.fromSlice(allocator.dupe(u8, rp) catch "")
    else
        .{ .ptr = null, .len = 0 };
    response_out.processing_time_ms = result.processing_time_ms;
    response_out.model_used = CString.fromSlice(allocator.dupe(u8, result.model_used) catch "");

    if (result.images.len > 0) {
        const c_images = allocator.alloc(CGeneratedMedia, result.images.len) catch {
            response_out.success = false;
            response_out.error_code = ErrorCode.OUT_OF_MEMORY;
            return;
        };

        for (result.images, 0..) |img, i| {
            c_images[i] = .{
                .data = .{
                    .ptr = (allocator.dupe(u8, img.data) catch &[_]u8{}).ptr,
                    .len = img.data.len,
                },
                .format = mapFormatToC(img.format),
                .local_path = CString.fromSlice(allocator.dupe(u8, img.local_path) catch ""),
                .store_path = CString.fromSlice(allocator.dupe(u8, img.store_path) catch ""),
                .revised_prompt = if (img.revised_prompt) |rp|
                    CString.fromSlice(allocator.dupe(u8, rp) catch "")
                else
                    .{ .ptr = null, .len = 0 },
            };
        }

        response_out.images = .{
            .items = c_images.ptr,
            .count = c_images.len,
        };
    }
}

// ============================================================================
// Internal Helpers
// ============================================================================

fn mapBackground(cb: CBackground) ?media_types.Background {
    return switch (cb) {
        .@"opaque" => null, // opaque = default = don't send
        .transparent => .transparent,
    };
}

fn mapInputFidelity(cf: CInputFidelity) ?media_types.InputFidelity {
    return switch (cf) {
        .low => null, // low = default
        .high => .high,
    };
}

fn mapProvider(cp: CImageProvider) media_types.ImageProvider {
    return switch (cp) {
        .dalle3 => .dalle3,
        .dalle2 => .dalle2,
        .gpt_image => .gpt_image,
        .gpt_image_15 => .gpt_image_15,
        .grok => .grok,
        .imagen_genai => .imagen_genai,
        .imagen_vertex => .imagen_vertex,
        .gemini_flash => .gemini_flash,
        .gemini_pro => .gemini_pro,
        .unknown => .dalle3,
    };
}

fn mapQuality(cq: CQuality) ?media_types.Quality {
    return switch (cq) {
        .auto => null,
        .standard => .standard,
        .hd => .hd,
        .high => .high,
        .medium => .medium,
        .low => .low,
        .premium => .premium,
    };
}

fn mapStyle(cs: CStyle) ?media_types.Style {
    return switch (cs) {
        .vivid => .vivid,
        .natural => .natural,
    };
}

fn mapFormatToC(f: media_types.MediaFormat) CMediaFormat {
    return switch (f) {
        .png => .png,
        .jpeg => .jpeg,
        .webp => .webp,
        .gif => .gif,
        .mp4 => .mp4,
        .wav => .wav,
    };
}

fn mapConfig(config: *const CMediaConfig) media_types.MediaConfig {
    return config.toMediaConfig();
}

fn mapError(err: anyerror) i32 {
    return switch (err) {
        error.OutOfMemory => ErrorCode.OUT_OF_MEMORY,
        error.NetworkError => ErrorCode.NETWORK_ERROR,
        error.ApiError => ErrorCode.API_ERROR,
        error.AuthError => ErrorCode.AUTH_ERROR,
        else => ErrorCode.UNKNOWN_ERROR,
    };
}

fn makeErrorString(msg: []const u8) CString {
    const duped = allocator.dupeZ(u8, msg) catch return .{ .ptr = null, .len = 0 };
    return .{ .ptr = duped.ptr, .len = msg.len };
}

fn freeString(s: CString) void {
    if (s.ptr) |p| {
        allocator.free(p[0 .. s.len + 1]); // +1 for null terminator
    }
}
