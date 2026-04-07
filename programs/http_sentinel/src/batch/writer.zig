// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Result writer - Write batch results to CSV (pure Zig — no libc)

const std = @import("std");
const types = @import("types.zig");

/// Reject paths containing directory traversal sequences
fn validateOutputPath(path: []const u8) !void {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return error.PathTraversal;
    }
    // Also check backslash separators
    var it2 = std.mem.splitScalar(u8, path, '\\');
    while (it2.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return error.PathTraversal;
    }
}

/// Write batch results to CSV file
pub fn writeResults(
    allocator: std.mem.Allocator,
    results: []types.BatchResult,
    output_path: []const u8,
    full_responses: bool,
) !void {
    try validateOutputPath(output_path);

    var io_threaded: std.Io.Threaded = .init(allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    const dir_path = std.fs.path.dirname(output_path) orelse ".";
    const file_name = std.fs.path.basename(output_path);

    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dir.close(io);

    // Build CSV content in memory
    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(allocator);

    // CSV header
    try csv.appendSlice(allocator, "id,provider,prompt,response,input_tokens,output_tokens,cost,execution_time_ms,error\n");

    // Write each result
    for (results) |*result| {
        const csv_line = try result.toCsv(allocator);
        defer allocator.free(csv_line);
        try csv.appendSlice(allocator, csv_line);
    }

    // Write file atomically
    try dir.writeFile(io, .{
        .sub_path = file_name,
        .data = csv.items,
    });

    std.debug.print("Results written to: {s}\n", .{output_path});

    // Write full responses if requested
    if (full_responses) {
        try writeFullResponses(allocator, io, results, output_path);
    }
}

/// Write full responses to separate files
fn writeFullResponses(
    allocator: std.mem.Allocator,
    io: std.Io,
    results: []types.BatchResult,
    output_path: []const u8,
) !void {
    // Create directory for full responses
    const dir_name = try std.fmt.allocPrint(
        allocator,
        "{s}_responses",
        .{output_path},
    );
    defer allocator.free(dir_name);

    // Create directory (pure Zig via Io)
    const parent_path = std.fs.path.dirname(dir_name) orelse ".";
    const sub_dir_name = std.fs.path.basename(dir_name);

    var parent_dir = try std.Io.Dir.openDirAbsolute(io, parent_path, .{});
    defer parent_dir.close(io);

    parent_dir.createDir(io, sub_dir_name, .default_dir) catch {};

    var resp_dir = parent_dir.openDir(io, sub_dir_name, .{}) catch return;
    defer resp_dir.close(io);

    // Write each response to a separate file
    for (results) |*result| {
        if (result.response) |response| {
            const provider_name = @tagName(result.provider);
            const filename = std.fmt.allocPrint(
                allocator,
                "{d}_{s}.txt",
                .{ result.id, provider_name },
            ) catch continue;
            defer allocator.free(filename);

            resp_dir.writeFile(io, .{
                .sub_path = filename,
                .data = response,
            }) catch {};
        }
    }

    std.debug.print("Full responses written to: {s}/\n", .{dir_name});
}

/// Generate default output filename with timestamp
pub fn generateOutputFilename(allocator: std.mem.Allocator) ![]u8 {
    var io_threaded: std.Io.Threaded = .init(allocator, .{});
    defer io_threaded.deinit();
    const timestamp = std.Io.Timestamp.now(io_threaded.io(), .real).toSeconds();
    return try std.fmt.allocPrint(
        allocator,
        "batch_results_{d}.csv",
        .{timestamp},
    );
}
