// FFI Music Generation - C bindings for music generation and streaming

const std = @import("std");
const types = @import("types.zig");
const media_types = @import("../media/types.zig");
const providers = @import("../media/providers/mod.zig");
const lyria_streaming = @import("../media/lyria_streaming.zig");

const CString = types.CString;
const CBuffer = types.CBuffer;
const CMusicProvider = types.CMusicProvider;
const CMusicRequest = types.CMusicRequest;
const CMusicResponse = types.CMusicResponse;
const CMediaConfig = types.CMediaConfig;
const CMediaArray = types.CMediaArray;
const CGeneratedMedia = types.CGeneratedMedia;
const CMediaFormat = types.CMediaFormat;
const CLyriaSession = types.CLyriaSession;
const CLyriaConfig = types.CLyriaConfig;
const CLyriaState = types.CLyriaState;
const CWeightedPrompt = types.CWeightedPrompt;
const CAudioFormat = types.CAudioFormat;
const ErrorCode = types.ErrorCode;

// Global allocator for FFI
const allocator = std.heap.c_allocator;

// ============================================================================
// Music Generation (One-shot)
// ============================================================================

/// Generate music using the specified provider
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

    // Map C types to Zig types
    const zig_provider = mapProvider(request.provider);

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

    const zig_config = mapConfig(config);

    // Generate music
    const result = providers.generateMusic(allocator, zig_request, zig_config) catch |err| {
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
    response_out.bpm = result.bpm orelse 0;

    // Copy tracks
    if (result.tracks.len > 0) {
        const c_tracks = allocator.alloc(CGeneratedMedia, result.tracks.len) catch {
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

/// Generate music with Lyria (convenience function)
export fn zig_ai_music_lyria(
    prompt: CString,
    duration_seconds: u32,
    bpm: u16,
    api_key: CString,
    response_out: *CMusicResponse,
) void {
    var request = CMusicRequest{
        .prompt = prompt,
        .provider = .lyria,
        .count = 1,
        .duration_seconds = duration_seconds,
        .negative_prompt = .{ .ptr = null, .len = 0 },
        .seed = 0,
        .bpm = bpm,
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

    zig_ai_music_generate(&request, &config, response_out);
}

// ============================================================================
// Lyria Streaming Session
// ============================================================================

/// Create a new Lyria streaming session
export fn zig_ai_lyria_session_create() ?*CLyriaSession {
    const session = lyria_streaming.LyriaStream.init(allocator) catch return null;
    return @ptrCast(session);
}

/// Destroy a Lyria streaming session
export fn zig_ai_lyria_session_destroy(session: ?*CLyriaSession) void {
    if (session == null) return;
    const s: *lyria_streaming.LyriaStream = @ptrCast(@alignCast(session));
    s.deinit();
}

/// Connect to Lyria RealTime service
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

/// Set weighted prompts for DJ-style blending
export fn zig_ai_lyria_set_prompts(
    session: ?*CLyriaSession,
    prompts: [*]const CWeightedPrompt,
    count: usize,
) i32 {
    if (session == null or count == 0) return ErrorCode.INVALID_ARGUMENT;
    const s: *lyria_streaming.LyriaStream = @ptrCast(@alignCast(session));

    // Convert to Zig type
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

/// Update music generation config
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

/// Start playback
export fn zig_ai_lyria_play(session: ?*CLyriaSession) i32 {
    if (session == null) return ErrorCode.INVALID_ARGUMENT;
    const s: *lyria_streaming.LyriaStream = @ptrCast(@alignCast(session));

    s.play() catch |err| {
        return mapError(err);
    };

    return ErrorCode.SUCCESS;
}

/// Pause playback
export fn zig_ai_lyria_pause(session: ?*CLyriaSession) i32 {
    if (session == null) return ErrorCode.INVALID_ARGUMENT;
    const s: *lyria_streaming.LyriaStream = @ptrCast(@alignCast(session));

    s.pause() catch |err| {
        return mapError(err);
    };

    return ErrorCode.SUCCESS;
}

/// Stop playback
export fn zig_ai_lyria_stop(session: ?*CLyriaSession) i32 {
    if (session == null) return ErrorCode.INVALID_ARGUMENT;
    const s: *lyria_streaming.LyriaStream = @ptrCast(@alignCast(session));

    s.stop() catch |err| {
        return mapError(err);
    };

    return ErrorCode.SUCCESS;
}

/// Reset context (required after BPM changes)
export fn zig_ai_lyria_reset_context(session: ?*CLyriaSession) i32 {
    if (session == null) return ErrorCode.INVALID_ARGUMENT;
    const s: *lyria_streaming.LyriaStream = @ptrCast(@alignCast(session));

    s.resetContext() catch |err| {
        return mapError(err);
    };

    return ErrorCode.SUCCESS;
}

/// Get next audio chunk (PCM data)
/// Returns buffer with audio data, or empty buffer if no data available
/// Caller must free the buffer with zig_ai_buffer_free
export fn zig_ai_lyria_get_audio_chunk(session: ?*CLyriaSession, buffer_out: *CBuffer) i32 {
    buffer_out.* = .{ .ptr = null, .len = 0 };

    if (session == null) return ErrorCode.INVALID_ARGUMENT;
    const s: *lyria_streaming.LyriaStream = @ptrCast(@alignCast(session));

    const chunk = s.getAudioChunk() catch |err| {
        return mapError(err);
    };

    if (chunk) |data| {
        // Data is already owned by the caller (from the Zig side)
        buffer_out.ptr = data.ptr;
        buffer_out.len = data.len;
    }

    return ErrorCode.SUCCESS;
}

/// Check if session is connected
export fn zig_ai_lyria_is_connected(session: ?*const CLyriaSession) bool {
    if (session == null) return false;
    const s: *const lyria_streaming.LyriaStream = @ptrCast(@alignCast(session));
    return s.isConnected();
}

/// Get current session state
export fn zig_ai_lyria_get_state(session: ?*const CLyriaSession) CLyriaState {
    if (session == null) return .disconnected;
    const s: *const lyria_streaming.LyriaStream = @ptrCast(@alignCast(session));
    return mapState(s.getState());
}

/// Get audio format info
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

/// Close the connection
export fn zig_ai_lyria_close(session: ?*CLyriaSession) void {
    if (session == null) return;
    const s: *lyria_streaming.LyriaStream = @ptrCast(@alignCast(session));
    s.close();
}

// ============================================================================
// Memory Management
// ============================================================================

/// Free a music response
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

/// Free a buffer allocated by this library
export fn zig_ai_buffer_free(buffer: CBuffer) void {
    if (buffer.ptr) |p| {
        allocator.free(p[0..buffer.len]);
    }
}

// ============================================================================
// Internal Helpers
// ============================================================================

fn mapProvider(cp: CMusicProvider) media_types.MusicProvider {
    return switch (cp) {
        .lyria => .lyria,
        .lyria_realtime => .lyria_realtime,
        .unknown => .lyria,
    };
}

fn mapState(state: lyria_streaming.SessionState) CLyriaState {
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
        error.NetworkError, error.DnsResolutionFailed => ErrorCode.NETWORK_ERROR,
        error.ApiError => ErrorCode.API_ERROR,
        error.AuthError, error.WebSocketUpgradeFailed => ErrorCode.AUTH_ERROR,
        error.Timeout => ErrorCode.TIMEOUT,
        error.NotConnected => ErrorCode.NOT_CONNECTED,
        error.AlreadyConnected => ErrorCode.ALREADY_CONNECTED,
        error.SetupFailed => ErrorCode.INVALID_STATE,
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
