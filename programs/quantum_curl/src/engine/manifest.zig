// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! HTTP Request/Response Manifest Format
//!
//! The Command Protocol - defines the declarative battle plan format for
//! quantum-curl operations. This is the language of command for distributed
//! service orchestration.
//!
//! ## Input Format (JSONL - JSON Lines)
//!
//! Each line is an independent request manifest:
//! ```jsonl
//! {"id":"req-001","method":"GET","url":"https://api.example.com/health"}
//! {"id":"req-002","method":"POST","url":"https://api.example.com/data","body":"{...}"}
//! ```
//!
//! ## Output Format (JSONL)
//!
//! Each line is a response with full telemetry:
//! ```jsonl
//! {"id":"req-001","status":200,"latency_ms":45,"retry_count":0,"body":"..."}
//! {"id":"req-002","status":500,"error":"Connection refused","retry_count":3}
//! ```

const std = @import("std");

/// Request manifest - defines a single HTTP request in the battle plan
pub const RequestManifest = struct {
    /// Unique identifier for tracking this request through execution
    id: []const u8,

    /// HTTP method (GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS)
    method: Method,

    /// Target URL (full URL including scheme)
    url: []const u8,

    /// Optional headers map
    headers: ?std.json.ArrayHashMap([]const u8) = null,

    /// Optional request body (for POST, PUT, PATCH)
    body: ?[]const u8 = null,

    /// Optional timeout in milliseconds (overrides engine default)
    timeout_ms: ?u64 = null,

    /// Optional retry configuration (overrides engine default)
    max_retries: ?u32 = null,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *RequestManifest) void {
        self.allocator.free(self.id);
        self.allocator.free(self.url);
        if (self.body) |body| {
            self.allocator.free(body);
        }
        if (self.headers) |*headers| {
            var it = headers.map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            headers.deinit(self.allocator);
        }
    }
};

/// Response manifest - output format with full telemetry data
pub const ResponseManifest = struct {
    /// Request ID this response corresponds to
    id: []const u8,

    /// HTTP status code (0 if request failed before receiving response)
    status: u16,

    /// Latency in milliseconds (wall-clock time from request start to response complete)
    latency_ms: u64,

    /// Response headers (optional - not currently populated)
    headers: ?std.json.ArrayHashMap([]const u8) = null,

    /// Response body (may be truncated for large responses)
    body: ?[]const u8 = null,

    /// Error message if request failed
    error_message: ?[]const u8 = null,

    /// Number of retry attempts made (0 = succeeded on first try)
    retry_count: u32 = 0,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *ResponseManifest) void {
        self.allocator.free(self.id);
        if (self.body) |body| {
            self.allocator.free(body);
        }
        if (self.error_message) |msg| {
            self.allocator.free(msg);
        }
        if (self.headers) |*headers| {
            var it = headers.map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            headers.deinit(self.allocator);
        }
    }

    /// Serialize to JSON for JSONL output streaming
    pub fn toJson(self: *const ResponseManifest, writer: anytype) !void {
        try writer.writeAll("{");

        // ID
        try writer.writeAll("\"id\":\"");
        try writer.writeAll(self.id);
        try writer.writeAll("\",");

        // Status
        try writer.print("\"status\":{},", .{self.status});

        // Latency
        try writer.print("\"latency_ms\":{},", .{self.latency_ms});

        // Retry count
        try writer.print("\"retry_count\":{}", .{self.retry_count});

        // Error message if present
        if (self.error_message) |err_msg| {
            try writer.writeAll(",\"error\":\"");
            try writeEscapedString(writer, err_msg);
            try writer.writeAll("\"");
        }

        // Body if present (truncated for large responses)
        if (self.body) |body| {
            try writer.writeAll(",\"body\":\"");
            const max_body_len = 1000; // Truncate large bodies for JSONL output
            const body_to_write = if (body.len > max_body_len) body[0..max_body_len] else body;
            try writeEscapedString(writer, body_to_write);
            if (body.len > max_body_len) {
                try writer.writeAll("... (truncated)");
            }
            try writer.writeAll("\"");
        }

        try writer.writeAll("}\n");
    }
};

/// HTTP methods supported by quantum-curl
pub const Method = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    HEAD,
    OPTIONS,

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .PATCH => "PATCH",
            .DELETE => "DELETE",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
        };
    }

    pub fn fromString(s: []const u8) ?Method {
        if (std.mem.eql(u8, s, "GET")) return .GET;
        if (std.mem.eql(u8, s, "POST")) return .POST;
        if (std.mem.eql(u8, s, "PUT")) return .PUT;
        if (std.mem.eql(u8, s, "PATCH")) return .PATCH;
        if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, s, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, s, "OPTIONS")) return .OPTIONS;
        return null;
    }
};

/// Parse a request manifest from a JSON line
pub fn parseRequestManifest(allocator: std.mem.Allocator, json_line: []const u8) !RequestManifest {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_line,
        .{},
    );
    defer parsed.deinit();

    const obj = parsed.value.object;

    // Required fields
    const id = try allocator.dupe(u8, obj.get("id").?.string);
    errdefer allocator.free(id);

    const method_str = obj.get("method").?.string;
    const method = Method.fromString(method_str) orelse return error.InvalidMethod;

    const url = try allocator.dupe(u8, obj.get("url").?.string);
    errdefer allocator.free(url);

    // Optional fields
    var body: ?[]u8 = null;
    if (obj.get("body")) |body_val| {
        if (body_val == .string) {
            body = try allocator.dupe(u8, body_val.string);
        }
    }

    var headers: ?std.json.ArrayHashMap([]const u8) = null;
    if (obj.get("headers")) |headers_obj| {
        if (headers_obj == .object) {
            headers = std.json.ArrayHashMap([]const u8){};
            var it = headers_obj.object.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try allocator.dupe(u8, entry.value_ptr.*.string);
                try headers.?.map.put(allocator, key, val);
            }
        }
    }

    const timeout_ms = if (obj.get("timeout_ms")) |t| @as(u64, @intCast(t.integer)) else null;
    const max_retries = if (obj.get("max_retries")) |r| @as(u32, @intCast(r.integer)) else null;

    return RequestManifest{
        .id = id,
        .method = method,
        .url = url,
        .headers = headers,
        .body = body,
        .timeout_ms = timeout_ms,
        .max_retries = max_retries,
        .allocator = allocator,
    };
}

/// Helper to write escaped JSON strings
fn writeEscapedString(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
}
