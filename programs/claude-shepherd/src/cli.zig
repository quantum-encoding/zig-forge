//! shepherd CLI - Command-line interface for claude-shepherd daemon
//!
//! Usage:
//!   shepherd status              Show all Claude instances and pending requests
//!   shepherd queue "task"        Queue a new task for execution
//!   shepherd approve <id>        Approve a permission request
//!   shepherd deny <id>           Deny a permission request
//!   shepherd approve-all         Approve all pending requests
//!   shepherd policy add ...      Add a policy rule
//!   shepherd response "trigger"  Set a pre-queued response
//!   shepherd kill <pid>          Stop a Claude instance

const std = @import("std");

// C library imports for file operations
const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

// C functions for sleep
const Timespec = extern struct { tv_sec: i64, tv_nsec: i64 };
extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;

// C functions for Unix socket communication
extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn connect(sockfd: c_int, addr: *const anyopaque, addrlen: u32) c_int;

const AF_UNIX: c_int = 1;
const SOCK_STREAM: c_int = 1;

const SockaddrUn = extern struct {
    family: u16 = 1, // AF_UNIX
    path: [108]u8 = [_]u8{0} ** 108,
};

const VERSION = "0.1.0";
const SOCKET_PATH = "/tmp/claude-shepherd.sock";
const PID_FILE = "/tmp/claude-shepherd.pid";

// ANSI color codes
const RESET = "\x1b[0m";
const BOLD = "\x1b[1m";
const RED = "\x1b[31m";
const GREEN = "\x1b[32m";
const YELLOW = "\x1b[33m";
const BLUE = "\x1b[34m";
const CYAN = "\x1b[36m";
const DIM = "\x1b[2m";

fn writeStdout(msg: []const u8) void {
    _ = c.write(1, msg.ptr, msg.len);
}

fn writeStderr(msg: []const u8) void {
    _ = c.write(2, msg.ptr, msg.len);
}

fn printUsage() void {
    const usage =
        \\
        \\Usage: shepherd <command> [args...]
        \\
        \\Claude Shepherd CLI - Manage Claude Code instances
        \\
        \\Commands:
        \\  status                    Show daemon status and active instances
        \\  queue "<task>" [dir]      Queue a task for execution
        \\  approve <id>              Approve a permission request
        \\  deny <id>                 Deny a permission request
        \\  approve-all               Approve all pending permission requests
        \\  policy add <cmd> <allow|deny|prompt>
        \\                            Add a policy rule
        \\  policy list               List all policy rules
        \\  response "<trigger>" "<response>"
        \\                            Add a pre-queued response
        \\  kill <pid>                Terminate a Claude instance
        \\  logs [-f]                 Show daemon logs (with optional follow)
        \\
        \\Options:
        \\  --help, -h                Show this help message
        \\  --version, -v             Show version
        \\
        \\Examples:
        \\  shepherd status
        \\  shepherd queue "build zsort and run tests"
        \\  shepherd approve 1
        \\  shepherd policy add rm deny
        \\  shepherd response "Permission required" "y"
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("shepherd " ++ VERSION ++ " - Claude Shepherd CLI\n");
}

const Command = enum {
    status,
    queue,
    approve,
    deny,
    approve_all,
    policy,
    response,
    kill,
    logs,
    help,
    version,
    unknown,
};

fn parseCommand(arg: []const u8) Command {
    if (std.mem.eql(u8, arg, "status")) return .status;
    if (std.mem.eql(u8, arg, "queue")) return .queue;
    if (std.mem.eql(u8, arg, "approve")) return .approve;
    if (std.mem.eql(u8, arg, "deny")) return .deny;
    if (std.mem.eql(u8, arg, "approve-all")) return .approve_all;
    if (std.mem.eql(u8, arg, "policy")) return .policy;
    if (std.mem.eql(u8, arg, "response")) return .response;
    if (std.mem.eql(u8, arg, "kill")) return .kill;
    if (std.mem.eql(u8, arg, "logs")) return .logs;
    if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .help;
    if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) return .version;
    return .unknown;
}

