// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Structured Output Module
//!
//! Provides JSON schema-based structured output generation across multiple AI providers.
//! Schemas are loaded from configuration files and referenced by name.
//!
//! ## Supported Providers
//! - OpenAI (gpt-5.2): Strict schema via Responses API
//! - Claude (Opus 4.6+): Strict schema via output_config.format (GA)
//! - Gemini: Strict schema via responseJsonSchema
//! - Grok: Strict schema via response_format
//! - DeepSeek: JSON mode with schema in prompt (no strict enforcement)
//!
//! ## Usage
//! ```
//! zig-ai structured "prompt" --schema <name> --provider <provider>
//! zig-ai schemas list
//! ```

const std = @import("std");

pub const types = @import("types.zig");
pub const schema_loader = @import("schema_loader.zig");
pub const cli = @import("cli.zig");
pub const providers = @import("providers/mod.zig");
pub const templates = @import("templates.zig");

// Re-export commonly used types
pub const Provider = types.Provider;
pub const Schema = types.Schema;
pub const StructuredRequest = types.StructuredRequest;
pub const StructuredResponse = types.StructuredResponse;
pub const StructuredError = types.StructuredError;
pub const UsageStats = types.UsageStats;
pub const SchemaLoader = schema_loader.SchemaLoader;

/// Generate structured output using the specified provider
pub const generate = providers.generate;

/// Run the 'structured' CLI command
pub fn runStructured(allocator: std.mem.Allocator, args: []const []const u8) !void {
    return cli.runStructured(allocator, args);
}

/// Run the 'schemas' CLI command
pub fn runSchemas(allocator: std.mem.Allocator, args: []const []const u8) !void {
    return cli.runSchemas(allocator, args);
}
