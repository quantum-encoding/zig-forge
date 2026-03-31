// Copyright (c) 2025 QUANTUM ENCODING LTD
// Licensed under the MIT License.

//! execute_command tool implementation
//! Runs shell commands with security validation and process group management

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const security = @import("../security/mod.zig");
const config = @import("../config.zig");
const process_table = @import("process_table.zig");

// Zig 0.16 compatible - get monotonic time in nanoseconds
fn getMonotonicNs() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

pub const ExecuteCommandArgs = struct {
    command: []const u8,
    working_dir: []const u8 = ".",
};

/// Execute execute_command tool
pub fn execute(
    allocator: std.mem.Allocator,
    sandbox: *security.Sandbox,
    args: ExecuteCommandArgs,
    exec_config: config.ExecuteCommandConfig,
    proc_table: ?*process_table.ProcessTable,
) !types.ToolOutput {
    // Validate command against security rules
    sandbox.validateCommand(args.command) catch |err| {
        return types.ToolOutput.error_result(allocator, switch (err) {
            security.SandboxError.CommandNotAllowed => "Command not in allowed list",
            security.SandboxError.BannedPatternMatch => "Command matches banned pattern",
            else => "Command validation failed",
        });
    };

    // Validate working directory
    const work_dir = sandbox.validatePath(args.working_dir) catch |err| {
        return types.ToolOutput.error_result(allocator, switch (err) {
            security.SandboxError.PathOutsideSandbox => "Working directory is outside sandbox",
            else => "Invalid working directory",
        });
    };
    defer allocator.free(work_dir);

    // Execute command
    const result = runCommand(allocator, args.command, work_dir, exec_config, proc_table) catch |err| {
        const msg = switch (err) {
            error.Timeout => "Command timed out",
            error.ForkFailed => "Failed to execute command",
            else => "Command execution failed",
        };
        return types.ToolOutput.error_result(allocator, msg);
    };

    return result;
}

