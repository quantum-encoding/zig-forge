//! Anthropic Claude Export Extractor
//!
//! Converts conversations.json from Anthropic's data export into
//! organized markdown files — one per conversation, with timestamps,
//! sender roles, and extracted artifacts.
//!
//! Usage: zig-docx conversations.json --anthropic -o chats/

const std = @import("std");

pub const ExportStats = struct {
    conversations: u32,
    messages: u32,
    artifacts: u32,
    total_bytes: usize,
};

/// Process an Anthropic conversations.json export
/// Writes one markdown file per conversation to output_dir
pub fn extractExport(
    allocator: std.mem.Allocator,
    json_data: []const u8,
    output_dir: []const u8,
    write_fn: *const fn (std.mem.Allocator, []const u8, []const u8) void,
    mkdir_fn: *const fn (std.mem.Allocator, []const u8) void,
) !ExportStats {
    var stats = ExportStats{ .conversations = 0, .messages = 0, .artifacts = 0, .total_bytes = json_data.len };

    // Parse the root array
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_data, .{
        .max_value_len = std.json.default_max_value_len,
    });
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .array) return error.InvalidFormat;

    mkdir_fn(allocator, output_dir);

    for (root.array.items) |conversation| {
        if (conversation != .object) continue;

        const name = getStr(conversation, "name") orelse "Untitled";
        const uuid = getStr(conversation, "uuid") orelse "unknown";
        const created = getStr(conversation, "created_at") orelse "";
        const updated = getStr(conversation, "updated_at") orelse "";

        // Generate filename: YYYY-MM-DD_sanitized_name_UUID8.md
        const date_prefix = if (created.len >= 10) created[0..10] else "undated";
        const safe_name = sanitizeName(allocator, name) catch continue;
        defer allocator.free(safe_name);

        const filename = std.fmt.allocPrint(allocator, "{s}/{s}_{s}_{s}.md", .{
            output_dir, date_prefix, safe_name, if (uuid.len >= 8) uuid[0..8] else uuid,
        }) catch continue;
        defer allocator.free(filename);

        // Build markdown
        var md: std.ArrayList(u8) = .empty;
        defer md.deinit(allocator);

        // Header
        const header = std.fmt.allocPrint(allocator,
            "# {s}\n\n**Created:** {s}\n**Updated:** {s}\n**UUID:** `{s}`\n\n---\n\n",
            .{ name, created, updated, uuid },
        ) catch continue;
        defer allocator.free(header);
        md.appendSlice(allocator, header) catch continue;

        // Messages
        const messages = conversation.object.get("chat_messages") orelse continue;
        if (messages != .array) continue;

        var msg_idx: u32 = 0;
        for (messages.array.items) |message| {
            if (message != .object) continue;

            const sender = getStr(message, "sender") orelse "unknown";
            const text = getStr(message, "text") orelse "";
            const msg_created = getStr(message, "created_at") orelse "";

            // Role header
            const role_icon = if (std.mem.eql(u8, sender, "human")) "**You**" else "**Claude**";
            const msg_header = std.fmt.allocPrint(allocator,
                "## {s}\n\n*{s}*\n\n",
                .{ role_icon, msg_created },
            ) catch continue;
            defer allocator.free(msg_header);
            md.appendSlice(allocator, msg_header) catch continue;

            // Message text
            md.appendSlice(allocator, text) catch continue;
            md.appendSlice(allocator, "\n\n") catch continue;

            // Attachments
            if (message.object.get("attachments")) |attachments| {
                if (attachments == .array and attachments.array.items.len > 0) {
                    md.appendSlice(allocator, "**Attachments:**\n") catch continue;
                    for (attachments.array.items) |att| {
                        if (att != .object) continue;
                        const att_name = getStr(att, "file_name") orelse "unnamed";

                        // Save attachment content to artifacts dir
                        if (getStr(att, "extracted_content")) |content| {
                            // Reject attachment names that escape the artifact
                            // directory (CWE-22: zip-slip via JSON). Names with
                            // `/`, `\`, `\0`, or a leading `.` are dropped — the
                            // attachment is still listed in the markdown for the
                            // user, but no file is written.
                            if (isSafeAttachmentName(att_name)) {
                                // Create per-conversation artifact dir
                                const conv_art_dir = std.fmt.allocPrint(allocator, "{s}/artifacts/{s}_{s}", .{
                                    output_dir, date_prefix, if (uuid.len >= 8) uuid[0..8] else uuid,
                                }) catch continue;
                                defer allocator.free(conv_art_dir);
                                // Create parent artifacts/ dir first, then sub-dir
                                const parent = std.fmt.allocPrint(allocator, "{s}/artifacts", .{output_dir}) catch continue;
                                defer allocator.free(parent);
                                mkdir_fn(allocator, parent);
                                mkdir_fn(allocator, conv_art_dir);

                                const art_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ conv_art_dir, att_name }) catch continue;
                                defer allocator.free(art_path);
                                write_fn(allocator, art_path, content);
                                stats.artifacts += 1;
                            }
                        }

                        const att_line = std.fmt.allocPrint(allocator, "- `{s}`\n", .{att_name}) catch continue;
                        defer allocator.free(att_line);
                        md.appendSlice(allocator, att_line) catch continue;
                    }
                    md.appendSlice(allocator, "\n") catch continue;
                }
            }

            md.appendSlice(allocator, "---\n\n") catch continue;
            msg_idx += 1;
            stats.messages += 1;
        }

        // Write the conversation markdown
        write_fn(allocator, filename, md.items);
        stats.conversations += 1;

        std.debug.print("  [{d} msgs] {s}\n", .{ msg_idx, name });
    }

    return stats;
}

