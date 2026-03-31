// Results CSV writer for image batch processing
// Writes batch results to a CSV file after execution

const std = @import("std");
const types = @import("types.zig");

// C file functions for Zig 0.16 compatibility
const FILE = std.c.FILE;
extern "c" fn fputs(s: [*:0]const u8, stream: *FILE) c_int;

/// Write batch results to a CSV file
pub fn writeResults(
    allocator: std.mem.Allocator,
    results: []types.ImageBatchResult,
    output_path: []const u8,
) !void {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{output_path}) catch return error.PathTooLong;

    const file = std.c.fopen(path_z, "w") orelse return error.FileOpenFailed;
    defer _ = std.c.fclose(file);

    // Write header
    writeStr(file, "id,status,provider,prompt,image_paths,execution_time_ms,file_size_bytes,error\n");

    // Write each result
    for (results) |*result| {
        const line = try resultToCsv(allocator, result);
        defer allocator.free(line);

        var line_buf: [8192]u8 = undefined;
        const line_z = std.fmt.bufPrintZ(&line_buf, "{s}", .{line}) catch continue;
        _ = fputs(line_z, file);
    }

    std.debug.print("Results written to: {s}\n", .{output_path});
}

/// Generate default output filename with timestamp
pub fn generateOutputFilename(allocator: std.mem.Allocator) ![]u8 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const timestamp = ts.sec;
    return try std.fmt.allocPrint(
        allocator,
        "image_batch_results_{d}.csv",
        .{timestamp},
    );
}

/// Convert a single result to a CSV line
fn resultToCsv(allocator: std.mem.Allocator, result: *const types.ImageBatchResult) ![]const u8 {
    // Build image_paths as semicolon-separated string
    var paths_buf: std.ArrayList(u8) = .empty;
    defer paths_buf.deinit(allocator);
    for (result.image_paths, 0..) |path, i| {
        if (i > 0) try paths_buf.append(allocator, ';');
        try paths_buf.appendSlice(allocator, path);
    }
    const paths_str = if (paths_buf.items.len > 0) paths_buf.items else "";

    const provider_name = if (result.provider) |p| @tagName(p) else "";
    const error_msg = result.error_message orelse "";

    // Escape prompt for CSV (double quotes inside, wrap in quotes)
    const escaped_prompt = try escapeCsvField(allocator, result.prompt);
    defer allocator.free(escaped_prompt);

    const escaped_error = try escapeCsvField(allocator, error_msg);
    defer allocator.free(escaped_error);

    return std.fmt.allocPrint(allocator, "{},{s},{s},{s},{s},{},{},{s}\n", .{
        result.id,
        result.status.toString(),
        provider_name,
        escaped_prompt,
        paths_str,
        result.execution_time_ms,
        result.file_size_bytes,
        escaped_error,
    });
}

/// Escape a string for CSV: wrap in quotes if it contains commas, quotes, or newlines
fn escapeCsvField(allocator: std.mem.Allocator, field: []const u8) ![]const u8 {
    var needs_quoting = false;
    var quote_count: usize = 0;

    for (field) |c| {
        if (c == '"') {
            needs_quoting = true;
            quote_count += 1;
        } else if (c == ',' or c == '\n' or c == '\r') {
            needs_quoting = true;
        }
    }

    if (!needs_quoting) return allocator.dupe(u8, field);

    // Allocate: 2 for wrapping quotes + field length + extra quotes for escaping
    var result = try allocator.alloc(u8, field.len + quote_count + 2);
    var j: usize = 0;
    result[j] = '"';
    j += 1;

    for (field) |c| {
        if (c == '"') {
            result[j] = '"';
            j += 1;
            result[j] = '"';
            j += 1;
        } else {
            result[j] = c;
            j += 1;
        }
    }

    result[j] = '"';
    j += 1;

    // Trim to actual size (should match, but be safe)
    if (j < result.len) {
        const trimmed = try allocator.dupe(u8, result[0..j]);
        allocator.free(result);
        return trimmed;
    }
    return result;
}

fn writeStr(file: *FILE, s: []const u8) void {
    _ = std.c.fwrite(s.ptr, 1, s.len, file);
}
