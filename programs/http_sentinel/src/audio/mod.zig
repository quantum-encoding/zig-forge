// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Audio module - Text-to-Speech and Speech-to-Text functionality
//!
//! Supported providers:
//! - OpenAI TTS (gpt-4o-mini-tts, tts-1, tts-1-hd)
//! - OpenAI STT (whisper-1, gpt-4o-transcribe, gpt-4o-mini-transcribe)
//! - Google Cloud TTS/STT (coming soon)

pub const types = @import("types.zig");
pub const openai_tts = @import("openai_tts.zig");
pub const openai_stt = @import("openai_stt.zig");
pub const google_tts = @import("google_tts.zig");

// Re-export OpenAI TTS types
pub const Voice = types.Voice;
pub const AudioFormat = types.AudioFormat;
pub const TTSModel = types.TTSModel;
pub const TTSRequest = types.TTSRequest;
pub const TTSResponse = types.TTSResponse;
pub const TTSError = types.TTSError;

// Re-export STT types
pub const STTModel = types.STTModel;
pub const STTResponseFormat = types.STTResponseFormat;
pub const AudioInputFormat = types.AudioInputFormat;
pub const STTRequest = types.STTRequest;
pub const STTResponse = types.STTResponse;
pub const STTError = types.STTError;

// Re-export Google TTS types
pub const GoogleVoice = types.GoogleVoice;
pub const GoogleTTSModel = types.GoogleTTSModel;
pub const SpeakerConfig = types.SpeakerConfig;
pub const GoogleTTSRequest = types.GoogleTTSRequest;
pub const GoogleTTSResponse = types.GoogleTTSResponse;
pub const GoogleTTSError = types.GoogleTTSError;

// Re-export clients
pub const OpenAITTSClient = openai_tts.OpenAITTSClient;
pub const OpenAISTTClient = openai_stt.OpenAISTTClient;
pub const GoogleTTSClient = google_tts.GoogleTTSClient;

test {
    @import("std").testing.refAllDecls(@This());
}
