// FFI TTS - C bindings for Text-to-Speech (OpenAI + Google)

const std = @import("std");
const types = @import("types.zig");
const http_sentinel = @import("http-sentinel");

const CString = types.CString;
const CBuffer = types.CBuffer;
const CTTSRequest = types.CTTSRequest;
const CTTSResponse = types.CTTSResponse;
const ErrorCode = types.ErrorCode;

// Global allocator for FFI
const allocator = std.heap.c_allocator;

// ============================================================================
// OpenAI TTS
// ============================================================================

/// Generate speech using OpenAI TTS API
export fn zig_ai_tts_openai(
    request: *const CTTSRequest,
    response_out: *CTTSResponse,
) void {
    response_out.* = std.mem.zeroes(CTTSResponse);

    const text = request.text.toSlice();
    if (text.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Text is empty");
        return;
    }

    // Get API key
    const api_key = getApiKey(request.api_key, "OPENAI_API_KEY") orelse {
        response_out.success = false;
        response_out.error_code = ErrorCode.AUTH_ERROR;
        response_out.error_message = makeErrorString("OPENAI_API_KEY not set");
        return;
    };

    // Parse voice (default: coral)
    const voice = if (request.voice.len > 0)
        http_sentinel.audio.Voice.fromString(request.voice.toSlice()) orelse .coral
    else
        .coral;

    // Parse model (default: gpt-4o-mini-tts)
    const model = if (request.model.len > 0)
        http_sentinel.audio.TTSModel.fromString(request.model.toSlice()) orelse .gpt_4o_mini_tts
    else
        .gpt_4o_mini_tts;

    // Parse format (default: mp3)
    const format = if (request.format.len > 0)
        http_sentinel.audio.AudioFormat.fromString(request.format.toSlice()) orelse .mp3
    else
        .mp3;

    // Speed (default: 1.0)
    const speed: f32 = if (request.speed > 0.0) request.speed else 1.0;

    // Instructions (gpt-4o-mini-tts only)
    const instructions: ?[]const u8 = if (request.instructions.len > 0) request.instructions.toSlice() else null;

    // Create client and generate speech
    var client = http_sentinel.audio.OpenAITTSClient.init(allocator, api_key) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };
    defer client.deinit();

    var result = client.speak(.{
        .text = text,
        .voice = voice,
        .model = model,
        .format = format,
        .instructions = instructions,
        .speed = speed,
    }) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };
    defer result.deinit();

    // Copy audio data for C ownership
    const audio_copy = allocator.dupe(u8, result.audio_data) catch {
        response_out.success = false;
        response_out.error_code = ErrorCode.OUT_OF_MEMORY;
        response_out.error_message = makeErrorString("Out of memory");
        return;
    };

    response_out.success = true;
    response_out.error_code = ErrorCode.SUCCESS;
    response_out.audio_data = .{ .ptr = audio_copy.ptr, .len = audio_copy.len };
    response_out.format = CString.fromSlice(format.toString());
    response_out.sample_rate = 0; // OpenAI doesn't report sample rate
}

// ============================================================================
// Google TTS
// ============================================================================

/// Generate speech using Google Gemini TTS API
export fn zig_ai_tts_google(
    request: *const CTTSRequest,
    response_out: *CTTSResponse,
) void {
    response_out.* = std.mem.zeroes(CTTSResponse);

    const text = request.text.toSlice();
    if (text.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Text is empty");
        return;
    }

    // Get API key (try GEMINI_API_KEY first, then GOOGLE_GENAI_API_KEY)
    const api_key = getApiKey(request.api_key, "GEMINI_API_KEY") orelse
        getEnvKey("GOOGLE_GENAI_API_KEY") orelse {
        response_out.success = false;
        response_out.error_code = ErrorCode.AUTH_ERROR;
        response_out.error_message = makeErrorString("GEMINI_API_KEY not set");
        return;
    };

    // Parse voice (default: kore)
    const voice_val = if (request.voice.len > 0)
        http_sentinel.audio.GoogleVoice.fromString(request.voice.toSlice()) orelse .kore
    else
        .kore;

    // Parse model (default: flash)
    const model = if (request.model.len > 0)
        http_sentinel.audio.GoogleTTSModel.fromString(request.model.toSlice()) orelse .gemini_2_5_flash_tts
    else
        .gemini_2_5_flash_tts;

    // Create client and generate speech
    var client = http_sentinel.audio.GoogleTTSClient.init(allocator, api_key) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };
    defer client.deinit();

    var result = client.speak(.{
        .text = text,
        .voice = voice_val,
        .model = model,
    }) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };
    defer result.deinit();

    // Convert PCM to WAV
    const wav_data = result.toWav(allocator) catch {
        response_out.success = false;
        response_out.error_code = ErrorCode.OUT_OF_MEMORY;
        response_out.error_message = makeErrorString("Failed to encode WAV");
        return;
    };

    response_out.success = true;
    response_out.error_code = ErrorCode.SUCCESS;
    response_out.audio_data = .{ .ptr = wav_data.ptr, .len = wav_data.len };
    response_out.format = CString.fromSlice("wav");
    response_out.sample_rate = 24000;
}

// ============================================================================
// Memory Management
// ============================================================================

/// Free a TTS response
export fn zig_ai_tts_response_free(response: *CTTSResponse) void {
    if (response.audio_data.ptr) |p| {
        allocator.free(p[0..response.audio_data.len]);
    }
    freeString(response.error_message);
    response.* = std.mem.zeroes(CTTSResponse);
}

// ============================================================================
// Internal Helpers
// ============================================================================

fn getApiKey(explicit: CString, env_var: [*:0]const u8) ?[]const u8 {
    if (explicit.len > 0) return explicit.toSlice();
    return getEnvKey(env_var);
}

fn getEnvKey(env_var: [*:0]const u8) ?[]const u8 {
    const ptr = std.c.getenv(env_var) orelse return null;
    return std.mem.span(ptr);
}

fn mapError(err: anyerror) i32 {
    return switch (err) {
        error.OutOfMemory => ErrorCode.OUT_OF_MEMORY,
        error.ConnectionRefused, error.NetworkUnreachable => ErrorCode.NETWORK_ERROR,
        error.AuthenticationFailed => ErrorCode.AUTH_ERROR,
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
