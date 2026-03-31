// FFI Video Generation - C bindings for video generation with AI providers

const std = @import("std");
const types = @import("types.zig");
const media_types = @import("../media/types.zig");
const providers = @import("../media/providers/mod.zig");

const CString = types.CString;
const CBuffer = types.CBuffer;
const CVideoProvider = types.CVideoProvider;
const CVideoRequest = types.CVideoRequest;
const CVideoResponse = types.CVideoResponse;
const CMediaConfig = types.CMediaConfig;
const CMediaArray = types.CMediaArray;
const CGeneratedMedia = types.CGeneratedMedia;
const CMediaFormat = types.CMediaFormat;
const ErrorCode = types.ErrorCode;

// Global allocator for FFI
const allocator = std.heap.c_allocator;

// ============================================================================
// Video Generation
// ============================================================================

/// Generate videos using the specified provider
export fn zig_ai_video_generate(
    request: *const CVideoRequest,
    config: *const CMediaConfig,
    response_out: *CVideoResponse,
) void {
    response_out.* = std.mem.zeroes(CVideoResponse);

    const prompt = request.prompt.toSlice();
    if (prompt.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Prompt is empty");
        return;
    }

    // Map C types to Zig types
    const zig_provider = mapProvider(request.provider);

    const zig_request = media_types.VideoRequest{
        .prompt = prompt,
        .provider = zig_provider,
        .model = if (request.model.len > 0) request.model.toSlice() else null,
        .duration = if (request.duration_seconds > 0) request.duration_seconds else null,
        .size = if (request.size.len > 0) request.size.toSlice() else null,
        .aspect_ratio = if (request.aspect_ratio.len > 0) request.aspect_ratio.toSlice() else null,
        .resolution = if (request.resolution.len > 0) request.resolution.toSlice() else null,
        .audio = request.audio,
        .output_path = if (request.output_path.len > 0) request.output_path.toSlice() else null,
    };

    const zig_config = mapConfig(config);

    // Check provider availability
    if (!providers.isVideoProviderAvailable(zig_provider, zig_config)) {
        response_out.success = false;
        response_out.error_code = ErrorCode.PROVIDER_NOT_AVAILABLE;
        response_out.error_message = makeErrorString("Video provider not available - check API key");
        return;
    }

    // Generate video
    const result = providers.generateVideo(allocator, zig_request, zig_config) catch |err| {
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
    response_out.processing_time_ms = result.processing_time_ms;
    response_out.model_used = CString.fromSlice(allocator.dupe(u8, result.model_used) catch "");

    // Copy videos
    if (result.videos.len > 0) {
        const c_videos = allocator.alloc(CGeneratedMedia, result.videos.len) catch {
            response_out.success = false;
            response_out.error_code = ErrorCode.OUT_OF_MEMORY;
            return;
        };

        for (result.videos, 0..) |vid, i| {
            c_videos[i] = .{
                .data = .{
                    .ptr = (allocator.dupe(u8, vid.data) catch &[_]u8{}).ptr,
                    .len = vid.data.len,
                },
                .format = mapFormatToC(vid.format),
                .local_path = CString.fromSlice(allocator.dupe(u8, vid.local_path) catch ""),
                .store_path = CString.fromSlice(allocator.dupe(u8, vid.store_path) catch ""),
                .revised_prompt = .{ .ptr = null, .len = 0 },
            };
        }

        response_out.videos = .{
            .items = c_videos.ptr,
            .count = c_videos.len,
        };
    }
}

/// Generate video with Sora (convenience function)
export fn zig_ai_video_sora(
    prompt: CString,
    duration_seconds: u8,
    resolution: CString,
    api_key: CString,
    response_out: *CVideoResponse,
) void {
    var request = CVideoRequest{
        .prompt = prompt,
        .provider = .sora,
        .model = .{ .ptr = null, .len = 0 },
        .duration_seconds = duration_seconds,
        .size = .{ .ptr = null, .len = 0 },
        .aspect_ratio = .{ .ptr = null, .len = 0 },
        .resolution = resolution,
        .audio = false,
        .output_path = .{ .ptr = null, .len = 0 },
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

    zig_ai_video_generate(&request, &config, response_out);
}

/// Generate video with Veo (convenience function)
export fn zig_ai_video_veo(
    prompt: CString,
    duration_seconds: u8,
    aspect_ratio: CString,
    api_key: CString,
    response_out: *CVideoResponse,
) void {
    var request = CVideoRequest{
        .prompt = prompt,
        .provider = .veo,
        .model = .{ .ptr = null, .len = 0 },
        .duration_seconds = duration_seconds,
        .size = .{ .ptr = null, .len = 0 },
        .aspect_ratio = aspect_ratio,
        .resolution = .{ .ptr = null, .len = 0 },
        .audio = false,
        .output_path = .{ .ptr = null, .len = 0 },
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

    zig_ai_video_generate(&request, &config, response_out);
}

/// Generate video with Grok Imagine Video (convenience function)
export fn zig_ai_video_grok(
    prompt: CString,
    duration_seconds: u8,
    api_key: CString,
    response_out: *CVideoResponse,
) void {
    const request = CVideoRequest{
        .prompt = prompt,
        .provider = .grok_video,
        .model = .{ .ptr = null, .len = 0 },
        .duration_seconds = duration_seconds,
        .size = .{ .ptr = null, .len = 0 },
        .aspect_ratio = .{ .ptr = null, .len = 0 },
        .resolution = .{ .ptr = null, .len = 0 },
        .audio = false,
        .output_path = .{ .ptr = null, .len = 0 },
    };

    const config = CMediaConfig{
        .openai_api_key = .{ .ptr = null, .len = 0 },
        .xai_api_key = api_key,
        .genai_api_key = .{ .ptr = null, .len = 0 },
        .vertex_project_id = .{ .ptr = null, .len = 0 },
        .vertex_location = .{ .ptr = null, .len = 0 },
        .media_store_path = .{ .ptr = null, .len = 0 },
        .output_dir = .{ .ptr = null, .len = 0 },
        .disable_central_store = false,
    };

    zig_ai_video_generate(&request, &config, response_out);
}

// ============================================================================
// Provider Information
// ============================================================================

/// Check if a video provider is available
export fn zig_ai_video_provider_available(provider: CVideoProvider, config: *const CMediaConfig) bool {
    const zig_provider = mapProvider(provider);
    const zig_config = mapConfig(config);
    return providers.isVideoProviderAvailable(zig_provider, zig_config);
}

/// Get provider name
export fn zig_ai_video_provider_name(provider: CVideoProvider) CString {
    const zig_provider = mapProvider(provider);
    return CString.fromSlice(zig_provider.getName());
}

// ============================================================================
// Memory Management
// ============================================================================

/// Free a video response
export fn zig_ai_video_response_free(response: *CVideoResponse) void {
    freeString(response.job_id);
    freeString(response.original_prompt);
    freeString(response.error_message);
    freeString(response.model_used);

    if (response.videos.items) |items| {
        for (items[0..response.videos.count]) |*vid| {
            if (vid.data.ptr) |p| allocator.free(p[0..vid.data.len]);
            freeString(vid.local_path);
            freeString(vid.store_path);
        }
        allocator.free(items[0..response.videos.count]);
    }

    response.* = std.mem.zeroes(CVideoResponse);
}

// ============================================================================
// Internal Helpers
// ============================================================================

fn mapProvider(cp: CVideoProvider) media_types.VideoProvider {
    return switch (cp) {
        .sora => .sora,
        .veo => .veo,
        .grok_video => .grok_video,
        .unknown => .sora,
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
        error.Timeout => ErrorCode.TIMEOUT,
        else => ErrorCode.UNKNOWN_ERROR,
    };
}

fn makeErrorString(msg: []const u8) CString {
    const duped = allocator.dupeZ(u8, msg) catch return .{ .ptr = null, .len = 0 };
    return .{ .ptr = duped.ptr, .len = msg.len };
}

fn freeString(s: CString) void {
    if (s.ptr) |p| {
        allocator.free(p[0 .. s.len + 1]);
    }
}
