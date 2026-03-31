// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Common types for audio/TTS functionality

const std = @import("std");

/// OpenAI TTS voices
pub const Voice = enum {
    alloy,
    ash,
    ballad,
    coral,
    echo,
    fable,
    nova,
    onyx,
    sage,
    shimmer,
    verse,
    marin,
    cedar,

    pub fn toString(self: Voice) []const u8 {
        return switch (self) {
            .alloy => "alloy",
            .ash => "ash",
            .ballad => "ballad",
            .coral => "coral",
            .echo => "echo",
            .fable => "fable",
            .nova => "nova",
            .onyx => "onyx",
            .sage => "sage",
            .shimmer => "shimmer",
            .verse => "verse",
            .marin => "marin",
            .cedar => "cedar",
        };
    }

    pub fn fromString(s: []const u8) ?Voice {
        const voices = [_]struct { name: []const u8, voice: Voice }{
            .{ .name = "alloy", .voice = .alloy },
            .{ .name = "ash", .voice = .ash },
            .{ .name = "ballad", .voice = .ballad },
            .{ .name = "coral", .voice = .coral },
            .{ .name = "echo", .voice = .echo },
            .{ .name = "fable", .voice = .fable },
            .{ .name = "nova", .voice = .nova },
            .{ .name = "onyx", .voice = .onyx },
            .{ .name = "sage", .voice = .sage },
            .{ .name = "shimmer", .voice = .shimmer },
            .{ .name = "verse", .voice = .verse },
            .{ .name = "marin", .voice = .marin },
            .{ .name = "cedar", .voice = .cedar },
        };
        for (voices) |v| {
            if (std.mem.eql(u8, s, v.name)) return v.voice;
        }
        return null;
    }
};

/// Audio output formats
pub const AudioFormat = enum {
    mp3,
    opus,
    aac,
    flac,
    wav,
    pcm,

    pub fn toString(self: AudioFormat) []const u8 {
        return switch (self) {
            .mp3 => "mp3",
            .opus => "opus",
            .aac => "aac",
            .flac => "flac",
            .wav => "wav",
            .pcm => "pcm",
        };
    }

    pub fn fromString(s: []const u8) ?AudioFormat {
        if (std.mem.eql(u8, s, "mp3")) return .mp3;
        if (std.mem.eql(u8, s, "opus")) return .opus;
        if (std.mem.eql(u8, s, "aac")) return .aac;
        if (std.mem.eql(u8, s, "flac")) return .flac;
        if (std.mem.eql(u8, s, "wav")) return .wav;
        if (std.mem.eql(u8, s, "pcm")) return .pcm;
        return null;
    }

    pub fn fileExtension(self: AudioFormat) []const u8 {
        return switch (self) {
            .mp3 => ".mp3",
            .opus => ".opus",
            .aac => ".aac",
            .flac => ".flac",
            .wav => ".wav",
            .pcm => ".pcm",
        };
    }

    pub fn mimeType(self: AudioFormat) []const u8 {
        return switch (self) {
            .mp3 => "audio/mpeg",
            .opus => "audio/opus",
            .aac => "audio/aac",
            .flac => "audio/flac",
            .wav => "audio/wav",
            .pcm => "audio/pcm",
        };
    }
};

/// TTS models
pub const TTSModel = enum {
    gpt_4o_mini_tts, // Controllable with instructions
    tts_1, // Standard quality
    tts_1_hd, // High definition

    pub fn toString(self: TTSModel) []const u8 {
        return switch (self) {
            .gpt_4o_mini_tts => "gpt-4o-mini-tts",
            .tts_1 => "tts-1",
            .tts_1_hd => "tts-1-hd",
        };
    }

    pub fn fromString(s: []const u8) ?TTSModel {
        if (std.mem.eql(u8, s, "gpt-4o-mini-tts")) return .gpt_4o_mini_tts;
        if (std.mem.eql(u8, s, "tts-1")) return .tts_1;
        if (std.mem.eql(u8, s, "tts-1-hd")) return .tts_1_hd;
        return null;
    }

    /// Returns true if the model supports the instructions parameter
    pub fn supportsInstructions(self: TTSModel) bool {
        return self == .gpt_4o_mini_tts;
    }
};

