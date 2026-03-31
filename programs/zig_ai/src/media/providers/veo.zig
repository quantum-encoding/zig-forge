// Google Veo Video Generation Provider
// Supports: Veo 2.0 via Gemini API

const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;

// Extern C functions for running shell commands and file operations
extern "c" fn system(command: [*:0]const u8) c_int;
extern "c" fn remove(path: [*:0]const u8) c_int;

const types = @import("../types.zig");
const storage = @import("../storage.zig");
const Timer = @import("../../timer.zig").Timer;
const VideoRequest = types.VideoRequest;
const VideoResponse = types.VideoResponse;
const MediaConfig = types.MediaConfig;

const http_sentinel = @import("http-sentinel");
const HttpClient = http_sentinel.HttpClient;

// ============================================================================
// API Constants
// ============================================================================

const VEO_MODEL = "veo-3.1-generate-001";
const VEO_API_BASE = "https://generativelanguage.googleapis.com/v1beta";

// ============================================================================
// Veo Video Generation (GenAI API)
// ============================================================================

pub fn generateVeo(
    allocator: Allocator,
    request: VideoRequest,
    config: MediaConfig,
) !VideoResponse {
    const api_key = config.genai_api_key orelse return error.MissingApiKey;
    var timer = Timer.start() catch unreachable;

    const aspect_ratio = request.aspect_ratio orelse "16:9";
    const duration = request.duration orelse 8;
    const resolution = request.resolution orelse "720p";

    // Build JSON payload
    const escaped_prompt = try escapeJson(allocator, request.prompt);
    defer allocator.free(escaped_prompt);

    // Build parameters part
    const params = try std.fmt.allocPrint(allocator,
        \\,"parameters":{{"aspectRatio":"{s}","durationSeconds":{d},"resolution":"{s}"}}
    , .{ aspect_ratio, duration, resolution });
    defer allocator.free(params);

    const payload = try std.fmt.allocPrint(allocator,
        \\{{"instances":[{{"prompt":"{s}"}}]{s}}}
    , .{ escaped_prompt, params });
    defer allocator.free(payload);

    // Build URL with API key
    const url = try std.fmt.allocPrint(allocator,
        "{s}/models/{s}:predictLongRunning?key={s}",
        .{ VEO_API_BASE, VEO_MODEL, api_key },
    );
    defer allocator.free(url);

    // Make HTTP request to start video generation
    var client = try HttpClient.init(allocator);
    defer client.deinit();

    const headers = [_]http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept-Encoding", .value = "identity" },
    };

    std.debug.print("  Starting video generation...\n", .{});

    var http_response = try client.post(url, &headers, payload);
    defer http_response.deinit();

    if (http_response.status != .ok) {
        std.debug.print("Veo API error ({any}): {s}\n", .{ http_response.status, http_response.body });
        return error.ApiError;
    }

    // Parse response to get operation name
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, http_response.body, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = parsed.value.object;
    const operation_name = root.get("name") orelse return error.InvalidResponse;

    std.debug.print("  Operation: {s}\n", .{operation_name.string});
    std.debug.print("  Polling for completion...\n", .{});

    // Poll for completion
    const video_data = try pollForCompletion(allocator, api_key, operation_name.string);
    defer allocator.free(video_data);

    // Generate job ID and build response
    const job_id = try storage.generateJobId(allocator);
    const elapsed_ns = timer.read();

    var result = VideoResponse{
        .job_id = job_id,
        .provider = .veo,
        .original_prompt = try allocator.dupe(u8, request.prompt),
        .videos = &.{},
        .processing_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
        .model_used = try allocator.dupe(u8, VEO_MODEL),
        .allocator = allocator,
    };

    // Save video
    const resolved = try storage.resolveStorageConfig(allocator, config, request.output_path);
    defer allocator.free(resolved.store_path_owned);
    defer allocator.free(resolved.local_path_owned);

    try storage.saveVideo(allocator, &result, video_data, .mp4, resolved.config);

    return result;
}

