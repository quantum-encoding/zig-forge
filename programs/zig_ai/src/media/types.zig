// Media generation types for image, video, and music generation
// Part of the zig_ai media extension

const std = @import("std");
const Allocator = std.mem.Allocator;

// Zig 0.16 helper for environment variables
fn getEnv(key: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(key) orelse return null;
    return std.mem.span(value);
}

// ============================================================================
// Provider Enums
// ============================================================================

/// Image generation providers
pub const ImageProvider = enum {
    // OpenAI
    dalle3,
    dalle2,
    gpt_image,
    gpt_image_15,

    // xAI
    grok,

    // Google
    imagen_genai,
    imagen_vertex,
    gemini_flash,
    gemini_pro,

    pub fn getName(self: ImageProvider) []const u8 {
        return switch (self) {
            .dalle3 => "DALL-E 3",
            .dalle2 => "DALL-E 2",
            .gpt_image => "GPT-Image 1",
            .gpt_image_15 => "GPT-Image 1.5",
            .grok => "Grok-2-Image",
            .imagen_genai => "Imagen (GenAI)",
            .imagen_vertex => "Imagen (Vertex)",
            .gemini_flash => "Gemini Flash",
            .gemini_pro => "Gemini Pro",
        };
    }

    pub fn getEnvVar(self: ImageProvider) []const u8 {
        return switch (self) {
            .dalle3, .dalle2, .gpt_image, .gpt_image_15 => "OPENAI_API_KEY",
            .grok => "XAI_API_KEY",
            .imagen_genai, .gemini_flash, .gemini_pro => "GEMINI_API_KEY",
            .imagen_vertex => "VERTEX_PROJECT_ID",
        };
    }

    pub fn fromString(str: []const u8) ?ImageProvider {
        const map = std.StaticStringMap(ImageProvider).initComptime(.{
            .{ "dalle3", .dalle3 },
            .{ "dalle2", .dalle2 },
            .{ "gpt-image", .gpt_image },
            .{ "gpt-image-15", .gpt_image_15 },
            .{ "grok-image", .grok },
            .{ "imagen", .imagen_genai },
            .{ "vertex-image", .imagen_vertex },
            .{ "gemini-image", .gemini_flash },
            .{ "gemini-image-pro", .gemini_pro },
        });
        return map.get(str);
    }
};

/// Video generation providers
pub const VideoProvider = enum {
    veo,
    sora,
    grok_video,

    pub fn getName(self: VideoProvider) []const u8 {
        return switch (self) {
            .veo => "Google Veo 3.1",
            .sora => "OpenAI Sora 2",
            .grok_video => "Grok Imagine Video",
        };
    }

    pub fn fromString(str: []const u8) ?VideoProvider {
        const map = std.StaticStringMap(VideoProvider).initComptime(.{
            .{ "veo", .veo },
            .{ "sora", .sora },
            .{ "grok-video", .grok_video },
        });
        return map.get(str);
    }

    pub fn getEnvVar(self: VideoProvider) []const u8 {
        return switch (self) {
            .veo => "GEMINI_API_KEY",
            .sora => "OPENAI_API_KEY",
            .grok_video => "XAI_API_KEY",
        };
    }
};

/// Music generation providers
pub const MusicProvider = enum {
    lyria,
    lyria_realtime,

    pub fn getName(self: MusicProvider) []const u8 {
        return switch (self) {
            .lyria => "Google Lyria 2",
            .lyria_realtime => "Lyria RealTime",
        };
    }

    pub fn fromString(str: []const u8) ?MusicProvider {
        const map = std.StaticStringMap(MusicProvider).initComptime(.{
            .{ "lyria", .lyria },
            .{ "lyria-realtime", .lyria_realtime },
        });
        return map.get(str);
    }

    pub fn getEnvVar(self: MusicProvider) []const u8 {
        _ = self;
        return "VERTEX_PROJECT_ID";
    }
};

