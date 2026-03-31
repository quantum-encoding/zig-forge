// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! rm tool implementation
//! In-process file/directory removal without spawning external processes

const std = @import("std");
const types = @import("types.zig");
const security = @import("../security/mod.zig");

pub const RmArgs = struct {
    path: []const u8,
    recursive: bool = false,
    force: bool = false,
    reason: ?[]const u8 = null,
};

/// Execute rm tool - in-process file/directory removal
pub fn execute(
    allocator: std.mem.Allocator,
    sandbox: *security.Sandbox,
    args: RmArgs,
) !types.ToolOutput {
    // Validate path is writable within sandbox
    const canonical_path = sandbox.validateWritablePath(args.path) catch |err| {
        return types.ToolOutput.error_result(allocator, switch (err) {
            security.SandboxError.PathOutsideSandbox => "Path is outside the sandbox",
            security.SandboxError.PathNotWritable => "Path is not in a writable area",
            else => "Invalid path",
        });
    };
    defer allocator.free(canonical_path);

    // Safety: refuse to remove sandbox root
    const sandbox_root = sandbox.validatePath(".") catch {
        return types.ToolOutput.error_result(allocator, "Cannot resolve sandbox root");
    };
    defer allocator.free(sandbox_root);

    if (std.mem.eql(u8, canonical_path, sandbox_root)) {
        return types.ToolOutput.error_result(allocator, "Refusing to remove sandbox root directory");
    }

    // Check if target exists and its type
    const path_z = try allocator.allocSentinel(u8, canonical_path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, canonical_path);

    const is_dir = blk: {
        const dir = std.c.opendir(path_z.ptr);
        if (dir != null) {
            _ = std.c.closedir(dir.?);
            break :blk true;
        }
        break :blk false;
    };

    if (is_dir) {
        if (!args.recursive) {
            return types.ToolOutput.error_result(allocator, "Cannot remove directory without recursive flag");
        }

        var removed: usize = 0;
        removeDirectoryRecursive(allocator, sandbox, canonical_path, &removed, 0) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Failed to remove directory (removed {d} items before error: {any})", .{ removed, err });
            return types.ToolOutput{
                .success = false,
                .content = try allocator.dupe(u8, ""),
                .error_message = msg,
                .allocator = allocator,
            };
        };

        const result = try std.fmt.allocPrint(allocator, "Removed directory and {d} items: {s}", .{ removed, canonical_path });
        return types.ToolOutput{
            .success = true,
            .content = result,
            .allocator = allocator,
        };
    } else {
        // It's a file - try to remove it
        const file = std.c.fopen(path_z.ptr, "rb");
        if (file == null and !args.force) {
            return types.ToolOutput.error_result(allocator, "File does not exist");
        }
        if (file != null) _ = std.c.fclose(file.?);

        if (std.c.unlink(path_z.ptr) != 0) {
            if (!args.force) {
                return types.ToolOutput.error_result(allocator, "Failed to remove file");
            }
        }

        const result = try std.fmt.allocPrint(allocator, "Removed: {s}", .{canonical_path});
        return types.ToolOutput{
            .success = true,
            .content = result,
            .allocator = allocator,
        };
    }
}

fn removeDirectoryRecursive(
    allocator: std.mem.Allocator,
    sandbox: *security.Sandbox,
    dir_path: []const u8,
    removed: *usize,
    depth: u32,
) !void {
    if (depth > 20) return error.ExecutionFailed;
    if (removed.* > 10000) return error.ExecutionFailed; // Safety cap

    const dir_z = try allocator.allocSentinel(u8, dir_path.len, 0);
    defer allocator.free(dir_z);
    @memcpy(dir_z, dir_path);

    const dir = std.c.opendir(dir_z.ptr) orelse return error.ExecutionFailed;
    defer _ = std.c.closedir(dir);

    while (std.c.readdir(dir)) |entry| {
        if (removed.* > 10000) return error.ExecutionFailed;

        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, name });
        defer allocator.free(full_path);

        // Validate still in sandbox
        if (sandbox.validateWritablePath(full_path)) |validated| {
            allocator.free(validated);
        } else |_| continue;

        const fp_z = try allocator.allocSentinel(u8, full_path.len, 0);
        defer allocator.free(fp_z);
        @memcpy(fp_z, full_path);

        // Check if subdirectory
        const sub_dir = std.c.opendir(fp_z.ptr);
        if (sub_dir != null) {
            _ = std.c.closedir(sub_dir.?);
            try removeDirectoryRecursive(allocator, sandbox, full_path, removed, depth + 1);
        } else {
            // Remove file
            if (std.c.unlink(fp_z.ptr) == 0) {
                removed.* += 1;
            }
        }
    }

    // Remove the now-empty directory
    if (std.c.rmdir(dir_z.ptr) == 0) {
        removed.* += 1;
    }
}

/// Parse arguments from JSON
pub fn parseArgs(allocator: std.mem.Allocator, json_str: []const u8) !RmArgs {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.InvalidArguments;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    const path = obj.get("path") orelse return error.InvalidArguments;

    return RmArgs{
        .path = try allocator.dupe(u8, path.string),
        .recursive = if (obj.get("recursive")) |r| r.bool else false,
        .force = if (obj.get("force")) |f| f.bool else false,
        .reason = if (obj.get("reason")) |r| try allocator.dupe(u8, r.string) else null,
    };
}

/// Free allocated args
pub fn freeArgs(allocator: std.mem.Allocator, args: RmArgs) void {
    allocator.free(args.path);
    if (args.reason) |r| allocator.free(r);
}