/// TTS request configuration
pub const TTSRequest = struct {
    text: []const u8,
    model: TTSModel = .gpt_4o_mini_tts,
    voice: Voice = .coral,
    format: AudioFormat = .mp3,
    instructions: ?[]const u8 = null, // Only for gpt-4o-mini-tts
    speed: f32 = 1.0, // 0.25 to 4.0
};

/// TTS response
pub const TTSResponse = struct {
    audio_data: []u8,
    format: AudioFormat,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TTSResponse) void {
        self.allocator.free(self.audio_data);
    }
};

/// TTS errors
pub const TTSError = error{
    InvalidApiKey,
    RateLimitExceeded,
    InvalidRequest,
    ServerError,
    NetworkError,
    InvalidResponse,
    TextTooLong,
    UnsupportedVoice,
};

test "Voice fromString" {
    try std.testing.expectEqual(Voice.coral, Voice.fromString("coral").?);
    try std.testing.expectEqual(Voice.marin, Voice.fromString("marin").?);
    try std.testing.expect(Voice.fromString("invalid") == null);
}

test "AudioFormat" {
    try std.testing.expectEqualStrings(".mp3", AudioFormat.mp3.fileExtension());
    try std.testing.expectEqualStrings("audio/wav", AudioFormat.wav.mimeType());
}

test "TTSModel supportsInstructions" {
    try std.testing.expect(TTSModel.gpt_4o_mini_tts.supportsInstructions());
    try std.testing.expect(!TTSModel.tts_1.supportsInstructions());
}

// ============================================================
// Speech-to-Text (STT) Types
// ============================================================

/// STT models
pub const STTModel = enum {
    whisper_1, // Original Whisper model
    gpt_4o_transcribe, // Higher quality
    gpt_4o_mini_transcribe, // Faster
    gpt_4o_transcribe_diarize, // Speaker diarization

    pub fn toString(self: STTModel) []const u8 {
        return switch (self) {
            .whisper_1 => "whisper-1",
            .gpt_4o_transcribe => "gpt-4o-transcribe",
            .gpt_4o_mini_transcribe => "gpt-4o-mini-transcribe",
            .gpt_4o_transcribe_diarize => "gpt-4o-transcribe-diarize",
        };
    }

    pub fn fromString(s: []const u8) ?STTModel {
        if (std.mem.eql(u8, s, "whisper-1") or std.mem.eql(u8, s, "whisper")) return .whisper_1;
        if (std.mem.eql(u8, s, "gpt-4o-transcribe")) return .gpt_4o_transcribe;
        if (std.mem.eql(u8, s, "gpt-4o-mini-transcribe")) return .gpt_4o_mini_transcribe;
        if (std.mem.eql(u8, s, "gpt-4o-transcribe-diarize")) return .gpt_4o_transcribe_diarize;
        return null;
    }

    /// Returns true if the model supports timestamps
    pub fn supportsTimestamps(self: STTModel) bool {
        return self == .whisper_1;
    }

    /// Returns true if the model supports prompting
    pub fn supportsPrompt(self: STTModel) bool {
        return self != .gpt_4o_transcribe_diarize;
    }
};

/// STT response format
pub const STTResponseFormat = enum {
    json,
    text,
    srt, // whisper-1 only
    verbose_json, // whisper-1 only
    vtt, // whisper-1 only
    diarized_json, // gpt-4o-transcribe-diarize only

    pub fn toString(self: STTResponseFormat) []const u8 {
        return switch (self) {
            .json => "json",
            .text => "text",
            .srt => "srt",
            .verbose_json => "verbose_json",
            .vtt => "vtt",
            .diarized_json => "diarized_json",
        };
    }

    pub fn fromString(s: []const u8) ?STTResponseFormat {
        if (std.mem.eql(u8, s, "json")) return .json;
        if (std.mem.eql(u8, s, "text")) return .text;
        if (std.mem.eql(u8, s, "srt")) return .srt;
        if (std.mem.eql(u8, s, "verbose_json")) return .verbose_json;
        if (std.mem.eql(u8, s, "vtt")) return .vtt;
        if (std.mem.eql(u8, s, "diarized_json")) return .diarized_json;
        return null;
    }
};

