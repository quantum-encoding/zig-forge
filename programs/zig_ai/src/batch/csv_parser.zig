// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! CSV parser for batch processing

const std = @import("std");
const types = @import("types.zig");
const cli = @import("../cli.zig");

pub const ParseError = error{
    InvalidHeader,
    MissingProvider,
    MissingPrompt,
    InvalidProvider,
    InvalidTemperature,
    InvalidMaxTokens,
    UnexpectedEndOfFile,
};

/// Parse CSV file into BatchRequest array
pub fn parseFile(allocator: std.mem.Allocator, file_path: []const u8) ![]types.BatchRequest {
    const io = std.Io.Threaded.global_single_threaded.io();
    const max_size = 10 * 1024 * 1024; // 10MB max

    // Use readFileAlloc for simplicity
    const content = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, std.Io.Limit.limited(max_size));
    defer allocator.free(content);

    return try parseContent(allocator, content);
}

/// Parse CSV content string
pub fn parseContent(allocator: std.mem.Allocator, content: []const u8) ![]types.BatchRequest {
    var requests: std.ArrayList(types.BatchRequest) = .empty;
    errdefer {
        for (requests.items) |*req| {
            req.deinit();
        }
        requests.deinit(allocator);
    }

    var line_iter = std.mem.splitScalar(u8, content, '\n');

    // Parse header
    const header_line = line_iter.next() orelse return ParseError.InvalidHeader;
    const header = try parseHeader(allocator, header_line);
    defer allocator.free(header);

    // Parse data rows
    var id: u32 = 1;
    while (line_iter.next()) |line| {
        if (line.len == 0 or isWhitespace(line)) continue;

        const request = parseRow(allocator, line, header, id) catch |err| {
            std.debug.print("⚠️  Warning: Skipping row {}: {}\n", .{ id, err });
            continue;
        };

        try requests.append(allocator, request);
        id += 1;
    }

    if (requests.items.len == 0) {
        std.debug.print("Error: No valid requests found in CSV\n", .{});
        return error.NoValidRequests;
    }

    return requests.toOwnedSlice(allocator);
}

/// Parse CSV header row
fn parseHeader(allocator: std.mem.Allocator, header_line: []const u8) ![][]const u8 {
    var headers: std.ArrayList([]const u8) = .empty;
    errdefer headers.deinit(allocator);

    const fields = try parseFields(allocator, header_line);
    defer {
        for (fields) |field| allocator.free(field);
        allocator.free(fields);
    }

    // Validate required headers
    var has_provider = false;
    var has_prompt = false;

    for (fields) |field| {
        const trimmed = std.mem.trim(u8, field, &std.ascii.whitespace);
        if (std.mem.eql(u8, trimmed, "provider")) has_provider = true;
        if (std.mem.eql(u8, trimmed, "prompt")) has_prompt = true;
    }

    if (!has_provider or !has_prompt) {
        std.debug.print("Error: CSV must have 'provider' and 'prompt' columns\n", .{});
        return ParseError.InvalidHeader;
    }

    // Store header names
    for (fields) |field| {
        const trimmed = std.mem.trim(u8, field, &std.ascii.whitespace);
        try headers.append(allocator, try allocator.dupe(u8, trimmed));
    }

    return headers.toOwnedSlice(allocator);
}

