// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Response Management System for AI Providers
//! Handles storage, retrieval, and analysis of AI responses across all providers

const std = @import("std");
const common = @import("common.zig");

/// Pure Zig mutex using atomics (no libc)
const Mutex = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn lock(self: *Mutex) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *Mutex) void {
        self.state.store(0, .release);
    }
};

/// Get current Unix timestamp in seconds (pure Zig via Io)
fn getCurrentTimestamp(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

/// Thread-safe response storage and management
pub const ResponseManager = struct {
    allocator: std.mem.Allocator,
    responses: std.ArrayList(StoredResponse),
    conversations: std.StringHashMap(ConversationData),
    mutex: Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) ResponseManager {
        return .{
            .allocator = allocator,
            .responses = std.ArrayList(StoredResponse).empty,
            .conversations = std.StringHashMap(ConversationData).init(allocator),
        };
    }

    pub fn deinit(self: *ResponseManager) void {
        for (self.responses.items) |*response| {
            response.deinit();
        }
        self.responses.deinit(self.allocator);

        var it = self.conversations.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.conversations.deinit();
    }

    /// Store a response (thread-safe)
    pub fn storeResponse(
        self: *ResponseManager,
        io: std.Io,
        conversation_id: []const u8,
        request: Request,
        response: common.AIResponse,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const stored = try StoredResponse.init(
            self.allocator,
            io,
            conversation_id,
            request,
            response,
        );

        try self.responses.append(self.allocator, stored);

        // Update conversation data
        const gop = try self.conversations.getOrPut(conversation_id);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, conversation_id);
            gop.value_ptr.* = ConversationData.init(self.allocator);
        }

        try gop.value_ptr.addResponse(&stored);
    }

    /// Get all responses for a conversation
    pub fn getConversation(self: *ResponseManager, conversation_id: []const u8) ?[]const StoredResponse {
        self.mutex.lock();
        defer self.mutex.unlock();

        var results = std.ArrayList(*const StoredResponse).init(self.allocator);
        defer results.deinit();

        for (self.responses.items) |*response| {
            if (std.mem.eql(u8, response.conversation_id, conversation_id)) {
                results.append(response) catch continue;
            }
        }

        if (results.items.len == 0) return null;

        // Return owned slice (caller must free)
        return results.toOwnedSlice() catch null;
    }

    /// Get conversation statistics
    pub fn getConversationStats(self: *ResponseManager, conversation_id: []const u8) ?ConversationStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        const data = self.conversations.get(conversation_id) orelse return null;
        return data.stats;
    }

    /// Get all conversation IDs
    pub fn getAllConversationIds(self: *ResponseManager) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var ids = std.ArrayList([]const u8).init(self.allocator);
        errdefer ids.deinit();

        var it = self.conversations.keyIterator();
        while (it.next()) |key| {
            try ids.append(try self.allocator.dupe(u8, key.*));
        }

        return ids.toOwnedSlice();
    }

    /// Export conversation to JSON
    pub fn exportConversationJson(
        self: *ResponseManager,
        conversation_id: []const u8,
        writer: anytype,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const data = self.conversations.get(conversation_id) orelse return error.ConversationNotFound;

        try writer.writeAll("{\"conversation_id\":\"");
        try writer.writeAll(conversation_id);
        try writer.writeAll("\",\"messages\":[");

        var first = true;
        for (self.responses.items) |*response| {
            if (!std.mem.eql(u8, response.conversation_id, conversation_id)) continue;

            if (!first) try writer.writeAll(",");
            first = false;

            try response.writeJson(writer);
        }

        try writer.writeAll("],\"stats\":");
        try data.stats.writeJson(writer);
        try writer.writeAll("}");
    }

    /// Export conversation to Markdown
    pub fn exportConversationMarkdown(
        self: *ResponseManager,
        conversation_id: []const u8,
        writer: anytype,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try writer.print("# Conversation: {s}\n\n", .{conversation_id});

        for (self.responses.items) |*response| {
            if (!std.mem.eql(u8, response.conversation_id, conversation_id)) continue;

            try writer.print("## {} - {s} ({s})\n\n", .{
                response.timestamp,
                response.response.metadata.provider,
                response.response.metadata.model,
            });

            try writer.print("**User:**\n```\n{s}\n```\n\n", .{response.request.prompt});
            try writer.print("**Assistant:**\n{s}\n\n", .{response.response.message.content});
            try writer.print("**Tokens:** {} in, {} out ({} total)\n\n", .{
                response.response.usage.input_tokens,
                response.response.usage.output_tokens,
                response.response.usage.total(),
            });
            try writer.writeAll("---\n\n");
        }
    }
};