fn pollForCompletion(allocator: Allocator, api_key: []const u8, operation_name: []const u8) ![]u8 {
    var client = try HttpClient.init(allocator);
    defer client.deinit();

    const status_url = try std.fmt.allocPrint(allocator, "{s}/{s}?key={s}", .{ VEO_API_BASE, operation_name, api_key });
    defer allocator.free(status_url);

    const headers = [_]http.Header{
        .{ .name = "Accept-Encoding", .value = "identity" },
    };

    const max_polls: u32 = 60; // 10 minutes max (10s intervals)
    var poll_count: u32 = 0;

    while (poll_count < max_polls) : (poll_count += 1) {
        var response = try client.get(status_url, &headers);
        defer response.deinit();

        if (response.status != .ok) {
            std.debug.print("Veo status error: {s}\n", .{response.body});
            return error.ApiError;
        }

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const root = parsed.value.object;
        const done = root.get("done");

        if (done != null and done.?.bool) {
            // Check for error
            if (root.get("error")) |err| {
                std.debug.print("\n  Generation failed: {any}\n", .{err});
                return error.RenderFailed;
            }

            // Get response data
            if (root.get("response")) |resp| {
                std.debug.print("\n  Generation complete! Downloading video...\n", .{});
                return extractVideoData(allocator, api_key, resp);
            }

            return error.InvalidResponse;
        }

        // Show progress
        printProgress(poll_count);

        // Wait before next poll (10 seconds)
        const ts = std.c.timespec{ .sec = 10, .nsec = 0 };
        _ = std.c.nanosleep(&ts, null);
    }

    return error.Timeout;
}

fn extractVideoData(allocator: Allocator, api_key: []const u8, response: std.json.Value) ![]u8 {
    // GenAI response: generateVideoResponse.generatedSamples[].video.uri
    const gen_response = response.object.get("generateVideoResponse") orelse return error.InvalidResponse;
    const samples = gen_response.object.get("generatedSamples") orelse return error.InvalidResponse;

    if (samples.array.items.len == 0) {
        return error.NoVideosGenerated;
    }

    const first_sample = samples.array.items[0].object;
    const video = first_sample.get("video") orelse return error.InvalidResponse;
    const uri = video.object.get("uri") orelse return error.InvalidResponse;

    // Download video from URI
    return downloadFromUri(allocator, api_key, uri.string);
}

fn downloadFromUri(allocator: Allocator, api_key: []const u8, uri: []const u8) ![]u8 {
    // Add API key to URI (use ? if first param, & otherwise)
    const separator: []const u8 = if (std.mem.indexOf(u8, uri, "?") != null) "&" else "?";
    const download_url = try std.fmt.allocPrint(allocator, "{s}{s}key={s}", .{ uri, separator, api_key });
    defer allocator.free(download_url);

    // Try using HTTP client first
    var client = try HttpClient.init(allocator);
    defer client.deinit();

    const headers = [_]http.Header{
        .{ .name = "Accept-Encoding", .value = "identity" },
    };

    // Try HTTP client download with redirect handling
    var response = client.downloadLargeFile(download_url, &headers, .{
        .max_body_size = 100 * 1024 * 1024, // 100MB max for video
    }) catch {
        // Fall back to curl for downloads with very long redirect URLs
        std.debug.print("  Using curl for download (long redirect URL)...\n", .{});
        return downloadWithCurl(allocator, download_url);
    };
    defer response.deinit();

    if (response.status != .ok) {
        // If we get a non-OK status, try curl as fallback
        return downloadWithCurl(allocator, download_url);
    }

    const size_mb = @as(f64, @floatFromInt(response.body.len)) / (1024.0 * 1024.0);
    std.debug.print("  Downloaded: {d:.2} MB\n", .{size_mb});

    return allocator.dupe(u8, response.body);
}