/// Image editing providers
pub const EditProvider = enum {
    gpt_image,
    grok,
    gemini_flash,
    gemini_pro,

    pub fn getName(self: EditProvider) []const u8 {
        return switch (self) {
            .gpt_image => "GPT-Image 1.5",
            .grok => "Grok Imagine Image",
            .gemini_flash => "Gemini Flash",
            .gemini_pro => "Gemini Pro",
        };
    }

    pub fn getEnvVar(self: EditProvider) []const u8 {
        return switch (self) {
            .gpt_image => "OPENAI_API_KEY",
            .grok => "XAI_API_KEY",
            .gemini_flash, .gemini_pro => "GEMINI_API_KEY",
        };
    }
};

// ============================================================================
// Quality and Style
// ============================================================================

pub const Quality = enum {
    auto,
    standard,
    hd,
    high,
    medium,
    low,
    premium,

    pub fn toString(self: Quality) []const u8 {
        return switch (self) {
            .auto => "auto",
            .standard => "standard",
            .hd => "hd",
            .high => "high",
            .medium => "medium",
            .low => "low",
            .premium => "premium",
        };
    }

    pub fn fromString(str: []const u8) ?Quality {
        const map = std.StaticStringMap(Quality).initComptime(.{
            .{ "auto", .auto },
            .{ "standard", .standard },
            .{ "hd", .hd },
            .{ "high", .high },
            .{ "medium", .medium },
            .{ "low", .low },
            .{ "premium", .premium },
        });
        return map.get(str);
    }
};

pub const Style = enum {
    vivid,
    natural,

    pub fn toString(self: Style) []const u8 {
        return switch (self) {
            .vivid => "vivid",
            .natural => "natural",
        };
    }

    pub fn fromString(str: []const u8) ?Style {
        if (std.mem.eql(u8, str, "vivid")) return .vivid;
        if (std.mem.eql(u8, str, "natural")) return .natural;
        return null;
    }
};

pub const MediaFormat = enum {
    png,
    jpeg,
    webp,
    gif,
    mp4,
    wav,

    pub fn getExtension(self: MediaFormat) []const u8 {
        return switch (self) {
            .png => "png",
            .jpeg => "jpg",
            .webp => "webp",
            .gif => "gif",
            .mp4 => "mp4",
            .wav => "wav",
        };
    }

    pub fn getMimeType(self: MediaFormat) []const u8 {
        return switch (self) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .webp => "image/webp",
            .gif => "image/gif",
            .mp4 => "video/mp4",
            .wav => "audio/wav",
        };
    }

    pub fn fromExtension(ext: []const u8) ?MediaFormat {
        const map = std.StaticStringMap(MediaFormat).initComptime(.{
            .{ "png", .png },
            .{ "jpg", .jpeg },
            .{ "jpeg", .jpeg },
            .{ "webp", .webp },
            .{ "gif", .gif },
            .{ "mp4", .mp4 },
            .{ "wav", .wav },
        });
        return map.get(ext);
    }
};

// ============================================================================
// Request Types
// ============================================================================

/// Image generation request
pub const ImageRequest = struct {
    prompt: []const u8,
    provider: ImageProvider,
    count: u8 = 1,
    size: ?[]const u8 = null, // e.g., "1024x1024", "1792x1024"
    aspect_ratio: ?[]const u8 = null, // e.g., "1:1", "16:9"
    quality: ?Quality = null,
    style: ?Style = null,
    output_path: ?[]const u8 = null, // Custom output filename
    response_format: ResponseFormat = .b64_json,
    background: ?Background = null, // transparent or opaque (GPT-Image only)
};

/// Video generation request
pub const VideoRequest = struct {
    prompt: []const u8,
    provider: VideoProvider,
    model: ?[]const u8 = null, // e.g., "sora-2", "sora-2-pro"
    duration: ?u8 = null, // seconds (default: 5-8)
    size: ?[]const u8 = null, // e.g., "1280x720", "1920x1080"
    aspect_ratio: ?[]const u8 = null, // e.g., "16:9", "9:16"
    resolution: ?[]const u8 = null, // e.g., "720p", "1080p"
    audio: bool = false,
    output_path: ?[]const u8 = null,
};

