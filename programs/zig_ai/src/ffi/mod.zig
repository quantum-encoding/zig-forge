// FFI Module - C-compatible bindings for zig_ai library
//
// This module exports all functionality for use from other languages:
// - Text AI chat with multiple providers
// - Image generation (DALL-E, Grok, Imagen, Gemini)
// - Video generation (Sora, Veo)
// - Music generation (Lyria) with streaming support
// - Batch processing for text AI
//
// Build as shared library: zig build -Dlib
// Build as static library: zig build -Dlib -Dstatic

pub const types = @import("types.zig");
pub const text = @import("text.zig");
pub const image = @import("image.zig");
pub const video = @import("video.zig");
pub const music = @import("music.zig");
pub const batch = @import("batch.zig");
pub const agent = @import("agent.zig");
pub const orchestrator = @import("orchestrator.zig");
pub const voice = @import("voice.zig");
pub const tts = @import("tts.zig");
pub const stt = @import("stt.zig");
pub const files = @import("files.zig");
pub const live = @import("live.zig");

// Re-export all types
pub const CString = types.CString;
pub const CBuffer = types.CBuffer;
pub const CResult = types.CResult;
pub const CTextProvider = types.CTextProvider;
pub const CImageProvider = types.CImageProvider;
pub const CVideoProvider = types.CVideoProvider;
pub const CMusicProvider = types.CMusicProvider;
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
pub const ErrorCode = types.ErrorCode;
pub const CAgentSession = types.CAgentSession;
pub const CAgentConfig = types.CAgentConfig;
pub const CAgentEvent = types.CAgentEvent;
pub const CAgentEventType = types.CAgentEventType;
pub const CAgentResult = types.CAgentResult;
pub const CAgentEventCallback = types.CAgentEventCallback;

// Orchestrator types
pub const CTaskStatus = types.CTaskStatus;
pub const COrchestratorEventType = types.COrchestratorEventType;
pub const COrchestratorEvent = types.COrchestratorEvent;
pub const COrchestratorConfig = types.COrchestratorConfig;
pub const COrchestratorResult = types.COrchestratorResult;
pub const COrchestratorEventCallback = types.COrchestratorEventCallback;
pub const CVoiceSession = types.CVoiceSession;
pub const CVoice = types.CVoice;
pub const CVoiceEncoding = types.CVoiceEncoding;
pub const CVoiceState = types.CVoiceState;
pub const CVoiceConfig = types.CVoiceConfig;
pub const CVoiceToolCall = types.CVoiceToolCall;
pub const CVoiceResponse = types.CVoiceResponse;

// TTS types
pub const CTTSProvider = types.CTTSProvider;
pub const CTTSRequest = types.CTTSRequest;
pub const CTTSResponse = types.CTTSResponse;

// STT types
pub const CSTTRequest = types.CSTTRequest;
pub const CSTTResponse = types.CSTTResponse;

// File types
pub const CFileResponse = types.CFileResponse;

// Live types (Gemini Live real-time WebSocket)
pub const CLiveSession = types.CLiveSession;
pub const CLiveModality = types.CLiveModality;
pub const CLiveVoice = types.CLiveVoice;
pub const CLiveSessionState = types.CLiveSessionState;
pub const CLiveConfig = types.CLiveConfig;
pub const CLiveFunctionCall = types.CLiveFunctionCall;
pub const CLiveResponse = types.CLiveResponse;

pub const models = @import("models.zig");

// ============================================================================
// Library Initialization
// ============================================================================

/// Initialize the library (call once at startup)
export fn zig_ai_init() void {
    // Currently no-op, but reserved for future initialization
}

/// Shutdown the library (call before exit)
export fn zig_ai_shutdown() void {
    // Currently no-op, but reserved for future cleanup
}

/// Get library version string
export fn zig_ai_version() types.CString {
    return types.CString.fromSlice("1.0.0");
}

// ============================================================================
// Model Discovery (for app dropdowns)
// ============================================================================

/// Get main (default) model name for a text provider
/// Returns the model name string. Caller must NOT free.
export fn zig_ai_get_main_model(provider: types.CTextProvider) types.CString {
    return models.getMainModelForProvider(provider);
}

/// Get small (fast/cheap) model name for a text provider
export fn zig_ai_get_small_model(provider: types.CTextProvider) types.CString {
    return models.getSmallModelForProvider(provider);
}

/// Get available models for a text provider as JSON array string
/// Returns: '["model-1","model-2",...]'
/// Caller must free the returned string with zig_ai_free_string()
export fn zig_ai_list_models(provider: types.CTextProvider) types.CStringResult {
    return models.listModelsForProvider(provider);
}

/// Free a string returned by zig_ai_list_models
export fn zig_ai_free_string(s: types.CString) void {
    models.freeString(s);
}

// ============================================================================
// Tests
// ============================================================================

test "FFI module compiles" {
    _ = types;
    _ = text;
    _ = image;
    _ = video;
    _ = music;
    _ = batch;
    _ = agent;
    _ = orchestrator;
    _ = voice;
    _ = tts;
    _ = stt;
    _ = files;
    _ = live;
    _ = models;
}
