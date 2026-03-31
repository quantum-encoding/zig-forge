// Dual storage system for generated media
// Saves to both local directory and central media store

const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const Timer = @import("../timer.zig").Timer;

// Extern C file functions for Zig 0.16 compatibility
const FILE = std.c.FILE;
const SEEK_END: c_int = 2;
const SEEK_SET: c_int = 0;
extern "c" fn fseek(stream: *FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *FILE) c_long;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;

// Time functions
const time_t = i64;
const tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
};
extern "c" fn time(timer: ?*time_t) time_t;
extern "c" fn localtime_r(timer: *const time_t, result: *tm) ?*tm;
const types = @import("types.zig");
const ImageResponse = types.ImageResponse;
const VideoResponse = types.VideoResponse;
const MusicResponse = types.MusicResponse;
const GeneratedMedia = types.GeneratedMedia;
const MediaFormat = types.MediaFormat;
const MediaMetadata = types.MediaMetadata;
const ImageMetadata = types.ImageMetadata;
const ImageProvider = types.ImageProvider;
const VideoProvider = types.VideoProvider;

/// Get environment variable (Zig 0.16 compatible)
fn getEnv(name: [*:0]const u8) ?[]const u8 {
    const ptr = std.c.getenv(name);
    if (ptr) |p| {
        return std.mem.span(p);
    }
    return null;
}

/// Storage configuration
pub const StorageConfig = struct {
    /// Central store path (defaults to ~/media_store)
    store_path: []const u8,
    /// Local output directory (defaults to current directory)
    local_path: []const u8 = ".",
    /// Whether to save to central store
    use_central_store: bool = true,
    /// Whether to save metadata.json
    save_metadata: bool = true,
};

/// Get the default media store path (~/.media_store or MEDIA_STORE_PATH)
pub fn getDefaultStorePath(allocator: Allocator) ![]const u8 {
    // Check environment variable first
    if (getEnv("MEDIA_STORE_PATH")) |path| {
        return allocator.dupe(u8, path);
    }

    // Fall back to ~/media_store
    if (getEnv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/media_store", .{home});
    }

    return allocator.dupe(u8, "media_store");
}

/// Get the platform-appropriate central store path using comptime OS detection.
/// Priority: MEDIA_STORE_PATH env > platform default > HOME/media_store > media_store
pub fn getPlatformStorePath(allocator: Allocator) ![]const u8 {
    // 1. Explicit env var (works on all platforms)
    if (getEnv("MEDIA_STORE_PATH")) |path| {
        return allocator.dupe(u8, path);
    }

    // 2. Platform-specific defaults
    switch (comptime builtin.os.tag) {
        .macos => {
            if (getEnv("HOME")) |home| {
                return std.fmt.allocPrint(allocator, "{s}/Library/Application Support/zig-ai", .{home});
            }
        },
        .linux => {
            if (getEnv("XDG_DATA_HOME")) |xdg| {
                return std.fmt.allocPrint(allocator, "{s}/zig-ai", .{xdg});
            }
            if (getEnv("HOME")) |home| {
                return std.fmt.allocPrint(allocator, "{s}/.local/share/zig-ai", .{home});
            }
        },
        .windows => {
            if (getEnv("APPDATA")) |appdata| {
                return std.fmt.allocPrint(allocator, "{s}/zig-ai", .{appdata});
            }
        },
        .ios, .tvos, .watchos => {
            // iOS apps MUST set media_store_path via FFI — no default in sandbox
            return error.NoPlatformDefault;
        },
        else => {},
    }

    // 3. Fallback
    if (getEnv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/media_store", .{home});
    }
    return allocator.dupe(u8, "media_store");
}

/// Resolved storage configuration with owned path strings.
pub const ResolvedStorageConfig = struct {
    config: StorageConfig,
    store_path_owned: []const u8,
    local_path_owned: []const u8,
};

