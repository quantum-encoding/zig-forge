// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! kill_process tool implementation
//! Sends signals to agent-spawned processes with conditional safety check:
//! only PIDs tracked in the process table can be killed.

const std = @import("std");
const types = @import("types.zig");
const process_table = @import("process_table.zig");

pub const KillProcessArgs = struct {
    pid: std.c.pid_t,
    signal: Signal = .TERM,
    kill_group: bool = false,
    reason: ?[]const u8 = null,

    pub const Signal = enum {
        TERM,
        KILL,
        INT,

        pub fn toSig(self: Signal) std.c.SIG {
            return switch (self) {
                .TERM => .TERM,
                .KILL => .KILL,
                .INT => .INT,
            };
        }

        pub fn name(self: Signal) []const u8 {
            return switch (self) {
                .TERM => "SIGTERM",
                .KILL => "SIGKILL",
                .INT => "SIGINT",
            };
        }

        pub fn fromString(s: []const u8) Signal {
            if (std.mem.eql(u8, s, "KILL")) return .KILL;
            if (std.mem.eql(u8, s, "INT")) return .INT;
            return .TERM;
        }
    };
};

/// Execute kill_process tool
pub fn execute(
    allocator: std.mem.Allocator,
    proc_table: *process_table.ProcessTable,
    args: KillProcessArgs,
) !types.ToolOutput {
    // Conditional safety check: only allow killing tracked processes
    if (!proc_table.isTracked(args.pid)) {
        return types.ToolOutput.error_result(
            allocator,
            "PID not tracked by agent — can only kill processes spawned by execute_command",
        );
    }

    // Get entry for PGID and status check
    const entry = proc_table.getEntry(args.pid) orelse {
        return types.ToolOutput.error_result(allocator, "Process entry not found");
    };

    // Check if already dead
    if (entry.status != .running) {
        const msg = try std.fmt.allocPrint(allocator, "Process {d} already {s}", .{
            args.pid,
            switch (entry.status) {
                .completed => "completed",
                .killed => "killed",
                .timed_out => "timed out",
                .running => unreachable,
            },
        });
        defer allocator.free(msg);
        return types.ToolOutput.error_result(allocator, msg);
    }

    // Send signal
    const sig = args.signal.toSig();
    const target: std.c.pid_t = if (args.kill_group) -entry.pgid else args.pid;
    const result = std.c.kill(target, sig);

    if (result != 0) {
        const err_msg = try std.fmt.allocPrint(allocator, "Failed to send {s} to PID {d}", .{
            args.signal.name(),
            args.pid,
        });
        defer allocator.free(err_msg);
        return types.ToolOutput.error_result(allocator, err_msg);
    }

    // Update process table
    proc_table.updateStatus(args.pid, .killed, null);

    // Build success message
    const target_desc = if (args.kill_group) "process group" else "process";
    const msg = try std.fmt.allocPrint(allocator, "Sent {s} to {s} {d} ({s})", .{
        args.signal.name(),
        target_desc,
        args.pid,
        if (entry.command.len > 60) entry.command[0..60] else entry.command,
    });
    defer allocator.free(msg);

    return types.ToolOutput.success_result(allocator, msg);
}

/// Parse arguments from JSON
pub fn parseArgs(allocator: std.mem.Allocator, json_str: []const u8) !KillProcessArgs {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.InvalidArguments;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    const pid_val = obj.get("pid") orelse return error.InvalidArguments;
    const pid: std.c.pid_t = @intCast(pid_val.integer);
    if (pid <= 0) return error.InvalidArguments;

    const signal = if (obj.get("signal")) |s|
        KillProcessArgs.Signal.fromString(s.string)
    else
        .TERM;

    const kill_group = if (obj.get("kill_group")) |k| k.bool else false;

    const reason = if (obj.get("reason")) |r|
        try allocator.dupe(u8, r.string)
    else
        null;

    return KillProcessArgs{
        .pid = pid,
        .signal = signal,
        .kill_group = kill_group,
        .reason = reason,
    };
}

pub fn freeArgs(allocator: std.mem.Allocator, args: KillProcessArgs) void {
    if (args.reason) |r| allocator.free(r);
}
