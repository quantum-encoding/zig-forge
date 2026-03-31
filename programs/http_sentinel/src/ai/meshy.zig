// Copyright (c) 2025 QUANTUM ENCODING LTD
//! Meshy 3D model generation API client.
//!
//! Supports: text-to-3D, image-to-3D, remesh, retexture, rig, animate.
//! All operations are async — submit job, poll status, get result URLs.
//! Auth: Authorization: Bearer with MESHY_API_KEY env var.

const std = @import("std");
const HttpClient = @import("../http_client.zig").HttpClient;
const common = @import("common.zig");

const API_BASE = "https://api.meshy.ai/openapi";

pub const Models = struct {
    pub const MESHY_6 = "meshy-6";
    pub const MESHY_5 = "meshy-5";
    pub const LATEST = "latest";
};

pub const TaskStatus = enum {
    pending,
    in_progress,
    succeeded,
    failed,
    canceled,

    pub fn fromString(s: []const u8) TaskStatus {
        if (std.mem.eql(u8, s, "PENDING")) return .pending;
        if (std.mem.eql(u8, s, "IN_PROGRESS")) return .in_progress;
        if (std.mem.eql(u8, s, "SUCCEEDED")) return .succeeded;
        if (std.mem.eql(u8, s, "FAILED")) return .failed;
        if (std.mem.eql(u8, s, "CANCELED")) return .canceled;
        return .pending;
    }

    pub fn isTerminal(self: TaskStatus) bool {
        return self == .succeeded or self == .failed or self == .canceled;
    }
};

/// Result from a 3D generation task.
pub const TaskResult = struct {
    id: []const u8,
    status: TaskStatus,
    progress: u8,
    model_urls: ?ModelUrls,
    thumbnail_url: ?[]const u8,
    error_message: ?[]const u8,
};

pub const ModelUrls = struct {
    glb: ?[]const u8 = null,
    fbx: ?[]const u8 = null,
    obj: ?[]const u8 = null,
    usdz: ?[]const u8 = null,
};

pub const MeshyClient = struct {
    http_client: HttpClient,
    api_key: []const u8,
    allocator: std.mem.Allocator,

    const POLL_INTERVAL_MS: u64 = 5000;
    const MAX_POLLS: u32 = 120; // 10 minutes

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) !MeshyClient {
        return .{
            .http_client = try HttpClient.init(allocator),
            .api_key = api_key,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MeshyClient) void {
        self.http_client.deinit();
    }

    fn authHeader(self: *MeshyClient) [2]std.http.Header {
        var auth_buf: [256]u8 = undefined;
        const auth = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.api_key}) catch "Bearer ";
        return .{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth },
        };
    }

    /// Text-to-3D: submit job, return task ID.
    pub fn textTo3D(
        self: *MeshyClient,
        prompt: []const u8,
        model: []const u8,
        mode: []const u8, // "preview" or "refine"
    ) ![]u8 {
        const escaped = try common.escapeJsonString(self.allocator, prompt);
        defer self.allocator.free(escaped);

        const payload = try std.fmt.allocPrint(self.allocator,
            \\{{"mode":"{s}","prompt":"{s}","ai_model":"{s}","topology":"triangle"}}
        , .{ mode, escaped, model });
        defer self.allocator.free(payload);

        const headers = self.authHeader();
        var response = try self.http_client.post(API_BASE ++ "/v2/text-to-3d", &headers, payload);
        defer response.deinit();
        if (response.status != .ok) return common.AIError.ApiRequestFailed;

        // Parse {"result": "task_id"}
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();
        const task_id = parsed.value.object.get("result") orelse return common.AIError.InvalidResponse;
        return try self.allocator.dupe(u8, task_id.string);
    }

    /// Image-to-3D: submit job with image URL.
    pub fn imageTo3D(self: *MeshyClient, image_url: []const u8, model: []const u8) ![]u8 {
        const escaped = try common.escapeJsonString(self.allocator, image_url);
        defer self.allocator.free(escaped);

        const payload = try std.fmt.allocPrint(self.allocator,
            \\{{"image_url":"{s}","ai_model":"{s}","should_texture":true,"topology":"triangle"}}
        , .{ escaped, model });
        defer self.allocator.free(payload);

        const headers = self.authHeader();
        var response = try self.http_client.post(API_BASE ++ "/v1/image-to-3d", &headers, payload);
        defer response.deinit();
        if (response.status != .ok) return common.AIError.ApiRequestFailed;

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();
        const task_id = parsed.value.object.get("result") orelse return common.AIError.InvalidResponse;
        return try self.allocator.dupe(u8, task_id.string);
    }

    /// Remesh: re-topology an existing 3D model.
    pub fn remesh(self: *MeshyClient, input_task_id: []const u8, target_polycount: u32) ![]u8 {
        const payload = try std.fmt.allocPrint(self.allocator,
            \\{{"input_task_id":"{s}","target_formats":["glb","fbx","obj","usdz"],"topology":"quad","target_polycount":{}}}
        , .{ input_task_id, target_polycount });
        defer self.allocator.free(payload);

        const headers = self.authHeader();
        var response = try self.http_client.post(API_BASE ++ "/v1/remesh", &headers, payload);
        defer response.deinit();
        if (response.status != .ok) return common.AIError.ApiRequestFailed;

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();
        const task_id = parsed.value.object.get("result") orelse return common.AIError.InvalidResponse;
        return try self.allocator.dupe(u8, task_id.string);
    }

    /// Retexture: generate new textures for a 3D model.
    pub fn retexture(self: *MeshyClient, input_task_id: []const u8, style_prompt: []const u8) ![]u8 {
        const escaped = try common.escapeJsonString(self.allocator, style_prompt);
        defer self.allocator.free(escaped);

        const payload = try std.fmt.allocPrint(self.allocator,
            \\{{"input_task_id":"{s}","text_style_prompt":"{s}","ai_model":"meshy-6","enable_pbr":true}}
        , .{ input_task_id, escaped });
        defer self.allocator.free(payload);

        const headers = self.authHeader();
        var response = try self.http_client.post(API_BASE ++ "/v1/retexture", &headers, payload);
        defer response.deinit();
        if (response.status != .ok) return common.AIError.ApiRequestFailed;

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
        defer parsed.deinit();
        const task_id = parsed.value.object.get("result") orelse return common.AIError.InvalidResponse;
        return try self.allocator.dupe(u8, task_id.string);
    }

    /// Poll task status until terminal state. Returns raw JSON response.
    pub fn pollTask(self: *MeshyClient, endpoint_path: []const u8, task_id: []const u8) ![]u8 {
        const url = try std.fmt.allocPrint(self.allocator, API_BASE ++ "{s}/{s}", .{ endpoint_path, task_id });
        defer self.allocator.free(url);

        const auth_val = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_val);
        const headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_val },
        };

        var polls: u32 = 0;
        while (polls < MAX_POLLS) : (polls += 1) {
            var response = try self.http_client.get(url, &headers);
            defer response.deinit();

            if (response.status != .ok) return common.AIError.ApiRequestFailed;

            // Check if terminal
            const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{});
            defer parsed.deinit();

            if (parsed.value.object.get("status")) |status_val| {
                const status = TaskStatus.fromString(status_val.string);
                if (status.isTerminal()) {
                    return try self.allocator.dupe(u8, response.body);
                }
            }

            // Sleep 5 seconds
            const c = @cImport({ @cInclude("unistd.h"); });
            _ = c.usleep(POLL_INTERVAL_MS * 1000);
        }

        return common.AIError.RequestTimeout;
    }
};