fn isDaemonRunning() ?u32 {
    // Check PID file
    var buf: [32]u8 = undefined;
    var path_buf: [256]u8 = undefined;

    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{PID_FILE}) catch return null;
    const fd = c.open(@ptrCast(path_z.ptr), c.O_RDONLY, @as(c_uint, 0));
    if (fd < 0) return null;
    defer _ = c.close(fd);

    const n_raw = c.read(fd, &buf, buf.len);
    if (n_raw <= 0) return null;
    const n: usize = @intCast(n_raw);

    // Parse PID
    var end: usize = 0;
    while (end < n and buf[end] >= '0' and buf[end] <= '9') {
        end += 1;
    }

    const pid = std.fmt.parseInt(u32, buf[0..end], 10) catch return null;

    // Verify process exists
    var proc_path: [64]u8 = undefined;
    const proc_z = std.fmt.bufPrintZ(&proc_path, "/proc/{d}", .{pid}) catch return null;
    const proc_fd = c.open(@ptrCast(proc_z.ptr), c.O_RDONLY, @as(c_uint, 0));
    if (proc_fd < 0) return null;
    _ = c.close(proc_fd);

    return pid;
}

/// Send a command to the daemon via Unix socket and receive response
/// Returns response bytes read, or null on failure
fn sendDaemonCommand(cmd: []const u8, response_buf: []u8) ?usize {
    const fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return null;
    defer _ = c.close(fd);

    var addr = SockaddrUn{};
    const sock_path = SOCKET_PATH;
    @memcpy(addr.path[0..sock_path.len], sock_path);

    if (connect(fd, @ptrCast(&addr), @sizeOf(SockaddrUn)) < 0) return null;

    // Send command
    const written = c.write(fd, cmd.ptr, cmd.len);
    if (written < 0) return null;

    // Read response
    const n = c.read(fd, response_buf.ptr, response_buf.len);
    if (n < 0) return null;
    return @intCast(n);
}

fn printStatus() void {
    writeStdout("\n");
    writeStdout(BOLD ++ "  Claude Shepherd Status\n" ++ RESET);
    writeStdout("  " ++ DIM ++ "═══════════════════════════════════════\n" ++ RESET);
    writeStdout("\n");

    // Check daemon status
    if (isDaemonRunning()) |pid| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "  Daemon:    " ++ GREEN ++ "●" ++ RESET ++ " Running (PID {d})\n", .{pid}) catch return;
        writeStdout(msg);
    } else {
        writeStdout("  Daemon:    " ++ RED ++ "○" ++ RESET ++ " Not running\n");
        writeStdout("\n  " ++ DIM ++ "Start with: claude-shepherd -d" ++ RESET ++ "\n\n");
        return;
    }

    writeStdout("\n");

    // Query daemon for real-time status via Unix socket
    var resp_buf: [4096]u8 = undefined;
    if (sendDaemonCommand("STATUS\n", &resp_buf)) |n| {
        if (n > 0) {
            writeStdout(resp_buf[0..n]);
            writeStdout("\n");
            return;
        }
    }

    // Fallback: read exported JSON files from GNOME extension export
    writeStdout("  " ++ CYAN ++ "Active Instances" ++ RESET ++ "\n");
    writeStdout("  " ++ DIM ++ "───────────────────────────────────────\n" ++ RESET);

    // Try reading agents JSON
    var agents_buf: [4096]u8 = undefined;
    var agents_path: [256]u8 = undefined;
    const agents_z = std.fmt.bufPrintZ(&agents_path, "/tmp/claude-shepherd-agents.json", .{}) catch {
        writeStdout("  " ++ DIM ++ "No active Claude instances" ++ RESET ++ "\n");
        writeStdout("\n");
        return;
    };
    const agents_fd = c.open(@ptrCast(agents_z.ptr), c.O_RDONLY, @as(c_uint, 0));
    if (agents_fd >= 0) {
        defer _ = c.close(agents_fd);
        const an = c.read(agents_fd, &agents_buf, agents_buf.len);
        if (an > 0) {
            const agents_n: usize = @intCast(an);
            writeStdout("  ");
            writeStdout(agents_buf[0..agents_n]);
            writeStdout("\n");
        } else {
            writeStdout("  " ++ DIM ++ "No active Claude instances" ++ RESET ++ "\n");
        }
    } else {
        writeStdout("  " ++ DIM ++ "No active Claude instances" ++ RESET ++ "\n");
    }
    writeStdout("\n");

    writeStdout("  " ++ YELLOW ++ "Pending Permissions" ++ RESET ++ "\n");
    writeStdout("  " ++ DIM ++ "───────────────────────────────────────\n" ++ RESET);
    writeStdout("  " ++ DIM ++ "No pending permission requests" ++ RESET ++ "\n");
    writeStdout("\n");

    writeStdout("  " ++ BLUE ++ "Task Queue" ++ RESET ++ "\n");
    writeStdout("  " ++ DIM ++ "───────────────────────────────────────\n" ++ RESET);
    writeStdout("  " ++ DIM ++ "Queue empty" ++ RESET ++ "\n");
    writeStdout("\n");
}

