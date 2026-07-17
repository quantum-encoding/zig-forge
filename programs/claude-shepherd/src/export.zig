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
        var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };

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
        try aw.writer.writeByte('\n');

        writeFile(AGENTS_FILE, aw.writer.buffered());
    }

    pub fn exportPermissions(self: *JsonExporter) !void {
        const requests = self.state.getPendingRequests();

        // Serialize via std.json.Stringify so command/args/reason are escaped.
        // These strings come from monitored-agent output and must not be
        // interpolated raw. Allocating writer avoids the fixed-buffer overflow.
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        var js: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };

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
        try aw.writer.writeByte('\n');

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
