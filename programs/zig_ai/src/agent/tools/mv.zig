// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! mv tool implementation
//! In-process file/directory moving without spawning external processes

const std = @import("std");
const types = @import("types.zig");
const security = @import("../security/mod.zig");

pub const MvArgs = struct {
    source: []const u8,
    destination: []const u8,
    overwrite: bool = false,
    reason: ?[]const u8 = null,
};

/// Execute mv tool - in-process move/rename
pub fn execute(
    allocator: std.mem.Allocator,
    sandbox: *security.Sandbox,
    args: MvArgs,
) !types.ToolOutput {
    // Both paths must be writable (removing from source, creating at dest)
    const src_path = sandbox.validateWritablePath(args.source) catch |err| {
        return types.ToolOutput.error_result(allocator, switch (err) {
            security.SandboxError.PathOutsideSandbox => "Source path is outside the sandbox",
            security.SandboxError.PathNotWritable => "Source path is not in a writable area",
            else => "Invalid source path",
        });
    };
    defer allocator.free(src_path);

    const dst_path = sandbox.validateWritablePath(args.destination) catch |err| {
        return types.ToolOutput.error_result(allocator, switch (err) {
            security.SandboxError.PathOutsideSandbox => "Destination path is outside the sandbox",
            security.SandboxError.PathNotWritable => "Destination is not in a writable area",
            else => "Invalid destination path",
        });
    };
    defer allocator.free(dst_path);

    // Check source exists
    const src_z = try allocator.allocSentinel(u8, src_path.len, 0);
    defer allocator.free(src_z);
    @memcpy(src_z, src_path);

    // Verify source exists (try as file, then as directory)
    const src_exists = blk: {
        const f = std.c.fopen(src_z.ptr, "rb");
        if (f != null) {
            _ = std.c.fclose(f.?);
            break :blk true;
        }
        const d = std.c.opendir(src_z.ptr);
        if (d != null) {
            _ = std.c.closedir(d.?);
            break :blk true;
        }
        break :blk false;
    };

    if (!src_exists) {
        return types.ToolOutput.error_result(allocator, "Source does not exist");
    }

    // Check if destination already exists
    const dst_z = try allocator.allocSentinel(u8, dst_path.len, 0);
    defer allocator.free(dst_z);
    @memcpy(dst_z, dst_path);

    if (!args.overwrite) {
        const existing_f = std.c.fopen(dst_z.ptr, "rb");
        if (existing_f != null) {
            _ = std.c.fclose(existing_f.?);
            return types.ToolOutput.error_result(allocator, "Destination already exists (use overwrite: true to replace)");
        }
        const existing_d = std.c.opendir(dst_z.ptr);
        if (existing_d != null) {
            _ = std.c.closedir(existing_d.?);
            return types.ToolOutput.error_result(allocator, "Destination already exists (use overwrite: true to replace)");
        }
    }

    // Try rename (works on same filesystem)
    if (std.c.rename(src_z.ptr, dst_z.ptr) == 0) {
        const result = try std.fmt.allocPrint(allocator, "Moved {s} -> {s}", .{ src_path, dst_path });
        return types.ToolOutput{
            .success = true,
            .content = result,
            .allocator = allocator,
        };
    }

    // Fallback: copy + delete (cross-filesystem)
    // Only works for regular files
    const src_file = std.c.fopen(src_z.ptr, "rb") orelse {
        return types.ToolOutput.error_result(allocator, "Cannot open source for cross-filesystem move (directories cannot be moved across filesystems)");
    };
    defer _ = std.c.fclose(src_file);

    const dst_file = std.c.fopen(dst_z.ptr, "wb") orelse {
        return types.ToolOutput.error_result(allocator, "Cannot create destination file");
    };
    defer _ = std.c.fclose(dst_file);

    var buf: [8192]u8 = undefined;
    while (true) {
        const read_count = std.c.fread(&buf, 1, buf.len, src_file);
        if (read_count > 0) {
            const written = std.c.fwrite(&buf, 1, read_count, dst_file);
            if (written != read_count) {
                return types.ToolOutput.error_result(allocator, "Write error during move");
            }
        }
        if (read_count < buf.len) break;
    }

    // Remove source after successful copy
    _ = std.c.unlink(src_z.ptr);

    const result = try std.fmt.allocPrint(allocator, "Moved {s} -> {s} (cross-filesystem)", .{ src_path, dst_path });
    return types.ToolOutput{
        .success = true,
        .content = result,
        .allocator = allocator,
    };
}

/// Parse arguments from JSON
pub fn parseArgs(allocator: std.mem.Allocator, json_str: []const u8) !MvArgs {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.InvalidArguments;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    const source = obj.get("source") orelse return error.InvalidArguments;
    const destination = obj.get("destination") orelse return error.InvalidArguments;

    return MvArgs{
        .source = try allocator.dupe(u8, source.string),
        .destination = try allocator.dupe(u8, destination.string),
        .overwrite = if (obj.get("overwrite")) |o| o.bool else false,
        .reason = if (obj.get("reason")) |r| try allocator.dupe(u8, r.string) else null,
    };
}

/// Free allocated args
pub fn freeArgs(allocator: std.mem.Allocator, args: MvArgs) void {
    allocator.free(args.source);
    allocator.free(args.destination);
    if (args.reason) |r| allocator.free(r);
}
