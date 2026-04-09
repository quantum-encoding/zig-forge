//! Claude Code session export extractor.
//!
//! Walks ~/.claude/projects/<project-slug>/ directories, reads each
//! <session-uuid>.jsonl as the main conversation, inlines any sidecar
//! subagents (subagents/agent-<id>.jsonl) under their parent Agent tool
//! call, and resolves spilled tool results (tool-results/<id>.txt) back
//! into the conversation flow.
//!
//! Output: one markdown file per session, in the same format as the
//! Anthropic export extractor, so the existing chunker pipeline works
//! unchanged.
//!
//! Usage: zig-docx --claude-code ~/.claude/projects/ -o sessions/

const std = @import("std");

pub const ExportStats = struct {
    projects: u32,
    sessions: u32,
    messages: u32,
    tool_calls: u32,
    subagents: u32,
    spilled_results: u32,
    total_bytes: usize,
};

pub const ExtractOptions = struct {
    /// Project slug filter (basename of project directory). If null, all projects.
    only_project: ?[]const u8 = null,
    /// Skip sessions smaller than this many bytes (often empty test sessions).
    min_session_bytes: usize = 512,
};

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*std.c.FILE;
extern "c" fn fclose(stream: *std.c.FILE) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *std.c.FILE) usize;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

const cdir = @cImport({
    @cInclude("dirent.h");
    @cInclude("sys/stat.h");
});

/// Extract all Claude Code sessions from projects_dir into output_dir.
/// projects_dir should be ~/.claude/projects or a single project subdirectory.
pub fn extractAll(
    allocator: std.mem.Allocator,
    projects_dir: []const u8,
    output_dir: []const u8,
    options: ExtractOptions,
    write_fn: *const fn (std.mem.Allocator, []const u8, []const u8) void,
    mkdir_fn: *const fn (std.mem.Allocator, []const u8) void,
) !ExportStats {
    var stats = ExportStats{
        .projects = 0,
        .sessions = 0,
        .messages = 0,
        .tool_calls = 0,
        .subagents = 0,
        .spilled_results = 0,
        .total_bytes = 0,
    };

    mkdir_fn(allocator, output_dir);

    // Detect whether projects_dir is a single project or a container of projects.
    // A project directory contains <session-uuid>.jsonl files directly.
    // A container directory contains project subdirectories.
    const is_single_project = containsJsonlFiles(allocator, projects_dir);

    if (is_single_project) {
        try extractProject(allocator, projects_dir, output_dir, options, &stats, write_fn, mkdir_fn);
        return stats;
    }

    // Iterate project subdirectories
    const dir_z = try allocator.allocSentinel(u8, projects_dir.len, 0);
    defer allocator.free(dir_z);
    @memcpy(dir_z, projects_dir);

    const dir = cdir.opendir(dir_z.ptr) orelse {
        std.debug.print("Error: cannot open directory '{s}'\n", .{projects_dir});
        return stats;
    };
    defer _ = cdir.closedir(dir);

    while (cdir.readdir(dir)) |entry| {
        const d_name: [*]const u8 = @ptrCast(&entry.*.d_name);
        const name_len = std.mem.indexOfScalar(u8, d_name[0..256], 0) orelse 256;
        const name = d_name[0..name_len];

        if (name.len == 0 or name[0] == '.') continue;

        // Only directories
        if (entry.*.d_type != cdir.DT_DIR and entry.*.d_type != cdir.DT_UNKNOWN) continue;

        if (options.only_project) |filter| {
            if (!std.mem.eql(u8, name, filter)) continue;
        }

        const project_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ projects_dir, name }) catch continue;
        defer allocator.free(project_path);

        extractProject(allocator, project_path, output_dir, options, &stats, write_fn, mkdir_fn) catch |err| {
            std.debug.print("  ⚠ Project {s} failed: {}\n", .{ name, err });
            continue;
        };
    }

    return stats;
}

