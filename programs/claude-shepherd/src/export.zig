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

        var json_buf: [8192]u8 = undefined;
        var pos: usize = 0;

        // Write opening bracket
        const open = "[\n";
        @memcpy(json_buf[pos..][0..open.len], open);
        pos += open.len;

        for (instances, 0..) |inst, i| {
            if (i > 0) {
                const comma = ",\n";
                @memcpy(json_buf[pos..][0..comma.len], comma);
                pos += comma.len;
            }

            const entry = std.fmt.bufPrint(json_buf[pos..], "  {{\n    \"pid\": {d},\n    \"task\": \"{s}\",\n    \"working_dir\": \"{s}\",\n    \"status\": \"{s}\",\n    \"started_at\": {d},\n    \"last_activity\": {d}\n  }}", .{
                inst.pid,
                inst.task,
                inst.working_dir,
                @tagName(inst.status),
                inst.started_at,
                inst.last_activity,
            }) catch break;
            pos += entry.len;
        }

        const close = "\n]\n";
        @memcpy(json_buf[pos..][0..close.len], close);
        pos += close.len;

        writeFile(AGENTS_FILE, json_buf[0..pos]);
    }

    pub fn exportPermissions(self: *JsonExporter) !void {
        const requests = self.state.getPendingRequests();

        var json_buf: [8192]u8 = undefined;
        var pos: usize = 0;

        const open = "[\n";
        @memcpy(json_buf[pos..][0..open.len], open);
        pos += open.len;

        var first = true;
        for (requests) |req| {
            if (req.status != .pending) continue;

            if (!first) {
                const comma = ",\n";
                @memcpy(json_buf[pos..][0..comma.len], comma);
                pos += comma.len;
            }
            first = false;

            const entry = std.fmt.bufPrint(json_buf[pos..], "  {{\n    \"id\": {d},\n    \"pid\": {d},\n    \"command\": \"{s}\",\n    \"args\": \"{s}\",\n    \"reason\": \"{s}\",\n    \"timestamp\": {d}\n  }}", .{
                req.id,
                req.pid,
                req.command,
                req.args,
                req.reason,
                req.timestamp,
            }) catch break;
            pos += entry.len;
        }

        const close = "\n]\n";
        @memcpy(json_buf[pos..][0..close.len], close);
        pos += close.len;

        writeFile(PERMISSIONS_FILE, json_buf[0..pos]);
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

fn escapeJson(s: []const u8) []const u8 {
    // Simple pass-through for now - real implementation would escape special chars
    // This is safe for most task descriptions
    return s;
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