/// Build a StorageConfig from all available inputs, in priority order:
///   local_path:  output_path > config.output_dir > "."
///   store_path:  config.media_store_path > getPlatformStorePath()
///   use_central_store: !config.disable_central_store
pub fn resolveStorageConfig(
    allocator: Allocator,
    config: types.MediaConfig,
    output_path: ?[]const u8,
) !ResolvedStorageConfig {
    // Resolve local output directory
    const local_path = if (output_path) |op|
        try allocator.dupe(u8, op)
    else if (config.output_dir) |od|
        try allocator.dupe(u8, od)
    else
        try allocator.dupe(u8, ".");

    // Resolve central store path
    const use_central = !config.disable_central_store;
    const store_path = if (config.media_store_path) |sp|
        try allocator.dupe(u8, sp)
    else if (use_central)
        getPlatformStorePath(allocator) catch try allocator.dupe(u8, "media_store")
    else
        try allocator.dupe(u8, "media_store");

    return .{
        .config = .{
            .store_path = store_path,
            .local_path = local_path,
            .use_central_store = use_central,
            .save_metadata = use_central,
        },
        .store_path_owned = store_path,
        .local_path_owned = local_path,
    };
}

/// Save generated images to storage
/// Returns the list of saved file paths
pub fn saveImages(
    allocator: Allocator,
    response: *ImageResponse,
    image_data: []const []const u8,
    format: MediaFormat,
    config: StorageConfig,
) !void {
    // Create job directory in central store
    const store_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/images/{s}/{s}",
        .{ config.store_path, @tagName(response.provider), response.job_id },
    );
    defer allocator.free(store_dir);

    if (config.use_central_store) {
        try ensureDir(store_dir);
    }

    // Allocate array for generated media
    var images = try allocator.alloc(GeneratedMedia, image_data.len);
    errdefer allocator.free(images);

    // Generate descriptive base name from prompt
    const base_name = try generateDescriptiveName(allocator, response.original_prompt);
    defer allocator.free(base_name);

    // Save each image
    for (image_data, 0..) |data, i| {
        const filename = if (image_data.len == 1)
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ base_name, format.getExtension() })
        else
            try std.fmt.allocPrint(allocator, "{s}_{d:0>3}.{s}", .{ base_name, i + 1, format.getExtension() });

        // Save to local directory
        const local_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.local_path, filename });
        try writeFile(local_path, data);

        // Save to central store
        var store_path: []const u8 = undefined;
        if (config.use_central_store) {
            const store_filename = if (image_data.len == 1)
                try std.fmt.allocPrint(allocator, "image.{s}", .{format.getExtension()})
            else
                try std.fmt.allocPrint(allocator, "image_{d:0>3}.{s}", .{ i + 1, format.getExtension() });
            defer allocator.free(store_filename);

            store_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ store_dir, store_filename });
            try writeFile(store_path, data);
        } else {
            store_path = try allocator.dupe(u8, local_path);
        }

        // Create generated media entry
        images[i] = .{
            .data = try allocator.dupe(u8, data),
            .format = format,
            .local_path = local_path,
            .store_path = store_path,
            .revised_prompt = if (response.revised_prompt) |rp| try allocator.dupe(u8, rp) else null,
            .allocator = allocator,
        };

        allocator.free(filename);
    }

    response.images = images;

    // Save metadata
    if (config.save_metadata and config.use_central_store) {
        try saveMetadata(allocator, response, store_dir);
    }
}

/// Save a single image (convenience function)
pub fn saveImage(
    allocator: Allocator,
    response: *ImageResponse,
    data: []const u8,
    format: MediaFormat,
    config: StorageConfig,
) !void {
    var data_array = [_][]const u8{data};
    try saveImages(allocator, response, &data_array, format, config);
}