/// Extract all sessions from a single project directory.
fn extractProject(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    output_dir: []const u8,
    options: ExtractOptions,
    stats: *ExportStats,
    write_fn: *const fn (std.mem.Allocator, []const u8, []const u8) void,
    mkdir_fn: *const fn (std.mem.Allocator, []const u8) void,
) !void {
    const project_slug = std.fs.path.basename(project_dir);
    stats.projects += 1;
    std.debug.print("Project: {s}\n", .{project_slug});

    const dir_z = try allocator.allocSentinel(u8, project_dir.len, 0);
    defer allocator.free(dir_z);
    @memcpy(dir_z, project_dir);

    const dir = cdir.opendir(dir_z.ptr) orelse {
        std.debug.print("  Cannot open {s}\n", .{project_dir});
        return error.DirOpenFailed;
    };
    defer _ = cdir.closedir(dir);

    while (cdir.readdir(dir)) |entry| {
        const d_name: [*]const u8 = @ptrCast(&entry.*.d_name);
        const name_len = std.mem.indexOfScalar(u8, d_name[0..256], 0) orelse 256;
        const name = d_name[0..name_len];

        if (!std.mem.endsWith(u8, name, ".jsonl")) continue;

        // Build full path
        const session_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, name }) catch continue;
        defer allocator.free(session_path);

        // Session UUID = filename without .jsonl extension
        const session_uuid = name[0 .. name.len - 6];

        // Side resource directory for this session
        const session_resources = std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, session_uuid }) catch continue;
        defer allocator.free(session_resources);

        extractSession(
            allocator,
            session_path,
            session_uuid,
            session_resources,
            project_slug,
            output_dir,
            options,
            stats,
            write_fn,
        ) catch |err| {
            std.debug.print("  ⚠ Session {s} failed: {}\n", .{ session_uuid, err });
            continue;
        };
    }

    _ = mkdir_fn;
}

