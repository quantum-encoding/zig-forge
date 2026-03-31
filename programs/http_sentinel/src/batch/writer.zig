// Copyright (c) 2025 QUANTUM ENCODING LTD
// Author: Rich <rich@quantumencoding.io>
// Website: https://quantumencoding.io
//
// Licensed under the MIT License. See LICENSE file for details.

//! Result writer - Write batch results to CSV

const std = @import("std");
const types = @import("types.zig");

/// Write batch results to CSV file
pub fn writeResults(
    allocator: std.mem.Allocator,
    results: []types.BatchResult,
    output_path: []const u8,
    full_responses: bool,
) !void {
    // Convert path to null-terminated string
    const path_z = try allocator.dupeZ(u8, output_path);
    defer allocator.free(path_z);

    // Open file for writing
    const fd = try std.posix.openatZ(
        std.posix.AT.FDCWD,
        path_z,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    );
    defer _ = std.c.close(fd);

    // Write CSV header
    const header = "id,provider,prompt,response,input_tokens,output_tokens,cost,execution_time_ms,error\n";
    _ = try writeAll(fd, header);

    // Write each result
    for (results) |*result| {
        const csv_line = try result.toCsv(allocator);
        defer allocator.free(csv_line);
        _ = try writeAll(fd, csv_line);
    }

    std.debug.print("Results written to: {s}\n", .{output_path});

    // Write full responses if requested
    if (full_responses) {
        try writeFullResponses(allocator, results, output_path);
    }
}

/// Write all bytes to file descriptor
fn writeAll(fd: std.posix.fd_t, data: []const u8) !usize {
    var written: usize = 0;
    while (written < data.len) {
        const n = std.c.write(fd, data.ptr + written, data.len - written);
        if (n < 0) return error.WriteError;
        if (n == 0) break;
        written += @intCast(n);
    }
    return written;
}

/// Write full responses to separate files
fn writeFullResponses(
    allocator: std.mem.Allocator,
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

    const dir_name_z = try allocator.dupeZ(u8, dir_name);
    defer allocator.free(dir_name_z);

    // Try to create directory (ignore if exists)
    _ = std.c.mkdir(dir_name_z, 0o755);

    // Write each response to a separate file
    for (results) |*result| {
        if (result.response) |response| {
            const provider_name = @tagName(result.provider);
            const filename = try std.fmt.allocPrint(
                allocator,
                "{s}/{d}_{s}.txt",
                .{ dir_name, result.id, provider_name },
            );
            defer allocator.free(filename);

            const filename_z = try allocator.dupeZ(u8, filename);
            defer allocator.free(filename_z);

            const fd = std.posix.openatZ(
                std.posix.AT.FDCWD,
                filename_z,
                .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
                0o644,
            ) catch continue;
            defer _ = std.c.close(fd);

            _ = writeAll(fd, response) catch {};
        }
    }

    std.debug.print("Full responses written to: {s}/\n", .{dir_name});
}

/// Generate default output filename with timestamp
pub fn generateOutputFilename(allocator: std.mem.Allocator) ![]u8 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const timestamp = ts.sec;
    return try std.fmt.allocPrint(
        allocator,
        "batch_results_{d}.csv",
        .{timestamp},
    );
}