fn queueTask(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        writeStderr(RED ++ "Error: " ++ RESET ++ "Missing task description\n");
        writeStderr("Usage: shepherd queue \"<task description>\" [working_dir]\n");
        return;
    }

    const task = args[0];
    const working_dir = if (args.len > 1) args[1] else ".";

    // Check daemon is running
    if (isDaemonRunning() == null) {
        writeStderr(RED ++ "Error: " ++ RESET ++ "Daemon not running\n");
        writeStderr("Start with: claude-shepherd -d\n");
        return;
    }

    // Send to daemon via Unix socket
    var cmd_buf: [1024]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "QUEUE {s} {s}\n", .{ task, working_dir }) catch {
        writeStderr(RED ++ "Error: " ++ RESET ++ "Command too long\n");
        return;
    };
    var resp_buf: [256]u8 = undefined;
    _ = sendDaemonCommand(cmd, &resp_buf);
    _ = allocator;

    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, GREEN ++ "✓" ++ RESET ++ " Queued task: {s}\n  Working dir: {s}\n", .{ task, working_dir }) catch return;
    writeStdout(msg);
}

fn approveRequest(id_str: []const u8) void {
    const id = std.fmt.parseInt(u64, id_str, 10) catch {
        writeStderr(RED ++ "Error: " ++ RESET ++ "Invalid request ID\n");
        return;
    };

    if (isDaemonRunning() == null) {
        writeStderr(RED ++ "Error: " ++ RESET ++ "Daemon not running\n");
        return;
    }

    // Send approval to daemon via Unix socket
    var cmd_buf: [128]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "APPROVE {d}\n", .{id}) catch return;
    var resp_buf: [256]u8 = undefined;
    _ = sendDaemonCommand(cmd, &resp_buf);

    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, GREEN ++ "✓" ++ RESET ++ " Approved request #{d}\n", .{id}) catch return;
    writeStdout(msg);
}

fn denyRequest(id_str: []const u8) void {
    const id = std.fmt.parseInt(u64, id_str, 10) catch {
        writeStderr(RED ++ "Error: " ++ RESET ++ "Invalid request ID\n");
        return;
    };

    if (isDaemonRunning() == null) {
        writeStderr(RED ++ "Error: " ++ RESET ++ "Daemon not running\n");
        return;
    }

    // Send denial to daemon via Unix socket
    var cmd_buf2: [128]u8 = undefined;
    const cmd2 = std.fmt.bufPrint(&cmd_buf2, "DENY {d}\n", .{id}) catch return;
    var resp_buf2: [256]u8 = undefined;
    _ = sendDaemonCommand(cmd2, &resp_buf2);

    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, YELLOW ++ "✗" ++ RESET ++ " Denied request #{d}\n", .{id}) catch return;
    writeStdout(msg);
}