/// Generate a summary index of all conversations
pub fn generateIndex(allocator: std.mem.Allocator, json_data: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_data, .{
        .max_value_len = std.json.default_max_value_len,
    });
    defer parsed.deinit();

    if (parsed.value != .array) return error.InvalidFormat;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "# Claude Conversations Index\n\n");
    const count_line = try std.fmt.allocPrint(allocator, "Total: {d} conversations\n\n", .{parsed.value.array.items.len});
    defer allocator.free(count_line);
    try buf.appendSlice(allocator, count_line);

    try buf.appendSlice(allocator, "| Date | Title | Messages |\n|---|---|---|\n");

    for (parsed.value.array.items) |conv| {
        if (conv != .object) continue;
        const name = getStr(conv, "name") orelse "Untitled";
        const created = getStr(conv, "created_at") orelse "";
        const date = if (created.len >= 10) created[0..10] else "—";

        var msg_count: usize = 0;
        if (conv.object.get("chat_messages")) |msgs| {
            if (msgs == .array) msg_count = msgs.array.items.len;
        }

        const row = try std.fmt.allocPrint(allocator, "| {s} | {s} | {d} |\n", .{ date, name, msg_count });
        defer allocator.free(row);
        try buf.appendSlice(allocator, row);
    }

    return buf.toOwnedSlice(allocator);
}

// ─────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────

fn getStr(obj: std.json.Value, key: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    if (val != .string) return null;
    return val.string;
}

/// Returns true if `name` is safe to use as a filename inside an artifact
/// directory — no path separators, no NUL, no leading dot (which would let
/// the attacker write `..`, `.`, or hidden files), bounded length.
fn isSafeAttachmentName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    if (name[0] == '.') return false;
    for (name) |c| {
        if (c == '/' or c == '\\' or c == 0) return false;
    }
    return true;
}

fn sanitizeName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
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
        } else if (c == ' ') {
            try buf.append(allocator, '_');
            count += 1;
        }
    }

    if (buf.items.len == 0) {
        try buf.appendSlice(allocator, "untitled");
    }

    return buf.toOwnedSlice(allocator);
}
