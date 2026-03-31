// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Types for the Batch API (Anthropic + Gemini + OpenAI + xAI)
//! https://docs.anthropic.com/en/api/creating-message-batches
//! https://ai.google.dev/api/generate-content#method:-models.batchgeneratecontent
//! https://platform.openai.com/docs/guides/batch
//! https://docs.x.ai/docs/guides/batch

const std = @import("std");

/// Batch API provider
pub const BatchProvider = enum {
    anthropic,
    gemini,
    openai,
    xai,

    pub fn getEnvVar(self: BatchProvider) [:0]const u8 {
        return switch (self) {
            .anthropic => "ANTHROPIC_API_KEY",
            .gemini => "GEMINI_API_KEY",
            .openai => "OPENAI_API_KEY",
            .xai => "XAI_API_KEY",
        };
    }

    pub fn getCostProvider(self: BatchProvider) []const u8 {
        return switch (self) {
            .anthropic => "anthropic",
            .gemini => "google",
            .openai => "openai",
            .xai => "xai",
        };
    }

    pub fn getDefaultModel(self: BatchProvider) []const u8 {
        return switch (self) {
            .anthropic => "claude-sonnet-4-5-20250929",
            .gemini => "gemini-2.5-flash",
            .openai => "gpt-4.1-mini",
            .xai => "grok-4-1-fast-non-reasoning",
        };
    }

    pub fn fromString(s: []const u8) ?BatchProvider {
        if (std.mem.eql(u8, s, "anthropic") or std.mem.eql(u8, s, "claude")) return .anthropic;
        if (std.mem.eql(u8, s, "gemini") or std.mem.eql(u8, s, "google")) return .gemini;
        if (std.mem.eql(u8, s, "openai") or std.mem.eql(u8, s, "gpt")) return .openai;
        if (std.mem.eql(u8, s, "xai") or std.mem.eql(u8, s, "grok")) return .xai;
        return null;
    }
};

/// Batch processing status
pub const BatchStatus = enum {
    in_progress,
    canceling,
    ended,

    pub fn fromString(s: []const u8) ?BatchStatus {
        if (std.mem.eql(u8, s, "in_progress")) return .in_progress;
        if (std.mem.eql(u8, s, "canceling")) return .canceling;
        if (std.mem.eql(u8, s, "ended")) return .ended;
        return null;
    }

    pub fn toString(self: BatchStatus) []const u8 {
        return switch (self) {
            .in_progress => "in_progress",
            .canceling => "canceling",
            .ended => "ended",
        };
    }
};

/// Request count breakdown
pub const RequestCounts = struct {
    processing: u32 = 0,
    succeeded: u32 = 0,
    errored: u32 = 0,
    canceled: u32 = 0,
    expired: u32 = 0,

    pub fn total(self: RequestCounts) u32 {
        return self.processing + self.succeeded + self.errored + self.canceled + self.expired;
    }
};

/// Batch info returned by create/status/cancel/list
pub const BatchInfo = struct {
    id: []u8,
    processing_status: BatchStatus,
    request_counts: RequestCounts,
    created_at: []u8,
    ended_at: ?[]u8 = null,
    expires_at: []u8,
    results_url: ?[]u8 = null,
    provider: BatchProvider = .anthropic,
    raw_status: ?[]u8 = null,
    output_file_id: ?[]u8 = null, // OpenAI: file ID for downloading results
    allocator: std.mem.Allocator,

    pub fn deinit(self: *BatchInfo) void {
        self.allocator.free(self.id);
        self.allocator.free(self.created_at);
        if (self.ended_at) |ea| self.allocator.free(ea);
        self.allocator.free(self.expires_at);
        if (self.results_url) |ru| self.allocator.free(ru);
        if (self.raw_status) |rs| self.allocator.free(rs);
        if (self.output_file_id) |ofi| self.allocator.free(ofi);
    }
};

/// Result type for individual batch items
pub const ResultType = enum {
    succeeded,
    errored,
    canceled,
    expired,

    pub fn fromString(s: []const u8) ?ResultType {
        if (std.mem.eql(u8, s, "succeeded")) return .succeeded;
        if (std.mem.eql(u8, s, "errored")) return .errored;
        if (std.mem.eql(u8, s, "canceled")) return .canceled;
        if (std.mem.eql(u8, s, "expired")) return .expired;
        return null;
    }
};

/// Single result item from batch JSONL output
pub const BatchResultItem = struct {
    custom_id: []u8,
    result_type: ResultType,
    content: ?[]u8 = null,
    model: ?[]u8 = null,
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    stop_reason: ?[]u8 = null,
    error_type: ?[]u8 = null,
    error_message: ?[]u8 = null,
    image_path: ?[]u8 = null, // OpenAI image batches: path to saved image file
    allocator: std.mem.Allocator,

    pub fn deinit(self: *BatchResultItem) void {
        self.allocator.free(self.custom_id);
        if (self.content) |c| self.allocator.free(c);
        if (self.model) |m| self.allocator.free(m);
        if (self.stop_reason) |sr| self.allocator.free(sr);
        if (self.error_type) |et| self.allocator.free(et);
        if (self.error_message) |em| self.allocator.free(em);
        if (self.image_path) |ip| self.allocator.free(ip);
    }
};

/// Shared configuration for batch request creation
pub const BatchCreateConfig = struct {
    model: []const u8 = "claude-sonnet-4-5-20250929",
    max_tokens: u32 = 64000,
    temperature: ?f32 = null,
    system_prompt: ?[]const u8 = null,
    // Image batch options (OpenAI only)
    image_size: ?[]const u8 = null, // e.g., "1024x1024"
    image_quality: ?[]const u8 = null, // "standard" or "hd"
    image_count: u8 = 1,
};

/// Input row parsed from CSV (one prompt = one batch request)
pub const BatchInputRow = struct {
    prompt: []const u8,
    model: ?[]const u8 = null,
    max_tokens: ?u32 = null,
    temperature: ?f32 = null,
    system_prompt: ?[]const u8 = null,
    custom_id: ?[]const u8 = null,
    // Image batch fields (OpenAI only)
    size: ?[]const u8 = null, // e.g., "1024x1024"
    quality: ?[]const u8 = null, // "standard", "hd"
    n: ?u8 = null, // number of images
    allocator: std.mem.Allocator,

    pub fn deinit(self: *BatchInputRow) void {
        self.allocator.free(self.prompt);
        if (self.model) |m| self.allocator.free(m);
        if (self.system_prompt) |sp| self.allocator.free(sp);
        if (self.custom_id) |cid| self.allocator.free(cid);
        if (self.size) |sz| self.allocator.free(sz);
        if (self.quality) |q| self.allocator.free(q);
    }
};

pub const BatchApiError = error{
    InvalidApiKey,
    RateLimitExceeded,
    InvalidRequest,
    BatchNotFound,
    BatchTooLarge,
    ServerError,
    ParseError,
    Timeout,
    ResultsNotReady,
    FileUploadFailed,
};
