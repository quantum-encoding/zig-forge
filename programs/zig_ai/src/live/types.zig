// Gemini Live API Types
// Type definitions for real-time streaming sessions via WebSocket

const std = @import("std");

/// Response modality — TEXT or AUDIO (only one per session)
pub const Modality = enum {
    text,
    audio,

    pub fn toApiString(self: Modality) []const u8 {
        return switch (self) {
            .text => "TEXT",
            .audio => "AUDIO",
        };
    }

    pub fn fromString(s: []const u8) ?Modality {
        if (std.mem.eql(u8, s, "text") or std.mem.eql(u8, s, "TEXT")) return .text;
        if (std.mem.eql(u8, s, "audio") or std.mem.eql(u8, s, "AUDIO")) return .audio;
        return null;
    }
};

/// Gemini Live voice presets (same as TTS voices)
pub const GeminiVoice = enum {
    kore,
    charon,
    fenrir,
    aoede,
    puck,
    leda,
    orus,
    zephyr,

    pub fn toString(self: GeminiVoice) []const u8 {
        return switch (self) {
            .kore => "Kore",
            .charon => "Charon",
            .fenrir => "Fenrir",
            .aoede => "Aoede",
            .puck => "Puck",
            .leda => "Leda",
            .orus => "Orus",
            .zephyr => "Zephyr",
        };
    }

    pub fn fromString(s: []const u8) ?GeminiVoice {
        const lower = struct {
            fn eqi(a: []const u8, b: []const u8) bool {
                if (a.len != b.len) return false;
                for (a, b) |ca, cb| {
                    const la: u8 = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
                    const lb: u8 = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
                    if (la != lb) return false;
                }
                return true;
            }
        };
        if (lower.eqi(s, "kore")) return .kore;
        if (lower.eqi(s, "charon")) return .charon;
        if (lower.eqi(s, "fenrir")) return .fenrir;
        if (lower.eqi(s, "aoede")) return .aoede;
        if (lower.eqi(s, "puck")) return .puck;
        if (lower.eqi(s, "leda")) return .leda;
        if (lower.eqi(s, "orus")) return .orus;
        if (lower.eqi(s, "zephyr")) return .zephyr;
        return null;
    }

    pub fn description(self: GeminiVoice) []const u8 {
        return switch (self) {
            .kore => "Firm and authoritative (default)",
            .charon => "Warm and calm",
            .fenrir => "Excitable and energetic",
            .aoede => "Bright and upbeat",
            .puck => "Lively and playful",
            .leda => "Youthful and clear",
            .orus => "Firm and informative",
            .zephyr => "Breezy and conversational",
        };
    }
};

/// VAD start-of-speech sensitivity
pub const StartSensitivity = enum {
    low,
    high, // default

    pub fn toApiString(self: StartSensitivity) []const u8 {
        return switch (self) {
            .low => "START_SENSITIVITY_LOW",
            .high => "START_SENSITIVITY_HIGH",
        };
    }
};

/// VAD end-of-speech sensitivity
pub const EndSensitivity = enum {
    low,
    high, // default

    pub fn toApiString(self: EndSensitivity) []const u8 {
        return switch (self) {
            .low => "END_SENSITIVITY_LOW",
            .high => "END_SENSITIVITY_HIGH",
        };
    }
};

/// VAD configuration
pub const VadConfig = struct {
    disabled: bool = false,
    start_sensitivity: StartSensitivity = .high,
    end_sensitivity: EndSensitivity = .high,
    prefix_padding_ms: u32 = 20,
    silence_duration_ms: u32 = 100,
};

/// Live session configuration
pub const LiveConfig = struct {
    model: []const u8 = Models.FLASH_LIVE,
    modality: Modality = .text,
    system_instruction: ?[]const u8 = null,
    voice: ?GeminiVoice = null,
    vad: VadConfig = .{},
    temperature: f32 = 1.0,
    max_output_tokens: u32 = 64000,
    /// Enable context window compression for unlimited session duration
    context_compression: bool = false,
    /// Enable output audio transcription
    output_transcription: bool = false,
    /// Enable input audio transcription
    input_transcription: bool = false,
    /// Enable affective dialog (emotion-aware, native audio only)
    affective_dialog: bool = false,
    /// Enable proactive audio (model decides when to respond)
    proactive_audio: bool = false,
    /// Thinking budget (0 = disabled, >0 = token budget)
    thinking_budget: ?u32 = null,
    /// Google Search grounding
    google_search: bool = false,
};

/// Available Live API models
pub const Models = struct {
    /// Text + VAD (non-native audio)
    pub const FLASH_LIVE = "gemini-live-2.5-flash-preview";
    /// Native audio output (affective dialog, proactive audio, thinking)
    pub const FLASH_NATIVE_AUDIO = "gemini-2.5-flash-native-audio-preview-12-2025";
};

/// A function call received from the model
pub const FunctionCall = struct {
    id: []u8,
    name: []u8,
    args: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *FunctionCall) void {
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        self.allocator.free(self.args);
    }
};

/// Response from a live turn
pub const LiveResponse = struct {
    /// Model text output
    text: []u8,
    /// Audio data (raw PCM, 24kHz 16-bit mono)
    audio_data: []u8,
    /// Output transcription (if enabled)
    output_transcript: []u8,
    /// Input transcription (if enabled)
    input_transcript: []u8,
    /// Function calls (if any)
    function_calls: []FunctionCall,
    /// Processing time
    processing_time_ms: u64,
    /// Token count
    total_tokens: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *LiveResponse) void {
        if (self.text.len > 0) self.allocator.free(self.text);
        if (self.audio_data.len > 0) self.allocator.free(self.audio_data);
        if (self.output_transcript.len > 0) self.allocator.free(self.output_transcript);
        if (self.input_transcript.len > 0) self.allocator.free(self.input_transcript);
        for (self.function_calls) |*fc| fc.deinit();
        if (self.function_calls.len > 0) self.allocator.free(self.function_calls);
    }
};

/// Session state
pub const SessionState = enum {
    disconnected,
    connecting,
    setup_sent,
    ready,
    responding,
    tool_calling,
    failed,
};
