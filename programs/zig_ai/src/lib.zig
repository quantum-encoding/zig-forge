// zig_ai Library Entry Point
// Exports all functionality for both direct Zig usage and FFI
//
// Build as executable: zig build
// Build as shared library: zig build -Dlib
// Build as static library: zig build -Dlib -Dstatic

const std = @import("std");

// ============================================================================
// Core Modules (for Zig usage)
// ============================================================================

pub const cli = @import("cli.zig");
pub const model_costs = @import("model_costs.zig");
pub const batch = struct {
    pub const types = @import("batch/types.zig");
    pub const executor = @import("batch/executor.zig");
    pub const csv_parser = @import("batch/csv_parser.zig");
    pub const writer = @import("batch/writer.zig");
};

// ============================================================================
// Media Modules (for Zig usage)
// ============================================================================

pub const media = @import("media/mod.zig");
pub const text = @import("text/mod.zig");
pub const live = @import("live/mod.zig");

// ============================================================================
// FFI Types
// ============================================================================

pub const ffi_types = @import("ffi/types.zig");

// ============================================================================
// Re-exports for convenience
// ============================================================================

// Text AI
pub const Provider = cli.Provider;
pub const CLIConfig = cli.CLIConfig;
pub const CLI = cli.CLI;

// Media types
pub const ImageProvider = media.ImageProvider;
pub const ImageRequest = media.ImageRequest;
pub const ImageResponse = media.ImageResponse;
pub const MediaConfig = media.MediaConfig;

// Lyria streaming
pub const LyriaStream = media.LyriaStream;
pub const WeightedPrompt = media.WeightedPrompt;
pub const MusicConfig = media.MusicConfig;
pub const SessionState = media.SessionState;

// ============================================================================
// FFI Exports (C-compatible functions)
// ============================================================================

// Import from ffi_types for C types
const CString = ffi_types.CString;
const CBuffer = ffi_types.CBuffer;
const CTextProvider = ffi_types.CTextProvider;
const CImageProvider = ffi_types.CImageProvider;
const CMusicProvider = ffi_types.CMusicProvider;
const CTextConfig = ffi_types.CTextConfig;
const CTextResponse = ffi_types.CTextResponse;
const CTextSession = ffi_types.CTextSession;
const CMediaConfig = ffi_types.CMediaConfig;
const CImageRequest = ffi_types.CImageRequest;
const CEditRequest = ffi_types.CEditRequest;
const CImageResponse = ffi_types.CImageResponse;
const CBackground = ffi_types.CBackground;
const CInputFidelity = ffi_types.CInputFidelity;
const CMusicRequest = ffi_types.CMusicRequest;
const CMusicResponse = ffi_types.CMusicResponse;
const CImageSession = ffi_types.CImageSession;
const CImageSessionConfig = ffi_types.CImageSessionConfig;
const CImageSessionResponse = ffi_types.CImageSessionResponse;
const CLyriaSession = ffi_types.CLyriaSession;
const CLyriaConfig = ffi_types.CLyriaConfig;
const CLyriaState = ffi_types.CLyriaState;
const CWeightedPrompt = ffi_types.CWeightedPrompt;
const CAudioFormat = ffi_types.CAudioFormat;
const ErrorCode = ffi_types.ErrorCode;
const CAgentSession = ffi_types.CAgentSession;
const CAgentConfig = ffi_types.CAgentConfig;
const CAgentEvent = ffi_types.CAgentEvent;
const CAgentResult = ffi_types.CAgentResult;
const CAgentEventCallback = ffi_types.CAgentEventCallback;
const CStringResult = ffi_types.CStringResult;
const CStructuredRequest = ffi_types.CStructuredRequest;
const CStructuredResponse = ffi_types.CStructuredResponse;
const CResearchMode = ffi_types.CResearchMode;
const CResearchResponse = ffi_types.CResearchResponse;
const CSearchMode = ffi_types.CSearchMode;
const CSearchResponse = ffi_types.CSearchResponse;

// Internal imports for FFI implementations
const media_types = media.types;
const providers = media.providers;
const lyria_streaming = media.lyria_streaming;
const struct_templates = @import("structured/templates.zig");
const structured_types = @import("structured/types.zig");
const structured_providers = @import("structured/providers/mod.zig");
const research_mod = @import("research/mod.zig");
const research_web = @import("research/web_search.zig");
const research_deep = @import("research/deep_research.zig");
const research_types = @import("research/types.zig");
const search_mod = @import("search/mod.zig");
const search_grok = @import("search/grok_search.zig");
const search_types = @import("search/types.zig");

// Global allocator for FFI
const ffi_allocator = std.heap.c_allocator;

// ============================================================================
// Library Initialization
// ============================================================================

export fn zig_ai_init() void {}

export fn zig_ai_shutdown() void {}

export fn zig_ai_version() CString {
    return CString.fromSlice("1.0.0");
}

// ============================================================================
// Text AI Functions
// ============================================================================

const TextSessionInternal = struct {
    provider: cli.Provider,
    config_provider: CTextProvider = .unknown,
    model_str: ?[]const u8,
    temperature: f32,
    max_tokens: u32,
    system_prompt: ?[]const u8,
    api_key: ?[]const u8,
    conversation: std.ArrayList(Message),
};

const Message = struct {
    content: []const u8,
    is_user: bool,
};

export fn zig_ai_text_session_create(config: *const CTextConfig) ?*CTextSession {
    const session = ffi_allocator.create(TextSessionInternal) catch return null;

    session.* = .{
        .provider = mapTextProvider(config.provider),
        .model_str = dupeString(config.model.toSlice()) catch null,
        .temperature = config.temperature,
        .max_tokens = config.max_tokens,
        .system_prompt = dupeString(config.system_prompt.toSlice()) catch null,
        .api_key = dupeString(config.api_key.toSlice()) catch null,
        .conversation = .{ .items = &.{}, .capacity = 0 },
    };

    return @ptrCast(session);
}

export fn zig_ai_text_session_destroy(session: ?*CTextSession) void {
    if (session == null) return;
    const s: *TextSessionInternal = @ptrCast(@alignCast(session));

    if (s.model_str) |m| ffi_allocator.free(m);
    if (s.system_prompt) |sp| ffi_allocator.free(sp);
    if (s.api_key) |ak| ffi_allocator.free(ak);

    for (s.conversation.items) |msg| {
        ffi_allocator.free(msg.content);
    }
    s.conversation.deinit(ffi_allocator);

    ffi_allocator.destroy(s);
}

export fn zig_ai_text_send(
    session: ?*CTextSession,
    prompt: CString,
    response_out: *CTextResponse,
) void {
    response_out.* = std.mem.zeroes(CTextResponse);

    if (session == null) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Session is null");
        return;
    }

    const s: *TextSessionInternal = @ptrCast(@alignCast(session));
    const prompt_slice = prompt.toSlice();

    if (prompt_slice.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Prompt is empty");
        return;
    }

    // Create CLI config
    const cli_config = cli.CLIConfig{
        .provider = s.provider,
        .temperature = s.temperature,
        .max_tokens = s.max_tokens,
        .system_prompt = s.system_prompt,
    };

    // Make API call
    var cli_instance = cli.CLI.init(ffi_allocator, cli_config);
    defer cli_instance.deinit();
    const result = cli_instance.sendToProvider(prompt_slice, null) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };

    // Store in conversation
    s.conversation.append(ffi_allocator, .{
        .content = ffi_allocator.dupe(u8, prompt_slice) catch "",
        .is_user = true,
    }) catch {};

    s.conversation.append(ffi_allocator, .{
        .content = ffi_allocator.dupe(u8, result.message.content) catch "",
        .is_user = false,
    }) catch {};

    // Build response
    response_out.success = true;
    response_out.error_code = ErrorCode.SUCCESS;
    response_out.content = CString.fromSlice(ffi_allocator.dupe(u8, result.message.content) catch "");
    response_out.usage = .{
        .input_tokens = result.usage.input_tokens,
        .output_tokens = result.usage.output_tokens,
        .total_tokens = result.usage.input_tokens + result.usage.output_tokens,
        .cost_usd = 0,
    };
    response_out.provider = s.config_provider;
}

export fn zig_ai_text_clear_history(session: ?*CTextSession) void {
    if (session == null) return;
    const s: *TextSessionInternal = @ptrCast(@alignCast(session));

    for (s.conversation.items) |msg| {
        ffi_allocator.free(msg.content);
    }
    s.conversation.clearRetainingCapacity();
}

