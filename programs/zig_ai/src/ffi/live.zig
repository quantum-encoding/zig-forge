// FFI Gemini Live - C bindings for Gemini Live real-time WebSocket streaming

const std = @import("std");
const types = @import("types.zig");
const live_mod = @import("../live/mod.zig");

const CString = types.CString;
const CBuffer = types.CBuffer;
const CLiveSession = types.CLiveSession;
const CLiveModality = types.CLiveModality;
const CLiveVoice = types.CLiveVoice;
const CLiveSessionState = types.CLiveSessionState;
const CLiveConfig = types.CLiveConfig;
const CLiveFunctionCall = types.CLiveFunctionCall;
const CLiveResponse = types.CLiveResponse;
const ErrorCode = types.ErrorCode;

// Global allocator for FFI
const allocator = std.heap.c_allocator;

// ============================================================================
// Live Session Lifecycle
// ============================================================================

/// Create a new Gemini Live session
export fn zig_ai_live_session_create() ?*CLiveSession {
    const session = live_mod.GeminiLiveSession.init(allocator) catch return null;
    return @ptrCast(session);
}

/// Destroy a Gemini Live session
export fn zig_ai_live_session_destroy(session: ?*CLiveSession) void {
    if (session == null) return;
    const s: *live_mod.GeminiLiveSession = @ptrCast(@alignCast(session));
    s.deinit();
}

/// Connect to Gemini Live API
export fn zig_ai_live_connect(
    session: ?*CLiveSession,
    api_key: CString,
    config: *const CLiveConfig,
) i32 {
    if (session == null) return ErrorCode.INVALID_ARGUMENT;
    const s: *live_mod.GeminiLiveSession = @ptrCast(@alignCast(session));

    const key = api_key.toSlice();
    if (key.len == 0) return ErrorCode.INVALID_ARGUMENT;

    const zig_config = live_mod.LiveConfig{
        .model = if (config.model.len > 0) config.model.toSlice() else live_mod.Models.FLASH_LIVE,
        .modality = mapModality(config.modality),
        .system_instruction = if (config.system_instruction.len > 0) config.system_instruction.toSlice() else null,
        .voice = mapVoice(config.voice),
        .temperature = config.temperature,
        .context_compression = config.context_compression,
        .output_transcription = config.output_transcription,
        .google_search = config.google_search,
        .thinking_budget = if (config.thinking_budget > 0) config.thinking_budget else null,
    };

    s.connect(key, zig_config) catch |err| {
        return mapError(err);
    };

    return ErrorCode.SUCCESS;
}

/// Send text and get response
export fn zig_ai_live_send_text(
    session: ?*CLiveSession,
    text: CString,
    response_out: *CLiveResponse,
) void {
    response_out.* = std.mem.zeroes(CLiveResponse);

    if (session == null) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Session is null");
        return;
    }

    const s: *live_mod.GeminiLiveSession = @ptrCast(@alignCast(session));
    const text_slice = text.toSlice();

    if (text_slice.len == 0) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Text is empty");
        return;
    }

    var result = s.sendTextAndWait(text_slice) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };

    fillResponse(response_out, &result);
}

/// Send tool responses and get next model response
export fn zig_ai_live_send_tool_response(
    session: ?*CLiveSession,
    tool_id: CString,
    tool_name: CString,
    tool_output: CString,
    response_out: *CLiveResponse,
) void {
    response_out.* = std.mem.zeroes(CLiveResponse);

    if (session == null) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        return;
    }

    const s: *live_mod.GeminiLiveSession = @ptrCast(@alignCast(session));

    const responses = [_]live_mod.ToolResponse{.{
        .id = tool_id.toSlice(),
        .name = tool_name.toSlice(),
        .output = tool_output.toSlice(),
    }};

    var result = s.sendToolResponseAndWait(&responses) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };

    fillResponse(response_out, &result);
}

/// Get current session state
export fn zig_ai_live_get_state(session: ?*const CLiveSession) CLiveSessionState {
    if (session == null) return .disconnected;
    const s: *const live_mod.GeminiLiveSession = @ptrCast(@alignCast(session));
    return mapState(s.getState());
}

/// Check if session is connected
export fn zig_ai_live_is_connected(session: ?*const CLiveSession) bool {
    if (session == null) return false;
    const s: *const live_mod.GeminiLiveSession = @ptrCast(@alignCast(session));
    return s.isConnected();
}

/// Close the connection
export fn zig_ai_live_close(session: ?*CLiveSession) void {
    if (session == null) return;
    const s: *live_mod.GeminiLiveSession = @ptrCast(@alignCast(session));
    s.close();
}

/// Free a live response
export fn zig_ai_live_response_free(response: *CLiveResponse) void {
    freeString(response.text);
    freeString(response.error_message);
    freeString(response.output_transcript);

    if (response.audio_data.ptr) |p| {
        allocator.free(p[0..response.audio_data.len]);
    }

    if (response.function_calls) |calls| {
        for (calls[0..response.function_call_count]) |*fc| {
            freeString(fc.id);
            freeString(fc.name);
            freeString(fc.args);
        }
        allocator.free(calls[0..response.function_call_count]);
    }

    response.* = std.mem.zeroes(CLiveResponse);
}

