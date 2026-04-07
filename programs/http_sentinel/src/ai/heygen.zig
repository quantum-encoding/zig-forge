// Copyright (c) 2025 QUANTUM ENCODING LTD
//! HeyGen video synthesis & digital human API client.
//!
//! Supports: video agent (simple), studio v2 (avatar+voice), avatar/voice listing.
//! Auth: x-api-key header with HEYGEN_API_KEY env var.

const std = @import("std");
const HttpClient = @import("../http_client.zig").HttpClient;
const common = @import("common.zig");

const API_BASE = "https://api.heygen.com";

pub const HeyGenClient = struct {
    http_client: HttpClient,
    api_key: []const u8,
    allocator: std.mem.Allocator,

    const POLL_INTERVAL_MS: u64 = 5000;
    const MAX_POLLS: u32 = 120; // 10 minutes

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !HeyGenClient {
        return .{
            .http_client = try HttpClient.init(allocator),
            .api_key = api_key,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HeyGenClient) void {
        self.http_client.deinit();
    }

    /// Video Agent: simple prompt → video generation.
    pub fn generateVideoAgent(self: *HeyGenClient, prompt: []const u8) ![]u8 {
        const escaped = try common.escapeJsonString(self.allocator, prompt);
        defer self.allocator.free(escaped);

        const payload = try std.fmt.allocPrint(self.allocator,
            \\{{"prompt":"{s}"}}
        , .{escaped});
        defer self.allocator.free(payload);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "x-api-key", .value = self.api_key },
        };

        var response = try self.http_client.post(API_BASE ++ "/v1/video_agent/generate", &headers, payload);
        defer response.deinit();
        if (response.status != .ok) return common.AIError.ApiRequestFailed;

        // Parse {"data": {"video_id": "..."}}
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();
        const data = parsed.value.object.get("data") orelse return common.AIError.InvalidResponse;
        const video_id = data.object.get("video_id") orelse return common.AIError.InvalidResponse;
        return try self.allocator.dupe(u8, video_id.string);
    }

    /// Studio v2: avatar + script + voice → video.
    pub fn generateStudioVideo(
        self: *HeyGenClient,
        avatar_id: []const u8,
        script_text: []const u8,
        voice_id: ?[]const u8,
        width: u32,
        height: u32,
    ) ![]u8 {
        const escaped_text = try common.escapeJsonString(self.allocator, script_text);
        defer self.allocator.free(escaped_text);

        // Build voice section
        var voice_part: []u8 = undefined;
        if (voice_id) |vid| {
            voice_part = try std.fmt.allocPrint(self.allocator,
                \\,"voice_id":"{s}"
            , .{vid});
        } else {
            voice_part = try self.allocator.dupe(u8, "");
        }
        defer self.allocator.free(voice_part);

        const payload = try std.fmt.allocPrint(self.allocator,
            \\{{"video_inputs":[{{"character":{{"type":"avatar","avatar_id":"{s}"}},"voice":{{"type":"text","input_text":"{s}"{s}}}}}],"dimension":{{"width":{},"height":{}}}}}
        , .{ avatar_id, escaped_text, voice_part, width, height });
        defer self.allocator.free(payload);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "x-api-key", .value = self.api_key },
        };

        var response = try self.http_client.post(API_BASE ++ "/v2/video/generate", &headers, payload);
        defer response.deinit();
        if (response.status != .ok) return common.AIError.ApiRequestFailed;

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();
        const data = parsed.value.object.get("data") orelse return common.AIError.InvalidResponse;
        const video_id = data.object.get("video_id") orelse return common.AIError.InvalidResponse;
        return try self.allocator.dupe(u8, video_id.string);
    }

    /// Poll video status until complete. Returns video_url on success.
    pub fn pollVideo(self: *HeyGenClient, video_id: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(self.allocator,
            API_BASE ++ "/v1/video_status.get?video_id={s}", .{video_id});
        defer self.allocator.free(url);

        const headers = [_]std.http.Header{
            .{ .name = "x-api-key", .value = self.api_key },
        };

        var polls: u32 = 0;
        while (polls < MAX_POLLS) : (polls += 1) {
            var response = try self.http_client.get(url, &headers);
            defer response.deinit();
            if (response.status != .ok) return common.AIError.ApiRequestFailed;

            const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
            defer parsed.deinit();

            const data = parsed.value.object.get("data") orelse return common.AIError.InvalidResponse;
            const status = data.object.get("status") orelse return common.AIError.InvalidResponse;

            if (std.mem.eql(u8, status.string, "completed")) {
                if (data.object.get("video_url")) |url_val| {
                    return try self.allocator.dupe(u8, url_val.string);
                }
                return common.AIError.InvalidResponse;
            }

            if (std.mem.eql(u8, status.string, "failed")) {
                return common.AIError.ApiRequestFailed;
            }

            // Sleep between polls (pure Zig via Io)
            self.http_client.io().sleep(std.Io.Duration.fromMilliseconds(POLL_INTERVAL_MS), .awake) catch {};
        }

        return common.AIError.RequestTimeout;
    }

    /// List available avatars.
    pub fn listAvatars(self: *HeyGenClient) ![]u8 {
        const headers = [_]std.http.Header{
            .{ .name = "x-api-key", .value = self.api_key },
        };
        var response = try self.http_client.get(API_BASE ++ "/v2/avatars", &headers);
        defer response.deinit();
        if (response.status != .ok) return common.AIError.ApiRequestFailed;
        return try self.allocator.dupe(u8, response.body);
    }

    /// List available voices.
    pub fn listVoices(self: *HeyGenClient) ![]u8 {
        const headers = [_]std.http.Header{
            .{ .name = "x-api-key", .value = self.api_key },
        };
        var response = try self.http_client.get(API_BASE ++ "/v2/voices", &headers);
        defer response.deinit();
        if (response.status != .ok) return common.AIError.ApiRequestFailed;
        return try self.allocator.dupe(u8, response.body);
    }
};
