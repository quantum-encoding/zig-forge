// Media generation providers module
// Exports all provider implementations

const std = @import("std");
const types = @import("../types.zig");
const ImageRequest = types.ImageRequest;
const ImageResponse = types.ImageResponse;
const ImageProvider = types.ImageProvider;
const EditRequest = types.EditRequest;
const VideoRequest = types.VideoRequest;
const VideoResponse = types.VideoResponse;
const VideoProvider = types.VideoProvider;
const MusicRequest = types.MusicRequest;
const MusicResponse = types.MusicResponse;
const MusicProvider = types.MusicProvider;
const MediaConfig = types.MediaConfig;

// Image providers
pub const openai = @import("openai.zig");
pub const xai = @import("xai.zig");
pub const google = @import("google.zig");

// Video providers
pub const sora = @import("sora.zig");
pub const veo = @import("veo.zig");
pub const xai_video = @import("xai_video.zig");

// Music providers
pub const lyria = @import("lyria.zig");

/// Generate image using the appropriate provider
pub fn generateImage(
    allocator: std.mem.Allocator,
    request: ImageRequest,
    config: MediaConfig,
) !ImageResponse {
    return switch (request.provider) {
        .dalle3 => openai.generateDalle3(allocator, request, config),
        .dalle2 => openai.generateDalle2(allocator, request, config),
        .gpt_image => openai.generateGptImage(allocator, request, config),
        .gpt_image_15 => openai.generateGptImage15(allocator, request, config),
        .grok => xai.generateGrokImage(allocator, request, config),
        .imagen_genai => google.generateImagenGenAI(allocator, request, config),
        .imagen_vertex => google.generateImagenVertex(allocator, request, config),
        .gemini_flash => google.generateGeminiFlash(allocator, request, config),
        .gemini_pro => google.generateGeminiPro(allocator, request, config),
    };
}

/// Edit image using the appropriate provider
pub fn editImage(
    allocator: std.mem.Allocator,
    request: EditRequest,
    config: MediaConfig,
) !ImageResponse {
    return switch (request.provider) {
        .gpt_image => openai.editGptImage(allocator, request, config),
        .grok => xai.editGrokImage(allocator, request, config),
        .gemini_flash, .gemini_pro => openai.editGptImage(allocator, request, config), // fallback
    };
}

/// Generate video using the appropriate provider
pub fn generateVideo(
    allocator: std.mem.Allocator,
    request: VideoRequest,
    config: MediaConfig,
) !VideoResponse {
    return switch (request.provider) {
        .sora => sora.generateSora(allocator, request, config),
        .veo => veo.generateVeo(allocator, request, config),
        .grok_video => xai_video.generateGrokVideo(allocator, request, config),
    };
}

/// Generate music using the appropriate provider
pub fn generateMusic(
    allocator: std.mem.Allocator,
    request: MusicRequest,
    config: MediaConfig,
) !MusicResponse {
    return switch (request.provider) {
        .lyria => lyria.generateLyria(allocator, request, config),
        .lyria_realtime => lyria.generateLyriaRealtime(allocator, request, config),
    };
}

/// Check if a provider is available (has API key configured)
pub fn isProviderAvailable(provider: ImageProvider, config: MediaConfig) bool {
    return config.hasProvider(provider);
}

/// Check if a video provider is available
pub fn isVideoProviderAvailable(provider: VideoProvider, config: MediaConfig) bool {
    return config.hasVideoProvider(provider);
}

/// Get list of available providers
pub fn getAvailableProviders(config: MediaConfig) []const ImageProvider {
    var count: usize = 0;
    var available: [9]ImageProvider = undefined;

    inline for (std.meta.fields(ImageProvider)) |field| {
        const provider: ImageProvider = @enumFromInt(field.value);
        if (config.hasProvider(provider)) {
            available[count] = provider;
            count += 1;
        }
    }

    return available[0..count];
}

test {
    std.testing.refAllDecls(@This());
}
