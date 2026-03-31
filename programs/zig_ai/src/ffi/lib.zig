// FFI Library - C bindings for zig_ai
// This file is the entry point for the FFI module when built as a library

const std = @import("std");
const root = @import("root");

// Import from root lib module via build system
const cli = root.cli;
const model_costs = root.model_costs;
const batch_types = root.batch.types;
const batch_executor = root.batch.executor;
const batch_parser = root.batch.csv_parser;
const batch_writer = root.batch.writer;
const media = root.media;
const media_types = media.types;
const providers = media.providers;
const lyria_streaming = media.lyria_streaming;

// Re-export FFI types
pub const types = @import("types.zig");
const text_templates = @import("../text/templates.zig");
const struct_templates = @import("../structured/templates.zig");

// ============================================================================
// Re-export all C types
// ============================================================================

pub const CString = types.CString;
pub const CBuffer = types.CBuffer;
pub const CResult = types.CResult;
pub const CTextProvider = types.CTextProvider;
pub const CImageProvider = types.CImageProvider;
pub const CVideoProvider = types.CVideoProvider;
pub const CMusicProvider = types.CMusicProvider;
pub const CTemplateParam = types.CTemplateParam;
pub const CTextConfig = types.CTextConfig;
pub const CMediaConfig = types.CMediaConfig;
pub const CImageRequest = types.CImageRequest;
pub const CVideoRequest = types.CVideoRequest;
pub const CMusicRequest = types.CMusicRequest;
pub const CLyriaConfig = types.CLyriaConfig;
pub const CWeightedPrompt = types.CWeightedPrompt;
pub const CTextResponse = types.CTextResponse;
pub const CImageResponse = types.CImageResponse;
pub const CVideoResponse = types.CVideoResponse;
pub const CMusicResponse = types.CMusicResponse;
pub const CAudioFormat = types.CAudioFormat;
pub const CBatchRequest = types.CBatchRequest;
pub const CBatchResult = types.CBatchResult;
pub const CBatchResults = types.CBatchResults;
pub const CBatchConfig = types.CBatchConfig;
pub const CTextSession = types.CTextSession;
pub const CLyriaSession = types.CLyriaSession;
pub const CBatchExecutor = types.CBatchExecutor;
pub const ErrorCode = types.ErrorCode;

// Global allocator for FFI
const allocator = std.heap.c_allocator;

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
    model: ?[]const u8,
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
    const session = allocator.create(TextSessionInternal) catch return null;

    // Determine system prompt — template overrides, or stacks with explicit system_prompt
    var final_system_prompt: ?[]const u8 = null;

    const template_name = config.template_name.toSlice();
    if (template_name.len > 0) {
        if (text_templates.findTemplate(template_name)) |template| {
            // Build params map from C array
            var params = std.StringHashMapUnmanaged([]const u8){};
            defer params.deinit(allocator);

            if (config.template_params) |c_params| {
                for (c_params[0..config.template_param_count]) |p| {
                    const key = p.key.toSlice();
                    const value = p.value.toSlice();
                    if (key.len > 0) {
                        params.put(allocator, key, value) catch {};
                    }
                }
            }

            // Interpolate system prompt from template
            const sys_prompt = text_templates.buildSystemPrompt(allocator, template, &params) catch null;

            if (sys_prompt) |sp| {
                const explicit = config.system_prompt.toSlice();
                if (explicit.len > 0) {
                    // Stack: template prompt + explicit prompt
                    final_system_prompt = std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ sp, explicit }) catch null;
                    allocator.free(sp);
                } else {
                    final_system_prompt = sp;
                }
            }
        }
    }

    // Fall back to explicit system_prompt if no template
    if (final_system_prompt == null) {
        final_system_prompt = dupeString(config.system_prompt.toSlice()) catch null;
    }

    session.* = .{
        .provider = mapTextProvider(config.provider),
        .model = dupeString(config.model.toSlice()) catch null,
        .temperature = config.temperature,
        .max_tokens = config.max_tokens,
        .system_prompt = final_system_prompt,
        .api_key = dupeString(config.api_key.toSlice()) catch null,
        .conversation = std.ArrayList(Message).init(allocator),
    };

    return @ptrCast(session);
}