export fn zig_ai_text_query(
    provider_c: CTextProvider,
    prompt: CString,
    _: CString, // api_key - not used yet, env vars used instead
    response_out: *CTextResponse,
) void {
    response_out.* = std.mem.zeroes(CTextResponse);

    const prompt_slice = prompt.toSlice();
    if (prompt_slice.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Prompt is empty");
        return;
    }

    const zig_provider = mapTextProvider(provider_c);

    const cli_config = cli.CLIConfig{
        .provider = zig_provider,
    };

    var cli_instance = cli.CLI.init(ffi_allocator, cli_config);
    defer cli_instance.deinit();
    const result = cli_instance.sendToProvider(prompt_slice, null) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };

    response_out.success = true;
    response_out.error_code = ErrorCode.SUCCESS;
    response_out.content = CString.fromSlice(ffi_allocator.dupe(u8, result.message.content) catch "");
    response_out.usage = .{
        .input_tokens = result.usage.input_tokens,
        .output_tokens = result.usage.output_tokens,
        .total_tokens = result.usage.input_tokens + result.usage.output_tokens,
        .cost_usd = 0,
    };
    response_out.provider = provider_c;
}

export fn zig_ai_text_calculate_cost(
    provider_c: CTextProvider,
    model_name: CString,
    input_tokens: u32,
    output_tokens: u32,
) f64 {
    const provider_name = switch (provider_c) {
        .claude => "anthropic",
        .deepseek => "deepseek",
        .gemini => "google",
        .grok => "xai",
        .vertex => "google",
        .openai => "openai",
        .unknown => return 0,
    };

    return model_costs.calculateCost(
        provider_name,
        model_name.toSlice(),
        input_tokens,
        output_tokens,
    );
}

export fn zig_ai_text_default_model(provider_c: CTextProvider) CString {
    const zig_provider = mapTextProvider(provider_c);
    return CString.fromSlice(zig_provider.getDefaultModel(null));
}

export fn zig_ai_text_provider_available(provider_c: CTextProvider) bool {
    const zig_provider = mapTextProvider(provider_c);
    const env_var = zig_provider.getEnvVar();
    return std.c.getenv(env_var) != null;
}

export fn zig_ai_text_response_free(response: *CTextResponse) void {
    freeString(response.content);
    freeString(response.error_message);
    freeString(response.model_used);
    response.* = std.mem.zeroes(CTextResponse);
}

export fn zig_ai_string_free(s: CString) void {
    freeString(s);
}

