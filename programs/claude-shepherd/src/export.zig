//! JSON Export for GNOME Extension
//!
//! Writes state to JSON files that the GNOME extension can read.

const std = @import("std");
const State = @import("state.zig").State;

// C library imports for file operations
const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});
const ClaudeInstance = @import("state.zig").ClaudeInstance;
const PermissionRequest = @import("state.zig").PermissionRequest;

extern "c" fn unlink(path: [*:0]const u8) c_int;

const AGENTS_FILE: [:0]const u8 = "/tmp/claude-shepherd-agents.json";
const PERMISSIONS_FILE: [:0]const u8 = "/tmp/claude-shepherd-permissions.json";
const STATUS_FILE: [:0]const u8 = "/tmp/claude-shepherd-status.json";

pub const JsonExporter = struct {
    allocator: std.mem.Allocator,
    state: *State,

    pub fn init(allocator: std.mem.Allocator, state: *State) JsonExporter {
        return .{
            .allocator = allocator,
            .state = state,
        };
    }

    /// Export all state to JSON files
    pub fn exportAll(self: *JsonExporter) void {
        self.exportAgents() catch {};
        self.exportPermissions() catch {};
        self.exportStatus() catch {};
    }

    pub fn exportAgents(self: *JsonExporter) !void {
        const instances = try self.state.getAllInstances(self.allocator);
        defer self.allocator.free(instances);

        // Serialize via std.json.Stringify so every string field (task,
        // working_dir) is escaped correctly. The source strings originate from
        // monitored-agent output (Chronos log / eBPF TTY), so a raw `{s}`
        // format would let a `"`, `\`, or newline break or inject JSON.
        // An Allocating writer also removes the old fixed-buffer overflow risk.
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try writeAgentsJson(&aw.writer, instances);

        writeFile(AGENTS_FILE, aw.writer.buffered());
    }

    pub fn exportPermissions(self: *JsonExporter) !void {
        const requests = self.state.getPendingRequests();

        // Serialize via std.json.Stringify so command/args/reason are escaped.
        // These strings come from monitored-agent output and must not be
        // interpolated raw. Allocating writer avoids the fixed-buffer overflow.
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try writePermissionsJson(&aw.writer, requests);

        writeFile(PERMISSIONS_FILE, aw.writer.buffered());
    }

    fn exportStatus(self: *JsonExporter) !void {
        self.exportStatusWithMode("polling");
    }

    pub fn exportStatusWithMode(self: *JsonExporter, mode: []const u8) void {
        const active_count = self.state.getActiveCount();
        const pending_reqs = self.state.getPendingRequests();

        var pending_count: usize = 0;
        for (pending_reqs) |req| {
            if (req.status == .pending) pending_count += 1;
        }

        var json_buf: [256]u8 = undefined;
        const json = std.fmt.bufPrint(&json_buf, "{{\n  \"daemon_running\": true,\n  \"mode\": \"{s}\",\n  \"active_agents\": {d},\n  \"pending_permissions\": {d}\n}}\n", .{ mode, active_count, pending_count }) catch return;

        writeFile(STATUS_FILE, json);
    }
};

/// Serialize the instance list as a JSON array via std.json.Stringify.
///
/// Every string field (task, working_dir) is escaped by the encoder. These
/// strings originate from monitored-agent output (Chronos log / eBPF TTY),
/// so a raw `{s}` format would let a `"`, `\`, or newline break the document
/// or inject fields. Growing the writer also removes the old fixed-buffer
/// overflow risk in the hand-rolled assembler.
fn writeAgentsJson(w: *std.Io.Writer, instances: []const ClaudeInstance) std.Io.Writer.Error!void {
    var js: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };

    try js.beginArray();
    for (instances) |inst| {
        try js.write(.{
            .pid = inst.pid,
            .task = inst.task,
            .working_dir = inst.working_dir,
            .status = @tagName(inst.status),
            .started_at = inst.started_at,
            .last_activity = inst.last_activity,
        });
    }
    try js.endArray();
    try w.writeByte('\n');
}

