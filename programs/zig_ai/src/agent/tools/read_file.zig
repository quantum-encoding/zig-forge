// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! read_file tool implementation

const std = @import("std");
const types = @import("types.zig");
const security = @import("../security/mod.zig");

pub const ReadFileArgs = struct {
    path: []const u8,
    offset: u32 = 1,
    limit: u32 = 500,
};

/// Execute read_file tool
pub fn execute(
    allocator: std.mem.Allocator,
    sandbox: *security.Sandbox,
    args: ReadFileArgs,
    max_file_size: u32,
) !types.ToolOutput {
    // Validate path
    const canonical_path = sandbox.validatePath(args.path) catch |err| {
        return types.ToolOutput.error_result(allocator, switch (err) {
            security.SandboxError.PathOutsideSandbox => "Path is outside the sandbox",
            else => "Invalid path",
        });
    };
    defer allocator.free(canonical_path);

    // Open file using C API
    const path_z = try allocator.allocSentinel(u8, canonical_path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, canonical_path);

    const file = std.c.fopen(path_z.ptr, "rb") orelse {
        return types.ToolOutput.error_result(allocator, "File not found or cannot be opened");
    };
    defer _ = std.c.fclose(file);

    // Read content in chunks (no fseek/ftell in Zig 0.16)
    var content_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer content_buf.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const read_count = std.c.fread(&buf, 1, buf.len, file);
        if (read_count > 0) {
            if (content_buf.items.len + read_count > max_file_size) {
                const msg = try std.fmt.allocPrint(allocator, "File too large (> {d} bytes)", .{max_file_size});
                defer allocator.free(msg);
                return types.ToolOutput.error_result(allocator, msg);
            }
            try content_buf.appendSlice(allocator, buf[0..read_count]);
        }
        if (read_count < buf.len) break;
    }

    const content = content_buf.items;

    // Apply line offset and limit
    const filtered = applyLineFilter(allocator, content, args.offset, args.limit) catch {
        return types.ToolOutput.error_result(allocator, "Failed to process file content");
    };

    return types.ToolOutput{
        .success = true,
        .content = filtered,
        .allocator = allocator,
    };
}

/// Apply line offset and limit filter
fn applyLineFilter(allocator: std.mem.Allocator, content: []const u8, offset: u32, limit: u32) ![]const u8 {
    if (offset <= 1 and limit >= 10000) {
        // No filtering needed
        return allocator.dupe(u8, content);
    }

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var line_num: u32 = 1;
    var lines_output: u32 = 0;
    var line_start: usize = 0;

    for (content, 0..) |c, i| {
        if (c == '\n' or i == content.len - 1) {
            const line_end = if (c == '\n') i else i + 1;

            if (line_num >= offset and lines_output < limit) {
                // Add line number prefix
                const prefix = try std.fmt.allocPrint(allocator, "{d: >6}\t", .{line_num});
                defer allocator.free(prefix);
                try result.appendSlice(allocator, prefix);
                try result.appendSlice(allocator, content[line_start..line_end]);
                if (c != '\n' and i == content.len - 1) {
                    try result.append(allocator, '\n');
                }
                lines_output += 1;
            }

            line_start = i + 1;
            line_num += 1;

            if (lines_output >= limit) {
                break;
            }
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Parse arguments from JSON
pub fn parseArgs(allocator: std.mem.Allocator, json_str: []const u8) !ReadFileArgs {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.InvalidArguments;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    const path = obj.get("path") orelse return error.InvalidArguments;

    return ReadFileArgs{
        .path = try allocator.dupe(u8, path.string),
        .offset = if (obj.get("offset")) |o| @intCast(o.integer) else 1,
        .limit = if (obj.get("limit")) |l| @intCast(l.integer) else 500,
    };
}
