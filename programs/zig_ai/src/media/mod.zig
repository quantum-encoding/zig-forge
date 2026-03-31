// Media generation module for zig_ai
// Provides image, video, and music generation capabilities

pub const types = @import("types.zig");
pub const storage = @import("storage.zig");
pub const cli = @import("cli.zig");
pub const providers = @import("providers/mod.zig");
pub const lyria_streaming = @import("lyria_streaming.zig");
pub const image_batch = @import("batch/mod.zig");
pub const batch_cli = @import("batch_cli.zig");

// Re-export commonly used types
pub const ImageProvider = types.ImageProvider;
pub const ImageRequest = types.ImageRequest;
pub const ImageResponse = types.ImageResponse;
pub const GeneratedMedia = types.GeneratedMedia;
pub const MediaConfig = types.MediaConfig;
pub const Quality = types.Quality;
pub const Style = types.Style;
pub const MediaFormat = types.MediaFormat;

// Re-export provider functions
pub const generateImage = providers.generateImage;

// Re-export Lyria streaming types
pub const LyriaStream = lyria_streaming.LyriaStream;
pub const WeightedPrompt = lyria_streaming.WeightedPrompt;
pub const MusicConfig = lyria_streaming.MusicConfig;
pub const AudioFormat = lyria_streaming.AudioFormat;
pub const SessionState = lyria_streaming.SessionState;

test {
    @import("std").testing.refAllDecls(@This());
}