export fn zig_ai_text_session_destroy(session: ?*CTextSession) void {
    if (session == null) return;
    const s: *TextSessionInternal = @ptrCast(@alignCast(session));

    if (s.model) |m| allocator.free(m);
    if (s.system_prompt) |sp| allocator.free(sp);
    if (s.api_key) |ak| allocator.free(ak);

    for (s.conversation.items) |msg| {
        allocator.free(msg.content);
    }
    s.conversation.deinit();

    allocator.destroy(s);
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
        .model = s.model,
        .temperature = s.temperature,
        .max_tokens = s.max_tokens,
        .system_prompt = s.system_prompt,
        .api_key = s.api_key,
    };

    // Make API call
    var cli_instance = cli.CLI.init(allocator, cli_config);
    defer cli_instance.deinit();
    const result = cli_instance.sendToProvider(prompt_slice, null) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };

    // Store in conversation
    s.conversation.append(.{
        .content = allocator.dupe(u8, prompt_slice) catch "",
        .is_user = true,
    }) catch {};

    s.conversation.append(.{
        .content = allocator.dupe(u8, result.message.content) catch "",
        .is_user = false,
    }) catch {};

    // Build response
    response_out.success = true;
    response_out.error_code = ErrorCode.SUCCESS;
    response_out.content = CString.fromSlice(allocator.dupe(u8, result.message.content) catch "");
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
        allocator.free(msg.content);
    }
    s.conversation.clearRetainingCapacity();
}

export fn zig_ai_text_query(
    provider: CTextProvider,
    prompt: CString,
    api_key: CString,
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

    const zig_provider = mapTextProvider(provider);

    const cli_config = cli.CLIConfig{
        .provider = zig_provider,
        .api_key = if (api_key.len > 0) api_key.toSlice() else null,
    };

    var cli_instance = cli.CLI.init(allocator, cli_config);
    defer cli_instance.deinit();
    const result = cli_instance.sendToProvider(prompt_slice, null) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };

    response_out.success = true;
    response_out.error_code = ErrorCode.SUCCESS;
    response_out.content = CString.fromSlice(allocator.dupe(u8, result.message.content) catch "");
    response_out.usage = .{
        .input_tokens = result.usage.input_tokens,
        .output_tokens = result.usage.output_tokens,
        .total_tokens = result.usage.input_tokens + result.usage.output_tokens,
        .cost_usd = 0,
    };
    response_out.provider = provider;
}

export fn zig_ai_text_calculate_cost(
    provider: CTextProvider,
    model: CString,
    input_tokens: u32,
    output_tokens: u32,
) f64 {
    const provider_name = switch (provider) {
        .claude => "anthropic",
        .deepseek => "deepseek",
        .gemini => "google",
        .grok => "xai",
        .vertex => "google",
        .unknown => return 0,
    };

    return model_costs.calculateCost(
        provider_name,
        model.toSlice(),
        input_tokens,
        output_tokens,
    );
}

export fn zig_ai_text_default_model(provider: CTextProvider) CString {
    const zig_provider = mapTextProvider(provider);
    return CString.fromSlice(zig_provider.getDefaultModel(null));
}

