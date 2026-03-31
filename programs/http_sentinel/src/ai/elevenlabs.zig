// Copyright (c) 2025 QUANTUM ENCODING LTD
//! ElevenLabs voice synthesis & audio API client.
//!
//! Supports: TTS, voice cloning, voice design, dubbing, STT, sound effects.
//! Auth: xi-api-key header with ELEVENLABS_API_KEY env var.

const std = @import("std");
const HttpClient = @import("../http_client.zig").HttpClient;
const common = @import("common.zig");

const API_BASE = "https://api.elevenlabs.io";

pub const Models = struct {
    pub const MULTILINGUAL_V2 = "eleven_multilingual_v2";
    pub const TURBO_V2_5 = "eleven_turbo_v2_5";
    pub const FLASH_V2_5 = "eleven_flash_v2_5";
    pub const V3 = "eleven_v3";
    pub const SCRIBE_V2 = "scribe_v2"; // STT
    pub const MUSIC_V1 = "eleven_music_v1";
    pub const SFX_V2 = "eleven_sfx_v2";
};

/// Well-known voice IDs (friendly name → UUID)
pub const Voices = struct {
    pub const RACHEL = "21m00Tcm4TlvDq8ikWAM";
    pub const ADAM = "pNInz6obpgDQGcFmaJgB";
    pub const ANTONI = "ErXwobaYiN019PkySvjV";
    pub const SAM = "yoZ06aMxZJJ28mfd3POQ";
    pub const ALLOY = "alloy"; // OpenAI-compat name

    pub fn resolve(name: []const u8) []const u8 {
        if (std.mem.eql(u8, name, "rachel")) return RACHEL;
        if (std.mem.eql(u8, name, "adam")) return ADAM;
        if (std.mem.eql(u8, name, "antoni")) return ANTONI;
        if (std.mem.eql(u8, name, "sam")) return SAM;
        return name; // Assume it's already a voice ID
    }
};

pub const ElevenLabsClient = struct {
    http_client: HttpClient,
    api_key: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !ElevenLabsClient {
        return .{
            .http_client = try HttpClient.init(allocator),
            .api_key = api_key,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ElevenLabsClient) void {
        self.http_client.deinit();
    }

    /// Text-to-Speech: returns raw audio bytes (MP3 by default).
    pub fn textToSpeech(
        self: *ElevenLabsClient,
        text: []const u8,
        voice_id: []const u8,
        model_id: []const u8,
        stability: f32,
        similarity: f32,
    ) ![]u8 {
        const resolved_voice = Voices.resolve(voice_id);
        const endpoint = try std.fmt.allocPrint(self.allocator,
            API_BASE ++ "/v1/text-to-speech/{s}?output_format=mp3_44100_128",
            .{resolved_voice},
        );
        defer self.allocator.free(endpoint);

        const escaped_text = try common.escapeJsonString(self.allocator, text);
        defer self.allocator.free(escaped_text);

        const payload = try std.fmt.allocPrint(self.allocator,
            \\{{"text":"{s}","model_id":"{s}","voice_settings":{{"stability":{d},"similarity_boost":{d},"use_speaker_boost":true}}}}
        , .{ escaped_text, model_id, stability, similarity });
        defer self.allocator.free(payload);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "xi-api-key", .value = self.api_key },
        };

        var response = try self.http_client.post(endpoint, &headers, payload);
        defer response.deinit();

        if (response.status != .ok) return common.AIError.ApiRequestFailed;
        return try self.allocator.dupe(u8, response.body);
    }

    /// List available voices.
    pub fn listVoices(self: *ElevenLabsClient) ![]u8 {
        const headers = [_]std.http.Header{
            .{ .name = "xi-api-key", .value = self.api_key },
        };
        var response = try self.http_client.get(API_BASE ++ "/v1/voices", &headers);
        defer response.deinit();
        if (response.status != .ok) return common.AIError.ApiRequestFailed;
        return try self.allocator.dupe(u8, response.body);
    }

    /// Voice design: generate 3 preview voices from a text description.
    pub fn designVoice(self: *ElevenLabsClient, description: []const u8, sample_text: []const u8) ![]u8 {
        const escaped_desc = try common.escapeJsonString(self.allocator, description);
        defer self.allocator.free(escaped_desc);
        const escaped_text = try common.escapeJsonString(self.allocator, sample_text);
        defer self.allocator.free(escaped_text);

        const payload = try std.fmt.allocPrint(self.allocator,
            \\{{"voice_description":"{s}","text":"{s}"}}
        , .{ escaped_desc, escaped_text });
        defer self.allocator.free(payload);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "xi-api-key", .value = self.api_key },
        };

        var response = try self.http_client.post(API_BASE ++ "/v1/text-to-voice/create-previews", &headers, payload);
        defer response.deinit();
        if (response.status != .ok) return common.AIError.ApiRequestFailed;
        return try self.allocator.dupe(u8, response.body);
    }

    /// Sound effects generation.
    pub fn generateSfx(self: *ElevenLabsClient, text: []const u8, duration_seconds: f32) ![]u8 {
        const escaped = try common.escapeJsonString(self.allocator, text);
        defer self.allocator.free(escaped);

        const payload = try std.fmt.allocPrint(self.allocator,
            \\{{"text":"{s}","duration_seconds":{d}}}
        , .{ escaped, duration_seconds });
        defer self.allocator.free(payload);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "xi-api-key", .value = self.api_key },
        };

        var response = try self.http_client.post(API_BASE ++ "/v1/sound-generation", &headers, payload);
        defer response.deinit();
        if (response.status != .ok) return common.AIError.ApiRequestFailed;
        return try self.allocator.dupe(u8, response.body);
    }
};
