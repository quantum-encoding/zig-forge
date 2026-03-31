// FFI Voice Agent - C bindings for xAI Grok Voice Agent

const std = @import("std");
const types = @import("types.zig");
const voice_mod = @import("../voice/mod.zig");

const CString = types.CString;
const CBuffer = types.CBuffer;
const CVoice = types.CVoice;
const CVoiceEncoding = types.CVoiceEncoding;
const CVoiceState = types.CVoiceState;
const CVoiceConfig = types.CVoiceConfig;
const CVoiceToolCall = types.CVoiceToolCall;
const CVoiceResponse = types.CVoiceResponse;
const CVoiceSession = types.CVoiceSession;
const ErrorCode = types.ErrorCode;

// Global allocator for FFI
const allocator = std.heap.c_allocator;

// ============================================================================
// Voice Session Lifecycle
// ============================================================================

/// Create a new voice agent session
export fn zig_ai_voice_session_create() ?*CVoiceSession {
    const session = voice_mod.GrokVoiceSession.init(allocator) catch return null;
    return @ptrCast(session);
}

/// Destroy a voice agent session
export fn zig_ai_voice_session_destroy(session: ?*CVoiceSession) void {
    if (session == null) return;
    const s: *voice_mod.GrokVoiceSession = @ptrCast(@alignCast(session));
    s.deinit();
}

/// Connect to xAI Realtime API
export fn zig_ai_voice_connect(
    session: ?*CVoiceSession,
    api_key: CString,
    config: *const CVoiceConfig,
) i32 {
    if (session == null) return ErrorCode.INVALID_ARGUMENT;
    const s: *voice_mod.GrokVoiceSession = @ptrCast(@alignCast(session));

    const key = api_key.toSlice();
    if (key.len == 0) return ErrorCode.INVALID_ARGUMENT;

    const zig_config = voice_mod.SessionConfig{
        .voice = mapVoice(config.voice),
        .instructions = if (config.instructions.len > 0) config.instructions.toSlice() else null,
        .output_format = .{
            .encoding = mapEncoding(config.encoding),
            .sample_rate = if (config.sample_rate > 0) config.sample_rate else 24000,
            .channels = 1,
        },
    };

    s.connect(key, zig_config) catch |err| {
        return mapError(err);
    };

    return ErrorCode.SUCCESS;
}

/// Send text and get response
export fn zig_ai_voice_send_text(
    session: ?*CVoiceSession,
    text: CString,
    response_out: *CVoiceResponse,
) void {
    response_out.* = std.mem.zeroes(CVoiceResponse);

    if (session == null) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        response_out.error_message = makeErrorString("Session is null");
        return;
    }

    const s: *voice_mod.GrokVoiceSession = @ptrCast(@alignCast(session));
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

/// Send tool result and get next response
export fn zig_ai_voice_send_tool_result(
    session: ?*CVoiceSession,
    call_id: CString,
    output: CString,
    response_out: *CVoiceResponse,
) void {
    response_out.* = std.mem.zeroes(CVoiceResponse);

    if (session == null) {
        response_out.success = false;
        response_out.error_code = ErrorCode.INVALID_ARGUMENT;
        return;
    }

    const s: *voice_mod.GrokVoiceSession = @ptrCast(@alignCast(session));

    s.sendToolResult(call_id.toSlice(), output.toSlice()) catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };

    var result = s.collectToolResponse() catch |err| {
        response_out.success = false;
        response_out.error_code = mapError(err);
        response_out.error_message = makeErrorString(@errorName(err));
        return;
    };

    fillResponse(response_out, &result);
}

/// Get current session state
export fn zig_ai_voice_get_state(session: ?*const CVoiceSession) CVoiceState {
    if (session == null) return .disconnected;
    const s: *const voice_mod.GrokVoiceSession = @ptrCast(@alignCast(session));
    return mapState(s.getState());
}

/// Check if session is connected
export fn zig_ai_voice_is_connected(session: ?*const CVoiceSession) bool {
    if (session == null) return false;
    const s: *const voice_mod.GrokVoiceSession = @ptrCast(@alignCast(session));
    return s.isConnected();
}

/// Close the connection
export fn zig_ai_voice_close(session: ?*CVoiceSession) void {
    if (session == null) return;
    const s: *voice_mod.GrokVoiceSession = @ptrCast(@alignCast(session));
    s.close();
}

/// Free a voice response
export fn zig_ai_voice_response_free(response: *CVoiceResponse) void {
    freeString(response.transcript);
    freeString(response.error_message);

    if (response.audio_data.ptr) |p| {
        allocator.free(p[0..response.audio_data.len]);
    }

    if (response.tool_calls) |calls| {
        for (calls[0..response.tool_call_count]) |*tc| {
            freeString(tc.call_id);
            freeString(tc.name);
            freeString(tc.arguments);
        }
        allocator.free(calls[0..response.tool_call_count]);
    }

    response.* = std.mem.zeroes(CVoiceResponse);
}

// ============================================================================
// Internal Helpers
// ============================================================================

fn fillResponse(out: *CVoiceResponse, result: *voice_mod.VoiceResponse) void {
    out.success = true;
    out.error_code = ErrorCode.SUCCESS;
    out.processing_time_ms = result.processing_time_ms;

    // Transcript
    if (result.transcript.len > 0) {
        const duped = allocator.dupeZ(u8, result.transcript) catch {
            out.transcript = .{ .ptr = null, .len = 0 };
            return;
        };
        out.transcript = .{ .ptr = duped.ptr, .len = result.transcript.len };
    }

    // Audio data
    if (result.audio_data.len > 0) {
        const audio = allocator.dupe(u8, result.audio_data) catch {
            out.audio_data = .{ .ptr = null, .len = 0 };
            return;
        };
        out.audio_data = .{ .ptr = audio.ptr, .len = audio.len };
    }

    // Tool calls
    if (result.tool_calls.len > 0) {
        const c_calls = allocator.alloc(CVoiceToolCall, result.tool_calls.len) catch return;
        for (result.tool_calls, 0..) |tc, i| {
            c_calls[i] = .{
                .call_id = CString.fromSlice(allocator.dupe(u8, tc.call_id) catch ""),
                .name = CString.fromSlice(allocator.dupe(u8, tc.name) catch ""),
                .arguments = CString.fromSlice(allocator.dupe(u8, tc.arguments) catch ""),
            };
        }
        out.tool_calls = c_calls.ptr;
        out.tool_call_count = c_calls.len;
    }

    result.deinit();
}

fn mapVoice(cv: CVoice) voice_mod.Voice {
    return switch (cv) {
        .ara => .ara,
        .rex => .rex,
        .sal => .sal,
        .eve => .eve,
        .leo => .leo,
    };
}

fn mapEncoding(ce: CVoiceEncoding) voice_mod.AudioEncoding {
    return switch (ce) {
        .pcm16 => .pcm16,
        .pcmu => .pcmu,
        .pcma => .pcma,
    };
}

fn mapState(state: voice_mod.SessionState) CVoiceState {
    return switch (state) {
        .disconnected => .disconnected,
        .connecting => .connecting,
        .configuring => .configuring,
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

fn freeString(s: CString) void {
    if (s.ptr) |p| {
        allocator.free(p[0 .. s.len + 1]);
    }
}
