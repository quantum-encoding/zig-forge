// xAI Grok Imagine Video Generation Provider
// Supports: video generation and video editing via Grok Imagine Video

const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;

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

const XAI_VIDEO_API = "https://api.x.ai/v1/videos/generations";
const XAI_VIDEO_EDIT_API = "https://api.x.ai/v1/videos/edits";
const XAI_VIDEO_STATUS_API = "https://api.x.ai/v1/videos";

// ============================================================================
// Grok Imagine Video Generation
// ============================================================================

pub fn generateGrokVideo(
    allocator: Allocator,
    request: VideoRequest,
    config: MediaConfig,
) !VideoResponse {
    const api_key = config.xai_api_key orelse return error.MissingApiKey;
    var timer = Timer.start() catch unreachable;

    const model = request.model orelse "grok-imagine-video";
    const duration: u8 = request.duration orelse 6;

    // Build JSON payload
    const escaped_prompt = try escapeJson(allocator, request.prompt);
    defer allocator.free(escaped_prompt);

    const payload = try std.fmt.allocPrint(allocator,
        \\{{"prompt":"{s}","model":"{s}","duration":{d}}}
    , .{ escaped_prompt, model, duration });
    defer allocator.free(payload);

    // POST to start video generation
    var client = try HttpClient.init(allocator);
    defer client.deinit();

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    const headers = [_]http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Accept-Encoding", .value = "identity" },
    };

    std.debug.print("  Starting render job...\n", .{});

    var http_response = try client.post(XAI_VIDEO_API, &headers, payload);
    defer http_response.deinit();

    if (http_response.status != .ok and http_response.status != .created and http_response.status != .accepted) {
        std.debug.print("xAI Video API error ({any}): {s}\n", .{ http_response.status, http_response.body });
        return error.ApiError;
    }

    // Parse response to get request_id
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, http_response.body, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = parsed.value.object;
    const request_id_val = root.get("request_id") orelse return error.InvalidResponse;

    std.debug.print("  Request ID: {s}\n", .{request_id_val.string});
    std.debug.print("  Polling for completion...\n", .{});

    // Poll for completion and download video
    const video_data = try pollForCompletion(allocator, api_key, request_id_val.string);
    defer allocator.free(video_data);

    // Build response
    const job_id = try storage.generateJobId(allocator);
    const elapsed_ns = timer.read();

    var result = VideoResponse{
        .job_id = job_id,
        .provider = .grok_video,
        .original_prompt = try allocator.dupe(u8, request.prompt),
        .videos = &.{},
        .processing_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
        .model_used = try allocator.dupe(u8, model),
        .allocator = allocator,
    };

    // Save video
    const resolved = try storage.resolveStorageConfig(allocator, config, request.output_path);
    defer allocator.free(resolved.store_path_owned);
    defer allocator.free(resolved.local_path_owned);

    try storage.saveVideo(allocator, &result, video_data, .mp4, resolved.config);

    return result;
}

/// Edit an existing video by URL + prompt
pub fn editGrokVideo(
    allocator: Allocator,
    prompt: []const u8,
    video_url: []const u8,
    config: MediaConfig,
) !VideoResponse {
    const api_key = config.xai_api_key orelse return error.MissingApiKey;
    var timer = Timer.start() catch unreachable;

    // Build JSON payload
    const escaped_prompt = try escapeJson(allocator, prompt);
    defer allocator.free(escaped_prompt);

    const escaped_url = try escapeJson(allocator, video_url);
    defer allocator.free(escaped_url);

    const payload = try std.fmt.allocPrint(allocator,
        \\{{"prompt":"{s}","video":{{"url":"{s}"}},"model":"grok-imagine-video"}}
    , .{ escaped_prompt, escaped_url });
    defer allocator.free(payload);

    // POST to start video edit
    var client = try HttpClient.init(allocator);
    defer client.deinit();

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    const headers = [_]http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Accept-Encoding", .value = "identity" },
    };

    std.debug.print("  Starting video edit job...\n", .{});

    var http_response = try client.post(XAI_VIDEO_EDIT_API, &headers, payload);
    defer http_response.deinit();

    if (http_response.status != .ok and http_response.status != .created and http_response.status != .accepted) {
        std.debug.print("xAI Video Edit API error ({any}): {s}\n", .{ http_response.status, http_response.body });
        return error.ApiError;
    }

    // Parse response to get request_id
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, http_response.body, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = parsed.value.object;
    const request_id_val = root.get("request_id") orelse return error.InvalidResponse;

    std.debug.print("  Request ID: {s}\n", .{request_id_val.string});
    std.debug.print("  Polling for completion...\n", .{});

    // Poll for completion and download video
    const video_data = try pollForCompletion(allocator, api_key, request_id_val.string);
    defer allocator.free(video_data);

    // Build response
    const job_id = try storage.generateJobId(allocator);
    const elapsed_ns = timer.read();

    var result = VideoResponse{
        .job_id = job_id,
        .provider = .grok_video,
        .original_prompt = try allocator.dupe(u8, prompt),
        .videos = &.{},
        .processing_time_ms = @intCast(elapsed_ns / std.time.ns_per_ms),
        .model_used = try allocator.dupe(u8, "grok-imagine-video"),
        .allocator = allocator,
    };

    // Save video
    const resolved = try storage.resolveStorageConfig(allocator, config, null);
    defer allocator.free(resolved.store_path_owned);
    defer allocator.free(resolved.local_path_owned);

    try storage.saveVideo(allocator, &result, video_data, .mp4, resolved.config);

    return result;
}