// ============================================================================
// Image Generation Functions
// ============================================================================

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

    const zig_provider = mapImageProvider(request.provider);
    const zig_config = mapMediaConfig(config);

    if (!providers.isProviderAvailable(zig_provider, zig_config)) {
        response_out.success = false;
        response_out.error_code = ErrorCode.PROVIDER_NOT_AVAILABLE;
        response_out.error_message = makeErrorString("Provider not available - check API key");
        return;
    }

    const zig_request = media_types.ImageRequest{
        .prompt = prompt,
        .provider = zig_provider,
        .count = request.count,
        .size = if (request.size.len > 0) request.size.toSlice() else null,
        .aspect_ratio = if (request.aspect_ratio.len > 0) request.aspect_ratio.toSlice() else null,
        .quality = mapQuality(request.quality),
        .style = mapStyle(request.style),
        .output_path = if (request.output_path.len > 0) request.output_path.toSlice() else null,
        .background = mapBackground(request.background),
    };

    const result = providers.generateImage(ffi_allocator, zig_request, zig_config) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };

    response_out.success = true;
    response_out.error_code = ErrorCode.SUCCESS;
    response_out.job_id = CString.fromSlice(ffi_allocator.dupe(u8, result.job_id) catch "");
    response_out.provider = request.provider;
    response_out.original_prompt = CString.fromSlice(ffi_allocator.dupe(u8, result.original_prompt) catch "");
    response_out.processing_time_ms = result.processing_time_ms;
    response_out.model_used = CString.fromSlice(ffi_allocator.dupe(u8, result.model_used) catch "");

    if (result.images.len > 0) {
        const c_images = ffi_allocator.alloc(ffi_types.CGeneratedMedia, result.images.len) catch {
            response_out.success = false;
            response_out.error_code = ErrorCode.OUT_OF_MEMORY;
            return;
        };

        for (result.images, 0..) |img, i| {
            const img_data = ffi_allocator.dupe(u8, img.data) catch {
                response_out.success = false;
                response_out.error_code = ErrorCode.OUT_OF_MEMORY;
                return;
            };
            c_images[i] = .{
                .data = .{
                    .ptr = img_data.ptr,
                    .len = img_data.len,
                },
                .format = mapFormatToC(img.format),
                .local_path = CString.fromSlice(ffi_allocator.dupe(u8, img.local_path) catch ""),
                .store_path = CString.fromSlice(ffi_allocator.dupe(u8, img.store_path) catch ""),
                .revised_prompt = if (img.revised_prompt) |rp|
                    CString.fromSlice(ffi_allocator.dupe(u8, rp) catch "")
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

export fn zig_ai_image_provider_available(provider_c: CImageProvider, config: *const CMediaConfig) bool {
    const zig_provider = mapImageProvider(provider_c);
    const zig_config = mapMediaConfig(config);
    return providers.isProviderAvailable(zig_provider, zig_config);
}

export fn zig_ai_image_provider_name(provider_c: CImageProvider) CString {
    const zig_provider = mapImageProvider(provider_c);
    return CString.fromSlice(zig_provider.getName());
}

export fn zig_ai_image_response_free(response: *CImageResponse) void {
    freeString(response.job_id);
    freeString(response.original_prompt);
    freeString(response.revised_prompt);
    freeString(response.error_message);
    freeString(response.model_used);

    if (response.images.items) |items| {
        for (items[0..response.images.count]) |*img| {
            if (img.data.ptr) |p| ffi_allocator.free(p[0..img.data.len]);
            freeString(img.local_path);
            freeString(img.store_path);
            freeString(img.revised_prompt);
        }
        ffi_allocator.free(items[0..response.images.count]);
    }

    response.* = std.mem.zeroes(CImageResponse);
}

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

    const zig_config = mapMediaConfig(config);

    const result = providers.editImage(ffi_allocator, zig_request, zig_config) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };

    response_out.success = true;
    response_out.error_code = ErrorCode.SUCCESS;
    response_out.job_id = CString.fromSlice(ffi_allocator.dupe(u8, result.job_id) catch "");
    response_out.original_prompt = CString.fromSlice(ffi_allocator.dupe(u8, result.original_prompt) catch "");
    response_out.revised_prompt = if (result.revised_prompt) |rp|
        CString.fromSlice(ffi_allocator.dupe(u8, rp) catch "")
    else
        .{ .ptr = null, .len = 0 };
    response_out.processing_time_ms = result.processing_time_ms;
    response_out.model_used = CString.fromSlice(ffi_allocator.dupe(u8, result.model_used) catch "");

    if (result.images.len > 0) {
        const c_images = ffi_allocator.alloc(ffi_types.CGeneratedMedia, result.images.len) catch {
            response_out.success = false;
            response_out.error_code = ErrorCode.OUT_OF_MEMORY;
            return;
        };

        for (result.images, 0..) |img, i| {
            const img_data = ffi_allocator.dupe(u8, img.data) catch {
                response_out.success = false;
                response_out.error_code = ErrorCode.OUT_OF_MEMORY;
                return;
            };
            c_images[i] = .{
                .data = .{
                    .ptr = img_data.ptr,
                    .len = img_data.len,
                },
                .format = mapFormatToC(img.format),
                .local_path = CString.fromSlice(ffi_allocator.dupe(u8, img.local_path) catch ""),
                .store_path = CString.fromSlice(ffi_allocator.dupe(u8, img.store_path) catch ""),
                .revised_prompt = if (img.revised_prompt) |rp|
                    CString.fromSlice(ffi_allocator.dupe(u8, rp) catch "")
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
// Image Session API (simplified session-based API for cross-language FFI)
// ============================================================================

const ImageSessionInternal = struct {
    provider: media_types.ImageProvider,
    size: ?[]const u8,
    quality: ?media_types.Quality,
    style: ?media_types.Style,
    background: ?media_types.Background,
    media_config: media_types.MediaConfig,
};

export fn zig_ai_image_session_create(config: *const CImageSessionConfig) ?*CImageSession {
    const session = ffi_allocator.create(ImageSessionInternal) catch return null;

    session.* = .{
        .provider = mapImageProvider(config.provider),
        .size = if (config.size.len > 0) (ffi_allocator.dupe(u8, config.size.toSlice()) catch null) else null,
        .quality = mapQuality(config.quality),
        .style = mapStyle(config.style),
        .background = mapBackground(config.background),
        .media_config = .{
            .openai_api_key = if (config.openai_api_key.len > 0) config.openai_api_key.toSlice() else null,
            .xai_api_key = if (config.xai_api_key.len > 0) config.xai_api_key.toSlice() else null,
            .genai_api_key = if (config.genai_api_key.len > 0) config.genai_api_key.toSlice() else null,
            .vertex_project_id = if (config.vertex_project_id.len > 0) config.vertex_project_id.toSlice() else null,
            .vertex_location = if (config.vertex_location.len > 0) config.vertex_location.toSlice() else "us-central1",
            .media_store_path = null,
        },
    };

    return @ptrCast(session);
}

export fn zig_ai_image_session_destroy(session: ?*CImageSession) void {
    if (session == null) return;
    const s: *ImageSessionInternal = @ptrCast(@alignCast(session));

    if (s.size) |sz| ffi_allocator.free(sz);
    ffi_allocator.destroy(s);
}

export fn zig_ai_image_session_generate(
    session: ?*CImageSession,
    prompt: CString,
    size_override: CString,
    quality_override: ffi_types.CQuality,
    response_out: *CImageSessionResponse,
) void {
    response_out.* = std.mem.zeroes(CImageSessionResponse);

    if (session == null) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Session is null");
        return;
    }

    const s: *ImageSessionInternal = @ptrCast(@alignCast(session));
    const prompt_slice = prompt.toSlice();

    if (prompt_slice.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Prompt is empty");
        return;
    }

    if (!providers.isProviderAvailable(s.provider, s.media_config)) {
        response_out.success = false;
        response_out.error_code = ErrorCode.PROVIDER_NOT_AVAILABLE;
        response_out.error_message = makeErrorString("Provider not available - check API key");
        return;
    }

    // Use override quality if not auto, otherwise session default
    const quality = if (quality_override != .auto) mapQuality(quality_override) else s.quality;
    const size = if (size_override.len > 0) size_override.toSlice() else if (s.size) |sz| sz else null;

    const zig_request = media_types.ImageRequest{
        .prompt = prompt_slice,
        .provider = s.provider,
        .count = 1,
        .size = size,
        .aspect_ratio = null,
        .quality = quality,
        .style = s.style,
        .output_path = null,
        .background = s.background,
    };

    const result = providers.generateImage(ffi_allocator, zig_request, s.media_config) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };

    if (result.images.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.API_ERROR;
        response_out.error_message = makeErrorString("No image returned");
        return;
    }

    const img = result.images[0];

    // Encode raw image bytes to base64
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(img.data.len);
    const b64_buf = ffi_allocator.allocSentinel(u8, encoded_len, 0) catch {
        response_out.success = false;
        response_out.error_code = ErrorCode.OUT_OF_MEMORY;
        response_out.error_message = makeErrorString("Out of memory encoding base64");
        return;
    };
    _ = encoder.encode(b64_buf[0..encoded_len], img.data);

    response_out.success = true;
    response_out.error_code = ErrorCode.SUCCESS;
    response_out.image_data = .{ .ptr = b64_buf.ptr, .len = encoded_len };
    response_out.format = mapFormatToC(img.format);
    response_out.revised_prompt = if (img.revised_prompt) |rp|
        CString.fromSlice(ffi_allocator.dupe(u8, rp) catch "")
    else
        .{ .ptr = null, .len = 0 };
}

export fn zig_ai_image_session_response_free(response: *CImageSessionResponse) void {
    if (response.image_data.ptr) |p| {
        ffi_allocator.free(p[0 .. response.image_data.len + 1]); // +1 for sentinel
    }
    freeString(response.error_message);
    freeString(response.revised_prompt);
    response.* = std.mem.zeroes(CImageSessionResponse);
}

// ============================================================================
// Structured Output Template Functions
// ============================================================================

export fn zig_ai_structured_list_templates() CStringResult {
    const json = struct_templates.listTemplatesJson(ffi_allocator) catch |err| {
        return .{
            .success = false,
            .error_code = mapError(err),
            .error_message = makeErrorString(@errorName(err)),
            .value = .{ .ptr = null, .len = 0 },
        };
    };

    return .{
        .success = true,
        .error_code = ErrorCode.SUCCESS,
        .error_message = .{ .ptr = null, .len = 0 },
        .value = CString.fromSlice(json),
    };
}

export fn zig_ai_structured_get_template(name: CString) CStringResult {
    const template_name = name.toSlice();
    if (template_name.len == 0) {
        return .{
            .success = false,
            .error_code = ErrorCode.INVALID_ARGUMENT,
            .error_message = makeErrorString("Template name is empty"),
            .value = .{ .ptr = null, .len = 0 },
        };
    }

    const json = struct_templates.getTemplateJson(ffi_allocator, template_name) catch {
        return .{
            .success = false,
            .error_code = ErrorCode.INVALID_ARGUMENT,
            .error_message = makeErrorString("Structured template not found"),
            .value = .{ .ptr = null, .len = 0 },
        };
    };

    return .{
        .success = true,
        .error_code = ErrorCode.SUCCESS,
        .error_message = .{ .ptr = null, .len = 0 },
        .value = CString.fromSlice(json),
    };
}

/// Generate structured output with an arbitrary JSON schema at runtime.
/// This is the key function for orchestrator/DAG use: pass any schema,
/// get back conforming JSON. The library handles per-provider differences.
export fn zig_ai_structured_generate(
    request: *const CStructuredRequest,
    response_out: *CStructuredResponse,
) void {
    response_out.* = std.mem.zeroes(CStructuredResponse);

    const prompt_slice = request.prompt.toSlice();
    if (prompt_slice.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Prompt is empty");
        return;
    }

    const schema_json_slice = request.schema_json.toSlice();
    if (schema_json_slice.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Schema JSON is empty");
        return;
    }

    // Map CTextProvider to structured Provider
    const provider = mapStructuredProvider(request.provider) orelse {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Unsupported provider for structured output");
        return;
    };

    // Get API key: explicit > environment variable
    const api_key: []const u8 = if (request.api_key.len > 0)
        request.api_key.toSlice()
    else blk: {
        const env_var = provider.getEnvVar();
        const env_val = std.c.getenv(env_var) orelse {
            response_out.success = false;
            response_out.error_code = ErrorCode.AUTH_ERROR;
            response_out.error_message = makeErrorString("API key not set");
            return;
        };
        break :blk std.mem.span(env_val);
    };

    // Dupe schema_json to mutable []u8 (Schema requires []u8, not []const u8)
    const schema_json_owned = ffi_allocator.dupe(u8, schema_json_slice) catch {
        response_out.success = false;
        response_out.error_code = ErrorCode.OUT_OF_MEMORY;
        response_out.error_message = makeErrorString("Out of memory");
        return;
    };

    const schema_name_slice = if (request.schema_name.len > 0) request.schema_name.toSlice() else "ffi_schema";
    const schema_name_owned = ffi_allocator.dupe(u8, schema_name_slice) catch {
        ffi_allocator.free(schema_json_owned);
        response_out.success = false;
        response_out.error_code = ErrorCode.OUT_OF_MEMORY;
        response_out.error_message = makeErrorString("Out of memory");
        return;
    };

    // Build Schema on the stack (temporary, lives for duration of this call)
    var schema = structured_types.Schema{
        .name = schema_name_owned,
        .description = null,
        .schema_json = schema_json_owned,
        .allocator = ffi_allocator,
    };
    defer schema.deinit();

    const zig_request = structured_types.StructuredRequest{
        .prompt = prompt_slice,
        .schema = &schema,
        .provider = provider,
        .model = if (request.model.len > 0) request.model.toSlice() else null,
        .system_prompt = if (request.system_prompt.len > 0) request.system_prompt.toSlice() else null,
        .max_tokens = if (request.max_tokens > 0) request.max_tokens else 64000,
    };

    var result = structured_providers.generate(ffi_allocator, api_key, zig_request) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };
    defer result.deinit();

    // Dupe the json_output for the caller (result.deinit frees the original)
    const output_copy = ffi_allocator.dupeZ(u8, result.json_output) catch {
        response_out.success = false;
        response_out.error_code = ErrorCode.OUT_OF_MEMORY;
        response_out.error_message = makeErrorString("Out of memory copying output");
        return;
    };

    response_out.success = true;
    response_out.error_code = ErrorCode.SUCCESS;
    response_out.json_output = .{ .ptr = output_copy.ptr, .len = result.json_output.len };
    if (result.usage) |usage| {
        response_out.input_tokens = usage.input_tokens;
        response_out.output_tokens = usage.output_tokens;
    }
}

/// Free a structured output response
export fn zig_ai_structured_response_free(response: *CStructuredResponse) void {
    freeString(response.json_output);
    freeString(response.error_message);
    response.* = std.mem.zeroes(CStructuredResponse);
}

// ============================================================================
// Music Generation Functions
// ============================================================================

export fn zig_ai_music_generate(
    request: *const CMusicRequest,
    config: *const CMediaConfig,
    response_out: *CMusicResponse,
) void {
    response_out.* = std.mem.zeroes(CMusicResponse);

    const prompt = request.prompt.toSlice();
    if (prompt.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Prompt is empty");
        return;
    }

    const zig_provider = mapMusicProvider(request.provider);
    const zig_config = mapMediaConfig(config);

    const zig_request = media_types.MusicRequest{
        .prompt = prompt,
        .provider = zig_provider,
        .count = request.count,
        .duration_seconds = request.duration_seconds,
        .negative_prompt = if (request.negative_prompt.len > 0) request.negative_prompt.toSlice() else null,
        .seed = if (request.seed > 0) request.seed else null,
        .bpm = if (request.bpm > 0) request.bpm else null,
        .output_path = if (request.output_path.len > 0) request.output_path.toSlice() else null,
    };

    const result = providers.generateMusic(ffi_allocator, zig_request, zig_config) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };

    response_out.success = true;
    response_out.error_code = ErrorCode.SUCCESS;
    response_out.job_id = CString.fromSlice(ffi_allocator.dupe(u8, result.job_id) catch "");
    response_out.provider = request.provider;
    response_out.original_prompt = CString.fromSlice(ffi_allocator.dupe(u8, result.original_prompt) catch "");
    response_out.processing_time_ms = result.processing_time_ms;
    response_out.model_used = CString.fromSlice(ffi_allocator.dupe(u8, result.model_used) catch "");
    response_out.bpm = result.bpm orelse 0;

    if (result.tracks.len > 0) {
        const c_tracks = ffi_allocator.alloc(ffi_types.CGeneratedMedia, result.tracks.len) catch {
            response_out.success = false;
            response_out.error_code = ErrorCode.OUT_OF_MEMORY;
            return;
        };

        for (result.tracks, 0..) |track, i| {
            const track_data = ffi_allocator.dupe(u8, track.data) catch {
                response_out.success = false;
                response_out.error_code = ErrorCode.OUT_OF_MEMORY;
                return;
            };
            c_tracks[i] = .{
                .data = .{
                    .ptr = track_data.ptr,
                    .len = track_data.len,
                },
                .format = mapFormatToC(track.format),
                .local_path = CString.fromSlice(ffi_allocator.dupe(u8, track.local_path) catch ""),
                .store_path = CString.fromSlice(ffi_allocator.dupe(u8, track.store_path) catch ""),
                .revised_prompt = .{ .ptr = null, .len = 0 },
            };
        }

        response_out.tracks = .{
            .items = c_tracks.ptr,
            .count = c_tracks.len,
        };
    }
}

export fn zig_ai_music_response_free(response: *CMusicResponse) void {
    freeString(response.job_id);
    freeString(response.original_prompt);
    freeString(response.error_message);
    freeString(response.model_used);

    if (response.tracks.items) |items| {
        for (items[0..response.tracks.count]) |*track| {
            if (track.data.ptr) |p| ffi_allocator.free(p[0..track.data.len]);
            freeString(track.local_path);
            freeString(track.store_path);
        }
        ffi_allocator.free(items[0..response.tracks.count]);
    }

    response.* = std.mem.zeroes(CMusicResponse);
}

// ============================================================================
// Lyria Streaming Functions
// ============================================================================

export fn zig_ai_lyria_session_create() ?*CLyriaSession {
    const session = lyria_streaming.LyriaStream.init(ffi_allocator) catch return null;
    return @ptrCast(session);
}

export fn zig_ai_lyria_session_destroy(session: ?*CLyriaSession) void {
    if (session == null) return;
    const s: *lyria_streaming.LyriaStream = @ptrCast(@alignCast(session));
    s.deinit();
}

export fn zig_ai_lyria_connect(session: ?*CLyriaSession, api_key: CString) i32 {
    if (session == null) return ErrorCode.INVALID_ARGUMENT;
    const s: *lyria_streaming.LyriaStream = @ptrCast(@alignCast(session));

    const key = api_key.toSlice();
    if (key.len == 0) return ErrorCode.INVALID_ARGUMENT;

    s.connect(key) catch |err| {
        return mapError(err);
    };

    return ErrorCode.SUCCESS;
}

export fn zig_ai_lyria_set_prompts(
    session: ?*CLyriaSession,
    prompts: [*]const CWeightedPrompt,
    count: usize,
) i32 {
    if (session == null or count == 0) return ErrorCode.INVALID_ARGUMENT;
    const s: *lyria_streaming.LyriaStream = @ptrCast(@alignCast(session));

    var zig_prompts = ffi_allocator.alloc(lyria_streaming.WeightedPrompt, count) catch {
        return ErrorCode.OUT_OF_MEMORY;
    };
    defer ffi_allocator.free(zig_prompts);

    for (prompts[0..count], 0..) |p, i| {
        zig_prompts[i] = .{
            .text = p.text.toSlice(),
            .weight = p.weight,
        };
    }

    s.setPrompts(zig_prompts) catch |err| {
        return mapError(err);
    };

    return ErrorCode.SUCCESS;
}

export fn zig_ai_lyria_set_config(session: ?*CLyriaSession, config: *const CLyriaConfig) i32 {
    if (session == null) return ErrorCode.INVALID_ARGUMENT;
    const s: *lyria_streaming.LyriaStream = @ptrCast(@alignCast(session));

    const zig_config = lyria_streaming.MusicConfig{
        .bpm = if (config.bpm > 0) config.bpm else null,
        .temperature = config.temperature,
        .guidance = config.guidance,
        .density = if (config.density > 0) config.density else null,
        .brightness = if (config.brightness > 0) config.brightness else null,
        .mute_bass = config.mute_bass,
        .mute_drums = config.mute_drums,
        .only_bass_and_drums = config.only_bass_and_drums,
    };

    s.setConfig(zig_config) catch |err| {
        return mapError(err);
    };

    return ErrorCode.SUCCESS;
}

export fn zig_ai_lyria_play(session: ?*CLyriaSession) i32 {
    if (session == null) return ErrorCode.INVALID_ARGUMENT;
    const s: *lyria_streaming.LyriaStream = @ptrCast(@alignCast(session));
    s.play() catch |err| return mapError(err);
    return ErrorCode.SUCCESS;
}

export fn zig_ai_lyria_pause(session: ?*CLyriaSession) i32 {
    if (session == null) return ErrorCode.INVALID_ARGUMENT;
    const s: *lyria_streaming.LyriaStream = @ptrCast(@alignCast(session));
    s.pause() catch |err| return mapError(err);
    return ErrorCode.SUCCESS;
}

export fn zig_ai_lyria_stop(session: ?*CLyriaSession) i32 {
    if (session == null) return ErrorCode.INVALID_ARGUMENT;
    const s: *lyria_streaming.LyriaStream = @ptrCast(@alignCast(session));
    s.stop() catch |err| return mapError(err);
    return ErrorCode.SUCCESS;
}

export fn zig_ai_lyria_reset_context(session: ?*CLyriaSession) i32 {
    if (session == null) return ErrorCode.INVALID_ARGUMENT;
    const s: *lyria_streaming.LyriaStream = @ptrCast(@alignCast(session));
    s.resetContext() catch |err| return mapError(err);
    return ErrorCode.SUCCESS;
}

export fn zig_ai_lyria_get_audio_chunk(session: ?*CLyriaSession, buffer_out: *CBuffer) i32 {
    buffer_out.* = .{ .ptr = null, .len = 0 };

    if (session == null) return ErrorCode.INVALID_ARGUMENT;
    const s: *lyria_streaming.LyriaStream = @ptrCast(@alignCast(session));

    const chunk = s.getAudioChunk() catch |err| {
        return mapError(err);
    };

    if (chunk) |data| {
        buffer_out.ptr = data.ptr;
        buffer_out.len = data.len;
    }

    return ErrorCode.SUCCESS;
}

export fn zig_ai_lyria_is_connected(session: ?*const CLyriaSession) bool {
    if (session == null) return false;
    const s: *const lyria_streaming.LyriaStream = @ptrCast(@alignCast(session));
    return s.isConnected();
}

export fn zig_ai_lyria_get_state(session: ?*const CLyriaSession) CLyriaState {
    if (session == null) return .disconnected;
    const s: *const lyria_streaming.LyriaStream = @ptrCast(@alignCast(session));
    return mapLyriaState(s.getState());
}

export fn zig_ai_lyria_get_audio_format(session: ?*const CLyriaSession, format_out: *CAudioFormat) void {
    if (session == null) {
        format_out.* = .{ .sample_rate = 48000, .channels = 2, .bits_per_sample = 16 };
        return;
    }
    const s: *const lyria_streaming.LyriaStream = @ptrCast(@alignCast(session));
    const fmt = s.getAudioFormat();
    format_out.* = .{
        .sample_rate = fmt.sample_rate,
        .channels = fmt.channels,
        .bits_per_sample = fmt.bits_per_sample,
    };
}

export fn zig_ai_lyria_close(session: ?*CLyriaSession) void {
    if (session == null) return;
    const s: *lyria_streaming.LyriaStream = @ptrCast(@alignCast(session));
    s.close();
}

export fn zig_ai_buffer_free(buffer: CBuffer) void {
    if (buffer.ptr) |p| {
        ffi_allocator.free(p[0..buffer.len]);
    }
}

// ============================================================================
// Agent Functions
// ============================================================================

const ffi_agent = @import("ffi/agent.zig");
const ffi_orchestrator = @import("ffi/orchestrator.zig");

export fn zig_ai_agent_create(c_config: *const CAgentConfig) ?*CAgentSession {
    return ffi_agent.agentCreate(c_config);
}

export fn zig_ai_agent_destroy(session: ?*CAgentSession) void {
    ffi_agent.agentDestroy(session);
}

export fn zig_ai_agent_set_callback(session: ?*CAgentSession, cb: CAgentEventCallback, userdata: ?*anyopaque) void {
    ffi_agent.agentSetCallback(session, cb, userdata);
}

export fn zig_ai_agent_run(session: ?*CAgentSession, task: CString, result_out: *CAgentResult) void {
    ffi_agent.agentRun(session, task, result_out);
}

export fn zig_ai_agent_result_free(result: *CAgentResult) void {
    ffi_agent.agentResultFree(result);
}

// ============================================================================
// Orchestrator Functions
// ============================================================================

const COrchestratorConfig = ffi_types.COrchestratorConfig;
const COrchestratorResult = ffi_types.COrchestratorResult;
const COrchestratorEvent = ffi_types.COrchestratorEvent;
const COrchestratorEventCallback = ffi_types.COrchestratorEventCallback;

export fn zig_ai_orchestrator_run(
    config: *const COrchestratorConfig,
    goal: CString,
    callback: COrchestratorEventCallback,
    userdata: ?*anyopaque,
    result_out: *COrchestratorResult,
) void {
    ffi_orchestrator.orchestratorRun(config, goal, callback, userdata, result_out);
}

export fn zig_ai_orchestrator_run_from_plan(
    config: *const COrchestratorConfig,
    plan_json: CString,
    callback: COrchestratorEventCallback,
    userdata: ?*anyopaque,
    result_out: *COrchestratorResult,
) void {
    ffi_orchestrator.orchestratorRunFromPlan(config, plan_json, callback, userdata, result_out);
}

export fn zig_ai_orchestrator_result_free(result: *COrchestratorResult) void {
    ffi_orchestrator.orchestratorResultFree(result);
}

// ============================================================================
// Research Functions
// ============================================================================

/// Perform a web search using Gemini's google_search grounding
export fn zig_ai_research_web_search(
    query: CString,
    api_key: CString,
    model: CString,
    system_prompt: CString,
    response_out: *CResearchResponse,
) void {
    response_out.* = std.mem.zeroes(CResearchResponse);

    const query_slice = query.toSlice();
    if (query_slice.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Query is empty");
        return;
    }

    const key_slice = api_key.toSlice();
    if (key_slice.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.AUTH_ERROR;
        response_out.error_message = makeErrorString("API key is empty");
        return;
    }

    const request = research_types.ResearchRequest{
        .query = query_slice,
        .mode = .web_search,
        .model = if (model.len > 0) model.toSlice() else null,
        .system_prompt = if (system_prompt.len > 0) system_prompt.toSlice() else null,
    };

    var result = research_web.search(ffi_allocator, key_slice, request) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };
    defer result.deinit();

    fillResearchResponse(response_out, &result);
}

