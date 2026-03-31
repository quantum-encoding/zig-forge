//! claude-shepherd - Claude Code Orchestration Daemon
//!
//! Monitors, manages, and orchestrates multiple Claude Code instances.
//! Provides permission policies, task queuing, and pre-approved responses.
//!
//! Architecture:
//!   ┌─────────────────────────────────────────────────────┐
//!   │                  claude-shepherd                     │
//!   ├─────────────────────────────────────────────────────┤
//!   │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌────────┐ │
//!   │  │ Watcher │  │ Policy  │  │  Queue  │  │  D-Bus │ │
//!   │  │ (logs)  │  │ Engine  │  │Scheduler│  │ Server │ │
//!   │  └────┬────┘  └────┬────┘  └────┬────┘  └────┬───┘ │
//!   │       │            │            │            │      │
//!   │       └────────────┴────────────┴────────────┘      │
//!   │                        │                            │
//!   │                   ┌────┴────┐                       │
//!   │                   │  State  │                       │
//!   │                   │ Manager │                       │
//!   │                   └─────────┘                       │
//!   └─────────────────────────────────────────────────────┘

const std = @import("std");
const config = @import("config.zig");

// C library imports for file operations
const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});
const PolicyEngine = @import("policy/engine.zig").PolicyEngine;
const TaskQueue = @import("queue/scheduler.zig").TaskQueue;
const ChronosWatcher = @import("watcher/chronos.zig").ChronosWatcher;
const State = @import("state.zig").State;
const JsonExporter = @import("export.zig").JsonExporter;
const exportCleanup = @import("export.zig").cleanup;

const VERSION = "0.1.0";

pub const ClaudeInstance = struct {
    pid: u32,
    task: []const u8,
    working_dir: []const u8,
    status: Status,
    started_at: i64,
    last_activity: i64,

    pub const Status = enum {
        running,
        waiting_permission,
        paused,
        completed,
        failed,
    };
};

pub const PermissionRequest = struct {
    id: u64,
    pid: u32,
    command: []const u8,
    args: []const u8,
    reason: []const u8,
    timestamp: i64,
    status: Status,

    pub const Status = enum {
        pending,
        approved,
        denied,
        auto_approved,
    };
};

// C functions for daemon operations
extern "c" fn fork() c_int;
extern "c" fn setsid() c_int;
extern "c" fn getpid() c_int;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn umask(mask: u32) u32;
extern "c" fn signal(sig: c_int, handler: ?*const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;

const Timespec = extern struct { tv_sec: i64, tv_nsec: i64 };
extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn time(t: ?*i64) i64;

const SIGHUP: c_int = 1;
const SIGTERM: c_int = 15;
const SIGINT: c_int = 2;

var g_running: bool = true;

fn signalHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    g_running = false;
}

fn writeStdout(msg: []const u8) void {
    _ = c.write(1, msg.ptr, msg.len);
}

fn writeStderr(msg: []const u8) void {
    _ = c.write(2, msg.ptr, msg.len);
}

fn printUsage() void {
    const usage =
        \\Usage: claude-shepherd [OPTIONS]
        \\
        \\Claude Code Orchestration Daemon
        \\
        \\Options:
        \\  -d, --daemon       Run as background daemon
        \\  -f, --foreground   Run in foreground (default)
        \\  -c, --config=FILE  Use config file (default: ~/.config/claude-shepherd/config.json)
        \\  -v, --verbose      Verbose logging
        \\      --status       Show daemon status and exit
        \\      --help         Display this help
        \\      --version      Show version
        \\
        \\Commands (via `shepherd` CLI):
        \\  shepherd status              Show all Claude instances
        \\  shepherd queue "task"        Queue a new task
        \\  shepherd approve <id>        Approve permission request
        \\  shepherd deny <id>           Deny permission request
        \\  shepherd approve-all         Approve all pending requests
        \\  shepherd policy add ...      Add policy rule
        \\  shepherd response "on:msg"   Set pre-queued response
        \\
        \\Configuration:
        \\  ~/.config/claude-shepherd/config.json   Main config
        \\  ~/.config/claude-shepherd/policy.json   Permission policies
        \\  ~/.config/claude-shepherd/queue.json    Task queue
        \\
        \\Example:
        \\  claude-shepherd -d                     # Start daemon
        \\  shepherd queue "build zsort"           # Queue task
        \\  shepherd status                        # Check status
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("claude-shepherd " ++ VERSION ++ " - Claude Code Orchestration Daemon\n");
}

