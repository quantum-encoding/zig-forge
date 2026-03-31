//! Quantum Seed Vault - Main Application
//!
//! Secure seed management on Raspberry Pi with 1.3" LCD HAT.
//! Supports hardware display (ST7789) and terminal mock for testing.
//!
//! Usage:
//!   quantum-seed-vault              # Auto-detect hardware
//!   quantum-seed-vault --terminal   # Force terminal display
//!   quantum-seed-vault --ascii      # ASCII art display

const std = @import("std");
const linux = std.os.linux;
const display = @import("display.zig");
const input = @import("input.zig");
const ui = @import("ui.zig");
const crypto = @import("crypto.zig");

const Framebuffer = display.Framebuffer;
const TerminalDisplay = display.TerminalDisplay;
const ST7789 = display.ST7789;
const InputHandler = input.InputHandler;
const InputEvent = input.InputEvent;
const MenuState = ui.MenuState;
const MenuRenderer = ui.MenuRenderer;

/// Application configuration
const Config = struct {
    /// Force terminal display even if hardware available
    force_terminal: bool = false,
    /// Use ASCII art instead of ANSI colors
    ascii_mode: bool = false,
    /// Target frame rate
    target_fps: u32 = 30,
};

/// Application state
const App = struct {
    config: Config,
    framebuffer: Framebuffer,
    terminal_display: ?TerminalDisplay,
    input_handler: InputHandler,
    menu_state: MenuState,
    menu_renderer: MenuRenderer,
    running: bool,
    frame_count: u64,

    const Self = @This();
    const FRAME_TIME_NS: u64 = 1_000_000_000 / 30; // 30 FPS

    pub fn init(config: Config) Self {
        var fb = Framebuffer.init(display.Colors.BLACK);

        // Initialize terminal display for testing
        var term_display: ?TerminalDisplay = null;
        if (config.force_terminal or !display.isHardwareAvailable()) {
            var term = TerminalDisplay.init();
            term.clear();
            term_display = term;
        }

        // Initialize input handler
        const input_handler = if (config.force_terminal)
            InputHandler.initKeyboard()
        else
            InputHandler.init();

        var menu_state = MenuState.init();
        const menu_renderer = MenuRenderer.init(&fb, &menu_state);

        return Self{
            .config = config,
            .framebuffer = fb,
            .terminal_display = term_display,
            .input_handler = input_handler,
            .menu_state = menu_state,
            .menu_renderer = menu_renderer,
            .running = true,
            .frame_count = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        // Restore terminal
        if (self.terminal_display) |*term| {
            _ = term;
            // Clear screen on exit
            const reset_seq = "\x1b[2J\x1b[H\x1b[0m";
            _ = std.c.write(std.posix.STDOUT_FILENO, reset_seq, reset_seq.len);
        }
        self.input_handler.deinit();
    }

    pub fn run(self: *Self) void {
        // Initialize crypto tables
        crypto.GF256.init();

        // Main loop
        while (self.running) {
            // Handle input
            const input_state = self.input_handler.poll();
            const event = input_state.getEvent();

            if (event != .none) {
                self.running = self.menu_renderer.handleInput(event);
            }

            // Update display
            self.menu_renderer.render();

            // Present to display
            self.present();

            // Frame timing
            self.frame_count += 1;
            self.sleepUntilNextFrame();
        }
    }

    fn present(self: *Self) void {
        if (self.terminal_display) |*term| {
            // Format status line
            var status_buf: [128]u8 = undefined;
            const status = std.fmt.bufPrint(&status_buf, "Frame: {d} | Input: {s}", .{
                self.frame_count,
                self.input_handler.getBackendName(),
            }) catch "Quantum Seed Vault";

            term.renderWithStatus(&self.framebuffer, status);
        }
        // Hardware display would update via ST7789.update()
    }

    fn sleepUntilNextFrame(self: *Self) void {
        // Simple fixed-rate sleep - 30 FPS = ~33ms per frame
        const frame_ns: u64 = 1_000_000_000 / @as(u64, self.config.target_fps);
        var ts = linux.timespec{ .sec = 0, .nsec = @intCast(frame_ns) };
        _ = linux.nanosleep(&ts, null);
    }
};

/// Parse command line arguments
fn parseArgs(args_ptr: std.process.Args) Config {
    var config = Config{};
    var args = std.process.Args.Iterator.init(args_ptr);
    _ = args.next(); // Skip program name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--terminal") or std.mem.eql(u8, arg, "-t")) {
            config.force_terminal = true;
        } else if (std.mem.eql(u8, arg, "--ascii") or std.mem.eql(u8, arg, "-a")) {
            config.ascii_mode = true;
            config.force_terminal = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        }
    }

    return config;
}

fn writeStdout(data: []const u8) void {
    _ = std.c.write(std.posix.STDOUT_FILENO, data.ptr, data.len);
}

fn printUsage() void {
    writeStdout(
        \\Quantum Seed Vault - Secure Seed Management
        \\
        \\USAGE:
        \\  quantum-seed-vault [OPTIONS]
        \\
        \\OPTIONS:
        \\  -t, --terminal    Force terminal display mode
        \\  -a, --ascii       Use ASCII art display (implies --terminal)
        \\  -h, --help        Show this help message
        \\
        \\CONTROLS:
        \\  Arrow keys / WASD / hjkl   Navigate menus
        \\  Enter / Space              Select item
        \\  Escape                     Go back
        \\  Q                          Quit application
        \\
        \\HARDWARE:
        \\  Joystick Up/Down/Left/Right   Navigate
        \\  Joystick Press                Select
        \\  KEY1                          Back
        \\  KEY2                          Confirm
        \\  KEY3                          Options
        \\
    );
}

pub fn main(init: std.process.Init) !void {
    const config = parseArgs(init.minimal.args);

    // Print startup banner
    writeStdout("\x1b[2J\x1b[H"); // Clear screen
    writeStdout(
        \\
        \\  ╔═══════════════════════════════════════╗
        \\  ║     Quantum Seed Vault v1.0.0         ║
        \\  ║   Secure Seed Management System       ║
        \\  ╚═══════════════════════════════════════╝
        \\
        \\  Starting in terminal mode...
        \\  Press Q to quit, Arrow keys to navigate
        \\
        \\
    );

    // Small delay for user to see banner
    var banner_ts = linux.timespec{ .sec = 0, .nsec = 500 * std.time.ns_per_ms };
    _ = linux.nanosleep(&banner_ts, null);

    // Create and run application
    var app = App.init(config);
    defer app.deinit();

    app.run();

    // Exit message
    writeStdout("\n  Goodbye! Stay secure.\n\n");
}

// Tests
test "app initialization" {
    var app = App.init(.{ .force_terminal = true });
    defer app.deinit();

    try std.testing.expect(app.running);
    try std.testing.expectEqual(@as(u64, 0), app.frame_count);
}

test "menu navigation" {
    var state = MenuState.init();
    try std.testing.expectEqual(ui.ScreenId.main_menu, state.current_screen);

    state.navigateTo(.settings);
    try std.testing.expectEqual(ui.ScreenId.settings, state.current_screen);

    const went_back = state.goBack();
    try std.testing.expect(went_back);
    try std.testing.expectEqual(ui.ScreenId.main_menu, state.current_screen);
}