/// Start a deep research interaction. Returns interaction ID in content field.
export fn zig_ai_research_deep_start(
    query: CString,
    api_key: CString,
    agent_name: CString,
    response_out: *CResearchResponse,
) void {
    response_out.* = std.mem.zeroes(CResearchResponse);

    const query_slice = query.toSlice();
    if (query_slice.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Query is empty");
        return;
    }

    const key_slice = api_key.toSlice();
    if (key_slice.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.AUTH_ERROR;
        response_out.error_message = makeErrorString("API key is empty");
        return;
    }

    const agent = if (agent_name.len > 0) agent_name.toSlice() else research_deep.DEEP_RESEARCH_AGENT;

    const interaction_id = research_deep.startResearch(ffi_allocator, key_slice, query_slice, agent) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };

    // Return interaction ID in content field
    response_out.success = true;
    response_out.error_code = ErrorCode.SUCCESS;
    response_out.content = CString.fromSlice(interaction_id);
}

/// Poll a deep research interaction once. Check success to see if complete.
/// If not complete (still processing), success=false with error_code=TIMEOUT.
export fn zig_ai_research_deep_poll(
    interaction_id: CString,
    api_key: CString,
    response_out: *CResearchResponse,
) void {
    response_out.* = std.mem.zeroes(CResearchResponse);

    const id_slice = interaction_id.toSlice();
    if (id_slice.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Interaction ID is empty");
        return;
    }

    const key_slice = api_key.toSlice();
    if (key_slice.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.AUTH_ERROR;
        response_out.error_message = makeErrorString("API key is empty");
        return;
    }

    const poll_result = research_deep.pollOnce(ffi_allocator, key_slice, id_slice) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };

    switch (poll_result) {
        .completed => |resp| {
            var result = resp;
            defer result.deinit();
            fillResearchResponse(response_out, &result);
        },
        .processing => {
            response_out.success = false;
            response_out.error_code = ErrorCode.TIMEOUT; // Signal: still processing
            response_out.error_message = makeErrorString("PROCESSING");
        },
        .failed => {
            response_out.success = false;
            response_out.error_code = ErrorCode.API_ERROR;
            response_out.error_message = makeErrorString("Research failed");
        },
    }
}