/// Supported audio input formats
pub const AudioInputFormat = enum {
    mp3,
    mp4,
    mpeg,
    mpga,
    m4a,
    wav,
    webm,

    pub fn fromExtension(ext: []const u8) ?AudioInputFormat {
        if (std.mem.eql(u8, ext, ".mp3") or std.mem.eql(u8, ext, "mp3")) return .mp3;
        if (std.mem.eql(u8, ext, ".mp4") or std.mem.eql(u8, ext, "mp4")) return .mp4;
        if (std.mem.eql(u8, ext, ".mpeg") or std.mem.eql(u8, ext, "mpeg")) return .mpeg;
        if (std.mem.eql(u8, ext, ".mpga") or std.mem.eql(u8, ext, "mpga")) return .mpga;
        if (std.mem.eql(u8, ext, ".m4a") or std.mem.eql(u8, ext, "m4a")) return .m4a;
        if (std.mem.eql(u8, ext, ".wav") or std.mem.eql(u8, ext, "wav")) return .wav;
        if (std.mem.eql(u8, ext, ".webm") or std.mem.eql(u8, ext, "webm")) return .webm;
        return null;
    }

    pub fn mimeType(self: AudioInputFormat) []const u8 {
        return switch (self) {
            .mp3 => "audio/mpeg",
            .mp4 => "video/mp4",
            .mpeg => "audio/mpeg",
            .mpga => "audio/mpeg",
            .m4a => "audio/mp4",
            .wav => "audio/wav",
            .webm => "audio/webm",
        };
    }
};

/// STT request configuration
pub const STTRequest = struct {
    audio_data: []const u8,
    filename: []const u8 = "audio.mp3",
    model: STTModel = .gpt_4o_mini_transcribe,
    response_format: STTResponseFormat = .text,
    language: ?[]const u8 = null, // ISO-639-1 code
    prompt: ?[]const u8 = null, // Context hint
    temperature: f32 = 0.0, // 0.0 to 1.0
};

/// STT response
pub const STTResponse = struct {
    text: []u8,
    language: ?[]u8 = null,
    duration: ?f64 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *STTResponse) void {
        self.allocator.free(self.text);
        if (self.language) |lang| self.allocator.free(lang);
    }
};

/// STT errors
pub const STTError = error{
    InvalidApiKey,
    RateLimitExceeded,
    InvalidRequest,
    ServerError,
    NetworkError,
    InvalidResponse,
    FileTooLarge,
    UnsupportedFormat,
};

test "STTModel" {
    try std.testing.expectEqual(STTModel.whisper_1, STTModel.fromString("whisper-1").?);
    try std.testing.expect(STTModel.whisper_1.supportsTimestamps());
    try std.testing.expect(!STTModel.gpt_4o_transcribe.supportsTimestamps());
}

// ============================================================
// Google Gemini TTS Types
// ============================================================

