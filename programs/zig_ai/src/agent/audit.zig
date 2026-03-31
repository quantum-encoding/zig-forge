// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Audit Log - JSONL append-only audit trail for orchestrator operations
//! Each line is a self-contained JSON object with timestamp, agent ID, event type, and details.

const std = @import("std");
const Allocator = std.mem.Allocator;

extern "c" fn fflush(stream: ?*std.c.FILE) c_int;

pub const AuditLog = struct {
    allocator: Allocator,
    path: []const u8,
    file: ?*std.c.FILE,

    pub fn init(allocator: Allocator, path: []const u8) !AuditLog {
        const path_owned = try allocator.dupe(u8, path);
        errdefer allocator.free(path_owned);

        // Open file for append
        const path_z = try allocator.allocSentinel(u8, path.len, 0);
        defer allocator.free(path_z);
        @memcpy(path_z, path);

        const file = std.c.fopen(path_z.ptr, "ab") orelse {
            return error.OpenFailed;
        };

        return .{
            .allocator = allocator,
            .path = path_owned,
            .file = file,
        };
    }

    pub fn deinit(self: *AuditLog) void {
        if (self.file) |f| {
            _ = std.c.fclose(f);
            self.file = null;
        }
        self.allocator.free(self.path);
    }

    /// Log a tool execution event
    pub fn logToolExecution(
        self: *AuditLog,
        agent_id: []const u8,
        tool_name: []const u8,
        args_preview: []const u8,
        success: bool,
        duration_ms: u64,
    ) void {
        const ts = getTimestamp();
        const ok_str: []const u8 = if (success) "true" else "false";
        // Truncate args preview
        const preview = if (args_preview.len > 200) args_preview[0..200] else args_preview;

        const line = std.fmt.allocPrint(self.allocator, "{{\"ts\":{d},\"agent\":\"{s}\",\"event\":\"tool\",\"tool\":\"{s}\",\"args\":\"{s}\",\"ok\":{s},\"ms\":{d}}}\n", .{
            ts, agent_id, tool_name, preview, ok_str, duration_ms,
        }) catch return;
        defer self.allocator.free(line);

        self.writeLine(line);
    }

    /// Log a generic event
    pub fn logEvent(
        self: *AuditLog,
        agent_id: []const u8,
        event_type: []const u8,
        details: []const u8,
    ) void {
        const ts = getTimestamp();

        const line = std.fmt.allocPrint(self.allocator, "{{\"ts\":{d},\"agent\":\"{s}\",\"event\":\"{s}\",\"details\":\"{s}\"}}\n", .{
            ts, agent_id, event_type, details,
        }) catch return;
        defer self.allocator.free(line);

        self.writeLine(line);
    }

    /// Log orchestrator phase transition
    pub fn logPhase(
        self: *AuditLog,
        phase: []const u8,
        details: []const u8,
    ) void {
        const ts = getTimestamp();

        const line = std.fmt.allocPrint(self.allocator, "{{\"ts\":{d},\"agent\":\"orchestrator\",\"event\":\"phase\",\"phase\":\"{s}\",\"details\":\"{s}\"}}\n", .{
            ts, phase, details,
        }) catch return;
        defer self.allocator.free(line);

        self.writeLine(line);
    }

    /// Log task status change
    pub fn logTaskStatus(
        self: *AuditLog,
        task_id: []const u8,
        status: []const u8,
        input_tokens: u32,
        output_tokens: u32,
        duration_ms: u64,
    ) void {
        const ts = getTimestamp();

        const line = std.fmt.allocPrint(self.allocator, "{{\"ts\":{d},\"agent\":\"orchestrator\",\"event\":\"task_status\",\"task\":\"{s}\",\"status\":\"{s}\",\"input_tokens\":{d},\"output_tokens\":{d},\"ms\":{d}}}\n", .{
            ts, task_id, status, input_tokens, output_tokens, duration_ms,
        }) catch return;
        defer self.allocator.free(line);

        self.writeLine(line);
    }

    fn writeLine(self: *AuditLog, line: []const u8) void {
        if (self.file) |f| {
            _ = std.c.fwrite(line.ptr, 1, line.len, f);
            _ = fflush(f);
        }
    }
};

fn getTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}
