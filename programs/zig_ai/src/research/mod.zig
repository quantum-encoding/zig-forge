// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Research module — Web Search and Deep Research via Gemini APIs
//!
//! Two modes:
//! - Web Search: generateContent with google_search grounding (fast, seconds)
//! - Deep Research: Interactions API with autonomous agent (comprehensive, minutes)

const std = @import("std");

pub const types = @import("types.zig");
pub const web_search = @import("web_search.zig");
pub const deep_research = @import("deep_research.zig");
pub const cli = @import("cli.zig");

// Re-exports
pub const ResearchRequest = types.ResearchRequest;
pub const ResearchResponse = types.ResearchResponse;
pub const ResearchMode = types.ResearchMode;
pub const Source = types.Source;

pub fn runCli(allocator: std.mem.Allocator, args: []const []const u8) !void {
    try cli.run(allocator, args);
}
