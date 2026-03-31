// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! Process table for tracking spawned child processes
//! Used by execute_command to register and monitor external processes

const std = @import("std");

extern "c" fn time(tloc: ?*i64) i64;

pub const ProcessStatus = enum {
    running,
    completed,
    killed,
    timed_out,
};

pub const ProcessEntry = struct {
    pid: std.c.pid_t,
    pgid: std.c.pid_t,
    command: []const u8,
    start_time: i64, // unix seconds
    status: ProcessStatus,
    exit_code: ?u8 = null,
};

pub const ProcessTable = struct {
    entries: std.ArrayListUnmanaged(ProcessEntry) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ProcessTable {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ProcessTable) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.command);
        }
        self.entries.deinit(self.allocator);
    }

    /// Register a new process
    pub fn register(self: *ProcessTable, pid: std.c.pid_t, pgid: std.c.pid_t, command: []const u8) !void {
        const cmd_copy = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(cmd_copy);

        const now = time(null);

        try self.entries.append(self.allocator, .{
            .pid = pid,
            .pgid = pgid,
            .command = cmd_copy,
            .start_time = now,
            .status = .running,
        });
    }

    /// Update status for a process by PID
    pub fn updateStatus(self: *ProcessTable, pid: std.c.pid_t, status: ProcessStatus, exit_code: ?u8) void {
        for (self.entries.items) |*entry| {
            if (entry.pid == pid) {
                entry.status = status;
                entry.exit_code = exit_code;
                return;
            }
        }
    }

    /// Check if a PID is tracked
    pub fn isTracked(self: *const ProcessTable, pid: std.c.pid_t) bool {
        for (self.entries.items) |entry| {
            if (entry.pid == pid) return true;
        }
        return false;
    }

    /// Get entry by PID (for PGID lookup and status checks)
    pub fn getEntry(self: *const ProcessTable, pid: std.c.pid_t) ?*const ProcessEntry {
        for (self.entries.items) |*entry| {
            if (entry.pid == pid) return entry;
        }
        return null;
    }

    /// Get count of running processes
    pub fn runningCount(self: *const ProcessTable) usize {
        var count: usize = 0;
        for (self.entries.items) |entry| {
            if (entry.status == .running) count += 1;
        }
        return count;
    }

    /// Format process table for display
    pub fn format(self: *const ProcessTable, allocator: std.mem.Allocator) ![]const u8 {
        if (self.entries.items.len == 0) {
            return try allocator.dupe(u8, "No tracked processes");
        }

        var output: std.ArrayListUnmanaged(u8) = .empty;
        errdefer output.deinit(allocator);

        try output.appendSlice(allocator, "PID\tSTATUS\t\tCOMMAND\n");
        try output.appendSlice(allocator, "---\t------\t\t-------\n");

        for (self.entries.items) |entry| {
            const status_str = switch (entry.status) {
                .running => "running",
                .completed => "completed",
                .killed => "killed",
                .timed_out => "timed_out",
            };
            const line = try std.fmt.allocPrint(allocator, "{d}\t{s}\t\t{s}\n", .{
                entry.pid,
                status_str,
                if (entry.command.len > 60) entry.command[0..60] else entry.command,
            });
            defer allocator.free(line);
            try output.appendSlice(allocator, line);
        }

        return try output.toOwnedSlice(allocator);
    }
};
