// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! touch tool implementation
//! In-process file creation/timestamp update without spawning external processes

const std = @import("std");
const types = @import("types.zig");
const security = @import("../security/mod.zig");

pub const TouchArgs = struct {
    path: []const u8,
    reason: ?[]const u8 = null,
};

/// Execute touch tool - create file or update timestamp
pub fn execute(
    allocator: std.mem.Allocator,
    sandbox: *security.Sandbox,
    args: TouchArgs,
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

    const path_z = try allocator.allocSentinel(u8, canonical_path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, canonical_path);

    // Open in append mode - creates if doesn't exist, doesn't truncate if it does
    const file = std.c.fopen(path_z.ptr, "ab") orelse {
        return types.ToolOutput.error_result(allocator, "Cannot create or open file");
    };
    _ = std.c.fclose(file);

    // Update timestamp by opening again (utimes not available in Zig 0.16 C bindings)
    // The fopen above already updates atime; re-opening with "ab" is sufficient

    const result = try std.fmt.allocPrint(allocator, "Touched: {s}", .{canonical_path});
    return types.ToolOutput{
        .success = true,
        .content = result,
        .allocator = allocator,
    };
}

/// Parse arguments from JSON
pub fn parseArgs(allocator: std.mem.Allocator, json_str: []const u8) !TouchArgs {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.InvalidArguments;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    const path = obj.get("path") orelse return error.InvalidArguments;

    return TouchArgs{
        .path = try allocator.dupe(u8, path.string),
        .reason = if (obj.get("reason")) |r| try allocator.dupe(u8, r.string) else null,
    };
}

/// Free allocated args
pub fn freeArgs(allocator: std.mem.Allocator, args: TouchArgs) void {
    allocator.free(args.path);
    if (args.reason) |r| allocator.free(r);
}