/// Free a research response
export fn zig_ai_research_response_free(response: *CResearchResponse) void {
    freeString(response.content);
    freeString(response.sources_json);
    freeString(response.error_message);
    response.* = std.mem.zeroes(CResearchResponse);
}

fn fillResearchResponse(response_out: *CResearchResponse, result: *research_types.ResearchResponse) void {
    // Dupe content
    const content_copy = ffi_allocator.dupeZ(u8, result.content) catch {
        response_out.success = false;
        response_out.error_code = ErrorCode.OUT_OF_MEMORY;
        response_out.error_message = makeErrorString("Out of memory");
        return;
    };

    // Build sources JSON
    var sources_json: std.ArrayListUnmanaged(u8) = .empty;
    sources_json.appendSlice(ffi_allocator, "[") catch {
        ffi_allocator.free(content_copy);
        response_out.success = false;
        response_out.error_code = ErrorCode.OUT_OF_MEMORY;
        return;
    };

    for (result.sources, 0..) |src, idx| {
        if (idx > 0) sources_json.append(ffi_allocator, ',') catch break;
        sources_json.appendSlice(ffi_allocator, "{\"title\":\"") catch break;
        sources_json.appendSlice(ffi_allocator, src.title) catch break;
        sources_json.appendSlice(ffi_allocator, "\",\"uri\":\"") catch break;
        sources_json.appendSlice(ffi_allocator, src.uri) catch break;
        sources_json.appendSlice(ffi_allocator, "\"}") catch break;
    }
    sources_json.append(ffi_allocator, ']') catch {};

    // Null-terminate sources JSON
    const sources_slice = sources_json.toOwnedSlice(ffi_allocator) catch {
        ffi_allocator.free(content_copy);
        response_out.success = false;
        response_out.error_code = ErrorCode.OUT_OF_MEMORY;
        return;
    };
    const sources_z = ffi_allocator.dupeZ(u8, sources_slice) catch {
        ffi_allocator.free(sources_slice);
        ffi_allocator.free(content_copy);
        response_out.success = false;
        response_out.error_code = ErrorCode.OUT_OF_MEMORY;
        return;
    };
    ffi_allocator.free(sources_slice);

    response_out.success = true;
    response_out.error_code = ErrorCode.SUCCESS;
    response_out.content = .{ .ptr = content_copy.ptr, .len = result.content.len };
    response_out.sources_json = .{ .ptr = sources_z.ptr, .len = sources_z.len - 1 }; // exclude sentinel from len
    response_out.input_tokens = result.input_tokens;
    response_out.output_tokens = result.output_tokens;
}

// ============================================================================
// Search Functions (xAI Grok Web Search / X Search)
// ============================================================================

/// Perform a web search or X search using xAI Grok Responses API
export fn zig_ai_search(
    query: CString,
    api_key: CString,
    mode: CSearchMode,
    model: CString,
    instructions: CString,
    max_tokens: u32,
    response_out: *CSearchResponse,
) void {
    response_out.* = std.mem.zeroes(CSearchResponse);

    const query_slice = query.toSlice();
    if (query_slice.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Query is empty");
        return;
    }

    const key_slice = api_key.toSlice();
    if (key_slice.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.AUTH_ERROR;
        response_out.error_message = makeErrorString("API key is empty");
        return;
    }

    const search_mode: search_types.SearchMode = switch (mode) {
        .web_search => .web_search,
        .x_search => .x_search,
    };

    const request = search_types.SearchRequest{
        .query = query_slice,
        .mode = search_mode,
        .model = if (model.len > 0) model.toSlice() else null,
        .instructions = if (instructions.len > 0) instructions.toSlice() else null,
        .max_output_tokens = if (max_tokens > 0) max_tokens else 16384,
    };

    var result = search_grok.search(ffi_allocator, key_slice, request) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };
    defer result.deinit();

    fillSearchResponse(response_out, &result);
}