/// Save a video to storage
pub fn saveVideo(
    allocator: Allocator,
    response: *VideoResponse,
    data: []const u8,
    format: MediaFormat,
    config: StorageConfig,
) !void {
    // Create job directory in central store
    const store_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/videos/{s}/{s}",
        .{ config.store_path, @tagName(response.provider), response.job_id },
    );
    defer allocator.free(store_dir);

    if (config.use_central_store) {
        try ensureDir(store_dir);
    }

    // Allocate array for generated media
    var videos = try allocator.alloc(GeneratedMedia, 1);
    errdefer allocator.free(videos);

    // Generate descriptive filename from prompt
    const base_name = try generateDescriptiveName(allocator, response.original_prompt);
    defer allocator.free(base_name);
    const filename = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ base_name, format.getExtension() });

    // Save to local directory
    const local_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.local_path, filename });
    try writeFile(local_path, data);

    // Save to central store
    var store_path: []const u8 = undefined;
    if (config.use_central_store) {
        const store_filename = try std.fmt.allocPrint(allocator, "video.{s}", .{format.getExtension()});
        defer allocator.free(store_filename);

        store_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ store_dir, store_filename });
        try writeFile(store_path, data);
    } else {
        store_path = try allocator.dupe(u8, local_path);
    }

    // Create generated media entry
    videos[0] = .{
        .data = try allocator.dupe(u8, data),
        .format = format,
        .local_path = local_path,
        .store_path = store_path,
        .revised_prompt = null,
        .allocator = allocator,
    };

    allocator.free(filename);
    response.videos = videos;

    // Save simple metadata
    if (config.save_metadata and config.use_central_store) {
        const metadata_path = try std.fmt.allocPrint(allocator, "{s}/metadata.json", .{store_dir});
        defer allocator.free(metadata_path);

        const json_str = try std.fmt.allocPrint(allocator,
            \\{{"job_id":"{s}","provider":"{s}","model":"{s}","prompt":"{s}","processing_time_ms":{d},"size_bytes":{d}}}
        , .{
            response.job_id,
            @tagName(response.provider),
            response.model_used,
            response.original_prompt,
            response.processing_time_ms,
            data.len,
        });
        defer allocator.free(json_str);

        try writeFile(metadata_path, json_str);
    }
}

/// Save music/audio to storage
pub fn saveMusic(
    allocator: Allocator,
    response: *MusicResponse,
    data: []const u8,
    format: MediaFormat,
    config: StorageConfig,
) !void {
    // Create job directory in central store
    const store_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/music/{s}/{s}",
        .{ config.store_path, @tagName(response.provider), response.job_id },
    );
    defer allocator.free(store_dir);

    if (config.use_central_store) {
        try ensureDir(store_dir);
    }

    // Allocate array for generated media
    var tracks = try allocator.alloc(GeneratedMedia, 1);
    errdefer allocator.free(tracks);

    // Generate descriptive filename from prompt
    const base_name = try generateDescriptiveName(allocator, response.original_prompt);
    defer allocator.free(base_name);
    const filename = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ base_name, format.getExtension() });

    // Save to local directory
    const local_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.local_path, filename });
    try writeFile(local_path, data);

    // Save to central store
    var store_path: []const u8 = undefined;
    if (config.use_central_store) {
        const store_filename = try std.fmt.allocPrint(allocator, "audio.{s}", .{format.getExtension()});
        defer allocator.free(store_filename);

        store_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ store_dir, store_filename });
        try writeFile(store_path, data);
    } else {
        store_path = try allocator.dupe(u8, local_path);
    }

    // Create generated media entry
    tracks[0] = .{
        .data = try allocator.dupe(u8, data),
        .format = format,
        .local_path = local_path,
        .store_path = store_path,
        .revised_prompt = null,
        .allocator = allocator,
    };

    allocator.free(filename);
    response.tracks = tracks;

    // Save metadata
    if (config.save_metadata and config.use_central_store) {
        const metadata_path = try std.fmt.allocPrint(allocator, "{s}/metadata.json", .{store_dir});
        defer allocator.free(metadata_path);

        const bpm_str = if (response.bpm) |b|
            try std.fmt.allocPrint(allocator, "{d}", .{b})
        else
            try allocator.dupe(u8, "null");
        defer allocator.free(bpm_str);

        const json_str = try std.fmt.allocPrint(allocator,
            \\{{"job_id":"{s}","provider":"{s}","model":"{s}","prompt":"{s}","processing_time_ms":{d},"size_bytes":{d},"bpm":{s}}}
        , .{
            response.job_id,
            @tagName(response.provider),
            response.model_used,
            response.original_prompt,
            response.processing_time_ms,
            data.len,
            bpm_str,
        });
        defer allocator.free(json_str);

        try writeFile(metadata_path, json_str);
    }
}

