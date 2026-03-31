// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! cp tool implementation
//! In-process file copying without spawning external processes

const std = @import("std");
const types = @import("types.zig");
const security = @import("../security/mod.zig");

pub const CpArgs = struct {
    source: []const u8,
    destination: []const u8,
    overwrite: bool = false,
    reason: ?[]const u8 = null,
};

/// Execute cp tool - in-process file copying
pub fn execute(
    allocator: std.mem.Allocator,
    sandbox: *security.Sandbox,
    args: CpArgs,
) !types.ToolOutput {
    // Validate source path is readable within sandbox
    const src_path = sandbox.validatePath(args.source) catch |err| {
        return types.ToolOutput.error_result(allocator, switch (err) {
            security.SandboxError.PathOutsideSandbox => "Source path is outside the sandbox",
            else => "Invalid source path",
        });
    };
    defer allocator.free(src_path);

    // Validate destination path is writable
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

    const src_file = std.c.fopen(src_z.ptr, "rb") orelse {
        return types.ToolOutput.error_result(allocator, "Source file does not exist or is not readable");
    };
    defer _ = std.c.fclose(src_file);

    // Check if destination already exists
    const dst_z = try allocator.allocSentinel(u8, dst_path.len, 0);
    defer allocator.free(dst_z);
    @memcpy(dst_z, dst_path);

    if (!args.overwrite) {
        const existing = std.c.fopen(dst_z.ptr, "rb");
        if (existing != null) {
            _ = std.c.fclose(existing.?);
            return types.ToolOutput.error_result(allocator, "Destination already exists (use overwrite: true to replace)");
        }
    }

    // Copy file content
    const dst_file = std.c.fopen(dst_z.ptr, "wb") orelse {
        return types.ToolOutput.error_result(allocator, "Cannot create destination file");
    };
    defer _ = std.c.fclose(dst_file);

    var total_bytes: usize = 0;
    var buf: [8192]u8 = undefined;
    while (true) {
        const read_count = std.c.fread(&buf, 1, buf.len, src_file);
        if (read_count > 0) {
            const written = std.c.fwrite(&buf, 1, read_count, dst_file);
            if (written != read_count) {
                return types.ToolOutput.error_result(allocator, "Write error during copy");
            }
            total_bytes += read_count;
        }
        if (read_count < buf.len) break;
    }

    const result = try std.fmt.allocPrint(allocator, "Copied {s} -> {s} ({d} bytes)", .{ src_path, dst_path, total_bytes });
    return types.ToolOutput{
        .success = true,
        .content = result,
        .allocator = allocator,
    };
}

/// Parse arguments from JSON
pub fn parseArgs(allocator: std.mem.Allocator, json_str: []const u8) !CpArgs {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.InvalidArguments;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    const source = obj.get("source") orelse return error.InvalidArguments;
    const destination = obj.get("destination") orelse return error.InvalidArguments;

    return CpArgs{
        .source = try allocator.dupe(u8, source.string),
        .destination = try allocator.dupe(u8, destination.string),
        .overwrite = if (obj.get("overwrite")) |o| o.bool else false,
        .reason = if (obj.get("reason")) |r| try allocator.dupe(u8, r.string) else null,
    };
}

/// Free allocated args
pub fn freeArgs(allocator: std.mem.Allocator, args: CpArgs) void {
    allocator.free(args.source);
    allocator.free(args.destination);
    if (args.reason) |r| allocator.free(r);
}
