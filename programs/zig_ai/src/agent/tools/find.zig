// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! find tool implementation
//! In-process file finding without spawning external processes

const std = @import("std");
const types = @import("types.zig");
const security = @import("../security/mod.zig");

pub const FindArgs = struct {
    path: []const u8 = ".",
    name: ?[]const u8 = null,
    file_type: ?FileType = null,
    max_depth: u32 = 10,
    min_size: ?usize = null,
    max_size: ?usize = null,
    max_results: u32 = 500,

    pub const FileType = enum {
        file, // f
        directory, // d
        symlink, // l
    };
};

const FindResult = struct {
    path: []const u8,
    file_type: FindArgs.FileType,
    size: usize,
};

/// Execute find tool - in-process file finding
pub fn execute(
    allocator: std.mem.Allocator,
    sandbox: *security.Sandbox,
    args: FindArgs,
) !types.ToolOutput {
    // Validate starting path is within sandbox
    const canonical_path = sandbox.validatePath(args.path) catch |err| {
        return types.ToolOutput.error_result(allocator, switch (err) {
            security.SandboxError.PathOutsideSandbox => "Path is outside the sandbox",
            else => "Invalid path",
        });
    };
    defer allocator.free(canonical_path);

    var results: std.ArrayListUnmanaged(FindResult) = .empty;
    defer {
        for (results.items) |r| allocator.free(r.path);
        results.deinit(allocator);
    }

    // Search
    try findInDirectory(allocator, sandbox, canonical_path, args, &results, 0);

    // Format output
    return formatOutput(allocator, results.items);
}

fn findInDirectory(
    allocator: std.mem.Allocator,
    sandbox: *security.Sandbox,
    dir_path: []const u8,
    args: FindArgs,
    results: *std.ArrayListUnmanaged(FindResult),
    depth: u32,
) !void {
    if (depth > args.max_depth) return;
    if (results.items.len >= args.max_results) return;

    const dir_z = try allocator.allocSentinel(u8, dir_path.len, 0);
    defer allocator.free(dir_z);
    @memcpy(dir_z, dir_path);

    const dir = std.c.opendir(dir_z.ptr) orelse return;
    defer _ = std.c.closedir(dir);

    while (std.c.readdir(dir)) |entry| {
        if (results.items.len >= args.max_results) break;

        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, name });
        errdefer allocator.free(full_path);

        // Validate path is still in sandbox
        if (sandbox.validatePath(full_path)) |validated| {
            allocator.free(validated);
        } else |_| {
            allocator.free(full_path);
            continue;
        }

        // Get file info
        const info = getFileInfo(allocator, full_path) catch {
            allocator.free(full_path);
            continue;
        };

        // Check if matches criteria
        const matches = checkCriteria(name, info, args);

        if (matches) {
            try results.append(allocator, .{
                .path = full_path,
                .file_type = info.file_type,
                .size = info.size,
            });
        } else {
            allocator.free(full_path);
        }

        // Recurse into directories
        if (info.file_type == .directory) {
            const recurse_path = try allocator.dupe(u8, if (matches) results.items[results.items.len - 1].path else full_path);
            defer if (!matches) allocator.free(recurse_path);

            try findInDirectory(allocator, sandbox, recurse_path, args, results, depth + 1);
        }
    }
}

const FileInfo = struct {
    file_type: FindArgs.FileType,
    size: usize,
};