/// Extract a single session jsonl into a markdown file.
fn extractSession(
    allocator: std.mem.Allocator,
    session_path: []const u8,
    session_uuid: []const u8,
    session_resources_dir: []const u8,
    project_slug: []const u8,
    output_dir: []const u8,
    options: ExtractOptions,
    stats: *ExportStats,
    write_fn: *const fn (std.mem.Allocator, []const u8, []const u8) void,
) !void {
    const jsonl_data = readFile(allocator, session_path) catch return;
    defer allocator.free(jsonl_data);

    if (jsonl_data.len < options.min_session_bytes) return;
    stats.total_bytes += jsonl_data.len;

    // Load subagent files into a map keyed by agentId
    var subagents = std.StringHashMap([]const u8).init(allocator);
    defer {
        var kit = subagents.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        var vit = subagents.valueIterator();
        while (vit.next()) |v| allocator.free(v.*);
        subagents.deinit();
    }
    loadSubagents(allocator, session_resources_dir, &subagents) catch {};

    // Build the markdown output
    var md: std.ArrayListUnmanaged(u8) = .empty;
    defer md.deinit(allocator);

    // Parse session metadata from first line
    var first_timestamp: []const u8 = "";
    var first_cwd: []const u8 = "";
    var first_git_branch: []const u8 = "";
    var first_slug: []const u8 = "";
    var msg_count: u32 = 0;

    // First pass: collect metadata
    {
        var line_it = std.mem.splitScalar(u8, jsonl_data, '\n');
        var parsed_first = false;
        while (line_it.next()) |line| {
            if (line.len == 0) continue;
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
                .max_value_len = std.json.default_max_value_len,
                .allocate = .alloc_always,
            }) catch continue;
            defer parsed.deinit();

            if (!parsed_first) {
                if (getStr(parsed.value, "timestamp")) |t| first_timestamp = try allocator.dupe(u8, t);
                if (getStr(parsed.value, "cwd")) |c| first_cwd = try allocator.dupe(u8, c);
                if (getStr(parsed.value, "gitBranch")) |b| first_git_branch = try allocator.dupe(u8, b);
                if (getStr(parsed.value, "slug")) |s| first_slug = try allocator.dupe(u8, s);
                parsed_first = true;
            }
            msg_count += 1;
        }
    }
    defer if (first_timestamp.len > 0) allocator.free(first_timestamp);
    defer if (first_cwd.len > 0) allocator.free(first_cwd);
    defer if (first_git_branch.len > 0) allocator.free(first_git_branch);
    defer if (first_slug.len > 0) allocator.free(first_slug);

    // Generate header
    const uuid_short = if (session_uuid.len >= 8) session_uuid[0..8] else session_uuid;
    const date_prefix = if (first_timestamp.len >= 10) first_timestamp[0..10] else "undated";
    const session_title = if (first_slug.len > 0) first_slug else session_uuid;

    const header = try std.fmt.allocPrint(allocator,
        \\# Session: {s}
        \\
        \\**Session ID:** `{s}`
        \\**Project:** `{s}`
        \\**Started:** {s}
        \\**Working Dir:** `{s}`
        \\**Git Branch:** `{s}`
        \\**Subagents:** {d}
        \\
        \\---
        \\
        \\
    , .{
        session_title,
        session_uuid,
        project_slug,
        first_timestamp,
        first_cwd,
        first_git_branch,
        subagents.count(),
    });
    defer allocator.free(header);
    try md.appendSlice(allocator, header);

    // Second pass: render messages + tool calls + inline subagents
    var line_it = std.mem.splitScalar(u8, jsonl_data, '\n');
    while (line_it.next()) |line| {
        if (line.len == 0) continue;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
            .max_value_len = std.json.default_max_value_len,
            .allocate = .alloc_always,
        }) catch continue;
        defer parsed.deinit();

        const entry_type = getStr(parsed.value, "type") orelse continue;
        const timestamp = getStr(parsed.value, "timestamp") orelse "";
        const message = parsed.value.object.get("message") orelse continue;
        if (message != .object) continue;

        const role = getStr(message, "role") orelse "";

        // Role header
        const role_display = if (std.mem.eql(u8, role, "user")) "**You**"
            else if (std.mem.eql(u8, role, "assistant")) "**Claude**"
            else "**System**";

        const msg_header = try std.fmt.allocPrint(allocator, "## {s}\n\n*{s}*\n\n", .{ role_display, timestamp });
        defer allocator.free(msg_header);
        try md.appendSlice(allocator, msg_header);

        // Handle content (may be string or array)
        const content = message.object.get("content") orelse continue;
        try renderContent(allocator, &md, content, session_resources_dir, &subagents, stats);

        try md.appendSlice(allocator, "\n---\n\n");
        _ = entry_type;
    }

    stats.messages += msg_count;
    stats.sessions += 1;

    // Generate filename: YYYY-MM-DD_slug_UUID8.md
    const safe_title = sanitizeName(allocator, session_title) catch "untitled";
    defer allocator.free(safe_title);

    const filename = try std.fmt.allocPrint(allocator,
        "{s}/{s}_{s}_{s}.md",
        .{ output_dir, date_prefix, safe_title, uuid_short },
    );
    defer allocator.free(filename);

    write_fn(allocator, filename, md.items);

    std.debug.print("  [{d} msgs, {d} subagents] {s}\n", .{ msg_count, subagents.count(), session_title });
}

