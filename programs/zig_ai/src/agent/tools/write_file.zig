// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! write_file tool implementation

const std = @import("std");
const types = @import("types.zig");
const security = @import("../security/mod.zig");

pub const WriteFileArgs = struct {
    path: []const u8,
    content: []const u8,
};

/// Execute write_file tool
pub fn execute(
    allocator: std.mem.Allocator,
    sandbox: *security.Sandbox,
    args: WriteFileArgs,
    max_file_size: u32,
) !types.ToolOutput {
    // Check content size
    if (args.content.len > max_file_size) {
        const msg = try std.fmt.allocPrint(allocator, "Content too large ({d} bytes, max {d})", .{ args.content.len, max_file_size });
        defer allocator.free(msg);
        return types.ToolOutput.error_result(allocator, msg);
    }

    // Validate path and ensure writable
    const canonical_path = sandbox.validateWritablePath(args.path) catch |err| {
        return types.ToolOutput.error_result(allocator, switch (err) {
            security.SandboxError.PathOutsideSandbox => "Path is outside the sandbox",
            security.SandboxError.PathNotWritable => "Path is not writable",
            else => "Invalid path",
        });
    };
    defer allocator.free(canonical_path);

    // Ensure parent directory exists
    const parent_dir = std.fs.path.dirname(canonical_path) orelse ".";
    try ensureDirectoryExists(allocator, parent_dir);

    // Write file using C API
    const path_z = try allocator.allocSentinel(u8, canonical_path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, canonical_path);

    const file = std.c.fopen(path_z.ptr, "wb") orelse {
        return types.ToolOutput.error_result(allocator, "Failed to create/open file for writing");
    };
    defer _ = std.c.fclose(file);

    const written = std.c.fwrite(args.content.ptr, 1, args.content.len, file);
    if (written != args.content.len) {
        return types.ToolOutput.error_result(allocator, "Failed to write complete content");
    }

    const msg = try std.fmt.allocPrint(allocator, "Successfully wrote {d} bytes to {s}", .{ args.content.len, args.path });
    return types.ToolOutput{
        .success = true,
        .content = msg,
        .allocator = allocator,
    };
}

/// Ensure directory exists, creating if necessary
fn ensureDirectoryExists(allocator: std.mem.Allocator, path: []const u8) !void {
    const path_z = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, path);

    // Check if exists by trying to open as directory
    const dir = std.c.opendir(path_z.ptr);
    if (dir != null) {
        _ = std.c.closedir(dir.?);
        return; // Exists
    }

    // Try to create using mkdir -p equivalent
    var current: std.ArrayListUnmanaged(u8) = .empty;
    defer current.deinit(allocator);

    for (path) |c| {
        try current.append(allocator, c);
        if (c == '/') {
            const partial_z = try allocator.allocSentinel(u8, current.items.len, 0);
            defer allocator.free(partial_z);
            @memcpy(partial_z, current.items);
            _ = std.c.mkdir(partial_z.ptr, 0o755);
        }
    }

    // Final mkdir
    _ = std.c.mkdir(path_z.ptr, 0o755);
}

/// Parse arguments from JSON
pub fn parseArgs(allocator: std.mem.Allocator, json_str: []const u8) !WriteFileArgs {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.InvalidArguments;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    const path = obj.get("path") orelse return error.InvalidArguments;
    const content = obj.get("content") orelse return error.InvalidArguments;

    return WriteFileArgs{
        .path = try allocator.dupe(u8, path.string),
        .content = try allocator.dupe(u8, content.string),
    };
}
