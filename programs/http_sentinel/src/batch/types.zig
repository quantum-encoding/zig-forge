// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Batch processing types and data structures

const std = @import("std");
const cli = @import("../cli.zig");

/// Represents a single batch request from CSV
pub const BatchRequest = struct {
    id: u32,
    provider: cli.Provider,
    prompt: []const u8,
    temperature: f32 = 1.0,
    max_tokens: u32 = 4096,
    system_prompt: ?[]const u8 = null,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *BatchRequest) void {
        self.allocator.free(self.prompt);
        if (self.system_prompt) |sys| {
            self.allocator.free(sys);
        }
    }
};

/// Represents the result of a batch request
pub const BatchResult = struct {
    id: u32,
    provider: cli.Provider,
    prompt: []const u8,
    response: ?[]const u8,
    input_tokens: u32,
    output_tokens: u32,
    cost: f64,
    execution_time_ms: u64,
    error_message: ?[]const u8,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *BatchResult) void {
        self.allocator.free(self.prompt);
        if (self.response) |resp| {
            self.allocator.free(resp);
        }
        if (self.error_message) |err| {
            self.allocator.free(err);
        }
    }

    /// Truncate text for CSV output (max 200 chars)
    fn truncate(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
        if (text.len <= 200) {
            return try allocator.dupe(u8, text);
        }
        const truncated = text[0..197];
        return try std.fmt.allocPrint(allocator, "{s}...", .{truncated});
    }

    /// Write result as CSV row
    pub fn toCsv(self: *const BatchResult, allocator: std.mem.Allocator) ![]const u8 {
        const truncated_prompt = try truncate(allocator, self.prompt);
        defer allocator.free(truncated_prompt);

        const truncated_response = if (self.response) |resp|
            try truncate(allocator, resp)
        else
            try allocator.dupe(u8, "");
        defer allocator.free(truncated_response);

        const error_str = self.error_message orelse "";

        // Escape CSV fields (double quotes)
        const escaped_prompt = try escapeCsvField(allocator, truncated_prompt);
        defer allocator.free(escaped_prompt);

        const escaped_response = try escapeCsvField(allocator, truncated_response);
        defer allocator.free(escaped_response);

        const escaped_error = try escapeCsvField(allocator, error_str);
        defer allocator.free(escaped_error);

        const provider_name = @tagName(self.provider);
        return try std.fmt.allocPrint(allocator,
            "{},{s},\"{s}\",\"{s}\",{},{},{d:.6},{},\"{s}\"\n",
            .{
                self.id,
                provider_name,
                escaped_prompt,
                escaped_response,
                self.input_tokens,
                self.output_tokens,
                self.cost,
                self.execution_time_ms,
                escaped_error,
            },
        );
    }
};

/// Batch processing configuration
pub const BatchConfig = struct {
    input_file: []const u8,
    output_file: []const u8,
    concurrency: u32 = 50,
    full_responses: bool = false,
    continue_on_error: bool = true,
    retry_count: u32 = 2,
    timeout_ms: u64 = 120000,
    show_progress: bool = true,
};

/// Escape CSV field (handle quotes and commas)
fn escapeCsvField(allocator: std.mem.Allocator, field: []const u8) ![]const u8 {
    var needs_escape = false;
    for (field) |c| {
        if (c == '"' or c == ',' or c == '\n') {
            needs_escape = true;
            break;
        }
    }

    if (!needs_escape) {
        return try allocator.dupe(u8, field);
    }

    // Count quotes to allocate right size
    var quote_count: usize = 0;
    for (field) |c| {
        if (c == '"') quote_count += 1;
    }

    var result = try std.ArrayList(u8).initCapacity(allocator, field.len + quote_count);
    errdefer result.deinit(allocator);

    for (field) |c| {
        if (c == '"') {
            try result.append(allocator, '"'); // Escape quote with double quote
        }
        try result.append(allocator, c);
    }

    return result.toOwnedSlice(allocator);
}

test "BatchRequest basic" {
    const allocator = std.testing.allocator;

    var req = BatchRequest{
        .id = 1,
        .provider = .deepseek,
        .prompt = try allocator.dupe(u8, "Test prompt"),
        .allocator = allocator,
    };
    defer req.deinit();

    try std.testing.expectEqual(@as(u32, 1), req.id);
    try std.testing.expectEqual(cli.Provider.deepseek, req.provider);
}

test "BatchResult CSV generation" {
    const allocator = std.testing.allocator;

    var result = BatchResult{
        .id = 1,
        .provider = .deepseek,
        .prompt = try allocator.dupe(u8, "What is Zig?"),
        .response = try allocator.dupe(u8, "Zig is a programming language"),
        .input_tokens = 10,
        .output_tokens = 20,
        .cost = 0.00001,
        .execution_time_ms = 1234,
        .error_message = null,
        .allocator = allocator,
    };
    defer result.deinit();

    const csv = try result.toCsv(allocator);
    defer allocator.free(csv);

    try std.testing.expect(std.mem.indexOf(u8, csv, "deepseek") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "What is Zig?") != null);
}

test "CSV field escaping" {
    const allocator = std.testing.allocator;

    const escaped = try escapeCsvField(allocator, "Hello \"World\"");
    defer allocator.free(escaped);

    try std.testing.expectEqualStrings("Hello \"\"World\"\"", escaped);
}