/// Image editing request
pub const EditRequest = struct {
    prompt: []const u8,
    image_paths: []const []const u8, // 1-16 input image file paths
    provider: EditProvider = .gpt_image,
    model: []const u8 = "gpt-image-1.5",
    quality: ?Quality = null,
    size: ?[]const u8 = null,
    count: u8 = 1,
    input_fidelity: ?InputFidelity = null,
    background: ?Background = null,
    output_path: ?[]const u8 = null,
};

/// Music generation request
pub const MusicRequest = struct {
    prompt: []const u8,
    provider: MusicProvider = .lyria,
    count: u8 = 1,
    duration_seconds: u32 = 30,
    negative_prompt: ?[]const u8 = null,
    seed: ?u64 = null,
    bpm: ?u16 = null,
    output_path: ?[]const u8 = null,
};

pub const ResponseFormat = enum {
    url, // Return URL to download
    b64_json, // Return base64-encoded data in JSON
};

/// Input fidelity for image editing (how closely to preserve original)
pub const InputFidelity = enum {
    low, // default — faster, less faithful
    high, // slower, preserves more of source

    pub fn toString(self: InputFidelity) []const u8 {
        return switch (self) {
            .low => "low",
            .high => "high",
        };
    }
};

/// Background mode for image generation/editing
pub const Background = enum {
    @"opaque",
    transparent,

    pub fn toString(self: Background) []const u8 {
        return switch (self) {
            .@"opaque" => "opaque",
            .transparent => "transparent",
        };
    }
};

// ============================================================================
// Response Types
// ============================================================================

/// A single generated media item
pub const GeneratedMedia = struct {
    data: []u8,
    format: MediaFormat,
    local_path: []const u8,
    store_path: []const u8,
    revised_prompt: ?[]const u8 = null,
    allocator: Allocator,

    pub fn deinit(self: *GeneratedMedia) void {
        self.allocator.free(self.data);
        self.allocator.free(self.local_path);
        self.allocator.free(self.store_path);
        if (self.revised_prompt) |rp| self.allocator.free(rp);
    }
};

/// Image generation response
pub const ImageResponse = struct {
    job_id: []const u8,
    provider: ImageProvider,
    original_prompt: []const u8,
    revised_prompt: ?[]const u8,
    images: []GeneratedMedia,
    processing_time_ms: u64,
    model_used: []const u8,
    allocator: Allocator,

    pub fn deinit(self: *ImageResponse) void {
        self.allocator.free(self.job_id);
        self.allocator.free(self.original_prompt);
        if (self.revised_prompt) |rp| self.allocator.free(rp);
        self.allocator.free(self.model_used);
        for (self.images) |*img| {
            img.deinit();
        }
        self.allocator.free(self.images);
    }
};

/// Video generation response
pub const VideoResponse = struct {
    job_id: []const u8,
    provider: VideoProvider,
    original_prompt: []const u8,
    videos: []GeneratedMedia,
    processing_time_ms: u64,
    model_used: []const u8,
    allocator: Allocator,

    pub fn deinit(self: *VideoResponse) void {
        self.allocator.free(self.job_id);
        self.allocator.free(self.original_prompt);
        self.allocator.free(self.model_used);
        for (self.videos) |*vid| {
            vid.deinit();
        }
        self.allocator.free(self.videos);
    }
};

/// Music generation response
pub const MusicResponse = struct {
    job_id: []const u8,
    provider: MusicProvider,
    original_prompt: []const u8,
    tracks: []GeneratedMedia,
    processing_time_ms: u64,
    model_used: []const u8,
    bpm: ?u16 = null,
    allocator: Allocator,

    pub fn deinit(self: *MusicResponse) void {
        self.allocator.free(self.job_id);
        self.allocator.free(self.original_prompt);
        self.allocator.free(self.model_used);
        for (self.tracks) |*track| {
            track.deinit();
        }
        self.allocator.free(self.tracks);
    }
};