fn getFileInfo(allocator: std.mem.Allocator, path: []const u8) !FileInfo {
    const path_z = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, path);

    // Check if it's a directory
    const dir = std.c.opendir(path_z.ptr);
    if (dir != null) {
        _ = std.c.closedir(dir.?);
        return FileInfo{ .file_type = .directory, .size = 0 };
    }

    // Check if it's a symlink by checking if readlink works
    // (We can't easily distinguish symlinks without lstat in Zig 0.16)
    // For now, treat everything that's not a directory as a file

    // Get file size by reading (no fseek/ftell in Zig 0.16)
    const file = std.c.fopen(path_z.ptr, "rb") orelse {
        // Might be a symlink to nonexistent target or permission denied
        return FileInfo{ .file_type = .symlink, .size = 0 };
    };
    defer _ = std.c.fclose(file);

    // Count bytes by reading
    var size: usize = 0;
    var buf: [8192]u8 = undefined;
    while (true) {
        const read_count = std.c.fread(&buf, 1, buf.len, file);
        size += read_count;
        if (read_count < buf.len) break;
        if (size > 100 * 1024 * 1024) break; // 100MB cap for size check
    }

    return FileInfo{ .file_type = .file, .size = size };
}

fn checkCriteria(name: []const u8, info: FileInfo, args: FindArgs) bool {
    // Check file type
    if (args.file_type) |ft| {
        if (info.file_type != ft) return false;
    }

    // Check name pattern
    if (args.name) |pattern| {
        if (!matchGlob(name, pattern)) return false;
    }

    // Check size (only for files)
    if (info.file_type == .file) {
        if (args.min_size) |min| {
            if (info.size < min) return false;
        }
        if (args.max_size) |max| {
            if (info.size > max) return false;
        }
    }

    return true;
}

fn matchGlob(name: []const u8, pattern: []const u8) bool {
    var n_idx: usize = 0;
    var p_idx: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (n_idx < name.len) {
        if (p_idx < pattern.len and (pattern[p_idx] == name[n_idx] or pattern[p_idx] == '?')) {
            n_idx += 1;
            p_idx += 1;
        } else if (p_idx < pattern.len and pattern[p_idx] == '*') {
            star_idx = p_idx;
            match_idx = n_idx;
            p_idx += 1;
        } else if (star_idx != null) {
            p_idx = star_idx.? + 1;
            match_idx += 1;
            n_idx = match_idx;
        } else {
            return false;
        }
    }

    while (p_idx < pattern.len and pattern[p_idx] == '*') {
        p_idx += 1;
    }

    return p_idx == pattern.len;
}

fn formatOutput(allocator: std.mem.Allocator, results: []const FindResult) !types.ToolOutput {
    if (results.len == 0) {
        return types.ToolOutput{
            .success = true,
            .content = try allocator.dupe(u8, "No matches found"),
            .allocator = allocator,
        };
    }

    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);

    for (results) |r| {
        try output.appendSlice(allocator, r.path);
        try output.append(allocator, '\n');
    }

    return types.ToolOutput{
        .success = true,
        .content = try output.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Parse arguments from JSON
pub fn parseArgs(allocator: std.mem.Allocator, json_str: []const u8) !FindArgs {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.InvalidArguments;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    var args = FindArgs{
        .path = if (obj.get("path")) |p| try allocator.dupe(u8, p.string) else try allocator.dupe(u8, "."),
        .name = if (obj.get("name")) |n| try allocator.dupe(u8, n.string) else null,
        .file_type = null,
        .max_depth = if (obj.get("max_depth")) |d| @intCast(d.integer) else 10,
        .min_size = null,
        .max_size = null,
        .max_results = if (obj.get("max_results")) |m| @intCast(m.integer) else 500,
    };

    // Parse type
    if (obj.get("type")) |t| {
        const type_str = t.string;
        if (std.mem.eql(u8, type_str, "f")) {
            args.file_type = .file;
        } else if (std.mem.eql(u8, type_str, "d")) {
            args.file_type = .directory;
        } else if (std.mem.eql(u8, type_str, "l")) {
            args.file_type = .symlink;
        }
    }

    // Parse sizes
    if (obj.get("min_size")) |s| {
        args.min_size = @intCast(s.integer);
    }
    if (obj.get("max_size")) |s| {
        args.max_size = @intCast(s.integer);
    }

    return args;
}

/// Free allocated args
pub fn freeArgs(allocator: std.mem.Allocator, args: FindArgs) void {
    allocator.free(args.path);
    if (args.name) |n| allocator.free(n);
}