/// A single stored request/response pair
pub const StoredResponse = struct {
    id: []const u8,
    conversation_id: []const u8,
    timestamp: i64,
    request: Request,
    response: common.AIResponse,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        conversation_id: []const u8,
        request: Request,
        response: common.AIResponse,
    ) !StoredResponse {
        return .{
            .id = try common.generateId(allocator),
            .conversation_id = try allocator.dupe(u8, conversation_id),
            .timestamp = getCurrentTimestamp(io),
            .request = try request.clone(allocator),
            .response = response, // Ownership transferred
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StoredResponse) void {
        self.allocator.free(self.id);
        self.allocator.free(self.conversation_id);
        self.request.deinit();
        self.response.deinit();
    }

    pub fn writeJson(self: *const StoredResponse, writer: anytype) !void {
        try writer.writeAll("{");
        try writer.print("\"id\":\"{s}\",", .{self.id});
        try writer.print("\"timestamp\":{},", .{self.timestamp});
        try writer.print("\"provider\":\"{s}\",", .{self.response.metadata.provider});
        try writer.print("\"model\":\"{s}\",", .{self.response.metadata.model});

        // Escape and write request
        const escaped_prompt = try common.escapeJsonString(self.allocator, self.request.prompt);
        defer self.allocator.free(escaped_prompt);
        try writer.print("\"request\":\"{s}\",", .{escaped_prompt});

        // Escape and write response
        const escaped_response = try common.escapeJsonString(self.allocator, self.response.message.content);
        defer self.allocator.free(escaped_response);
        try writer.print("\"response\":\"{s}\",", .{escaped_response});

        try writer.print("\"input_tokens\":{},", .{self.response.usage.input_tokens});
        try writer.print("\"output_tokens\":{}", .{self.response.usage.output_tokens});
        try writer.writeAll("}");
    }
};

/// Request data to store
pub const Request = struct {
    prompt: []const u8,
    model: []const u8,
    config: common.RequestConfig,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Request) void {
        self.allocator.free(self.prompt);
        self.allocator.free(self.model);
    }

    pub fn clone(self: Request, allocator: std.mem.Allocator) !Request {
        return .{
            .prompt = try allocator.dupe(u8, self.prompt),
            .model = try allocator.dupe(u8, self.model),
            .config = self.config,
            .allocator = allocator,
        };
    }
};

/// Aggregated conversation data
pub const ConversationData = struct {
    stats: ConversationStats,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConversationData {
        return .{
            .stats = ConversationStats{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConversationData) void {
        _ = self;
    }

    pub fn addResponse(self: *ConversationData, response: *const StoredResponse) !void {
        self.stats.total_requests += 1;
        self.stats.total_input_tokens += response.response.usage.input_tokens;
        self.stats.total_output_tokens += response.response.usage.output_tokens;
        self.stats.total_execution_time_ms += response.response.metadata.execution_time_ms;
    }
};

/// Statistics for a conversation
pub const ConversationStats = struct {
    total_requests: u32 = 0,
    total_input_tokens: u64 = 0,
    total_output_tokens: u64 = 0,
    total_execution_time_ms: u64 = 0,

    pub fn averageLatencyMs(self: ConversationStats) u64 {
        if (self.total_requests == 0) return 0;
        return self.total_execution_time_ms / self.total_requests;
    }

    pub fn totalTokens(self: ConversationStats) u64 {
        return self.total_input_tokens + self.total_output_tokens;
    }

    pub fn writeJson(self: ConversationStats, writer: anytype) !void {
        try writer.writeAll("{");
        try writer.print("\"total_requests\":{},", .{self.total_requests});
        try writer.print("\"total_input_tokens\":{},", .{self.total_input_tokens});
        try writer.print("\"total_output_tokens\":{},", .{self.total_output_tokens});
        try writer.print("\"total_execution_time_ms\":{},", .{self.total_execution_time_ms});
        try writer.print("\"average_latency_ms\":{}", .{self.averageLatencyMs()});
        try writer.writeAll("}");
    }
};

test "ResponseManager basic operations" {
    const allocator = std.testing.allocator;
    var io_threaded = std.Io.Threaded.init_single_threaded;
    const io = io_threaded.io();

    var manager = ResponseManager.init(allocator);
    defer manager.deinit();

    // Create test response
    const conv_id = "test-conv-1";
    const request = Request{
        .prompt = "Hello",
        .model = "test-model",
        .config = .{ .model = "test-model" },
        .allocator = allocator,
    };

    const response = common.AIResponse{
        .message = .{
            .id = try allocator.dupe(u8, "msg-1"),
            .role = .assistant,
            .content = try allocator.dupe(u8, "Hi there!"),
            .timestamp = getCurrentTimestamp(io),
            .allocator = allocator,
        },
        .usage = .{
            .input_tokens = 10,
            .output_tokens = 5,
        },
        .metadata = .{
            .model = try allocator.dupe(u8, "test-model"),
            .provider = try allocator.dupe(u8, "test"),
            .execution_time_ms = 100,
            .allocator = allocator,
        },
    };

    try manager.storeResponse(io, conv_id, request, response);

    // Get conversation stats
    const stats = manager.getConversationStats(conv_id);
    try std.testing.expect(stats != null);
    try std.testing.expectEqual(@as(u32, 1), stats.?.total_requests);
    try std.testing.expectEqual(@as(u64, 10), stats.?.total_input_tokens);
    try std.testing.expectEqual(@as(u64, 5), stats.?.total_output_tokens);
}
