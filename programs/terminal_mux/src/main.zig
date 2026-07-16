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
const lib = @import("lib.zig");

/// This toolchain's std.c doesn't expose signal(3); declare the libc extern
/// directly (same pattern as zig_ai's execvp). Portable signal() over
/// sigaction per the guardian_shield lesson (platform-specific struct layout).
const SignalHandler = ?*const fn (c_int) callconv(.c) void;
extern "c" fn signal(sig: c_int, handler: SignalHandler) SignalHandler;

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
    // This binary runs a self-contained, single-process session (the multiplexer
    // core driving a PTY + VT emulator). Cross-process attach/detach is provided
    // by the in-process C ABI (libterminal_mux, src/capi.zig) for embedding into
    // host apps such as the Swift/SwiftUI front-end — see docs/CAPI.md.
    try runServer(allocator, session_name);
}

fn attachToSession(allocator: std.mem.Allocator, session_name: []const u8) !void {
    // No standalone socket daemon in this build; run the session directly.
    try runServer(allocator, session_name);
}

fn runServer(allocator: std.mem.Allocator, session_name: []const u8) !void {
    const socket_path = try lib.ipc.getDefaultSocketPath(allocator);
    defer allocator.free(socket_path);

    // Ensure socket directory exists
    try lib.ipc.ensureSocketDir(socket_path);

    // Get terminal size (kept current via SIGWINCH below)
    var size = lib.pty.getTerminalSize(posix.STDIN_FILENO) catch lib.Winsize{
        .ws_row = 24,
        .ws_col = 80,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    // A fresh PTY reports 0x0 until the host sets a winsize; `ws_row - 1`
    // below would underflow u16. Fall back until a real SIGWINCH arrives.
    if (size.ws_row < 2 or size.ws_col < 2) {
        size.ws_row = 24;
        size.ws_col = 80;
    }

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

    // Host terminal resize: the handler only sets a flag; the loop re-reads the
    // size and resizes the session. Portable signal() per the guardian_shield
    // lesson (sigaction's struct layout is platform-specific and has crashed
    // before). poll() returning EINTR is already swallowed by the `catch 0`.
    const winch = struct {
        var got = std.atomic.Value(bool).init(false);
        fn handle(_: c_int) callconv(.c) void {
            got.store(true, .monotonic);
        }
    };
    _ = signal(@intFromEnum(std.c.SIG.WINCH), winch.handle);

    // Input state
    var prefix_active = false;
    const cfg = lib.Config{};

    var running = true;
    var input_buf: [4096]u8 = undefined;
    var pty_buf: [65536]u8 = undefined;

    // Layout/window changes need a clear + full repaint: dirty-row rendering
    // only touches rows the panes wrote, never cells the OLD layout owned.
    var force_redraw = false;

    // Poll set rebuilt per iteration: stdin + every pane's PTY (all windows).
    var poll_fds: std.ArrayList(posix.pollfd) = .empty;
    defer poll_fds.deinit(allocator);
    var poll_panes: std.ArrayList(*lib.session.Pane) = .empty;
    defer poll_panes.deinit(allocator);

    // Main event loop — poll() is portable across Linux (epoll equivalent) and
    // Darwin (kqueue equivalent) without per-platform code.
    while (running) {
        // Apply a pending host resize before anything reads pane geometry:
        // grid + PTY follow the new size (SIGWINCH reaches the shell), and a
        // clear + full redraw flushes stale rows the smaller frame won't touch.
        if (winch.got.swap(false, .monotonic)) {
            if (lib.pty.getTerminalSize(posix.STDIN_FILENO) catch null) |ns| {
                if (ns.ws_row < 2 or ns.ws_col < 2) continue; // bogus size; keep current
                size = ns;
                initial_session.resize(.{
                    .x = 0,
                    .y = 0,
                    .width = ns.ws_col,
                    .height = ns.ws_row - 1, // -1 for status bar
                }) catch {};
                renderer.beginFrame();
                try renderer.clearScreen();
                _ = c.write(posix.STDOUT_FILENO, renderer.getOutput().ptr, renderer.getOutput().len);
            }
        }

        // Poll stdin + EVERY pane's PTY across all windows: a busy pane in a
        // background split/window must keep draining, or its app blocks on a
        // full PTY buffer the moment focus leaves it — the whole point of a
        // multiplexer is that it doesn't.
        poll_fds.clearRetainingCapacity();
        poll_panes.clearRetainingCapacity();
        try poll_fds.append(allocator, .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 });
        for (initial_session.windows.items) |w| {
            for (w.panes.items) |p| {
                const fd = p.getFd() orelse continue;
                try poll_fds.append(allocator, .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 });
                try poll_panes.append(allocator, p);
            }
        }

        const n_ready = posix.poll(poll_fds.items, 100) catch 0; // 100ms timeout

        if (n_ready > 0) {
            // Handle user input from stdin
            if (poll_fds.items[0].revents & posix.POLL.IN != 0) {
                const n = posix.read(posix.STDIN_FILENO, &input_buf) catch 0;
                if (n == 0) {
                    running = false;
                } else {
                    for (input_buf[0..n]) |byte| {
                        if (prefix_active) {
                            // Handle prefix commands
                            prefix_active = false;

                            switch (byte) {
                                'd' => {
                                    // Detach
                                    running = false;
                                },
                                'c' => {
                                    // New window: select it BY INDEX (nextWindow
                                    // from window k of n lands on k+1, not the
                                    // new last window) and spawn its shell — a
                                    // pane without a spawned shell is dead air.
                                    if (initial_session.createWindow() catch null) |new_win| {
                                        _ = initial_session.selectWindow(new_win.index);
                                        new_win.getActivePane().spawn(shell, env) catch {};
                                    }
                                    force_redraw = true;
                                },
                                'n' => {
                                    // Next window
                                    initial_session.nextWindow();
                                    force_redraw = true;
                                },
                                'p' => {
                                    // Previous window
                                    initial_session.prevWindow();
                                    force_redraw = true;
                                },
                                '%' => {
                                    // Split horizontal + spawn a shell in the new pane
                                    const active_window = initial_session.getActiveWindow();
                                    if (active_window.split(.horizontal, 10000) catch null) |new_pane| {
                                        new_pane.spawn(shell, env) catch {};
                                    }
                                    force_redraw = true;
                                },
                                '"' => {
                                    // Split vertical + spawn a shell in the new pane
                                    const active_window = initial_session.getActiveWindow();
                                    if (active_window.split(.vertical, 10000) catch null) |new_pane| {
                                        new_pane.spawn(shell, env) catch {};
                                    }
                                    force_redraw = true;
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
                }
            }

            // Drain every pane with output ready (poll_fds[i+1] ↔ poll_panes[i]).
            // Panes created by a split THIS iteration aren't in the set yet;
            // the next iteration picks them up.
            for (poll_panes.items, 0..) |p, i| {
                if (poll_fds.items[i + 1].revents & posix.POLL.IN == 0) continue;
                const n = p.readOutput(&pty_buf) catch continue;
                if (n > 0) p.processOutput(pty_buf[0..n]);
            }
        }

        // Render
        renderer.beginFrame();
        try renderer.hideCursor();

        const active_window = initial_session.getActiveWindow();
        if (force_redraw) {
            force_redraw = false;
            try renderer.clearScreen();
            for (active_window.panes.items) |p| p.terminal.markAllDirty();
        }
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

        // Reap dead panes in the active window (any pane, not just the focused
        // one). Empty window → close it; last window empty → exit. The reflow
        // after removePane re-tiles the survivors over the freed space.
        var pi: usize = 0;
        while (pi < active_window.panes.items.len) {
            const p = active_window.panes.items[pi];
            if (p.isAlive()) {
                pi += 1;
                continue;
            }
            if (active_window.panes.items.len <= 1) {
                if (!initial_session.removeWindow(initial_session.active_window_idx)) {
                    running = false;
                }
                force_redraw = true;
                break; // active_window is gone (or we're exiting)
            }
            _ = active_window.removePane(p.id);
            active_window.resize(initial_session.rect) catch {};
            force_redraw = true;
        }
    }

    // Cleanup
    renderer.beginFrame();
    try renderer.exitAltScreen();
    try renderer.showCursor();
    _ = c.write(posix.STDOUT_FILENO, renderer.getOutput().ptr, renderer.getOutput().len);
}

fn listSessions(allocator: std.mem.Allocator) !void {
    _ = allocator;
    // The standalone binary is single-session; multi-session enumeration lives
    // in the embedding C ABI (tmux_list, src/capi.zig).
    std.debug.print("This build runs one session per process. For multi-session\n", .{});
    std.debug.print("attach/detach, embed libterminal_mux (see docs/CAPI.md).\n", .{});
}

fn killSession(allocator: std.mem.Allocator, session_name: []const u8) !void {
    _ = allocator;
    std.debug.print("kill-session '{s}': not applicable to the standalone binary.\n", .{session_name});
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
