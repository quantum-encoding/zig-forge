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

/// Build the text-to-speech request body. Factored out of `textToSpeech`
/// so the JSON serialization (and its escaping of caller-controlled
/// identifier fields like `model_id`) can be unit-tested without a live
/// HTTP client. Caller owns the returned slice.
fn buildTextToSpeechBody(
    allocator: std.mem.Allocator,
    text: []const u8,
    model_id: []const u8,
    stability: f32,
    similarity: f32,
) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .text = text,
        .model_id = model_id,
        .voice_settings = .{
            .stability = stability,
            .similarity_boost = similarity,
            .use_speaker_boost = true,
        },
    }, .{});
}

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

        // Emit the whole body via std.json.Stringify so every field —
        // including identifier fields like model_id — is escaped. A `"`
        // in any value can no longer break or inject into the JSON.
        const payload = try buildTextToSpeechBody(self.allocator, text, model_id, stability, similarity);
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
        const payload = try std.json.Stringify.valueAlloc(self.allocator, .{
            .voice_description = description,
            .text = sample_text,
        }, .{});
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
        const payload = try std.json.Stringify.valueAlloc(self.allocator, .{
            .text = text,
            .duration_seconds = duration_seconds,
        }, .{});
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

test "TTS body escapes a hostile model_id per RFC 8259 (no JSON injection)" {
    // External anchor: RFC 8259 §7 "String" — the two-character escape
    // sequences are fixed by the spec, not by this codebase:
    //   quotation mark  U+0022  ->  \"   (")
    //   reverse solidus U+005C  ->  \\   (\)
    //
    // A `model_id` carrying a `"` used to be substituted unescaped by the
    // old allocPrint template, letting a caller-controlled identifier break
    // the JSON or inject a sibling field. Migrating to std.json.Stringify
    // (buildTextToSpeechBody) must emit the RFC-mandated escapes instead.
    const allocator = std.testing.allocator;

    // Hostile identifier: a `"` (would close the string) followed by an
    // injected field, plus a backslash. Per RFC 8259 both must be escaped.
    const hostile_model_id = "evil\",\"injected\":\"x\\y";

    const body = try buildTextToSpeechBody(allocator, "hello", hostile_model_id, 0.5, 0.75);
    defer allocator.free(body);

    // Golden substring — the exact bytes RFC 8259 mandates for this input.
    // `"` -> `\"`, `\` -> `\\`. Any unescaped `"` here would be an injection.
    const expected_field = "\"model_id\":\"evil\\\",\\\"injected\\\":\\\"x\\\\y\"";
    try std.testing.expect(std.mem.indexOf(u8, body, expected_field) != null);

    // The body must remain a single valid JSON object, and the hostile
    // string must survive as the *value* of model_id — proving no field was
    // injected and the parser sees exactly one model_id equal to the input.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings(hostile_model_id, obj.get("model_id").?.string);
    // The injected key name must NOT appear as a real top-level field.
    try std.testing.expect(obj.get("injected") == null);
}