/// Run command using fork/exec with process group management
fn runCommand(
    allocator: std.mem.Allocator,
    command: []const u8,
    work_dir: []const u8,
    exec_config: config.ExecuteCommandConfig,
    proc_table: ?*process_table.ProcessTable,
) !types.ToolOutput {
    // Create pipes for stdout/stderr
    var stdout_pipe: [2]c_int = undefined;
    var stderr_pipe: [2]c_int = undefined;

    if (std.c.pipe(&stdout_pipe) != 0 or std.c.pipe(&stderr_pipe) != 0) {
        return error.ForkFailed;
    }

    const pid = std.c.fork();
    if (pid < 0) {
        return error.ForkFailed;
    }

    if (pid == 0) {
        // Child process
        // Create new process group
        _ = std.c.setpgid(0, 0);

        // Close read ends
        _ = std.c.close(stdout_pipe[0]);
        _ = std.c.close(stderr_pipe[0]);

        // Redirect stdout/stderr
        _ = std.c.dup2(stdout_pipe[1], 1);
        _ = std.c.dup2(stderr_pipe[1], 2);
        _ = std.c.close(stdout_pipe[1]);
        _ = std.c.close(stderr_pipe[1]);

        // Change to working directory
        const work_dir_z = allocator.allocSentinel(u8, work_dir.len, 0) catch std.c.exit(1);
        @memcpy(work_dir_z, work_dir);
        if (std.c.chdir(work_dir_z.ptr) != 0) {
            std.c.exit(1);
        }

        // Execute command via shell
        const cmd_z = allocator.allocSentinel(u8, command.len, 0) catch std.c.exit(1);
        @memcpy(cmd_z, command);

        const shell = std.c.getenv("SHELL") orelse "/bin/sh";
        const argv = [_:null]?[*:0]const u8{ shell, "-c", cmd_z.ptr, null };
        _ = std.c.execve(shell, &argv, std.c.environ);
        std.c.exit(127);
    }

    // Parent process
    // Close write ends
    _ = std.c.close(stdout_pipe[1]);
    _ = std.c.close(stderr_pipe[1]);

    // Set process group for child
    _ = std.c.setpgid(pid, pid);

    // Register in process table
    if (proc_table) |pt| {
        pt.register(pid, pid, command) catch {};
    }

    // Read output with timeout
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);

    const timeout_ns: i128 = @as(i128, exec_config.timeout_ms) * 1_000_000;
    const start_ns: i128 = getMonotonicNs();

    // Non-blocking read
    var buf: [4096]u8 = undefined;
    var status: c_int = 0;

    while (true) {
        // Check timeout
        const now_ns: i128 = getMonotonicNs();
        if (now_ns - start_ns > timeout_ns) {
            // Kill process group
            if (exec_config.kill_process_group) {
                _ = std.c.kill(-pid, std.c.SIG.KILL); // SIGKILL to process group
            } else {
                _ = std.c.kill(pid, std.c.SIG.KILL);
            }
            _ = std.c.waitpid(pid, &status, 0);
            _ = std.c.close(stdout_pipe[0]);
            _ = std.c.close(stderr_pipe[0]);
            if (proc_table) |pt| {
                pt.updateStatus(pid, .timed_out, null);
            }
            return error.Timeout;
        }

        // Check if child exited
        const wait_result = std.c.waitpid(pid, &status, 1); // WNOHANG
        if (wait_result == pid) {
            break; // Child exited
        }

        // Read available output
        const read_count = std.c.read(stdout_pipe[0], &buf, buf.len);
        if (read_count > 0) {
            const count: usize = @intCast(read_count);
            if (output.items.len + count <= exec_config.max_output_bytes) {
                try output.appendSlice(allocator, buf[0..count]);
            }
        }

        // Small sleep to avoid busy loop (10ms)
        var sleep_ts = std.posix.timespec{ .sec = 0, .nsec = 10_000_000 };
        _ = std.c.nanosleep(&sleep_ts, null);
    }

    // Read remaining output
    while (true) {
        const read_count = std.c.read(stdout_pipe[0], &buf, buf.len);
        if (read_count <= 0) break;
        const count: usize = @intCast(read_count);
        if (output.items.len + count <= exec_config.max_output_bytes) {
            try output.appendSlice(allocator, buf[0..count]);
        }
    }

    // Read stderr
    var stderr_output: std.ArrayListUnmanaged(u8) = .empty;
    defer stderr_output.deinit(allocator);
    while (true) {
        const read_count = std.c.read(stderr_pipe[0], &buf, buf.len);
        if (read_count <= 0) break;
        const count: usize = @intCast(read_count);
        if (stderr_output.items.len + count <= 4096) {
            try stderr_output.appendSlice(allocator, buf[0..count]);
        }
    }

    _ = std.c.close(stdout_pipe[0]);
    _ = std.c.close(stderr_pipe[0]);

    // Check exit status
    const exit_code = (status >> 8) & 0xFF;

    // Update process table
    if (proc_table) |pt| {
        pt.updateStatus(pid, .completed, @intCast(exit_code));
    }

    if (exit_code != 0) {
        var error_msg: std.ArrayListUnmanaged(u8) = .empty;
        defer error_msg.deinit(allocator);

        const header = try std.fmt.allocPrint(allocator, "Command exited with code {d}", .{exit_code});
        defer allocator.free(header);
        try error_msg.appendSlice(allocator, header);

        if (stderr_output.items.len > 0) {
            try error_msg.appendSlice(allocator, "\nstderr: ");
            try error_msg.appendSlice(allocator, stderr_output.items);
        }

        if (output.items.len > 0) {
            try error_msg.appendSlice(allocator, "\nstdout: ");
            try error_msg.appendSlice(allocator, output.items);
        }

        return types.ToolOutput{
            .success = false,
            .content = try output.toOwnedSlice(allocator),
            .error_message = try error_msg.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    return types.ToolOutput{
        .success = true,
        .content = try output.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// Parse arguments from JSON
pub fn parseArgs(allocator: std.mem.Allocator, json_str: []const u8) !ExecuteCommandArgs {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return error.InvalidArguments;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    const command = obj.get("command") orelse return error.InvalidArguments;

    // Always allocate strings so they can be uniformly freed by caller
    return ExecuteCommandArgs{
        .command = try allocator.dupe(u8, command.string),
        .working_dir = if (obj.get("working_dir")) |w| try allocator.dupe(u8, w.string) else try allocator.dupe(u8, "."),
    };
}
