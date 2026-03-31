// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! wc tool implementation
//! In-process line/word/byte counting without spawning external processes

const std = @import("std");
const types = @import("types.zig");
const security = @import("../security/mod.zig");

pub const WcArgs = struct {
    paths: []const []const u8,
    lines: bool = true,
    words: bool = true,
    bytes: bool = true,
    chars: bool = false,
};

const Counts = struct {
    lines: usize = 0,
    words: usize = 0,
    bytes: usize = 0,
    chars: usize = 0,
};

/// Execute wc tool - in-process counting
pub fn execute(
    allocator: std.mem.Allocator,
    sandbox: *security.Sandbox,
    args: WcArgs,
    max_file_size: usize,
) !types.ToolOutput {
    if (args.paths.len == 0) {
        return types.ToolOutput.error_result(allocator, "No files specified");
    }

    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);

    var totals = Counts{};
    var file_count: usize = 0;

    for (args.paths) |path| {
        // Validate path is within sandbox
        const canonical_path = sandbox.validatePath(path) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "wc: {s}: {s}\n", .{
                path,
                switch (err) {
                    security.SandboxError.PathOutsideSandbox => "Path is outside the sandbox",
                    else => "Invalid path",
                },
            });
            defer allocator.free(msg);
            try output.appendSlice(allocator, msg);
            continue;
        };
        defer allocator.free(canonical_path);

        // Count file
        const counts = countFile(allocator, canonical_path, max_file_size) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "wc: {s}: {s}\n", .{
                path,
                switch (err) {
                    error.FileNotFound => "No such file or directory",
                    error.IsDirectory => "Is a directory",
                    error.FileTooLarge => "File too large",
                    else => "Read error",
                },
            });
            defer allocator.free(msg);
            try output.appendSlice(allocator, msg);
            continue;
        };

        // Accumulate totals
        totals.lines += counts.lines;
        totals.words += counts.words;
        totals.bytes += counts.bytes;
        totals.chars += counts.chars;
        file_count += 1;

        // Format line
        const line = try formatCounts(allocator, counts, args, path);
        defer allocator.free(line);
        try output.appendSlice(allocator, line);
        try output.append(allocator, '\n');
    }

    // Print totals if multiple files
    if (file_count > 1) {
        const total_line = try formatCounts(allocator, totals, args, "total");
        defer allocator.free(total_line);
        try output.appendSlice(allocator, total_line);
        try output.append(allocator, '\n');
    }

    if (output.items.len == 0) {
        return types.ToolOutput.error_result(allocator, "No files could be counted");
    }

    return types.ToolOutput{
        .success = true,
        .content = try output.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn countFile(allocator: std.mem.Allocator, path: []const u8, max_size: usize) !Counts {
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

    var counts = Counts{};
    var in_word = false;
    var total_read: usize = 0;

    var buf: [8192]u8 = undefined;
    while (true) {
        const read_count = std.c.fread(&buf, 1, buf.len, file);
        if (read_count == 0) break;

        total_read += read_count;
        if (total_read > max_size) return error.FileTooLarge;

        counts.bytes += read_count;

        for (buf[0..read_count]) |c| {
            // Count lines
            if (c == '\n') {
                counts.lines += 1;
            }

            // Count words (whitespace-separated)
            const is_space = (c == ' ' or c == '\t' or c == '\n' or c == '\r' or
                c == '\x0b' or c == '\x0c');
            if (is_space) {
                in_word = false;
            } else if (!in_word) {
                in_word = true;
                counts.words += 1;
            }

            // Count UTF-8 characters (not continuation bytes)
            if ((c & 0xC0) != 0x80) {
                counts.chars += 1;
            }
        }
    }

    return counts;
}

fn formatCounts(allocator: std.mem.Allocator, counts: Counts, args: WcArgs, name: []const u8) ![]u8 {
    var parts: std.ArrayListUnmanaged(u8) = .empty;
    errdefer parts.deinit(allocator);

    if (args.lines) {
        const s = try std.fmt.allocPrint(allocator, "{d:>7} ", .{counts.lines});
        defer allocator.free(s);
        try parts.appendSlice(allocator, s);
    }
    if (args.words) {
        const s = try std.fmt.allocPrint(allocator, "{d:>7} ", .{counts.words});
        defer allocator.free(s);
        try parts.appendSlice(allocator, s);
    }
    if (args.chars) {
        const s = try std.fmt.allocPrint(allocator, "{d:>7} ", .{counts.chars});
        defer allocator.free(s);
        try parts.appendSlice(allocator, s);
    }
    if (args.bytes) {
        const s = try std.fmt.allocPrint(allocator, "{d:>7} ", .{counts.bytes});
        defer allocator.free(s);
        try parts.appendSlice(allocator, s);
    }

    try parts.appendSlice(allocator, name);

    return parts.toOwnedSlice(allocator);
}

/// Parse arguments from JSON
pub fn parseArgs(allocator: std.mem.Allocator, json_str: []const u8) !WcArgs {
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

    // If any specific flag is set, use those; otherwise default to all
    const has_specific = obj.get("lines") != null or obj.get("words") != null or
        obj.get("bytes") != null or obj.get("chars") != null;

    return WcArgs{
        .paths = paths,
        .lines = if (obj.get("lines")) |l| l.bool else !has_specific,
        .words = if (obj.get("words")) |w| w.bool else !has_specific,
        .bytes = if (obj.get("bytes")) |b| b.bool else !has_specific,
        .chars = if (obj.get("chars")) |c| c.bool else false,
    };
}

/// Free allocated args
pub fn freeArgs(allocator: std.mem.Allocator, args: WcArgs) void {
    for (args.paths) |p| {
        allocator.free(p);
    }
    allocator.free(args.paths);
}