/// Free a search response
export fn zig_ai_search_response_free(response: *CSearchResponse) void {
    freeString(response.content);
    freeString(response.sources_json);
    freeString(response.error_message);
    freeString(response.response_id);
    response.* = std.mem.zeroes(CSearchResponse);
}

fn fillSearchResponse(response_out: *CSearchResponse, result: *search_types.SearchResponse) void {
    // Dupe content
    const content_copy = ffi_allocator.dupeZ(u8, result.content) catch {
        response_out.success = false;
        response_out.error_code = ErrorCode.OUT_OF_MEMORY;
        response_out.error_message = makeErrorString("Out of memory");
        return;
    };

    // Build sources JSON
    var sources_json: std.ArrayListUnmanaged(u8) = .empty;
    sources_json.appendSlice(ffi_allocator, "[") catch {
        ffi_allocator.free(content_copy);
        response_out.success = false;
        response_out.error_code = ErrorCode.OUT_OF_MEMORY;
        return;
    };

    for (result.sources, 0..) |src, idx| {
        if (idx > 0) sources_json.append(ffi_allocator, ',') catch break;
        sources_json.appendSlice(ffi_allocator, "{\"title\":\"") catch break;
        sources_json.appendSlice(ffi_allocator, src.title) catch break;
        sources_json.appendSlice(ffi_allocator, "\",\"uri\":\"") catch break;
        sources_json.appendSlice(ffi_allocator, src.uri) catch break;
        sources_json.appendSlice(ffi_allocator, "\"}") catch break;
    }
    sources_json.append(ffi_allocator, ']') catch {};

    const sources_slice = sources_json.toOwnedSlice(ffi_allocator) catch {
        ffi_allocator.free(content_copy);
        response_out.success = false;
        response_out.error_code = ErrorCode.OUT_OF_MEMORY;
        return;
    };
    const sources_z = ffi_allocator.dupeZ(u8, sources_slice) catch {
        ffi_allocator.free(sources_slice);
        ffi_allocator.free(content_copy);
        response_out.success = false;
        response_out.error_code = ErrorCode.OUT_OF_MEMORY;
        return;
    };
    ffi_allocator.free(sources_slice);

    // Dupe response_id
    var rid_cstr: CString = .{ .ptr = null, .len = 0 };
    if (result.response_id) |rid| {
        const rid_z = ffi_allocator.dupeZ(u8, rid) catch {
            ffi_allocator.free(content_copy);
            ffi_allocator.free(sources_z);
            response_out.success = false;
            response_out.error_code = ErrorCode.OUT_OF_MEMORY;
            return;
        };
        rid_cstr = .{ .ptr = rid_z.ptr, .len = rid.len };
    }

    response_out.success = true;
    response_out.error_code = ErrorCode.SUCCESS;
    response_out.content = .{ .ptr = content_copy.ptr, .len = result.content.len };
    response_out.sources_json = .{ .ptr = sources_z.ptr, .len = sources_z.len - 1 };
    response_out.input_tokens = result.input_tokens;
    response_out.output_tokens = result.output_tokens;
    response_out.response_id = rid_cstr;
}

// ============================================================================
// Batch API Functions (Anthropic + Gemini + OpenAI + xAI)
// ============================================================================

const batch_api_client = @import("batch_api/client.zig");
const batch_api_gemini = @import("batch_api/gemini_client.zig");
const batch_api_openai = @import("batch_api/openai_client.zig");
const batch_api_xai = @import("batch_api/xai_client.zig");
const batch_api_types = @import("batch_api/types.zig");
const CBatchApiStatus = ffi_types.CBatchApiStatus;
const CBatchApiInfo = ffi_types.CBatchApiInfo;

fn fillBatchApiInfo(out: *CBatchApiInfo, info: *batch_api_types.BatchInfo) void {
    out.success = true;
    out.error_code = ErrorCode.SUCCESS;
    out.batch_id = makeCString(info.id);
    out.processing_status = switch (info.processing_status) {
        .in_progress => .in_progress,
        .canceling => .canceling,
        .ended => .ended,
    };
    out.processing = info.request_counts.processing;
    out.succeeded = info.request_counts.succeeded;
    out.errored = info.request_counts.errored;
    out.canceled = info.request_counts.canceled;
    out.expired = info.request_counts.expired;
    out.created_at = makeCString(info.created_at);
    out.results_url = if (info.results_url) |ru| makeCString(ru) else .{ .ptr = null, .len = 0 };
}

fn makeCString(s: []const u8) ffi_types.CString {
    const duped = ffi_allocator.dupeZ(u8, s) catch return .{ .ptr = null, .len = 0 };
    return .{ .ptr = duped.ptr, .len = s.len };
}

fn batchApiError(out: *CBatchApiInfo, code: i32, msg: []const u8) void {
    out.* = std.mem.zeroes(CBatchApiInfo);
    out.success = false;
    out.error_code = code;
    out.error_message = makeErrorString(msg);
}

fn mapBatchProvider(cp: CTextProvider) batch_api_types.BatchProvider {
    return switch (cp) {
        .gemini => .gemini,
        .openai => .openai,
        .grok => .xai,
        else => .anthropic,
    };
}

/// Create a batch from JSON payload. Returns batch info.
/// For Anthropic: payload is pre-built JSONL. For Gemini: payload is pre-built JSON.
export fn zig_ai_batch_api_create(
    payload: ffi_types.CString,
    api_key: ffi_types.CString,
    provider: CTextProvider,
    result_out: *CBatchApiInfo,
) void {
    result_out.* = std.mem.zeroes(CBatchApiInfo);

    const payload_slice = payload.toSlice();
    const key_slice = api_key.toSlice();

    if (payload_slice.len == 0 or key_slice.len == 0) {
        batchApiError(result_out, ErrorCode.INVALID_ARGUMENT, "Payload and API key required");
        return;
    }

    const bp = mapBatchProvider(provider);
    var info = switch (bp) {
        .anthropic => batch_api_client.create(ffi_allocator, key_slice, payload_slice) catch |err| {
            batchApiError(result_out, ErrorCode.API_ERROR, @errorName(err));
            return;
        },
        .gemini => batch_api_gemini.createFromPayload(ffi_allocator, key_slice, payload_slice, "") catch |err| {
            batchApiError(result_out, ErrorCode.API_ERROR, @errorName(err));
            return;
        },
        .openai => batch_api_openai.createFromPayload(ffi_allocator, key_slice, payload_slice, "") catch |err| {
            batchApiError(result_out, ErrorCode.API_ERROR, @errorName(err));
            return;
        },
        .xai => batch_api_xai.createFromPayload(ffi_allocator, key_slice, payload_slice, "") catch |err| {
            batchApiError(result_out, ErrorCode.API_ERROR, @errorName(err));
            return;
        },
    };
    defer info.deinit();

    fillBatchApiInfo(result_out, &info);
}

/// Get batch status.
export fn zig_ai_batch_api_status(
    batch_id: ffi_types.CString,
    api_key: ffi_types.CString,
    provider: CTextProvider,
    result_out: *CBatchApiInfo,
) void {
    result_out.* = std.mem.zeroes(CBatchApiInfo);

    const id_slice = batch_id.toSlice();
    const key_slice = api_key.toSlice();

    if (id_slice.len == 0 or key_slice.len == 0) {
        batchApiError(result_out, ErrorCode.INVALID_ARGUMENT, "Batch ID and API key required");
        return;
    }

    const bp = mapBatchProvider(provider);
    var info = switch (bp) {
        .anthropic => batch_api_client.getStatus(ffi_allocator, key_slice, id_slice) catch |err| {
            batchApiError(result_out, ErrorCode.API_ERROR, @errorName(err));
            return;
        },
        .gemini => batch_api_gemini.getStatus(ffi_allocator, key_slice, id_slice) catch |err| {
            batchApiError(result_out, ErrorCode.API_ERROR, @errorName(err));
            return;
        },
        .openai => batch_api_openai.getStatus(ffi_allocator, key_slice, id_slice) catch |err| {
            batchApiError(result_out, ErrorCode.API_ERROR, @errorName(err));
            return;
        },
        .xai => batch_api_xai.getStatus(ffi_allocator, key_slice, id_slice) catch |err| {
            batchApiError(result_out, ErrorCode.API_ERROR, @errorName(err));
            return;
        },
    };
    defer info.deinit();

    fillBatchApiInfo(result_out, &info);
}