fn approveAll() void {
    if (isDaemonRunning() == null) {
        writeStderr(RED ++ "Error: " ++ RESET ++ "Daemon not running\n");
        return;
    }

    // Send bulk approval to daemon via Unix socket
    var resp_buf3: [256]u8 = undefined;
    _ = sendDaemonCommand("APPROVE_ALL\n", &resp_buf3);

    writeStdout(GREEN ++ "✓" ++ RESET ++ " Approved all pending requests\n");
}

fn handlePolicy(args: []const []const u8) void {
    if (args.len < 1) {
        writeStderr(RED ++ "Error: " ++ RESET ++ "Missing policy subcommand\n");
        writeStderr("Usage: shepherd policy <add|list|remove> [...]\n");
        return;
    }

    const subcommand = args[0];

    if (std.mem.eql(u8, subcommand, "list")) {
        writeStdout("\n" ++ BOLD ++ "  Policy Rules\n" ++ RESET);
        writeStdout("  " ++ DIM ++ "═══════════════════════════════════════\n" ++ RESET);
        writeStdout("\n  " ++ GREEN ++ "Allow" ++ RESET ++ "\n");
        writeStdout("    cat, ls, tree, find, head, tail, grep, rg, wc, file\n");
        writeStdout("    zig build*, zig test*, zig version*\n");
        writeStdout("    ./zig-out/bin/*\n");
        writeStdout("\n  " ++ YELLOW ++ "Prompt" ++ RESET ++ "\n");
        writeStdout("    rm, mv, cp, chmod, chown\n");
        writeStdout("\n  " ++ RED ++ "Deny" ++ RESET ++ "\n");
        writeStdout("    sudo, su, dd, mkfs, fdisk\n");
        writeStdout("\n");
    } else if (std.mem.eql(u8, subcommand, "add")) {
        if (args.len < 3) {
            writeStderr(RED ++ "Error: " ++ RESET ++ "Missing arguments\n");
            writeStderr("Usage: shepherd policy add <command> <allow|deny|prompt>\n");
            return;
        }

        const cmd = args[1];
        const decision = args[2];

        if (isDaemonRunning() == null) {
            writeStderr(RED ++ "Error: " ++ RESET ++ "Daemon not running\n");
            return;
        }

        // Send policy add to daemon via Unix socket
        var cmd_buf4: [512]u8 = undefined;
        const cmd4 = std.fmt.bufPrint(&cmd_buf4, "POLICY_ADD {s} {s}\n", .{ cmd, decision }) catch return;
        var resp_buf4: [256]u8 = undefined;
        _ = sendDaemonCommand(cmd4, &resp_buf4);

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, GREEN ++ "✓" ++ RESET ++ " Added policy: {s} → {s}\n", .{ cmd, decision }) catch return;
        writeStdout(msg);
    } else {
        writeStderr(RED ++ "Error: " ++ RESET ++ "Unknown policy subcommand: ");
        writeStderr(subcommand);
        writeStderr("\n");
    }
}

fn addPreResponse(args: []const []const u8) void {
    if (args.len < 2) {
        writeStderr(RED ++ "Error: " ++ RESET ++ "Missing arguments\n");
        writeStderr("Usage: shepherd response \"<trigger>\" \"<response>\"\n");
        return;
    }

    const trigger = args[0];
    const response = args[1];

    if (isDaemonRunning() == null) {
        writeStderr(RED ++ "Error: " ++ RESET ++ "Daemon not running\n");
        return;
    }

    // Send pre-response to daemon via Unix socket
    var cmd_buf5: [1024]u8 = undefined;
    const cmd5 = std.fmt.bufPrint(&cmd_buf5, "RESPONSE {s} {s}\n", .{ trigger, response }) catch return;
    var resp_buf5: [256]u8 = undefined;
    _ = sendDaemonCommand(cmd5, &resp_buf5);

    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, GREEN ++ "✓" ++ RESET ++ " Added pre-response:\n  Trigger:  \"{s}\"\n  Response: \"{s}\"\n", .{ trigger, response }) catch return;
    writeStdout(msg);
}