/// Serialize the pending permission requests as a JSON array. command/args/
/// reason are agent-controlled and must be encoder-escaped, never interpolated.
fn writePermissionsJson(w: *std.Io.Writer, requests: []const PermissionRequest) std.Io.Writer.Error!void {
    var js: std.json.Stringify = .{ .writer = w, .options = .{ .whitespace = .indent_2 } };

    try js.beginArray();
    for (requests) |req| {
        if (req.status != .pending) continue;
        try js.write(.{
            .id = req.id,
            .pid = req.pid,
            .command = req.command,
            .args = req.args,
            .reason = req.reason,
            .timestamp = req.timestamp,
        });
    }
    try js.endArray();
    try w.writeByte('\n');
}

fn writeFile(path: []const u8, data: []const u8) void {
    var path_buf: [256]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return;

    const fd = c.open(@ptrCast(path_z.ptr), c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) return;
    defer _ = c.close(fd);

    _ = c.write(fd, data.ptr, data.len);
}

/// Clean up JSON files on shutdown
pub fn cleanup() void {
    _ = unlink(AGENTS_FILE);
    _ = unlink(PERMISSIONS_FILE);
    _ = unlink(STATUS_FILE);
}

test "writeAgentsJson escapes JSON-special chars from agent-controlled strings" {
    const allocator = std.testing.allocator;

    // Task/working_dir originate from monitored-agent output; feed the exact
    // characters that broke the old raw-`{s}` sink: a quote, a backslash, and a
    // newline. The output must remain valid JSON that roundtrips.
    const nasty_task = "hack\" ,\"injected\":true, \\slash\n newline";
    const nasty_dir = "/tmp/\"quoted\"/path";
    const instances = [_]ClaudeInstance{.{
        .pid = 4321,
        .task = nasty_task,
        .working_dir = nasty_dir,
        .status = .running,
        .started_at = 100,
        .last_activity = 200,
    }};

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeAgentsJson(&aw.writer, &instances);
    const bytes = aw.writer.buffered();

    // Must parse as valid JSON (the old code emitted a broken document here).
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const arr = parsed.value.array.items;
    try std.testing.expectEqual(@as(usize, 1), arr.len);
    const obj = arr[0].object;

    // The strings must roundtrip exactly — no truncation, no field injection.
    try std.testing.expectEqualStrings(nasty_task, obj.get("task").?.string);
    try std.testing.expectEqualStrings(nasty_dir, obj.get("working_dir").?.string);
    try std.testing.expectEqual(@as(i64, 4321), obj.get("pid").?.integer);
    try std.testing.expectEqualStrings("running", obj.get("status").?.string);
    // The injected `"injected":true` must NOT have become a real top-level field.
    try std.testing.expect(obj.get("injected") == null);
}

test "writePermissionsJson escapes command/args/reason and skips non-pending" {
    const allocator = std.testing.allocator;

    const requests = [_]PermissionRequest{
        .{
            .id = 1,
            .pid = 99,
            .command = "rm \"x\"",
            .args = "--flag=\"a\\b\"\n",
            .reason = "because \"reasons\"",
            .timestamp = 7,
            .status = .pending,
        },
        // Non-pending entries must be filtered out of the export.
        .{
            .id = 2,
            .pid = 100,
            .command = "ls",
            .args = "",
            .reason = "done",
            .timestamp = 8,
            .status = .approved,
        },
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writePermissionsJson(&aw.writer, &requests);
    const bytes = aw.writer.buffered();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();

    const arr = parsed.value.array.items;
    try std.testing.expectEqual(@as(usize, 1), arr.len);
    const obj = arr[0].object;
    try std.testing.expectEqual(@as(i64, 1), obj.get("id").?.integer);
    try std.testing.expectEqualStrings("rm \"x\"", obj.get("command").?.string);
    try std.testing.expectEqualStrings("--flag=\"a\\b\"\n", obj.get("args").?.string);
    try std.testing.expectEqualStrings("because \"reasons\"", obj.get("reason").?.string);
}