fn downloadWithCurl(allocator: Allocator, url: []const u8) ![]u8 {
    // Create a temporary file path for curl output
    const tmp_path = "/tmp/veo_video_download.mp4";
    const url_file = "/tmp/veo_download_url.txt";

    // Write URL to file using shell echo
    var echo_cmd_buf: [8192]u8 = undefined;
    // Escape single quotes in URL for shell
    const echo_cmd = std.fmt.bufPrintZ(&echo_cmd_buf, "printf '%s' '{s}' > {s}", .{ url, url_file }) catch return error.CommandTooLong;
    _ = system(echo_cmd);

    // Build curl command that reads URL from file
    var cmd_buf: [512]u8 = undefined;
    const cmd = std.fmt.bufPrintZ(&cmd_buf, "curl -s -L -o {s} \"$(cat {s})\"", .{ tmp_path, url_file }) catch return error.CommandTooLong;

    const result = system(cmd);

    // Clean up URL file
    var rm_url: [256]u8 = undefined;
    const rm_url_cmd = std.fmt.bufPrintZ(&rm_url, "rm -f {s}", .{url_file}) catch unreachable;
    _ = system(rm_url_cmd);

    if (result != 0) {
        std.debug.print("  curl download failed with status: {d}\n", .{result});
        return error.CurlFailed;
    }

    // Read the downloaded file using storage module's readFile
    const video_data = storage.readFile(allocator, tmp_path) catch |err| {
        std.debug.print("  Failed to read video file: {any}\n", .{err});
        return error.ReadError;
    };

    // Clean up temp file
    var rm_cmd: [256]u8 = undefined;
    const rm_cmd_z = std.fmt.bufPrintZ(&rm_cmd, "rm -f {s}", .{tmp_path}) catch unreachable;
    _ = system(rm_cmd_z);

    const size_mb = @as(f64, @floatFromInt(video_data.len)) / (1024.0 * 1024.0);
    std.debug.print("  Downloaded: {d:.2} MB\n", .{size_mb});

    return video_data;
}

fn printProgress(poll_count: u32) void {
    const progress = @min((poll_count * 100) / 60, 99);
    const bar_len: u32 = 30;
    const filled = (progress * bar_len) / 100;
    var bar: [30]u8 = undefined;
    for (0..bar_len) |i| {
        bar[i] = if (i < filled) '=' else '-';
    }
    std.debug.print("\r  Generating: [{s}] ~{d}%  ", .{ bar[0..bar_len], progress });
}

// ============================================================================
// Helpers
// ============================================================================

fn escapeJson(allocator: Allocator, s: []const u8) ![]u8 {
    var extra: usize = 0;
    for (s) |c| {
        switch (c) {
            '"', '\\', '\n', '\r', '\t' => extra += 1,
            else => if (c < 0x20) {
                extra += 5;
            },
        }
    }

    const result = try allocator.alloc(u8, s.len + extra);
    var i: usize = 0;

    for (s) |c| {
        switch (c) {
            '"' => {
                result[i] = '\\';
                result[i + 1] = '"';
                i += 2;
            },
            '\\' => {
                result[i] = '\\';
                result[i + 1] = '\\';
                i += 2;
            },
            '\n' => {
                result[i] = '\\';
                result[i + 1] = 'n';
                i += 2;
            },
            '\r' => {
                result[i] = '\\';
                result[i + 1] = 'r';
                i += 2;
            },
            '\t' => {
                result[i] = '\\';
                result[i + 1] = 't';
                i += 2;
            },
            else => {
                if (c < 0x20) {
                    _ = std.fmt.bufPrint(result[i .. i + 6], "\\u{x:0>4}", .{c}) catch unreachable;
                    i += 6;
                } else {
                    result[i] = c;
                    i += 1;
                }
            },
        }
    }

    return result[0..i];
}