/// Render the content field of a message entry (text + tool calls).
fn renderContent(
    allocator: std.mem.Allocator,
    md: *std.ArrayListUnmanaged(u8),
    content: std.json.Value,
    session_resources_dir: []const u8,
    subagents: *std.StringHashMap([]const u8),
    stats: *ExportStats,
) !void {
    // Content can be a string (legacy) or an array of content blocks
    if (content == .string) {
        try md.appendSlice(allocator, content.string);
        try md.appendSlice(allocator, "\n\n");
        return;
    }

    if (content != .array) return;

    for (content.array.items) |item| {
        if (item != .object) continue;
        const item_type = getStr(item, "type") orelse continue;

        if (std.mem.eql(u8, item_type, "text")) {
            if (getStr(item, "text")) |text| {
                try md.appendSlice(allocator, text);
                try md.appendSlice(allocator, "\n\n");
            }
        } else if (std.mem.eql(u8, item_type, "tool_use")) {
            const tool_name = getStr(item, "name") orelse "Unknown";
            const tool_header = try std.fmt.allocPrint(allocator, "### Tool: `{s}`\n\n", .{tool_name});
            defer allocator.free(tool_header);
            try md.appendSlice(allocator, tool_header);

            // Render key string fields from tool input (most tool calls have
            // simple string arguments we want visible for search)
            if (item.object.get("input")) |inp| {
                if (inp == .object) {
                    try md.appendSlice(allocator, "```\n");
                    var key_it = inp.object.iterator();
                    var rendered: usize = 0;
                    while (key_it.next()) |kv| {
                        if (rendered > 8) break; // cap fields per tool call
                        try md.appendSlice(allocator, kv.key_ptr.*);
                        try md.appendSlice(allocator, ": ");
                        const v_text = stringifyValue(allocator, kv.value_ptr.*, 256) catch continue;
                        defer allocator.free(v_text);
                        try md.appendSlice(allocator, v_text);
                        try md.appendSlice(allocator, "\n");
                        rendered += 1;
                    }
                    try md.appendSlice(allocator, "```\n\n");
                }
            }

            stats.tool_calls += 1;
        } else if (std.mem.eql(u8, item_type, "tool_result")) {
            const result_content = item.object.get("content") orelse continue;
            try md.appendSlice(allocator, "**Result:**\n\n");
            try renderToolResult(allocator, md, result_content, session_resources_dir, stats);
        }
    }

    // Check if any text contains an agentId reference (subagent launch)
    for (content.array.items) |item| {
        if (item != .object) continue;
        if (getStr(item, "type")) |t| {
            if (!std.mem.eql(u8, t, "tool_result")) continue;
        }
        const c = item.object.get("content") orelse continue;
        const text = extractTextFromToolResult(c) orelse continue;
        if (std.mem.indexOf(u8, text, "agentId: ") == null) continue;

        // Extract agentId
        const id_start = std.mem.indexOf(u8, text, "agentId: ").? + "agentId: ".len;
        var id_end = id_start;
        while (id_end < text.len and (std.ascii.isAlphanumeric(text[id_end]))) : (id_end += 1) {}
        if (id_end == id_start) continue;

        const agent_id = text[id_start..id_end];
        const subagent_content = subagents.get(agent_id) orelse continue;

        try md.appendSlice(allocator, "\n<details>\n<summary>Subagent conversation</summary>\n\n");
        try md.appendSlice(allocator, subagent_content);
        try md.appendSlice(allocator, "\n</details>\n\n");
        stats.subagents += 1;
    }
}

/// Render a tool result, resolving any spilled file references.
fn renderToolResult(
    allocator: std.mem.Allocator,
    md: *std.ArrayListUnmanaged(u8),
    content: std.json.Value,
    session_resources_dir: []const u8,
    stats: *ExportStats,
) !void {
    const text = extractTextFromToolResult(content) orelse return;

    // Detect spilled output: "<persisted-output>...Full output saved to: <path>..."
    if (std.mem.indexOf(u8, text, "Full output saved to: ")) |path_start_idx| {
        const path_start = path_start_idx + "Full output saved to: ".len;
        var path_end = path_start;
        while (path_end < text.len and text[path_end] != '\n') : (path_end += 1) {}
        const spill_path = text[path_start..path_end];

        // Try to read the full spilled file
        const spill_content = readFile(allocator, spill_path) catch {
            // Fall back to the preview that's already in the jsonl
            try md.appendSlice(allocator, "```\n");
            try md.appendSlice(allocator, text);
            try md.appendSlice(allocator, "\n```\n\n");
            return;
        };
        defer allocator.free(spill_content);

        try md.appendSlice(allocator, "<!-- spilled tool result -->\n\n```\n");
        // Cap inlined spill content at 16KB to keep output manageable
        const inline_cap = 16 * 1024;
        if (spill_content.len > inline_cap) {
            try md.appendSlice(allocator, spill_content[0..inline_cap]);
            const suffix = try std.fmt.allocPrint(allocator,
                "\n... ({d} bytes truncated from {d} total)",
                .{ spill_content.len - inline_cap, spill_content.len },
            );
            defer allocator.free(suffix);
            try md.appendSlice(allocator, suffix);
        } else {
            try md.appendSlice(allocator, spill_content);
        }
        try md.appendSlice(allocator, "\n```\n\n");
        stats.spilled_results += 1;
        _ = session_resources_dir;
        return;
    }

    // Regular inline tool result
    try md.appendSlice(allocator, "```\n");
    const cap = 4096;
    if (text.len > cap) {
        try md.appendSlice(allocator, text[0..cap]);
        const suffix = try std.fmt.allocPrint(allocator, "\n... ({d} bytes truncated)", .{text.len - cap});
        defer allocator.free(suffix);
        try md.appendSlice(allocator, suffix);
    } else {
        try md.appendSlice(allocator, text);
    }
    try md.appendSlice(allocator, "\n```\n\n");
}

