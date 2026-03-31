// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! search_files tool implementation (grep-like)

const std = @import("std");
const types = @import("types.zig");
const security = @import("../security/mod.zig");

pub const SearchFilesArgs = struct {
    pattern: []const u8,
    path: []const u8 = ".",
    file_pattern: []const u8 = "*",
    max_results: u32 = 50,
};

/// Execute search_files tool
pub fn execute(
    allocator: std.mem.Allocator,
    sandbox: *security.Sandbox,
    args: SearchFilesArgs,
) !types.ToolOutput {
    // Validate path
    const canonical_path = sandbox.validatePath(args.path) catch |err| {
        return types.ToolOutput.error_result(allocator, switch (err) {
            security.SandboxError.PathOutsideSandbox => "Path is outside the sandbox",
            else => "Invalid path",
        });
    };
    defer allocator.free(canonical_path);

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var match_count: u32 = 0;
    try searchDirectory(allocator, canonical_path, args.pattern, args.file_pattern, &result, &match_count, args.max_results);

    if (match_count == 0) {
        return types.ToolOutput.success_result(allocator, "No matches found");
    }

    const summary = try std.fmt.allocPrint(allocator, "\n--- {d} matches found ---", .{match_count});
    defer allocator.free(summary);
    try result.appendSlice(allocator, summary);

    return types.ToolOutput{
        .success = true,
        .content = try result.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Search directory recursively
fn searchDirectory(
    allocator: std.mem.Allocator,
    path: []const u8,
    pattern: []const u8,
    file_pattern: []const u8,
    result: *std.ArrayListUnmanaged(u8),
    match_count: *u32,
    max_results: u32,
) !void {
    if (match_count.* >= max_results) return;

    const path_z = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, path);

    // Try to open as directory
    const dir = std.c.opendir(path_z.ptr);
    if (dir == null) {
        // Not a directory - try to search as file
        if (matchesFilePattern(std.fs.path.basename(path), file_pattern)) {
            try searchFile(allocator, path, pattern, result, match_count, max_results);
        }
        return;
    }
    defer _ = std.c.closedir(dir.?);

    while (std.c.readdir(dir.?)) |entry| {
        if (match_count.* >= max_results) break;

        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        const subpath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, name });
        defer allocator.free(subpath);

        // Use entry.type to determine if it's a directory
        // DT_DIR = 4, DT_REG = 8, DT_UNKNOWN = 0
        const is_subdir = entry.type == 4;

        if (is_subdir) {
            try searchDirectory(allocator, subpath, pattern, file_pattern, result, match_count, max_results);
        } else if (entry.type == 0) {
            // Unknown type - try to recurse (will fail if not a directory)
            searchDirectory(allocator, subpath, pattern, file_pattern, result, match_count, max_results) catch {
                // Not a directory, try as file
                if (matchesFilePattern(name, file_pattern)) {
                    try searchFile(allocator, subpath, pattern, result, match_count, max_results);
                }
            };
        } else if (matchesFilePattern(name, file_pattern)) {
            try searchFile(allocator, subpath, pattern, result, match_count, max_results);
        }
    }
}

/// Search a single file for pattern matches
fn searchFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    pattern: []const u8,
    result: *std.ArrayListUnmanaged(u8),
    match_count: *u32,
    max_results: u32,
) !void {
    const path_z = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, path);

    const file = std.c.fopen(path_z.ptr, "rb") orelse return;
    defer _ = std.c.fclose(file);

    // Read file content in chunks (limit to 1MB for search)
    var content_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer content_buf.deinit(allocator);

    var buf: [4096]u8 = undefined;
    const max_size: usize = 1048576;
    while (true) {
        const read_count = std.c.fread(&buf, 1, buf.len, file);
        if (read_count > 0) {
            if (content_buf.items.len + read_count > max_size) break;
            try content_buf.appendSlice(allocator, buf[0..read_count]);
        }
        if (read_count < buf.len) break;
    }

    if (content_buf.items.len == 0) return;
    const content = content_buf.items;

    // Search line by line
    var line_num: u32 = 1;
    var line_start: usize = 0;

    for (content, 0..) |c, i| {
        if (c == '\n' or i == content.len - 1) {
            const line_end = if (c == '\n') i else i + 1;
            const line = content[line_start..line_end];

            if (std.mem.indexOf(u8, line, pattern) != null) {
                // Found match
                const match_line = try std.fmt.allocPrint(allocator, "{s}:{d}: {s}\n", .{
                    std.fs.path.basename(path),
                    line_num,
                    std.mem.trim(u8, line, &[_]u8{ '\r', '\n' }),
                });
                defer allocator.free(match_line);
                try result.appendSlice(allocator, match_line);
                match_count.* += 1;

                if (match_count.* >= max_results) return;
            }

            line_start = i + 1;
            line_num += 1;
        }
    }
}

/// Simple glob pattern matching for file names
fn matchesFilePattern(name: []const u8, pattern: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;

    // Simple extension matching: *.ext
    if (pattern.len > 1 and pattern[0] == '*' and pattern[1] == '.') {
        const ext = pattern[1..];
        return std.mem.endsWith(u8, name, ext);
    }

    return std.mem.eql(u8, name, pattern);
}

/// Parse arguments from JSON
pub fn parseArgs(allocator: std.mem.Allocator, json_str: []const u8) !SearchFilesArgs {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.InvalidArguments;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    const pattern = obj.get("pattern") orelse return error.InvalidArguments;

    // Always allocate strings so they can be uniformly freed by caller
    return SearchFilesArgs{
        .pattern = try allocator.dupe(u8, pattern.string),
        .path = if (obj.get("path")) |p| try allocator.dupe(u8, p.string) else try allocator.dupe(u8, "."),
        .file_pattern = if (obj.get("file_pattern")) |f| try allocator.dupe(u8, f.string) else try allocator.dupe(u8, "*"),
        .max_results = if (obj.get("max_results")) |m| @intCast(m.integer) else 50,
    };
}