const DaemonConfig = struct {
    run_as_daemon: bool = false,
    verbose: bool = false,
    config_path: ?[]const u8 = null,
    show_status: bool = false,
};

fn parseArgs(args: []const []const u8) DaemonConfig {
    var cfg = DaemonConfig{};

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--daemon")) {
            cfg.run_as_daemon = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--foreground")) {
            cfg.run_as_daemon = false;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            cfg.verbose = true;
        } else if (std.mem.eql(u8, arg, "--status")) {
            cfg.show_status = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--version")) {
            printVersion();
            std.process.exit(0);
        } else if (std.mem.startsWith(u8, arg, "-c=") or std.mem.startsWith(u8, arg, "--config=")) {
            const eq_pos = std.mem.indexOf(u8, arg, "=") orelse continue;
            cfg.config_path = arg[eq_pos + 1 ..];
        }
    }

    return cfg;
}

fn daemonize() !void {
    // First fork
    const pid1 = fork();
    if (pid1 < 0) return error.ForkFailed;
    if (pid1 > 0) std.process.exit(0); // Parent exits

    // Create new session
    if (setsid() < 0) return error.SetsidFailed;

    // Second fork (prevent acquiring terminal)
    const pid2 = fork();
    if (pid2 < 0) return error.ForkFailed;
    if (pid2 > 0) std.process.exit(0); // First child exits

    // Set file permissions
    _ = umask(0o022);

    // Change to root directory
    _ = chdir("/");

    // Close standard file descriptors
    _ = c.close(0);
    _ = c.close(1);
    _ = c.close(2);
}

fn writePidFile() !void {
    const pid = getpid();
    const pid_path = "/tmp/claude-shepherd.pid";

    var path_buf: [256]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{pid_path}) catch return;

    const fd = c.open(@ptrCast(path_z.ptr), c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) return;
    defer _ = c.close(fd);

    var buf: [16]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&buf, "{d}\n", .{pid}) catch return;
    _ = c.write(fd, pid_str.ptr, pid_str.len);
}