/// Extract text from a tool_result content field, which can be a string or an array.
fn extractTextFromToolResult(content: std.json.Value) ?[]const u8 {
    if (content == .string) return content.string;
    if (content == .array) {
        for (content.array.items) |item| {
            if (item != .object) continue;
            if (getStr(item, "type")) |t| {
                if (std.mem.eql(u8, t, "text")) {
                    return getStr(item, "text");
                }
            }
        }
    }
    return null;
}

/// Load all subagent jsonl files in <session_dir>/subagents/ into a map.
/// Each entry is a condensed markdown rendering of the subagent conversation.
fn loadSubagents(
    allocator: std.mem.Allocator,
    session_resources_dir: []const u8,
    map: *std.StringHashMap([]const u8),
) !void {
    const subagents_dir = try std.fmt.allocPrint(allocator, "{s}/subagents", .{session_resources_dir});
    defer allocator.free(subagents_dir);

    const dir_z = try allocator.allocSentinel(u8, subagents_dir.len, 0);
    defer allocator.free(dir_z);
    @memcpy(dir_z, subagents_dir);

    const dir = cdir.opendir(dir_z.ptr) orelse return;
    defer _ = cdir.closedir(dir);

    while (cdir.readdir(dir)) |entry| {
        const d_name: [*]const u8 = @ptrCast(&entry.*.d_name);
        const name_len = std.mem.indexOfScalar(u8, d_name[0..256], 0) orelse 256;
        const name = d_name[0..name_len];

        if (!std.mem.endsWith(u8, name, ".jsonl")) continue;
        if (!std.mem.startsWith(u8, name, "agent-")) continue;

        // Extract agentId from filename: agent-<id>.jsonl
        const id_start: usize = "agent-".len;
        const id_end = name.len - ".jsonl".len;
        if (id_end <= id_start) continue;
        const agent_id = name[id_start..id_end];

        // Read the subagent jsonl
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ subagents_dir, name });
        defer allocator.free(full_path);

        const data = readFile(allocator, full_path) catch continue;
        defer allocator.free(data);

        // Render as condensed markdown
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);

        var line_it = std.mem.splitScalar(u8, data, '\n');
        while (line_it.next()) |line| {
            if (line.len == 0) continue;
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
                .max_value_len = std.json.default_max_value_len,
                .allocate = .alloc_always,
            }) catch continue;
            defer parsed.deinit();

            const msg = parsed.value.object.get("message") orelse continue;
            if (msg != .object) continue;
            const role = getStr(msg, "role") orelse "";
            const role_label = if (std.mem.eql(u8, role, "user")) "**Prompt:**" else "**Subagent:**";
            try buf.appendSlice(allocator, role_label);
            try buf.appendSlice(allocator, "\n");

            const c = msg.object.get("content") orelse continue;
            if (c == .string) {
                try buf.appendSlice(allocator, c.string);
                try buf.appendSlice(allocator, "\n\n");
            } else if (c == .array) {
                for (c.array.items) |block| {
                    if (block != .object) continue;
                    const btype = getStr(block, "type") orelse continue;
                    if (std.mem.eql(u8, btype, "text")) {
                        if (getStr(block, "text")) |t| {
                            try buf.appendSlice(allocator, t);
                            try buf.appendSlice(allocator, "\n\n");
                        }
                    } else if (std.mem.eql(u8, btype, "tool_use")) {
                        const tname = getStr(block, "name") orelse "?";
                        const line2 = try std.fmt.allocPrint(allocator, "_[Tool: {s}]_\n\n", .{tname});
                        defer allocator.free(line2);
                        try buf.appendSlice(allocator, line2);
                    }
                }
            }
        }

        const id_dup = try allocator.dupe(u8, agent_id);
        const content_dup = try buf.toOwnedSlice(allocator);
        try map.put(id_dup, content_dup);
    }
}