/// Get batch results as JSONL string. Each line is a complete JSON object with all fields:
/// custom_id, status, content, model, input_tokens, output_tokens, stop_reason,
/// error_type, error_message. Content and error strings are properly JSON-escaped.
export fn zig_ai_batch_api_results(
    batch_id: ffi_types.CString,
    api_key: ffi_types.CString,
    provider: CTextProvider,
    result_out: *ffi_types.CStringResult,
) void {
    result_out.* = std.mem.zeroes(ffi_types.CStringResult);

    const id_slice = batch_id.toSlice();
    const key_slice = api_key.toSlice();

    if (id_slice.len == 0 or key_slice.len == 0) {
        result_out.success = false;
        result_out.error_code = ErrorCode.INVALID_ARGUMENT;
        result_out.error_message = makeErrorString("Batch ID and API key required");
        return;
    }

    const bp = mapBatchProvider(provider);
    const items = switch (bp) {
        .anthropic => batch_api_client.getResults(ffi_allocator, key_slice, id_slice) catch |err| {
            result_out.success = false;
            result_out.error_code = ErrorCode.API_ERROR;
            result_out.error_message = makeErrorString(@errorName(err));
            return;
        },
        .gemini => batch_api_gemini.getResults(ffi_allocator, key_slice, id_slice) catch |err| {
            result_out.success = false;
            result_out.error_code = ErrorCode.API_ERROR;
            result_out.error_message = makeErrorString(@errorName(err));
            return;
        },
        .openai => batch_api_openai.getResults(ffi_allocator, key_slice, id_slice) catch |err| {
            result_out.success = false;
            result_out.error_code = ErrorCode.API_ERROR;
            result_out.error_message = makeErrorString(@errorName(err));
            return;
        },
        .xai => batch_api_xai.getResults(ffi_allocator, key_slice, id_slice) catch |err| {
            result_out.success = false;
            result_out.error_code = ErrorCode.API_ERROR;
            result_out.error_message = makeErrorString(@errorName(err));
            return;
        },
    };
    defer {
        for (items) |*item| item.deinit();
        ffi_allocator.free(items);
    }

    // Serialize to JSONL — full representation of every field
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (items) |item| {
        serializeBatchResultItem(&buf, &item) catch continue;
        buf.append(ffi_allocator, '\n') catch continue;
    }
    const jsonl = buf.toOwnedSlice(ffi_allocator) catch {
        result_out.success = false;
        result_out.error_code = ErrorCode.OUT_OF_MEMORY;
        return;
    };
    const jsonl_z = ffi_allocator.dupeZ(u8, jsonl) catch {
        ffi_allocator.free(jsonl);
        result_out.success = false;
        result_out.error_code = ErrorCode.OUT_OF_MEMORY;
        return;
    };
    ffi_allocator.free(jsonl);

    result_out.success = true;
    result_out.error_code = ErrorCode.SUCCESS;
    result_out.value = .{ .ptr = jsonl_z.ptr, .len = jsonl_z.len - 1 };
}

/// Cancel a batch.
export fn zig_ai_batch_api_cancel(
    batch_id: ffi_types.CString,
    api_key: ffi_types.CString,
    provider: CTextProvider,
    result_out: *CBatchApiInfo,
) void {
    result_out.* = std.mem.zeroes(CBatchApiInfo);

    const id_slice = batch_id.toSlice();
    const key_slice = api_key.toSlice();

    if (id_slice.len == 0 or key_slice.len == 0) {
        batchApiError(result_out, ErrorCode.INVALID_ARGUMENT, "Batch ID and API key required");
        return;
    }

    const bp = mapBatchProvider(provider);
    var info = switch (bp) {
        .anthropic => batch_api_client.cancel(ffi_allocator, key_slice, id_slice) catch |err| {
            batchApiError(result_out, ErrorCode.API_ERROR, @errorName(err));
            return;
        },
        .gemini => batch_api_gemini.cancel(ffi_allocator, key_slice, id_slice) catch |err| {
            batchApiError(result_out, ErrorCode.API_ERROR, @errorName(err));
            return;
        },
        .openai => batch_api_openai.cancel(ffi_allocator, key_slice, id_slice) catch |err| {
            batchApiError(result_out, ErrorCode.API_ERROR, @errorName(err));
            return;
        },
        .xai => batch_api_xai.cancel(ffi_allocator, key_slice, id_slice) catch |err| {
            batchApiError(result_out, ErrorCode.API_ERROR, @errorName(err));
            return;
        },
    };
    defer info.deinit();

    fillBatchApiInfo(result_out, &info);
}

/// List batches as JSON array string. Each object includes all batch metadata:
/// id, processing_status, request_counts (processing/succeeded/errored/canceled/expired),
/// created_at, ended_at, expires_at, results_url.
export fn zig_ai_batch_api_list(
    api_key: ffi_types.CString,
    provider: CTextProvider,
    limit: u32,
    result_out: *ffi_types.CStringResult,
) void {
    result_out.* = std.mem.zeroes(ffi_types.CStringResult);

    const key_slice = api_key.toSlice();
    if (key_slice.len == 0) {
        result_out.success = false;
        result_out.error_code = ErrorCode.INVALID_ARGUMENT;
        result_out.error_message = makeErrorString("API key required");
        return;
    }

    const bp = mapBatchProvider(provider);
    const effective_limit = if (limit == 0) @as(u32, 20) else limit;
    const batches = switch (bp) {
        .anthropic => batch_api_client.listBatches(ffi_allocator, key_slice, effective_limit) catch |err| {
            result_out.success = false;
            result_out.error_code = ErrorCode.API_ERROR;
            result_out.error_message = makeErrorString(@errorName(err));
            return;
        },
        .gemini => batch_api_gemini.listBatches(ffi_allocator, key_slice, effective_limit) catch |err| {
            result_out.success = false;
            result_out.error_code = ErrorCode.API_ERROR;
            result_out.error_message = makeErrorString(@errorName(err));
            return;
        },
        .openai => batch_api_openai.listBatches(ffi_allocator, key_slice, effective_limit) catch |err| {
            result_out.success = false;
            result_out.error_code = ErrorCode.API_ERROR;
            result_out.error_message = makeErrorString(@errorName(err));
            return;
        },
        .xai => batch_api_xai.listBatches(ffi_allocator, key_slice, effective_limit) catch |err| {
            result_out.success = false;
            result_out.error_code = ErrorCode.API_ERROR;
            result_out.error_message = makeErrorString(@errorName(err));
            return;
        },
    };
    defer {
        for (batches) |*b| b.deinit();
        ffi_allocator.free(batches);
    }

    // Serialize to JSON array — full representation of every batch
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ffi_allocator, "[") catch {};
    for (batches, 0..) |b, idx| {
        if (idx > 0) buf.append(ffi_allocator, ',') catch {};
        serializeBatchInfo(&buf, &b) catch continue;
    }
    buf.append(ffi_allocator, ']') catch {};

    const json = buf.toOwnedSlice(ffi_allocator) catch {
        result_out.success = false;
        result_out.error_code = ErrorCode.OUT_OF_MEMORY;
        return;
    };
    const json_z = ffi_allocator.dupeZ(u8, json) catch {
        ffi_allocator.free(json);
        result_out.success = false;
        result_out.error_code = ErrorCode.OUT_OF_MEMORY;
        return;
    };
    ffi_allocator.free(json);

    result_out.success = true;
    result_out.error_code = ErrorCode.SUCCESS;
    result_out.value = .{ .ptr = json_z.ptr, .len = json_z.len - 1 };
}

/// Free batch API info response.
export fn zig_ai_batch_api_info_free(info: *CBatchApiInfo) void {
    freeString(info.batch_id);
    freeString(info.error_message);
    freeString(info.created_at);
    freeString(info.results_url);
    info.* = std.mem.zeroes(CBatchApiInfo);
}

// ============================================================================
// Batch API JSON Serialization Helpers
// ============================================================================

/// Serialize a BatchResultItem to a complete JSON object in the buffer.
/// Includes all fields: custom_id, status, content, model, input_tokens,
/// output_tokens, stop_reason, error_type, error_message.
fn serializeBatchResultItem(buf: *std.ArrayListUnmanaged(u8), item: *const batch_api_types.BatchResultItem) !void {
    try buf.appendSlice(ffi_allocator, "{\"custom_id\":\"");
    try batch_api_client.escapeJsonString(ffi_allocator, buf, item.custom_id);
    try buf.appendSlice(ffi_allocator, "\",\"status\":\"");
    try buf.appendSlice(ffi_allocator, @tagName(item.result_type));
    try buf.appendSlice(ffi_allocator, "\"");

    // Content (response text for succeeded results)
    if (item.content) |content| {
        try buf.appendSlice(ffi_allocator, ",\"content\":\"");
        try batch_api_client.escapeJsonString(ffi_allocator, buf, content);
        try buf.appendSlice(ffi_allocator, "\"");
    } else {
        try buf.appendSlice(ffi_allocator, ",\"content\":null");
    }

    // Model used
    if (item.model) |model| {
        try buf.appendSlice(ffi_allocator, ",\"model\":\"");
        try batch_api_client.escapeJsonString(ffi_allocator, buf, model);
        try buf.appendSlice(ffi_allocator, "\"");
    } else {
        try buf.appendSlice(ffi_allocator, ",\"model\":null");
    }

    // Token usage
    const itok = std.fmt.allocPrint(ffi_allocator, ",\"input_tokens\":{d},\"output_tokens\":{d}", .{ item.input_tokens, item.output_tokens }) catch return error.OutOfMemory;
    defer ffi_allocator.free(itok);
    try buf.appendSlice(ffi_allocator, itok);

    // Stop reason
    if (item.stop_reason) |sr| {
        try buf.appendSlice(ffi_allocator, ",\"stop_reason\":\"");
        try batch_api_client.escapeJsonString(ffi_allocator, buf, sr);
        try buf.appendSlice(ffi_allocator, "\"");
    } else {
        try buf.appendSlice(ffi_allocator, ",\"stop_reason\":null");
    }

    // Error fields (populated for errored results)
    if (item.error_type) |et| {
        try buf.appendSlice(ffi_allocator, ",\"error_type\":\"");
        try batch_api_client.escapeJsonString(ffi_allocator, buf, et);
        try buf.appendSlice(ffi_allocator, "\"");
    } else {
        try buf.appendSlice(ffi_allocator, ",\"error_type\":null");
    }

    if (item.error_message) |em| {
        try buf.appendSlice(ffi_allocator, ",\"error_message\":\"");
        try batch_api_client.escapeJsonString(ffi_allocator, buf, em);
        try buf.appendSlice(ffi_allocator, "\"");
    } else {
        try buf.appendSlice(ffi_allocator, ",\"error_message\":null");
    }

    try buf.appendSlice(ffi_allocator, "}");
}