// ============================================================================
// Internal: Polling and Download
// ============================================================================

fn pollForCompletion(allocator: Allocator, api_key: []const u8, request_id: []const u8) ![]u8 {
    var client = try HttpClient.init(allocator);
    defer client.deinit();

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    const status_url = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ XAI_VIDEO_STATUS_API, request_id });
    defer allocator.free(status_url);

    const headers = [_]http.Header{
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Accept-Encoding", .value = "identity" },
    };

    const max_polls: u32 = 120; // 20 minutes max (10s intervals)
    var poll_count: u32 = 0;

    while (poll_count < max_polls) : (poll_count += 1) {
        var response = try client.get(status_url, &headers);
        defer response.deinit();

        if (response.status != .ok and response.status != .accepted) {
            std.debug.print("xAI Video status error ({any}): {s}\n", .{ response.status, response.body });
            return error.ApiError;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{
            .allocate = .alloc_always,
        }) catch {
            std.debug.print("\n  Parse error on poll response\n", .{});
            return error.InvalidResponse;
        };
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidResponse;
        const root = parsed.value.object;

        // Completion: response has "video" object with "url" (no "status" field when done)
        if (root.get("video")) |video_obj| {
            if (video_obj == .object) {
                if (video_obj.object.get("url")) |video_url| {
                    std.debug.print("\n  Render complete! Downloading video...\n", .{});
                    return downloadFromUrl(allocator, api_key, video_url.string);
                }
            }
        }

        // Check explicit status field (pending or failed)
        if (root.get("status")) |status| {
            if (status == .string) {
                if (std.mem.eql(u8, status.string, "failed") or std.mem.eql(u8, status.string, "error")) {
                    const err_msg = root.get("error");
                    if (err_msg) |e| {
                        if (e == .string) {
                            std.debug.print("\n  Render failed: {s}\n", .{e.string});
                        } else if (e == .object) {
                            if (e.object.get("message")) |msg| {
                                std.debug.print("\n  Render failed: {s}\n", .{msg.string});
                            }
                        }
                    }
                    return error.RenderFailed;
                }
            }
        }

        // Show progress
        const progress: u32 = @intCast(@min(poll_count * 100 / max_polls, 99));
        printProgress(progress);

        // Wait 10 seconds before next poll
        const ts = std.c.timespec{ .sec = 10, .nsec = 0 };
        _ = std.c.nanosleep(&ts, null);
    }

    return error.Timeout;
}

fn downloadFromUrl(allocator: Allocator, api_key: []const u8, url: []const u8) ![]u8 {
    var client = try HttpClient.init(allocator);
    defer client.deinit();

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    const headers = [_]http.Header{
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Accept-Encoding", .value = "identity" },
    };

    var response = try client.get(url, &headers);
    defer response.deinit();

    if (response.status != .ok) {
        std.debug.print("xAI Video download error: {s}\n", .{response.body});
        return error.DownloadFailed;
    }

    return allocator.dupe(u8, response.body);
}

fn printProgress(progress: u32) void {
    const bar_len: u32 = 30;
    const filled = (progress * bar_len) / 100;
    var bar: [30]u8 = undefined;
    for (0..bar_len) |i| {
        bar[i] = if (i < filled) '=' else '-';
    }
    std.debug.print("\r  Rendering: [{s}] {d}%  ", .{ bar[0..bar_len], progress });
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
