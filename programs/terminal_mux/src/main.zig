//! Terminal Multiplexer - Main Entry Point
//!
//! Usage:
//!   tmux                    # Start new session or attach to existing
//!   tmux new -s name        # Create new session with name
//!   tmux attach -t name     # Attach to existing session
//!   tmux list-sessions      # List all sessions
//!   tmux kill-session -t X  # Kill session
//!
//! When attached:
//!   Ctrl-b d               # Detach from session
//!   Ctrl-b c               # Create new window
//!   Ctrl-b n/p             # Next/previous window
//!   Ctrl-b %               # Split horizontally
//!   Ctrl-b "               # Split vertically

const std = @import("std");
const posix = std.posix;
const c = std.c;
const linux = std.os.linux;
const lib = @import("lib.zig");

const VERSION = "0.1.0";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Collect args into a slice
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(allocator);
    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    // Parse command
    if (args.len < 2) {
        // Default: try to attach or create new session
        try attachOrCreate(allocator, "0");
        return;
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printHelp();
        return;
    }

    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        std.debug.print("terminal_mux {s}\n", .{VERSION});
        return;
    }

    if (std.mem.eql(u8, cmd, "new") or std.mem.eql(u8, cmd, "new-session")) {
        var session_name: []const u8 = "0";

        // Parse options
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "-s") and i + 1 < args.len) {
                i += 1;
                session_name = args[i];
            }
        }

        try runServer(allocator, session_name);
        return;
    }

    if (std.mem.eql(u8, cmd, "attach") or std.mem.eql(u8, cmd, "a")) {
        var session_name: []const u8 = "0";

        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
                i += 1;
                session_name = args[i];
            }
        }

        try attachToSession(allocator, session_name);
        return;
    }

    if (std.mem.eql(u8, cmd, "list-sessions") or std.mem.eql(u8, cmd, "ls")) {
        try listSessions(allocator);
        return;
    }

    if (std.mem.eql(u8, cmd, "kill-session")) {
        var session_name: ?[]const u8 = null;

        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
                i += 1;
                session_name = args[i];
            }
        }

        if (session_name) |name| {
            try killSession(allocator, name);
        } else {
            std.debug.print("Error: -t <session> required\n", .{});
        }
        return;
    }

    std.debug.print("Unknown command: {s}\n", .{cmd});
    printHelp();
}

fn attachOrCreate(allocator: std.mem.Allocator, session_name: []const u8) !void {
    const socket_path = try lib.ipc.getDefaultSocketPath(allocator);
    defer allocator.free(socket_path);

    // Try to connect to existing server
    var client = lib.IpcClient.connect(allocator, socket_path) catch {
        // No server running, start one
        try runServer(allocator, session_name);
        return;
    };
    defer client.deinit();

    // Server exists, attach to it
    try runClient(allocator, &client, session_name);
}

fn attachToSession(allocator: std.mem.Allocator, session_name: []const u8) !void {
    const socket_path = try lib.ipc.getDefaultSocketPath(allocator);
    defer allocator.free(socket_path);

    var client = lib.IpcClient.connect(allocator, socket_path) catch {
        std.debug.print("No server running. Use 'tmux new' to start a session.\n", .{});
        return;
    };
    defer client.deinit();

    try runClient(allocator, &client, session_name);
}

