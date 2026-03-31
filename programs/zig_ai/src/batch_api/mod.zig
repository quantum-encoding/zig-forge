// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Batch API module (Anthropic + Gemini + OpenAI + xAI)
//!
//! Submit up to 100,000 requests asynchronously at 50% cost.
//! Batches typically complete within 1-24 hours.
//!
//! CLI: zig-ai batch-api <create|status|results|cancel|list|submit>
//! FFI: zig_ai_batch_api_*

const std = @import("std");

pub const types = @import("types.zig");
pub const client = @import("client.zig");
pub const gemini_client = @import("gemini_client.zig");
pub const openai_client = @import("openai_client.zig");
pub const xai_client = @import("xai_client.zig");
pub const cli = @import("cli.zig");

pub const BatchInfo = types.BatchInfo;
pub const BatchResultItem = types.BatchResultItem;
pub const BatchStatus = types.BatchStatus;
pub const BatchCreateConfig = types.BatchCreateConfig;
pub const BatchInputRow = types.BatchInputRow;
pub const BatchApiError = types.BatchApiError;
pub const BatchProvider = types.BatchProvider;

pub fn runCli(allocator: std.mem.Allocator, args: []const []const u8) !void {
    try cli.run(allocator, args);
}
