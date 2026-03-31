// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Structured output types for JSON schema-based responses
//!
//! Supports multiple providers with their native structured output mechanisms:
//! - OpenAI: text.format with json_schema
//! - Claude: output_config.format with json_schema (GA)
//! - Gemini: responseMimeType + responseJsonSchema
//! - Grok: response_format with json_schema
//! - DeepSeek: JSON mode with schema in prompt

const std = @import("std");

/// Provider for structured output generation
pub const Provider = enum {
    openai,
    claude,
    gemini,
    grok,
    deepseek,

    pub fn fromString(s: []const u8) ?Provider {
        if (std.mem.eql(u8, s, "openai")) return .openai;
        if (std.mem.eql(u8, s, "claude")) return .claude;
        if (std.mem.eql(u8, s, "gemini")) return .gemini;
        if (std.mem.eql(u8, s, "grok")) return .grok;
        if (std.mem.eql(u8, s, "deepseek")) return .deepseek;
        return null;
    }

    pub fn toString(self: Provider) []const u8 {
        return switch (self) {
            .openai => "openai",
            .claude => "claude",
            .gemini => "gemini",
            .grok => "grok",
            .deepseek => "deepseek",
        };
    }

    pub fn displayName(self: Provider) []const u8 {
        return switch (self) {
            .openai => "OpenAI",
            .claude => "Claude",
            .gemini => "Gemini",
            .grok => "Grok",
            .deepseek => "DeepSeek",
        };
    }

    pub fn getEnvVar(self: Provider) [:0]const u8 {
        return switch (self) {
            .openai => "OPENAI_API_KEY",
            .claude => "ANTHROPIC_API_KEY",
            .gemini => "GEMINI_API_KEY",
            .grok => "XAI_API_KEY",
            .deepseek => "DEEPSEEK_API_KEY",
        };
    }

    pub fn getDefaultModel(self: Provider) []const u8 {
        return switch (self) {
            .openai => "gpt-5.2",
            .claude => "claude-opus-4-6",
            .gemini => "gemini-3-flash-preview",
            .grok => "grok-4-1-fast-non-reasoning",
            .deepseek => "deepseek-chat",
        };
    }

    /// Returns true if the provider supports strict schema enforcement
    pub fn supportsStrictSchema(self: Provider) bool {
        return switch (self) {
            .openai, .claude, .gemini, .grok => true,
            .deepseek => false, // Uses JSON mode with schema in prompt
        };
    }
};

/// Loaded schema from config file
pub const Schema = struct {
    name: []u8,
    description: ?[]u8,
    schema_json: []u8, // Raw JSON schema string
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Schema) void {
        self.allocator.free(self.name);
        if (self.description) |desc| self.allocator.free(desc);
        self.allocator.free(self.schema_json);
    }
};

/// Request for structured output
pub const StructuredRequest = struct {
    prompt: []const u8,
    schema: *const Schema,
    provider: Provider = .gemini,
    model: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    max_tokens: u32 = 64000,
};

/// Usage statistics
pub const UsageStats = struct {
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    total_tokens: u32 = 0,
};

/// Structured output response
pub const StructuredResponse = struct {
    json_output: []u8, // The structured JSON output
    raw_response: ?[]u8 = null, // Full API response (optional)
    usage: ?UsageStats = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *StructuredResponse) void {
        self.allocator.free(self.json_output);
        if (self.raw_response) |raw| self.allocator.free(raw);
    }
};

/// Structured output errors
pub const StructuredError = error{
    SchemaNotFound,
    InvalidSchema,
    InvalidApiKey,
    RateLimitExceeded,
    InvalidRequest,
    ServerError,
    NetworkError,
    InvalidResponse,
    ParseError,
    RefusalError,
    MaxTokensExceeded,
};

test "Provider fromString" {
    try std.testing.expectEqual(Provider.gemini, Provider.fromString("gemini").?);
    try std.testing.expectEqual(Provider.openai, Provider.fromString("openai").?);
    try std.testing.expect(Provider.fromString("invalid") == null);
}

test "Provider supportsStrictSchema" {
    try std.testing.expect(Provider.gemini.supportsStrictSchema());
    try std.testing.expect(Provider.openai.supportsStrictSchema());
    try std.testing.expect(!Provider.deepseek.supportsStrictSchema());
}
