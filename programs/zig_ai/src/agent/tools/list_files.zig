// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! list_files tool implementation

const std = @import("std");
const types = @import("types.zig");
const security = @import("../security/mod.zig");

pub const ListFilesArgs = struct {
    path: []const u8 = ".",
    recursive: bool = false,
    max_depth: u32 = 3,
};

/// Execute list_files tool
pub fn execute(
    allocator: std.mem.Allocator,
    sandbox: *security.Sandbox,
    args: ListFilesArgs,
    max_files: u32,
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

    var file_count: u32 = 0;
    try listDirectory(allocator, canonical_path, &result, 0, args.max_depth, args.recursive, &file_count, max_files);

    if (result.items.len == 0) {
        return types.ToolOutput.success_result(allocator, "(empty directory)");
    }

    return types.ToolOutput{
        .success = true,
        .content = try result.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// List directory contents recursively
fn listDirectory(
    allocator: std.mem.Allocator,
    path: []const u8,
    result: *std.ArrayListUnmanaged(u8),
    depth: u32,
    max_depth: u32,
    recursive: bool,
    file_count: *u32,
    max_files: u32,
) !void {
    if (file_count.* >= max_files) {
        try result.appendSlice(allocator, "... (truncated, max files reached)\n");
        return;
    }

    // Open directory using C API
    const path_z = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, path);

    const dir = std.c.opendir(path_z.ptr);
    if (dir == null) return; // Skip unreadable directories
    defer _ = std.c.closedir(dir.?);

    while (std.c.readdir(dir.?)) |entry| {
        if (file_count.* >= max_files) break;

        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.name)));

        // Skip . and ..
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
            continue;
        }

        // Add indentation
        var i: u32 = 0;
        while (i < depth) : (i += 1) {
            try result.appendSlice(allocator, "  ");
        }

        // Determine type (macOS uses 'type' not 'd_type')
        const is_dir = entry.type == 4; // DT_DIR
        const suffix: []const u8 = if (is_dir) "/" else "";

        try result.appendSlice(allocator, name);
        try result.appendSlice(allocator, suffix);
        try result.append(allocator, '\n');
        file_count.* += 1;

        // Recurse if directory and recursive mode
        if (is_dir and recursive and depth < max_depth) {
            const subpath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, name });
            defer allocator.free(subpath);
            try listDirectory(allocator, subpath, result, depth + 1, max_depth, recursive, file_count, max_files);
        }
    }
}

/// Parse arguments from JSON
pub fn parseArgs(allocator: std.mem.Allocator, json_str: []const u8) !ListFilesArgs {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.InvalidArguments;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    // Always allocate path so it can be uniformly freed by caller
    return ListFilesArgs{
        .path = if (obj.get("path")) |p| try allocator.dupe(u8, p.string) else try allocator.dupe(u8, "."),
        .recursive = if (obj.get("recursive")) |r| r.bool else false,
        .max_depth = if (obj.get("max_depth")) |d| @intCast(d.integer) else 3,
    };
}