/// Serialize a BatchInfo to a complete JSON object in the buffer.
/// Includes all fields: id, processing_status, request_counts (processing/succeeded/
/// errored/canceled/expired), created_at, ended_at, expires_at, results_url.
fn serializeBatchInfo(buf: *std.ArrayListUnmanaged(u8), info: *const batch_api_types.BatchInfo) !void {
    try buf.appendSlice(ffi_allocator, "{\"id\":\"");
    try batch_api_client.escapeJsonString(ffi_allocator, buf, info.id);
    try buf.appendSlice(ffi_allocator, "\",\"processing_status\":\"");
    try buf.appendSlice(ffi_allocator, info.processing_status.toString());
    try buf.appendSlice(ffi_allocator, "\"");

    // Request counts as nested object
    const counts = std.fmt.allocPrint(ffi_allocator,
        ",\"request_counts\":{{\"processing\":{d},\"succeeded\":{d},\"errored\":{d},\"canceled\":{d},\"expired\":{d}}}",
        .{ info.request_counts.processing, info.request_counts.succeeded, info.request_counts.errored, info.request_counts.canceled, info.request_counts.expired },
    ) catch return error.OutOfMemory;
    defer ffi_allocator.free(counts);
    try buf.appendSlice(ffi_allocator, counts);

    // Timestamps
    try buf.appendSlice(ffi_allocator, ",\"created_at\":\"");
    try batch_api_client.escapeJsonString(ffi_allocator, buf, info.created_at);
    try buf.appendSlice(ffi_allocator, "\"");

    if (info.ended_at) |ea| {
        try buf.appendSlice(ffi_allocator, ",\"ended_at\":\"");
        try batch_api_client.escapeJsonString(ffi_allocator, buf, ea);
        try buf.appendSlice(ffi_allocator, "\"");
    } else {
        try buf.appendSlice(ffi_allocator, ",\"ended_at\":null");
    }

    try buf.appendSlice(ffi_allocator, ",\"expires_at\":\"");
    try batch_api_client.escapeJsonString(ffi_allocator, buf, info.expires_at);
    try buf.appendSlice(ffi_allocator, "\"");

    if (info.results_url) |ru| {
        try buf.appendSlice(ffi_allocator, ",\"results_url\":\"");
        try batch_api_client.escapeJsonString(ffi_allocator, buf, ru);
        try buf.appendSlice(ffi_allocator, "\"");
    } else {
        try buf.appendSlice(ffi_allocator, ",\"results_url\":null");
    }

    try buf.appendSlice(ffi_allocator, "}");
}

// ============================================================================
// Helper Functions
// ============================================================================

fn mapTextProvider(cp: CTextProvider) cli.Provider {
    return switch (cp) {
        .claude => .claude,
        .deepseek => .deepseek,
        .gemini => .gemini,
        .grok => .grok,
        .vertex => .vertex,
        .openai => .openai,
        .unknown => .claude,
    };
}

fn mapImageProvider(cp: CImageProvider) media_types.ImageProvider {
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

fn mapMusicProvider(cp: CMusicProvider) media_types.MusicProvider {
    return switch (cp) {
        .lyria => .lyria,
        .lyria_realtime => .lyria_realtime,
        .unknown => .lyria,
    };
}

fn mapQuality(cq: ffi_types.CQuality) ?media_types.Quality {
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

fn mapStyle(cs: ffi_types.CStyle) ?media_types.Style {
    return switch (cs) {
        .vivid => .vivid,
        .natural => .natural,
    };
}

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

fn mapFormatToC(f: media_types.MediaFormat) ffi_types.CMediaFormat {
    return switch (f) {
        .png => .png,
        .jpeg => .jpeg,
        .webp => .webp,
        .gif => .gif,
        .mp4 => .mp4,
        .wav => .wav,
    };
}

fn mapLyriaState(state: lyria_streaming.SessionState) CLyriaState {
    return switch (state) {
        .disconnected => .disconnected,
        .connecting => .connecting,
        .setup => .setup,
        .ready => .ready,
        .playing => .playing,
        .paused => .paused,
        .failed => .failed,
    };
}

fn mapMediaConfig(config: *const CMediaConfig) media_types.MediaConfig {
    return .{
        .openai_api_key = if (config.openai_api_key.len > 0) config.openai_api_key.toSlice() else null,
        .xai_api_key = if (config.xai_api_key.len > 0) config.xai_api_key.toSlice() else null,
        .genai_api_key = if (config.genai_api_key.len > 0) config.genai_api_key.toSlice() else null,
        .vertex_project_id = if (config.vertex_project_id.len > 0) config.vertex_project_id.toSlice() else null,
        .vertex_location = if (config.vertex_location.len > 0) config.vertex_location.toSlice() else "us-central1",
        .media_store_path = if (config.media_store_path.len > 0) config.media_store_path.toSlice() else null,
    };
}

fn mapStructuredProvider(cp: ffi_types.CTextProvider) ?structured_types.Provider {
    return switch (cp) {
        .claude => .claude,
        .deepseek => .deepseek,
        .gemini => .gemini,
        .grok => .grok,
        .openai => .openai,
        .vertex => .openai, // Vertex uses OpenAI-compatible structured output
        .unknown => null,
    };
}

fn mapError(err: anyerror) i32 {
    return switch (err) {
        error.OutOfMemory => ErrorCode.OUT_OF_MEMORY,
        error.NetworkError, error.DnsResolutionFailed, error.ConnectionRefused => ErrorCode.NETWORK_ERROR,
        error.ApiError => ErrorCode.API_ERROR,
        error.AuthError, error.WebSocketUpgradeFailed, error.AuthenticationFailed => ErrorCode.AUTH_ERROR,
        error.Timeout => ErrorCode.TIMEOUT,
        error.NotConnected => ErrorCode.NOT_CONNECTED,
        error.AlreadyConnected => ErrorCode.ALREADY_CONNECTED,
        error.SetupFailed => ErrorCode.INVALID_STATE,
        else => ErrorCode.UNKNOWN_ERROR,
    };
}

fn dupeString(s: []const u8) !?[]const u8 {
    if (s.len == 0) return null;
    return try ffi_allocator.dupe(u8, s);
}

fn makeErrorString(msg: []const u8) CString {
    const duped = ffi_allocator.dupeZ(u8, msg) catch return .{ .ptr = null, .len = 0 };
    return .{ .ptr = duped.ptr, .len = msg.len };
}

fn freeString(s: CString) void {
    if (s.ptr) |p| {
        ffi_allocator.free(p[0 .. s.len + 1]);
    }
}

// ============================================================================
// Voice Agent Functions (delegated to ffi/voice.zig)
// ============================================================================

comptime {
    _ = @import("ffi/voice.zig");
    _ = @import("ffi/tts.zig");
    _ = @import("ffi/stt.zig");
    _ = @import("ffi/files.zig");
    _ = @import("ffi/live.zig");
    _ = @import("ffi/models.zig");
    _ = @import("ffi/orchestrator.zig");
}

// ============================================================================
// Model Discovery Functions (for app dropdowns)
// ============================================================================

const ffi_models = @import("ffi/models.zig");

export fn zig_ai_get_main_model(provider: CTextProvider) CString {
    return ffi_models.getMainModelForProvider(provider);
}

export fn zig_ai_get_small_model(provider: CTextProvider) CString {
    return ffi_models.getSmallModelForProvider(provider);
}

export fn zig_ai_list_models(provider: CTextProvider) CStringResult {
    return ffi_models.listModelsForProvider(provider);
}

export fn zig_ai_free_model_string(s: CString) void {
    ffi_models.freeString(s);
}

// ============================================================================
// Tests
// ============================================================================

test {
    std.testing.refAllDecls(@This());
}