/// Google Gemini TTS voices (30 voices)
pub const GoogleVoice = enum {
    // Row 1
    zephyr, // Bright
    puck, // Upbeat
    charon, // Informative
    // Row 2
    kore, // Firm
    fenrir, // Excitable
    leda, // Youthful
    // Row 3
    orus, // Firm
    aoede, // Breezy
    callirrhoe, // Easy-going
    // Row 4
    autonoe, // Bright
    enceladus, // Breathy
    iapetus, // Clear
    // Row 5
    umbriel, // Easy-going
    algieba, // Smooth
    despina, // Smooth
    // Row 6
    erinome, // Clear
    algenib, // Gravelly
    rasalgethi, // Informative
    // Row 7
    laomedeia, // Upbeat
    achernar, // Soft
    alnilam, // Firm
    // Row 8
    schedar, // Even
    gacrux, // Mature
    pulcherrima, // Forward
    // Row 9
    achird, // Friendly
    zubenelgenubi, // Casual
    vindemiatrix, // Gentle
    // Row 10
    sadachbia, // Lively
    sadaltager, // Knowledgeable
    sulafat, // Warm

    pub fn toString(self: GoogleVoice) []const u8 {
        return switch (self) {
            .zephyr => "Zephyr",
            .puck => "Puck",
            .charon => "Charon",
            .kore => "Kore",
            .fenrir => "Fenrir",
            .leda => "Leda",
            .orus => "Orus",
            .aoede => "Aoede",
            .callirrhoe => "Callirrhoe",
            .autonoe => "Autonoe",
            .enceladus => "Enceladus",
            .iapetus => "Iapetus",
            .umbriel => "Umbriel",
            .algieba => "Algieba",
            .despina => "Despina",
            .erinome => "Erinome",
            .algenib => "Algenib",
            .rasalgethi => "Rasalgethi",
            .laomedeia => "Laomedeia",
            .achernar => "Achernar",
            .alnilam => "Alnilam",
            .schedar => "Schedar",
            .gacrux => "Gacrux",
            .pulcherrima => "Pulcherrima",
            .achird => "Achird",
            .zubenelgenubi => "Zubenelgenubi",
            .vindemiatrix => "Vindemiatrix",
            .sadachbia => "Sadachbia",
            .sadaltager => "Sadaltager",
            .sulafat => "Sulafat",
        };
    }

    pub fn fromString(s: []const u8) ?GoogleVoice {
        const voices = [_]struct { name: []const u8, voice: GoogleVoice }{
            .{ .name = "zephyr", .voice = .zephyr },
            .{ .name = "puck", .voice = .puck },
            .{ .name = "charon", .voice = .charon },
            .{ .name = "kore", .voice = .kore },
            .{ .name = "fenrir", .voice = .fenrir },
            .{ .name = "leda", .voice = .leda },
            .{ .name = "orus", .voice = .orus },
            .{ .name = "aoede", .voice = .aoede },
            .{ .name = "callirrhoe", .voice = .callirrhoe },
            .{ .name = "autonoe", .voice = .autonoe },
            .{ .name = "enceladus", .voice = .enceladus },
            .{ .name = "iapetus", .voice = .iapetus },
            .{ .name = "umbriel", .voice = .umbriel },
            .{ .name = "algieba", .voice = .algieba },
            .{ .name = "despina", .voice = .despina },
            .{ .name = "erinome", .voice = .erinome },
            .{ .name = "algenib", .voice = .algenib },
            .{ .name = "rasalgethi", .voice = .rasalgethi },
            .{ .name = "laomedeia", .voice = .laomedeia },
            .{ .name = "achernar", .voice = .achernar },
            .{ .name = "alnilam", .voice = .alnilam },
            .{ .name = "schedar", .voice = .schedar },
            .{ .name = "gacrux", .voice = .gacrux },
            .{ .name = "pulcherrima", .voice = .pulcherrima },
            .{ .name = "achird", .voice = .achird },
            .{ .name = "zubenelgenubi", .voice = .zubenelgenubi },
            .{ .name = "vindemiatrix", .voice = .vindemiatrix },
            .{ .name = "sadachbia", .voice = .sadachbia },
            .{ .name = "sadaltager", .voice = .sadaltager },
            .{ .name = "sulafat", .voice = .sulafat },
        };
        // Case-insensitive match
        for (voices) |v| {
            if (std.ascii.eqlIgnoreCase(s, v.name)) return v.voice;
        }
        return null;
    }

    /// Voice description/style
    pub fn description(self: GoogleVoice) []const u8 {
        return switch (self) {
            .zephyr => "Bright",
            .puck => "Upbeat",
            .charon => "Informative",
            .kore => "Firm",
            .fenrir => "Excitable",
            .leda => "Youthful",
            .orus => "Firm",
            .aoede => "Breezy",
            .callirrhoe => "Easy-going",
            .autonoe => "Bright",
            .enceladus => "Breathy",
            .iapetus => "Clear",
            .umbriel => "Easy-going",
            .algieba => "Smooth",
            .despina => "Smooth",
            .erinome => "Clear",
            .algenib => "Gravelly",
            .rasalgethi => "Informative",
            .laomedeia => "Upbeat",
            .achernar => "Soft",
            .alnilam => "Firm",
            .schedar => "Even",
            .gacrux => "Mature",
            .pulcherrima => "Forward",
            .achird => "Friendly",
            .zubenelgenubi => "Casual",
            .vindemiatrix => "Gentle",
            .sadachbia => "Lively",
            .sadaltager => "Knowledgeable",
            .sulafat => "Warm",
        };
    }
};

