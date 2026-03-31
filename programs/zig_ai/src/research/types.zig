// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Research module types
//!
//! Two research modes using Gemini APIs:
//! - Web Search: generateContent with google_search grounding (fast, seconds)
//! - Deep Research: Interactions API with autonomous agent (comprehensive, minutes)

const std = @import("std");

pub const ResearchMode = enum {
    web_search,
    deep_research,

    pub fn toString(self: ResearchMode) []const u8 {
        return switch (self) {
            .web_search => "web_search",
            .deep_research => "deep_research",
        };
    }

    pub fn displayName(self: ResearchMode) []const u8 {
        return switch (self) {
            .web_search => "Web Search",
            .deep_research => "Deep Research",
        };
    }
};

/// Thinking level for Gemini models.
///
/// Gemini 3 Pro:   thinkingLevel — only "low" and "high" (default) supported
/// Gemini 3 Flash: thinkingLevel — "minimal", "low", "medium", "high" (default)
/// Gemini 2.5:     thinkingBudget (0=off, -1=dynamic, 128..32768)
///
/// The web_search module maps these to the correct API parameter based on model.
pub const ThinkingLevel = enum {
    off, // 2.5: budget=0, 3 Flash: "minimal", 3 Pro: maps to "low" (lowest supported)
    low, // 2.5: budget=1024, 3 Pro/Flash: "low"
    medium, // 2.5: budget=8192, 3 Flash: "medium", 3 Pro: maps to "low" (unsupported)
    high, // 2.5: budget=-1 (dynamic), 3 Pro/Flash: "high"

    pub fn toString(self: ThinkingLevel) []const u8 {
        return switch (self) {
            .off => "off",
            .low => "low",
            .medium => "medium",
            .high => "high",
        };
    }
};

pub const ResearchRequest = struct {
    query: []const u8,
    mode: ResearchMode = .web_search,
    model: ?[]const u8 = null,
    agent: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    max_tokens: u32 = 64000,
    thinking: ThinkingLevel = .low,
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

pub const ResearchResponse = struct {
    content: []u8,
    sources: []Source,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ResearchResponse) void {
        self.allocator.free(self.content);
        for (self.sources) |*src| {
            src.deinit();
        }
        self.allocator.free(self.sources);
    }
};

pub const ResearchError = error{
    InvalidApiKey,
    RateLimitExceeded,
    InvalidRequest,
    ServerError,
    NetworkError,
    InvalidResponse,
    ParseError,
    ResearchTimeout,
    ResearchFailed,
};