fn runServer(allocator: std.mem.Allocator, session_name: []const u8) !void {
    const socket_path = try lib.ipc.getDefaultSocketPath(allocator);
    defer allocator.free(socket_path);

    // Ensure socket directory exists
    try lib.ipc.ensureSocketDir(socket_path);

    // Get terminal size
    const size = lib.pty.getTerminalSize(posix.STDIN_FILENO) catch lib.Winsize{
        .ws_row = 24,
        .ws_col = 80,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    const rect = lib.Rect{
        .x = 0,
        .y = 0,
        .width = size.ws_col,
        .height = size.ws_row - 1, // -1 for status bar
    };

    // Create session manager
    var session_manager = lib.SessionManager.init(allocator);
    defer session_manager.deinit();

    // Create initial session
    const initial_session = try session_manager.createSession(session_name, rect, 10000);

    // Spawn shell in first pane
    const window = initial_session.getActiveWindow();
    const pane = window.getActivePane();

    const shell = if (std.c.getenv("SHELL")) |s| std.mem.sliceTo(s, 0) else "/bin/bash";
    const env = std.c.environ;
    try pane.spawn(shell, env);

    // Initialize renderer
    var renderer = lib.Renderer.init(allocator);
    defer renderer.deinit();

    // Enter raw mode and alternate screen
    var raw_mode = try lib.RawMode.enter(posix.STDIN_FILENO);
    defer raw_mode.exit();

    renderer.beginFrame();
    try renderer.enterAltScreen();
    try renderer.hideCursor();
    try renderer.clearScreen();
    _ = c.write(posix.STDOUT_FILENO, renderer.getOutput().ptr, renderer.getOutput().len);

    // Main event loop
    const epoll_ret = linux.epoll_create1(0);
    if (epoll_ret > std.math.maxInt(isize)) return error.EpollCreateFailed;
    const epoll_fd: i32 = @intCast(epoll_ret);
    defer _ = std.c.close(epoll_fd);

    // Add stdin to epoll
    var stdin_event = linux.epoll_event{
        .events = linux.EPOLL.IN,
        .data = .{ .fd = posix.STDIN_FILENO },
    };
    _ = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, posix.STDIN_FILENO, &stdin_event);

    // Add PTY master to epoll
    if (pane.getFd()) |pty_fd| {
        var pty_event = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .fd = pty_fd },
        };
        _ = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, pty_fd, &pty_event);
    }

    // Input state
    var prefix_active = false;
    const cfg = lib.Config{};

    var running = true;
    var input_buf: [4096]u8 = undefined;
    var pty_buf: [65536]u8 = undefined;
    var events: [16]std.os.linux.epoll_event = undefined;

    while (running) {
        const wait_ret = linux.epoll_wait(epoll_fd, &events, 16, 100); // 100ms timeout
        if (wait_ret > std.math.maxInt(isize)) continue; // Error, retry
        const n_events: usize = wait_ret;

        for (events[0..n_events]) |event| {
            const fd = event.data.fd;

            if (fd == posix.STDIN_FILENO) {
                // Handle user input
                const n = posix.read(posix.STDIN_FILENO, &input_buf) catch 0;
                if (n == 0) {
                    running = false;
                    continue;
                }

                const input = input_buf[0..n];

                // Process input
                for (input) |byte| {
                    if (prefix_active) {
                        // Handle prefix commands
                        prefix_active = false;

                        switch (byte) {
                            'd' => {
                                // Detach
                                running = false;
                            },
                            'c' => {
                                // New window
                                _ = initial_session.createWindow() catch {};
                                initial_session.nextWindow();
                            },
                            'n' => {
                                // Next window
                                initial_session.nextWindow();
                            },
                            'p' => {
                                // Previous window
                                initial_session.prevWindow();
                            },
                            '%' => {
                                // Split horizontal
                                const active_window = initial_session.getActiveWindow();
                                _ = active_window.split(.horizontal, 10000) catch {};
                            },
                            '"' => {
                                // Split vertical
                                const active_window = initial_session.getActiveWindow();
                                _ = active_window.split(.vertical, 10000) catch {};
                            },
                            'o' => {
                                // Next pane
                                initial_session.getActiveWindow().focusNext();
                            },
                            else => {
                                // Unknown command, send raw
                                const active_pane = initial_session.getActiveWindow().getActivePane();
                                active_pane.sendInput(&[_]u8{byte}) catch {};
                            },
                        }
                    } else if (byte == cfg.prefix_key.char - 'a' + 1 and cfg.prefix_key.mods.ctrl) {
                        // Prefix key pressed (Ctrl-b = 0x02)
                        prefix_active = true;
                    } else if (byte == 0x02) {
                        // Ctrl-b
                        prefix_active = true;
                    } else {
                        // Send to active pane
                        const active_pane = initial_session.getActiveWindow().getActivePane();
                        active_pane.sendInput(&[_]u8{byte}) catch {};
                    }
                }
            } else {
                // Handle PTY output
                const active_pane = initial_session.getActiveWindow().getActivePane();
                if (active_pane.getFd()) |pty_fd| {
                    if (fd == pty_fd) {
                        const n = active_pane.readOutput(&pty_buf) catch 0;
                        if (n > 0) {
                            active_pane.processOutput(pty_buf[0..n]);
                        }
                    }
                }
            }
        }

        // Render
        renderer.beginFrame();
        try renderer.hideCursor();

        const active_window = initial_session.getActiveWindow();
        try renderer.renderWindow(active_window, active_window.panes.items.len > 1);

        // Status bar
        try renderer.renderStatusBar(
            &cfg.status_bar,
            initial_session.getName(),
            active_window.index,
            size.ws_row,
            size.ws_col,
        );

        // Position cursor
        const active_pane = active_window.getActivePane();
        const term = &active_pane.terminal;
        if (term.modes.cursor_visible) {
            try renderer.showCursor();
        }

        // Write output
        _ = c.write(posix.STDOUT_FILENO, renderer.getOutput().ptr, renderer.getOutput().len);

        // Check if process died
        if (!active_pane.isAlive()) {
            // Remove dead pane or exit if last one
            if (active_window.panes.items.len <= 1) {
                running = false;
            } else {
                _ = active_window.removePane(active_pane.id);
            }
        }
    }

    // Cleanup
    renderer.beginFrame();
    try renderer.exitAltScreen();
    try renderer.showCursor();
    _ = c.write(posix.STDOUT_FILENO, renderer.getOutput().ptr, renderer.getOutput().len);
}

