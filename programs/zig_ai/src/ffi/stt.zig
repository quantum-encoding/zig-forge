// FFI STT - C bindings for Speech-to-Text (OpenAI Whisper / GPT-4o)

const std = @import("std");
const types = @import("types.zig");
const http_sentinel = @import("http-sentinel");

const CString = types.CString;
const CBuffer = types.CBuffer;
const CSTTRequest = types.CSTTRequest;
const CSTTResponse = types.CSTTResponse;
const ErrorCode = types.ErrorCode;

// Global allocator for FFI
const allocator = std.heap.c_allocator;

// ============================================================================
// OpenAI STT (Transcription + Translation)
// ============================================================================

/// Transcribe audio using OpenAI STT API
export fn zig_ai_stt_openai(
    request: *const CSTTRequest,
    response_out: *CSTTResponse,
) void {
    response_out.* = std.mem.zeroes(CSTTResponse);

    const audio_data = request.audio_data.toSlice();
    if (audio_data.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Audio data is empty");
        return;
    }

    // 25 MB limit
    if (audio_data.len > 25 * 1024 * 1024) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Audio file exceeds 25 MB limit");
        return;
    }

    // Get API key
    const api_key = getApiKey(request.api_key, "OPENAI_API_KEY") orelse {
        response_out.success = false;
        response_out.error_code = ErrorCode.AUTH_ERROR;
        response_out.error_message = makeErrorString("OPENAI_API_KEY not set");
        return;
    };

    // Parse model (default: gpt-4o-mini-transcribe)
    const model = if (request.model.len > 0)
        http_sentinel.audio.STTModel.fromString(request.model.toSlice()) orelse .gpt_4o_mini_transcribe
    else
        .gpt_4o_mini_transcribe;

    // Parse response format (default: text)
    const response_format = if (request.response_format.len > 0)
        http_sentinel.audio.STTResponseFormat.fromString(request.response_format.toSlice()) orelse .text
    else
        .text;

    // Filename (default: audio.mp3)
    const filename = if (request.filename.len > 0) request.filename.toSlice() else "audio.mp3";

    // Optional fields
    const language: ?[]const u8 = if (request.language.len > 0) request.language.toSlice() else null;
    const prompt: ?[]const u8 = if (request.prompt.len > 0) request.prompt.toSlice() else null;

    // Create client
    var client = http_sentinel.audio.OpenAISTTClient.init(allocator, api_key) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };
    defer client.deinit();

    // Call transcribe or translate
    var result = if (request.translate)
        client.translate(audio_data) catch |err| {
            response_out.success = false;
            response_out.error_code = mapError(err);
            response_out.error_message = makeErrorString(@errorName(err));
            return;
        }
    else
        client.transcribe(.{
            .audio_data = audio_data,
            .filename = filename,
            .model = model,
            .response_format = response_format,
            .language = language,
            .prompt = prompt,
        }) catch |err| {
            response_out.success = false;
            response_out.error_code = mapError(err);
            response_out.error_message = makeErrorString(@errorName(err));
            return;
        };
    defer result.deinit();

    // Copy text for C ownership
    const text_copy = allocator.dupeZ(u8, result.text) catch {
        response_out.success = false;
        response_out.error_code = ErrorCode.OUT_OF_MEMORY;
        response_out.error_message = makeErrorString("Out of memory");
        return;
    };

    response_out.success = true;
    response_out.error_code = ErrorCode.SUCCESS;
    response_out.text = .{ .ptr = text_copy.ptr, .len = result.text.len };

    if (result.language) |lang| {
        const lang_copy = allocator.dupeZ(u8, lang) catch null;
        if (lang_copy) |lc| {
            response_out.language = .{ .ptr = lc.ptr, .len = lang.len };
        }
    }

    if (result.duration) |dur| {
        response_out.duration = dur;
    }
}

// ============================================================================
// Memory Management
// ============================================================================

/// Free an STT response
export fn zig_ai_stt_response_free(response: *CSTTResponse) void {
    freeString(response.text);
    freeString(response.language);
    freeString(response.error_message);
    response.* = std.mem.zeroes(CSTTResponse);
}

// ============================================================================
// Internal Helpers
// ============================================================================

fn getApiKey(explicit: CString, env_var: [*:0]const u8) ?[]const u8 {
    if (explicit.len > 0) return explicit.toSlice();
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