/// Save metadata.json alongside the images
fn saveMetadata(allocator: Allocator, response: *ImageResponse, store_dir: []const u8) !void {
    const metadata_path = try std.fmt.allocPrint(allocator, "{s}/metadata.json", .{store_dir});
    defer allocator.free(metadata_path);

    // Build image metadata array
    var image_metas = try allocator.alloc(ImageMetadata, response.images.len);
    defer allocator.free(image_metas);

    for (response.images, 0..) |img, i| {
        const basename = std.fs.path.basename(img.store_path);
        image_metas[i] = .{
            .filename = basename,
            .format = @tagName(img.format),
            .size_bytes = img.data.len,
        };
    }

    // Get current timestamp using Timer
    var timer = Timer.start() catch unreachable;
    const timestamp: i64 = @intCast(timer.read() / std.time.ns_per_s);

    const metadata = MediaMetadata{
        .job_id = response.job_id,
        .provider = @tagName(response.provider),
        .model = response.model_used,
        .timestamp = timestamp,
        .original_prompt = response.original_prompt,
        .revised_prompt = response.revised_prompt,
        .processing_time_ms = response.processing_time_ms,
        .images = image_metas,
    };

    // Format revised_prompt for JSON
    const revised_str = if (metadata.revised_prompt) |rp|
        try std.fmt.allocPrint(allocator, "\"{s}\"", .{rp})
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(revised_str);

    // Serialize to JSON manually (simpler than std.json for this struct)
    const json_str = try std.fmt.allocPrint(allocator,
        \\{{"job_id":"{s}","provider":"{s}","model":"{s}","timestamp":{d},"original_prompt":"{s}","revised_prompt":{s},"processing_time_ms":{d},"image_count":{d}}}
    , .{
        metadata.job_id,
        metadata.provider,
        metadata.model,
        metadata.timestamp,
        metadata.original_prompt,
        revised_str,
        metadata.processing_time_ms,
        metadata.images.len,
    });
    defer allocator.free(json_str);

    try writeFile(metadata_path, json_str);
}

/// Generate a descriptive filename from prompt + timestamp
/// Example: "cosmic_duck_20260205_143052"
pub fn generateDescriptiveName(allocator: Allocator, prompt: []const u8) ![]const u8 {
    // Get current time
    var time_buf: [20]u8 = undefined;
    const timestamp = getTimestampString(&time_buf);

    // Sanitize prompt: lowercase, replace spaces/special chars with underscore, truncate
    const max_prompt_len: usize = 40;
    var sanitized: [64]u8 = undefined;
    var j: usize = 0;
    var last_was_underscore = false;

    for (prompt) |c| {
        if (j >= max_prompt_len) break;

        if ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9')) {
            sanitized[j] = c;
            j += 1;
            last_was_underscore = false;
        } else if (c >= 'A' and c <= 'Z') {
            // Convert to lowercase
            sanitized[j] = c + 32;
            j += 1;
            last_was_underscore = false;
        } else if (c == ' ' or c == '-' or c == '_' or c == '.' or c == ',') {
            // Replace with underscore, avoiding duplicates
            if (!last_was_underscore and j > 0) {
                sanitized[j] = '_';
                j += 1;
                last_was_underscore = true;
            }
        }
        // Skip other special characters
    }

    // Remove trailing underscore
    if (j > 0 and sanitized[j - 1] == '_') {
        j -= 1;
    }

    // Fallback if prompt was empty or all special chars
    if (j == 0) {
        return std.fmt.allocPrint(allocator, "generated_{s}", .{timestamp});
    }

    return std.fmt.allocPrint(allocator, "{s}_{s}", .{ sanitized[0..j], timestamp });
}

