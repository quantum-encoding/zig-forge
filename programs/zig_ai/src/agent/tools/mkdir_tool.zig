// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! mkdir tool implementation
//! In-process directory creation without spawning external processes

const std = @import("std");
const types = @import("types.zig");
const security = @import("../security/mod.zig");

pub const MkdirArgs = struct {
    path: []const u8,
    parents: bool = false,
    reason: ?[]const u8 = null,
};

/// Execute mkdir tool - in-process directory creation
pub fn execute(
    allocator: std.mem.Allocator,
    sandbox: *security.Sandbox,
    args: MkdirArgs,
) !types.ToolOutput {
    // Validate path is writable
    const canonical_path = sandbox.validateWritablePath(args.path) catch |err| {
        return types.ToolOutput.error_result(allocator, switch (err) {
            security.SandboxError.PathOutsideSandbox => "Path is outside the sandbox",
            security.SandboxError.PathNotWritable => "Path is not in a writable area",
            else => "Invalid path",
        });
    };
    defer allocator.free(canonical_path);

    if (args.parents) {
        // Create parent directories
        try createParents(allocator, canonical_path);
    } else {
        // Single directory creation
        const path_z = try allocator.allocSentinel(u8, canonical_path.len, 0);
        defer allocator.free(path_z);
        @memcpy(path_z, canonical_path);

        if (std.c.mkdir(path_z.ptr, 0o755) != 0) {
            // Check if already exists
            const dir = std.c.opendir(path_z.ptr);
            if (dir != null) {
                _ = std.c.closedir(dir.?);
                return types.ToolOutput.error_result(allocator, "Directory already exists");
            }
            return types.ToolOutput.error_result(allocator, "Failed to create directory (parent may not exist, use parents: true)");
        }
    }

    const result = try std.fmt.allocPrint(allocator, "Created directory: {s}", .{canonical_path});
    return types.ToolOutput{
        .success = true,
        .content = result,
        .allocator = allocator,
    };
}

/// Create directory and all parent directories
fn createParents(allocator: std.mem.Allocator, path: []const u8) !void {
    // Walk through path components and create each
    var i: usize = 1; // Skip leading /
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            const partial = path[0..i];
            const partial_z = try allocator.allocSentinel(u8, partial.len, 0);
            defer allocator.free(partial_z);
            @memcpy(partial_z, partial);

            // Try to create - ignore EEXIST
            const result = std.c.mkdir(partial_z.ptr, 0o755);
            if (result != 0) {
                // Check if it already exists as a directory (that's fine)
                const dir = std.c.opendir(partial_z.ptr);
                if (dir != null) {
                    _ = std.c.closedir(dir.?);
                    continue;
                }
                return error.ExecutionFailed;
            }
        }
    }
}

/// Parse arguments from JSON
pub fn parseArgs(allocator: std.mem.Allocator, json_str: []const u8) !MkdirArgs {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.InvalidArguments;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    const path = obj.get("path") orelse return error.InvalidArguments;

    return MkdirArgs{
        .path = try allocator.dupe(u8, path.string),
        .parents = if (obj.get("parents")) |p| p.bool else false,
        .reason = if (obj.get("reason")) |r| try allocator.dupe(u8, r.string) else null,
    };
}

/// Free allocated args
pub fn freeArgs(allocator: std.mem.Allocator, args: MkdirArgs) void {
    allocator.free(args.path);
    if (args.reason) |r| allocator.free(r);
}