fn log(comptime level: []const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;

    // Get timestamp
    var time_buf: [32]u8 = undefined;
    const timestamp = std.fmt.bufPrint(&time_buf, "{d}", .{time(null)}) catch "?";

    const msg = std.fmt.bufPrint(&buf, "[{s}] [{s}] " ++ fmt ++ "\n", .{timestamp} ++ .{level} ++ args) catch return;

    // Write to log file
    const log_path = "/tmp/claude-shepherd.log";
    var path_buf: [256]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{log_path}) catch return;

    const fd = c.open(@ptrCast(path_z.ptr), c.O_WRONLY | c.O_CREAT | c.O_APPEND, @as(c_uint, 0o644));
    if (fd < 0) return;
    defer _ = c.close(fd);

    _ = c.write(fd, msg.ptr, msg.len);
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

    const daemon_cfg = parseArgs(args[1..]);

    // Show status mode
    if (daemon_cfg.show_status) {
        try showStatus(allocator);
        return;
    }

    // Setup signal handlers
    _ = signal(SIGTERM, signalHandler);
    _ = signal(SIGINT, signalHandler);
    _ = signal(SIGHUP, signalHandler);

    // Daemonize if requested
    if (daemon_cfg.run_as_daemon) {
        try daemonize();
    }

    // Write PID file
    try writePidFile();

    log("INFO", "claude-shepherd starting (pid={d})", .{getpid()});

    // Initialize components
    var state = try State.init(allocator);
    defer state.deinit();

    var policy_engine = try PolicyEngine.init(allocator);
    defer policy_engine.deinit();

    var task_queue = try TaskQueue.init(allocator);
    defer task_queue.deinit();

    var watcher = try ChronosWatcher.init(allocator, &state);
    defer watcher.deinit();

    // JSON exporter for GNOME extension
    var exporter = JsonExporter.init(allocator, &state);

    log("INFO", "All components initialized", .{});

    if (!daemon_cfg.run_as_daemon) {
        writeStderr("claude-shepherd running in foreground (Ctrl+C to stop)\n");
    }

    // Main event loop
    while (g_running) {
        // Poll chronos logs for activity
        watcher.poll() catch |err| {
            log("ERROR", "Watcher poll failed: {any}", .{err});
        };

        // Process pending permission requests
        state.processPendingRequests(&policy_engine) catch |err| {
            log("ERROR", "Permission processing failed: {any}", .{err});
        };

        // Check task queue for ready tasks
        task_queue.processReady(&state) catch |err| {
            log("ERROR", "Queue processing failed: {any}", .{err});
        };

        // Export state for GNOME extension
        exporter.exportAll();

        // Sleep before next iteration (100ms)
        const sleep_req = Timespec{ .tv_sec = 0, .tv_nsec = 100_000_000 };
        _ = nanosleep(&sleep_req, null);
    }

    log("INFO", "claude-shepherd shutting down", .{});

    // Cleanup JSON export files
    exportCleanup();

    // Cleanup PID file
    _ = unlink("/tmp/claude-shepherd.pid");
}

fn showStatus(allocator: std.mem.Allocator) !void {
    _ = allocator;

    writeStdout("\n");
    writeStdout("  Claude Shepherd Status\n");
    writeStdout("  ======================\n\n");

    // Check if daemon is running
    const fd = c.open("/tmp/claude-shepherd.pid", c.O_RDONLY, @as(c_uint, 0));
    if (fd < 0) {
        writeStdout("  Daemon: NOT RUNNING\n\n");
        return;
    }
    defer _ = c.close(fd);

    var buf: [16]u8 = undefined;
    const n_raw = c.read(fd, &buf, buf.len);
    if (n_raw > 0) {
        const n: usize = @intCast(n_raw);
        writeStdout("  Daemon: RUNNING (PID ");
        writeStdout(buf[0..n]);
        writeStdout(")\n\n");
    }

    // Read state from exported JSON status file
    var status_buf: [4096]u8 = undefined;
    var status_path: [256]u8 = undefined;
    const status_z = std.fmt.bufPrintZ(&status_path, "/tmp/claude-shepherd-status.json", .{}) catch {
        writeStdout("  Active Claude instances: 0\n");
        writeStdout("  Pending permissions: 0\n");
        writeStdout("  Queued tasks: 0\n");
        return;
    };
    const status_fd = c.open(@ptrCast(status_z.ptr), c.O_RDONLY, @as(c_uint, 0));
    if (status_fd >= 0) {
        defer _ = c.close(status_fd);
        const sn = c.read(status_fd, &status_buf, status_buf.len);
        if (sn > 0) {
            const status_n: usize = @intCast(sn);
            writeStdout("  ");
            writeStdout(status_buf[0..status_n]);
            writeStdout("\n");
        } else {
            writeStdout("  Active Claude instances: 0\n");
            writeStdout("  Pending permissions: 0\n");
            writeStdout("  Queued tasks: 0\n");
        }
    } else {
        writeStdout("  Active Claude instances: 0\n");
        writeStdout("  Pending permissions: 0\n");
        writeStdout("  Queued tasks: 0\n");
    }
}

test "signal handler sets g_running to false" {
    g_running = true;
    signalHandler(SIGTERM);
    try std.testing.expect(!g_running);
}