/// Get timestamp string in format YYYYMMDD_HHMMSS
fn getTimestampString(buf: *[20]u8) []const u8 {
    // Get current time via libc
    const now = time(null);
    var tm_result: tm = undefined;
    _ = localtime_r(&now, &tm_result);

    const year: u32 = @intCast(tm_result.tm_year + 1900);
    const month: u32 = @intCast(tm_result.tm_mon + 1);
    const day: u32 = @intCast(tm_result.tm_mday);
    const hour: u32 = @intCast(tm_result.tm_hour);
    const min: u32 = @intCast(tm_result.tm_min);
    const sec: u32 = @intCast(tm_result.tm_sec);

    const len = std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}", .{
        year, month, day, hour, min, sec,
    }) catch return "00000000_000000";

    return len;
}

/// Generate a unique job ID (UUID v4)
pub fn generateJobId(allocator: Allocator) ![]const u8 {
    var uuid_bytes: [16]u8 = undefined;
    // Use time + address space entropy for randomness
    var timer = Timer.start() catch unreachable;
    const now = timer.read();
    const addr: u64 = @intFromPtr(&uuid_bytes);
    const seed: u64 = now ^ addr;
    var prng = std.Random.DefaultPrng.init(seed);
    prng.fill(&uuid_bytes);

    // Set version (4) and variant (RFC 4122)
    uuid_bytes[6] = (uuid_bytes[6] & 0x0f) | 0x40;
    uuid_bytes[8] = (uuid_bytes[8] & 0x3f) | 0x80;

    // Format as hex string
    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        uuid_bytes[0],  uuid_bytes[1],  uuid_bytes[2],  uuid_bytes[3],
        uuid_bytes[4],  uuid_bytes[5],
        uuid_bytes[6],  uuid_bytes[7],
        uuid_bytes[8],  uuid_bytes[9],
        uuid_bytes[10], uuid_bytes[11], uuid_bytes[12], uuid_bytes[13], uuid_bytes[14], uuid_bytes[15],
    });
}

// ============================================================================
// File System Helpers
// ============================================================================

/// Ensure a directory exists (create recursively if necessary)
fn ensureDir(path: []const u8) !void {
    // Create directory tree by creating each component
    var buf: [4096]u8 = undefined;
    var i: usize = 0;

    // Find each path separator and create intermediate directories
    while (i < path.len) : (i += 1) {
        if (path[i] == '/' and i > 0) {
            const partial = std.fmt.bufPrintZ(&buf, "{s}", .{path[0..i]}) catch return error.PathTooLong;
            _ = std.c.mkdir(partial, 0o755);
        }
    }

    // Create final directory
    const full = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return error.PathTooLong;
    _ = std.c.mkdir(full, 0o755);
}

/// Write data to a file using C stdio
fn writeFile(path: []const u8, data: []const u8) !void {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.PathTooLong;

    const file = std.c.fopen(path_z, "wb") orelse return error.FileOpenFailed;
    defer _ = std.c.fclose(file);

    const written = std.c.fwrite(data.ptr, 1, data.len, file);
    if (written != data.len) return error.WriteError;
}

/// Read data from a file
pub fn readFile(allocator: Allocator, path: []const u8) ![]u8 {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.PathTooLong;

    const file = std.c.fopen(path_z, "rb") orelse return error.FileOpenFailed;
    defer _ = std.c.fclose(file);

    // Get file size using extern functions
    _ = fseek(file, 0, SEEK_END);
    const size_long = ftell(file);
    if (size_long < 0) return error.FileSizeError;
    const size: usize = @intCast(size_long);
    _ = fseek(file, 0, SEEK_SET);

    // Check size limit
    if (size > 100 * 1024 * 1024) return error.FileTooLarge;

    // Allocate and read
    const buffer = try allocator.alloc(u8, size);
    errdefer allocator.free(buffer);

    const read = fread(buffer.ptr, 1, size, file);
    if (read != size) {
        allocator.free(buffer);
        return error.ReadError;
    }

    return buffer;
}

// ============================================================================
// Display Helpers
// ============================================================================

/// Format file size for display
pub fn formatSize(size: usize) struct { value: f64, unit: []const u8 } {
    if (size >= 1024 * 1024) {
        return .{ .value = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0), .unit = "MB" };
    } else if (size >= 1024) {
        return .{ .value = @as(f64, @floatFromInt(size)) / 1024.0, .unit = "KB" };
    } else {
        return .{ .value = @as(f64, @floatFromInt(size)), .unit = "B" };
    }
}

