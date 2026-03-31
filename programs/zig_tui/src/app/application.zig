//! Application runner
//!
//! Main entry point for TUI applications. Handles terminal setup,
//! event loop, and widget rendering.

const std = @import("std");
const core = @import("../core/core.zig");
const input = @import("../input/input.zig");
const render = @import("../render/render.zig");

pub const Buffer = core.Buffer;
pub const Size = core.Size;
pub const Rect = core.Rect;
pub const Event = input.Event;
pub const Parser = input.Parser;
pub const Renderer = render.Renderer;
pub const TerminalMode = render.TerminalMode;

/// Application configuration
pub const Config = struct {
    /// Enable mouse support
    mouse_enabled: bool = true,
    /// Enable focus tracking
    focus_tracking: bool = true,
    /// Use alternate screen buffer
    alt_screen: bool = true,
    /// Tick rate for animations (ms, 0 = disabled)
    tick_rate_ms: u32 = 16, // ~60fps
    /// Initial terminal size (if not detected)
    default_size: Size = .{ .width = 80, .height = 24 },
};

/// Application state
pub const Application = struct {
    allocator: std.mem.Allocator,
    config: Config,
    term_mode: TerminalMode,
    renderer: Renderer,
    parser: Parser,
    buffer: Buffer,
    running: bool,
    size: Size,
    /// User-provided render callback
    render_fn: ?*const fn (*Buffer, Size) void,
    /// User-provided event handler
    event_fn: ?*const fn (Event) bool,
    /// User context pointer
    user_data: ?*anyopaque,

    const Self = @This();

    /// Create a new application
    pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
        const size = detectTerminalSize() orelse config.default_size;

        return Self{
            .allocator = allocator,
            .config = config,
            .term_mode = TerminalMode.init(),
            .renderer = Renderer.init(allocator),
            .parser = Parser{},
            .buffer = try Buffer.init(allocator, size.width, size.height),
            .running = false,
            .size = size,
            .render_fn = null,
            .event_fn = null,
            .user_data = null,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
        self.renderer.deinit();
    }

    /// Set the render callback
    pub fn setRenderCallback(self: *Self, callback: *const fn (*Buffer, Size) void) void {
        self.render_fn = callback;
    }

    /// Set the event handler
    pub fn setEventCallback(self: *Self, callback: *const fn (Event) bool) void {
        self.event_fn = callback;
    }

    /// Set user data pointer
    pub fn setUserData(self: *Self, data: *anyopaque) void {
        self.user_data = data;
    }

    /// Start the application
    pub fn run(self: *Self) !void {
        // Setup terminal
        try self.term_mode.enterRaw();
        // Use defer (not errdefer) to ensure cleanup on ANY exit including panics
        defer self.term_mode.exitRaw();

        if (self.config.alt_screen) {
            self.term_mode.enterAltScreen();
        }
        defer if (self.config.alt_screen) self.term_mode.exitAltScreen();

        if (self.config.mouse_enabled) {
            self.term_mode.enableMouse();
        }
        defer if (self.config.mouse_enabled) self.term_mode.disableMouse();

        if (self.config.focus_tracking) {
            self.term_mode.enableFocus();
        }
        defer if (self.config.focus_tracking) self.term_mode.disableFocus();

        self.term_mode.clearScreen();

        self.running = true;

        // Main event loop
        while (self.running) {
            // Render
            try self.renderFrame();

            // Process input
            try self.processInput();
        }
    }

    /// Stop the application
    pub fn quit(self: *Self) void {
        self.running = false;
    }

    /// Request a redraw
    pub fn redraw(self: *Self) void {
        self.renderer.invalidate();
    }

    /// Get current terminal size
    pub fn getSize(self: *const Self) Size {
        return self.size;
    }

    /// Get drawing area
    pub fn getArea(self: *const Self) Rect {
        return .{ .x = 0, .y = 0, .width = self.size.width, .height = self.size.height };
    }

    fn renderFrame(self: *Self) !void {
        // Check for terminal resize
        if (detectTerminalSize()) |new_size| {
            if (new_size.width != self.size.width or new_size.height != self.size.height) {
                self.size = new_size;
                try self.buffer.resize(new_size.width, new_size.height);
                self.renderer.invalidate(); // Force full redraw
                // Notify user of resize
                _ = self.handleEvent(.{ .resize = .{ .width = new_size.width, .height = new_size.height } });
            }
        }

        // Clear buffer
        self.buffer.clear();

        // Call user render function
        if (self.render_fn) |render_fn| {
            render_fn(&self.buffer, self.size);
        }

        // Render to terminal
        try self.renderer.render(&self.buffer);
    }

    fn processInput(self: *Self) !void {
        var buf: [64]u8 = undefined;

        // Non-blocking read with poll
        const POLLIN: i16 = 0x0001;
        const POLLHUP: i16 = 0x0010;

        var fds = [_]std.posix.pollfd{
            .{
                .fd = std.posix.STDIN_FILENO,
                .events = POLLIN,
                .revents = 0,
            },
        };

        const timeout: i32 = if (self.config.tick_rate_ms > 0)
            @intCast(self.config.tick_rate_ms)
        else
            100;

        const poll_result = std.posix.poll(&fds, timeout) catch return;
        if (poll_result == 0) {
            // Timeout - send tick event
            if (self.config.tick_rate_ms > 0) {
                _ = self.handleEvent(.tick);
            }
            return;
        }

        if ((fds[0].revents & POLLIN) != 0) {
            const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return;
            if (n == 0) return;

            // Parse input bytes
            for (buf[0..n]) |byte| {
                if (self.parser.feed(byte)) |event| {
                    if (!self.handleEvent(event)) {
                        self.running = false;
                        return;
                    }
                }
            }
        }

        // Check for SIGWINCH (terminal resize)
        if ((fds[0].revents & POLLHUP) != 0) {
            if (detectTerminalSize()) |new_size| {
                if (new_size.width != self.size.width or new_size.height != self.size.height) {
                    self.size = new_size;
                    try self.buffer.resize(new_size.width, new_size.height);
                    try self.renderer.handleResize(new_size.width, new_size.height);
                    _ = self.handleEvent(.{ .resize = .{
                        .width = new_size.width,
                        .height = new_size.height,
                    } });
                }
            }
        }
    }

    fn handleEvent(self: *Self, event: Event) bool {
        // Default Ctrl+C handling
        if (event.isCtrlC()) {
            return false;
        }

        // Call user event handler
        if (self.event_fn) |event_fn| {
            return event_fn(event);
        }

        return true;
    }

    fn cleanup(self: *Self) void {
        if (self.config.focus_tracking) {
            self.term_mode.disableFocus();
        }
        if (self.config.mouse_enabled) {
            self.term_mode.disableMouse();
        }
        if (self.config.alt_screen) {
            self.term_mode.exitAltScreen();
        }
        self.term_mode.exitRaw();
    }
};

/// Detect terminal size using ioctl
fn detectTerminalSize() ?Size {
    const TIOCGWINSZ: u32 = 0x5413;

    const Winsize = extern struct {
        ws_row: u16,
        ws_col: u16,
        ws_xpixel: u16,
        ws_ypixel: u16,
    };

    var ws: Winsize = undefined;
    const result = std.os.linux.ioctl(std.posix.STDOUT_FILENO, TIOCGWINSZ, @intFromPtr(&ws));
    if (result == 0 and ws.ws_col > 0 and ws.ws_row > 0) {
        return .{ .width = ws.ws_col, .height = ws.ws_row };
    }
    return null;
}

test "Application init" {
    // Can't fully test without terminal
    // Just verify struct creation
    _ = Config{};
}