/// Google TTS models
pub const GoogleTTSModel = enum {
    gemini_2_5_flash_tts, // Faster
    gemini_2_5_pro_tts, // Higher quality

    pub fn toString(self: GoogleTTSModel) []const u8 {
        return switch (self) {
            .gemini_2_5_flash_tts => "gemini-2.5-flash-preview-tts",
            .gemini_2_5_pro_tts => "gemini-2.5-pro-preview-tts",
        };
    }

    pub fn fromString(s: []const u8) ?GoogleTTSModel {
        if (std.mem.eql(u8, s, "gemini-2.5-flash-preview-tts") or
            std.mem.eql(u8, s, "flash") or
            std.mem.eql(u8, s, "2.5-flash"))
        {
            return .gemini_2_5_flash_tts;
        }
        if (std.mem.eql(u8, s, "gemini-2.5-pro-preview-tts") or
            std.mem.eql(u8, s, "pro") or
            std.mem.eql(u8, s, "2.5-pro"))
        {
            return .gemini_2_5_pro_tts;
        }
        return null;
    }
};

/// Speaker configuration for multi-speaker TTS
pub const SpeakerConfig = struct {
    name: []const u8,
    voice: GoogleVoice,
};

/// Google TTS request configuration
pub const GoogleTTSRequest = struct {
    text: []const u8,
    model: GoogleTTSModel = .gemini_2_5_flash_tts,
    voice: GoogleVoice = .kore,
    // Multi-speaker support (up to 2 speakers)
    speakers: ?[]const SpeakerConfig = null,
};

/// Google TTS response (PCM audio data)
pub const GoogleTTSResponse = struct {
    audio_data: []u8, // Raw PCM: 24kHz, 16-bit LE, mono
    sample_rate: u32 = 24000,
    channels: u8 = 1,
    bits_per_sample: u8 = 16,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GoogleTTSResponse) void {
        self.allocator.free(self.audio_data);
    }

    /// Convert PCM to WAV format
    pub fn toWav(self: *const GoogleTTSResponse, allocator: std.mem.Allocator) ![]u8 {
        const data_size: u32 = @intCast(self.audio_data.len);
        const file_size: u32 = 36 + data_size;

        var wav: std.ArrayList(u8) = .empty;
        errdefer wav.deinit(allocator);

        // RIFF header
        try wav.appendSlice(allocator, "RIFF");
        try wav.appendSlice(allocator, &std.mem.toBytes(file_size));
        try wav.appendSlice(allocator, "WAVE");

        // fmt chunk
        try wav.appendSlice(allocator, "fmt ");
        try wav.appendSlice(allocator, &std.mem.toBytes(@as(u32, 16))); // chunk size
        try wav.appendSlice(allocator, &std.mem.toBytes(@as(u16, 1))); // PCM format
        try wav.appendSlice(allocator, &std.mem.toBytes(@as(u16, self.channels)));
        try wav.appendSlice(allocator, &std.mem.toBytes(self.sample_rate));
        const byte_rate: u32 = self.sample_rate * self.channels * (self.bits_per_sample / 8);
        try wav.appendSlice(allocator, &std.mem.toBytes(byte_rate));
        const block_align: u16 = self.channels * (self.bits_per_sample / 8);
        try wav.appendSlice(allocator, &std.mem.toBytes(block_align));
        try wav.appendSlice(allocator, &std.mem.toBytes(@as(u16, self.bits_per_sample)));

        // data chunk
        try wav.appendSlice(allocator, "data");
        try wav.appendSlice(allocator, &std.mem.toBytes(data_size));
        try wav.appendSlice(allocator, self.audio_data);

        return try wav.toOwnedSlice(allocator);
    }
};

/// Google TTS errors
pub const GoogleTTSError = error{
    InvalidApiKey,
    RateLimitExceeded,
    InvalidRequest,
    ServerError,
    NetworkError,
    InvalidResponse,
    TextTooLong,
    UnsupportedVoice,
    Base64DecodeError,
};

test "GoogleVoice" {
    try std.testing.expectEqual(GoogleVoice.kore, GoogleVoice.fromString("kore").?);
    try std.testing.expectEqual(GoogleVoice.puck, GoogleVoice.fromString("Puck").?);
    try std.testing.expectEqualStrings("Kore", GoogleVoice.kore.toString());
    try std.testing.expectEqualStrings("Firm", GoogleVoice.kore.description());
}

test "GoogleTTSModel" {
    try std.testing.expectEqual(GoogleTTSModel.gemini_2_5_flash_tts, GoogleTTSModel.fromString("flash").?);
    try std.testing.expectEqualStrings("gemini-2.5-flash-preview-tts", GoogleTTSModel.gemini_2_5_flash_tts.toString());
}
