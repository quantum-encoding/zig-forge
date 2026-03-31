// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Provider dispatch module for structured output
//!
//! Routes requests to the appropriate provider implementation.

const std = @import("std");
const types = @import("../types.zig");

const claude = @import("claude.zig");
const deepseek = @import("deepseek.zig");
const gemini = @import("gemini.zig");
const grok = @import("grok.zig");
const openai = @import("openai.zig");

/// Generate structured output using the specified provider
pub fn generate(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    request: types.StructuredRequest,
) !types.StructuredResponse {
    return switch (request.provider) {
        .openai => openai.generate(allocator, api_key, request),
        .claude => claude.generate(allocator, api_key, request),
        .gemini => gemini.generate(allocator, api_key, request),
        .grok => grok.generate(allocator, api_key, request),
        .deepseek => deepseek.generate(allocator, api_key, request),
    };
}

/// Get the environment variable name for API key
pub fn getApiKeyEnvVar(provider: types.Provider) [:0]const u8 {
    return provider.getEnvVar();
}

/// Check if provider supports strict schema enforcement
pub fn supportsStrictSchema(provider: types.Provider) bool {
    return provider.supportsStrictSchema();
}

/// Get default model for provider
pub fn getDefaultModel(provider: types.Provider) []const u8 {
    return provider.getDefaultModel();
}
