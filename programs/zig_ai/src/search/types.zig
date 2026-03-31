// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Search module types — Web Search and X Search via xAI Grok Responses API
//!
//! Two search modes:
//! - Web Search: search the internet via xAI's web_search tool
//! - X Search: search X/Twitter posts via xAI's x_search tool
//!
//! Server-side tool call types in Responses API output:
//!   web_search_call  — web_search, web_search_with_snippets, browse_page
//!   x_search_call    — x_user_search, x_keyword_search, x_semantic_search, x_thread_fetch

const std = @import("std");

pub const SearchMode = enum {
    web_search,
    x_search,

    pub fn toString(self: SearchMode) []const u8 {
        return switch (self) {
            .web_search => "web_search",
            .x_search => "x_search",
        };
    }

    pub fn displayName(self: SearchMode) []const u8 {
        return switch (self) {
            .web_search => "Grok Web Search",
            .x_search => "Grok X Search",
        };
    }

    pub fn toolType(self: SearchMode) []const u8 {
        return switch (self) {
            .web_search => "web_search",
            .x_search => "x_search",
        };
    }

    /// Usage category key in server_side_tool_usage
    pub fn usageCategory(self: SearchMode) []const u8 {
        return switch (self) {
            .web_search => "SERVER_SIDE_TOOL_WEB_SEARCH",
            .x_search => "SERVER_SIDE_TOOL_X_SEARCH",
        };
    }
};

pub const SearchRequest = struct {
    query: []const u8,
    mode: SearchMode = .web_search,
    model: ?[]const u8 = null,
    instructions: ?[]const u8 = null,
    max_output_tokens: u32 = 64000,
    // Agentic loop control
    max_turns: ?u32 = null,
    // Web search filtering
    allowed_domains: ?[]const []const u8 = null,
    excluded_domains: ?[]const []const u8 = null,
    // X search filtering
    allowed_x_handles: ?[]const []const u8 = null,
    excluded_x_handles: ?[]const []const u8 = null,
    // Date range (X search)
    from_date: ?[]const u8 = null,
    to_date: ?[]const u8 = null,
    // Media understanding
    enable_image_understanding: bool = false,
    enable_video_understanding: bool = false,
};

pub const Source = struct {
    title: []u8,
    uri: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Source) void {
        self.allocator.free(self.title);
        self.allocator.free(self.uri);
    }
};

/// Server-side tool usage counts (only successful/billable executions)
pub const ServerSideToolUsage = struct {
    web_search_calls: u32 = 0,
    x_search_calls: u32 = 0,
    code_execution_calls: u32 = 0,
    view_image_calls: u32 = 0,
    view_x_video_calls: u32 = 0,
    collections_search_calls: u32 = 0,
    mcp_calls: u32 = 0,

    pub fn total(self: ServerSideToolUsage) u32 {
        return self.web_search_calls + self.x_search_calls + self.code_execution_calls +
            self.view_image_calls + self.view_x_video_calls + self.collections_search_calls +
            self.mcp_calls;
    }
};

pub const SearchResponse = struct {
    content: []u8,
    sources: []Source,
    // Token usage
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    reasoning_tokens: u32 = 0,
    cached_tokens: u32 = 0,
    // Server-side tool usage (billable)
    tool_usage: ServerSideToolUsage = .{},
    response_id: ?[]u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SearchResponse) void {
        self.allocator.free(self.content);
        for (self.sources) |*src| {
            src.deinit();
        }
        self.allocator.free(self.sources);
        if (self.response_id) |rid| self.allocator.free(rid);
    }
};

pub const SearchError = error{
    InvalidApiKey,
    RateLimitExceeded,
    InvalidRequest,
    ServerError,
    NetworkError,
    InvalidResponse,
    ParseError,
};