// ============================================================================
// Configuration
// ============================================================================

/// Media generation configuration (from environment)
pub const MediaConfig = struct {
    openai_api_key: ?[]const u8 = null,
    xai_api_key: ?[]const u8 = null,
    genai_api_key: ?[]const u8 = null,
    vertex_project_id: ?[]const u8 = null,
    vertex_location: []const u8 = "us-central1",
    media_store_path: ?[]const u8 = null,
    /// Default local output directory (overrides "." for file saves)
    output_dir: ?[]const u8 = null,
    /// When true, skip saving to central media store (mobile/embedded)
    disable_central_store: bool = false,

    pub fn loadFromEnv() MediaConfig {
        return .{
            .openai_api_key = getEnv("OPENAI_API_KEY"),
            .xai_api_key = getEnv("XAI_API_KEY"),
            .genai_api_key = getEnv("GEMINI_API_KEY") orelse getEnv("GOOGLE_GENAI_API_KEY"),
            .vertex_project_id = getEnv("VERTEX_PROJECT_ID"),
            .vertex_location = getEnv("GCP_LOCATION") orelse "us-central1",
            .media_store_path = getEnv("MEDIA_STORE_PATH"),
            .output_dir = getEnv("ZIG_AI_OUTPUT_DIR"),
            .disable_central_store = getEnv("ZIG_AI_NO_CENTRAL_STORE") != null,
        };
    }

    pub fn hasProvider(self: MediaConfig, provider: ImageProvider) bool {
        return switch (provider) {
            .dalle3, .dalle2, .gpt_image, .gpt_image_15 => self.openai_api_key != null,
            .grok => self.xai_api_key != null,
            .imagen_genai, .gemini_flash, .gemini_pro => self.genai_api_key != null,
            .imagen_vertex => self.vertex_project_id != null,
        };
    }

    pub fn hasVideoProvider(self: MediaConfig, provider: VideoProvider) bool {
        return switch (provider) {
            .sora => self.openai_api_key != null,
            .veo => self.genai_api_key != null,
            .grok_video => self.xai_api_key != null,
        };
    }

    pub fn hasMusicProvider(self: MediaConfig, provider: MusicProvider) bool {
        _ = self;
        _ = provider;
        // Lyria can use either VERTEX_PROJECT_ID or gcloud config
        // We'll check gcloud at runtime, so just return true for now
        // The actual auth check happens in the provider
        return true;
    }
};

// ============================================================================
// Metadata (for storage)
// ============================================================================

/// Metadata stored alongside generated media
pub const MediaMetadata = struct {
    job_id: []const u8,
    provider: []const u8,
    model: []const u8,
    timestamp: i64,
    original_prompt: []const u8,
    revised_prompt: ?[]const u8,
    processing_time_ms: u64,
    images: []ImageMetadata,
};

pub const ImageMetadata = struct {
    filename: []const u8,
    format: []const u8,
    size_bytes: usize,
};

// ============================================================================
// Tests
// ============================================================================

test "ImageProvider.fromString" {
    try std.testing.expectEqual(ImageProvider.dalle3, ImageProvider.fromString("dalle3").?);
    try std.testing.expectEqual(ImageProvider.grok, ImageProvider.fromString("grok-image").?);
    try std.testing.expect(ImageProvider.fromString("invalid") == null);
}

test "Quality.fromString" {
    try std.testing.expectEqual(Quality.hd, Quality.fromString("hd").?);
    try std.testing.expectEqual(Quality.standard, Quality.fromString("standard").?);
    try std.testing.expect(Quality.fromString("invalid") == null);
}

test "MediaFormat.getExtension" {
    try std.testing.expectEqualStrings("png", MediaFormat.png.getExtension());
    try std.testing.expectEqualStrings("jpg", MediaFormat.jpeg.getExtension());
}

test "MediaConfig.loadFromEnv" {
    const config = MediaConfig.loadFromEnv();
    // Just verify it doesn't crash - actual values depend on environment
    _ = config.vertex_location;
}