export fn zig_ai_text_provider_available(provider: CTextProvider) bool {
    const zig_provider = mapTextProvider(provider);
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
// Text Template Functions
// ============================================================================

/// List all text templates as JSON array
export fn zig_ai_text_list_templates() types.CStringResult {
    const json = text_templates.listTemplatesJson(allocator) catch |err| {
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

/// Get a single text template as JSON
export fn zig_ai_text_get_template(name: CString) types.CStringResult {
    const template_name = name.toSlice();
    if (template_name.len == 0) {
        return .{
            .success = false,
            .error_code = ErrorCode.INVALID_ARGUMENT,
            .error_message = makeErrorString("Template name is empty"),
            .value = .{ .ptr = null, .len = 0 },
        };
    }

    const json = text_templates.getTemplateJson(allocator, template_name) catch {
        return .{
            .success = false,
            .error_code = ErrorCode.INVALID_ARGUMENT,
            .error_message = makeErrorString("Template not found"),
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

// ============================================================================
// Structured Output Template Functions
// ============================================================================

/// List all structured output templates as JSON array
export fn zig_ai_structured_list_templates() types.CStringResult {
    const json = struct_templates.listTemplatesJson(allocator) catch |err| {
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

/// Get a single structured output template as JSON (includes schema)
export fn zig_ai_structured_get_template(name: CString) types.CStringResult {
    const template_name = name.toSlice();
    if (template_name.len == 0) {
        return .{
            .success = false,
            .error_code = ErrorCode.INVALID_ARGUMENT,
            .error_message = makeErrorString("Template name is empty"),
            .value = .{ .ptr = null, .len = 0 },
        };
    }

    const json = struct_templates.getTemplateJson(allocator, template_name) catch {
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
    };

    const result = providers.generateImage(allocator, zig_request, zig_config) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };

    response_out.success = true;
    response_out.error_code = ErrorCode.SUCCESS;
    response_out.job_id = CString.fromSlice(allocator.dupe(u8, result.job_id) catch "");
    response_out.provider = request.provider;
    response_out.original_prompt = CString.fromSlice(allocator.dupe(u8, result.original_prompt) catch "");
    response_out.processing_time_ms = result.processing_time_ms;
    response_out.model_used = CString.fromSlice(allocator.dupe(u8, result.model_used) catch "");

    if (result.images.len > 0) {
        const c_images = allocator.alloc(types.CGeneratedMedia, result.images.len) catch {
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

export fn zig_ai_image_provider_available(provider: CImageProvider, config: *const CMediaConfig) bool {
    const zig_provider = mapImageProvider(provider);
    const zig_config = mapMediaConfig(config);
    return providers.isProviderAvailable(zig_provider, zig_config);
}

export fn zig_ai_image_provider_name(provider: CImageProvider) CString {
    const zig_provider = mapImageProvider(provider);
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

    const result = providers.generateMusic(allocator, zig_request, zig_config) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };

    response_out.success = true;
    response_out.error_code = ErrorCode.SUCCESS;
    response_out.job_id = CString.fromSlice(allocator.dupe(u8, result.job_id) catch "");
    response_out.provider = request.provider;
    response_out.original_prompt = CString.fromSlice(allocator.dupe(u8, result.original_prompt) catch "");
    response_out.processing_time_ms = result.processing_time_ms;
    response_out.model_used = CString.fromSlice(allocator.dupe(u8, result.model_used) catch "");
    response_out.bpm = result.bpm orelse 0;

    if (result.tracks.len > 0) {
        const c_tracks = allocator.alloc(types.CGeneratedMedia, result.tracks.len) catch {
            response_out.success = false;
            response_out.error_code = ErrorCode.OUT_OF_MEMORY;
            return;
        };

        for (result.tracks, 0..) |track, i| {
            c_tracks[i] = .{
                .data = .{
                    .ptr = (allocator.dupe(u8, track.data) catch &[_]u8{}).ptr,
                    .len = track.data.len,
                },
                .format = mapFormatToC(track.format),
                .local_path = CString.fromSlice(allocator.dupe(u8, track.local_path) catch ""),
                .store_path = CString.fromSlice(allocator.dupe(u8, track.store_path) catch ""),
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
            if (track.data.ptr) |p| allocator.free(p[0..track.data.len]);
            freeString(track.local_path);
            freeString(track.store_path);
        }
        allocator.free(items[0..response.tracks.count]);
    }

    response.* = std.mem.zeroes(CMusicResponse);
}

// ============================================================================
// Lyria Streaming Functions
// ============================================================================

export fn zig_ai_lyria_session_create() ?*CLyriaSession {
    const session = lyria_streaming.LyriaStream.init(allocator) catch return null;
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

    var zig_prompts = allocator.alloc(lyria_streaming.WeightedPrompt, count) catch {
        return ErrorCode.OUT_OF_MEMORY;
    };
    defer allocator.free(zig_prompts);

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

export fn zig_ai_lyria_get_state(session: ?*const CLyriaSession) types.CLyriaState {
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
        allocator.free(p[0..buffer.len]);
    }
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

fn mapQuality(cq: types.CQuality) ?media_types.Quality {
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

fn mapStyle(cs: types.CStyle) ?media_types.Style {
    return switch (cs) {
        .vivid => .vivid,
        .natural => .natural,
    };
}

fn mapFormatToC(f: media_types.MediaFormat) types.CMediaFormat {
    return switch (f) {
        .png => .png,
        .jpeg => .jpeg,
        .webp => .webp,
        .gif => .gif,
        .mp4 => .mp4,
        .wav => .wav,
    };
}

fn mapLyriaState(state: lyria_streaming.SessionState) types.CLyriaState {
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
    return config.toMediaConfig();
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
    return try allocator.dupe(u8, s);
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

// ============================================================================
// Tests
// ============================================================================

test "FFI library compiles" {
    _ = types;
}
