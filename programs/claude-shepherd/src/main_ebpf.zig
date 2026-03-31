//! claude-shepherd-ebpf - eBPF-enabled Claude Code Orchestration Daemon
//!
//! Event-driven monitoring using kernel eBPF hooks.
//! Requires root privileges to load eBPF programs.
//!
//! This is the zero-polling version that listens directly to kernel events.

const std = @import("std");
const config = @import("config.zig");

// C library imports for file operations
const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});
const PolicyEngine = @import("policy/engine.zig").PolicyEngine;
const TaskQueue = @import("queue/scheduler.zig").TaskQueue;
const State = @import("state.zig").State;
const JsonExporter = @import("export.zig").JsonExporter;
const exportCleanup = @import("export.zig").cleanup;
const EbpfConsumer = @import("ebpf_consumer.zig").EbpfConsumer;

const VERSION = "0.1.0-ebpf";

// C functions for daemon operations
extern "c" fn fork() c_int;
extern "c" fn setsid() c_int;
extern "c" fn getpid() c_int;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn umask(mask: u32) u32;
extern "c" fn signal(sig: c_int, handler: ?*const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;
extern "c" fn geteuid() u32;

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
        \\Usage: claude-shepherd-ebpf [OPTIONS]
        \\
        \\Claude Code Orchestration Daemon (eBPF Mode)
        \\
        \\This version uses kernel eBPF for event-driven monitoring.
        \\Requires root privileges to load eBPF programs.
        \\
        \\Options:
        \\  -d, --daemon       Run as background daemon
        \\  -f, --foreground   Run in foreground (default)
        \\  -v, --verbose      Verbose logging
        \\      --status       Show daemon status and exit
        \\      --help         Display this help
        \\      --version      Show version
        \\
        \\Features:
        \\  - Zero-polling kernel event monitoring
        \\  - Automatic Claude instance detection
        \\  - Real-time permission request handling
        \\  - Sub-millisecond event latency
        \\
        \\Example:
        \\  sudo claude-shepherd-ebpf -d    # Start as daemon
        \\  sudo claude-shepherd-ebpf -f    # Run in foreground
        \\
    ;
    writeStderr(usage);
}

fn printVersion() void {
    writeStderr("claude-shepherd-ebpf " ++ VERSION ++ " - eBPF-enabled Claude Orchestration\n");
}

const DaemonConfig = struct {
    run_as_daemon: bool = false,
    verbose: bool = false,
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
        }
    }

    return cfg;
}

fn daemonize() !void {
    const pid1 = fork();
    if (pid1 < 0) return error.ForkFailed;
    if (pid1 > 0) std.process.exit(0);

    if (setsid() < 0) return error.SetsidFailed;

    const pid2 = fork();
    if (pid2 < 0) return error.ForkFailed;
    if (pid2 > 0) std.process.exit(0);

    _ = umask(0o022);
    _ = chdir("/");

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
    var time_buf: [32]u8 = undefined;

    const timestamp = std.fmt.bufPrint(&time_buf, "{d}", .{time(null)}) catch "?";
    const msg = std.fmt.bufPrint(&buf, "[{s}] [{s}] " ++ fmt ++ "\n", .{timestamp} ++ .{level} ++ args) catch return;

    const log_path = "/tmp/claude-shepherd.log";
    var path_buf: [256]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{log_path}) catch return;

    const fd = c.open(@ptrCast(path_z.ptr), c.O_WRONLY | c.O_CREAT | c.O_APPEND, @as(c_uint, 0o644));
    if (fd < 0) return;
    defer _ = c.close(fd);

    _ = c.write(fd, msg.ptr, msg.len);
}

fn showStatus(allocator: std.mem.Allocator) !void {
    _ = allocator;

    writeStdout("\n");
    writeStdout("  Claude Shepherd Status (eBPF Mode)\n");
    writeStdout("  ===================================\n\n");

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
        writeStdout(")\n");
        writeStdout("  Mode: eBPF (event-driven)\n\n");
    }

    writeStdout("  Active Claude instances: (see JSON files)\n");
    writeStdout("  Pending permissions: (see JSON files)\n");
    writeStdout("\n");
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

    if (daemon_cfg.show_status) {
        try showStatus(allocator);
        return;
    }

    // Check for root privileges
    if (geteuid() != 0) {
        writeStderr("Error: eBPF mode requires root privileges\n");
        writeStderr("Run with: sudo claude-shepherd-ebpf\n");
        writeStderr("\nOr use the polling-based daemon: claude-shepherd\n");
        std.process.exit(1);
    }

    // Setup signal handlers
    _ = signal(SIGTERM, signalHandler);
    _ = signal(SIGINT, signalHandler);
    _ = signal(SIGHUP, signalHandler);

    if (daemon_cfg.run_as_daemon) {
        try daemonize();
    }

    try writePidFile();

    log("INFO", "claude-shepherd-ebpf starting (pid={d})", .{getpid()});

    // Initialize components
    var state = try State.init(allocator);
    defer state.deinit();

    var policy_engine = try PolicyEngine.init(allocator);
    defer policy_engine.deinit();

    var task_queue = try TaskQueue.init(allocator);
    defer task_queue.deinit();

    var exporter = JsonExporter.init(allocator, &state);

    // Initialize eBPF consumer
    var consumer = try EbpfConsumer.init(allocator, &state, &policy_engine, &exporter);
    defer consumer.deinit();

    if (!consumer.isEbpfEnabled()) {
        log("ERROR", "Failed to initialize eBPF - falling back would require polling daemon", .{});
        writeStderr("Error: eBPF initialization failed\n");
        writeStderr("Check that:\n");
        writeStderr("  1. You have root privileges\n");
        writeStderr("  2. shepherd.bpf.o exists in zig-out/bin/\n");
        writeStderr("  3. Kernel supports eBPF (Linux 4.15+)\n");
        std.process.exit(1);
    }

    log("INFO", "All components initialized (eBPF mode)", .{});

    if (!daemon_cfg.run_as_daemon) {
        writeStderr("claude-shepherd-ebpf running in foreground (Ctrl+C to stop)\n");
        writeStderr("Monitoring Claude instances via kernel eBPF hooks...\n");
    }

    // Main event loop - eBPF driven, no polling!
    while (g_running) {
        // Poll ring buffer with timeout (this is NOT polling the filesystem)
        // Events are delivered instantly when they occur in the kernel
        consumer.poll(100) catch |err| {
            log("ERROR", "eBPF poll failed: {any}", .{err});
        };

        // Process pending permission requests with policy engine
        state.processPendingRequests(&policy_engine) catch |err| {
            log("ERROR", "Permission processing failed: {any}", .{err});
        };

        // Check task queue for ready tasks
        task_queue.processReady(&state) catch |err| {
            log("ERROR", "Queue processing failed: {any}", .{err});
        };

        // Export state for GNOME extension (with eBPF mode indicator)
        exporter.exportAgents() catch {};
        exporter.exportPermissions() catch {};
        exporter.exportStatusWithMode("ebpf");
    }

    log("INFO", "claude-shepherd-ebpf shutting down", .{});

    exportCleanup();
    _ = unlink("/tmp/claude-shepherd.pid");
}