/// Check if a directory contains .jsonl files directly (single project).
fn containsJsonlFiles(allocator: std.mem.Allocator, path: []const u8) bool {
    const path_z = allocator.allocSentinel(u8, path.len, 0) catch return false;
    defer allocator.free(path_z);
    @memcpy(path_z, path);

    const dir = cdir.opendir(path_z.ptr) orelse return false;
    defer _ = cdir.closedir(dir);

    while (cdir.readdir(dir)) |entry| {
        const d_name: [*]const u8 = @ptrCast(&entry.*.d_name);
        const name_len = std.mem.indexOfScalar(u8, d_name[0..256], 0) orelse 256;
        const name = d_name[0..name_len];
        if (std.mem.endsWith(u8, name, ".jsonl")) return true;
    }
    return false;
}

// ─── Helpers ────────────────────────────────────────────────────────

fn getStr(obj: std.json.Value, key: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    if (val != .string) return null;
    return val.string;
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.allocSentinel(u8, path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z, path);

    const fp = fopen(path_z.ptr, "rb") orelse return error.FileOpenFailed;
    defer _ = fclose(fp);

    _ = fseek(fp, 0, 2);
    const size = ftell(fp);
    if (size <= 0) return error.EmptyFile;
    _ = fseek(fp, 0, 0);

    const buf = try allocator.alloc(u8, @intCast(size));
    const n = fread(buf.ptr, 1, @intCast(size), fp);
    if (n != @as(usize, @intCast(size))) {
        allocator.free(buf);
        return error.ReadFailed;
    }
    return buf;
}

/// Simple JSON value renderer. Returns a heap-allocated string up to max_len chars.
fn stringifyValue(allocator: std.mem.Allocator, val: std.json.Value, max_len: usize) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    switch (val) {
        .string => |s| {
            const limit = @min(s.len, max_len);
            try buf.appendSlice(allocator, s[0..limit]);
            if (s.len > max_len) try buf.appendSlice(allocator, "...");
        },
        .integer => |n| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{n});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .float => |f| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{f});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        },
        .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .null => try buf.appendSlice(allocator, "null"),
        .array => |a| {
            try buf.appendSlice(allocator, "[");
            const s = try std.fmt.allocPrint(allocator, "{d} items", .{a.items.len});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
            try buf.appendSlice(allocator, "]");
        },
        .object => try buf.appendSlice(allocator, "{...}"),
        else => try buf.appendSlice(allocator, "?"),
    }

    return buf.toOwnedSlice(allocator);
}

fn sanitizeName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    var count: usize = 0;
    for (name) |c| {
        if (count >= 60) break;
        if ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '-') {
            try buf.append(allocator, c);
            count += 1;
        } else if (c >= 'A' and c <= 'Z') {
            try buf.append(allocator, c + 32);
            count += 1;
        } else if (c == ' ' or c == '/' or c == '.' or c == ':') {
            try buf.append(allocator, '_');
            count += 1;
        }
    }

    if (buf.items.len == 0) {
        try buf.appendSlice(allocator, "untitled");
    }

    return buf.toOwnedSlice(allocator);
}
