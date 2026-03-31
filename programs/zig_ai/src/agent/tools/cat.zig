// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! cat tool implementation
//! In-process file concatenation without spawning external processes

const std = @import("std");
const types = @import("types.zig");
const security = @import("../security/mod.zig");

pub const CatArgs = struct {
    paths: []const []const u8,
    number_lines: bool = false,
    number_nonblank: bool = false,
    show_ends: bool = false,
    squeeze_blank: bool = false,
};

/// Execute cat tool - in-process file concatenation
pub fn execute(
    allocator: std.mem.Allocator,
    sandbox: *security.Sandbox,
    args: CatArgs,
    max_file_size: usize,
) !types.ToolOutput {
    if (args.paths.len == 0) {
        return types.ToolOutput.error_result(allocator, "No files specified");
    }

    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);

    var line_number: usize = 1;
    var prev_blank = false;

    for (args.paths) |path| {
        // Validate path is within sandbox
        const canonical_path = sandbox.validatePath(path) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "{s}: {s}", .{
                path,
                switch (err) {
                    security.SandboxError.PathOutsideSandbox => "Path is outside the sandbox",
                    else => "Invalid path",
                },
            });
            defer allocator.free(msg);
            try output.appendSlice(allocator, msg);
            try output.append(allocator, '\n');
            continue;
        };
        defer allocator.free(canonical_path);

        // Read file
        const content = readFile(allocator, canonical_path, max_file_size) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "{s}: {s}", .{
                path,
                switch (err) {
                    error.FileNotFound => "No such file",
                    error.IsDirectory => "Is a directory",
                    error.FileTooLarge => "File too large",
                    else => "Read error",
                },
            });
            defer allocator.free(msg);
            try output.appendSlice(allocator, msg);
            try output.append(allocator, '\n');
            continue;
        };
        defer allocator.free(content);

        // Process content
        var line_start: usize = 0;
        for (content, 0..) |c, i| {
            if (c == '\n' or i == content.len - 1) {
                const line_end = if (c == '\n') i else i + 1;
                const line = content[line_start..line_end];
                const is_blank = line.len == 0 or (line.len == 1 and line[0] == '\r');

                // Squeeze blank lines
                if (args.squeeze_blank and is_blank and prev_blank) {
                    line_start = i + 1;
                    continue;
                }
                prev_blank = is_blank;

                // Line numbering
                if (args.number_nonblank and !is_blank) {
                    const num = try std.fmt.allocPrint(allocator, "{d:>6}\t", .{line_number});
                    defer allocator.free(num);
                    try output.appendSlice(allocator, num);
                    line_number += 1;
                } else if (args.number_lines) {
                    const num = try std.fmt.allocPrint(allocator, "{d:>6}\t", .{line_number});
                    defer allocator.free(num);
                    try output.appendSlice(allocator, num);
                    line_number += 1;
                }

                // Line content
                try output.appendSlice(allocator, line);

                // Show ends
                if (args.show_ends) {
                    try output.append(allocator, '$');
                }

                try output.append(allocator, '\n');
                line_start = i + 1;
            }
        }

        // Handle file without trailing newline
        if (line_start < content.len and content[content.len - 1] != '\n') {
            // Already handled in the loop above
        }
    }

    if (output.items.len == 0) {
        return types.ToolOutput.error_result(allocator, "No files could be read");
    }

    return types.ToolOutput{
        .success = true,
        .content = try output.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn readFile(allocator: std.mem.Allocator, path: []const u8, max_size: usize) ![]u8 {
    const path_z = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, path);

    // Check if it's a directory
    const dir = std.c.opendir(path_z.ptr);
    if (dir != null) {
        _ = std.c.closedir(dir.?);
        return error.IsDirectory;
    }

    const file = std.c.fopen(path_z.ptr, "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(file);

    var content: std.ArrayListUnmanaged(u8) = .empty;
    errdefer content.deinit(allocator);

    var buf: [8192]u8 = undefined;
    while (true) {
        const read_count = std.c.fread(&buf, 1, buf.len, file);
        if (read_count > 0) {
            try content.appendSlice(allocator, buf[0..read_count]);
            if (content.items.len > max_size) {
                return error.FileTooLarge;
            }
        }
        if (read_count < buf.len) break;
    }

    return content.toOwnedSlice(allocator);
}

/// Parse arguments from JSON
pub fn parseArgs(allocator: std.mem.Allocator, json_str: []const u8) !CatArgs {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.InvalidArguments;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    const paths_val = obj.get("paths") orelse return error.InvalidArguments;
    const paths_arr = paths_val.array.items;

    var paths = try allocator.alloc([]const u8, paths_arr.len);
    errdefer {
        for (paths) |p| allocator.free(p);
        allocator.free(paths);
    }

    for (paths_arr, 0..) |p, i| {
        paths[i] = try allocator.dupe(u8, p.string);
    }

    return CatArgs{
        .paths = paths,
        .number_lines = if (obj.get("number_lines")) |n| n.bool else false,
        .number_nonblank = if (obj.get("number_nonblank")) |n| n.bool else false,
        .show_ends = if (obj.get("show_ends")) |s| s.bool else false,
        .squeeze_blank = if (obj.get("squeeze_blank")) |s| s.bool else false,
    };
}

/// Free allocated args
pub fn freeArgs(allocator: std.mem.Allocator, args: CatArgs) void {
    for (args.paths) |p| {
        allocator.free(p);
    }
    allocator.free(args.paths);
}
