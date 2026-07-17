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

// std.c in Zig 0.16 only exposes `execve` (absolute-path exec). We
// want PATH resolution so the agent can call `git`, `make`, etc.
// without spelling out `/usr/bin/git`. Declaring execvp directly is
// portable across macOS/Linux (POSIX).
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

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

/// Run command using fork/exec with process group management.
///
/// Audit (SHELL-CHILD): the child previously did `execve("/bin/sh",
/// ["sh", "-c", command, null])`, which is an RCE primitive — an
/// agent-controlled `command` containing `;`, `$()`, backticks,
/// pipes, or redirects would run those AS SHELL CODE. The fork now
/// runs the program directly via execvp: argv[0] resolves through
/// PATH, every subsequent argv element is opaque bytes to the
/// program. Shell metacharacters in argv items are inert.
///
/// Tokenization happens in the PARENT (before fork) so any
/// allocation failure surfaces as a clean tool error rather than
/// dying in the child after fork (when allocator state is fragile).
/// The argv arrays live in the parent's address space until execvp;
/// fork copies the whole address space so the pointers are valid in
/// the child without further allocation.
///
/// Audit (validator/executor tokenizer parity): argv is built from the
/// SAME quote/escape-aware `command_parser.parse` that `validateCommand`
/// used to approve the command — not a separate whitespace split. The
/// previous `tokenizeAny(u8, command, " \t")` re-tokenizer ignored
/// quotes/escapes, so a quoted command (e.g. `grep "a b" file`) would
/// validate as three tokens but exec as four, and the allowlist gate
/// could reason about a different token stream than the one handed to
/// execvp. Re-running the deterministic parser on the same immutable
/// `command` string yields exactly the argv the validator approved.
fn runCommand(
    allocator: std.mem.Allocator,
    command: []const u8,
    work_dir: []const u8,
    exec_config: config.ExecuteCommandConfig,
    proc_table: ?*process_table.ProcessTable,
) !types.ToolOutput {
    // Tokenize the command into argv in the parent using the security
    // command parser — the identical routine (and identical input) that
    // `sandbox.validateCommand` ran, so the executed argv is guaranteed
    // to match the validated token stream. Shell features
    // (pipes/redirects/expansion) do not work; the agent must issue
    // multiple tool calls instead.
    var parser = security.command_parser.CommandParser.init(allocator);
    var parsed = parser.parse(command) catch return error.ForkFailed;
    defer parsed.deinit();

    var argv_storage: std.ArrayListUnmanaged([:0]u8) = .empty;
    defer {
        for (argv_storage.items) |s| allocator.free(s);
        argv_storage.deinit(allocator);
    }
    var argv_ptrs: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
    defer argv_ptrs.deinit(allocator);

    for (parsed.args) |tok| {
        const z = try allocator.allocSentinel(u8, tok.len, 0);
        @memcpy(z, tok);
        try argv_storage.append(allocator, z);
        try argv_ptrs.append(allocator, z.ptr);
    }
    try argv_ptrs.append(allocator, null);

    if (argv_storage.items.len == 0) return error.ForkFailed;

    // Null-terminate work_dir for chdir(2). Allocating in the
    // parent (not the child) keeps the post-fork window free of
    // allocator calls — async-signal-safety best-effort.
    const work_dir_z = try allocator.allocSentinel(u8, work_dir.len, 0);
    defer allocator.free(work_dir_z);
    @memcpy(work_dir_z, work_dir);

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
        if (std.c.chdir(work_dir_z.ptr) != 0) {
            std.c.exit(1);
        }

        // execvp: PATH-resolved exec of argv[0]. The argv array is
        // built from the model-supplied command via the security
        // command parser (the same tokens the validator approved);
        // no shell is invoked, so shell metacharacters in argv items
        // are inert.
        const prog: [*:0]const u8 = argv_storage.items[0].ptr;
        // execvp takes a non-const argv per POSIX signature, but
        // it does not modify the elements. The cast is required
        // to satisfy the type.
        _ = execvp(prog, @ptrCast(argv_ptrs.items.ptr));
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
