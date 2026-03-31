// OpenAI Sora Video Generation Provider
// Supports: Sora 2, Sora 2 Pro

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

const SORA_API_URL = "https://api.openai.com/v1/videos";

// ============================================================================
// Sora Video Generation
// ============================================================================

pub fn generateSora(
    allocator: Allocator,
    request: VideoRequest,
    config: MediaConfig,
) !VideoResponse {
    const api_key = config.openai_api_key orelse return error.MissingApiKey;
    var timer = Timer.start() catch unreachable;

    const model = request.model orelse "sora-2-2025-12-08";
    const size = request.size orelse "1280x720";
    // Sora only accepts duration as string: "4", "8", or "12"
    const duration_str = if (request.duration) |d|
        if (d <= 4) "4" else if (d <= 8) "8" else "12"
    else
        "8";

    // Build JSON payload for video generation
    const escaped_prompt = try escapeJson(allocator, request.prompt);
    defer allocator.free(escaped_prompt);

    const payload = try std.fmt.allocPrint(allocator,
        \\{{"model":"{s}","prompt":"{s}","size":"{s}","seconds":"{s}"}}
    , .{ model, escaped_prompt, size, duration_str });
    defer allocator.free(payload);

    // Make HTTP request to start video generation
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

    var http_response = try client.post(SORA_API_URL, &headers, payload);
    defer http_response.deinit();

    if (http_response.status != .ok and http_response.status != .created and http_response.status != .accepted) {
        std.debug.print("Sora API error ({any}): {s}\n", .{ http_response.status, http_response.body });
        return error.ApiError;
    }

    // Parse response to get video ID
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, http_response.body, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const root = parsed.value.object;
    const video_id = root.get("id") orelse return error.InvalidResponse;

    std.debug.print("  Video ID: {s}\n", .{video_id.string});
    std.debug.print("  Polling for completion...\n", .{});

    // Poll for completion
    const video_data = try pollForCompletion(allocator, api_key, video_id.string);
    defer allocator.free(video_data);

    // Generate job ID and build response
    const job_id = try storage.generateJobId(allocator);
    const elapsed_ns = timer.read();

    var result = VideoResponse{
        .job_id = job_id,
        .provider = .sora,
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

fn pollForCompletion(allocator: Allocator, api_key: []const u8, video_id: []const u8) ![]u8 {
    var client = try HttpClient.init(allocator);
    defer client.deinit();

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    const status_url = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ SORA_API_URL, video_id });
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

        if (response.status != .ok) {
            std.debug.print("Sora status error: {s}\n", .{response.body});
            return error.ApiError;
        }

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();

        const root = parsed.value.object;
        const status = root.get("status") orelse return error.InvalidResponse;

        if (std.mem.eql(u8, status.string, "completed")) {
            std.debug.print("\n  Render complete! Downloading video...\n", .{});
            return downloadVideo(allocator, api_key, video_id);
        } else if (std.mem.eql(u8, status.string, "failed")) {
            const err_obj = root.get("error");
            if (err_obj) |e| {
                if (e.object.get("message")) |msg| {
                    std.debug.print("\n  Render failed: {s}\n", .{msg.string});
                }
            }
            return error.RenderFailed;
        }

        // Show progress
        const progress = if (root.get("progress")) |p| p.integer else 0;
        printProgress(@intCast(progress));

        // Wait before next poll (10 seconds)
        const ts = std.c.timespec{ .sec = 10, .nsec = 0 };
        _ = std.c.nanosleep(&ts, null);
    }

    return error.Timeout;
}

fn downloadVideo(allocator: Allocator, api_key: []const u8, video_id: []const u8) ![]u8 {
    var client = try HttpClient.init(allocator);
    defer client.deinit();

    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    const download_url = try std.fmt.allocPrint(allocator, "{s}/{s}/content", .{ SORA_API_URL, video_id });
    defer allocator.free(download_url);

    const headers = [_]http.Header{
        .{ .name = "Authorization", .value = auth_header },
        .{ .name = "Accept-Encoding", .value = "identity" },
    };

    var response = try client.get(download_url, &headers);
    defer response.deinit();

    if (response.status != .ok) {
        std.debug.print("Sora download error: {s}\n", .{response.body});
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
