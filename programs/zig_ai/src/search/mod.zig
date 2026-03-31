// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Search module — Web Search and X Search via xAI Grok Responses API
//!
//! Two modes:
//! - Web Search: search the internet with Grok (fast, grounded)
//! - X Search: search X/Twitter posts with Grok (real-time social data)

const std = @import("std");

pub const types = @import("types.zig");
pub const grok_search = @import("grok_search.zig");
pub const cli = @import("cli.zig");

// Re-exports
pub const SearchRequest = types.SearchRequest;
pub const SearchResponse = types.SearchResponse;
pub const SearchMode = types.SearchMode;
pub const Source = types.Source;

pub fn runCli(allocator: std.mem.Allocator, args: []const []const u8) !void {
    try cli.run(allocator, args);
}