fn runClient(allocator: std.mem.Allocator, client: *lib.IpcClient, session_name: []const u8) !void {
    _ = allocator;
    _ = client;
    _ = session_name;
    std.debug.print("Client mode not fully implemented yet. Running server directly.\n", .{});
}

fn listSessions(allocator: std.mem.Allocator) !void {
    const socket_path = try lib.ipc.getDefaultSocketPath(allocator);
    defer allocator.free(socket_path);

    _ = lib.IpcClient.connect(allocator, socket_path) catch {
        std.debug.print("No sessions.\n", .{});
        return;
    };

    std.debug.print("Session listing not fully implemented yet.\n", .{});
}

fn killSession(allocator: std.mem.Allocator, session_name: []const u8) !void {
    _ = allocator;
    _ = session_name;
    std.debug.print("Kill session not implemented yet.\n", .{});
}

fn printHelp() void {
    std.debug.print(
        \\Terminal Multiplexer v{s}
        \\
        \\Usage: tmux [command] [options]
        \\
        \\Commands:
        \\  new [-s name]          Create a new session
        \\  attach [-t name]       Attach to an existing session
        \\  list-sessions          List all sessions
        \\  kill-session -t name   Kill a session
        \\
        \\Options:
        \\  -h, --help             Show this help
        \\  -v, --version          Show version
        \\
        \\Key Bindings (default prefix: Ctrl-b):
        \\  d                      Detach from session
        \\  c                      Create new window
        \\  n / p                  Next / previous window
        \\  %                      Split pane horizontally
        \\  "                      Split pane vertically
        \\  o                      Switch to next pane
        \\  0-9                    Select window by number
        \\
        \\Examples:
        \\  tmux                   Start new session (or attach if one exists)
        \\  tmux new -s dev        Create session named "dev"
        \\  tmux attach -t dev     Attach to session "dev"
        \\
    , .{VERSION});
}