fn killInstance(pid_str: []const u8) void {
    const pid = std.fmt.parseInt(u32, pid_str, 10) catch {
        writeStderr(RED ++ "Error: " ++ RESET ++ "Invalid PID\n");
        return;
    };

    if (isDaemonRunning() == null) {
        writeStderr(RED ++ "Error: " ++ RESET ++ "Daemon not running\n");
        return;
    }

    // Send kill signal to daemon via Unix socket
    var cmd_buf6: [128]u8 = undefined;
    const cmd6 = std.fmt.bufPrint(&cmd_buf6, "KILL {d}\n", .{pid}) catch return;
    var resp_buf6: [256]u8 = undefined;
    _ = sendDaemonCommand(cmd6, &resp_buf6);

    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, YELLOW ++ "✗" ++ RESET ++ " Sent termination signal to PID {d}\n", .{pid}) catch return;
    writeStdout(msg);
}

fn showLogs(follow: bool) void {
    const log_path = "/tmp/claude-shepherd.log";
    var path_buf: [256]u8 = undefined;

    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{log_path}) catch return;
    const fd = c.open(@ptrCast(path_z.ptr), c.O_RDONLY, @as(c_uint, 0));
    if (fd < 0) {
        writeStderr(DIM ++ "No log file found\n" ++ RESET);
        return;
    }
    defer _ = c.close(fd);

    var buf: [4096]u8 = undefined;

    if (follow) {
        writeStderr(DIM ++ "Following log file (Ctrl+C to stop)...\n" ++ RESET);

        while (true) {
            const n_raw = c.read(fd, &buf, buf.len);
            if (n_raw < 0) break;
            const n: usize = @intCast(n_raw);
            if (n > 0) {
                writeStdout(buf[0..n]);
            } else {
                // Sleep briefly before checking again (100ms)
                const sleep_req = Timespec{ .tv_sec = 0, .tv_nsec = 100_000_000 };
                _ = nanosleep(&sleep_req, null);
            }
        }
    } else {
        // Just read and display current contents
        while (true) {
            const n_raw = c.read(fd, &buf, buf.len);
            if (n_raw <= 0) break;
            const n: usize = @intCast(n_raw);
            writeStdout(buf[0..n]);
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;

    // Parse arguments using Args.Iterator for Zig 0.16.2187+
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    if (args.len < 2) {
        printStatus();
        return;
    }

    const command = parseCommand(args[1]);

    switch (command) {
        .status => printStatus(),
        .queue => try queueTask(allocator, args[2..]),
        .approve => {
            if (args.len < 3) {
                writeStderr(RED ++ "Error: " ++ RESET ++ "Missing request ID\n");
                return;
            }
            approveRequest(args[2]);
        },
        .deny => {
            if (args.len < 3) {
                writeStderr(RED ++ "Error: " ++ RESET ++ "Missing request ID\n");
                return;
            }
            denyRequest(args[2]);
        },
        .approve_all => approveAll(),
        .policy => handlePolicy(args[2..]),
        .response => addPreResponse(args[2..]),
        .kill => {
            if (args.len < 3) {
                writeStderr(RED ++ "Error: " ++ RESET ++ "Missing PID\n");
                return;
            }
            killInstance(args[2]);
        },
        .logs => {
            const follow = args.len > 2 and std.mem.eql(u8, args[2], "-f");
            showLogs(follow);
        },
        .help => printUsage(),
        .version => printVersion(),
        .unknown => {
            writeStderr(RED ++ "Error: " ++ RESET ++ "Unknown command: ");
            writeStderr(args[1]);
            writeStderr("\n");
            printUsage();
        },
    }
}
