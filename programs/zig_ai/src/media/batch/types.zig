// Image batch processing types
// Defines request, result, and config types for CSV-driven batch image generation

const std = @import("std");
const media_types = @import("../types.zig");

pub const ImageProvider = media_types.ImageProvider;
pub const Quality = media_types.Quality;
pub const Style = media_types.Style;
pub const Background = media_types.Background;

/// A single image generation request parsed from a CSV row
pub const ImageBatchRequest = struct {
    id: u32,
    prompt: []const u8,
    provider: ?ImageProvider = null, // null = use CLI default
    size: ?[]const u8 = null,
    quality: ?Quality = null,
    style: ?Style = null,
    aspect_ratio: ?[]const u8 = null,
    template: ?[]const u8 = null,
    filename: ?[]const u8 = null,
    count: u8 = 1,
    background: ?Background = null,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *ImageBatchRequest) void {
        self.allocator.free(self.prompt);
        if (self.size) |s| self.allocator.free(s);
        if (self.aspect_ratio) |a| self.allocator.free(a);
        if (self.template) |t| self.allocator.free(t);
        if (self.filename) |f| self.allocator.free(f);
    }
};

/// Result from processing a single batch request
pub const ImageBatchResult = struct {
    id: u32,
    prompt: []const u8,
    provider: ?ImageProvider = null,
    status: Status,
    image_paths: [][]const u8,
    execution_time_ms: u64 = 0,
    file_size_bytes: usize = 0,
    error_message: ?[]const u8 = null,

    allocator: std.mem.Allocator,

    pub const Status = enum {
        success,
        failed,
        skipped,

        pub fn toString(self: Status) []const u8 {
            return switch (self) {
                .success => "success",
                .failed => "failed",
                .skipped => "skipped",
            };
        }
    };

    pub fn deinit(self: *ImageBatchResult) void {
        self.allocator.free(self.prompt);
        for (self.image_paths) |p| self.allocator.free(p);
        self.allocator.free(self.image_paths);
        if (self.error_message) |e| self.allocator.free(e);
    }
};

/// Configuration for a batch run (CLI flags + defaults)
pub const ImageBatchConfig = struct {
    input_file: []const u8,
    output_dir: []const u8 = ".",
    results_file: ?[]const u8 = null,
    delay_ms: u64 = 2000,
    retry_count: u32 = 2,
    dry_run: bool = false,
    start_from: u32 = 1,

    // CLI defaults (used when CSV row omits a field)
    default_provider: ?ImageProvider = null,
    default_size: ?[]const u8 = null,
    default_quality: ?Quality = null,
    default_style: ?Style = null,
    default_aspect_ratio: ?[]const u8 = null,
    default_template: ?[]const u8 = null,
    default_count: u8 = 1,
    default_background: ?Background = null,
};
