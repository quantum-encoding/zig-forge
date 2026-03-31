// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! grep tool implementation
//! In-process pattern matching without spawning external processes

const std = @import("std");
const types = @import("types.zig");
const security = @import("../security/mod.zig");

pub const GrepArgs = struct {
    pattern: []const u8,
    path: []const u8 = ".",
    recursive: bool = true,
    ignore_case: bool = false,
    invert_match: bool = false,
    context_lines: u32 = 0,
    max_matches: u32 = 100,
    include_pattern: ?[]const u8 = null,
};

const Match = struct {
    file: []const u8,
    line_num: usize,
    content: []const u8,
    is_context: bool = false,
};

/// Execute grep tool - in-process pattern matching
pub fn execute(
    allocator: std.mem.Allocator,
    sandbox: *security.Sandbox,
    args: GrepArgs,
) !types.ToolOutput {
    // Validate path is within sandbox
    const canonical_path = sandbox.validatePath(args.path) catch |err| {
        return types.ToolOutput.error_result(allocator, switch (err) {
            security.SandboxError.PathOutsideSandbox => "Path is outside the sandbox",
            else => "Invalid path",
        });
    };
    defer allocator.free(canonical_path);

    var matches: std.ArrayListUnmanaged(Match) = .empty;
    defer {
        for (matches.items) |m| {
            allocator.free(m.file);
            allocator.free(m.content);
        }
        matches.deinit(allocator);
    }

    // Check if path is file or directory
    const path_z = try allocator.allocSentinel(u8, canonical_path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, canonical_path);

    const dir = std.c.opendir(path_z.ptr);
    if (dir != null) {
        _ = std.c.closedir(dir.?);
        // It's a directory - search recursively
        try searchDirectory(allocator, sandbox, canonical_path, args, &matches, 0);
    } else {
        // It's a file - search directly
        try searchFile(allocator, canonical_path, args, &matches);
    }

    // Format output
    return formatOutput(allocator, matches.items, args.max_matches);
}

fn searchDirectory(
    allocator: std.mem.Allocator,
    sandbox: *security.Sandbox,
    dir_path: []const u8,
    args: GrepArgs,
    matches: *std.ArrayListUnmanaged(Match),
    depth: u32,
) !void {
    if (depth > 20) return; // Prevent infinite recursion
    if (matches.items.len >= args.max_matches) return;

    const dir_z = try allocator.allocSentinel(u8, dir_path.len, 0);
    defer allocator.free(dir_z);
    @memcpy(dir_z, dir_path);

    const dir = std.c.opendir(dir_z.ptr) orelse return;
    defer _ = std.c.closedir(dir);

    while (std.c.readdir(dir)) |entry| {
        if (matches.items.len >= args.max_matches) break;

        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (name.len > 0 and name[0] == '.') continue; // Skip hidden files

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, name });
        defer allocator.free(full_path);

        // Validate path is still in sandbox
        if (sandbox.validatePath(full_path)) |validated| {
            allocator.free(validated);
        } else |_| continue;

        const is_dir = blk: {
            const fp_z = try allocator.allocSentinel(u8, full_path.len, 0);
            defer allocator.free(fp_z);
            @memcpy(fp_z, full_path);
            const d = std.c.opendir(fp_z.ptr);
            if (d != null) {
                _ = std.c.closedir(d.?);
                break :blk true;
            }
            break :blk false;
        };

        if (is_dir) {
            if (args.recursive) {
                try searchDirectory(allocator, sandbox, full_path, args, matches, depth + 1);
            }
        } else {
            // Check include pattern
            if (args.include_pattern) |pattern| {
                if (!matchGlob(name, pattern)) continue;
            }
            try searchFile(allocator, full_path, args, matches);
        }
    }
}