/// Parse single CSV row into BatchRequest
fn parseRow(
    allocator: std.mem.Allocator,
    line: []const u8,
    headers: []const []const u8,
    id: u32,
) !types.BatchRequest {
    const fields = try parseFields(allocator, line);
    defer {
        for (fields) |field| allocator.free(field);
        allocator.free(fields);
    }

    if (fields.len != headers.len) {
        return error.FieldCountMismatch;
    }

    var request = types.BatchRequest{
        .id = id,
        .provider = undefined,
        .prompt = undefined,
        .allocator = allocator,
    };
    errdefer {
        if (@intFromPtr(request.prompt.ptr) != 0) allocator.free(request.prompt);
        if (request.system_prompt) |sys| allocator.free(sys);
    }

    var has_provider = false;
    var has_prompt = false;

    for (headers, 0..) |header, i| {
        const value = std.mem.trim(u8, fields[i], &std.ascii.whitespace);

        if (std.mem.eql(u8, header, "provider")) {
            request.provider = cli.Provider.fromString(value) orelse {
                std.debug.print("Invalid provider: {s}\n", .{value});
                return ParseError.InvalidProvider;
            };
            has_provider = true;
        } else if (std.mem.eql(u8, header, "prompt")) {
            if (value.len == 0) return ParseError.MissingPrompt;
            request.prompt = try allocator.dupe(u8, value);
            has_prompt = true;
        } else if (std.mem.eql(u8, header, "temperature")) {
            if (value.len > 0) {
                request.temperature = std.fmt.parseFloat(f32, value) catch |err| {
                    std.debug.print("Invalid temperature: {s}\n", .{value});
                    return err;
                };
            }
        } else if (std.mem.eql(u8, header, "max_tokens")) {
            if (value.len > 0) {
                request.max_tokens = std.fmt.parseInt(u32, value, 10) catch |err| {
                    std.debug.print("Invalid max_tokens: {s}\n", .{value});
                    return err;
                };
            }
        } else if (std.mem.eql(u8, header, "system_prompt")) {
            if (value.len > 0) {
                request.system_prompt = try allocator.dupe(u8, value);
            }
        }
    }

    if (!has_provider) return ParseError.MissingProvider;
    if (!has_prompt) return ParseError.MissingPrompt;

    return request;
}

/// Parse CSV fields, handling quoted strings
fn parseFields(allocator: std.mem.Allocator, line: []const u8) ![][]const u8 {
    var fields: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (fields.items) |field| allocator.free(field);
        fields.deinit(allocator);
    }

    var field: std.ArrayList(u8) = .empty;
    defer field.deinit(allocator);

    var in_quotes = false;
    var i: usize = 0;

    while (i < line.len) : (i += 1) {
        const c = line[i];

        if (c == '"') {
            if (in_quotes and i + 1 < line.len and line[i + 1] == '"') {
                // Escaped quote
                try field.append(allocator, '"');
                i += 1;
            } else {
                // Toggle quote mode
                in_quotes = !in_quotes;
            }
        } else if (c == ',' and !in_quotes) {
            // End of field
            try fields.append(allocator, try field.toOwnedSlice(allocator));
            field = std.ArrayList(u8).empty;
        } else {
            try field.append(allocator, c);
        }
    }

    // Last field
    try fields.append(allocator, try field.toOwnedSlice(allocator));

    return fields.toOwnedSlice(allocator);
}

/// Check if line is only whitespace
fn isWhitespace(line: []const u8) bool {
    for (line) |c| {
        if (!std.ascii.isWhitespace(c)) return false;
    }
    return true;
}

test "parse simple CSV" {
    const allocator = std.testing.allocator;

    const csv =
        \\provider,prompt
        \\deepseek,What is Zig?
        \\claude,Explain async
    ;

    const requests = try parseContent(allocator, csv);
    defer {
        for (requests) |*req| req.deinit();
        allocator.free(requests);
    }

    try std.testing.expectEqual(@as(usize, 2), requests.len);
    try std.testing.expectEqual(cli.Provider.deepseek, requests[0].provider);
    try std.testing.expectEqualStrings("What is Zig?", requests[0].prompt);
}

test "parse CSV with quotes" {
    const allocator = std.testing.allocator;

    const csv =
        \\provider,prompt
        \\deepseek,"What is ""Zig""?"
    ;

    const requests = try parseContent(allocator, csv);
    defer {
        for (requests) |*req| req.deinit();
        allocator.free(requests);
    }

    try std.testing.expectEqual(@as(usize, 1), requests.len);
    try std.testing.expectEqualStrings("What is \"Zig\"?", requests[0].prompt);
}

test "parse CSV with optional fields" {
    const allocator = std.testing.allocator;

    const csv =
        \\provider,prompt,temperature,max_tokens,system_prompt
        \\deepseek,Test,0.5,512,You are helpful
    ;

    const requests = try parseContent(allocator, csv);
    defer {
        for (requests) |*req| req.deinit();
        allocator.free(requests);
    }

    try std.testing.expectEqual(@as(usize, 1), requests.len);
    try std.testing.expectEqual(@as(f32, 0.5), requests[0].temperature);
    try std.testing.expectEqual(@as(u32, 512), requests[0].max_tokens);
    try std.testing.expectEqualStrings("You are helpful", requests[0].system_prompt.?);
}