/// Print storage paths to stdout
pub fn printSavedPaths(response: *const ImageResponse, writer: anytype) !void {
    try writer.print("\n{s} Saved {d} image(s):\n", .{
        "\x1b[32m✓\x1b[0m", // Green checkmark
        response.images.len,
    });

    for (response.images) |img| {
        const size = formatSize(img.data.len);
        try writer.print("  → {s} ({d:.1} {s})\n", .{
            img.local_path,
            size.value,
            size.unit,
        });
    }
}

// ============================================================================
// Tests
// ============================================================================

test "generateJobId produces valid UUID format" {
    const allocator = std.testing.allocator;
    const id = try generateJobId(allocator);
    defer allocator.free(id);

    // UUID format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (36 chars)
    try std.testing.expectEqual(@as(usize, 36), id.len);
    try std.testing.expectEqual(@as(u8, '-'), id[8]);
    try std.testing.expectEqual(@as(u8, '-'), id[13]);
    try std.testing.expectEqual(@as(u8, '-'), id[18]);
    try std.testing.expectEqual(@as(u8, '-'), id[23]);
}

test "formatSize" {
    const kb = formatSize(2048);
    try std.testing.expectEqual(@as(f64, 2.0), kb.value);
    try std.testing.expectEqualStrings("KB", kb.unit);

    const mb = formatSize(5 * 1024 * 1024);
    try std.testing.expectEqual(@as(f64, 5.0), mb.value);
    try std.testing.expectEqualStrings("MB", mb.unit);
}

test "getDefaultStorePath" {
    const allocator = std.testing.allocator;
    const path = try getDefaultStorePath(allocator);
    defer allocator.free(path);
    try std.testing.expect(path.len > 0);
}

test "getPlatformStorePath returns valid path" {
    const allocator = std.testing.allocator;
    const path = getPlatformStorePath(allocator) catch |err| {
        // On iOS or no HOME, may return NoPlatformDefault
        try std.testing.expect(err == error.NoPlatformDefault);
        return;
    };
    defer allocator.free(path);
    try std.testing.expect(path.len > 0);
}

test "resolveStorageConfig uses output_path override" {
    const allocator = std.testing.allocator;
    const config = types.MediaConfig{
        .media_store_path = "/custom/store",
        .output_dir = "/custom/output",
    };
    const resolved = try resolveStorageConfig(allocator, config, "/explicit/path");
    defer allocator.free(resolved.store_path_owned);
    defer allocator.free(resolved.local_path_owned);

    try std.testing.expectEqualStrings("/explicit/path", resolved.config.local_path);
    try std.testing.expectEqualStrings("/custom/store", resolved.config.store_path);
    try std.testing.expect(resolved.config.use_central_store);
}

test "resolveStorageConfig uses output_dir when no output_path" {
    const allocator = std.testing.allocator;
    const config = types.MediaConfig{
        .output_dir = "/photos",
    };
    const resolved = try resolveStorageConfig(allocator, config, null);
    defer allocator.free(resolved.store_path_owned);
    defer allocator.free(resolved.local_path_owned);

    try std.testing.expectEqualStrings("/photos", resolved.config.local_path);
}

test "resolveStorageConfig defaults to dot" {
    const allocator = std.testing.allocator;
    const config = types.MediaConfig{};
    const resolved = try resolveStorageConfig(allocator, config, null);
    defer allocator.free(resolved.store_path_owned);
    defer allocator.free(resolved.local_path_owned);

    try std.testing.expectEqualStrings(".", resolved.config.local_path);
    try std.testing.expect(resolved.config.use_central_store);
}

test "resolveStorageConfig disable_central_store" {
    const allocator = std.testing.allocator;
    const config = types.MediaConfig{
        .disable_central_store = true,
    };
    const resolved = try resolveStorageConfig(allocator, config, null);
    defer allocator.free(resolved.store_path_owned);
    defer allocator.free(resolved.local_path_owned);

    try std.testing.expect(!resolved.config.use_central_store);
    try std.testing.expect(!resolved.config.save_metadata);
}