fn searchFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    args: GrepArgs,
    matches: *std.ArrayListUnmanaged(Match),
) !void {
    if (matches.items.len >= args.max_matches) return;

    // Read file content
    const path_z = try allocator.allocSentinel(u8, file_path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, file_path);

    const file = std.c.fopen(path_z.ptr, "rb") orelse return;
    defer _ = std.c.fclose(file);

    // Read file in chunks
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(allocator);

    var buf: [8192]u8 = undefined;
    while (true) {
        const read_count = std.c.fread(&buf, 1, buf.len, file);
        if (read_count > 0) {
            // Check for binary content (null bytes in first chunk)
            if (content.items.len == 0) {
                for (buf[0..read_count]) |b| {
                    if (b == 0) return; // Skip binary files
                }
            }
            try content.appendSlice(allocator, buf[0..read_count]);
            if (content.items.len > 10 * 1024 * 1024) return; // 10MB limit
        }
        if (read_count < buf.len) break;
    }

    if (content.items.len == 0) return;

    // Prepare pattern for matching
    var pattern_lower: ?[]u8 = null;
    defer if (pattern_lower) |p| allocator.free(p);
    if (args.ignore_case) {
        pattern_lower = try allocator.alloc(u8, args.pattern.len);
        for (args.pattern, 0..) |c, i| {
            pattern_lower.?[i] = std.ascii.toLower(c);
        }
    }

    // Split into lines and search
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(allocator);

    var line_start: usize = 0;
    for (content.items, 0..) |c, i| {
        if (c == '\n') {
            try lines.append(allocator, content.items[line_start..i]);
            line_start = i + 1;
        }
    }
    if (line_start < content.items.len) {
        try lines.append(allocator, content.items[line_start..]);
    }

    // Find matches
    for (lines.items, 0..) |line, line_idx| {
        if (matches.items.len >= args.max_matches) break;

        const match_found = if (args.ignore_case)
            containsIgnoreCase(line, pattern_lower.?)
        else
            std.mem.indexOf(u8, line, args.pattern) != null;

        const should_include = if (args.invert_match) !match_found else match_found;

        if (should_include) {
            // Add context lines before
            if (args.context_lines > 0) {
                const start = if (line_idx > args.context_lines) line_idx - args.context_lines else 0;
                for (start..line_idx) |ctx_idx| {
                    if (matches.items.len >= args.max_matches) break;
                    try matches.append(allocator, .{
                        .file = try allocator.dupe(u8, file_path),
                        .line_num = ctx_idx + 1,
                        .content = try allocator.dupe(u8, lines.items[ctx_idx]),
                        .is_context = true,
                    });
                }
            }

            // Add matching line
            try matches.append(allocator, .{
                .file = try allocator.dupe(u8, file_path),
                .line_num = line_idx + 1,
                .content = try allocator.dupe(u8, line),
                .is_context = false,
            });

            // Add context lines after
            if (args.context_lines > 0) {
                const end = @min(line_idx + args.context_lines + 1, lines.items.len);
                for ((line_idx + 1)..end) |ctx_idx| {
                    if (matches.items.len >= args.max_matches) break;
                    try matches.append(allocator, .{
                        .file = try allocator.dupe(u8, file_path),
                        .line_num = ctx_idx + 1,
                        .content = try allocator.dupe(u8, lines.items[ctx_idx]),
                        .is_context = true,
                    });
                }
            }
        }
    }
}

fn containsIgnoreCase(haystack: []const u8, needle_lower: []const u8) bool {
    if (needle_lower.len > haystack.len) return false;
    if (needle_lower.len == 0) return true;

    var i: usize = 0;
    while (i <= haystack.len - needle_lower.len) : (i += 1) {
        var match = true;
        for (needle_lower, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != nc) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
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

fn formatOutput(allocator: std.mem.Allocator, matches: []const Match, max_matches: u32) !types.ToolOutput {
    if (matches.len == 0) {
        return types.ToolOutput{
            .success = true,
            .content = try allocator.dupe(u8, "No matches found"),
            .allocator = allocator,
        };
    }

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    const count = @min(matches.len, max_matches);
    for (matches[0..count]) |m| {
        const prefix = if (m.is_context) "-" else ":";
        const line = try std.fmt.allocPrint(allocator, "{s}{s}{d}{s}{s}\n", .{
            m.file,
            prefix,
            m.line_num,
            prefix,
            m.content,
        });
        defer allocator.free(line);
        try result.appendSlice(allocator, line);
    }

    if (matches.len > max_matches) {
        const truncated = try std.fmt.allocPrint(allocator, "\n... truncated ({d} total matches)\n", .{matches.len});
        defer allocator.free(truncated);
        try result.appendSlice(allocator, truncated);
    }

    return types.ToolOutput{
        .success = true,
        .content = try result.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Parse arguments from JSON
pub fn parseArgs(allocator: std.mem.Allocator, json_str: []const u8) !GrepArgs {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.InvalidArguments;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    const pattern = obj.get("pattern") orelse return error.InvalidArguments;

    return GrepArgs{
        .pattern = try allocator.dupe(u8, pattern.string),
        .path = if (obj.get("path")) |p| try allocator.dupe(u8, p.string) else try allocator.dupe(u8, "."),
        .recursive = if (obj.get("recursive")) |r| r.bool else true,
        .ignore_case = if (obj.get("ignore_case")) |i| i.bool else false,
        .invert_match = if (obj.get("invert_match")) |i| i.bool else false,
        .context_lines = if (obj.get("context_lines")) |c| @intCast(c.integer) else 0,
        .max_matches = if (obj.get("max_matches")) |m| @intCast(m.integer) else 100,
        .include_pattern = if (obj.get("include_pattern")) |p| try allocator.dupe(u8, p.string) else null,
    };
}

/// Free allocated args
pub fn freeArgs(allocator: std.mem.Allocator, args: GrepArgs) void {
    allocator.free(args.pattern);
    allocator.free(args.path);
    if (args.include_pattern) |p| allocator.free(p);
}
