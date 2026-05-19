// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! HTTP Request Manifest Format
//! Defines the input/output format for the universal HTTP engine

const std = @import("std");

/// Request manifest - defines a single HTTP request
pub const RequestManifest = struct {
    /// Unique identifier for tracking this request
    id: []const u8,

    /// HTTP method
    method: Method,

    /// Target URL
    url: []const u8,

    /// Optional headers
    headers: ?std.json.ArrayHashMap([]const u8) = null,

    /// Optional request body
    body: ?[]const u8 = null,

    /// Optional timeout in milliseconds (overrides default)
    timeout_ms: ?u64 = null,

    /// Optional retry configuration (overrides default)
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

/// Response manifest - output format with telemetry
pub const ResponseManifest = struct {
    /// Request ID this response corresponds to
    id: []const u8,

    /// HTTP status code (0 if request failed before receiving response)
    status: u16,

    /// Latency in milliseconds
    latency_ms: u64,

    /// Response headers
    headers: ?std.json.ArrayHashMap([]const u8) = null,

    /// Response body
    body: ?[]const u8 = null,

    /// Error message if request failed
    error_message: ?[]const u8 = null,

    /// Number of retry attempts made
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

    /// Serialize to JSON
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
            const max_body_len = 1000; // Truncate large bodies
            const body_to_write = if (body.len > max_body_len) body[0..max_body_len] else body;
            try writeEscapedString(writer, body_to_write);
            if (body.len > max_body_len) {
                try writer.writeAll("... (truncated)");
            }
            try writer.writeAll("\"");
        }

        try writer.writeAll("}\n");
    }

    /// Serialize to JSON string (allocated)
    pub fn toJsonString(self: *const ResponseManifest, allocator: std.mem.Allocator) ![]u8 {
        var list: std.ArrayListUnmanaged(u8) = .empty;
        errdefer list.deinit(allocator);

        // Create a wrapper that writes to the array list
        const ListWriter = struct {
            list: *std.ArrayListUnmanaged(u8),
            alloc: std.mem.Allocator,

            pub fn writeAll(ctx: *@This(), data: []const u8) !void {
                try ctx.list.appendSlice(ctx.alloc, data);
            }

            pub fn writeByte(ctx: *@This(), byte: u8) !void {
                try ctx.list.append(ctx.alloc, byte);
            }

            pub fn print(ctx: *@This(), comptime fmt: []const u8, args: anytype) !void {
                const str = try std.fmt.allocPrint(ctx.alloc, fmt, args);
                defer ctx.alloc.free(str);
                try ctx.list.appendSlice(ctx.alloc, str);
            }
        };
        var writer = ListWriter{ .list = &list, .alloc = allocator };

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
            for (err_msg) |c| {
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
            try writer.writeAll("\"");
        }

        // Body if present (truncated for large responses)
        if (self.body) |body| {
            try writer.writeAll(",\"body\":\"");
            const max_body_len = 1000;
            const body_to_write = if (body.len > max_body_len) body[0..max_body_len] else body;
            for (body_to_write) |c| {
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
            if (body.len > max_body_len) {
                try writer.writeAll("... (truncated)");
            }
            try writer.writeAll("\"");
        }

        try writer.writeAll("}\n");

        return list.toOwnedSlice(allocator);
    }
};

/// HTTP methods supported
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

/// Cap retry count to keep `1 << (attempts-1)` shifts well-defined and
/// to bound worst-case backoff (~17 minutes at 30).
const MAX_RETRIES_CAP: u32 = 30;
/// Cap a single request timeout at 24 h so a hostile manifest cannot pin a worker indefinitely.
const MAX_TIMEOUT_MS: u64 = 24 * 60 * 60 * 1000;

fn jsonStringField(obj: anytype, key: []const u8) !?[]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .string) return error.InvalidJson;
    return v.string;
}

fn jsonNonNegativeInteger(comptime T: type, obj: anytype, key: []const u8, max: T) !?T {
    const v = obj.get(key) orelse return null;
    if (v != .integer) return error.InvalidJson;
    if (v.integer < 0) return error.InvalidJson;
    const u: u64 = @intCast(v.integer);
    if (u > @as(u64, max)) return @as(T, max);
    return @intCast(u);
}

/// Parse a request manifest from JSON.
///
/// Rejects malformed input with `error.InvalidJson` rather than panicking
/// — this parser reads from untrusted stdin (CWE-20).
pub fn parseRequestManifest(allocator: std.mem.Allocator, json_line: []const u8) !RequestManifest {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_line,
        .{},
    ) catch return error.InvalidJson;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidJson;
    const obj = parsed.value.object;

    // Required fields
    const id_str = (try jsonStringField(obj, "id")) orelse return error.InvalidJson;
    const id = try allocator.dupe(u8, id_str);
    errdefer allocator.free(id);

    const method_str = (try jsonStringField(obj, "method")) orelse return error.InvalidJson;
    const method = Method.fromString(method_str) orelse return error.InvalidMethod;

    const url_str = (try jsonStringField(obj, "url")) orelse return error.InvalidJson;
    const url = try allocator.dupe(u8, url_str);
    errdefer allocator.free(url);

    // Optional fields
    var body: ?[]u8 = null;
    if (obj.get("body")) |body_val| {
        if (body_val != .string) return error.InvalidJson;
        body = try allocator.dupe(u8, body_val.string);
    }
    errdefer if (body) |b| allocator.free(b);

    var headers: ?std.json.ArrayHashMap([]const u8) = null;
    errdefer if (headers) |*h| {
        var it = h.map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        h.deinit(allocator);
    };
    if (obj.get("headers")) |headers_obj| {
        if (headers_obj != .object) return error.InvalidJson;
        headers = std.json.ArrayHashMap([]const u8){};
        var it = headers_obj.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) return error.InvalidJson;
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);
            const val = try allocator.dupe(u8, entry.value_ptr.*.string);
            errdefer allocator.free(val);
            try headers.?.map.put(allocator, key, val);
        }
    }

    const timeout_ms = try jsonNonNegativeInteger(u64, obj, "timeout_ms", MAX_TIMEOUT_MS);
    const max_retries = try jsonNonNegativeInteger(u32, obj, "max_retries", MAX_RETRIES_CAP);

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