/// Get WAV audio from raw PCM data (24kHz 16-bit mono)
export fn zig_ai_live_pcm_to_wav(
    pcm_data: CBuffer,
    wav_out: *CBuffer,
) i32 {
    wav_out.* = .{ .ptr = null, .len = 0 };

    if (pcm_data.ptr == null or pcm_data.len == 0) return ErrorCode.INVALID_ARGUMENT;

    const wav = live_mod.writeWav(allocator, pcm_data.toSlice()) catch {
        return ErrorCode.OUT_OF_MEMORY;
    };

    wav_out.ptr = wav.ptr;
    wav_out.len = wav.len;
    return ErrorCode.SUCCESS;
}

// ============================================================================
// Internal Helpers
// ============================================================================

fn fillResponse(out: *CLiveResponse, result: *live_mod.LiveResponse) void {
    out.success = true;
    out.error_code = ErrorCode.SUCCESS;
    out.processing_time_ms = result.processing_time_ms;
    out.total_tokens = result.total_tokens;

    // Text
    if (result.text.len > 0) {
        const duped = allocator.dupeZ(u8, result.text) catch {
            out.text = .{ .ptr = null, .len = 0 };
            result.deinit();
            return;
        };
        out.text = .{ .ptr = duped.ptr, .len = result.text.len };
    }

    // Audio data
    if (result.audio_data.len > 0) {
        const audio = allocator.dupe(u8, result.audio_data) catch {
            out.audio_data = .{ .ptr = null, .len = 0 };
            result.deinit();
            return;
        };
        out.audio_data = .{ .ptr = audio.ptr, .len = audio.len };
    }

    // Output transcription
    if (result.output_transcript.len > 0) {
        const duped = allocator.dupeZ(u8, result.output_transcript) catch {
            out.output_transcript = .{ .ptr = null, .len = 0 };
            result.deinit();
            return;
        };
        out.output_transcript = .{ .ptr = duped.ptr, .len = result.output_transcript.len };
    }

    // Function calls
    if (result.function_calls.len > 0) {
        const c_calls = allocator.alloc(CLiveFunctionCall, result.function_calls.len) catch {
            result.deinit();
            return;
        };
        for (result.function_calls, 0..) |fc, i| {
            c_calls[i] = .{
                .id = makeCString(fc.id),
                .name = makeCString(fc.name),
                .args = makeCString(fc.args),
            };
        }
        out.function_calls = c_calls.ptr;
        out.function_call_count = c_calls.len;
    }

    result.deinit();
}

fn mapModality(cm: CLiveModality) live_mod.Modality {
    return switch (cm) {
        .text => .text,
        .audio => .audio,
    };
}

fn mapVoice(cv: CLiveVoice) ?live_mod.GeminiVoice {
    return switch (cv) {
        .none => null,
        .kore => .kore,
        .charon => .charon,
        .fenrir => .fenrir,
        .aoede => .aoede,
        .puck => .puck,
        .leda => .leda,
        .orus => .orus,
        .zephyr => .zephyr,
    };
}

fn mapState(state: live_mod.SessionState) CLiveSessionState {
    return switch (state) {
        .disconnected => .disconnected,
        .connecting => .connecting,
        .setup_sent => .setup_sent,
        .ready => .ready,
        .responding => .responding,
        .tool_calling => .tool_calling,
        .failed => .failed,
    };
}

fn mapError(err: anyerror) i32 {
    return switch (err) {
        error.OutOfMemory => ErrorCode.OUT_OF_MEMORY,
        error.DnsResolutionFailed => ErrorCode.NETWORK_ERROR,
        error.WebSocketUpgradeFailed => ErrorCode.AUTH_ERROR,
        error.NotConnected => ErrorCode.NOT_CONNECTED,
        error.AlreadyConnected => ErrorCode.ALREADY_CONNECTED,
        error.SetupFailed => ErrorCode.INVALID_STATE,
        error.ConnectionClosed => ErrorCode.NOT_CONNECTED,
        else => ErrorCode.UNKNOWN_ERROR,
    };
}

fn makeErrorString(msg: []const u8) CString {
    const duped = allocator.dupeZ(u8, msg) catch return .{ .ptr = null, .len = 0 };
    return .{ .ptr = duped.ptr, .len = msg.len };
}

fn makeCString(s: []const u8) CString {
    if (s.len == 0) return .{ .ptr = null, .len = 0 };
    const duped = allocator.dupeZ(u8, s) catch return .{ .ptr = null, .len = 0 };
    return .{ .ptr = duped.ptr, .len = s.len };
}

fn freeString(s: CString) void {
    if (s.ptr) |p| {
        allocator.free(p[0 .. s.len + 1]);
    }
}
